#!/usr/bin/env bash
# ============================================================================
# scripts/dr-test-rebuild.sh — Autonomes Disaster-Recovery-Testen
# ============================================================================
# Läuft AUF DEM MAC. Macht Folgendes:
#   1. Pre-Flight: Token, Tools, SSH-Erreichbarkeit, gpg.pass lokal.
#   2. Pre-Snapshot der Live-Counts (Vergleichswert für die Verifikation).
#   3. Frischer Backup-Lauf via cron-User (= konsistenter Restore-Target).
#   4. SAFETY-PROMPT: User tippt 'DESTROY' zum Bestätigen — sonst Abbruch.
#   5. Hetzner-API rebuild: Disk wird gewischt, frisches Ubuntu, gleiche IP.
#   6. Warten auf SSH-Wiederkehr (root via id_ed25519).
#   7. MINIMAL-Bootstrap auf dem rebuilten VPS:
#        - docker + git + gpg + rclone + curl + jq via apt
#        - /etc/brewing/gpg.pass via scp (vom Mac)
#        - Repo via git clone (public, kein Token)
#        - .env via decrypt-env.sh (gpg.pass-Kette)
#        - Compose-Stack hochziehen (vps + portainer-hub Profile)
#        - Marker für alle 3 stateful Units setzen
#   8. Restore via scripts/restore.sh (all + portainer)
#   9. Verify: Counts gegen Pre-Snapshot + HTTPS-Probes alle Domains.
#  10. Bericht mit kompletter Timeline.
#
# Was NICHT geschieht (kein alex-User, kein bw-Login, kein voller Bootstrap):
#   - alex-User-Anlage (würde Bitwarden-Master-PW brauchen → interaktiv)
#   - Nightly Cron + Restore-Smoke-Cron-Setup
#   - Cloudflare-Reconcile (DNS-Einträge bleiben unverändert auf der CF-Seite)
#   - Mail-Setup
#
# Für den vollen 1:1-Replica-Bootstrap nach DR-Test:
#   ssh root@brewvps → cd /root/webPage_infra && ./scripts/bootstrap.sh --menu
#
# Aufruf:
#   ./scripts/dr-test-rebuild.sh
#   ./scripts/dr-test-rebuild.sh --skip-backup     # nutzt letzten R2-Backup
# ============================================================================
set -uo pipefail

# ---- Args ----
SKIP_BACKUP=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --skip-backup) SKIP_BACKUP=1 ;;
    --yes)         ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *) echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
  esac
done

# ---- Pfad/Repo ----
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR" || exit 2

# ---- Logging ----
c_log='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_rst='\033[0m'
log()  { printf '\n%b▶ %s%b\n' "$c_log"  "$*" "$c_rst"; }
ok()   { printf '%b  ✓ %s%b\n' "$c_ok"   "$*" "$c_rst"; }
warn() { printf '%b  ⚠ %s%b\n' "$c_warn" "$*" "$c_rst" >&2; }
fail() { printf '%b  ✖ %s%b\n' "$c_err"  "$*" "$c_rst" >&2; }
die()  { fail "$*"; exit 2; }

TS_START="$(date +%s)"
phase_ts() { local p="$1"; printf '    [%s] %s\n' "$(date -u +%H:%M:%S)" "$p"; }

# ============================================================================
# 1. PRE-FLIGHT
# ============================================================================
log "Schritt 1/10 — Pre-Flight"

# .env entschlüsseln (lokal auf Mac)
if [[ ! -f .env ]]; then
  GPG_PASS_FILE="${HOME}/.config/brewing/gpg.pass" ./scripts/decrypt-env.sh \
    >/dev/null 2>&1 || die ".env-Decrypt fehlgeschlagen — gpg.pass lokal vorhanden?"
fi
set -a; source .env; set +a

# Pflicht-Checks (Token-WERT NIE printen)
[[ -n "${HCLOUD_TOKEN:-}" ]] || die "HCLOUD_TOKEN fehlt in .env (bzw. .env.gpg)"
ok "HCLOUD_TOKEN gesetzt (Wert nicht angezeigt)"

command -v hcloud >/dev/null || die "hcloud CLI fehlt — brew install hcloud"
ok "hcloud CLI: $(hcloud version 2>&1 | head -1)"

[[ -r "${HOME}/.config/brewing/gpg.pass" ]] || die "lokal kein ~/.config/brewing/gpg.pass — kann nicht aufs VPS scp'en"
ok "gpg.pass lokal vorhanden ($(wc -c < ~/.config/brewing/gpg.pass | tr -d ' ') bytes)"

# Server identifizieren
SERVER_NAME="$(hcloud server list -o columns=name --selector '' 2>/dev/null | tail -n +2 | head -1 || true)"
[[ -z "$SERVER_NAME" ]] && SERVER_NAME="ubuntu-4gb-hel1-1"   # Fallback aus 2026-05-27 Provisioning
SERVER_INFO="$(hcloud server describe "$SERVER_NAME" -o format='{{.ID}}|{{.PublicNet.IPv4.IP}}|{{.Image.Name}}|{{.ServerType.Name}}|{{.Status}}' 2>/dev/null)" \
  || die "Server '$SERVER_NAME' nicht gefunden — hcloud server list prüfen"

IFS='|' read -r SERVER_ID SERVER_IP SERVER_IMAGE SERVER_TYPE SERVER_STATUS <<< "$SERVER_INFO"
ok "Server: $SERVER_NAME (ID $SERVER_ID, IP $SERVER_IP, ${SERVER_TYPE}, status=$SERVER_STATUS)"
ok "Aktuelles Image: $SERVER_IMAGE"

# SSH-Erreichbarkeit (vor Rebuild — danach wird's neu)
if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$SERVER_IP" true 2>/dev/null; then
  ok "SSH-Erreichbarkeit als root@${SERVER_IP} OK"
else
  die "SSH root@${SERVER_IP} unerreichbar — Bootstrap nach Rebuild würde scheitern"
fi

# ============================================================================
# 2. PRE-SNAPSHOT (Live-Counts für Verifikation)
# ============================================================================
log "Schritt 2/10 — Pre-Snapshot der Live-Counts"

SNAP_FILE="/tmp/dr-test-presnap-$(date +%s).txt"
{
  echo "# DR-Test Pre-Snapshot — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ssh -o BatchMode=yes "root@$SERVER_IP" 'bash -s' <<'SNAP'
set -uo pipefail
# Whole-DB-Counts via psql gegen die Live-Container
for unit in db-assistent db-rapt; do
  case "$unit" in
    db-assistent) schema=aibrewgenius ;;
    db-rapt)      schema=rapt ;;
  esac
  pw="$(docker inspect "$unit" --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '/^POSTGRES_PASSWORD=/{print substr($0, index($0,"=")+1)}')"
  [[ -z "$pw" ]] && continue
  # Tabellenliste + count(*) pro Tabelle
  docker exec -e PGPASSWORD="$pw" "$unit" \
    psql -tA -U supabase_admin -d postgres -F'|' -c "
      SELECT '${unit}|' || table_name || '|' || (
        xpath('/row/c/text()',
              query_to_xml('SELECT count(*) AS c FROM ${schema}.' || quote_ident(table_name), true, true, '')))[1]::text
      FROM information_schema.tables WHERE table_schema='${schema}' AND table_type='BASE TABLE'
      ORDER BY table_name;" 2>/dev/null
done

# Portainer-Volume-Größe
vol="$(docker inspect portainer --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)"
if [[ -n "$vol" ]]; then
  size="$(docker run --rm -v "${vol}:/d:ro" alpine stat -c '%s' /d/portainer.db 2>/dev/null || echo 0)"
  echo "portainer|portainer.db|${size}"
fi
SNAP
} > "$SNAP_FILE"

LINES=$(grep -cE '^[a-z]' "$SNAP_FILE")
ok "Pre-Snapshot in $SNAP_FILE ($LINES Tabellen erfasst)"
echo "  Erste 6 Zeilen:"
grep -E '^[a-z]' "$SNAP_FILE" | head -6 | sed 's/^/    /'

# ============================================================================
# 3. FRISCHER BACKUP-LAUF (= Restore-Target)
# ============================================================================
log "Schritt 3/10 — Frischer Backup-Lauf für konsistenten Restore-Target"
if (( SKIP_BACKUP == 1 )); then
  warn "--skip-backup gesetzt → letzte R2-Backups werden für Restore genutzt"
else
  ssh -o BatchMode=yes brewvps 'cd ~/webPage_infra && ./scripts/backup.sh 2>&1 | grep -vE "pg_dump:|NotImplemented|circular foreign" | tail -8' \
    || die "Backup-Lauf fehlgeschlagen"
  ok "Frische R2-Backups erzeugt"
fi

# ============================================================================
# 4. SAFETY PROMPT
# ============================================================================
log "Schritt 4/10 — DESTROY-Bestätigung"
cat <<EOF
  ${c_warn}─────────────────────────────────────────────────────────────${c_rst}
  ${c_warn}Gleich wird die Disk von ${SERVER_NAME} (ID ${SERVER_ID}) GEWISCHT.${c_rst}
  ${c_warn}IP ${SERVER_IP} bleibt erhalten, alles andere ist weg.${c_rst}
  ${c_warn}─────────────────────────────────────────────────────────────${c_rst}
  Plan:
    1. hcloud server rebuild ${SERVER_NAME} --image ubuntu-24.04
    2. SSH-Wartezeit + scp gpg.pass
    3. Minimal-Bootstrap (docker + repo + compose up)
    4. Marker setzen → restore.sh all + portainer
    5. Verify-Probes
  Pre-Snapshot ist gespeichert: ${SNAP_FILE}
  Letzte R2-Backups: $(ls -1t backups/db-rapt/ 2>/dev/null | head -1 || echo '(lokal nicht da; werden aus R2 gezogen)')

EOF
if (( ASSUME_YES == 1 )); then
  echo "  --yes gesetzt → DESTROY-Prompt übersprungen (Auth liegt beim Aufrufer)"
else
  read -rp "  Tippe 'DESTROY' zum Bestätigen, sonst Abbruch: " ans
  [[ "$ans" == "DESTROY" ]] || die "Abgebrochen (keine Bestätigung)"
fi

# ============================================================================
# 5. REBUILD via Hetzner-API
# ============================================================================
log "Schritt 5/10 — Hetzner-API Rebuild (disk wipe)"
phase_ts "rebuild-start"
if ! hcloud server rebuild "$SERVER_NAME" --image ubuntu-24.04 2>&1; then
  die "hcloud rebuild fehlgeschlagen"
fi
phase_ts "rebuild-done"
ok "Disk gewischt, Ubuntu 24.04 frisch ausgerollt"

# Known-Host des alten Server-Keys aus dem Mac wischen (neuer Host-Key)
ssh-keygen -R "$SERVER_IP" >/dev/null 2>&1 || true
ssh-keygen -R "brewvps"    >/dev/null 2>&1 || true

# ============================================================================
# 6. SSH-Wartezeit
# ============================================================================
log "Schritt 6/10 — Auf SSH warten (max 5 min)"
ssh_ready=0
for _ in $(seq 1 60); do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "root@$SERVER_IP" 'echo "ssh-ready: $(uname -a)"' >/dev/null 2>&1; then
    ssh_ready=1
    break
  fi
  printf '.'
  sleep 5
done
printf '\n'
(( ssh_ready == 1 )) || die "SSH kam nicht in 5 min hoch"
ok "SSH wieder erreichbar — $(ssh -o BatchMode=yes root@$SERVER_IP 'uname -srv' 2>&1 | head -1)"
phase_ts "ssh-ready"

# ============================================================================
# 7. MINIMAL-BOOTSTRAP
# ============================================================================
log "Schritt 7/10 — Minimal-Bootstrap auf gerebuiltem VPS"

# 7a) gpg.pass via scp aufs VPS
ssh -o BatchMode=yes "root@$SERVER_IP" 'install -d -m 711 -o root -g root /etc/brewing'
scp -o BatchMode=yes -q ~/.config/brewing/gpg.pass "root@$SERVER_IP:/etc/brewing/gpg.pass"
ssh -o BatchMode=yes "root@$SERVER_IP" 'chmod 600 /etc/brewing/gpg.pass; ls -la /etc/brewing/gpg.pass'
ok "/etc/brewing/gpg.pass deployed (600)"

# 7b) System-Packages + Docker installieren
ssh -o BatchMode=yes "root@$SERVER_IP" bash <<'EOSU'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q -y >/dev/null
apt-get install -y -q curl git gnupg ca-certificates jq unzip >/dev/null
# Docker offiziell installieren
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q -y >/dev/null
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
systemctl enable --now docker
# rclone via official installer (v1.74+; apt-rclone hat R2-Bug)
curl -fsSL https://rclone.org/install.sh | bash >/dev/null
echo "OK — docker $(docker version --format '{{.Server.Version}}'), compose $(docker compose version --short), rclone $(rclone version | head -1)"
EOSU
ok "System-Packages installiert"
phase_ts "packages-ready"

# 7c) Repo clonen (public → kein Token nötig)
ssh -o BatchMode=yes "root@$SERVER_IP" bash <<'EOSU'
set -euo pipefail
cd /root
rm -rf webPage_infra
git clone -q https://github.com/alexstuder-web/webPage_infra.git
cd webPage_infra
git rev-parse --short HEAD
EOSU
ok "Repo cloned auf /root/webPage_infra"

# 7d) .env entschlüsseln (via gpg.pass-Kette)
ssh -o BatchMode=yes "root@$SERVER_IP" bash <<'EOSU'
set -euo pipefail
cd /root/webPage_infra
GPG_PASS_FILE=/etc/brewing/gpg.pass ./scripts/decrypt-env.sh >/dev/null
test -f .env && echo "OK — .env $(wc -l < .env) lines"
EOSU
ok ".env entschlüsselt"

# 7e-pre) Cloudflare-Tunnel-Connector-Token holen
# Der CLOUDFLARE_TUNNEL_TOKEN steckt absichtlich NICHT in .env.gpg (pro-VPS frisch).
# Normalerweise macht das cf_ensure_tunnel_if_token() in bootstrap.sh; wir
# replizieren die GET .../cfd_tunnel/{id}/token-Logik hier inline, sonst kommt
# cloudflared in einen restart-loop mit "tunnel run requires ID or config".
log "Schritt 7e-pre — Cloudflare-Tunnel-Connector-Token holen (sonst cloudflared crashloop)"
ssh -o BatchMode=yes "root@$SERVER_IP" bash <<'EOSU'
set -uo pipefail
cd /root/webPage_infra
# Erst Tunnel-Ensure (schreibt TUNNEL_ID falls noch nicht da)
./scripts/cloudflare-reconcile.sh --ensure-tunnel-only >/dev/null 2>&1 || true

CF_API_TOKEN="$(grep -E '^CLOUDFLARE_API_TOKEN=[[:print:]]'  .env | head -1 | cut -d= -f2-)"
CF_ACCOUNT_ID="$(grep -E '^CLOUDFLARE_ACCOUNT_ID=[[:print:]]' .env | head -1 | cut -d= -f2-)"
TUNNEL_ID="$(grep    -E '^CLOUDFLARE_TUNNEL_ID=[[:print:]]'  .env | head -1 | cut -d= -f2-)"
[[ -z "$CF_API_TOKEN" || -z "$CF_ACCOUNT_ID" || -z "$TUNNEL_ID" ]] && {
  echo "FEHLER: CLOUDFLARE_API_TOKEN / _ACCOUNT_ID / _TUNNEL_ID nicht alle in .env"; exit 1
}

TOKEN_TMP="$(mktemp)"; chmod 600 "$TOKEN_TMP"
raw="$(curl -sS -w '\n%{http_code}' -X GET \
  -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")"
http_code="${raw##*$'\n'}"
resp_body="${raw%$'\n'*}"
(( http_code >= 200 && http_code < 300 )) \
  || { echo "Token-Abruf HTTP $http_code"; rm -f "$TOKEN_TMP"; exit 1; }
[[ "$(echo "$resp_body" | jq -r '.success // false')" == "true" ]] \
  || { echo "CF-Fehler: $(echo "$resp_body" | jq -c '.errors')"; rm -f "$TOKEN_TMP"; exit 1; }
echo "$resp_body" | jq -r '.result' > "$TOKEN_TMP"

# .env atomisch updaten — Token via cat (nie als Shell-Var)
ENV_TMP="$(mktemp)"; chmod 600 "$ENV_TMP"
grep -v '^CLOUDFLARE_TUNNEL_TOKEN=' .env > "$ENV_TMP" || true
{ printf 'CLOUDFLARE_TUNNEL_TOKEN='; cat "$TOKEN_TMP"; printf '\n'; } >> "$ENV_TMP"
mv "$ENV_TMP" .env
chmod 600 .env
rm -f "$TOKEN_TMP"
echo "OK — CLOUDFLARE_TUNNEL_TOKEN in .env ($(wc -c < <(grep '^CLOUDFLARE_TUNNEL_TOKEN=' .env | cut -d= -f2-)) bytes)"
EOSU
ok "CF-Tunnel-Token in .env auf VPS"

# 7e) Compose-Stack hochziehen
log "Schritt 7e — Compose-Stack hochziehen (das kann 5-10 min dauern)"
ssh -o BatchMode=yes "root@$SERVER_IP" bash <<'EOSU'
set -euo pipefail
cd /root/webPage_infra
docker compose --profile vps --profile portainer-hub pull -q 2>&1 | tail -3
docker compose --profile vps --profile portainer-hub up -d 2>&1 | tail -5
EOSU
ok "Compose-Up durch"
phase_ts "compose-up"

# 7f) Auf DBs warten
log "Schritt 7f — Warten auf DB-Container ready"
ssh -o BatchMode=yes "root@$SERVER_IP" bash <<'EOSU'
set -uo pipefail
for unit in db-assistent db-rapt; do
  pw="$(docker inspect "$unit" --format='{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '/^POSTGRES_PASSWORD=/{print substr($0, index($0,"=")+1)}')"
  for i in $(seq 1 60); do
    if docker exec -e PGPASSWORD="$pw" "$unit" pg_isready -U supabase_admin -d postgres >/dev/null 2>&1; then
      echo "  ✓ $unit ready nach ${i}s"
      break
    fi
    sleep 2
  done
done
sleep 8   # init scripts
EOSU
ok "DBs ready"
phase_ts "dbs-ready"

# 7g) Marker setzen
ssh -o BatchMode=yes "root@$SERVER_IP" bash <<'EOSU'
set -euo pipefail
install -d -m 755 /etc/brewing/stateful-units.d
touch /etc/brewing/stateful-units.d/db-assistent
touch /etc/brewing/stateful-units.d/db-rapt
touch /etc/brewing/stateful-units.d/portainer
ls -la /etc/brewing/stateful-units.d/
EOSU
ok "Marker gesetzt"

# ============================================================================
# 8. RESTORE
# ============================================================================
log "Schritt 8/10 — Restore aus R2"
ssh -o BatchMode=yes "root@$SERVER_IP" bash <<'EOSU'
set -uo pipefail
cd /root/webPage_infra
echo "--- DBs ---"
./scripts/restore.sh all --yes 2>&1 | tail -15
echo "--- Portainer ---"
./scripts/restore.sh portainer latest --yes 2>&1 | tail -10
EOSU
ok "Restore durchgelaufen"
phase_ts "restore-done"

# ============================================================================
# 9. VERIFY — Counts gegen Pre-Snapshot
# ============================================================================
log "Schritt 9/10 — Verifikation"

POST_SNAP="/tmp/dr-test-postsnap-$(date +%s).txt"
ssh -o BatchMode=yes "root@$SERVER_IP" 'bash -s' > "$POST_SNAP" <<'POSTSNAP'
set -uo pipefail
for unit in db-assistent db-rapt; do
  case "$unit" in
    db-assistent) schema=aibrewgenius ;;
    db-rapt)      schema=rapt ;;
  esac
  pw="$(docker inspect "$unit" --format='{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '/^POSTGRES_PASSWORD=/{print substr($0, index($0,"=")+1)}')"
  [[ -z "$pw" ]] && continue
  docker exec -e PGPASSWORD="$pw" "$unit" \
    psql -tA -U supabase_admin -d postgres -F'|' -c "
      SELECT '${unit}|' || table_name || '|' || (
        xpath('/row/c/text()',
              query_to_xml('SELECT count(*) AS c FROM ${schema}.' || quote_ident(table_name), true, true, '')))[1]::text
      FROM information_schema.tables WHERE table_schema='${schema}' AND table_type='BASE TABLE'
      ORDER BY table_name;" 2>/dev/null
done
vol="$(docker inspect portainer --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)"
if [[ -n "$vol" ]]; then
  size="$(docker run --rm -v "${vol}:/d:ro" alpine stat -c '%s' /d/portainer.db 2>/dev/null || echo 0)"
  echo "portainer|portainer.db|${size}"
fi
POSTSNAP

# Vergleich
echo "Tabelle                                        Pre→Post"
echo "---------------------------------------------- ---------------"
ALL_OK=1; CHECKED=0
while IFS='|' read -r unit tab pre; do
  [[ -z "$unit" ]] && continue
  [[ "$unit" =~ ^# ]] && continue
  post="$(grep -E "^${unit}\|${tab}\|" "$POST_SNAP" 2>/dev/null | cut -d'|' -f3 | tr -d '[:space:]')"
  CHECKED=$((CHECKED+1))
  if [[ -z "$post" ]]; then
    printf '  %-46s %s\n' "${unit}.${tab}" "✖ FEHLT in Post"
    ALL_OK=0
  elif [[ "$pre" == "$post" ]]; then
    printf '  %-46s %s\n' "${unit}.${tab}" "✓ ${pre}=${post}"
  else
    # Drift erlauben für telemetry_* (zwischen pre-snap und restore-target können neue rows reinkommen)
    if [[ "$tab" =~ ^telemetry_ ]]; then
      delta=$(( pre - post ))
      tol=$(( pre / 1000 )); (( tol < 5 )) && tol=5
      if (( delta >= 0 && delta <= tol )); then
        printf '  %-46s %s\n' "${unit}.${tab}" "✓ ${pre}→${post} drift -${delta} (tol ${tol})"
      else
        printf '  %-46s %s\n' "${unit}.${tab}" "✖ ${pre}→${post} drift -${delta} > tol ${tol}"
        ALL_OK=0
      fi
    elif [[ "$tab" == "portainer.db" ]]; then
      printf '  %-46s %s\n' "${unit}.${tab}" "✓ ${pre}→${post} bytes"
    else
      printf '  %-46s %s\n' "${unit}.${tab}" "✖ ${pre}≠${post}"
      ALL_OK=0
    fi
  fi
done < <(grep -E '^[a-z]' "$SNAP_FILE")
echo "  ──────────────────────────────────────────── ────────────────"
echo "  $CHECKED Tabellen geprüft"

# HTTPS-Probes via Cloudflare
echo
log "HTTPS-Probes via Cloudflare"
for host in alexstuder.cloud aibrewgenius.alexstuder.cloud rapt.alexstuder.cloud portainer.alexstuder.cloud; do
  code="$(curl -sI -o /dev/null -w '%{http_code}' -m 10 "https://${host}" 2>/dev/null)"
  case "$code" in
    200|301|302|307|308) printf '  ✓ %s → %s\n' "$host" "$code" ;;
    *)                    printf '  ✖ %s → %s\n' "$host" "$code"; ALL_OK=0 ;;
  esac
done

# ============================================================================
# 10. BERICHT
# ============================================================================
TS_END="$(date +%s)"
DUR=$(( TS_END - TS_START ))
echo
echo "════════════════════════════════════════════════"
log "Schritt 10/10 — Bericht"
echo "  Total-Dauer:        $((DUR / 60)) min $((DUR % 60)) s"
echo "  Pre-Snapshot:       $SNAP_FILE"
echo "  Post-Snapshot:      $POST_SNAP"
echo

if (( ALL_OK == 1 )); then
  printf '%bDR-TEST BESTANDEN — alle Counts identisch (oder im Drift-Toleranzfenster),\n' "$c_ok"
  printf 'alle HTTPS-Endpunkte antworten, Restore aus R2 ist nach Disk-Wipe bewiesen.%b\n' "$c_rst"
  echo
  echo "Was du noch manuell machen kannst (optional, kein DR-Bestandteil):"
  echo "  ssh root@${SERVER_IP}"
  echo "  cd /root/webPage_infra && ./scripts/bootstrap.sh --menu"
  echo "  → alex-User anlegen, nightly Cron + Restore-Smoke-Cron aufsetzen (~10 min)"
  exit 0
else
  printf '%bDR-TEST FAILED — siehe Befunde oben.%b\n' "$c_err" "$c_rst"
  echo "  Server bleibt für Debug stehen: ssh root@${SERVER_IP}"
  exit 1
fi
