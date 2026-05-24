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
log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
err()  { printf '\n\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

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
apt-get install -y curl git gnupg ca-certificates lsb-release ufw jq unzip cron rclone
systemctl enable --now cron
ok "apt up-to-date (inkl. cron + rclone für Backups)"

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
# Bevorzugt: snap (signierter Channel, Signatur-Verifikation eingebaut).
# Warum snap statt fest-eingepinntem SHA-256: die Download-URL
# (?app=cli&platform=linux) liefert IMMER das jeweils neueste bw-Release —
# ein hartkodierter Hash würde bei der nächsten bw-Veröffentlichung brechen und
# einen Fresh-VPS-Bootstrap stilllegen. Der direkte Download bleibt nur als
# Notfall-Fallback und installiert NIE eine unverifizierte Datei: er verlangt
# einen via $BW_ZIP_SHA256 übergebenen Soll-Hash und bricht sonst hart ab.
log "Bitwarden CLI installieren"
if ! command -v bw >/dev/null 2>&1; then
  # 1) snap (default auf Ubuntu Server, verifizierter Channel)
  if command -v snap >/dev/null 2>&1; then
    snap install bw 2>/dev/null \
      || echo "  snap install bw fehlgeschlagen — versuche direkten Download" >&2
  fi
  # 2) Fallback: direkter Download — NUR mit SHA-256-Verifikation.
  if ! command -v bw >/dev/null 2>&1; then
    if [[ -z "${BW_ZIP_SHA256:-}" ]]; then
      err "bw via snap nicht installierbar und kein \$BW_ZIP_SHA256 für den Download-Fallback gesetzt.
   Aus Sicherheitsgründen wird keine unverifizierte Binary installiert.
   Lösung: 'snap install bw' ermöglichen ODER den erwarteten SHA-256 der aktuellen
   Linux-CLI-Zip auf https://bitwarden.com/help/cli/ prüfen und so erneut starten:
     BW_ZIP_SHA256=<hash> ./bootstrap.sh"
    fi
    BW_ZIP="$(mktemp --suffix=.zip)"
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

# ---------------------------------------------------------------- Repo clonen
log "Repo clonen / aktualisieren"
if [[ -d "$APP_DIR/.git" ]]; then
  # Dirty working tree absichern: ein VPS-Hotfix (uncommittete Änderung) darf
  # nicht still von 'git reset --hard' überschrieben werden. .env ist gitignored
  # und taucht in --porcelain ohnehin nicht auf.
  if [[ -n "$(sudo -u "$APP_USER" git -C "$APP_DIR" status --porcelain)" ]]; then
    err "Uncommittete Änderungen in $APP_DIR — 'git reset --hard origin/main' würde sie verwerfen.
   Erst sichern/committen (oder 'git -C $APP_DIR stash'), dann bootstrap erneut starten."
  fi
  sudo -u "$APP_USER" git -C "$APP_DIR" fetch --all
  sudo -u "$APP_USER" git -C "$APP_DIR" reset --hard origin/main
else
  sudo -u "$APP_USER" git clone "$REPO_URL" "$APP_DIR"
fi
ok "$APP_DIR auf main"

# ---------------------------------------------------------------- BW Login + Passphrase
log "Bitwarden Login + GPG-Passphrase abholen"

# Sichere Übergabe: Passwort + Output in tempfiles mit mode 600 (nicht in argv).
# Tempfiles werden als $APP_USER angelegt (kein root→chown-Fenster).
BW_PASS_FILE="$(sudo -u "$APP_USER" mktemp)"
PASS_TMP="$(sudo -u "$APP_USER" mktemp)"
chmod 600 "$BW_PASS_FILE" "$PASS_TMP"
# Cleanup aller Secret-Dateien bei Exit (auch bei Fehlern) — beide Pfade.
# Kombiniert mit einer eventuell früher gesetzten trap-Chain, indem wir
# die Variable vorab deklarieren und hier das einzige EXIT-trap setzen.
trap 'rm -f "${BW_PASS_FILE:-}" "${PASS_TMP:-}"' EXIT
printf "%s" "$BW_PASS" > "$BW_PASS_FILE"
unset BW_PASS

sudo -u "$APP_USER" -H \
  BW_EMAIL="$BW_EMAIL" \
  BW_PASS_FILE="$BW_PASS_FILE" \
  BW_ITEM="$BW_ITEM" \
  PASS_TMP="$PASS_TMP" \
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
# Zweizeilig: erst zuweisen (failt sofort bei Fehler), dann exportieren.
GPG_PASSPHRASE="$(cat "$PASS_TMP")"
export GPG_PASSPHRASE
./scripts/decrypt-env.sh
EOSU

ok ".env geschrieben"

# ---------------------------------------------------------------- GPG-Passphrase für cron persistieren
# backup.sh läuft nightly per cron — jetzt als $APP_USER (kein sudo/root mehr).
# Damit alex die Passphrase ohne Prompt lesen kann, gehört /etc/brewing/gpg.pass
# alex (mode 600) und das Verzeichnis ebenfalls alex (mode 700). Gleiche
# Passphrase wie .env.gpg. Wird aus PASS_TMP übernommen, dann PASS_TMP gelöscht.
log "GPG-Passphrase für nightly Backup hinterlegen (/etc/brewing/gpg.pass)"
install -d -m 700 -o "$APP_USER" -g "$APP_USER" /etc/brewing
install -m 600 -o "$APP_USER" -g "$APP_USER" "$PASS_TMP" /etc/brewing/gpg.pass
rm -f "$PASS_TMP"
ok "/etc/brewing/gpg.pass geschrieben (owner ${APP_USER}, mode 600)"

# ---------------------------------------------------------------- Container starten
log "Container ziehen + starten (Profil: vps)"
sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
docker compose --profile vps pull
docker compose --profile vps up -d
EOSU
ok "Stack läuft"

# ---------------------------------------------------------------- Cloudflare reconcile
log "Cloudflare Tunnel + DNS reconcilen"
# APP_DIR als Env-Var übergeben — kein Interpolations-Risiko durch Sonderzeichen.
if sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
grep -q '^CLOUDFLARE_API_TOKEN=.\+' "$APP_DIR/.env"
EOSU
then
  sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU'
set -euo pipefail
cd "$APP_DIR"
./scripts/cloudflare-reconcile.sh
EOSU
else
  echo "  CLOUDFLARE_API_TOKEN nicht gesetzt — übersprungen."
  echo "  Hostnames manuell im Dashboard pflegen oder Token nachtragen + ./scripts/cloudflare-reconcile.sh"
fi

# ---------------------------------------------------------------- Nightly Backup (cron)
# Idempotent: /etc/cron.d/-Drop-in wird bei jedem Lauf neu geschrieben.
# Läuft direkt als $APP_USER (Mitglied der docker-Gruppe → 'docker exec' ohne
# sudo; owner von Repo + /etc/brewing/gpg.pass → liest die Passphrase ohne Prompt).
# Kein root/sudo nötig — der frühere sudoers-Drop-in entfällt komplett.
log "Nightly Backup-Cron einrichten (03:00, als ${APP_USER}, idempotent)"

# Alten sudoers-Drop-in aus früheren Bootstraps entfernen (idempotent).
rm -f /etc/sudoers.d/brewing-backup

CRON_FILE="/etc/cron.d/brewing-backup"
cat > "$CRON_FILE" <<EOF
# Brewing Postgres-Backup — nightly 03:00. Von bootstrap.sh erzeugt (idempotent).
# Läuft als ${APP_USER} (docker-Gruppe + owner gpg.pass) — kein sudo.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * ${APP_USER} ${APP_DIR}/scripts/backup.sh >> /var/log/brewing-backup.log 2>&1
EOF
chmod 644 "$CRON_FILE"
# Logfile gehört alex → cron-Job (als alex) kann reinschreiben.
touch /var/log/brewing-backup.log
chown "$APP_USER:$APP_USER" /var/log/brewing-backup.log
chmod 644 /var/log/brewing-backup.log
ok "Cron aktiv: $CRON_FILE → backup.sh als ${APP_USER} (Log: /var/log/brewing-backup.log)"

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

  Cloudflare-Hostnames/DNS: scripts/cloudflare-routes.json editieren →
  ./scripts/cloudflare-reconcile.sh (idempotent).

  Backups      nightly 03:00 (cron, als ${APP_USER}, kein sudo) → R2, je drei
               verschlüsselte Dumps (_supabase_core / brew_assistent / rapt_dashboard).
               Retention: neueste N=7 pro Ordner (lokal + R2), via BACKUP_KEEP.
               Manuell (als ${APP_USER}): ./scripts/backup.sh
  Backup-Log   tail -f /var/log/brewing-backup.log
  Restore      ./scripts/restore.sh all       (core → apps, manuell, destruktiv)

EOF
