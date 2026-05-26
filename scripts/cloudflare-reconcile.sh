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

# S-2 FIX: _cf_get_clean — wie _cf_get, aber strippt zusätzlich:
#   - Trailing Whitespace (Leerzeichen / Tabs am Zeilenende)
#   - Inline-Kommentare (erstes ' #' oder Tab+'#' bis Zeilenende)
# Wird für alle Mail-Vars verwendet, da diese direkt in DNS-Record-Werte
# (z.B. rua=mailto:${POSTE_ADMIN_EMAIL}) eingebettet werden.
_cf_get_clean() {
  local val
  val="$(_cf_get "$1")"
  # Inline-Kommentar entfernen: alles ab ' #' oder '\t#'
  val="${val%%[[:space:]]#*}"
  # Trailing Whitespace (Leerzeichen/Tabs) abschneiden
  val="${val%"${val##*[! 	]}"}"
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
#
# Zusaetzliches Gate fuer Portainer-Hub-Routen (_portainer_hub: true):
#   Diese Routen werden NUR beansprucht wenn PORTAINER_ROLE=hub in .env steht.
#   Hintergrund: portainer. + edge. sollen exklusiv vom Hub-VPS veroeffentlicht
#   werden. Der Container-laufend-Check wuerde Spoke-VPS korrekt ausfiltern (Agent
#   startet "portainer"-Container nicht), aber als zweite Sicherung verhindert das
#   Gate zusaetzlich DNS/Ingress-Eintraege auf Spoke-VPS die den Agent noch nicht
#   gestartet haben — und schuetzt vor Split-Brain wenn portainer kurz gestartet
#   aber noch nicht konfiguriert ist.
#   Implementierungswahl: Option (b) aus §7 BOOTSTRAP_MENU_V2_KONZEPT.md.
# ============================================================================
log "VPS-Scoping: laufende Ziel-Container ermitteln"

# PORTAINER_ROLE aus .env lesen (nur den Wert, kein set -a/source)
IS_PORTAINER_HUB=0
_portainer_role_val="$(_cf_get PORTAINER_ROLE)"
if [[ "${_portainer_role_val:-auto}" == "hub" ]]; then
  IS_PORTAINER_HUB=1
  ok "PORTAINER_ROLE=hub — Portainer-Hub-Routen werden beansprucht"
else
  echo "  PORTAINER_ROLE=${_portainer_role_val:-auto} (nicht hub) — Portainer-Hub-Routen werden uebersprungen"
fi

# ---- Frühzeitiger Access-Capability-Check (FAIL-SAFE) ----
# Wird NUR auf Hub-VPS ausgeführt. Prüft, ob der API-Token den Scope
# "Access: Apps and Policies: Edit" hat UND Zero Trust auf diesem Account
# eingerichtet ist. Schlägt der Check fehl, werden alle _portainer_hub-Routen
# (portainer.* und edge.*) NICHT in DESIRED_ROUTES_JSON aufgenommen →
# kein DNS-CNAME, kein Tunnel-Ingress → Portainer bleibt ausschliesslich lokal
# erreichbar (SSH-Tunnel: ssh -L 9000:localhost:9000 user@vps).
#
# WICHTIG: Kein cf_call() — cf_call() ruft err()→exit bei HTTP-Fehler.
# Stattdessen: eigener toleranter curl; Exit-Code + HTTP-Code werden getrennt
# ausgewertet (Lesson: nie curl -w '%{http_code}' mit || echo 'X' kombinieren).
ACCESS_CAPABLE=0
if (( IS_PORTAINER_HUB == 1 )); then
  log "Access-Capability-Check (frühzeitig, Fail-Safe)"
  _acc_http_code=""
  _acc_body=""
  _acc_raw=""
  _acc_curl_exit=0
  _acc_raw="$(curl -sS -w '\n%{http_code}' \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" 2>/dev/null)" \
    || _acc_curl_exit=$?
  _acc_http_code="${_acc_raw##*$'\n'}"
  _acc_body="${_acc_raw%$'\n'*}"

  # Auswertung: HTTP 2xx + success=true → capable
  if (( _acc_curl_exit == 0 )) \
     && [[ "$_acc_http_code" =~ ^2 ]] \
     && [[ "$(printf '%s' "$_acc_body" | jq -r '.success // false')" == "true" ]]; then
    ACCESS_CAPABLE=1
    ok "Access-Capability: Token + Zero Trust OK — Portainer-Routen werden exponiert"
  else
    # Nicht-fatal: gelber Hinweis, kein exit 1.
    printf '\n\033[1;33m' >&2
    printf '╔══════════════════════════════════════════════════════════════════════════╗\n' >&2
    printf '║  HINWEIS: Cloudflare Access nicht einrichtbar (Token-Scope fehlt        ║\n' >&2
    printf '║  oder Zero Trust Team-Domain nicht konfiguriert).                       ║\n' >&2
    printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
    printf '║  Portainer wird NICHT oeffentlich exponiert (Fail-Safe).                ║\n' >&2
    printf '║  portainer.alexstuder.cloud + edge.alexstuder.cloud werden NICHT        ║\n' >&2
    printf '║  in DNS/Tunnel aufgenommen — Portainer nur lokal erreichbar:            ║\n' >&2
    printf '║    ssh -L 9000:localhost:9000 user@vps                                  ║\n' >&2
    printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
    printf '║  HTTP-Code: %-59s ║\n' "${_acc_http_code:-keine Antwort (curl exit ${_acc_curl_exit})}" >&2
    printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
    printf '║  Schritte zur Behebung:                                                 ║\n' >&2
    printf '║  1. Cloudflare Dashboard → Zero Trust → Settings → Team-Domain          ║\n' >&2
    printf '║     sicherstellen (einmalig, wenn noch nicht aktiviert).                ║\n' >&2
    printf '║  2. API-Token (CLOUDFLARE_API_TOKEN in .env) mit Scope:                 ║\n' >&2
    printf '║       Account › Access: Apps and Policies › Edit                        ║\n' >&2
    printf '║     erstellen oder erweitern.                                           ║\n' >&2
    printf '║  3. ./scripts/cloudflare-reconcile.sh erneut ausfuehren.               ║\n' >&2
    printf '╚══════════════════════════════════════════════════════════════════════════╝\n' >&2
    printf '\033[0m\n' >&2
    ok "Reconcile laeuft weiter (Tunnel + App-DNS + Mail bleiben unveraendert)"
  fi
fi

# Alle Routen aus JSON lesen, pro Route Container prüfen.
# Ergebnis: JSON-Array nur mit den beanspruchten Routen.
DESIRED_ROUTES_JSON="[]"
CLAIMED_COUNT=0
SKIPPED_COUNT=0

while IFS= read -r route_json; do
  service="$(printf '%s' "$route_json" | jq -r '.service')"
  hostname_val="$(printf '%s' "$route_json" | jq -r '.hostname')"
  container_name="$(_service_to_container "$service")"

  # Portainer-Hub-Gate: _portainer_hub:true-Routen nur auf Hub-VPS beanspruchen
  # UND nur wenn Access einrichtbar (ACCESS_CAPABLE=1).
  # Zweistufig:
  #   a) nicht Hub-VPS → überspringen (wie bisher)
  #   b) Hub-VPS, aber ACCESS_CAPABLE=0 → überspringen (FAIL-SAFE: nie exponieren
  #      ohne Access-Schutz). Portainer bleibt nur lokal erreichbar.
  is_hub_route="$(printf '%s' "$route_json" | jq -r '._portainer_hub // false')"
  if [[ "$is_hub_route" == "true" ]]; then
    if (( IS_PORTAINER_HUB == 0 )); then
      echo "  Uebersprungen (nicht Hub-VPS): ${hostname_val}"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    if (( ACCESS_CAPABLE == 0 )); then
      echo "  Uebersprungen (Access nicht einrichtbar — Fail-Safe): ${hostname_val}"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
  fi

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


# ============================================================================
# Step 4: Cloudflare Access — portainer.alexstuder.cloud (nur Hub-VPS)
#
# Legt eine self-hosted Access-Application für portainer.alexstuder.cloud an
# und sichert sie mit einer Allow-Policy (E-Mail via PORTAINER_ACCESS_EMAIL,
# Default: alex@alexstuder.ch).
#
# Warum NUR Hub-VPS: edge.alexstuder.cloud muss öffentlich bleiben (Edge-Agents
# pollen ausgehend über diesen Endpoint). Wenn IS_PORTAINER_HUB=0, wird dieser
# Block vollständig übersprungen.
#
# Idempotenz:
#   App:    GET /accounts/{id}/access/apps → nach domain==portainer.alexstuder.cloud
#           filtern → falls vorhanden: ID übernehmen, sonst POST anlegen.
#   Policy: GET /accounts/{id}/access/apps/{app_id}/policies → nach name=="Allow
#           Portainer Admin" filtern → falls vorhanden: übernehmen (kein Re-POST),
#           sonst POST anlegen.
#
# Policy-Weg: inline unter /accounts/{id}/access/apps/{app_id}/policies.
#   Warum nicht reusable (/accounts/{id}/access/policies + link)?
#   Reusable-Policies brauchen einen zweistufigen Workflow (POST Policy, dann PUT
#   link auf die App). Für eine einzelne App, die nur eine Policy braucht, ist der
#   inline-Weg direkter, hat weniger API-Aufrufe und ist im CF-Dashboard auch als
#   "App policy" sichtbar — keine Nachteile.
#
# Fehlerverhalten:
#   - Kein Access-Scope / kein Zero Trust → wird bereits im frühen
#     Access-Capability-Check (ACCESS_CAPABLE=0) abgefangen; Step 4 wird dann
#     NICHT ausgeführt und Portainer wird NICHT exponiert (Fail-Safe).
#   - ACCESS_CAPABLE=1 aber ein späterer API-Call schlägt mid-run fehl
#     (z.B. Race-Condition, temporärer CF-Fehler): LAUTER Warn-Block + Exit 1.
#     In diesem Fall haben wir exponiert (DNS+Ingress gesetzt) und der Schutz
#     fehlt → harter Abbruch ist gerechtfertigt.
# ============================================================================

# Flag: wurde die Access-Einrichtung übersprungen oder hat sie versagt?
# 0 = OK / nicht Hub  1 = fehlgeschlagen
_ACCESS_SETUP_FAILED=0

if (( IS_PORTAINER_HUB == 1 )) && (( ACCESS_CAPABLE == 1 )); then
  log "Cloudflare Access — portainer.alexstuder.cloud absichern (Hub-VPS)"

  # PORTAINER_ACCESS_EMAIL aus .env lesen; Default: alex@alexstuder.ch
  _portainer_access_email="$(_cf_get PORTAINER_ACCESS_EMAIL)"
  _portainer_access_email="${_portainer_access_email:-alex@alexstuder.ch}"
  ok "Access-Policy E-Mail: ${_portainer_access_email}"

  _portainer_domain="portainer.alexstuder.cloud"
  _access_app_id=""

  # ---- 4a: Access-App suchen oder anlegen ----
  # cf_call() ruft err() bei HTTP-Fehler und verlässt die Subshell mit Exit 1.
  # err() schreibt nach stderr — ohne 2>&1 bleibt das für den Operator sichtbar.
  # Wir fangen nur den Exit-Code via 'if !', der API-Fehlertext erscheint direkt
  # auf dem Terminal, bevor unser Warn-Block kommt.
  # WICHTIG: kein 'local _access_apps_raw; _access_apps_raw=$(...)' in einem Schritt
  # (export VAR=$(cmd)-Äquivalent). Zweizeilig: erst zuweisen, dann prüfen.
  _access_apps_raw=""
  if ! _access_apps_raw="$(cf_call GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps")"; then
    # Dieser Pfad ist nach dem frühzeitigen ACCESS_CAPABLE-Check nur noch durch
    # eine Race-Condition / transienten CF-Fehler erreichbar. DNS + Ingress wurden
    # bereits gesetzt (ACCESS_CAPABLE=1 hat den Tunnel-Expose erlaubt).
    printf '\n\033[1;31m' >&2
    printf '╔══════════════════════════════════════════════════════════════════════════╗\n' >&2
    printf '║  SICHERHEITS-WARNUNG: Cloudflare Access konnte NICHT eingerichtet werden ║\n' >&2
    printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
    printf '║  portainer.alexstuder.cloud ist OEFFENTLICH ERREICHBAR (DNS+Ingress     ║\n' >&2
    printf '║  wurden gesetzt), aber Access-Schutz konnte nicht angelegt werden.      ║\n' >&2
    printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
    printf '║  Ursache: GET /access/apps fehlgeschlagen (transienter CF-Fehler?).     ║\n' >&2
    printf '║  Massnahme: ./scripts/cloudflare-reconcile.sh erneut ausfuehren.        ║\n' >&2
    printf '║  Portainer bis dahin NICHT oeffentlich nutzen!                          ║\n' >&2
    printf '╚══════════════════════════════════════════════════════════════════════════╝\n' >&2
    printf '\033[0m\n' >&2
    _ACCESS_SETUP_FAILED=1
  else
    # Exakter Domain-Match (Groß-/Kleinschreibung egal: domain kommt lowercase aus der API)
    _access_app_id="$(printf '%s' "$_access_apps_raw" \
      | jq -r --arg d "$_portainer_domain" \
          '.result[] | select(.domain == $d) | .id' \
      | head -1)"

    if [[ -n "$_access_app_id" && "$_access_app_id" != "null" ]]; then
      ok "Access-App '${_portainer_domain}' existiert bereits (ID: ${_access_app_id})"
    else
      log "Access-App '${_portainer_domain}' nicht gefunden — lege an"
      _app_body="$(jq -nc \
        --arg name "Portainer" \
        --arg domain "$_portainer_domain" \
        '{
          type:             "self_hosted",
          name:             $name,
          domain:           $domain,
          session_duration: "24h"
        }')"

      _app_create_raw=""
      if ! _app_create_raw="$(cf_call POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" "$_app_body")"; then
        printf '\n\033[1;31m' >&2
        printf '╔══════════════════════════════════════════════════════════════════════════╗\n' >&2
        printf '║  SICHERHEITS-WARNUNG: Access-App anlegen fehlgeschlagen                 ║\n' >&2
        printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
        printf '║  portainer.alexstuder.cloud ist UNGESCHUETZT OEFFENTLICH ERREICHBAR.    ║\n' >&2
        printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
        printf '║  Fehler-Details: POST /access/apps fehlgeschlagen (siehe oben).         ║\n' >&2
        printf '║  Scope pruefen: Account › Access: Apps and Policies › Edit              ║\n' >&2
        printf '║  Zero Trust Team-Domain konfiguriert? (CF Dashboard → Zero Trust)       ║\n' >&2
        printf '║  Danach: ./scripts/cloudflare-reconcile.sh erneut ausfuehren.           ║\n' >&2
        printf '╚══════════════════════════════════════════════════════════════════════════╝\n' >&2
        printf '\033[0m\n' >&2
        _ACCESS_SETUP_FAILED=1
      else
        _access_app_id="$(printf '%s' "$_app_create_raw" | jq -r '.result.id')"
        [[ -n "$_access_app_id" && "$_access_app_id" != "null" ]] \
          || { printf '\033[1;31m✖ Access-App-Create lieferte keine ID\033[0m\n' >&2; _ACCESS_SETUP_FAILED=1; }
        if (( _ACCESS_SETUP_FAILED == 0 )); then
          ok "Access-App '${_portainer_domain}' angelegt (ID: ${_access_app_id})"
        fi
      fi
    fi

    # ---- 4b: Policy sicherstellen (nur wenn App-ID bekannt + kein Fehler) ----
    if (( _ACCESS_SETUP_FAILED == 0 )) && [[ -n "$_access_app_id" ]]; then
      _policy_name="Allow Portainer Admin"
      _policies_raw=""
      if ! _policies_raw="$(cf_call GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${_access_app_id}/policies")"; then
        printf '\n\033[1;31m' >&2
        printf '╔══════════════════════════════════════════════════════════════════════════╗\n' >&2
        printf '║  SICHERHEITS-WARNUNG: Access-Policies konnten nicht abgerufen werden    ║\n' >&2
        printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
        printf '║  portainer.alexstuder.cloud koennte UNGESCHUETZT sein.                  ║\n' >&2
        printf '║  Fehler: GET /access/apps/{id}/policies fehlgeschlagen.                 ║\n' >&2
        printf '║  Danach: ./scripts/cloudflare-reconcile.sh erneut ausfuehren.           ║\n' >&2
        printf '╚══════════════════════════════════════════════════════════════════════════╝\n' >&2
        printf '\033[0m\n' >&2
        _ACCESS_SETUP_FAILED=1
      else
        # Suche nach existierender Policy mit demselben Namen (idempotent: nicht duplizieren)
        _existing_policy_id="$(printf '%s' "$_policies_raw" \
          | jq -r --arg n "$_policy_name" \
              '.result[] | select(.name == $n) | .id' \
          | head -1)"

        if [[ -n "$_existing_policy_id" && "$_existing_policy_id" != "null" ]]; then
          ok "Access-Policy '${_policy_name}' existiert bereits (ID: ${_existing_policy_id})"
        else
          log "Access-Policy '${_policy_name}' anlegen (Allow: ${_portainer_access_email})"
          # decision=allow, include=[{email: {email: "<addr>"}}]
          # OTP (One-Time-PIN) ist der Default-IdP wenn kein externer IdP konfiguriert ist —
          # kein explizites idp-Feld nötig, Cloudflare nutzt automatisch OTP.
          _policy_body="$(jq -nc \
            --arg name  "$_policy_name" \
            --arg email "$_portainer_access_email" \
            '{
              name:     $name,
              decision: "allow",
              include:  [{ email: { email: $email } }]
            }')"

          _policy_create_raw=""
          if ! _policy_create_raw="$(cf_call POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${_access_app_id}/policies" "$_policy_body")"; then
            printf '\n\033[1;31m' >&2
            printf '╔══════════════════════════════════════════════════════════════════════════╗\n' >&2
            printf '║  SICHERHEITS-WARNUNG: Access-Policy anlegen fehlgeschlagen               ║\n' >&2
            printf '╠══════════════════════════════════════════════════════════════════════════╣\n' >&2
            printf '║  portainer.alexstuder.cloud hat KEINE Allow-Policy.                     ║\n' >&2
            printf '║  Die Access-App existiert, aber ohne Policy blockiert CF jeden Zugang.  ║\n' >&2
            printf '║  Fehler: POST /access/apps/{id}/policies fehlgeschlagen (siehe oben).   ║\n' >&2
            printf '║  Danach: ./scripts/cloudflare-reconcile.sh erneut ausfuehren.           ║\n' >&2
            printf '╚══════════════════════════════════════════════════════════════════════════╝\n' >&2
            printf '\033[0m\n' >&2
            _ACCESS_SETUP_FAILED=1
          else
            _new_policy_id="$(printf '%s' "$_policy_create_raw" | jq -r '.result.id')"
            if [[ -z "$_new_policy_id" || "$_new_policy_id" == "null" ]]; then
              printf '\n\033[1;31m  ✖ Access-Policy POST lieferte keine ID — Schutz unklar, UI evtl. ungeschuetzt.\033[0m\n' >&2
              _ACCESS_SETUP_FAILED=1
            else
              ok "Access-Policy '${_policy_name}' angelegt (ID: ${_new_policy_id}, E-Mail: ${_portainer_access_email})"
            fi
          fi
        fi
      fi
    fi
  fi
fi

# ============================================================================
# Step 5: Mail-DNS reconcilen (MX / A-unproxied / SPF / DMARC / DKIM)
#
# Mail ist die bewusste Ausnahme zum Tunnel-Only-Prinzip (Freigabe 2026-05-25).
# Diese Sektion wird NUR ausgeführt wenn /etc/brewing/stateful-units.d/mail
# existiert (Marker) ODER der posteio-Container läuft.
# Die bestehende CNAME/Tunnel/Orphan-Logik (Steps 0–4) bleibt UNVERÄNDERT.
#
# Kein Orphan-Cleanup für MX/A/TXT — Mail-Records bleiben additiv/idempotent-
# update. (Der Orphan-Cleanup in Step 3 löscht nur CNAMEs auf den eigenen Tunnel
# und tastet MX/A/TXT per Design nicht an.)
# ============================================================================

# Marker/Container-Gate: Mail-Sektion aktiv?
_MAIL_ACTIVE=0
MAIL_MARKER="/etc/brewing/stateful-units.d/mail"
if [[ -f "$MAIL_MARKER" ]]; then
  _MAIL_ACTIVE=1
  ok "mail-Marker vorhanden (${MAIL_MARKER}) — Mail-DNS-Sektion aktiv"
elif docker inspect --format='{{.State.Running}}' posteio 2>/dev/null | grep -q '^true$'; then
  _MAIL_ACTIVE=1
  ok "posteio-Container läuft — Mail-DNS-Sektion aktiv (kein Marker, aber Container läuft)"
else
  echo "  Mail-Marker nicht vorhanden (${MAIL_MARKER}) und posteio läuft nicht — Mail-DNS übersprungen"
fi

if (( _MAIL_ACTIVE == 1 )); then
  log "Mail-DNS reconcilen (MX / A-unproxied / SPF / DMARC / DKIM)"

  # ---- Mail-Variablen aus .env lesen (kein source, nur gezielte Werte) ----
  # _cf_get_clean: strippt Trailing-Whitespace + Inline-Kommentare (S-2 FIX).
  MAIL_DOMAIN="$(_cf_get_clean MAIL_DOMAIN)"
  MAIL_HOSTNAME="$(_cf_get_clean MAIL_HOSTNAME)"
  POSTE_ADMIN_EMAIL="$(_cf_get_clean POSTE_ADMIN_EMAIL)"
  MAIL_VPS_IP="$(_cf_get_clean MAIL_VPS_IP)"
  MAIL_SPF_INCLUDE="$(_cf_get_clean MAIL_SPF_INCLUDE)"
  MAIL_DKIM_TXT="$(_cf_get_clean MAIL_DKIM_TXT)"

  # Default-Werte (analog .env.example)
  MAIL_DOMAIN="${MAIL_DOMAIN:-alexstuder.cloud}"
  MAIL_HOSTNAME="${MAIL_HOSTNAME:-mail.${MAIL_DOMAIN}}"
  POSTE_ADMIN_EMAIL="${POSTE_ADMIN_EMAIL:-admin@${MAIL_DOMAIN}}"

  # Validierung: MAIL_DOMAIN darf keine Shell-Injection-Zeichen enthalten.
  [[ "$MAIL_DOMAIN" =~ ^[a-zA-Z0-9._-]+$ ]] \
    || { echo "  MAIL_DOMAIN '${MAIL_DOMAIN}' enthält ungültige Zeichen — Mail-DNS übersprungen"; _MAIL_ACTIVE=0; }
fi

if (( _MAIL_ACTIVE == 1 )); then

  # ---- VPS-IP ermitteln (auto oder .env-Override) ----
  if [[ -n "$MAIL_VPS_IP" ]]; then
    ok "Mail-VPS-IP aus .env (MAIL_VPS_IP): ${MAIL_VPS_IP}"
  else
    # Automatische Ermittlung über ifconfig.co (robuster öffentlicher IP-Service).
    # Timeout 10s; bei Fehler → Abbruch mit klarem Hinweis (kein stilles Weglassen).
    MAIL_VPS_IP="$(curl -sS --max-time 10 https://ifconfig.co 2>/dev/null || true)"
    MAIL_VPS_IP="${MAIL_VPS_IP//[[:space:]]/}"  # trailing newline entfernen
    if [[ -z "$MAIL_VPS_IP" ]]; then
      printf '  \033[1;33m⚠ VPS-IP konnte nicht automatisch ermittelt werden (ifconfig.co nicht erreichbar).\033[0m\n'
      printf '  Mail-DNS (A-Record) wird übersprungen. MAIL_VPS_IP in .env setzen, dann erneut laufen.\n'
      MAIL_VPS_IP=""
    else
      # Sanity-Check: IPv4-Format
      if [[ ! "$MAIL_VPS_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        printf '  \033[1;33m⚠ Ermittelte IP "%s" sieht nicht nach IPv4 aus — A-Record übersprungen.\033[0m\n' \
          "$MAIL_VPS_IP"
        printf '  MAIL_VPS_IP in .env manuell setzen.\n'
        MAIL_VPS_IP=""
      else
        ok "Mail-VPS-IP auto-ermittelt: ${MAIL_VPS_IP}"
      fi
    fi
  fi

  # ---- Hilfsfunktion: DNS-Record idempotent anlegen/aktualisieren ----
  # cf_dns_ensure <type> <name> <content> <proxied> [priority]
  # Gibt bei Fehler eine Warnung aus, bricht aber den Mail-Block NICHT ab
  # (damit ein DKIM-Fehler nicht MX/A/SPF/DMARC blockiert).
  _mail_dns_ensure() {
    local rtype="$1" rname="$2" rcontent="$3" rproxied="$4" rpriority="${5:-}"

    local body_fields
    body_fields="$(jq -nc \
      --arg t  "$rtype" \
      --arg n  "$rname" \
      --arg c  "$rcontent" \
      --argjson p "$rproxied" \
      '{type: $t, name: $n, content: $c, ttl: 1, proxied: $p}')"

    # MX braucht priority
    if [[ -n "$rpriority" ]]; then
      body_fields="$(printf '%s' "$body_fields" \
        | jq -c --argjson prio "$rpriority" '. + {priority: $prio}')"
    fi

    # Bestehende Records suchen
    local existing count
    existing="$(cf_call GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=${rtype}&name=${rname}")" \
      || { printf '  \033[1;33m⚠ GET %s/%s fehlgeschlagen — übersprungen\033[0m\n' "$rtype" "$rname"; return 0; }
    count="$(printf '%s' "$existing" | jq '.result | length')"

    if (( count == 0 )); then
      cf_call POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "$body_fields" >/dev/null \
        || { printf '  \033[1;33m⚠ POST %s/%s fehlgeschlagen — übersprungen\033[0m\n' "$rtype" "$rname"; return 0; }
      ok "  + [${rtype}] ${rname}"
    else
      local rec_id rec_content rec_proxied rec_priority
      rec_id="$(printf '%s' "$existing" | jq -r '.result[0].id')"
      rec_content="$(printf '%s' "$existing" | jq -r '.result[0].content')"
      rec_proxied="$(printf '%s' "$existing" | jq -r '.result[0].proxied // false')"
      rec_priority="$(printf '%s' "$existing" | jq -r '.result[0].priority // ""')"

      # Änderung nötig?
      local needs_update=0
      [[ "$rec_content" != "$rcontent" ]]    && needs_update=1
      [[ "$rec_proxied" != "$rproxied" ]]    && needs_update=1
      [[ -n "$rpriority" && "$rec_priority" != "$rpriority" ]] && needs_update=1

      if (( needs_update == 0 )); then
        echo "  = [${rtype}] ${rname} (unverändert)"
      else
        cf_call PUT "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${rec_id}" "$body_fields" >/dev/null \
          || { printf '  \033[1;33m⚠ PUT %s/%s fehlgeschlagen — übersprungen\033[0m\n' "$rtype" "$rname"; return 0; }
        ok "  ↻ [${rtype}] ${rname}  (war: ${rec_content}, proxied=${rec_proxied})"
      fi
    fi
  }

  # ---- A-Record: mail.${MAIL_DOMAIN} → VPS-IP, unproxied ----
  if [[ -n "$MAIL_VPS_IP" ]]; then
    log "Mail A-Record: ${MAIL_HOSTNAME} → ${MAIL_VPS_IP} (proxied=false)"
    _mail_dns_ensure "A" "$MAIL_HOSTNAME" "$MAIL_VPS_IP" "false"
  fi

  # ---- MX-Record: ${MAIL_DOMAIN} → mail.${MAIL_DOMAIN}, Prio 10 ----
  log "Mail MX-Record: ${MAIL_DOMAIN} → ${MAIL_HOSTNAME} (prio 10)"
  _mail_dns_ensure "MX" "$MAIL_DOMAIN" "$MAIL_HOSTNAME" "false" "10"

  # ---- TXT SPF: ${MAIL_DOMAIN} → v=spf1 mx [include:...] ~all ----
  # (Script-Level — kein 'local' hier, kein Scope-Problem im Top-Level-Context)
  _mail_spf_val=""
  if [[ -n "$MAIL_SPF_INCLUDE" ]]; then
    _mail_spf_val="v=spf1 mx include:${MAIL_SPF_INCLUDE} ~all"
  else
    _mail_spf_val="v=spf1 mx ~all"
  fi
  log "Mail SPF-Record: ${MAIL_DOMAIN} TXT \"${_mail_spf_val}\""
  # SPF ist ein TXT-Record. Sonderlage: es kann bereits ein TXT mit anderem Inhalt
  # existieren (z.B. Domain-Verifikation). _mail_dns_ensure GET filtert auf type=TXT,
  # aber NICHT auf SPF-spezifischen Inhalt → bei Konflikt wird der erste Record
  # aktualisiert. Das ist konsistent mit dem idempotenten Ansatz.
  _mail_dns_ensure "TXT" "$MAIL_DOMAIN" "$_mail_spf_val" "false"

  # ---- TXT DMARC: _dmarc.${MAIL_DOMAIN} ----
  _mail_dmarc_val="v=DMARC1; p=none; rua=mailto:${POSTE_ADMIN_EMAIL}"
  log "Mail DMARC-Record: _dmarc.${MAIL_DOMAIN} TXT \"${_mail_dmarc_val}\""
  _mail_dns_ensure "TXT" "_dmarc.${MAIL_DOMAIN}" "$_mail_dmarc_val" "false"

  # ---- DKIM (nie hard-failend) ----
  # Zwei Mechanismen (beide optional, Fehler → nur Log-Hinweis):
  #
  # 1. MAIL_DKIM_TXT aus .env (Poste.io-Eigen-Key oder manuell eingetragen):
  #    → publiziert als TXT dkim._domainkey.${MAIL_DOMAIN}
  # 2. Poste.io-Eigen-Key aus Container auslesen (nice-to-have, defensiv):
  #    → docker exec posteio cat /data/ssl/dkim/<domain>/dkim.pub (Pfad für poste.io 2.x)
  #    → Falls leer/Fehler: kein Abbruch, nur Hinweis.
  #
  # Relay-DKIM (Brevo/SES) wird vom Relay-Anbieter selbst signiert; die zugehörigen
  # CNAME/TXT-Records werden beim Brevo-Domain-Setup manuell eingetragen
  # (CREDENTIAL-SCHRITT — Werte kennt nur der Anbieter).

  log "DKIM (defensiv, nie abortend)"

  _mail_dkim_val=""
  _mail_dkim_source=""

  # Quelle 1: MAIL_DKIM_TXT aus .env
  if [[ -n "$MAIL_DKIM_TXT" ]]; then
    _mail_dkim_val="$MAIL_DKIM_TXT"
    _mail_dkim_source=".env (MAIL_DKIM_TXT)"
  fi

  # Quelle 2: Poste.io-Eigen-Key aus Container (nur wenn Quelle 1 leer)
  # Poste.io 2.x speichert den DKIM-Key unter /data/ssl/dkim/<domain>/dkim.pub
  # als PEM-formatierter öffentlicher RSA-Key.
  if [[ -z "$_mail_dkim_val" ]]; then
    _mail_dkim_raw=""
    if docker inspect --format='{{.State.Running}}' posteio 2>/dev/null | grep -q '^true$'; then
      # Versuche den Key auszulesen (Pfad für poste.io 2.x).
      # Fehler (Container existiert, Datei fehlt noch) → leerer String, kein Abbruch.
      _mail_dkim_raw="$(docker exec posteio \
        cat "/data/ssl/dkim/${MAIL_DOMAIN}/dkim.pub" 2>/dev/null || true)"
      if [[ -n "$_mail_dkim_raw" ]]; then
        # PEM-Header/Footer und Newlines entfernen → base64-Blob für den TXT-Record.
        _mail_dkim_b64="$(printf '%s' "$_mail_dkim_raw" \
          | grep -v '^-----' \
          | tr -d '\n[:space:]')"
        if [[ -n "$_mail_dkim_b64" ]]; then
          _mail_dkim_val="v=DKIM1; k=rsa; p=${_mail_dkim_b64}"
          _mail_dkim_source="Container (posteio /data/ssl/dkim/${MAIL_DOMAIN}/dkim.pub)"
        fi
      fi
    fi
  fi

  if [[ -n "$_mail_dkim_val" ]]; then
    ok "DKIM-Key ermittelt (Quelle: ${_mail_dkim_source})"
    log "DKIM-Record: dkim._domainkey.${MAIL_DOMAIN} TXT"
    # DKIM-Record darf den restlichen Reconcile NIE abbrechen.
    _mail_dns_ensure "TXT" "dkim._domainkey.${MAIL_DOMAIN}" "$_mail_dkim_val" "false" || true
  else
    printf '  \033[1;33m⚠ DKIM-Key nicht verfügbar (MAIL_DKIM_TXT in .env leer,\033[0m\n'
    printf '  \033[1;33m  Poste.io-Key noch nicht generiert oder Pfad abweichend).\033[0m\n'
    printf '  DKIM-Record wird NICHT angelegt — kein Abbruch.\n'
    printf '  Optionen:\n'
    printf '    a) Relay-DKIM (Brevo): DKIM-CNAMEs beim Brevo-Domain-Setup einrichten\n'
    printf '       (CREDENTIAL-SCHRITT — Werte vom Anbieter vorgegeben).\n'
    printf '    b) Poste.io-Eigen-DKIM: nach erstem posteio-Start den Key in .env setzen:\n'
    printf '       MAIL_DKIM_TXT=<v=DKIM1; k=rsa; p=<base64>>  dann encrypt-env.sh\n'
    printf '       Alternativ: einmalig im Cloudflare-Dashboard eintragen.\n'
  fi

  ok "Mail-DNS reconcile abgeschlossen (${MAIL_DOMAIN})"
fi

# ============================================================================
# Abschluss
# ============================================================================
if (( _ACCESS_SETUP_FAILED == 1 )); then
  # Dieser Pfad wird nur noch erreicht wenn ACCESS_CAPABLE=1 war (frühzeitiger Check
  # hat bestanden), aber ein nachfolgender API-Call mid-run fehlgeschlagen ist.
  # Portainer ist bereits exponiert (DNS+Ingress gesetzt) OHNE vollständigen Schutz.
  printf '\n\033[1;31m' >&2
  printf '╔══════════════════════════════════════════════════════════════════════════╗\n' >&2
  printf '║  RECONCILE ABGESCHLOSSEN — ABER: Access-Einrichtung fehlgeschlagen!     ║\n' >&2
  printf '║  Tunnel + DNS wurden gesetzt; Portainer-Access-Schutz FEHLT.            ║\n' >&2
  printf '║  Sofort handeln — portainer.alexstuder.cloud ist ungeschuetzt!          ║\n' >&2
  printf '║  Reconcile erneut ausfuehren um Access-App/Policy anzulegen.            ║\n' >&2
  printf '╚══════════════════════════════════════════════════════════════════════════╝\n' >&2
  printf '\033[0m\n' >&2
  exit 1
fi

log "✓ Cloudflare reconcile abgeschlossen"
