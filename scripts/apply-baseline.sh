#!/usr/bin/env bash
# ============================================================================
# apply-baseline.sh — Konsolidierten Schema-Baseline auf frische DB anwenden
#
# Wendet webPage_infra/db_scripts/baseline_schema.sql auf supabase-db an.
# Deckt den End-Zustand aller 14 historischen Migrationen ab (aibrewgenius
# 001–009 + rapt 001–005) in einem einzigen SQL-File — getestet auf zwei
# frischen supabase/postgres:15.8.1.060-Instanzen.
#
# NUR für frische Deploys gedacht (keine Prod-Daten vorhanden).
# Für laufende Prod-DBs → Migrationen einzeln via apply-db-migrations.sh.
# Neue Schema-Änderungen NACH dem Live-Start → neue Migrations-Dateien auf
# dem Baseline, NICHT diesen Baseline editieren.
#
# Verwendung:
#   ./scripts/apply-baseline.sh [OPTIONEN]
#
#   Umgebungsvariablen:
#     DB_CONTAINER   Docker-Container-Name      (Default: supabase-db)
#     DB_USER        psql-Rolle                 (Default: supabase_admin)
#     DB_NAME        Datenbank-Name             (Default: postgres)
#     EXTERNAL_PSQL  1 → externer psql via PG*  (Default: 0)
#
# Optionen:
#   --dry-run   Zeigt Plan ohne tatsächlichen Apply
#   --yes       Überspringt interaktive Bestätigung (Pflicht bei Nicht-TTY/CI)
#   -c NAME     Docker-Container-Name (Override DB_CONTAINER)
#   -h          Diese Hilfe
#
# Externer Apply via DB-TCP-Tunnel (kein docker exec):
#   export PGHOST=db-tcp.alexstuder.cloud PGPORT=15432
#   export PGUSER=supabase_admin PGPASSWORD=<pw> PGDATABASE=postgres
#   EXTERNAL_PSQL=1 ./scripts/apply-baseline.sh --yes
#
# SICHERHEITSHINWEIS:
#   Der Baseline enthält DROP SCHEMA IF EXISTS ... CASCADE für aibrewgenius
#   und rapt. Auf einer DB mit Prod-Daten bedeutet das Datenverlust.
#   Das Script verlangt bei Nicht-TTY zwingend --yes; stilles Durchlaufen
#   ohne Flag (z.B. via Pipe/stdin-Redirect) wird verweigert.
#   Passwörter landen niemals in argv oder Logzeilen.
#
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- Working Dir
cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"

# ---------------------------------------------------------------- Helpers
log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
err()  { printf '\n\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------- Defaults
DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
DB_USER="${DB_USER:-supabase_admin}"
DB_NAME="${DB_NAME:-postgres}"
EXTERNAL_PSQL="${EXTERNAL_PSQL:-0}"
DRY_RUN=0
FORCE_YES=0

BASELINE_FILE="${REPO_DIR}/db_scripts/baseline_schema.sql"

# ---------------------------------------------------------------- Argument-Parsing
usage() {
  grep '^# Verwendung:' -A 30 "$0" | grep -v '^# ---' | sed 's/^# //' >&2
  exit 1
}

while getopts ":c:h-:" opt; do
  case "$opt" in
    c) DB_CONTAINER="$OPTARG" ;;
    h) usage ;;
    -)
      case "$OPTARG" in
        dry-run) DRY_RUN=1 ;;
        yes)     FORCE_YES=1 ;;
        *)       err "Unbekannte Option: --${OPTARG}" ;;
      esac
      ;;
    :) err "Option -${OPTARG} erfordert ein Argument" ;;
    ?) err "Unbekannte Option: -${OPTARG}" ;;
  esac
done
shift $(( OPTIND - 1 ))
[[ $# -eq 0 ]] || err "Unbekannte Argumente: $*"

# ---------------------------------------------------------------- Pre-flight
log "Pre-flight Checks"

[[ -f "$BASELINE_FILE" ]] \
  || err "Baseline-Datei nicht gefunden: ${BASELINE_FILE}"
ok "Baseline-Datei gefunden: db_scripts/baseline_schema.sql ($(wc -l < "$BASELINE_FILE") Zeilen)"

if (( EXTERNAL_PSQL == 1 )); then
  command -v psql >/dev/null 2>&1 \
    || err "EXTERNAL_PSQL=1 gesetzt, aber 'psql' nicht im PATH"
  [[ -n "${PGHOST:-}" ]] \
    || err "EXTERNAL_PSQL=1 gesetzt, aber PGHOST nicht gesetzt (PG*-Variablen nötig)"
  ok "Externer psql-Modus: ${PGHOST}:${PGPORT:-5432} DB=${PGDATABASE:-postgres}"
else
  command -v docker >/dev/null 2>&1 || err "docker nicht gefunden"
  [[ -n "$DB_CONTAINER" ]] \
    || err "DB_CONTAINER ist leer — setze -c <name> oder EXTERNAL_PSQL=1"
  _running="$(docker inspect --format='{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" \
    || err "Container '$DB_CONTAINER' nicht gefunden — Stack starten"
  [[ "$_running" == "true" ]] \
    || err "Container '$DB_CONTAINER' läuft nicht (State.Running=${_running}) — Stack starten"
  ok "Container '$DB_CONTAINER' läuft"
fi

# ---------------------------------------------------------------- Plan ausgeben
log "Baseline-Apply Plan"
info "Datei  : db_scripts/baseline_schema.sql"
info "Ziel   : ${DB_CONTAINER:-extern (PG*)} / User=${DB_USER} / DB=${DB_NAME}"
info "Inhalt : aibrewgenius (001–009) + rapt (001–005), konsolidiert"
info "WARNUNG: enthält DROP SCHEMA IF EXISTS aibrewgenius CASCADE"
info "         + DROP SCHEMA IF EXISTS rapt CASCADE"
info "         → Datenverlust auf einer bereits migrierten DB!"

if (( DRY_RUN == 1 )); then
  printf '\n\033[1;33m  DRY-RUN — kein Apply. Abbrechen.\033[0m\n'
  exit 0
fi

echo
printf '  \033[1;33mHINWEIS: Der Baseline beginnt mit DROP SCHEMA ... CASCADE für\033[0m\n'
printf '  \033[1;33m         aibrewgenius UND rapt. Nur auf einer FRISCHEN DB ausführen\033[0m\n'
printf '  \033[1;33m         oder wenn ein Backup vorhanden und bestätigt ist.\033[0m\n'

if (( FORCE_YES == 1 )); then
  printf '  \033[1;33m  --yes gesetzt — interaktive Bestätigung übersprungen.\033[0m\n'
elif [[ -t 0 ]]; then
  read -rp "  Baseline anwenden? [y/N] " _confirm
  [[ "$_confirm" =~ ^[Yy]$ ]] || { echo "  Abgebrochen."; exit 0; }
else
  err "Kein TTY erkannt und --yes nicht gesetzt. Destruktiven Apply bitte explizit mit --yes bestätigen."
fi

# ---------------------------------------------------------------- Passwort laden (docker-exec-Pfad)
# Nur POSTGRES_PASSWORD selektiv herausziehen — kein blindes 'source .env'
# (würde alle Secrets in den Shell-Scope laden).
POSTGRES_PASSWORD=""
if (( EXTERNAL_PSQL == 0 )) && [[ -f "${REPO_DIR}/.env" ]]; then
  _pw_line="$(grep -E '^POSTGRES_PASSWORD=' "${REPO_DIR}/.env" | head -1 || true)"
  if [[ -n "$_pw_line" ]]; then
    POSTGRES_PASSWORD="${_pw_line#*=}"
    export POSTGRES_PASSWORD
  fi
fi

# ---------------------------------------------------------------- Apply
log "Baseline anwenden"
printf '\n  \033[1;34m▶ Applying: baseline_schema.sql\033[0m\n'

if (( EXTERNAL_PSQL == 1 )); then
  # Externer psql-Pfad: PG*-Umgebungsvariablen steuern Verbindung.
  # Kein Passwort in argv (PGPASSWORD via Env).
  psql \
    --username="${PGUSER:-${DB_USER}}" \
    --dbname="${PGDATABASE:-${DB_NAME}}" \
    --variable=ON_ERROR_STOP=1 \
    --file="$BASELINE_FILE" \
    >/dev/null
else
  # Docker-exec-Pfad: SQL per Stdin (kein Mounten nötig).
  # PGPASSWORD via -e damit kein Klartext in argv.
  docker exec -i \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    "$DB_CONTAINER" \
    psql \
      --username="$DB_USER" \
      --dbname="$DB_NAME" \
      --variable=ON_ERROR_STOP=1 \
      --no-psqlrc \
    < "$BASELINE_FILE" \
    >/dev/null
fi

# ---------------------------------------------------------------- Ergebnis
ok "baseline_schema.sql erfolgreich angewendet"
echo
log "Baseline-Apply abgeschlossen"
info "Empfohlene Verifikation:"
info "  docker exec -e PGPASSWORD=... ${DB_CONTAINER} psql -U ${DB_USER} -d ${DB_NAME} \\"
info "    -c \"SELECT count(*) FROM aibrewgenius.user_profiles;\""
info "  docker exec -e PGPASSWORD=... ${DB_CONTAINER} psql -U ${DB_USER} -d ${DB_NAME} \\"
info "    -c \"SELECT count(*) FROM rapt.controllers;\""
info ""
info "Nächste Schritte nach dem Baseline-Apply:"
info "  1. proxy_sync-Passwort prüfen (PROD_ROLLOUT.md Schritt 3)"
info "  2. App-Container deployen (Watchtower / manuell)"
info "  3. Live-Gates A/B/C durchlaufen (PROD_ROLLOUT.md Schritt 4)"
