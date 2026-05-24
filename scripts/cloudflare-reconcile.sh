#!/usr/bin/env bash
# ============================================================================
# Cloudflare Tunnel + DNS Reconcile  (idempotent, pro-VPS-sicher)
#
# Liest scripts/cloudflare-routes.json + .env, gleicht ab:
#   0. Tunnel-Ensure: sucht "brewing-<sanitisierter-hostname>" per API;
#      existiert er nicht → anlegen (config_src: cloudflare). Liefert die
#      Tunnel-ID und schreibt sie in die lokale .env. Das Holen des
#      Connector-Tokens (CLOUDFLARE_TUNNEL_TOKEN) geschieht AUSSCHLIESSLICH
#      im Bootstrap (cf_ensure_tunnel_if_token), nicht hier.
#   1. Tunnel-Ingress (nur laufende Ziel-Container auf diesem VPS)
#   2. DNS-CNAMEs auf den eigenen Tunnel (nur beanspruchte Hostnames)
#   3. Orphan-Cleanup (CNAMEs die auf den EIGENEN Tunnel zeigen und nicht
#      mehr beansprucht sind — gescoped auf ${TUNNEL_ID}.cfargotunnel.com)
#
# Manuell:        ./scripts/cloudflare-reconcile.sh
# Aus bootstrap:  aufgerufen nach dem Container-Start
#
# Routing-Map ändern: scripts/cloudflare-routes.json editieren, dann erneut
# laufen lassen. Nur das Delta wird API-seitig geändert.
#
# Subcommand-Modus (nur Tunnel-Ensure, kein Reconcile):
#   ./scripts/cloudflare-reconcile.sh --ensure-tunnel-only
#   Gibt auf stdout aus: TUNNEL_ID=<id>
#   Wird von bootstrap.sh für cf_ensure_tunnel_if_token() genutzt.
#
# Token-Verantwortung:
#   Connector-Token (CLOUDFLARE_TUNNEL_TOKEN) wird von bootstrap.sh
#   cf_ensure_tunnel_if_token() geholt und in die lokale .env geschrieben.
#   Dieser Reconcile braucht und liest den Connector-Token NICHT —
#   er arbeitet nur mit CLOUDFLARE_API_TOKEN + der ermittelten Tunnel-ID.
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
ROUTES_JSON="scripts/cloudflare-routes.json"
ENV_FILE=".env"

# Subcommand-Flag
ENSURE_ONLY=0
case "${1:-}" in
  --ensure-tunnel-only) ENSURE_ONLY=1 ;;
  "")                   : ;;
  *) printf 'Unbekanntes Argument: %s\n' "$1" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- Zentrale EXIT-Trap (C-1)
# Alle mktemp-Pfade werden hier registriert. Nach einem erfolgreichen 'mv <tmp> <ziel>'
# ist der Original-Pfad (nicht das mv-Ziel) im Array — 'rm -f' auf den nicht mehr
# existierenden Pfad ist harmlos. Niemals den .env-Pfad selbst ins Array aufnehmen.
declare -a _RECONCILE_CLEANUP=()
_cleanup_reconcile() {
  local f
  for f in "${_RECONCILE_CLEANUP[@]+"${_RECONCILE_CLEANUP[@]}"}"; do
    rm -f "$f"
  done
}
trap '_cleanup_reconcile' EXIT

# ---------------------------------------------------------------- Helpers
# Im --ensure-tunnel-only-Modus schreiben log/ok nach stderr (fd 2), damit
# stdout als reiner Maschinen-Kanal (nur 'TUNNEL_ID=…') nutzbar ist (I-2).
# fd 3 wird im ensure-only-Pfad auf den ursprünglichen stdout umgelenkt.
if (( ENSURE_ONLY == 1 )); then
  exec 3>&1 1>&2
fi
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
err()  { echo -e "\033[1;31m✖ $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------- Pre-flight
[[ -f "$ROUTES_JSON" ]] || err "Keine Routes-Map: $ROUTES_JSON"
[[ -f "$ENV_FILE" ]]   || err "Keine .env — erst ./scripts/decrypt-env.sh"
command -v jq   >/dev/null || err "jq fehlt (apt install jq)"
command -v curl >/dev/null || err "curl fehlt"

# Nur die benötigten CF-Werte aus .env lesen — kein set -a/source, damit
# OpenAI/RAPT/Brewfather/Postgres-Keys nicht in den Reconcile-Prozess lecken.
# Connector-Token (CLOUDFLARE_TUNNEL_TOKEN) wird NICHT gelesen (Trennung, §5.1).
_cf_get() {
  local key="$1"
  local val
  val="$(grep -E "^${key}=[[:print:]]" "$ENV_FILE" | head -1 | cut -d= -f2-)"
  printf '%s' "$val"
}

CLOUDFLARE_API_TOKEN="$(_cf_get CLOUDFLARE_API_TOKEN)"
CLOUDFLARE_ACCOUNT_ID="$(_cf_get CLOUDFLARE_ACCOUNT_ID)"
CLOUDFLARE_ZONE_ID="$(_cf_get CLOUDFLARE_ZONE_ID)"

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN fehlt in .env}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID fehlt in .env}"
: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID fehlt in .env}"

CF_API="https://api.cloudflare.com/client/v4"
# AUTH_HEADER: pre-existing Muster (Bearer in curl-argv). Der Connector-Token
# kommt nie in argv — nur der API-Token (der für DNS/Tunnel-Config nicht
# sicherheitskritisch ist wie der Connector-Token).
AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

# cf_call <method> <path> [json_body]  → body to stdout, exit on error
cf_call() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -w '\n%{http_code}' -X "$method"
              -H "$AUTH_HEADER" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(-d "$body")
  local raw http_code resp_body
  raw="$(curl "${args[@]}" "${CF_API}${path}")"
  http_code="${raw##*$'\n'}"
  resp_body="${raw%$'\n'*}"
  if (( http_code < 200 || http_code >= 300 )); then
    err "CF API $method $path → HTTP $http_code: $resp_body"
  fi
  if [[ "$(echo "$resp_body" | jq -r '.success // false')" != "true" ]]; then
    err "CF API $method $path → success=false: $(echo "$resp_body" | jq -c '.errors // .')"
  fi
  echo "$resp_body"
}

# ============================================================================
# Hostname-Sanitisierung für Tunnel-Namen
#   brewing-<sanitisierter-hostname>
#   Regeln: lowercasen; alles außer [a-z0-9-] → "-"; führende/abschließende
#           "-" trimmen; Mehrfach-"-" kollabieren; max 60 Zeichen Gesamt-Name
#           (inkl. "brewing-"-Prefix, also max 52 Zeichen für den Hostname-Teil).
# ============================================================================
_sanitize_hostname() {
  local h="$1"
  # Lowercase
  h="${h,,}"
  # Alles außer a-z, 0-9, Bindestrich → Bindestrich
  h="${h//[^a-z0-9-]/-}"
  # Mehrfach-Bindestriche kollabieren (bash loop statt sed)
  while [[ "$h" == *"--"* ]]; do
    h="${h//--/-}"
  done
  # Führende und abschließende Bindestriche trimmen
  h="${h#-}"
  h="${h%-}"
  # Auf 52 Zeichen kürzen (brewing- = 8 Zeichen, Gesamt ≤ 60)
  h="${h:0:52}"
  # Nochmal trailing Bindestrich nach dem Trim entfernen (falls Kürzung mitten in "-" landete)
  h="${h%-}"
  printf '%s' "$h"
}

# ============================================================================
# Tunnel-Name ableiten
# Quelle: CLOUDFLARE_TUNNEL_NAME in .env (optionaler Override),
#         sonst: brewing-<sanitisierter hostname aus hostnamectl --static>
# Begründung hostnamectl --static: stabiler über Reboots (cloud-init ändert
# manchmal /etc/hostname zur Laufzeit, hostnamectl --static liest den
# persistierten Wert). Fallback: hostname -s falls hostnamectl fehlt.
# ============================================================================
_derive_tunnel_name() {
  # Optionaler Override aus .env
  local override
  override="$(_cf_get CLOUDFLARE_TUNNEL_NAME)"
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return
  fi

  local raw_host sanitized
  if command -v hostnamectl >/dev/null 2>&1; then
    raw_host="$(hostnamectl --static 2>/dev/null || hostname -s)"
  else
    raw_host="$(hostname -s)"
  fi
  sanitized="$(_sanitize_hostname "$raw_host")"
  [[ -n "$sanitized" ]] \
    || err "Hostname '${raw_host}' ergibt nach Sanitisierung einen leeren String. \
Setze CLOUDFLARE_TUNNEL_NAME manuell in .env (z.B. CLOUDFLARE_TUNNEL_NAME=brewing-vps-a)."
  printf 'brewing-%s' "$sanitized"
}

# ============================================================================
# Container-Name aus routes[].service ableiten
#   Eingabe:  "http://web-rapt:80"  oder  "tcp://supabase-db:5432"
#   Ausgabe:  "web-rapt"           bzw.   "supabase-db"
#   Methode:  Schema entfernen, Port abschneiden.
#   Alle container_name in docker-compose.yml nutzen Bindestriche —
#   routes.json ebenfalls. Kein Mapping von Unterstrich auf Bindestrich nötig
#   (A-3 verifiziert: exakter 1:1-Match).
# ============================================================================
_service_to_container() {
  local service="$1"
  # Schema entfernen (http:// oder tcp://)
  local host_port="${service#*://}"
  # Port abschneiden
  printf '%s' "${host_port%:*}"
}

# ============================================================================
# Step 0: Tunnel-Ensure (idempotent)
#   Sucht "brewing-<sanitisierter-hostname>" in der Account-Tunnel-Liste.
#   Falls gefunden → ID übernehmen.
#   Falls nicht gefunden → neu anlegen (config_src: cloudflare).
#   Schreibt die ID immer in die lokale .env (CLOUDFLARE_TUNNEL_ID=<id>).
#   Im --ensure-tunnel-only-Modus: gibt zusätzlich "TUNNEL_ID=<id>" auf
#   stdout aus (für bootstrap.sh zum Lesen) und beendet sich danach.
# ============================================================================
log "Tunnel-Ensure (brewing-<hostname>, idempotent)"

TUNNEL_NAME="$(_derive_tunnel_name)"
# I-1: Finalen Tunnel-Namen auf erlaubte Zeichen prüfen, bevor er in API-Calls geht.
# Erlaubt: [a-z0-9] (Start), dann [a-z0-9-]* — kein Leerzeichen, kein Underscore.
[[ "$TUNNEL_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
  || err "Tunnel-Name '${TUNNEL_NAME}' enthält ungültige Zeichen (nur [a-z0-9-] erlaubt). \
Setze CLOUDFLARE_TUNNEL_NAME manuell in .env (z.B. CLOUDFLARE_TUNNEL_NAME=brewing-vps-a)."
log "Tunnel-Name: ${TUNNEL_NAME}"

# Per Name suchen (exakter Match, nicht-gelöschte)
TUNNEL_LIST="$(cf_call GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false")"
# Exakter Name-Match (API filtert schon, aber Extra-Zeichen im Namen könnten
# Teil-Matches liefern → nochmals mit jq filtern)
TUNNEL_ID="$(printf '%s' "$TUNNEL_LIST" \
  | jq -r --arg n "$TUNNEL_NAME" \
      '.result[] | select(.name == $n) | .id' \
  | head -1)"

if [[ -n "$TUNNEL_ID" ]]; then
  ok "Tunnel '${TUNNEL_NAME}' existiert bereits (ID: ${TUNNEL_ID})"
else
  log "Tunnel '${TUNNEL_NAME}' nicht gefunden — lege an"
  # config_src: cloudflare = remote-managed = passt zum PUT .../configurations (Step 1).
  # A-1: erwartet ja; bei Abweichung in Prod dokumentieren.
  CREATE_BODY="$(jq -nc --arg name "$TUNNEL_NAME" \
    '{"name": $name, "config_src": "cloudflare"}')"
  CREATE_RESP="$(cf_call POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" "$CREATE_BODY")"
  TUNNEL_ID="$(printf '%s' "$CREATE_RESP" | jq -r '.result.id')"
  [[ -n "$TUNNEL_ID" && "$TUNNEL_ID" != "null" ]] \
    || err "Tunnel-Create lieferte keine ID — Antwort: ${CREATE_RESP}"
  ok "Tunnel '${TUNNEL_NAME}' angelegt (ID: ${TUNNEL_ID})"
fi

# Tunnel-ID in lokale .env schreiben (Idempotenz: ersetze bestehende Zeile oder hänge an)
# Kein set -x, kein echo der ID ins Log (nicht geheim, aber defensiv konsistent).
if grep -q '^CLOUDFLARE_TUNNEL_ID=' "$ENV_FILE"; then
  # Vorhandene Zeile ersetzen — reines bash mit tmp-Datei für atomisches Schreiben.
  # C-1: Kein inline trap; Tempfile wird in zentralem _RECONCILE_CLEANUP registriert.
  # Nach dem 'mv' existiert der Tempfile-Pfad nicht mehr — 'rm -f' in _cleanup_reconcile
  # ist dann harmlos. Den .env-Pfad selbst niemals ins Array aufnehmen.
  local_tmp_env="$(mktemp)"
  chmod 600 "$local_tmp_env"                        # I-3: Mode vor dem Befüllen setzen
  _RECONCILE_CLEANUP+=("$local_tmp_env")
  # Schreibe alle Zeilen außer der alten CLOUDFLARE_TUNNEL_ID-Zeile, dann die neue
  grep -v '^CLOUDFLARE_TUNNEL_ID=' "$ENV_FILE" > "$local_tmp_env" || true
  printf 'CLOUDFLARE_TUNNEL_ID=%s\n' "$TUNNEL_ID" >> "$local_tmp_env"
  # Atomisch ersetzen (mv auf demselben Filesystem ist atomar)
  mv "$local_tmp_env" "$ENV_FILE"
  chmod 600 "$ENV_FILE"                             # I-3: Mode nach mv erzwingen
else
  printf 'CLOUDFLARE_TUNNEL_ID=%s\n' "$TUNNEL_ID" >> "$ENV_FILE"
fi

ok "CLOUDFLARE_TUNNEL_ID in .env geschrieben"

# --ensure-tunnel-only: Ausgabe für bootstrap.sh, dann fertig (I-2).
# Diagnose (log/ok/err) geht bereits nach stderr (exec 3>&1 1>&2 am Anfang).
# Die TUNNEL_ID-Zeile geht gezielt nach fd 3 (= ursprünglicher stdout).
if (( ENSURE_ONLY == 1 )); then
  printf 'TUNNEL_ID=%s\n' "$TUNNEL_ID" >&3
  exit 0
fi

TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"

# ============================================================================
# VPS-Scoping: desired_routes = nur Routen, deren Ziel-Container laufen
# ============================================================================
log "VPS-Scoping: laufende Ziel-Container ermitteln"

# Alle Routen aus JSON lesen, pro Route Container prüfen.
# Ergebnis: JSON-Array nur mit den beanspruchten Routen.
DESIRED_ROUTES_JSON="[]"
CLAIMED_COUNT=0
SKIPPED_COUNT=0

while IFS= read -r route_json; do
  service="$(printf '%s' "$route_json" | jq -r '.service')"
  hostname_val="$(printf '%s' "$route_json" | jq -r '.hostname')"
  container_name="$(_service_to_container "$service")"

  running="$(docker inspect --format='{{.State.Running}}' \
    "$container_name" 2>/dev/null || echo "false")"

  if [[ "$running" == "true" ]]; then
    ok "  ${hostname_val} → ${service} (Container '${container_name}' läuft)"
    # Route zu desired_routes hinzufügen (nur hostname + service, ohne _comment etc.)
    route_clean="$(printf '%s' "$route_json" | jq -c '{hostname, service}')"
    DESIRED_ROUTES_JSON="$(printf '%s' "$DESIRED_ROUTES_JSON" \
      | jq -c --argjson r "$route_clean" '. + [$r]')"
    CLAIMED_COUNT=$((CLAIMED_COUNT + 1))
  else
    echo "  Übersprungen: ${hostname_val} (Container '${container_name}' läuft nicht)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
  fi
done < <(jq -c '.routes[]' "$ROUTES_JSON")

log "Beansprucht: ${CLAIMED_COUNT}  Übersprungen: ${SKIPPED_COUNT}"

if (( CLAIMED_COUNT == 0 )); then
  log "Kein einziger Ziel-Container läuft auf diesem VPS — Ingress wird auf catch-all 404 gesetzt, alle eigenen CNAMEs werden abgeräumt."
  # Kein harter Abbruch — legitimer Zustand (z.B. nur Portainer-Hub später)
fi

# ============================================================================
# Step 1: Tunnel-Ingress reconcilen (nur beanspruchte Routen)
# ============================================================================
log "Tunnel-Ingress reconcilen (${CLAIMED_COUNT} Hostnames + catch-all)"

CURRENT_CFG="$(cf_call GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")"
# Reduce auf {hostname, service} damit Extra-Felder (originRequest etc.)
# das Diff nicht stören.
CURRENT_NORM="$(printf '%s' "$CURRENT_CFG" \
  | jq -c '[.result.config.ingress[]? | {hostname, service}]')"
DESIRED_NORM="$(printf '%s' "$DESIRED_ROUTES_JSON" \
  | jq -c '[.[] , {hostname: null, service: "http_status:404"}]')"

if [[ "$CURRENT_NORM" == "$DESIRED_NORM" ]]; then
  ok "Ingress bereits aktuell (${CLAIMED_COUNT} Hostnames + catch-all)"
else
  echo "  Aktuell:"
  printf '%s' "$CURRENT_NORM" | jq -r '.[] | "    \(.hostname // "*") → \(.service)"'
  echo "  Gewollt:"
  printf '%s' "$DESIRED_NORM" | jq -r '.[] | "    \(.hostname // "*") → \(.service)"'
  PUT_BODY="$(jq -nc --argjson ingress "$DESIRED_NORM" '{config: {ingress: $ingress}}')"
  cf_call PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "$PUT_BODY" >/dev/null
  ok "Ingress aktualisiert"
fi

# ============================================================================
# Step 2: DNS-CNAMEs reconcilen (nur beanspruchte Hostnames)
# ============================================================================
log "DNS-CNAMEs reconcilen (${CLAIMED_COUNT} Hostnames → ${TUNNEL_CNAME})"

CREATED=0
UPDATED=0
UNCHANGED=0

while IFS= read -r HOSTNAME; do
  EXISTING="$(cf_call GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}")"
  COUNT="$(printf '%s' "$EXISTING" | jq '.result | length')"

  REC_BODY="$(jq -nc --arg n "$HOSTNAME" --arg c "$TUNNEL_CNAME" \
    '{type: "CNAME", name: $n, content: $c, ttl: 1, proxied: true}')"

  if (( COUNT == 0 )); then
    cf_call POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "$REC_BODY" >/dev/null
    ok "  + $HOSTNAME"
    CREATED=$((CREATED + 1))
  else
    REC_ID="$(printf '%s' "$EXISTING"      | jq -r '.result[0].id')"
    REC_CONTENT="$(printf '%s' "$EXISTING" | jq -r '.result[0].content')"
    REC_PROXIED="$(printf '%s' "$EXISTING" | jq -r '.result[0].proxied')"
    if [[ "$REC_CONTENT" == "$TUNNEL_CNAME" && "$REC_PROXIED" == "true" ]]; then
      UNCHANGED=$((UNCHANGED + 1))
    else
      cf_call PUT "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${REC_ID}" "$REC_BODY" >/dev/null
      ok "  ↻ $HOSTNAME  (war: $REC_CONTENT, proxied=$REC_PROXIED)"
      UPDATED=$((UPDATED + 1))
    fi
  fi
done < <(printf '%s' "$DESIRED_ROUTES_JSON" | jq -r '.[].hostname')

echo
ok "DNS-Records: $CREATED neu · $UPDATED aktualisiert · $UNCHANGED unverändert"

# ============================================================================
# Step 3: Orphan Tunnel-CNAMEs aufräumen
# (CNAMEs die auf den EIGENEN Tunnel zeigen — TUNNEL_CNAME = <eigene-id>.cfargotunnel.com —
# aber nicht mehr in den beanspruchten Hostnames stehen)
# VPS-Sicherheit: Hostnames anderer VPS zeigen auf deren eigene Tunnel-IDs → werden
# von diesem Check nie berührt (anderer CNAME-Content, nicht == $TUNNEL_CNAME).
# DKIM, MX, A, AAAA, andere CNAMEs bleiben unangetastet.
# ============================================================================
log "Orphan Tunnel-CNAMEs aufräumen (gescoped auf ${TUNNEL_CNAME})"

# I-4: per_page=100 ist das API-Maximum. Bei mehr als 100 CNAME-Records würden
# Orphans stillschweigend übersehen (false safety). Wir prüfen result_info und
# brechen hart ab, statt leise unvollständige Daten zu verarbeiten.
# Robuste Strategie: Trunkierung → err (klar abbrechen). Skalierungspfad wäre
# Paginierung, aber >100 CNAMEs ist für diese Stack-Größe unrealistisch und ein
# hartes Abbrechen ist sicherer als stille Fehlertoleranz.
ALL_CNAMES="$(cf_call GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=CNAME&per_page=100")"
_total="$(printf '%s' "$ALL_CNAMES" | jq '.result_info.total_count // 0')"
_count="$(printf '%s' "$ALL_CNAMES" | jq '.result_info.count // 0')"
if (( _total > _count )); then
  err "Orphan-Cleanup: API lieferte nur ${_count} von ${_total} CNAME-Records (Trunkierung). \
Abbruch, um stille Fehlklassifizierung von Orphans zu verhindern. \
Bitte CNAME-Records aufräumen und erneut laufen lassen."
fi
DESIRED_HOSTS="$(printf '%s' "$DESIRED_ROUTES_JSON" | jq -r '.[].hostname' | sort -u)"

DELETED=0
while IFS=$'\t' read -r REC_ID REC_NAME REC_CONTENT; do
  # Nur CNAMEs die EXAKT auf unseren Tunnel zeigen → andere bleiben in Ruhe
  [[ "$REC_CONTENT" == "$TUNNEL_CNAME" ]] || continue
  # In beanspruchten Hostnames enthalten? → behalten
  if printf '%s' "$DESIRED_HOSTS" | grep -Fxq -- "$REC_NAME"; then
    continue
  fi
  cf_call DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${REC_ID}" >/dev/null
  ok "  - $REC_NAME  (zeigte auf $TUNNEL_CNAME)"
  DELETED=$((DELETED + 1))
done < <(printf '%s' "$ALL_CNAMES" | jq -r '.result[] | "\(.id)\t\(.name)\t\(.content)"')

if (( DELETED == 0 )); then
  ok "Keine orphan Tunnel-CNAMEs gefunden"
else
  ok "$DELETED orphan CNAME(s) gelöscht"
fi

log "✓ Cloudflare reconcile abgeschlossen"
