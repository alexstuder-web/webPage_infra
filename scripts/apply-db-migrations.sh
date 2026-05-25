#!/usr/bin/env bash
# ============================================================================
# apply-db-migrations.sh — Brewing-Stack DB-Migrationen anwenden
#
# Wendet die SQL-Migrationen in der korrekten Reihenfolge auf supabase-db an:
#
#   Reihenfolge (hartverdrahtet, Abhängigkeiten beachten!):
#     1. aibrewgenius/full/001_init_schema.sql      (frisches Schema)
#     2. aibrewgenius/migrations/002_auth.sql       (Multi-User + RLS)
#     3. aibrewgenius/migrations/003_vault.sql      (API-Keys via Vault)
#     4. aibrewgenius/migrations/004_proxy_role.sql (proxy_sync-Role)
#     5. aibrewgenius/migrations/005_fix_proxy_role_grants.sql
#     6. aibrewgenius/migrations/006_retire_aibrewgenius_rapt.sql
#     7. aibrewgenius/migrations/007_harden_brewfather_search_path.sql
#     8. aibrewgenius/migrations/008_drop_aibrewgenius_rapt_columns.sql
#     9. aibrewgenius/migrations/009_drop_aibrewgenius_rapt_shims.sql
#    10. rapt/001_init_rapt_schema.sql
#    11. rapt/002_user_profiles.sql
#    12. rapt/003_device_activity_view.sql
#    13. rapt/004_rapt_user_vault.sql
#    14. rapt/005_rapt_telemetry_owner.sql
#
# Hinweis: aibrewgenius_seed.sql und test.sql sind bewusst NICHT in der
#   Migrations-Liste — sie sind dev-only und gehören nicht in ein Prod-Apply.
#
# WICHTIG: aibrewgenius-Migrationen MÜSSEN vor rapt laufen.
#   Grund: rapt/004_rapt_user_vault.sql setzt einen auth.users-Lookup per
#   email='alex@alexstuder.ch' voraus — dieser User wird erst durch
#   aibrewgenius/002_auth.sql angelegt.
#
# IDEMPOTENZ-HINWEIS:
#   001_init_schema.sql beginnt mit DROP SCHEMA IF EXISTS aibrewgenius CASCADE —
#   auf einer migrierten DB bedeutet das Datenverlust! Dieses Script ist primär
#   für eine FRISCHE DB gedacht. Re-run auf einer bereits migrierten DB nur nach
#   manueller Prüfung und Backup.
#   Migrations 002–005 und rapt 001–003 sind eingeschränkt idempotent (Transaktionen
#   mit DROP/CREATE IF EXISTS, aber Datenmigrations-Schritte können bei zweitem Lauf
#   anders verhalten). 006–009 und rapt 004–005 sind grösstenteils idempotent.
#
# Verwendung:
#   ./scripts/apply-db-migrations.sh [OPTIONEN]
#
#   Umgebungsvariablen (Override via Env oder -a/-r):
#     ASSISTENT_DB_DIR   Pfad zu brew_assistent-new/db_scripts
#                        (Default: <webPage_infra>/../brew_assistent-new/db_scripts)
#     RAPT_DB_DIR        Pfad zu RAPT_Brewing_Dashboard-new/db_scripts
#                        (Default: <webPage_infra>/../RAPT_Brewing_Dashboard-new/db_scripts)
#     DB_CONTAINER       Docker-Container-Name (Default: supabase-db)
#     DB_USER            psql-Rolle       (Default: supabase_admin)
#     DB_NAME            Datenbank-Name   (Default: postgres)
#
# Optionen:
#   -a DIR    Pfad zu brew_assistent-new/db_scripts (Override ASSISTENT_DB_DIR)
#   -r DIR    Pfad zu RAPT_Brewing_Dashboard-new/db_scripts (Override RAPT_DB_DIR)
#   -c NAME   Docker-Container-Name (Override DB_CONTAINER)
#   --dry-run Zeigt die Datei-Liste ohne tatsächlichen Apply
#   --yes     Überspringt interaktive Bestätigung (erforderlich bei Nicht-TTY/CI)
#   -h        Diese Hilfe
#
# SICHERHEITSHINWEIS:
#   001_init_schema.sql ist destruktiv (DROP SCHEMA CASCADE). Das Script
#   verlangt bei Nicht-TTY zwingend --yes; stilles Durchlaufen ohne Flag
#   wird verweigert. Damit ist versehentliches pipen/stdin-redirect sicher.
#
# Externe psql (DB-TCP-Tunnel, kein docker exec):
#   Für einen Remote-Apply via TCP-Tunnel (db-tcp.alexstuder.cloud:15432):
#     export PGHOST=db-tcp.alexstuder.cloud PGPORT=15432
#     export PGUSER=supabase_admin PGPASSWORD=<pw> PGDATABASE=postgres
#     # Dann apply-db-migrations.sh mit --external-psql aufrufen:
#     DB_CONTAINER="" EXTERNAL_PSQL=1 ./scripts/apply-db-migrations.sh
#   (EXTERNAL_PSQL=1 deaktiviert den docker-exec-Pfad, nutzt stattdessen
#    die Umgebungsvariablen PG* direkt. Setzt eine lokale psql-Installation voraus.)
#
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- Working Dir
cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"

# ---------------------------------------------------------------- Helpers
log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
err() { printf '\n\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
info(){ printf '  %s\n' "$*"; }

# ---------------------------------------------------------------- Defaults
ASSISTENT_DB_DIR="${ASSISTENT_DB_DIR:-${REPO_DIR}/../brew_assistent-new/db_scripts}"
RAPT_DB_DIR="${RAPT_DB_DIR:-${REPO_DIR}/../RAPT_Brewing_Dashboard-new/db_scripts}"
DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
DB_USER="${DB_USER:-supabase_admin}"
DB_NAME="${DB_NAME:-postgres}"
EXTERNAL_PSQL="${EXTERNAL_PSQL:-0}"
DRY_RUN=0
FORCE_YES=0

# ---------------------------------------------------------------- Argument-Parsing
usage() {
  sed -n '/^# Verwendung:/,/^# ------/p' "$0" | grep -v '^# ---' | sed 's/^# //' >&2
  exit 1
}

while getopts ":a:r:c:h-:" opt; do
  case "$opt" in
    a) ASSISTENT_DB_DIR="$OPTARG" ;;
    r) RAPT_DB_DIR="$OPTARG"      ;;
    c) DB_CONTAINER="$OPTARG"     ;;
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

# Pfade kanonisch auflösen (Symlinks + Relative bereinigen)
ASSISTENT_DB_DIR="$(cd "${ASSISTENT_DB_DIR}" 2>/dev/null && pwd)" \
  || err "ASSISTENT_DB_DIR nicht gefunden: ${ASSISTENT_DB_DIR}"
RAPT_DB_DIR="$(cd "${RAPT_DB_DIR}" 2>/dev/null && pwd)" \
  || err "RAPT_DB_DIR nicht gefunden: ${RAPT_DB_DIR}"

# ---------------------------------------------------------------- Migrations-Liste (hartverdrahtet, Reihenfolge kritisch)
# Format: "<pfad>|<label>"
#   <pfad>  — absoluter Pfad zur SQL-Datei
#   <label> — Kurzname für Logging
declare -a MIGRATIONS=(
  "${ASSISTENT_DB_DIR}/full/001_init_schema.sql|aibrewgenius/001_init_schema"
  "${ASSISTENT_DB_DIR}/migrations/002_auth.sql|aibrewgenius/002_auth"
  "${ASSISTENT_DB_DIR}/migrations/003_vault.sql|aibrewgenius/003_vault"
  "${ASSISTENT_DB_DIR}/migrations/004_proxy_role.sql|aibrewgenius/004_proxy_role"
  "${ASSISTENT_DB_DIR}/migrations/005_fix_proxy_role_grants.sql|aibrewgenius/005_fix_proxy_role_grants"
  "${ASSISTENT_DB_DIR}/migrations/006_retire_aibrewgenius_rapt.sql|aibrewgenius/006_retire_aibrewgenius_rapt"
  "${ASSISTENT_DB_DIR}/migrations/007_harden_brewfather_search_path.sql|aibrewgenius/007_harden_brewfather_search_path"
  "${ASSISTENT_DB_DIR}/migrations/008_drop_aibrewgenius_rapt_columns.sql|aibrewgenius/008_drop_aibrewgenius_rapt_columns"
  "${ASSISTENT_DB_DIR}/migrations/009_drop_aibrewgenius_rapt_shims.sql|aibrewgenius/009_drop_aibrewgenius_rapt_shims"
  "${RAPT_DB_DIR}/001_init_rapt_schema.sql|rapt/001_init_rapt_schema"
  "${RAPT_DB_DIR}/002_user_profiles.sql|rapt/002_user_profiles"
  "${RAPT_DB_DIR}/003_device_activity_view.sql|rapt/003_device_activity_view"
  "${RAPT_DB_DIR}/004_rapt_user_vault.sql|rapt/004_rapt_user_vault"
  "${RAPT_DB_DIR}/005_rapt_telemetry_owner.sql|rapt/005_rapt_telemetry_owner"
)

# ---------------------------------------------------------------- Pre-flight
log "Pre-flight Checks"

# Alle SQL-Dateien prüfen bevor wir starten
missing=()
for entry in "${MIGRATIONS[@]}"; do
  filepath="${entry%%|*}"
  [[ -f "$filepath" ]] || missing+=("$filepath")
done
if (( ${#missing[@]} > 0 )); then
  err "Fehlende SQL-Dateien — bitte App-Repos prüfen (klonen falls nötig):
$(printf '    %s\n' "${missing[@]}")"
fi
ok "Alle ${#MIGRATIONS[@]} SQL-Dateien gefunden"

if (( EXTERNAL_PSQL == 1 )); then
  # Externer psql-Pfad (TCP-Tunnel)
  command -v psql >/dev/null 2>&1 \
    || err "EXTERNAL_PSQL=1 gesetzt, aber 'psql' nicht im PATH"
  [[ -n "${PGHOST:-}" ]] \
    || err "EXTERNAL_PSQL=1 gesetzt, aber PGHOST nicht gesetzt (PG*-Variablen nötig)"
  ok "Externer psql-Modus: ${PGHOST:-}:${PGPORT:-5432} DB=${PGDATABASE:-postgres}"
else
  # Docker-exec-Pfad
  command -v docker >/dev/null 2>&1 || err "docker nicht gefunden"
  [[ -n "$DB_CONTAINER" ]] || err "DB_CONTAINER ist leer — setze -c <name> oder EXTERNAL_PSQL=1"
  # Einen einzigen inspect-Aufruf: "nicht gefunden" vs. "gefunden aber gestoppt"
  # vermeidet TOCTOU-Fenster zwischen zwei separaten Aufrufen.
  _running="$(docker inspect --format='{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" \
    || err "Container '$DB_CONTAINER' nicht gefunden — Stack starten"
  [[ "$_running" == "true" ]] \
    || err "Container '$DB_CONTAINER' läuft nicht (State.Running=${_running}) — Stack starten"
  ok "Container '$DB_CONTAINER' läuft"
fi

# ---------------------------------------------------------------- Plan ausgeben
log "Migrations-Plan (${#MIGRATIONS[@]} Dateien, aibrewgenius → rapt)"
i=0
for entry in "${MIGRATIONS[@]}"; do
  i=$(( i + 1 ))
  label="${entry##*|}"
  filepath="${entry%%|*}"
  printf '  %2d. %-55s (%d Zeilen)\n' "$i" "$label" "$(wc -l < "$filepath")"
done

if (( DRY_RUN == 1 )); then
  printf '\n\033[1;33m  DRY-RUN — kein Apply. Abbrechen.\033[0m\n'
  exit 0
fi

echo
printf '  \033[1;33mHINWEIS: 001_init_schema.sql beginnt mit DROP SCHEMA aibrewgenius CASCADE.\033[0m\n'
printf '  \033[1;33m         Nur auf einer FRISCHEN DB ausführen oder wenn ein Backup vorhanden ist.\033[0m\n'
if (( FORCE_YES == 1 )); then
  # --yes explizit übergeben → kein Prompt; Log damit nachvollziehbar bleibt.
  printf '  \033[1;33m  --yes gesetzt — interaktive Bestätigung übersprungen.\033[0m\n'
elif [[ -t 0 ]]; then
  # Interaktive Shell → Prompt
  read -rp "  Migrationen anwenden? [y/N] " _confirm
  [[ "$_confirm" =~ ^[Yy]$ ]] || { echo "  Abgebrochen."; exit 0; }
else
  # Kein TTY und kein --yes → abbrechen (verhindert stilles Durchlaufen in Pipes/CI)
  err "Kein TTY erkannt und --yes nicht gesetzt. Destruktiven Apply bitte explizit mit --yes bestätigen."
fi

# ---------------------------------------------------------------- Apply-Funktion
_apply_one() {
  local filepath="$1"
  local label="$2"

  if (( EXTERNAL_PSQL == 1 )); then
    # Externer psql-Pfad: PG*-Umgebungsvariablen steuern Verbindung.
    # Kein Passwort in argv (PGPASSWORD via Env).
    psql \
      --username="${PGUSER:-${DB_USER}}" \
      --dbname="${PGDATABASE:-${DB_NAME}}" \
      --variable=ON_ERROR_STOP=1 \
      --file="$filepath" \
      >/dev/null
  else
    # Docker-exec-Pfad: SQL-Datei per Stdin (kein Mounten nötig).
    # PGPASSWORD in docker exec -e damit kein Klartext in argv.
    # ON_ERROR_STOP=1: psql bricht bei erstem Fehler ab (Exit-Code != 0).
    docker exec -i \
      -e PGPASSWORD="${POSTGRES_PASSWORD:-}" \
      "$DB_CONTAINER" \
      psql \
        --username="$DB_USER" \
        --dbname="$DB_NAME" \
        --variable=ON_ERROR_STOP=1 \
        --no-psqlrc \
      < "$filepath" \
      >/dev/null
  fi
}

# ---------------------------------------------------------------- Apply-Loop
log "Migrationen anwenden"

# POSTGRES_PASSWORD für docker exec -e laden (falls .env vorhanden und nicht external)
if (( EXTERNAL_PSQL == 0 )) && [[ -f "${REPO_DIR}/.env" ]]; then
  # Nur POSTGRES_PASSWORD herausziehen — kein blindes 'source .env'
  # (würde alle Vars in den Scope laden, inkl. sensitiver Keys).
  _pw_line="$(grep -E '^POSTGRES_PASSWORD=' "${REPO_DIR}/.env" | head -1 || true)"
  if [[ -n "$_pw_line" ]]; then
    POSTGRES_PASSWORD="${_pw_line#*=}"
    export POSTGRES_PASSWORD
  fi
fi

failed=0
for entry in "${MIGRATIONS[@]}"; do
  filepath="${entry%%|*}"
  label="${entry##*|}"

  printf '\n  \033[1;34m▶ Applying: %s\033[0m\n' "$label"

  rc=0
  _apply_one "$filepath" "$label" || rc=$?

  if (( rc != 0 )); then
    printf '\n\033[1;31m✖ FEHLER bei %s (Exit-Code %d)\033[0m\n' "$label" "$rc" >&2
    printf '  Migration abgebrochen. Folgemigrationen wurden NICHT angewendet.\n' >&2
    printf '  Nächster Schritt: Fehler analysieren, ggf. Backup einspielen,\n' >&2
    printf '  dann ab dieser Migration neu starten.\n' >&2
    failed=1
    break
  fi

  ok "$label"
done

# ---------------------------------------------------------------- Ergebnis
echo
if (( failed == 1 )); then
  err "Migrations-Apply mit Fehler abgebrochen (siehe Ausgabe oben)"
fi

log "Alle ${#MIGRATIONS[@]} Migrationen erfolgreich angewendet"
info "Empfohlene Verifikation:"
info "  docker exec -e PGPASSWORD=... supabase-db psql -U supabase_admin -d postgres \\"
info "    -c \"SELECT count(*) FROM aibrewgenius.user_profiles;\""
info "  docker exec -e PGPASSWORD=... supabase-db psql -U supabase_admin -d postgres \\"
info "    -c \"SELECT count(*) FROM rapt.controllers;\""
