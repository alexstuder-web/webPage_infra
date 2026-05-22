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
# Drei interaktive Eingaben:
#   1. Bitwarden E-Mail
#   2. Bitwarden Master-Passwort
#   3. Passwort für neuen Linux-User 'alex'
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- Konstanten
REPO_URL="https://github.com/alexstuder-web/webPage_infra.git"
APP_USER="alex"
APP_HOME="/home/${APP_USER}"
APP_DIR="${APP_HOME}/webPage_infra"
BW_ITEM="ALEXSTUDER_WEBPAGE_GPG_PASSWORD"

# ---------------------------------------------------------------- Helpers
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
err()  { echo -e "\n\033[1;31m✖ $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------- Pre-flight
[[ $EUID -eq 0 ]] || err "Muss als root laufen — versuch: sudo bash $0"
[[ -f /etc/os-release ]] || err "Kein /etc/os-release — Linux?"
. /etc/os-release
[[ "$ID" == "ubuntu" ]] || err "Nur Ubuntu unterstützt (gefunden: $ID)"

# ---------------------------------------------------------------- Eingaben
log "Brewing-Stack Bootstrap"
cat <<EOF
  Repo: $REPO_URL
  Ziel: $APP_DIR  (User: $APP_USER, UID 1000)

Es werden drei Eingaben benötigt:
  - Bitwarden E-Mail + Master-PW (für die GPG-Passphrase)
  - Linux-User-PW (für sudo + ssh später)

EOF

read -rp "Bitwarden E-Mail: " BW_EMAIL
read -srp "Bitwarden Master-Passwort: " BW_PASS; echo
read -srp "Passwort für Linux-User '${APP_USER}': " USER_PASS; echo
read -srp "  (wiederholen): " USER_PASS2; echo
[[ "$USER_PASS" == "$USER_PASS2" ]] || err "Passwörter stimmen nicht überein"
[[ -n "$BW_EMAIL" && -n "$BW_PASS" && -n "$USER_PASS" ]] \
  || err "Eingaben dürfen nicht leer sein"

# ---------------------------------------------------------------- System
log "System-Update + Base-Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl git gnupg ca-certificates lsb-release ufw jq unzip
ok "apt up-to-date"

# ---------------------------------------------------------------- Linux-User
log "Linux-User '$APP_USER' anlegen"
if id "$APP_USER" >/dev/null 2>&1; then
  echo "  User existiert bereits — Passwort wird aktualisiert"
else
  useradd -m -s /bin/bash -u 1000 "$APP_USER"
fi
echo "${APP_USER}:${USER_PASS}" | chpasswd
usermod -aG sudo "$APP_USER"
ok "User '$APP_USER' bereit (sudo)"

# ---------------------------------------------------------------- Docker
log "Docker installieren"
if ! command -v docker >/dev/null 2>&1; then
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
usermod -aG docker "$APP_USER"
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) läuft"

# ---------------------------------------------------------------- Bitwarden CLI
log "Bitwarden CLI installieren"
if ! command -v bw >/dev/null 2>&1; then
  # 1) snap (default auf Ubuntu Server)
  if command -v snap >/dev/null 2>&1; then
    snap install bw 2>/dev/null || true
  fi
  # 2) Fallback: direkter Download
  if ! command -v bw >/dev/null 2>&1; then
    curl -fsSL "https://vault.bitwarden.com/download/?app=cli&platform=linux" \
      -o /tmp/bw.zip
    unzip -o /tmp/bw.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/bw
  fi
fi
command -v bw >/dev/null 2>&1 || err "bw CLI Installation fehlgeschlagen"
ok "bw $(bw --version) bereit"

# ---------------------------------------------------------------- Repo clonen
log "Repo clonen / aktualisieren"
if [[ -d "$APP_DIR/.git" ]]; then
  sudo -u "$APP_USER" git -C "$APP_DIR" fetch --all
  sudo -u "$APP_USER" git -C "$APP_DIR" reset --hard origin/main
else
  sudo -u "$APP_USER" git clone "$REPO_URL" "$APP_DIR"
fi
ok "$APP_DIR auf main"

# ---------------------------------------------------------------- BW Login + Passphrase
log "Bitwarden Login + GPG-Passphrase abholen"

# Sichere Übergabe: Passwort + Output in tempfiles mit mode 600 (nicht in argv).
BW_PASS_FILE="$(mktemp)"
PASS_TMP="$(mktemp)"
chown "$APP_USER:$APP_USER" "$BW_PASS_FILE" "$PASS_TMP"
chmod 600 "$BW_PASS_FILE" "$PASS_TMP"
printf "%s" "$BW_PASS" > "$BW_PASS_FILE"
unset BW_PASS

sudo -u "$APP_USER" -H \
  BW_EMAIL="$BW_EMAIL" \
  BW_PASS_FILE="$BW_PASS_FILE" \
  BW_ITEM="$BW_ITEM" \
  PASS_TMP="$PASS_TMP" \
  bash <<'EOSU'
set -euo pipefail
export BW_PASSWORD="$(cat "$BW_PASS_FILE")"
bw config server https://vault.bitwarden.com >/dev/null 2>&1 || true
status="$(bw status 2>/dev/null | jq -r .status || echo unauthenticated)"
if [[ "$status" == "unauthenticated" ]]; then
  bw login "$BW_EMAIL" --passwordenv BW_PASSWORD >/dev/null
fi
export BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)"
bw sync >/dev/null
bw get password "$BW_ITEM" > "$PASS_TMP"
EOSU

rm -f "$BW_PASS_FILE"
ok "Passphrase abgeholt"

# ---------------------------------------------------------------- .env entschlüsseln
log ".env entschlüsseln"
sudo -u "$APP_USER" -H \
  APP_DIR="$APP_DIR" \
  PASS_TMP="$PASS_TMP" \
  bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
[[ -f .env ]] && rm -f .env
export GPG_PASSPHRASE="$(cat "$PASS_TMP")"
./scripts/decrypt-env.sh
EOSU

rm -f "$PASS_TMP"
ok ".env geschrieben"

# ---------------------------------------------------------------- Container starten
log "Container ziehen + starten (Profil: vps)"
sudo -u "$APP_USER" -H bash <<EOSU
set -euo pipefail
cd "$APP_DIR"
docker compose --profile vps pull
docker compose --profile vps up -d
EOSU
ok "Stack läuft"

# ---------------------------------------------------------------- Done
log "✓ Bootstrap abgeschlossen"
cat <<EOF

  Repo:       $APP_DIR
  User:       $APP_USER  (Mitglied von 'sudo' + 'docker')
  Login:      ssh ${APP_USER}@<vps-ip>

  Status      sudo -u $APP_USER docker compose -C $APP_DIR --profile vps ps
  App-Logs    sudo -u $APP_USER docker logs -f api-proxy
  Tunnel-Log  sudo -u $APP_USER docker logs -f cloudflared

  Auto-Updates der App-Container (web_*, api_proxy) übernimmt Watchtower
  alle 5 Minuten. Supabase-Stack bleibt auf gepinnten Versionen.

EOF
