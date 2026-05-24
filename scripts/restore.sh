#!/usr/bin/env bash
# ============================================================================
# Brewing-Stack Postgres-Restore — Variante A (manuell, destruktiv)
#
#   restore.sh <target> [file|latest] [--yes]
#
#   target:  core | brew_assistent | rapt_dashboard | all
#   quelle:  'latest' (default) → jüngste .fc.gpg aus dem passenden R2-Ordner
#            <pfad>             → lokale .fc.gpg-Datei einspielen
#
#   restore.sh core                        → core, jüngstes aus R2
#   restore.sh brew_assistent latest       → aibrewgenius, jüngstes aus R2
#   restore.sh rapt_dashboard backups/rapt_dashboard/rapt_20260523_030000.fc.gpg
#   restore.sh all                         → core, dann brew_assistent, dann rapt
#
# Flow je Dump:
#   (R2 holen) → entschlüsseln (gpg, kein Klartext-Dump bleibt liegen) →
#   pg_restore --clean --if-exists --no-owner -U supabase_admin -d postgres
#
# REIHENFOLGE bei 'all' ist zwingend: core ZUERST (auth.users muss existieren),
# dann brew_assistent (aibrewgenius), dann rapt_dashboard (rapt) — beide App-
# Schemas FK'en auf auth.users.
#
# ⚠️  --clean droppt vorhandene Objekte vor dem Neuanlegen. Läuft NIE ohne
#     explizites Ziel-Argument + interaktive Bestätigung (oder --yes).
#
# Voraussetzung: laufender Stack (Image-Init hat Roles/Schemas angelegt).
# Restore ist bewusst NICHT Teil von bootstrap.sh.
#
# PASSPHRASE-QUELLE (gleiche Passphrase wie .env.gpg), in dieser Reihenfolge:
#   1. --passphrase-file $GPG_PASS_FILE (default /etc/brewing/gpg.pass).
#      Auf dem VPS gehört diese Datei alex (mode 600) → manueller Restore als
#      alex liest sie automatisch, kein Export nötig.
#   2. $GPG_PASSPHRASE (Env) — wenn die Datei fehlt/nicht lesbar ist:
#         export GPG_PASSPHRASE="$(bw get password ALEXSTUDER_WEBPAGE_GPG_PASSWORD)"
#   3. interaktiver Prompt (nur mit TTY).
# Die Passphrase landet immer in einer mode-600-Tempdatei (--passphrase-file),
# nie auf der Kommandozeile/in ps.
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"
ENV_FILE="${REPO_DIR}/.env"
DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
PASS_FILE="${GPG_PASS_FILE:-/etc/brewing/gpg.pass}"

# ---------------------------------------------------------------- Helpers
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
err()  { echo -e "\n\033[1;31m✖ $*\033[0m" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: $0 <core|brew_assistent|rapt_dashboard|all> [file|latest] [--yes]

  core             Restore _supabase_core (auth/storage/public/_realtime/Rest).
  brew_assistent   Restore Schema aibrewgenius.
  rapt_dashboard   Restore Schema rapt.
  all              Restore in zwingender Reihenfolge: core → brew_assistent → rapt_dashboard.

  [file|latest]    'latest' (default) zieht die jüngste .fc.gpg aus dem
                   passenden R2-Ordner. Ein Pfad spielt eine lokale Datei ein
                   (nur sinnvoll mit einem konkreten Ziel, nicht mit 'all').
  --yes            Sicherheitsabfrage überspringen (für Automatisierung).

  Beispiele:
    $0 all
    $0 core
    $0 rapt_dashboard latest
    $0 brew_assistent backups/brew_assistent/aibrewgenius_20260523_030000.fc.gpg
EOF
  exit 1
}

# Ordner + Schema-Restore-Argument je Ziel.
target_folder() {
  case "$1" in
    core)           echo "_supabase_core" ;;
    brew_assistent) echo "brew_assistent" ;;
    rapt_dashboard) echo "rapt_dashboard" ;;
    *)              err "Unbekanntes Ziel: $1" ;;
  esac
}

# ---------------------------------------------------------------- Args
[[ $# -ge 1 ]] || usage   # nie ohne explizites Ziel
TARGET=""
SOURCE=""
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    -*)        err "Unbekanntes Argument: $1" ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      elif [[ -z "$SOURCE" ]]; then
        SOURCE="$1"
      else
        err "Zu viele Positions-Argumente ('$1')"
      fi
      shift ;;
  esac
done
[[ -n "$TARGET" ]] || usage
case "$TARGET" in core|brew_assistent|rapt_dashboard|all) ;; *) err "Ungültiges Ziel '$TARGET'"; ;; esac
[[ -n "$SOURCE" ]] || SOURCE="latest"

if [[ "$TARGET" == "all" && "$SOURCE" != "latest" ]]; then
  err "'all' geht nur mit 'latest' (drei Ordner → ein Dateipfad ist mehrdeutig)"
fi

# ---------------------------------------------------------------- Pre-flight
command -v docker >/dev/null 2>&1 || err "docker fehlt"
command -v gpg    >/dev/null 2>&1 || err "gpg fehlt"
[[ -f "$ENV_FILE" ]] || err "Keine .env — erst ./scripts/decrypt-env.sh"
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 \
  || err "Container '$DB_CONTAINER' läuft nicht — Stack starten"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
: "${POSTGRES_PASSWORD:?fehlt in .env}"

# ---------------------------------------------------------------- Temp-Workspace
WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
PASS_TMP="$(mktemp)"
chmod 600 "$PASS_TMP"
# Räumt ALLES weg: entschlüsselte Dumps + Passphrase, auch bei Abbruch.
trap 'rm -rf "$WORK_DIR"; rm -f "$PASS_TMP"' EXIT

# ---------------------------------------------------------------- Passphrase
if [[ -r "$PASS_FILE" ]]; then
  cat "$PASS_FILE" > "$PASS_TMP"
elif [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  printf '%s' "$GPG_PASSPHRASE" > "$PASS_TMP"
else
  [[ -t 0 ]] || err "Keine Passphrase-Quelle ($PASS_FILE nicht lesbar, \$GPG_PASSPHRASE leer, kein TTY)"
  read -rsp "GPG-Passphrase: " _pp; echo
  printf '%s' "$_pp" > "$PASS_TMP"
  unset _pp
fi
[[ -s "$PASS_TMP" ]] || err "Passphrase ist leer"

# ---------------------------------------------------------------- R2-Remote (für 'latest')
R2_READY=0
setup_r2_remote() {
  (( R2_READY == 1 )) && return 0
  : "${R2_ACCESS_KEY_ID:?fehlt in .env (R2 für 'latest')}"
  : "${R2_SECRET_ACCESS_KEY:?fehlt in .env}"
  : "${R2_BUCKET:?fehlt in .env}"
  local endpoint="${R2_ENDPOINT:-}"
  if [[ -z "$endpoint" ]]; then
    : "${R2_ACCOUNT_ID:?fehlt in .env (R2_ENDPOINT oder R2_ACCOUNT_ID nötig)}"
    endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  fi
  command -v rclone >/dev/null 2>&1 || err "rclone fehlt — für 'latest' nötig (bootstrap installiert es)"
  # Creds via Env-Vars, NICHT in argv (nicht ps-sichtbar).
  export RCLONE_CONFIG_R2_TYPE="s3"
  export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="$endpoint"
  export RCLONE_CONFIG_R2_REGION="auto"
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET="true"
  R2_READY=1
}

# Holt die jüngste .fc.gpg eines R2-Ordners → lokale Tempdatei, gibt Pfad aus.
fetch_latest_from_r2() {
  local folder="$1"
  setup_r2_remote
  local latest
  latest="$(rclone lsf "R2:${R2_BUCKET}/${folder}/" --include '*.fc.gpg' 2>/dev/null \
            | sort | tail -1)"
  [[ -n "$latest" ]] || err "Kein *.fc.gpg in R2 ${R2_BUCKET}/${folder}/ gefunden"
  local dest="${WORK_DIR}/${folder}__${latest}"
  rclone copyto "R2:${R2_BUCKET}/${folder}/${latest}" "$dest" \
    || err "rclone-Download fehlgeschlagen: ${folder}/${latest}"
  echo "$dest"
}

# ---------------------------------------------------------------- Ein Ziel restoren
restore_one() {
  local target="$1" source="$2"
  local folder; folder="$(target_folder "$target")"
  local enc_file desc

  if [[ "$source" == "latest" ]]; then
    log "[$target] Jüngste .fc.gpg aus R2 ${R2_BUCKET:-?}/${folder}/ holen"
    enc_file="$(fetch_latest_from_r2 "$folder")"
    desc="R2:${folder}/$(basename "${enc_file#*__}")"
    ok "[$target] geholt: $(basename "$enc_file")"
  else
    [[ -f "$source" ]] || err "Datei nicht gefunden: $source"
    enc_file="$source"
    desc="$source"
  fi

  # Entschlüsseln in den Workspace (kein Klartext-Dump bleibt liegen).
  local dump="${WORK_DIR}/${target}.fc"
  gpg --batch --yes --decrypt --pinentry-mode loopback \
      --passphrase-file "$PASS_TMP" -o "$dump" "$enc_file" \
    || err "[$target] Entschlüsselung fehlgeschlagen (falsche Passphrase / korrupte Datei?)"
  [[ -s "$dump" ]] || err "[$target] Entschlüsselter Dump ist leer"

  log "[$target] pg_restore (Quelle: ${desc})"
  echo "  Ziel: Container ${DB_CONTAINER} → DB 'postgres' (--clean --if-exists --no-owner)"
  # pg_restore wird NICHT mit -e/--exit-on-error aufgerufen: Supabase emittiert
  # bekannte nicht-fatale Fehler (supabase_realtime-Publication, extensions-Schema,
  # pgsodium/Vault, bereits vom Image angelegte Roles). Erfolg wird über die
  # Tabellen-Counts/Smoke-Check bewertet, nicht über den Exit-Code.
  #
  # Exit-Code via '|| rc=$?' einfangen, OHNE set-State zu togglen: das ist ein
  # einzelner Befehl (kein Pipe → pipefail irrelevant) und der '|| ...'-Zweig
  # neutralisiert errexit nur für genau dieses Kommando. Kein 'set +e/-e'-Paar,
  # das bei vorzeitigem Abbruch errexit dauerhaft falsch hinterlassen könnte.
  local rc=0
  docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    pg_restore --clean --if-exists --no-owner -U supabase_admin -d postgres < "$dump" \
    || rc=$?
  if (( rc != 0 )); then
    echo "  [$target] pg_restore Exit-Code: $rc — bei Supabase oft nicht-fatal (s. README)."
  fi
  rm -f "$dump"
  ok "[$target] pg_restore durchgelaufen"
}

# ---------------------------------------------------------------- Verifikation
verify_count() {
  local schema="$1" tbl="$2"
  local n
  n="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
        psql -tA -U supabase_admin -d postgres \
        -c "SELECT count(*) FROM ${schema}.${tbl};" 2>/dev/null || echo "n/a")"
  printf '  %-32s %s\n' "${schema}.${tbl}" "$n"
}

# ---------------------------------------------------------------- Plan + Bestätigung
declare -a PLAN=()
if [[ "$TARGET" == "all" ]]; then
  PLAN=(core brew_assistent rapt_dashboard)   # zwingende Reihenfolge
else
  PLAN=("$TARGET")
fi

log "RESTORE — destruktiv"
echo "  Reihenfolge: ${PLAN[*]}"
echo "  Quelle:      ${SOURCE}"
echo "  Ziel:        Container ${DB_CONTAINER} → DB 'postgres'"
echo "  Hinweis:     --clean --if-exists droppt vorhandene Objekte vor dem Neuanlegen."
echo
if (( ASSUME_YES == 0 )); then
  [[ -t 0 ]] || err "Kein TTY und kein --yes — Restore aus Sicherheitsgründen abgebrochen"
  read -rp "Wirklich einspielen? Tippe 'restore' zum Bestätigen: " ans
  [[ "$ans" == "restore" ]] || err "Abgebrochen (keine Bestätigung)"
fi

# ---------------------------------------------------------------- Ausführung (in Reihenfolge)
for t in "${PLAN[@]}"; do
  restore_one "$t" "$SOURCE"
done

# ---------------------------------------------------------------- Verifikation
log "Verifikation (Tabellen-Counts je Schema)"
for t in "${PLAN[@]}"; do
  case "$t" in
    core)           verify_count auth users ;;
    brew_assistent) verify_count aibrewgenius recipes 2>/dev/null || true ;;
    rapt_dashboard) verify_count rapt brew_sessions 2>/dev/null || true ;;
  esac
done

log "✓ Restore abgeschlossen"
echo "  Nächster Smoke-Check: Login in der App + je eine Query auf aibrewgenius.* und rapt.*"
