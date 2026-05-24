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
  log "Nightly Backup-Cron einrichten (03:00, als ${APP_USER}, idempotent)"
  # Alten sudoers-Drop-in aus früheren Bootstraps entfernen (idempotent).
  rm -f /etc/sudoers.d/brewing-backup
  local cron_file="/etc/cron.d/brewing-backup"
  cat > "$cron_file" <<EOF
# Brewing Postgres-Backup — nightly 03:00. Von bootstrap.sh erzeugt (idempotent).
# Läuft als ${APP_USER} (docker-Gruppe + owner gpg.pass) — kein sudo.
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

action_install_unit() {
  printf '\n\033[1;34m▶ Welche App installieren/starten?\033[0m\n\n'
  printf '  1) brew_assistent + Supabase   (web_assistent + kompletter supabase-* Stack)\n'
  printf '  2) RAPT Dashboard              (web_rapt)\n'
  printf '  3) brew-proxy (API)            (api_proxy — braucht laufendes Supabase)\n'
  printf '  4) WebPageAlexStuder           (web_hauptseite, statisches Nginx)\n'
  printf '  b) zurück\n\n'
  read -rp "Auswahl [1-4,b]: " unit_choice

  case "$unit_choice" in
    1)
      log "brew_assistent + Supabase installieren/starten"
      echo "  Services: web_assistent supabase-kong (depends_on zieht auth/rest/realtime/storage/meta/db mit)"
      cf_ensure_tunnel_if_token
      sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull web_assistent supabase-kong
# cloudflared via --profile vps mitstarten (App sonst nicht über Tunnel erreichbar)
docker compose --profile vps up -d web_assistent supabase-kong cloudflared
EOSU
      ok "brew_assistent + Supabase gestartet"
      cf_reconcile_if_token
      ;;
    2)
      log "RAPT Dashboard installieren/starten"
      echo "  Service: web_rapt (zustandslos, kein depends_on)"
      cf_ensure_tunnel_if_token
      sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull web_rapt
docker compose --profile vps up -d web_rapt cloudflared
EOSU
      ok "RAPT Dashboard gestartet"
      cf_reconcile_if_token
      ;;
    3)
      log "brew-proxy (api_proxy) installieren/starten"
      # api_proxy hat kein depends_on auf Supabase in docker-compose.yml — muss
      # manuell geprüft werden (§5.1 BOOTSTRAP_MENU_KONZEPT.md Annahme 3).
      echo "  Prüfe, ob supabase-db läuft..."
      cf_ensure_tunnel_if_token
      local supabase_running=0
      sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU' && supabase_running=1 || supabase_running=0
docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null | grep -q '^true$'
EOSU
      if (( supabase_running == 0 )); then
        printf '  \033[1;33m⚠ supabase-db läuft nicht — wird mitgestartet (supabase-kong + deps).\033[0m\n'
        sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull supabase-kong api_proxy
docker compose --profile vps up -d supabase-kong api_proxy cloudflared
EOSU
      else
        echo "  Supabase läuft bereits."
        sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull api_proxy
docker compose --profile vps up -d api_proxy cloudflared
EOSU
      fi
      ok "brew-proxy gestartet"
      cf_reconcile_if_token
      ;;
    4)
      log "WebPageAlexStuder installieren/starten"
      echo "  Service: web_hauptseite (statisches Nginx, kein depends_on)"
      cf_ensure_tunnel_if_token
      sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull web_hauptseite
docker compose --profile vps up -d web_hauptseite cloudflared
EOSU
      ok "web_hauptseite gestartet"
      cf_reconcile_if_token
      ;;
    b|B)
      return 0
      ;;
    *)
      printf '  Ungültige Eingabe: %s\n' "$unit_choice"
      ;;
  esac
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
# ACHTUNG: muss als $APP_USER in einem heredoc-Subshell laufen, wo .env bereits
# gesourced ist. Hier als Hilfsfunktion die den r2_bucket-Pfad zurückgibt.
_verify_backup_in_r2() {
  # Aufruf: _verify_backup_in_r2 <old_user> <old_host> <old_port> <app_folder>
  # Prüft auf dem alten VPS, ob die pre-migration-Dateien in R2 existieren.
  # Gibt Dateinamen core + app zurück (eines pro Zeile) oder schlägt fehl.
  # Fehler-Diskriminierung: SSH-/Netzwerk-Fehler → sofortiger Abbruch mit
  # klarer Meldung; Backup nicht gefunden → return 1 (Aufrufer meldet).
  local old_user="$1" old_host="$2" old_port="$3" app_folder="$4"

  # Gemeinsame SSH-Optionen.
  local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

  # ---- core-Dump suchen ----
  # Kommando single-quoted: alle Vars (R2_*, R2_BUCKET) expandieren REMOTE (aus .env).
  # Kein '|| true': SSH-/Netzwerk-/rclone-Fehler schlagen durch → sofortiger Abbruch.
  # Muster: VAR="$(cmd)" || { handle; return; } — erfasst Fehler unter set -e sicher,
  # weil '||' die Fehler-Propagation blockiert und explizit behandelt.
  local core_file app_file
  core_file="$(ssh "${ssh_opts[@]}" -p "$old_port" "${old_user}@${old_host}" \
    'cd ~/webPage_infra && set -a && source .env && set +a
     export RCLONE_CONFIG_R2_TYPE=s3
     export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
     export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
     export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
     export RCLONE_CONFIG_R2_REGION=auto
     export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
     _ep="${R2_ENDPOINT:-}"
     if [[ -z "$_ep" ]]; then _ep="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"; fi
     export RCLONE_CONFIG_R2_ENDPOINT="$_ep"
     rclone lsf "R2:${R2_BUCKET}/_supabase_core/" --include "*.fc.gpg" \
       | sort | grep "_pre-migration" | tail -1' \
    )" \
    || { printf '\033[1;31m✖ SSH/rclone-Fehler beim Suchen des core-Dumps (Exit %s) — SSH-Zugang oder rclone/R2-Setup auf altem VPS prüfen.\033[0m\n' "$?" >&2; return 2; }

  # ---- app-Dump suchen ----
  # app_folder ist whitelist-validiert (nur [a-zA-Z0-9_-]) — sicher als Wort
  # in den double-quoted SSH-Befehl einzusetzen. Alle R2_*-Vars bleiben escaped
  # (\$) und expandieren erst REMOTE (aus .env).
  # Nur alphanumerisch + Unterstrich/Bindestrich erlaubt — kein Shell-Sonderzeichen.
  [[ "$app_folder" =~ ^[a-zA-Z0-9_-]+$ ]] \
    || { printf '\033[1;31m✖ Ungültiger app_folder-Wert: %s\033[0m\n' "$app_folder" >&2; return 2; }

  app_file="$(ssh "${ssh_opts[@]}" -p "$old_port" "${old_user}@${old_host}" \
    "cd ~/webPage_infra && set -a && source .env && set +a
     export RCLONE_CONFIG_R2_TYPE=s3
     export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
     export RCLONE_CONFIG_R2_ACCESS_KEY_ID=\"\${R2_ACCESS_KEY_ID:-}\"
     export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=\"\${R2_SECRET_ACCESS_KEY:-}\"
     export RCLONE_CONFIG_R2_REGION=auto
     export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
     _ep=\"\${R2_ENDPOINT:-}\"
     if [[ -z \"\$_ep\" ]]; then _ep=\"https://\${R2_ACCOUNT_ID}.r2.cloudflarestorage.com\"; fi
     export RCLONE_CONFIG_R2_ENDPOINT=\"\$_ep\"
     rclone lsf \"R2:\${R2_BUCKET}/${app_folder}/\" --include '*.fc.gpg' \
       | sort | grep '_pre-migration' | tail -1" \
    )" \
    || { printf '\033[1;31m✖ SSH/rclone-Fehler beim Suchen des app-Dumps (Exit %s) — SSH-Zugang oder rclone/R2-Setup auf altem VPS prüfen.\033[0m\n' "$?" >&2; return 2; }

  # SSH hat funktioniert, aber Dump-Datei nicht gefunden (rclone-Output leer).
  if [[ -z "$core_file" ]]; then
    printf '\033[1;31m✖ core-Dump mit Label "pre-migration" nicht in R2 gefunden (R2:<bucket>/_supabase_core/).\033[0m\n' >&2
    return 1
  fi
  if [[ -z "$app_file" ]]; then
    printf '\033[1;31m✖ app-Dump mit Label "pre-migration" nicht in R2 gefunden (R2:<bucket>/%s/).\033[0m\n' "$app_folder" >&2
    return 1
  fi

  # Gibt Dateinamen aus (eine Zeile pro Datei)
  printf '%s\n%s\n' "$core_file" "$app_file"
}

# ---------------------------------------------------------------- Migrations-Aktion
action_migrate_unit() {
  printf '\n\033[1;34m▶ Welche App migrieren?\033[0m\n\n'
  printf '  1) brew_assistent   (Schema aibrewgenius + Frontend web_assistent + Supabase-Core)\n'
  printf '  2) RAPT Dashboard   (Schema rapt + Frontend web_rapt)\n'
  printf '  b) zurück\n\n'
  printf '  Hinweis: WebPageAlexStuder und brew-proxy haben keine eigene DB.\n'
  printf '           Für diese → Option 2 (Einzelne App installieren) nutzen.\n\n'
  read -rp "Auswahl [1-2,b]: " mig_choice

  local app_name="" restore_target="" r2_folder="" stop_services=""
  case "$mig_choice" in
    1)
      app_name="brew_assistent"
      restore_target="brew_assistent"
      r2_folder="brew_assistent"
      stop_services="web_assistent"
      ;;
    2)
      app_name="rapt_dashboard"
      restore_target="rapt_dashboard"
      r2_folder="rapt_dashboard"
      stop_services="web_rapt"
      ;;
    b|B)
      return 0
      ;;
    *)
      printf '  Ungültige Eingabe: %s\n' "$mig_choice"
      return 0
      ;;
  esac

  # ---- SSH-Verbindungsdaten abfragen
  printf '\n\033[1;34m▶ Verbindung zum alten VPS\033[0m\n\n'
  local old_host old_user old_port
  read -rp "Hostname / IP des alten VPS: " old_host
  [[ -n "$old_host" ]] || err "Kein Host eingegeben"
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

  # ---- Supabase-Core-Überschreib-Schutz (§5.2 BOOTSTRAP_MENU_KONZEPT.md)
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
  # Check 1: läuft supabase-db?
  sudo -u "$APP_USER" -H bash <<'EOSU' 2>/dev/null && db_running=1 || db_running=0
docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null | grep -q '^true$'
EOSU

  if (( db_running == 1 )); then
    # Check 2: .env laden und Count abfragen — kein '|| echo 0': Fehler hier sollen
    # laut fehlschlagen, damit ein defektes/fehlendes .env sofort sichtbar wird
    # und kein stiller 0-Fallback in den destruktiven Restore-Pfad führt.
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
  printf '  Alter VPS:    %s@%s (Port %s)\n' "$old_user" "$old_host" "$old_port"
  printf '  App:          %s\n' "$app_name"
  printf '  Schritte:\n'
  printf '    (a) Backup auf altem VPS erstellen (--label pre-migration) + R2-Verifikation\n'
  printf '    (b) %s auf altem VPS stoppen\n' "$stop_services"
  printf '    (c) %s auf neuem VPS hochziehen (selektiver Start)\n' "$app_name"
  printf '    (d) Backup auf neuem VPS restoren (core → %s) via --clean\n\n' "$restore_target"
  printf '  ACHTUNG: Schritt (d) überschreibt vorhandene Daten im Ziel-Schema auf dem neuen VPS.\n'
  printf '  Rollback bei Bedarf: auf altem VPS docker compose start %s\n\n' "$stop_services"
  read -rp "Migration starten? Tippe 'migrate' zum Bestätigen: " migrate_ans
  [[ "$migrate_ans" == "migrate" ]] || { echo "  Abgebrochen."; return 0; }

  # ===========================================================================
  # SCHRITT (a) — Backup auf altem VPS erstellen
  # ===========================================================================
  log "(a) Frisches Backup auf altem VPS erstellen (--label pre-migration)"
  # Annahme: gleicher Repo-Pfad ~/webPage_infra + gleicher User auf altem VPS
  # (Standard-Bootstrap). Bei Abweichung schlägt der SSH-Befehl mit klarem Fehler fehl.
  ssh -o BatchMode=yes -o ConnectTimeout=30 \
      -o StrictHostKeyChecking=accept-new \
      -p "$old_port" "${old_user}@${old_host}" \
      'cd ~/webPage_infra && ./scripts/backup.sh --label pre-migration' \
    || err "Backup auf altem VPS fehlgeschlagen — Migration abgebrochen. Alter Stand bleibt laufend."
  ok "(a) Backup erstellt"

  # ===========================================================================
  # SCHRITT (a) VERIFIKATION — pre-migration-Dumps in R2 prüfen
  # ===========================================================================
  log "(a) Verifikation: pre-migration-Dumps in R2 suchen"
  local verify_out

  local core_dump_name app_dump_name
  # _verify_backup_in_r2 läuft als root aber SSH als old_user — liefert Dateinamen.
  if ! verify_out="$(_verify_backup_in_r2 "$old_user" "$old_host" "$old_port" "$r2_folder")"; then
    err "R2-Verifikation fehlgeschlagen: pre-migration-Dumps nicht in R2 gefunden.
   Migration abgebrochen — alter Stand bleibt laufend.
   Manuell prüfen: ssh ${old_user}@${old_host} 'rclone lsf R2:<bucket>/_supabase_core/ | grep pre-migration'"
  fi

  core_dump_name="$(printf '%s' "$verify_out" | head -1)"
  app_dump_name="$(printf '%s' "$verify_out" | tail -1)"

  ok "(a) Verifikation OK — core: ${core_dump_name}  app: ${app_dump_name}"

  # ===========================================================================
  # SCHRITT (b) — Frontend auf altem VPS stoppen
  # ===========================================================================
  log "(b) ${stop_services} auf altem VPS stoppen"
  # stop_services wird als SSH-Kommando-Argument übergeben — Whitelist-Validierung
  # verhindert Injection und stellt sicher, dass der Wert nicht leer ist
  # (leeres 'docker compose stop' würde ALLE Services stoppen).
  [[ -n "$stop_services" ]] \
    || err "Interner Fehler: stop_services ist leer."
  case "$stop_services" in
    web_assistent|web_rapt) : ;;
    *) err "Ungültiger stop_services-Wert: '${stop_services}' — nur 'web_assistent' und 'web_rapt' erlaubt." ;;
  esac
  # safe_svc ist whitelist-geprüft — kann sicher als Wort in das Kommando.
  local safe_svc="$stop_services"
  # Nur Frontend stoppen (Supabase-DB läuft weiter — macht alte App offline,
  # verhindert neue Writes in die migrierte App; DB-Stop ist nicht zwingend,
  # Annahme §5.2 BOOTSTRAP_MENU_KONZEPT.md: Frontend-Stop reicht).
  ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new \
      -p "$old_port" "${old_user}@${old_host}" \
      "cd ~/webPage_infra && docker compose stop ${safe_svc}" \
    || err "Stop auf altem VPS fehlgeschlagen. Bitte manuell prüfen."
  ok "(b) ${stop_services} gestoppt (docker compose stop, Volumes + DB bleiben intakt)"
  printf '  Rollback jederzeit möglich: ssh %s@%s "cd ~/webPage_infra && docker compose start %s"\n' \
    "$old_user" "$old_host" "$stop_services"

  # ===========================================================================
  # SCHRITT (c) — App auf neuem VPS hochziehen
  # ===========================================================================
  log "(c) ${app_name} auf neuem VPS hochziehen"
  # Selektiver Start analog §5.1 (Service-Namen, kein Per-App-Profil).
  # Tunnel-Ensure VOR dem Container-Start (Reihenfolge §3).
  cf_ensure_tunnel_if_token
  case "$app_name" in
    brew_assistent)
      echo "  Services: web_assistent supabase-kong (depends_on zieht Supabase-Core mit)"
      sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull web_assistent supabase-kong
docker compose --profile vps up -d web_assistent supabase-kong cloudflared
EOSU
      ;;
    rapt_dashboard)
      echo "  Service: web_rapt"
      # RAPT läuft zustandslos. Wenn Supabase noch nicht läuft, wird es hier mitgestartet
      # (RAPT-Frontend benötigt api_proxy/Supabase für Daten).
      local rapt_supabase_running=0
      sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU' && rapt_supabase_running=1 || rapt_supabase_running=0
docker inspect --format='{{.State.Running}}' supabase-db 2>/dev/null | grep -q '^true$'
EOSU
      if (( rapt_supabase_running == 0 )); then
        printf '  supabase-db läuft noch nicht — wird mitgestartet.\n'
        sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull web_rapt supabase-kong
docker compose --profile vps up -d web_rapt supabase-kong cloudflared
EOSU
      else
        sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose pull web_rapt
docker compose --profile vps up -d web_rapt cloudflared
EOSU
      fi
      ;;
  esac
  ok "(c) ${app_name} gestartet"

  # ===========================================================================
  # SCHRITT (d) — Backup auf neuem VPS restoren
  # ===========================================================================
  log "(d) Backup auf neuem VPS restoren (core → ${restore_target})"
  # Explizite Dateinamen aus dem Verifikations-Ergebnis verwenden (nicht 'latest'),
  # um Verwechslung mit einem neueren automatischen Dump zu vermeiden (§8.5).
  # restore.sh erwartet: <target> <datei-oder-latest> [--yes]
  # Der Dump liegt in R2 → restore.sh mit 'latest' würde den jüngsten R2-Dump holen,
  # das ist nach dem pre-migration-Backup korrekt, ABER: robuster ist der explizite Name.
  # Wir übergeben den vollen R2-Pfad nicht direkt (restore.sh unterstützt nur lokalen
  # Pfad oder 'latest') — daher laden wir den expliziten Dump zuerst lokal herunter.
  echo "  Core-Dump:  ${core_dump_name}"
  echo "  App-Dump:   ${app_dump_name}"
  echo "  Restore läuft mit --yes (Bestätigung wurde oben eingeholt)."

  sudo -u "$APP_USER" -H \
    APP_DIR="$APP_DIR" \
    CORE_DUMP="${core_dump_name}" \
    APP_DUMP="${app_dump_name}" \
    RESTORE_TARGET="${restore_target}" \
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

# App-Dump lokal laden
if [[ "$RESTORE_TARGET" == "brew_assistent" ]]; then
  APP_FOLDER="brew_assistent"
else
  APP_FOLDER="rapt_dashboard"
fi
APP_LOCAL="backups/${APP_FOLDER}/${APP_DUMP}"
mkdir -p "backups/${APP_FOLDER}"
rclone copyto "R2:${R2_BUCKET}/${APP_FOLDER}/${APP_DUMP}" "$APP_LOCAL" \
  || { echo "rclone-Download app fehlgeschlagen" >&2; exit 1; }
echo "  App-Dump geladen: $APP_LOCAL"

# Restore: core zuerst (auth.users muss existieren), dann App-Schema.
# --yes: Bestätigung wurde interaktiv im Menü bereits eingeholt.
./scripts/restore.sh core "$CORE_LOCAL" --yes
./scripts/restore.sh "$RESTORE_TARGET" "$APP_LOCAL" --yes

echo "  Lokale Dump-Dateien aufräumen..."
rm -f "$CORE_LOCAL" "$APP_LOCAL"
EOSU

  ok "(d) Restore abgeschlossen"

  # ---------------------------------------------------------------- Cloudflare reconcilen
  cf_reconcile_if_token

  # ---------------------------------------------------------------- Post-Migrations-Hinweise
  printf '\n\033[1;32m  ✓ Migration abgeschlossen\033[0m\n\n'
  printf '  Rollback-Info:\n'
  printf '    Falls Probleme auftreten:\n'
  printf '    ssh %s@%s "cd ~/webPage_infra && docker compose start %s"\n' \
    "$old_user" "$old_host" "$stop_services"
  printf '    Der pre-migration-Dump liegt rotation-exempt in R2.\n\n'
  printf '  Cloudflare-Routing:\n'
  printf '    Auf dem ALTEN VPS den Hostname aus scripts/cloudflare-routes.json entfernen\n'
  printf '    und ./scripts/cloudflare-reconcile.sh ausführen — sonst konkurrierende\n'
  printf '    Tunnel-Ingress-Einträge (beide Tunnel antworten auf denselben Hostname).\n\n'

  if [[ "$app_name" == "rapt_dashboard" ]]; then
    printf '  RAPT_DASHBOARD_URL:\n'
    printf '    RAPT läuft jetzt auf einem anderen VPS.\n'
    printf '    In brew_assistent/.env RAPT_DASHBOARD_URL auf die neue URL setzen\n'
    printf '    (https://rapt.alexstuder.cloud oder die URL des neuen VPS),\n'
    printf '    dann .env.gpg neu verschlüsseln:\n'
    printf '      ./scripts/encrypt-env.sh   (braucht GPG-Passphrase aus Bitwarden)\n'
    printf '    Credential-Schritt: ALEXSTUDER_WEBPAGE_GPG_PASSWORD aus Bitwarden holen.\n\n'
  fi

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
# HAUPT-MENÜ
# ================================================================
main_menu() {
  while true; do
    printf '\n\033[1;34m▶ Brewing-Stack — Aktion wählen\033[0m\n\n'
    printf '  1) Komplett-Stack starten        (docker compose --profile vps up -d, wie bisher)\n'
    printf '  2) Einzelne App installieren     (gezielt einen Stack hochziehen)\n'
    printf '  3) App migrieren (VPS-Umzug)     (Backup alt → Stop alt → Start neu → Restore)\n'
    printf '  q) Beenden\n\n'
    read -rp "Auswahl [1-3,q]: " menu_choice

    case "$menu_choice" in
      1)
        log "Komplett-Stack starten (Profil: vps)"
        cf_ensure_tunnel_if_token
        sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose --profile vps pull
docker compose --profile vps up -d
EOSU
        ok "Stack läuft"
        cf_reconcile_if_token
        ;;
      2)
        # Schleife im Untermenü — bei 'zurück' wieder Hauptmenü zeigen
        while true; do
          action_install_unit
          # action_install_unit gibt bei gültiger Wahl direkt zurück
          # Bei 'b' wird 0 returned und wir kommen hier an → Schleife verlassen
          break
        done
        ;;
      3)
        while true; do
          action_migrate_unit
          break
        done
        ;;
      q|Q)
        echo "  Beenden."
        return 0
        ;;
      *)
        printf '  Ungültige Eingabe: %s — Bitte 1, 2, 3 oder q eingeben.\n' "$menu_choice"
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

  Auto-Updates der App-Container (web_*, api_proxy) übernimmt Watchtower
  alle 5 Minuten. Supabase-Stack bleibt auf gepinnten Versionen.

  Cloudflare-Hostnames/DNS: scripts/cloudflare-routes.json editieren →
  ./scripts/cloudflare-reconcile.sh (idempotent).

  Backups      nightly 03:00 (cron, als ${APP_USER}, kein sudo) → R2, je drei
               verschlüsselte Dumps (_supabase_core / brew_assistent / rapt_dashboard).
               Retention: neueste N=7 pro Ordner (lokal + R2), via BACKUP_KEEP.
               Manuell (als ${APP_USER}): ./scripts/backup.sh
  Backup-Log   tail -f /var/log/brewing-backup.log
  Restore      ./scripts/restore.sh all       (core → apps, manuell, destruktiv)

EOF
