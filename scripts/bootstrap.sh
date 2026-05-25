#!/usr/bin/env bash
# ============================================================================
# Brewing-Stack Bootstrap für frischen Ubuntu-VPS (22.04 / 24.04).
# Als root ausführen — installiert: User 'alex' + Docker + Bitwarden CLI,
# clont webPage_infra, holt die GPG-Passphrase aus Bitwarden, entschlüsselt
# .env und startet alle Container.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/alexstuder-web/webPage_infra/main/scripts/bootstrap.sh -o bootstrap.sh && chmod +x bootstrap.sh && ./bootstrap.sh
#
# Aufruf:
#   ./bootstrap.sh            Vollständiger Erst-Bootstrap (mit Skip-Erkennung)
#   ./bootstrap.sh --menu     Direkt ins Interaktive Menü (Basis-Schritte werden
#                             übersprungen wenn bereits erledigt)
#
# Interaktive Eingaben werden NUR dann angefordert, wenn der jeweilige
# Schritt tatsächlich ausgeführt werden muss (lazy):
#   - BW-Mail + BW-Master-PW: nur falls .env fehlt
#   - Linux-User-PW:          nur falls User 'alex' neu angelegt wird
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- Konstanten
REPO_URL="https://github.com/alexstuder-web/webPage_infra.git"
APP_USER="alex"
APP_HOME="/home/${APP_USER}"
APP_DIR="${APP_HOME}/webPage_infra"
BW_ITEM="ALEXSTUDER_WEBPAGE_GPG_PASSWORD"

# ---------------------------------------------------------------- Argument-Parsing
# Optionaler --menu-Flag: springt nach Pre-flight + Skip-Checks direkt ins Menü.
MENU_MODE=0
case "${1:-}" in
  --menu) MENU_MODE=1 ;;
  "")     : ;;
  *)      printf 'Unbekanntes Argument: %s\n' "$1" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- Helpers
log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
err()  { printf '\n\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- Pre-flight
[[ $EUID -eq 0 ]] || err "Muss als root laufen — versuch: sudo bash $0"
[[ -f /etc/os-release ]] || err "Kein /etc/os-release — Linux?"
. /etc/os-release
[[ "$ID" == "ubuntu" ]] || err "Nur Ubuntu unterstützt (gefunden: $ID)"

# ---------------------------------------------------------------- Trap-Verwaltung
# Alle Secret-Tempfiles werden hier zentral registriert.
# Erweiterung: 'CLEANUP_FILES+=("$datei")' nach jedem mktemp.
declare -a CLEANUP_FILES=()
_cleanup() {
  local f
  for f in "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}"; do
    rm -f "$f"
  done
}
trap '_cleanup' EXIT

# ================================================================
# IDEMPOTENZ-CHECKS — Basis-Schritte überspringen wenn bereits erledigt.
# Wird vor UND im --menu-Modus ausgeführt.
# ================================================================
_base_packages_done() {
  command -v docker >/dev/null 2>&1 \
    && command -v bw     >/dev/null 2>&1 \
    && command -v rclone >/dev/null 2>&1 \
    && command -v jq     >/dev/null 2>&1
}
_user_exists()      { id "$APP_USER" >/dev/null 2>&1; }
_docker_done()      { command -v docker >/dev/null 2>&1; }
_bw_done()          { command -v bw >/dev/null 2>&1; }
_repo_done()        { [[ -d "$APP_DIR/.git" ]]; }
_env_done()         { [[ -f "$APP_DIR/.env" ]]; }
_gpgpass_done()     { [[ -s /etc/brewing/gpg.pass ]]; }

# ================================================================
# BASIS-BOOTSTRAP (überspringbar)
# ================================================================
run_base_bootstrap() {

  # ---------------------------------------------------------------- Eingaben (lazy)
  log "Brewing-Stack Bootstrap"
  cat <<EOF
  Repo: $REPO_URL
  Ziel: $APP_DIR  (User: $APP_USER, UID 1000)
EOF

  # Linux-User-PW nur abfragen, falls User neu angelegt wird
  local user_pass=""
  if ! _user_exists; then
    read -srp "Passwort für neuen Linux-User '${APP_USER}': " user_pass; echo
    local user_pass2
    read -srp "  (wiederholen): " user_pass2; echo
    [[ "$user_pass" == "$user_pass2" ]] || err "Passwörter stimmen nicht überein"
    [[ -n "$user_pass" ]] || err "Passwort darf nicht leer sein"
  fi

  # ---------------------------------------------------------------- System-Packages
  if _base_packages_done; then
    ok "Base-Packages bereits vorhanden — übersprungen"
  else
    log "System-Update + Base-Packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl git gnupg ca-certificates lsb-release ufw jq unzip cron rclone
    systemctl enable --now cron
    ok "apt up-to-date (inkl. cron + rclone für Backups)"
  fi

  # ---------------------------------------------------------------- Linux-User
  if _user_exists; then
    ok "User '${APP_USER}' existiert bereits — kein erneutes chpasswd"
  else
    log "Linux-User '$APP_USER' anlegen"
    useradd -m -s /bin/bash -u 1000 "$APP_USER"
    printf '%s\n' "${APP_USER}:${user_pass}" | chpasswd
    unset user_pass  # Secret sofort nach chpasswd vergessen
    usermod -aG sudo "$APP_USER"
    ok "User '$APP_USER' bereit (sudo)"
  fi
  # Docker-Gruppe: immer sicherstellen (idempotent)
  usermod -aG docker "$APP_USER" 2>/dev/null || true
  unset user_pass user_pass2 2>/dev/null || true

  # ---------------------------------------------------------------- Docker
  if _docker_done; then
    ok "Docker bereits installiert — übersprungen"
  else
    log "Docker installieren"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) läuft"

  # ---------------------------------------------------------------- Bitwarden CLI
  # Bevorzugt: snap (signierter Channel, Signatur-Verifikation eingebaut).
  # Warum snap statt fest-eingepinntem SHA-256: die Download-URL
  # (?app=cli&platform=linux) liefert IMMER das jeweils neueste bw-Release —
  # ein hartkodierter Hash würde bei der nächsten bw-Veröffentlichung brechen und
  # einen Fresh-VPS-Bootstrap stilllegen. Der direkte Download bleibt nur als
  # Notfall-Fallback und installiert NIE eine unverifizierte Datei: er verlangt
  # einen via $BW_ZIP_SHA256 übergebenen Soll-Hash und bricht sonst hart ab.
  if _bw_done; then
    ok "Bitwarden CLI bereits installiert — übersprungen"
  else
    log "Bitwarden CLI installieren"
    if command -v snap >/dev/null 2>&1; then
      snap install bw 2>/dev/null \
        || echo "  snap install bw fehlgeschlagen — versuche direkten Download" >&2
    fi
    # Fallback: direkter Download — NUR mit SHA-256-Verifikation.
    if ! command -v bw >/dev/null 2>&1; then
      if [[ -z "${BW_ZIP_SHA256:-}" ]]; then
        err "bw via snap nicht installierbar und kein \$BW_ZIP_SHA256 für den Download-Fallback gesetzt.
   Aus Sicherheitsgründen wird keine unverifizierte Binary installiert.
   Lösung: 'snap install bw' ermöglichen ODER den erwarteten SHA-256 der aktuellen
   Linux-CLI-Zip auf https://bitwarden.com/help/cli/ prüfen und so erneut starten:
     BW_ZIP_SHA256=<hash> ./bootstrap.sh"
      fi
      local BW_ZIP
      BW_ZIP="$(mktemp --suffix=.zip)"
      # Kein Secret im BW_ZIP — keine trap-Registrierung nötig; wird sofort rm -f'd.
      curl -fsSL "https://vault.bitwarden.com/download/?app=cli&platform=linux" -o "$BW_ZIP" \
        || { rm -f "$BW_ZIP"; err "Download der bw-CLI-Zip fehlgeschlagen"; }
      if ! echo "${BW_ZIP_SHA256}  ${BW_ZIP}" | sha256sum -c - ; then
        rm -f "$BW_ZIP"
        err "SHA-256 der bw-Zip stimmt NICHT mit \$BW_ZIP_SHA256 überein — Abbruch (mögliche Manipulation)."
      fi
      unzip -o "$BW_ZIP" -d /usr/local/bin/
      chmod +x /usr/local/bin/bw
      rm -f "$BW_ZIP"
    fi
  fi
  command -v bw >/dev/null 2>&1 || err "bw CLI Installation fehlgeschlagen"
  ok "bw $(bw --version) bereit"

  # ---------------------------------------------------------------- Repo clonen / aktualisieren
  log "Repo clonen / aktualisieren"
  if _repo_done; then
    # Dirty working tree absichern: ein VPS-Hotfix (uncommittete Änderung) darf
    # nicht still von 'git reset --hard' überschrieben werden. .env ist gitignored
    # und taucht in --porcelain ohnehin nicht auf.
    if [[ -n "$(sudo -u "$APP_USER" git -C "$APP_DIR" status --porcelain)" ]]; then
      err "Uncommittete Änderungen in $APP_DIR — 'git reset --hard origin/main' würde sie verwerfen.
   Erst sichern/committen (oder 'git -C $APP_DIR stash'), dann bootstrap erneut starten."
    fi
    sudo -u "$APP_USER" git -C "$APP_DIR" fetch --all
    # Unpushed-Commits absichern: lokale Commits, die noch nicht auf origin/main sind,
    # würden durch 'git reset --hard origin/main' still verworfen werden.
    local unpushed
    unpushed="$(sudo -u "$APP_USER" git -C "$APP_DIR" log origin/main..HEAD --oneline 2>/dev/null || true)"
    if [[ -n "$unpushed" ]]; then
      err "Nicht gepushte Commits in $APP_DIR (würden von 'git reset --hard' verworfen):
$(printf '%s\n' "$unpushed" | sed 's/^/   /')
   Erst pushen oder zurücksetzen ('git -C $APP_DIR reset --soft HEAD~N'), dann bootstrap erneut starten."
    fi
    sudo -u "$APP_USER" git -C "$APP_DIR" reset --hard origin/main
  else
    sudo -u "$APP_USER" git clone "$REPO_URL" "$APP_DIR"
  fi
  ok "$APP_DIR auf main"

  # ---------------------------------------------------------------- BW Login + Passphrase (lazy)
  if _env_done && _gpgpass_done; then
    ok ".env + gpg.pass bereits vorhanden — BW-Login übersprungen"
  else
    log "Bitwarden-Eingaben für .env-Entschlüsselung"
    local bw_email bw_pass
    read -rp "Bitwarden E-Mail: " bw_email
    read -srp "Bitwarden Master-Passwort: " bw_pass; echo
    [[ -n "$bw_email" && -n "$bw_pass" ]] || err "BW-Eingaben dürfen nicht leer sein"

    # Tempfiles für Secret-Transport: sofort in CLEANUP_FILES registrieren.
    local bw_pass_file pass_tmp
    bw_pass_file="$(sudo -u "$APP_USER" mktemp)"
    CLEANUP_FILES+=("$bw_pass_file")
    pass_tmp="$(sudo -u "$APP_USER" mktemp)"
    CLEANUP_FILES+=("$pass_tmp")
    chmod 600 "$bw_pass_file" "$pass_tmp"
    printf "%s" "$bw_pass" > "$bw_pass_file"
    unset bw_pass

    sudo -u "$APP_USER" -H \
      BW_EMAIL="$bw_email" \
      BW_PASS_FILE="$bw_pass_file" \
      BW_ITEM="$BW_ITEM" \
      PASS_TMP="$pass_tmp" \
      bash <<'EOSU'
set -euo pipefail
# Zweizeilig: erst zuweisen (failt sofort bei Fehler), dann exportieren.
BW_PASSWORD="$(cat "$BW_PASS_FILE")"
export BW_PASSWORD
bw config server https://vault.bitwarden.com >/dev/null 2>&1 || true
status="$(bw status 2>/dev/null | jq -r .status || echo unauthenticated)"
if [[ "$status" == "unauthenticated" ]]; then
  bw login "$BW_EMAIL" --passwordenv BW_PASSWORD >/dev/null
fi
BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)"
export BW_SESSION
bw sync >/dev/null
bw get password "$BW_ITEM" > "$PASS_TMP"
EOSU

    rm -f "$bw_pass_file"
    # bw_pass_file aus CLEANUP_FILES entfernen (bereits gelöscht).
    # Echtes Array-Filtern: mapfile + grep -vxF statt String-Ersetzung die ein
    # Leer-Element hinterlässt (und dann 'rm -f ""' riskiert).
    mapfile -t CLEANUP_FILES < <(printf '%s\n' "${CLEANUP_FILES[@]}" | grep -vxF "$bw_pass_file")
    ok "Passphrase abgeholt"

    # ---------------------------------------------------------------- .env entschlüsseln
    if _env_done; then
      ok ".env bereits vorhanden — Decrypt übersprungen"
    else
      log ".env entschlüsseln"
      sudo -u "$APP_USER" -H \
        APP_DIR="$APP_DIR" \
        PASS_TMP="$pass_tmp" \
        bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
[[ -f .env ]] && rm -f .env
# Zweizeilig: erst zuweisen (failt sofort bei Fehler), dann exportieren.
GPG_PASSPHRASE="$(cat "$PASS_TMP")"
export GPG_PASSPHRASE
./scripts/decrypt-env.sh
EOSU
      ok ".env geschrieben"
    fi

    # ---------------------------------------------------------------- GPG-Passphrase persistieren
    if _gpgpass_done; then
      ok "/etc/brewing/gpg.pass bereits vorhanden — übersprungen"
    else
      log "GPG-Passphrase für nightly Backup hinterlegen (/etc/brewing/gpg.pass)"
      install -d -m 700 -o "$APP_USER" -g "$APP_USER" /etc/brewing
      install -m 600 -o "$APP_USER" -g "$APP_USER" "$pass_tmp" /etc/brewing/gpg.pass
      ok "/etc/brewing/gpg.pass geschrieben (owner ${APP_USER}, mode 600)"
    fi

    rm -f "$pass_tmp"
    # pass_tmp aus CLEANUP_FILES entfernen (bereits gelöscht) — echtes Filtern.
    mapfile -t CLEANUP_FILES < <(printf '%s\n' "${CLEANUP_FILES[@]}" | grep -vxF "$pass_tmp")
  fi

  # ---------------------------------------------------------------- Nightly Backup (cron)
  # Idempotent: /etc/cron.d/-Drop-in wird bei jedem Lauf neu geschrieben.
  # Läuft direkt als $APP_USER (Mitglied der docker-Gruppe → 'docker exec' ohne
  # sudo; owner von Repo + /etc/brewing/gpg.pass → liest die Passphrase ohne Prompt).
  # Das Scoping "was wirklich gesichert wird" sitzt marker-seitig in backup.sh
  # (STATEFUL_UNITS_DIR=/etc/brewing/stateful-units.d): kein Marker → No-op, Exit 0.
  log "Nightly Backup-Cron einrichten (03:00, als ${APP_USER}, idempotent)"
  # Alten sudoers-Drop-in aus früheren Bootstraps entfernen (idempotent).
  rm -f /etc/sudoers.d/brewing-backup
  local cron_file="/etc/cron.d/brewing-backup"
  cat > "$cron_file" <<EOF
# Brewing Postgres-Backup — nightly 03:00. Von bootstrap.sh erzeugt (idempotent).
# Läuft als ${APP_USER} (docker-Gruppe + owner gpg.pass) — kein sudo.
# Scoping: backup.sh liest Marker aus /etc/brewing/stateful-units.d/ —
# auf stateless-only VPS (kein Marker) ist der Lauf ein sauberer No-op (Exit 0).
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * ${APP_USER} ${APP_DIR}/scripts/backup.sh >> /var/log/brewing-backup.log 2>&1
EOF
  chmod 644 "$cron_file"
  # Logfile gehört alex → cron-Job (als alex) kann reinschreiben.
  touch /var/log/brewing-backup.log
  chown "$APP_USER:$APP_USER" /var/log/brewing-backup.log
  chmod 644 /var/log/brewing-backup.log
  ok "Cron aktiv: $cron_file → backup.sh als ${APP_USER} (Log: /var/log/brewing-backup.log)"

  # ---------------------------------------------------------------- Marker-Registry-Verzeichnis sicherstellen
  # /etc/brewing/stateful-units.d/ — Marker-Dateien steuern, welche stateful Units
  # auf diesem VPS installiert sind (von backup.sh ausgelesen).
  # Owner alex, mode 755 → cron als alex kann lesen und schreiben; kein sudo nötig.
  local units_dir="/etc/brewing/stateful-units.d"
  install -d -m 755 -o "$APP_USER" -g "$APP_USER" "$units_dir"
  ok "Marker-Registry vorhanden: ${units_dir}"

  # ---------------------------------------------------------------- Marker-Backfill (selbstheilend, E6)
  # Auf bereits gebootstrappten VPS: wenn supabase-db jetzt läuft → Marker idempotent anlegen.
  # Beim Erst-Bootstrap ist supabase-db noch nicht gestartet (Start passiert im Menü via
  # action_select_and_start) — der Marker wird dort nach erfolgreichem docker compose up gesetzt.
  # Dieser Backfill ist die Selbstheilung für VPS, die vor der Marker-Einführung gebootstrapped
  # wurden.
  local supabase_marker="${units_dir}/supabase"
  if [[ -f "$supabase_marker" ]]; then
    ok "supabase-Marker bereits vorhanden — Backfill übersprungen"
  else
    local _sb_running=0
    sudo -u "$APP_USER" bash <<'EOSU' 2>/dev/null && _sb_running=1 || _sb_running=0
docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null | grep -q '^true$'
EOSU
    if (( _sb_running == 1 )); then
      install -m 644 -o "$APP_USER" -g "$APP_USER" /dev/null "$supabase_marker"
      ok "supabase-Marker gesetzt (Backfill: supabase-db läuft) → ${supabase_marker}"
    else
      echo "  supabase-db läuft noch nicht — Backfill übersprungen (Marker wird beim Install-Unit-Start gesetzt)."
    fi
  fi

} # end run_base_bootstrap

# ================================================================
# CLOUDFLARE TUNNEL-ENSURE HELPER
# (VOR dem Container-Start aufrufen — Reihenfolge: ensure → up → reconcile)
#
# Was hier passiert:
#   1. Guard: nur ausführen wenn CLOUDFLARE_API_TOKEN in .env gesetzt.
#   2. Tunnel-Ensure via cloudflare-reconcile.sh --ensure-tunnel-only:
#      Sucht "brewing-<sanitisierter-hostname>" → ID holen oder Tunnel neu anlegen.
#      Schreibt CLOUDFLARE_TUNNEL_ID in die lokale .env.
#   3. Connector-Token holen (GET .../token) → in lokale .env als
#      CLOUDFLARE_TUNNEL_TOKEN schreiben (Variante a, §5.4):
#        • Token kommt nie in argv oder Log.
#        • CLOUDFLARE_TUNNEL_TOKEN in .env ist lokal-only (gitignored).
#        • Nie in .env.gpg — Bootstrap schreibt ihn pro VPS frisch.
#   4. Idempotenz: bei existierendem Tunnel wird der Token erneut abgeholt
#      (GET .../token liefert immer den selben verwendbaren Token, A-2).
#      docker compose up -d recreated cloudflared nur wenn TUNNEL_TOKEN
#      in .env sich geändert hat (Variante a: compose liest ${CLOUDFLARE_TUNNEL_TOKEN}).
#
# Token-Sicherheit:
#   • Kein set -x um das Token-Schreiben.
#   • Token wird nie via log/ok/echo ausgegeben.
#   • Token läuft über eine tmp-Datei (mode 600) → in CLEANUP_FILES registriert.
#   • mv .env atomisch (kein Fenster mit halbem .env auf Platte).
# ================================================================
cf_ensure_tunnel_if_token() {
  if sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
grep -q '^CLOUDFLARE_API_TOKEN=.\+' "$APP_DIR/.env"
EOSU
  then
    log "Cloudflare Tunnel-Ensure (pro-VPS, idempotent)"

    # ---- Schritt A: Tunnel-Ensure + Tunnel-ID in .env schreiben ----
    # cloudflare-reconcile.sh --ensure-tunnel-only (I-2): das Script leitet intern
    # stdout nach stderr um (exec 3>&1 1>&2) und schreibt nur 'TUNNEL_ID=<id>'
    # gezielt nach fd3 (= ursprünglicher stdout = dieser $()-Kanal). Damit landen
    # Diagnose-Ausgaben (log/ok, ANSI) auf stderr, und $() fängt sauber nur die
    # eine Maschinen-Zeile ab.
    local ensure_out
    ensure_out="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
./scripts/cloudflare-reconcile.sh --ensure-tunnel-only
EOSU
)"
    # TUNNEL_ID extrahieren — robust, weil ensure_out nur die eine Zeile enthält
    local tunnel_id
    tunnel_id="$(printf '%s' "$ensure_out" | grep '^TUNNEL_ID=' | cut -d= -f2-)"
    [[ -n "$tunnel_id" ]] \
      || err "cf_ensure_tunnel_if_token: Tunnel-Ensure lieferte keine TUNNEL_ID (Output: ${ensure_out})"
    ok "Tunnel-ID: ${tunnel_id}"

    # ---- Schritt B: Connector-Token holen (GET .../token) ----
    # Token wird über ein mode-600-Tempfile transportiert (nie in argv/log).
    # A-2: GET .../token liefert für existierenden Tunnel denselben Token (re-run-sicher).
    local cf_api_token cf_account_id
    cf_api_token="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
grep -E "^CLOUDFLARE_API_TOKEN=[[:print:]]" "$APP_DIR/.env" | head -1 | cut -d= -f2-
EOSU
)"
    cf_account_id="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
grep -E "^CLOUDFLARE_ACCOUNT_ID=[[:print:]]" "$APP_DIR/.env" | head -1 | cut -d= -f2-
EOSU
)"

    # Token-Tempfile: mode 600, in CLEANUP_FILES registrieren
    local token_tmp
    token_tmp="$(sudo -u "$APP_USER" mktemp)"
    CLEANUP_FILES+=("$token_tmp")
    chmod 600 "$token_tmp"

    # Token holen und in Tempfile schreiben — kein set -x, kein echo
    # Zweizeilig: erst zuweisen, dann exportieren (kein export VAR="$(cmd)")
    sudo -u "$APP_USER" -H \
      CF_API_TOKEN="$cf_api_token" \
      CF_ACCOUNT_ID="$cf_account_id" \
      CF_TUNNEL_ID="$tunnel_id" \
      TOKEN_TMP="$token_tmp" \
      bash <<'EOSU'
set -euo pipefail
# Connector-Token abrufen (GET /accounts/{acct}/cfd_tunnel/{id}/token)
# Authorization-Header enthält den API-Token (pre-existing Muster).
raw="$(curl -sS -w '\n%{http_code}' -X GET \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/token")"
http_code="${raw##*$'\n'}"
resp_body="${raw%$'\n'*}"
if (( http_code < 200 || http_code >= 300 )); then
  printf 'Token-Abruf HTTP-Fehler %s\n' "$http_code" >&2
  exit 1
fi
success="$(printf '%s' "$resp_body" | jq -r '.success // false')"
if [[ "$success" != "true" ]]; then
  printf 'Token-Abruf CF-Fehler: %s\n' "$(printf '%s' "$resp_body" | jq -c '.errors // .')" >&2
  exit 1
fi
# Token aus .result (String) — kein echo, direkt in Datei
printf '%s' "$resp_body" | jq -r '.result' > "$TOKEN_TMP"
EOSU

    # ---- Schritt C: Token in lokale .env schreiben (Variante a, §5.4) ----
    # Atomisch: erst .env-Kopie ohne die alte Zeile, dann neue Zeile, dann mv.
    # KEIN set -x ab hier (Token ist sensitiv).
    local env_tmp
    env_tmp="$(sudo -u "$APP_USER" mktemp)"
    CLEANUP_FILES+=("$env_tmp")
    chmod 600 "$env_tmp"

    sudo -u "$APP_USER" -H \
      APP_DIR="$APP_DIR" \
      TOKEN_TMP="$token_tmp" \
      ENV_TMP="$env_tmp" \
      bash <<'EOSU'
set -euo pipefail
# Neue .env ohne alte CLOUDFLARE_TUNNEL_TOKEN-Zeile + neue Zeile hinten
grep -v '^CLOUDFLARE_TUNNEL_TOKEN=' "$APP_DIR/.env" > "$ENV_TMP" || true
# C-2: Token-Bytes direkt via cat durchreichen — KEINE Command-Substitution
# (kein "$(cat ...)" — das würde den Token als Shell-Wort expandieren und
# trailing newlines trimmen; außerdem ps-sichtbar wenn in argv).
{ printf 'CLOUDFLARE_TUNNEL_TOKEN='; cat "$TOKEN_TMP"; printf '\n'; } >> "$ENV_TMP"
# Atomisch tauschen
mv "$ENV_TMP" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"   # I-3: Mode nach mv erzwingen (umask-sicher)
EOSU

    # Tempfiles sofort aufräumen + aus CLEANUP_FILES entfernen
    rm -f "$token_tmp" "$env_tmp" 2>/dev/null || true
    mapfile -t CLEANUP_FILES < <(printf '%s\n' "${CLEANUP_FILES[@]}" | grep -vxF "$token_tmp" | grep -vxF "$env_tmp")

    ok "Cloudflare Tunnel-Ensure abgeschlossen (Token in lokaler .env — nicht in .env.gpg)"
  else
    echo "  CLOUDFLARE_API_TOKEN nicht gesetzt — Tunnel-Ensure übersprungen."
    echo "  Token + Tunnel-ID werden pro VPS automatisch gesetzt sobald CLOUDFLARE_API_TOKEN in .env steht."
  fi
}

# ================================================================
# CLOUDFLARE RECONCILE HELPER (wiederverwendbar, nach jedem Container-Start)
# ================================================================
cf_reconcile_if_token() {
  if sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
grep -q '^CLOUDFLARE_API_TOKEN=.\+' "$APP_DIR/.env"
EOSU
  then
    log "Cloudflare Tunnel + DNS reconcilen"
    sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
./scripts/cloudflare-reconcile.sh
EOSU
  else
    echo "  CLOUDFLARE_API_TOKEN nicht gesetzt — Cloudflare-Reconcile übersprungen."
    echo "  Hostnames manuell im Dashboard pflegen oder Token nachtragen + ./scripts/cloudflare-reconcile.sh"
  fi
}

# ================================================================
# MENÜ-FUNKTIONEN
# ================================================================

# ---------------------------------------------------------------- Selektiver Einzel-App-Start
# ACHTUNG: Kein Per-App-Profil in docker-compose.yml (Phase 1 hat keins eingeführt).
# Selektiver Start läuft daher über explizite Service-Namen (§5.1 BOOTSTRAP_MENU_KONZEPT.md).
# cloudflared hängt an profiles: [vps] → wird bei jeder selektiven Installation
# mitgestartet (App wäre ohne Tunnel nicht erreichbar); separater Befehl, damit
# der Service-Namens-Aufruf und der Profile-Aufruf klar getrennt sind.

# ---------------------------------------------------------------- Supabase-Marker idempotent setzen
# Setzt /etc/brewing/stateful-units.d/supabase (mode 644, owner alex), falls
# supabase-db jetzt läuft. Idempotent: vorhandener Marker → kein Fehler.
# Wird nach erfolgreichem docker compose up für Optionen aufgerufen, die supabase-db starten.
_ensure_supabase_marker() {
  local units_dir="/etc/brewing/stateful-units.d"
  local supabase_marker="${units_dir}/supabase"
  # Verzeichnis sicherstellen (idempotent, falls action_select_and_start vor run_base_bootstrap laeuft)
  install -d -m 755 -o "$APP_USER" -g "$APP_USER" "$units_dir" 2>/dev/null || true
  if [[ -f "$supabase_marker" ]]; then
    ok "supabase-Marker bereits vorhanden — ${supabase_marker}"
    return 0
  fi
  # Gegated auf laufenden supabase-db (kein Marker für eine Unit die nicht hochkam)
  local _sb_running=0
  sudo -u "$APP_USER" bash <<'EOSU' 2>/dev/null && _sb_running=1 || _sb_running=0
docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null | grep -q '^true$'
EOSU
  if (( _sb_running == 1 )); then
    install -m 644 -o "$APP_USER" -g "$APP_USER" /dev/null "$supabase_marker"
    ok "supabase-Marker gesetzt → ${supabase_marker}"
  else
    printf '  \033[1;33m⚠ supabase-db läuft noch nicht — Marker NICHT gesetzt (Unit kam nicht hoch?).\033[0m\n'
  fi
}

# ================================================================
# MEHRFACHAUSWAHL-TUI (Pure Bash, keine neue apt-Dependency)
# §4 BOOTSTRAP_MENU_V2_KONZEPT.md
#
# Bedienung:
#   ↑/↓  Cursor bewegen      (ESC-Sequenz via read -rsn)
#   SPC  Eintrag togglen     (▣/□)
#   RET  Auswahl starten
#   q/Q  Abbrechen
#
# Degradations-Fallback (kein TTY/kein ANSI): Nummern-Toggle-Menü.
#
# Eingabe-Zeile          Services die gestartet werden  Default
# ─────────────────────────────────────────────────────────────
# brew_assistent+Supa    web_assistent supabase-kong    nein
# RAPT Dashboard         web_rapt                       nein
# brew-proxy (API)       api_proxy                      nein
# WebPageAlexStuder      web_hauptseite                 nein
# Watchtower             watchtower                     JA
# Portainer              portainer/portainer_edge_agent JA
#
# cloudflared wird immer automatisch mitgestartet (kein Eintrag im Menü).
# ================================================================

# Einheiten-Definition (parallel arrays)
_TUI_LABELS=(
  "brew_assistent + Supabase"
  "RAPT Dashboard"
  "brew-proxy (API)"
  "WebPageAlexStuder"
  "Watchtower (Auto-Update)"
  "Portainer (Container-Uebersicht)"
)
# Default-Vorauswahl: Indices 0-based; 4=Watchtower, 5=Portainer
_TUI_DEFAULTS=(0 0 0 0 1 1)

# ---------------------------------------------------------------- Portainer-Rollen-Erkennung
# §5.3 — bestimmt hub|agent|skip; nutzt PORTAINER_ROLE aus .env (auto|hub|agent).
# Gibt in $1 (nameref) den ermittelten Modus zurück: "hub", "agent", oder "skip" (Fehler).
_portainer_determine_role() {
  local -n _role_out=$1

  # Vars aus .env lesen (defensiv, kein set -a/source)
  local role_env server_url
  role_env="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
grep -E '^PORTAINER_ROLE=[[:print:]]' "$APP_DIR/.env" | head -1 | cut -d= -f2- || true
EOSU
)"
  server_url="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
grep -E '^PORTAINER_SERVER_URL=[[:print:]]' "$APP_DIR/.env" | head -1 | cut -d= -f2- || true
EOSU
)"
  server_url="${server_url:-https://portainer.alexstuder.cloud}"
  role_env="${role_env:-auto}"

  case "$role_env" in
    hub)
      ok "PORTAINER_ROLE=hub — dieser VPS wird Hub"
      _role_out="hub"
      return 0
      ;;
    agent)
      ok "PORTAINER_ROLE=agent — dieser VPS wird Edge-Agent"
      _role_out="agent"
      return 0
      ;;
    auto)
      : ;;  # Probe unten
    *)
      printf '  \033[1;33m⚠ Unbekannter PORTAINER_ROLE-Wert "%s" — erwarte auto|hub|agent.\033[0m\n' "$role_env"
      _role_out="skip"
      return 0
      ;;
  esac

  # Probe: Hub-Endpoint testen (3s Timeout)
  # http_code und curl-Exit-Code getrennt erfassen, damit "000" und "Verbindungsfehler"
  # nicht zu "000ERR" konkateniert werden (set -e: Command-Substitution killt das Script
  # nicht, aber curl_rc=$? muss unmittelbar danach stehen).
  log "Portainer Hub-Probe: ${server_url}"
  local probe_status curl_rc
  probe_status="$(curl -o /dev/null -sS -w '%{http_code}' -m 3 "${server_url}" 2>/dev/null)"
  curl_rc=$?

  if [[ "$probe_status" =~ ^[2-5][0-9][0-9]$ ]]; then
    # Hub antwortet mit einem echten HTTP-Status → Agent werden
    ok "Hub antwortet (HTTP ${probe_status}) → dieser VPS wird Edge-Agent"
    _role_out="agent"
  elif [[ "$probe_status" == "000" ]] && (( curl_rc != 28 )); then
    # 000 + kein Timeout → Connection refused / NXDOMAIN → Hub noch nicht da → Hub werden
    ok "Hub antwortet nicht (HTTP 000, rc=${curl_rc}) → dieser VPS errichtet den Hub"
    _role_out="hub"
  else
    # curl_rc==28 (Timeout) oder sonstiger unklarer Zustand → Zweit-Hub-Schutz, Abbruch
    printf '\n\033[1;33m⚠ Portainer-Probe-Ergebnis unklar (HTTP %s, rc=%d).\033[0m\n' \
      "$probe_status" "$curl_rc"
    printf '  Sicherheits-Abbruch: bei auto-Modus wird kein Zweit-Hub gebaut wenn der\n'
    printf '  Hub nur kurz nicht erreichbar ist (False-Negative-Schutz).\n'
    printf '  Loesung: PORTAINER_ROLE=hub ODER =agent explizit in .env setzen und\n'
    printf '  Bootstrap erneut starten.\n\n'
    _role_out="skip"
  fi
}

# ---------------------------------------------------------------- Portainer-Hub starten (idempotent)
# Prueft ob Container bereits laeuft; falls nein, startet via docker compose.
_portainer_start_hub() {
  log "Portainer Hub starten"

  # Idempotenz: bereits laufend?
  local running=0
  sudo -u "$APP_USER" bash <<'EOSU' 2>/dev/null && running=1 || running=0
docker inspect --format='{{.State.Running}}' portainer 2>/dev/null | grep -q '^true$'
EOSU
  if (( running == 1 )); then
    ok "Portainer Hub laeuft bereits — nicht erneut aufgesetzt"
    return 0
  fi

  sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose --profile vps --profile portainer-hub pull portainer 2>/dev/null || docker compose --profile portainer-hub pull portainer
docker compose --profile vps --profile portainer-hub up -d portainer cloudflared
EOSU
  ok "Portainer Hub gestartet"
  printf '\n  \033[1;33m⚠ CREDENTIAL-SCHRITTE (Portainer Hub, einmalig):\033[0m\n'
  printf '  1. Portainer-Admin-Passwort im ersten UI-Login setzen:\n'
  printf '     https://portainer.alexstuder.cloud\n'
  printf '  2. Wiederverwendbaren Edge-Key (AEEC) erzeugen:\n'
  printf '     Portainer UI → Environments → Edge Environments → "Add Environment"\n'
  printf '     → Edge Agent → "Reuse existing key" oder neuen AEEC-Key generieren.\n'
  printf '  3. Key in .env eintragen: PORTAINER_EDGE_KEY=<key>\n'
  printf '     Dann .env.gpg neu verschluesseln: ./scripts/encrypt-env.sh\n'
  printf '     (Passphrase aus Bitwarden: ALEXSTUDER_WEBPAGE_GPG_PASSWORD)\n'
  printf '\n  \033[1;32m  ✓ Cloudflare Access-Policy wird automatisch angelegt:\033[0m\n'
  printf '     Der nachfolgende Reconcile (cf_reconcile_if_token) erstellt eine\n'
  printf '     self-hosted Access-App fuer portainer.alexstuder.cloud und eine\n'
  printf '     Allow-Policy fuer PORTAINER_ACCESS_EMAIL (Default: alex@alexstuder.ch).\n'
  printf '     Voraussetzung: Token-Scope "Access: Apps and Policies: Edit" +\n'
  printf '     Zero Trust Team-Domain im Cloudflare-Account aktiviert.\n'
  printf '  Hinweis: portainer.+edge. Hostnames werden vom Reconcile NUR auf diesem\n'
  printf '  Hub-VPS beansprucht (PORTAINER_ROLE=hub Gate in cloudflare-routes.json).\n\n'
}

# ---------------------------------------------------------------- Portainer Edge-Agent starten (idempotent)
_portainer_start_agent() {
  log "Portainer Edge-Agent starten"

  # Edge-Key aus .env lesen — NICHT in argv/log ausgeben
  local edge_key
  edge_key="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
grep -E '^PORTAINER_EDGE_KEY=[[:print:]]' "$APP_DIR/.env" | head -1 | cut -d= -f2- || true
EOSU
)"
  if [[ -z "$edge_key" ]]; then
    printf '\n\033[1;31m✖ PORTAINER_EDGE_KEY ist nicht in .env gesetzt.\033[0m\n'
    printf '  Ablauf:\n'
    printf '    1. Erst Hub-VPS bootstrappen (Portainer Server hochziehen).\n'
    printf '    2. Edge-Key aus Portainer-UI holen (AEEC-Key).\n'
    printf '    3. PORTAINER_EDGE_KEY=<key> in .env eintragen.\n'
    printf '    4. .env.gpg neu verschluesseln (encrypt-env.sh, Credential-Schritt).\n'
    printf '    5. Bootstrap auf diesem VPS erneut starten.\n'
    printf '  Portainer-Agent-Start wird uebersprungen.\n\n'
    return 0
  fi

  # Idempotenz: bereits laufend?
  local running=0
  sudo -u "$APP_USER" bash <<'EOSU' 2>/dev/null && running=1 || running=0
docker inspect --format='{{.State.Running}}' portainer_edge_agent 2>/dev/null | grep -q '^true$'
EOSU
  if (( running == 1 )); then
    ok "Portainer Edge-Agent laeuft bereits — nicht erneut aufgesetzt"
    return 0
  fi

  sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose --profile portainer-agent pull portainer_edge_agent 2>/dev/null || docker compose --profile portainer-agent pull portainer_edge_agent
# Kein Inbound-Port noetig — Edge-Agent pollt ausgehend.
# --profile portainer-agent: aktiviert den Service (der sonst nicht im Default-Set ist).
# Key-Validierung erfolgt bereits oben via edge_key-Guard — compose braucht kein :? mehr.
# Kein --profile vps: Agent-VPS startet cloudflared fuer seine Apps separat via TUI-Pfad.
docker compose --profile portainer-agent up -d portainer_edge_agent
EOSU
  ok "Portainer Edge-Agent gestartet (verbindet sich ausgehend zum Hub)"
}

# ---------------------------------------------------------------- TUI-Renderer (ANSI-Modus)
# Zeichnet die Liste in-place: bewegt Cursor n Zeilen hoch, dann neu zeichnen.
# $1 = aktueller Cursor-Index (0-basiert)
# $2 = nameref auf selected-Array (0/1 je Eintrag)
# $3 = Anzahl zuvor gezeichneter Zeilen (0 beim ersten Mal)
_tui_draw() {
  local cursor_idx=$1
  local -n _sel=$2
  local prev_lines=$3
  local n=${#_TUI_LABELS[@]}

  # Cursor zurueck an Anfang der Liste (prev_lines Zeilen hoch)
  if (( prev_lines > 0 )); then
    printf '\033[%dA' "$prev_lines"
  fi

  local i
  for (( i=0; i<n; i++ )); do
    # Marker: ▣ (gewählt) oder □ (nicht gewählt)
    local marker
    if (( _sel[i] == 1 )); then
      marker='\033[1;32m▣\033[0m'   # gruen
    else
      marker='□'
    fi
    # Cursor-Prefix
    local prefix
    if (( i == cursor_idx )); then
      prefix='\033[1;33m→\033[0m '
    else
      prefix='  '
    fi
    # Aktive Zeile gelb
    if (( i == cursor_idx )); then
      printf "  %b \033[1;33m%-40s\033[0m\n" "$prefix$marker" "${_TUI_LABELS[$i]}"
    else
      printf "  %b %-40s\n" "$prefix$marker" "${_TUI_LABELS[$i]}"
    fi
  done
  printf '  \033[2m[SPC]=togglen  [↑↓]=bewegen  [RET]=starten  [q]=abbrechen\033[0m\n'
}

# ---------------------------------------------------------------- TUI-Haupt-Schleife (ANSI-Modus)
# Gibt in $1 (nameref) ein Array selected[] zurueck (1=gewaehlt).
# Rueckgabewert: 0=Start, 1=Abbrechen
_tui_interactive() {
  local -n _result=$1
  local n=${#_TUI_LABELS[@]}
  local cursor=0
  # Default-Vorauswahl kopieren
  local selected=("${_TUI_DEFAULTS[@]}")
  local prev_lines=0

  # stty-Settings sichern, dann raw-Modus (kein Newline noetig fuer Tastendruck).
  # Einklinken in die bestehende CLEANUP_FILES/_cleanup-Kette:
  # Wir erweitern die EXIT-trap temporaer um den stty-Restore, damit beim Abbruch
  # (Ctrl-C / err() → exit) das Terminal nicht im raw-Modus bleibt.
  # Nach normalem TUI-Ende wird der stty explizit restored und die Trap wieder auf
  # _cleanup gesetzt.
  local stty_save
  stty_save="$(stty -g 2>/dev/null)" || stty_save=""
  if [[ -n "$stty_save" ]]; then
    # shellcheck disable=SC2064
    trap "stty '${stty_save}' 2>/dev/null; _cleanup" EXIT
    stty -echo -icanon min 1 time 0 2>/dev/null || true
  fi

  printf '\n\033[1;34m▶ Einheiten auswaehlen & starten\033[0m\n'
  printf '  cloudflared wird immer automatisch mitgestartet.\n\n'

  # Erste Zeichnung
  _tui_draw "$cursor" selected 0
  prev_lines=$(( n + 1 ))  # n Eintrags-Zeilen + 1 Hilfszeile

  local result=1  # Default: abgebrochen
  while true; do
    local ch rest
    IFS= read -rsn1 ch

    case "$ch" in
      $'\033')
        # ESC-Sequenz: zwei weitere Zeichen mit kurzem Timeout nachlesen
        IFS= read -rsn2 -t 0.05 rest 2>/dev/null || rest=""
        case "$rest" in
          '[A')  # Pfeil hoch
            (( cursor > 0 )) && (( cursor-- )) || cursor=$(( n - 1 ))
            ;;
          '[B')  # Pfeil runter
            (( cursor < n-1 )) && (( cursor++ )) || cursor=0
            ;;
          *)
            # Unbekannte Sequenz: schlucken
            ;;
        esac
        ;;
      ' ')
        # Leertaste: togglen
        if (( selected[cursor] == 0 )); then
          selected[$cursor]=1
        else
          selected[$cursor]=0
        fi
        ;;
      '' | $'\n' | $'\r')
        # Enter: Auswahl bestaetigen
        result=0
        break
        ;;
      q|Q)
        result=1
        break
        ;;
      *)
        # Unbekannte Zeichen: schlucken
        ;;
    esac

    _tui_draw "$cursor" selected "$prev_lines"
    prev_lines=$(( n + 1 ))
  done

  # stty wiederherstellen
  [[ -n "$stty_save" ]] && stty "$stty_save" 2>/dev/null || true
  # EXIT-trap zurueck auf Basis-Cleanup (stty ist schon restored)
  # shellcheck disable=SC2064
  trap "_cleanup" EXIT

  printf '\n'

  # Ergebnis kopieren
  _result=("${selected[@]}")
  return "$result"
}

# ---------------------------------------------------------------- Fallback: Nummern-Toggle (kein TTY)
# Kein interaktiver TTY oder ANSI: zeilenbasiertes Toggle-Menue.
# Gibt in $1 (nameref) ein Array selected[] zurueck.
# Rueckgabewert: 0=Start, 1=Abbrechen
_tui_fallback() {
  local -n _result_fb=$1
  local n=${#_TUI_LABELS[@]}
  local selected=("${_TUI_DEFAULTS[@]}")

  printf '\n\033[1;34m▶ Einheiten auswaehlen & starten (Text-Modus)\033[0m\n'
  printf '  Eintraege durch Tippen der Nummern togglen.\n'
  printf '  cloudflared wird immer automatisch mitgestartet.\n\n'

  while true; do
    local i
    for (( i=0; i<n; i++ )); do
      local mk
      (( selected[i] == 1 )) && mk="[x]" || mk="[ ]"
      printf '  %d) %s  %s\n' "$(( i+1 ))" "$mk" "${_TUI_LABELS[$i]}"
    done
    printf '\n  Eingabe: Nummer(n) zum Togglen (1-%d), a=alle, RET/leer=Starten, q=Abbrechen: ' "$n"

    local ans
    IFS= read -r ans

    case "$ans" in
      q|Q)
        _result_fb=("${selected[@]}")
        return 1
        ;;
      ''|$'\n')
        break
        ;;
      a|A)
        for (( i=0; i<n; i++ )); do selected[$i]=1; done
        ;;
      *)
        # Nummern-Liste auswerten (mehrere Nummern moeglich, leerzeichen-getrennt).
        # read -ra verhindert Glob-Expansion (z.B. bei Eingabe "*" oder "?").
        local -a nums
        read -ra nums <<< "$ans"
        local num
        for num in "${nums[@]}"; do
          if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= n )); then
            local idx=$(( num - 1 ))
            if (( selected[idx] == 0 )); then
              selected[$idx]=1
            else
              selected[$idx]=0
            fi
          else
            printf '  Unbekannte Eingabe: %s (ignoriert)\n' "$num"
          fi
        done
        ;;
    esac
    printf '\n'
  done

  _result_fb=("${selected[@]}")
  return 0
}

# ================================================================
# AKTION: Einheiten auswaehlen und starten (TUI-Dispatch)
# Zusammenlegung der heutigen Punkte 1+2 (§3.1 BOOTSTRAP_MENU_V2_KONZEPT.md).
# ================================================================
action_select_and_start() {
  # TUI-Modus bestimmen: interaktives TTY + ANSI? → volle TUI; sonst Fallback.
  local selected=()
  local tui_exit=1

  if [[ -t 0 && -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    # Interaktiver Modus
    if _tui_interactive selected; then
      tui_exit=0
    else
      tui_exit=1
    fi
  else
    # Kein TTY oder kein ANSI → Fallback
    printf '  (Kein interaktives Terminal erkannt — Text-Modus)\n'
    if _tui_fallback selected; then
      tui_exit=0
    else
      tui_exit=1
    fi
  fi

  if (( tui_exit != 0 )); then
    echo "  Abgebrochen — kein Start."
    return 0
  fi

  # ---- Service-Liste aufbauen aus der Auswahl ----
  # Mapping Index → Services (0-basiert):
  #   0 = brew_assistent+Supabase  → web_assistent supabase-kong
  #   1 = RAPT Dashboard           → web_rapt
  #   2 = brew-proxy               → api_proxy
  #   3 = WebPageAlexStuder        → web_hauptseite
  #   4 = Watchtower               → watchtower
  #   5 = Portainer                → portainer ODER portainer_edge_agent (Rolle-Logik)
  #
  # cloudflared wird IMMER angehaengt (kein Eintrag im Menue).

  # Service-Liste als assoziatives Set (via string-Suche verhindert Duplikate)
  local svc_list=""
  # Merker: wurde supabase-kong explizit oder via Abhaengigkeit aufgenommen?
  local has_supabase=0
  local has_portainer=0
  local portainer_role=""

  # Eintrag 0: brew_assistent + Supabase
  if (( selected[0] == 1 )); then
    log "brew_assistent + Supabase ausgewaehlt"
    echo "  Services: web_assistent supabase-kong (depends_on zieht Supabase-Core mit)"
    svc_list="${svc_list} web_assistent supabase-kong"
    has_supabase=1
  fi

  # Eintrag 1: RAPT Dashboard
  if (( selected[1] == 1 )); then
    log "RAPT Dashboard ausgewaehlt"
    svc_list="${svc_list} web_rapt"
  fi

  # Eintrag 2: brew-proxy — prueft ob Supabase laeuft
  if (( selected[2] == 1 )); then
    log "brew-proxy (api_proxy) ausgewaehlt"
    echo "  Pruefe, ob supabase-db laeuft..."
    local supabase_running=0
    sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU' && supabase_running=1 || supabase_running=0
docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null | grep -q '^true$'
EOSU
    if (( supabase_running == 0 && has_supabase == 0 )); then
      printf '  \033[1;33m⚠ supabase-db laeuft nicht und wurde nicht mitausgewaehlt —\033[0m\n'
      printf '  \033[1;33m  supabase-kong wird automatisch mitgestartet (brew-proxy braucht Supabase).\033[0m\n'
      svc_list="${svc_list} supabase-kong"
      has_supabase=1
    elif (( supabase_running == 1 )); then
      echo "  Supabase laeuft bereits — kein Mitstart noetig."
    fi
    svc_list="${svc_list} api_proxy"
  fi

  # Eintrag 3: WebPageAlexStuder
  if (( selected[3] == 1 )); then
    log "WebPageAlexStuder ausgewaehlt"
    svc_list="${svc_list} web_hauptseite"
  fi

  # Eintrag 4: Watchtower (an profiles: [vps] gebunden — --profile vps starten)
  if (( selected[4] == 1 )); then
    log "Watchtower ausgewaehlt"
    svc_list="${svc_list} watchtower"
  fi

  # Eintrag 5: Portainer — Rolle bestimmen, dann separater Start nach compose up
  if (( selected[5] == 1 )); then
    log "Portainer ausgewaehlt — Rolle bestimmen"
    _portainer_determine_role portainer_role
    has_portainer=1
    # Portainer-Services werden NACH dem allgemeinen compose-up separat gestartet
    # (Hub vs. Agent erfordert unterschiedliche Logik)
  fi

  # Keine Auswahl? Nur cloudflared starten wuerde keinen Sinn ergeben.
  local svc_trimmed="${svc_list# }"
  if [[ -z "$svc_trimmed" && "$has_portainer" -eq 0 ]]; then
    printf '  Keine Services ausgewaehlt — nichts zu starten.\n'
    return 0
  fi

  # ---- Tunnel sicherstellen ----
  cf_ensure_tunnel_if_token

  # ---- Services starten (Duplikate via sort -u entfernen) ----
  # Service-Liste bereinigen: Leerzeichen normalisieren, Duplikate entfernen.
  # tr + sort -u produziert eine korrekte eindeutige Liste.
  local unique_svcs=""
  if [[ -n "$svc_trimmed" ]]; then
    # Word-splitting ist hier BEABSICHTIGT: $svc_trimmed ist eine Leerzeichen-getrennte
    # Service-Liste die wir in einzelne Zeilen aufteilen wollen. Kein Glob-Risiko
    # (Service-Namen enthalten keine Glob-Sonderzeichen).
    # shellcheck disable=SC2086
    unique_svcs="$(printf '%s\n' $svc_trimmed | sort -u | tr '\n' ' ')"
    unique_svcs="${unique_svcs% }"
  fi

  if [[ -n "$unique_svcs" ]]; then
    log "Starte Services: ${unique_svcs} cloudflared"
    # --profile vps: benoetigt fuer watchtower und cloudflared (profiles: [vps]).
    # Schadet nicht fuer reine App-Services.
    sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" SVCS="$unique_svcs" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
# pull: Service-Liste ohne cloudflared (cloudflared wird getrennt via --profile vps up gestartet)
# shellcheck disable=SC2086
docker compose --profile vps pull $SVCS cloudflared
# shellcheck disable=SC2086
docker compose --profile vps up -d $SVCS cloudflared
EOSU
  else
    # Nur Portainer: sicherstellen dass cloudflared laeuft
    log "Nur Portainer ausgewaehlt — cloudflared sicherstellen"
    sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose --profile vps pull cloudflared
docker compose --profile vps up -d cloudflared
EOSU
  fi

  # ---- Supabase-Marker setzen (falls supabase-kong gestartet wurde) ----
  if (( has_supabase == 1 )); then
    _ensure_supabase_marker
  fi

  # ---- Portainer starten (nach compose up, damit cloudflared bereits laeuft) ----
  if (( has_portainer == 1 )); then
    case "$portainer_role" in
      hub)
        _portainer_start_hub
        ;;
      agent)
        _portainer_start_agent
        ;;
      skip)
        printf '  \033[1;33m⚠ Portainer-Start uebersprungen (Rolle unklar — siehe Meldung oben).\033[0m\n'
        ;;
    esac
  fi

  # ---- Cloudflare Reconcile ----
  cf_reconcile_if_token
}

# ---------------------------------------------------------------- SSH-Verbindung zum alten VPS prüfen
# Gibt 0 zurück wenn OK, 1 bei Fehler.
_check_ssh_access() {
  local user="$1" host="$2" port="$3"
  ssh -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      -p "$port" \
      "${user}@${host}" true 2>/dev/null
}

# ---------------------------------------------------------------- R2-Setup für Verifikation
# Setzt RCLONE_CONFIG_R2_* aus .env (gleiche Logik wie backup.sh/restore.sh).
# Prüft alle drei pre-migration-Dumps der supabase-Unit in R2:
#   core (_supabase_core), brew_assistent, rapt_dashboard.
# Gibt drei Dateinamen (je eine Zeile) zurück oder schlägt fehl.
# Fehler-Diskriminierung: SSH-/Netzwerk-Fehler → return 2 (sofortiger Abbruch);
# Backup nicht gefunden → return 1 (Aufrufer meldet).
_verify_backup_in_r2() {
  # Aufruf: _verify_backup_in_r2 <old_user> <old_host> <old_port>
  local old_user="$1" old_host="$2" old_port="$3"

  local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

  # Hilfsfunktion: sucht in einem R2-Ordner nach dem jüngsten pre-migration-Dump.
  # Gibt Dateinamen oder leeren String aus. Fehler → return 2.
  # $1=folder (whitelist-geprüft: nur [a-zA-Z0-9_-])
  #
  # C2: Remote-Kommandos laufen unter set -euo pipefail via bash -s Heredoc —
  # ein fehlschlagendes rclone lsf wird nicht durch grep's Exit-Code maskiert.
  # I2: $folder wird als Env-Variable übergeben (FOLDER="$folder") statt direkt
  # in den Command-String konkateniert → keine String-Interpolations-RCE-Lücke.
  _r2_find_premig() {
    local folder="$1"
    [[ "$folder" =~ ^[a-zA-Z0-9_-]+$ ]] \
      || { printf '\033[1;31m✖ Interner Fehler: ungültiger R2-Ordnerwert: %s\033[0m\n' "$folder" >&2; return 2; }
    local _out
    _out="$(ssh "${ssh_opts[@]}" -p "$old_port" "${old_user}@${old_host}" \
              FOLDER="$folder" bash -s <<'REMOTE'
set -euo pipefail
cd ~/webPage_infra
set -a
# shellcheck disable=SC1091
source .env
set +a
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?fehlt in .env auf altem VPS}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?fehlt in .env auf altem VPS}"
export RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
_ep="${R2_ENDPOINT:-}"
if [[ -z "$_ep" ]]; then
  _ep="https://${R2_ACCOUNT_ID:?fehlt in .env auf altem VPS}.r2.cloudflarestorage.com"
fi
export RCLONE_CONFIG_R2_ENDPOINT="$_ep"
# C2-Fix: rclone lsf zuerst in Variable fangen — set -e bricht bei rclone-Fehler hart ab
# (Exit != 0 propagiert durch $() direkt zum Remote-Shell, SSH gibt non-zero zurück).
# grep | tail -1 || true NUR auf die Variable anwenden: kein Match = leerer String = OK.
lsf_out="$(rclone lsf "R2:${R2_BUCKET}/${FOLDER}/" --include '*.fc.gpg')"
printf '%s\n' "$lsf_out" | sort | grep '_pre-migration' | tail -1 || true
REMOTE
    )" \
      || { printf '\033[1;31m✖ SSH/rclone-Fehler beim Suchen in R2-Ordner %s (Exit %s) — SSH-Zugang oder rclone/R2-Setup auf altem VPS prüfen.\033[0m\n' "$folder" "$?" >&2; return 2; }
    printf '%s' "$_out"
  }

  local core_file assistent_file rapt_file
  core_file="$(_r2_find_premig "_supabase_core")" || return 2
  assistent_file="$(_r2_find_premig "brew_assistent")" || return 2
  rapt_file="$(_r2_find_premig "rapt_dashboard")" || return 2

  local missing=0
  if [[ -z "$core_file" ]]; then
    printf '\033[1;31m✖ core-Dump mit Label "pre-migration" nicht in R2 gefunden (R2:<bucket>/_supabase_core/).\033[0m\n' >&2
    missing=1
  fi
  if [[ -z "$assistent_file" ]]; then
    printf '\033[1;31m✖ brew_assistent-Dump mit Label "pre-migration" nicht in R2 gefunden (R2:<bucket>/brew_assistent/).\033[0m\n' >&2
    missing=1
  fi
  if [[ -z "$rapt_file" ]]; then
    printf '\033[1;31m✖ rapt_dashboard-Dump mit Label "pre-migration" nicht in R2 gefunden (R2:<bucket>/rapt_dashboard/).\033[0m\n' >&2
    missing=1
  fi
  (( missing == 0 )) || return 1

  # Gibt drei Dateinamen aus (eine Zeile pro Datei: core, brew_assistent, rapt_dashboard)
  printf '%s\n%s\n%s\n' "$core_file" "$assistent_file" "$rapt_file"
}

# ---------------------------------------------------------------- Migrations-Aktion
# Migriert die gesamte Supabase / DB-Unit (core + aibrewgenius + rapt — alle Schemen).
# Supabase ist die EINZIGE stateful Unit; brew_assistent/rapt_dashboard sind zustandslos
# (kein Backup/Restore fuer Frontends — die werden via action_select_and_start neu gestartet).
action_migrate_unit() {
  printf '\n\033[1;34m▶ Was migrieren?\033[0m\n\n'
  printf '  1) Supabase / DB migrieren   (core + aibrewgenius + rapt — gesamte DB)\n'
  printf '  b) zurück\n\n'
  printf '  Hinweis: brew_assistent, rapt_dashboard, brew-proxy und WebPageAlexStuder\n'
  printf '           sind zustandslos — kein Backup/Restore nötig. Auf dem Ziel-VPS\n'
  printf '           via "Einheiten auswaehlen & starten" (Option 1) starten.\n\n'
  read -rp "Auswahl [1,b]: " mig_choice

  case "$mig_choice" in
    1) : ;;  # weiter unten behandelt
    b|B)
      return 0
      ;;
    *)
      printf '  Ungültige Eingabe: %s\n' "$mig_choice"
      return 0
      ;;
  esac

  # ---- SSH-Verbindungsdaten abfragen
  printf '\n\033[1;34m▶ Verbindung zum alten VPS (Quell-VPS mit supabase-db)\033[0m\n\n'
  local old_host old_user old_port
  read -rp "Hostname / IP des alten VPS: " old_host
  [[ -n "$old_host" ]] || err "Kein Host eingegeben"
  # I1: Whitelist-Validierung — verhindert Shell-Injection via Tippfehler wie
  # "192.168.1.1; rm -rf ~" die ohne Whitelist lokal ausgeführt würden.
  [[ "$old_host" =~ ^[a-zA-Z0-9._-]+$ ]] \
    || err "Ungültiger Hostname/IP: '$old_host' (erlaubt: A-Z a-z 0-9 . _ -)"
  read -rp "SSH-User auf altem VPS [alex]: " old_user
  old_user="${old_user:-alex}"
  read -rp "SSH-Port [22]: " old_port
  old_port="${old_port:-22}"
  [[ "$old_port" =~ ^[0-9]+$ ]] || err "Ungültiger SSH-Port: $old_port"

  # ---- SSH-Zugang prüfen (BatchMode=yes — kein Passwort-Prompt)
  log "SSH-Zugang zu ${old_user}@${old_host}:${old_port} prüfen"
  if ! _check_ssh_access "$old_user" "$old_host" "$old_port"; then
    err "Kein passwortloser SSH-Zugang zu ${old_user}@${old_host}:${old_port}.
   Credential-Schritt (vor erneuter Migration erledigen):
     1. Auf diesem (neuen) VPS: cat ~/.ssh/id_*.pub   (oder ssh-keygen falls kein Key)
     2. Auf dem alten VPS als ${old_user}: mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys
        und den Public-Key einfügen.
   Alternativ: ssh-copy-id -p ${old_port} ${old_user}@${old_host}"
  fi
  ok "SSH-Zugang OK"

  # ---- Supabase-Core-Überschreib-Schutz
  # Vor dem core-Restore prüfen, ob auf dem NEUEN VPS bereits auth.users existieren.
  # Wenn ja: Abbruch statt blindes Überschreiben (könnte fremde User zerstören).
  #
  # Zwei getrennte Checks:
  #   1. Läuft supabase-db überhaupt?
  #   2. .env laden + COUNT abfragen.
  # Trennung verhindert, dass ein .env-Fehler als "existing_users=0" maskiert wird
  # und ein destruktiver Restore ohne Warnung durchläuft.
  log "Supabase-Core-Konflikt-Schutz: auth.users auf neuem VPS prüfen"
  local existing_users=0 db_running=0
  sudo -u "$APP_USER" -H bash <<'EOSU' 2>/dev/null && db_running=1 || db_running=0
docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null | grep -q '^true$'
EOSU

  if (( db_running == 1 )); then
    existing_users="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
[[ -f .env ]] || { printf 'FEHLER: .env fehlt in %s — Migration nicht sicher fortsetzbar.\n' "$APP_DIR" >&2; exit 1; }
set -a; source .env; set +a
[[ -n "${POSTGRES_PASSWORD:-}" ]] || { printf 'FEHLER: POSTGRES_PASSWORD nicht in .env gesetzt.\n' >&2; exit 1; }
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" supabase-db \
  psql -tA -U supabase_admin -d postgres \
  -c "SELECT count(*) FROM auth.users;"
EOSU
)"
    existing_users="${existing_users//[[:space:]]/}"
    if [[ "$existing_users" =~ ^[0-9]+$ ]] && (( existing_users > 0 )); then
      printf '\n\033[1;31m✖ KONFLIKT: Auf dem neuen VPS existieren bereits %s auth.users.\033[0m\n' "$existing_users"
      printf '  Ein core-Restore (--clean) würde diese überschreiben.\n'
      printf '  Szenarien:\n'
      printf '  a) Neuer VPS ist dediziert für diese Migration → Benutzer explizit löschen, dann erneut starten.\n'
      printf '  b) Neuer VPS läuft bereits mit einer anderen App → Vorsicht: Restore würde diese App-Daten zerstören.\n\n'
      read -rp "Migration trotzdem fortsetzen? Tippe 'force-core' zum Bestätigen oder Enter zum Abbrechen: " force_ans
      if [[ "$force_ans" != "force-core" ]]; then
        err "Migration abgebrochen (core-Überschreib-Schutz)."
      fi
      printf '  \033[1;33m⚠ WARNUNG: Fortfahren — bestehende auth.users werden durch Restore überschrieben.\033[0m\n'
    fi
  else
    echo "  supabase-db läuft noch nicht auf neuem VPS — core-Restore unkritisch."
  fi

  # ---- Zusammenfassung + Bestätigung vor destruktivem Teil
  printf '\n\033[1;34m▶ Migrations-Plan — bitte bestätigen\033[0m\n\n'
  printf '  Alter VPS (Quell-VPS):  %s@%s (Port %s)\n' "$old_user" "$old_host" "$old_port"
  printf '  Umzug:   Supabase / gesamte DB (core + aibrewgenius + rapt)\n'
  printf '  Schritte:\n'
  printf '    (a) Backup auf altem VPS (--label pre-migration) + R2-Verifikation aller 3 Dumps\n'
  printf '    (b) Supabase-Stack auf altem VPS stoppen (supabase-db + Frontend)\n'
  printf '    (c) Supabase auf neuem VPS hochziehen\n'
  printf '    (d) Alle 3 Dumps restoren (core → brew_assistent → rapt_dashboard) via --clean\n'
  printf '    (e) supabase-Marker auf altem VPS entfernen (Backup wird No-op)\n'
  printf '    (f) supabase-Marker auf neuem VPS sicherstellen\n\n'
  printf '  ACHTUNG: Schritt (d) überschreibt vorhandene Daten auf dem neuen VPS.\n'
  printf '  Rollback: Supabase auf altem VPS neu starten + Marker wiederherstellen.\n\n'
  read -rp "Migration starten? Tippe 'migrate' zum Bestätigen: " migrate_ans
  [[ "$migrate_ans" == "migrate" ]] || { echo "  Abgebrochen."; return 0; }

  # ===========================================================================
  # SCHRITT (a) — Backup auf altem VPS erstellen
  # ===========================================================================
  log "(a) Frisches Backup auf altem VPS erstellen (--label pre-migration)"
  ssh -o BatchMode=yes -o ConnectTimeout=30 \
      -o StrictHostKeyChecking=accept-new \
      -p "$old_port" "${old_user}@${old_host}" \
      'cd ~/webPage_infra && ./scripts/backup.sh --label pre-migration' \
    || err "Backup auf altem VPS fehlgeschlagen — Migration abgebrochen. Alter Stand bleibt laufend."
  ok "(a) Backup erstellt"

  # ===========================================================================
  # SCHRITT (a) VERIFIKATION — alle drei pre-migration-Dumps in R2 prüfen
  # ===========================================================================
  log "(a) Verifikation: alle drei pre-migration-Dumps in R2 suchen"
  local verify_out
  local core_dump_name assistent_dump_name rapt_dump_name
  if ! verify_out="$(_verify_backup_in_r2 "$old_user" "$old_host" "$old_port")"; then
    err "R2-Verifikation fehlgeschlagen: nicht alle pre-migration-Dumps in R2 gefunden.
   Migration abgebrochen — alter Stand bleibt laufend.
   Manuell prüfen: ssh ${old_user}@${old_host} 'rclone lsf R2:<bucket>/_supabase_core/ | grep pre-migration'"
  fi

  core_dump_name="$(printf '%s' "$verify_out" | sed -n '1p')"
  assistent_dump_name="$(printf '%s' "$verify_out" | sed -n '2p')"
  rapt_dump_name="$(printf '%s' "$verify_out" | sed -n '3p')"

  ok "(a) Verifikation OK"
  printf '    core:          %s\n' "$core_dump_name"
  printf '    brew_assistent: %s\n' "$assistent_dump_name"
  printf '    rapt_dashboard: %s\n' "$rapt_dump_name"

  # ===========================================================================
  # SCHRITT (b) — Supabase-Stack auf altem VPS stoppen
  # ===========================================================================
  log "(b) Supabase-Stack (supabase-db + Frontends) auf altem VPS stoppen"
  # Supabase-Stack stoppen (inkl. supabase-db): verhindert neue Writes nach dem
  # pre-migration-Backup. Frontends werden ebenfalls gestoppt (zustandslos, kein Datenverlust).
  # 'docker compose stop' ohne Argument stoppt alle laufenden Services in der Compose-Datei.
  # Robuster Ansatz: explizit supabase-db + bekannte Frontend-Services — verhindert
  # versehentliches Stoppen von Services auf dem neuen VPS (falscher Host).
  ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new \
      -p "$old_port" "${old_user}@${old_host}" \
      'cd ~/webPage_infra && docker compose stop supabase-db supabase-kong supabase-auth supabase-rest supabase-realtime supabase-storage supabase-meta supabase-functions web_assistent web_rapt api_proxy 2>/dev/null || true
       docker compose stop 2>/dev/null || true' \
    || err "Stop auf altem VPS fehlgeschlagen. Bitte manuell prüfen: ssh ${old_user}@${old_host} 'cd ~/webPage_infra && docker compose ps'"

  # C1: Separater Verifikations-SSH-Call — NICHT auf Exit-Code von 'docker compose stop'
  # verlassen (der ist immer 0, auch wenn supabase-db noch läuft oder gar nicht existiert).
  # Erst wenn docker inspect bestätigt, dass supabase-db nicht mehr läuft (oder gar nicht
  # existiert), ist der Stop sicher — sonst würde Schritt (d) auf eine noch schreibende DB
  # restoren (pre-migration-Dump ungültig, Datenverlust-Risiko).
  log "(b) Verifikation: supabase-db auf altem VPS wirklich gestoppt?"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=15 \
           -o StrictHostKeyChecking=accept-new \
           -p "$old_port" "${old_user}@${old_host}" bash -s <<'REMOTE'
set -euo pipefail
# Zwei erlaubte Zustände: Container existiert + Running=false  ODER  Container existiert nicht.
state="$(docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null || echo 'absent')"
if [[ "$state" == "false" || "$state" == "absent" ]]; then
  exit 0   # supabase-db gestoppt oder gar nicht vorhanden — Migration sicher
fi
# state == "true" → Container läuft noch
printf 'supabase-db läuft noch (State.Running=%s) — Stop war nicht vollständig.\n' "$state" >&2
exit 1
REMOTE
  then
    err "(b) ABORT: supabase-db auf altem VPS läuft noch — Migration abgebrochen.
   Alter Stand bleibt unverändert (kein Datenverlust).
   Manuell prüfen + ggf. stop wiederholen:
     ssh ${old_user}@${old_host} 'cd ~/webPage_infra && docker compose stop supabase-db && docker inspect --format={{.State.Running}} supabase-db'"
  fi
  ok "(b) Supabase-Stack auf altem VPS gestoppt + verifiziert"
  printf '  Rollback: ssh %s@%s "cd ~/webPage_infra && docker compose up -d"\n' \
    "$old_user" "$old_host"

  # ===========================================================================
  # SCHRITT (c) — Supabase auf neuem VPS hochziehen
  # ===========================================================================
  log "(c) Supabase auf neuem VPS hochziehen"
  echo "  Services: web_assistent supabase-kong (depends_on zieht Supabase-Core mit)"
  cf_ensure_tunnel_if_token
  sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull web_assistent supabase-kong
docker compose --profile vps up -d web_assistent supabase-kong cloudflared
EOSU
  ok "(c) Supabase auf neuem VPS gestartet"
  # Marker auf neuem VPS sicherstellen (Schritt f wird nach Restore explizit gemacht,
  # aber setzen wir ihn schon hier da supabase-db jetzt läuft)
  _ensure_supabase_marker

  # ===========================================================================
  # SCHRITT (d) — Alle drei Dumps auf neuem VPS restoren
  # ===========================================================================
  log "(d) Alle drei Dumps restoren (core → brew_assistent → rapt_dashboard)"
  # Explizite Dateinamen aus der Verifikation — kein 'latest' (vermeidet Verwechslung
  # mit einem neueren automatischen Dump nach dem pre-migration-Backup).
  # Reihenfolge zwingend: core zuerst (auth.users muss existieren), dann App-Schemen.
  printf '    core:          %s\n' "$core_dump_name"
  printf '    brew_assistent: %s\n' "$assistent_dump_name"
  printf '    rapt_dashboard: %s\n' "$rapt_dump_name"
  echo "  Restore läuft mit --yes (Bestätigung wurde oben eingeholt)."

  sudo -u "$APP_USER" -H \
    APP_DIR="$APP_DIR" \
    CORE_DUMP="${core_dump_name}" \
    ASSISTENT_DUMP="${assistent_dump_name}" \
    RAPT_DUMP="${rapt_dump_name}" \
    bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
set -a; source .env; set +a

# R2-Remote via RCLONE_CONFIG_R2_* aufbauen (gleiche Logik wie backup.sh).
R2_BUCKET="${R2_BUCKET:?fehlt in .env (R2 für Migration)}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?fehlt in .env}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?fehlt in .env}"
_r2_ep="${R2_ENDPOINT:-}"
if [[ -z "$_r2_ep" ]]; then
  R2_ACCOUNT_ID="${R2_ACCOUNT_ID:?fehlt in .env (R2_ENDPOINT oder R2_ACCOUNT_ID nötig)}"
  _r2_ep="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$_r2_ep"
export RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

# Core-Dump lokal laden
CORE_LOCAL="backups/_supabase_core/${CORE_DUMP}"
mkdir -p backups/_supabase_core
rclone copyto "R2:${R2_BUCKET}/_supabase_core/${CORE_DUMP}" "$CORE_LOCAL" \
  || { echo "rclone-Download core fehlgeschlagen" >&2; exit 1; }
echo "  Core-Dump geladen: $CORE_LOCAL"

# brew_assistent-Dump lokal laden
ASSISTENT_LOCAL="backups/brew_assistent/${ASSISTENT_DUMP}"
mkdir -p backups/brew_assistent
rclone copyto "R2:${R2_BUCKET}/brew_assistent/${ASSISTENT_DUMP}" "$ASSISTENT_LOCAL" \
  || { echo "rclone-Download brew_assistent fehlgeschlagen" >&2; exit 1; }
echo "  brew_assistent-Dump geladen: $ASSISTENT_LOCAL"

# rapt_dashboard-Dump lokal laden
RAPT_LOCAL="backups/rapt_dashboard/${RAPT_DUMP}"
mkdir -p backups/rapt_dashboard
rclone copyto "R2:${R2_BUCKET}/rapt_dashboard/${RAPT_DUMP}" "$RAPT_LOCAL" \
  || { echo "rclone-Download rapt_dashboard fehlgeschlagen" >&2; exit 1; }
echo "  rapt_dashboard-Dump geladen: $RAPT_LOCAL"

# Restore: zwingende Reihenfolge core → brew_assistent → rapt_dashboard
# (gleiche Reihenfolge wie restore.sh all — auth.users muss zuerst existieren).
# --yes: Bestätigung wurde interaktiv im Menü bereits eingeholt.
./scripts/restore.sh core "$CORE_LOCAL" --yes
./scripts/restore.sh brew_assistent "$ASSISTENT_LOCAL" --yes
./scripts/restore.sh rapt_dashboard "$RAPT_LOCAL" --yes

echo "  Lokale Dump-Dateien aufräumen..."
rm -f "$CORE_LOCAL" "$ASSISTENT_LOCAL" "$RAPT_LOCAL"
EOSU

  ok "(d) Restore aller drei Dumps abgeschlossen"

  # ===========================================================================
  # SCHRITT (e) — supabase-Marker auf altem VPS entfernen (Backup → No-op)
  # ===========================================================================
  log "(e) supabase-Marker auf altem VPS entfernen"
  # rm -f als alex (owner /etc/brewing/stateful-units.d/) → kein sudo nötig.
  # Danach ist der nächtige Cron-Lauf auf dem alten VPS ein sauberer No-op (Exit 0).
  ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new \
      -p "$old_port" "${old_user}@${old_host}" \
      'rm -f /etc/brewing/stateful-units.d/supabase' \
    || printf '  \033[1;33m⚠ Marker-Entfernen fehlgeschlagen — bitte manuell auf altem VPS: rm -f /etc/brewing/stateful-units.d/supabase\033[0m\n'
  ok "(e) supabase-Marker auf altem VPS entfernt — Backup dort jetzt No-op"

  # ===========================================================================
  # SCHRITT (f) — supabase-Marker auf neuem VPS sicherstellen
  # ===========================================================================
  log "(f) supabase-Marker auf neuem VPS sicherstellen"
  # Wurde schon in Schritt (c) gesetzt — idempotenter Check.
  _ensure_supabase_marker

  # ---------------------------------------------------------------- Cloudflare reconcilen
  cf_reconcile_if_token

  # ---------------------------------------------------------------- Post-Migrations-Hinweise
  printf '\n\033[1;32m  ✓ Migration abgeschlossen — Supabase / DB läuft jetzt auf dem neuen VPS.\033[0m\n\n'

  printf '  Rollback-Info (falls Probleme auftreten):\n'
  printf '    1. Supabase auf altem VPS neu starten:\n'
  printf '       ssh %s@%s "cd ~/webPage_infra && docker compose up -d"\n' "$old_user" "$old_host"
  printf '    2. Marker auf altem VPS wiederherstellen:\n'
  printf '       ssh %s@%s "touch /etc/brewing/stateful-units.d/supabase"\n' "$old_user" "$old_host"
  printf '    3. Marker auf neuem VPS entfernen:\n'
  printf '       rm -f /etc/brewing/stateful-units.d/supabase\n'
  printf '    Der pre-migration-Dump liegt rotation-exempt in R2.\n\n'

  printf '  Zustandslose Frontends verschieben (kein Backup/Restore nötig):\n'
  printf '    brew_assistent / rapt_dashboard / web_hauptseite:\n'
  printf '    → Auf Ziel-VPS: Bootstrap-Menü → "Einheiten auswaehlen & starten" (Option 1)\n'
  printf '    → Auf altem VPS danach stoppen: docker compose stop web_assistent web_rapt web_hauptseite\n\n'

  printf '  Cloudflare-Routing:\n'
  printf '    Auf dem ALTEN VPS den Hostname aus scripts/cloudflare-routes.json entfernen\n'
  printf '    und ./scripts/cloudflare-reconcile.sh ausführen — sonst konkurrierende\n'
  printf '    Tunnel-Ingress-Einträge (beide Tunnel antworten auf denselben Hostname).\n\n'

  printf '  RAPT_DASHBOARD_URL (wenn RAPT auf separatem VPS):\n'
  printf '    In der .env RAPT_DASHBOARD_URL auf die neue URL setzen\n'
  printf '    (https://rapt.alexstuder.cloud o.ä.), dann .env.gpg neu verschlüsseln:\n'
  printf '      ./scripts/encrypt-env.sh   (braucht GPG-Passphrase aus Bitwarden)\n'
  printf '    Credential-Schritt: ALEXSTUDER_WEBPAGE_GPG_PASSWORD aus Bitwarden holen.\n\n'

  # V-10: Wenn Proxy auf einem anderen VPS als die DB landet (DB wurde migriert),
  # muss DATABASE_URL in der .env des Proxy-VPS angepasst werden.
  printf '  Cross-VPS-DB-Hinweis (V-10):\n'
  printf '    Wenn api_proxy auf einem anderen VPS als die DB läuft:\n'
  printf '    DATABASE_URL in .env auf den Cloudflare-TCP-Tunnel-Loopback setzen:\n'
  printf '    DATABASE_URL=postgres://proxy_sync:<PROXY_SYNC_PASSWORD>@host.docker.internal:15432/postgres?sslmode=disable\n'
  printf '    (PROXY_SYNC_PASSWORD ist eine dedizierte Var — nicht POSTGRES_PASSWORD)\n'
  printf '    Dann .env.gpg neu verschlüsseln (encrypt-env.sh, Credential-Schritt).\n\n'
}

# ================================================================
# AKTION: Erstdaten aus R2 wiederherstellen (latest)
#
# Disaster-Recovery- + Erst-Lauf-Pfad: frischer VPS zieht das juengste Backup
# (latest) aus R2 und restored es in zwingender Reihenfolge:
# core → brew_assistent → rapt_dashboard.
#
# Abgrenzung zur Migration (action_migrate_unit): die Migration verlangt einen
# LAUFENDEN alten VPS via SSH (Umzug). DIESER Pfad braucht keinen alten VPS und
# ist daher der einzige Weg, wenn der alte VPS tot/weg ist (Crash-Recovery) oder
# es noch gar keinen gab (Erst-Lauf). Voraussetzung: Backup in R2 vorhanden.
#
# DESTRUKTIV: pg_restore --clean überschreibt vorhandene Objekte.
# Sicherheits-Guards:
#   1. Tippe-"restore"-Prompt (Nicht-TTY ohne --yes → Abbruch).
#   2. auth.users-Check: wenn DB nicht leer → Warnung + "force-restore"-Bestaetigung.
#   3. Leerer Bucket / kein *.fc.gpg in >=1 Ordner → sauberer Skip (kein Abbruch).
# ================================================================
action_restore_from_r2() {

  # ---- Vorbedingungen ----
  log "Vorbedingungen pruefen (R2-Restore)"
  [[ -f "${APP_DIR}/.env" ]] \
    || err "R2-Restore: .env fehlt in ${APP_DIR} — erst Bootstrap vollstaendig durchlaufen."
  command -v docker  >/dev/null 2>&1 || err "R2-Restore: docker fehlt."
  command -v rclone  >/dev/null 2>&1 || err "R2-Restore: rclone fehlt (bootstrap installiert es)."
  command -v gpg     >/dev/null 2>&1 || err "R2-Restore: gpg fehlt."

  # R2-Vars aus .env pruefen (kein :? hier — compose-Lesson; eigener Guard).
  local _r2_check
  _r2_check="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
set -a; source "$APP_DIR/.env"; set +a
missing=""
[[ -n "${R2_ACCESS_KEY_ID:-}"     ]] || missing="${missing} R2_ACCESS_KEY_ID"
[[ -n "${R2_SECRET_ACCESS_KEY:-}" ]] || missing="${missing} R2_SECRET_ACCESS_KEY"
[[ -n "${R2_BUCKET:-}"            ]] || missing="${missing} R2_BUCKET"
# R2_ENDPOINT oder R2_ACCOUNT_ID ist noetig
if [[ -z "${R2_ENDPOINT:-}" && -z "${R2_ACCOUNT_ID:-}" ]]; then
  missing="${missing} R2_ENDPOINT/R2_ACCOUNT_ID"
fi
printf '%s' "${missing# }"
EOSU
)"
  if [[ -n "$_r2_check" ]]; then
    printf '\n\033[1;31m✖ R2-Restore: fehlende .env-Variablen: %s\033[0m\n' "$_r2_check"
    printf '  R2-Creds in .env eintragen, dann .env.gpg neu verschluesseln:\n'
    printf '    ./scripts/encrypt-env.sh\n\n'
    return 0
  fi
  ok "Vorbedingungen OK"

  # ---- Supabase hochziehen (idempotent) ----
  log "Supabase-Stack sicherstellen (falls nicht laufend)"
  local _sb_running=0
  sudo -u "$APP_USER" bash <<'EOSU' && _sb_running=1 || _sb_running=0
docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null | grep -q '^true$'
EOSU
  if (( _sb_running == 0 )); then
    log "supabase-db laeuft noch nicht — hochziehen"
    cf_ensure_tunnel_if_token
    sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull web_assistent supabase-kong
docker compose --profile vps up -d web_assistent supabase-kong cloudflared
EOSU
    ok "Supabase-Stack gestartet"
  else
    ok "supabase-db laeuft bereits"
  fi

  # supabase-Marker setzen (idempotent)
  _ensure_supabase_marker

  # ---- Pruefen ob R2-Ordner *.fc.gpg enthalten (Empty-Bucket-Sicherheitsnetz) ----
  # BLOCKER-Fix: rclone-Exit-Code explizit fangen; bei Fehler Sentinel "R2_ERROR:<folder>"
  # ausgeben und exit 0 damit der Heredoc IMMER sauber endet. Aeusserer Aufrufer unterscheidet:
  #   "R2_ERROR:" → R2-Verbindungsfehler (Creds/Netzwerk) → return 1 mit klarer Meldung.
  #   Leer          → echter leerer Bucket → sauberer Skip (return 0).
  #   Foldernamen   → fehlende *.fc.gpg → sauberer Skip (return 0).
  log "R2-Verfuegbarkeit pruefen (jüngste *.fc.gpg je Ordner)"
  local _r2_check_out
  _r2_check_out="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -uo pipefail
set -a; source "$APP_DIR/.env"; set +a
# R2-Remote via Env-Vars (nie in argv)
R2_EP="${R2_ENDPOINT:-}"
if [[ -z "$R2_EP" ]]; then
  R2_EP="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_EP"
export RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

missing=""
# SUGGESTION 1: rclone-stderr in Tempfile fangen, Snippet in Sentinel einbetten.
# Tempfile via mktemp + trap, damit kein Datei-Leak beim exit 0 nach R2_ERROR.
_rclone_err_tmp="$(mktemp)"
trap 'rm -f "$_rclone_err_tmp"' EXIT
for folder in _supabase_core brew_assistent rapt_dashboard; do
  # Lesson C2: rclone-Output in Variable fangen, Exit-Code separat pruefen.
  # Bei rclone-Fehler (Bad Creds, Netzwerk): Sentinel ausgeben, exit 0 (Heredoc bleibt sauber).
  lsf_out="$(rclone lsf "R2:${R2_BUCKET}/${folder}/" --include '*.fc.gpg' 2>"$_rclone_err_tmp")"
  rclone_exit=$?
  if (( rclone_exit != 0 )); then
    # Erster nicht-leerer stderr-Satz als kompakter Hinweis (max 120 Zeichen).
    _rclone_snippet="$(grep -v '^$' "$_rclone_err_tmp" 2>/dev/null | head -1 | cut -c1-120 || true)"
    printf 'R2_ERROR:%s' "$folder"
    [[ -n "$_rclone_snippet" ]] && printf ':%s' "$_rclone_snippet"
    exit 0
  fi
  latest="$(printf '%s\n' "$lsf_out" | sort | tail -1 || true)"
  if [[ -z "$latest" ]]; then
    missing="${missing} ${folder}"
  fi
done
printf '%s' "${missing# }"
EOSU
)"

  # Sentinel-Auswertung: R2_ERROR → Creds/Netzwerk-Problem (kein stiller Skip)
  # Format: R2_ERROR:<folder>[:<rclone-stderr-snippet>]
  if [[ "$_r2_check_out" == R2_ERROR:* ]]; then
    local _err_rest="${_r2_check_out#R2_ERROR:}"
    local _err_folder="${_err_rest%%:*}"
    local _err_snippet="${_err_rest#*:}"
    # Wenn kein Snippet vorhanden (kein zweites ':'), snippet = leer setzen.
    [[ "$_err_snippet" == "$_err_folder" ]] && _err_snippet=""
    printf '\n\033[1;31m✖ R2-Verbindung fehlgeschlagen (Ordner: %s).\033[0m\n' "$_err_folder"
    [[ -n "$_err_snippet" ]] && printf '  rclone: %s\n' "$_err_snippet"
    printf '  Ursache: Bad Credentials, Netzwerkfehler oder falscher Endpoint.\n'
    printf '  Massnahmen:\n'
    printf '    1. R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ACCOUNT_ID in .env pruefen.\n'
    printf '    2. rclone lsf R2:<bucket>/ manuell testen.\n'
    printf '    3. Dann erneut versuchen.\n\n'
    return 1
  fi

  if [[ -n "$_r2_check_out" ]]; then
    printf '\n\033[1;33m⚠ Kein *.fc.gpg in R2-Ordner: %s\033[0m\n' "$_r2_check_out"
    printf '  Sicherheitsnetz: kein Backup verfuegbar → Stack laeuft mit frischer DB weiter.\n'
    printf '  Tipp: erst ein Backup erstellen (z.B. ./scripts/backup.sh), dann erneut versuchen.\n\n'
    return 0
  fi
  ok "R2-Backup in allen drei Ordnern vorhanden"

  # ---- Ueberschreib-Schutz: auth.users auf neuem VPS pruefen ----
  # IMPORTANT 2-Fix: Heredoc ohne -e; psql-Fehler / leere Ausgabe → Sentinel "UNKNOWN",
  # das der Aufrufer konservativ als "nicht leer" behandelt.
  log "Ueberschreib-Schutz: auth.users-Count pruefen"
  local _existing_users
  _existing_users="$(sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -uo pipefail
set -a; source "$APP_DIR/.env" || { printf 'UNKNOWN'; exit 0; }; set +a
[[ -n "${POSTGRES_PASSWORD:-}" ]] \
  || { printf 'UNKNOWN'; exit 0; }
count="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" supabase-db \
  psql -tA -U supabase_admin -d postgres \
  -c "SELECT count(*) FROM auth.users;" 2>/dev/null)"
psql_exit=$?
if (( psql_exit != 0 )) || [[ -z "$count" ]]; then
  printf 'UNKNOWN'
  exit 0
fi
printf '%s' "${count//[[:space:]]/}"
EOSU
)"
  _existing_users="${_existing_users//[[:space:]]/}"

  # IMPORTANT 2-Fix: Konservative Auswertung:
  #   Numerisch > 0  → Daten vorhanden (Warnung + force-restore-Prompt).
  #   "UNKNOWN"      → DB-Status unbekannt (Fehler/psql-Timeout) → konservativ wie > 0 behandeln.
  #   "0"            → frische leere DB → kein force-Prompt noetig.
  local _force_needed=0
  if [[ "$_existing_users" == "UNKNOWN" ]]; then
    printf '\n\033[1;33m⚠ WARNUNG: auth.users-Count konnte nicht ermittelt werden (DB-Fehler oder POSTGRES_PASSWORD fehlt).\033[0m\n'
    printf '  Konservative Annahme: DB koennte Daten enthalten — force-restore-Bestaetigung wird verlangt.\n\n'
    _force_needed=1
  elif [[ "$_existing_users" =~ ^[0-9]+$ ]] && (( _existing_users > 0 )); then
    printf '\n\033[1;33m⚠ WARNUNG: Auf diesem VPS existieren bereits %s auth.users.\033[0m\n' \
      "$_existing_users"
    printf '  Ein Restore (--clean) wuerde diese vorhandenen Daten ueberschreiben.\n'
    printf '  Szenarien:\n'
    printf '    a) Frischer VPS — diese Benutzer sind nur die Initialdaten (gewollt).\n'
    printf '    b) Bereits produktiver VPS — Restore wuerde echte Nutzerdaten zerstoeren!\n\n'
    _force_needed=1
  fi

  # ---- Sicherheits-Bestaetigung ----
  printf '\n\033[1;34m▶ Restore-Plan — bitte bestaetigen\033[0m\n\n'
  printf '  Quelle:  juengstes Backup je Ordner aus R2 (latest)\n'
  printf '  Ziel:    Container supabase-db → DB postgres\n'
  printf '  Schritte: core → brew_assistent → rapt_dashboard\n'
  printf '  ACHTUNG: --clean droppt vorhandene Objekte vor dem Neuanlegen.\n\n'

  # IMPORTANT 1-Fix: ASSUME_YES ist implementiert (konsistent mit restore.sh --yes-Muster).
  # Setzt force-restore UND restore-Bestaetigung im Nicht-TTY-Modus voraus.
  # Nur in Kombination mit nicht-leerem / nicht-UNKNOWN users-Count tatsaechlich genutzt.
  local _assume_yes="${ASSUME_YES:-0}"

  # BLOCKER-Fix: UNKNOWN + ASSUME_YES=1 → harter Abbruch.
  # UNKNOWN bedeutet DB-Zustand unklar (kein POSTGRES_PASSWORD, psql-Timeout, …) —
  # kein automatisierter destruktiver Restore gegen unbekannten Zustand.
  # Bei TTY + UNKNOWN bleibt der konservative force-restore-Prompt (s. u.).
  if [[ "$_existing_users" == "UNKNOWN" && "$_assume_yes" == "1" ]]; then
    printf '\033[1;31m✖ UNKNOWN DB-State + ASSUME_YES=1 — automatisierter destruktiver Restore verweigert.\033[0m\n' >&2
    printf '  DB-Health zuerst klaeren (POSTGRES_PASSWORD in .env pruefen, supabase-db-Container pruefen).\n' >&2
    return 1
  fi

  if (( _force_needed == 1 )); then
    if [[ -t 0 ]]; then
      local _force_ans
      read -rp "Vorhandene Daten ueberschreiben? Tippe 'force-restore' zum Bestaetigen oder Enter zum Abbrechen: " _force_ans
      if [[ "$_force_ans" != "force-restore" ]]; then
        echo "  Abgebrochen (Ueberschreib-Schutz)."
        return 0
      fi
      printf '  \033[1;33m⚠ Fortfahren — vorhandene auth.users werden durch Restore ueberschrieben.\033[0m\n\n'
    elif [[ "$_assume_yes" == "1" ]]; then
      printf '  \033[1;33m⚠ ASSUME_YES=1 gesetzt — Ueberschreib-Schutz uebersprungen (Nicht-TTY).\033[0m\n\n'
    else
      printf '\033[1;31m✖ Nicht-TTY + vorhandene Daten — Restore aus Sicherheitsgruenden abgebrochen.\033[0m\n'
      printf '  Fuer automatisierten Restore: ASSUME_YES=1 als Env-Var setzen.\n\n'
      return 0
    fi
  fi

  if [[ -t 0 ]]; then
    local _confirm_ans
    read -rp "Restore starten? Tippe 'restore' zum Bestaetigen: " _confirm_ans
    [[ "$_confirm_ans" == "restore" ]] || { echo "  Abgebrochen."; return 0; }
  elif [[ "$_assume_yes" == "1" ]]; then
    printf '  \033[1;33m⚠ ASSUME_YES=1 gesetzt — Restore-Bestaetigung uebersprungen (Nicht-TTY).\033[0m\n\n'
  else
    printf '\033[1;31m✖ Kein TTY — Restore aus Sicherheitsgruenden abgebrochen (kein Blind-Restore).\033[0m\n'
    printf '  Fuer automatisierten Restore: ASSUME_YES=1 als Env-Var setzen.\n\n'
    return 0
  fi

  # ---- Restore: core → brew_assistent → rapt_dashboard ----
  # restore.sh all latest --yes: zwingende Reihenfolge, Bestaetigung bereits eingeholt.
  log "Restore: core → brew_assistent → rapt_dashboard (latest aus R2)"
  sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
./scripts/restore.sh all latest --yes
EOSU

  ok "Restore abgeschlossen"

  # ---- Abschluss ----
  _ensure_supabase_marker
  cf_reconcile_if_token

  printf '\n\033[1;32m  ✓ R2-Restore abgeschlossen — Supabase laeuft mit den Daten aus R2.\033[0m\n'
  printf '  Smoke-Check: Login in der App + je eine Query auf aibrewgenius.* und rapt.*\n\n'
}

# ================================================================
# HAUPT-MENÜ (V3)
# Punkt 1 = Mehrfachauswahl-TUI (Zusammenlegung der alten Punkte 1+2)
# Punkt 2 = Migrations-Pfad (VPS-Umzug) — unveraendert
# Punkt 3 = Erstdaten aus R2 wiederherstellen (latest) — NEU
# ================================================================
main_menu() {
  while true; do
    printf '\n\033[1;34m▶ Brewing-Stack — Aktion waehlen\033[0m\n\n'
    printf '  1) Einheiten auswaehlen & starten   (Mehrfachauswahl: Apps, Watchtower, Portainer)\n'
    printf '  2) App migrieren (VPS-Umzug)        (Backup alt → Stop alt → Start neu → Restore)\n'
    printf '  3) Aus R2 wiederherstellen (latest)  (Disaster-Recovery / Erst-Lauf — frischer VPS ohne alten VPS, destruktiv)\n'
    printf '  q) Beenden\n\n'
    read -rp "Auswahl [1-3,q]: " menu_choice

    case "$menu_choice" in
      1)
        action_select_and_start
        ;;
      2)
        action_migrate_unit
        ;;
      3)
        action_restore_from_r2
        ;;
      q|Q)
        echo "  Beenden."
        return 0
        ;;
      *)
        printf '  Ungueltige Eingabe: %s — Bitte 1, 2, 3 oder q eingeben.\n' "$menu_choice"
        ;;
    esac
  done
}

# ================================================================
# HAUPTPROGRAMM
# ================================================================

if (( MENU_MODE == 1 )); then
  # --menu: Basis-Schritte überspringen (wenn bereits erledigt), direkt ins Menü.
  log "Bootstrap-Menü (--menu Modus)"
  # Basis-Voraussetzungen prüfen — Menü ohne laufenden Stack ist nutzlos.
  _env_done    || err ".env fehlt — erst vollständigen Bootstrap laufen lassen (ohne --menu)."
  _gpgpass_done || err "/etc/brewing/gpg.pass fehlt — erst vollständigen Bootstrap laufen lassen."
  _docker_done  || err "docker fehlt — erst vollständigen Bootstrap laufen lassen."
  ok "Basis-Voraussetzungen erfüllt — springe direkt ins Menü"
  main_menu
else
  # Normaler Lauf: Basis-Bootstrap (mit Skip-Erkennung), dann Menü.
  run_base_bootstrap
  main_menu
fi

# ---------------------------------------------------------------- Done (nach Menü-Beenden)
log "Bootstrap-Session beendet"
cat <<EOF

  Repo:       $APP_DIR
  User:       $APP_USER  (Mitglied von 'sudo' + 'docker')
  Login:      ssh ${APP_USER}@<vps-ip>

  Status      cd $APP_DIR && sudo -u $APP_USER docker compose --profile vps ps
  App-Logs    sudo -u $APP_USER docker logs -f api-proxy
  Tunnel-Log  sudo -u $APP_USER docker logs -f cloudflared

  Auto-Updates der App-Container (web_*, api_proxy) uebernimmt Watchtower
  alle 5 Minuten. Supabase-Stack bleibt auf gepinnten Versionen.

  Portainer    Hub: https://portainer.alexstuder.cloud  (hinter Cloudflare Access)
               Edge-Endpoint: https://edge.alexstuder.cloud  (oeffentlich, Agents pollen)
               PORTAINER_ROLE=auto|hub|agent steuert die Rolle dieses VPS.

  Cloudflare-Hostnames/DNS: scripts/cloudflare-routes.json editieren →
  ./scripts/cloudflare-reconcile.sh (idempotent).

  Backups      nightly 03:00 (cron, als ${APP_USER}, kein sudo) → R2, je drei
               verschluesselte Dumps (_supabase_core / brew_assistent / rapt_dashboard).
               Retention: neueste N=7 pro Ordner (lokal + R2), via BACKUP_KEEP.
               Manuell (als ${APP_USER}): ./scripts/backup.sh
  Backup-Log   tail -f /var/log/brewing-backup.log
  Restore      ./scripts/restore.sh all       (core → apps, manuell, destruktiv)

  Erstdaten    Menü-Option 3 "Erstdaten aus R2 wiederherstellen" — zieht das juengste
               Backup (latest) aus R2 und restored es (core → brew_assistent → rapt).
               Nur auf frischem VPS: destruktiv, explizite Bestaetigung erforderlich.
               Voraussetzung: R2-Creds in .env + Backup in R2 vorhanden.

EOF
