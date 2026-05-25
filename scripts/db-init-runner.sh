#!/usr/bin/env bash
# ============================================================================
# db-init-runner.sh — Per-App DB Init-Container-Runner
#
# Läuft ALS psql-Client inside des db-init-<stack>-Containers (kein docker exec).
# Verbindung per TCP zu $DB_HOST:5432 im jeweiligen Stack-Netz.
#
# Ablauf (idempotent):
#   1. Warte auf auth.users (GoTrue-Readiness-Poll, max WAIT_MAX Sekunden)
#   2. Baseline-Gate: fehlende schema_migrations-Tabelle ODER fehlende Version '000'
#      → BASELINE_FILE anwenden (idempotent via ON CONFLICT DO NOTHING / CREATE IF NOT EXISTS)
#   3. Pending-Discovery: Lese Applied-Set aus schema_migrations; sammle
#      MIGRATIONS_DIR/[0-9][0-9][0-9]_*.sql-Files, parse 3-stellige Version,
#      sortiere numerisch aufsteigend; wende nur nicht-applied an.
#   4. Apply: psql --variable=ON_ERROR_STOP=1 pro File (Transaktion im Migrations-File).
#      Schlägt ein Apply fehl → sofort Stop, Exit ≠ 0 (Folge-Migrationen NICHT anwenden).
#   5. Pre-Migration-Backup-Gate (REQUIRE_PREMIGRATION_BACKUP=1): prüft
#      /etc/brewing/stateful-units.d/db-<STACK_LABEL> + Backup-Marker.
#      Standard: REQUIRE_PREMIGRATION_BACKUP=0 (Phase-4-scharfschalten).
#
# Env-Variablen (pflicht):
#   DB_HOST                 Hostname des Postgres-Containers (z.B. db-assistent)
#   PGPASSWORD              Postgres-Passwort (via Compose environment:, NIE argv)
#   BASELINE_FILE           Absoluter Pfad zur baseline.sql im Mount (/sql/...)
#   MIGRATIONS_DIR          Absoluter Pfad zum migrations/-Verzeichnis (/sql/migrations)
#   STACK_LABEL             Kurzname des Stacks (assistent | rapt) — für Logging + Gate
#
# Env-Variablen (optional):
#   PGUSER                  Default: supabase_admin
#   PGDATABASE              Default: postgres
#   PGPORT                  Default: 5432
#   WAIT_MAX                Timeout in Sekunden für auth.users-Poll (Default: 120)
#   WAIT_INTERVAL           Poll-Intervall in Sekunden (Default: 5)
#   REQUIRE_PREMIGRATION_BACKUP  0 (default) oder 1 (Phase-4-scharfschalten)
#
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- Helpers
log()  { printf '\n\033[1;34m[db-init-%s] ▶ %s\033[0m\n' "${STACK_LABEL:-?}" "$*"; }
ok()   { printf '\033[1;32m[db-init-%s]   ✓ %s\033[0m\n' "${STACK_LABEL:-?}" "$*"; }
err()  { printf '\n\033[1;31m[db-init-%s] ✖ %s\033[0m\n' "${STACK_LABEL:-?}" "$*" >&2; exit 1; }
info() { printf '[db-init-%s]   %s\n' "${STACK_LABEL:-?}" "$*"; }
warn() { printf '\033[1;33m[db-init-%s]   ⚠ %s\033[0m\n' "${STACK_LABEL:-?}" "$*" >&2; }

# ---------------------------------------------------------------- Env-Validierung
: "${DB_HOST:?DB_HOST muss gesetzt sein}"
: "${PGPASSWORD:?PGPASSWORD muss gesetzt sein}"
: "${BASELINE_FILE:?BASELINE_FILE muss gesetzt sein}"
: "${MIGRATIONS_DIR:?MIGRATIONS_DIR muss gesetzt sein}"
: "${STACK_LABEL:?STACK_LABEL muss gesetzt sein}"

# Feste psql-Verbindungsparameter (nicht via argv — PGPASSWORD via Env)
export PGUSER="${PGUSER:-supabase_admin}"
export PGDATABASE="${PGDATABASE:-postgres}"
export PGHOST="$DB_HOST"
export PGPORT="${PGPORT:-5432}"
# PGPASSWORD bereits gesetzt (aus Compose environment:)

WAIT_MAX="${WAIT_MAX:-120}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"
REQUIRE_PREMIGRATION_BACKUP="${REQUIRE_PREMIGRATION_BACKUP:-0}"
# MIGRATIONS_PATTERN ist ein Vertrags-Konstant (Vertrag mit dba-coder) — kein Env-Var.
# Dateinamen-Schema: NNN_beschreibung.sql (3-stellige Versions-Nummer + Unterstrich).
readonly MIGRATIONS_PATTERN="[0-9][0-9][0-9]_*.sql"

# ---------------------------------------------------------------- psql-Wrapper
# Führt eine einzeilige psql-Abfrage aus; gibt Ergebnis auf stdout.
# PGPASSWORD, PGUSER, PGHOST, PGPORT, PGDATABASE sind bereits exportiert.
# Nie Passwörter/Queries als argv — sql kommt via -c oder --file.
_psql_query() {
  # $1 = SQL-Abfrage (kurze tAc-Query)
  psql --no-psqlrc -tAc "$1"
}

_psql_file() {
  # $1 = Pfad zur SQL-Datei
  # --variable=ON_ERROR_STOP=1: Fail-Fast — psql bricht bei erstem Fehler ab (Exit ≠ 0).
  # KEIN --single-transaction: die Migrations-Files verwalten ihre eigene BEGIN/COMMIT-
  # Transaktion (dba-Template-Konvention). --single-transaction würde ein "transaction
  # already in progress"-Warning triggern und ist redundant.
  psql --no-psqlrc \
       --variable=ON_ERROR_STOP=1 \
       --file="$1"
}

# ---------------------------------------------------------------- Schritt 1: auth.users-Poll
# GoTrue läuft nach Postgres-initdb und legt auth.users via eigene Migrationen an.
# Wir warten, bis die Tabelle existiert (to_regclass gibt OID-Text zurück wenn vorhanden).
# Lesson: psql-Exit-Code GETRENNT vom Result erfassen — Verbindungsfehler (rc≠0)
# ≠ „Tabelle noch nicht da" (rc=0, leeres Ergebnis).
log "Warte auf auth.users (max ${WAIT_MAX}s, Intervall ${WAIT_INTERVAL}s)"

waited=0
auth_ready=0
while (( waited < WAIT_MAX )); do
  # psql-Exit-Code separat erfassen (nicht '|| echo fallback').
  # rc=1: transiente Verbindungsstörung (DB noch nicht bereit, GoTrue startet noch) → retry.
  # rc=2: Auth-Fehler (falsches Passwort) → sofort hart abbrechen — Retry hilft nicht.
  # rc=0, leeres Ergebnis: DB da, auth.users noch nicht migriert → retry.
  _result=""
  _rc=0
  _result="$( _psql_query "SELECT to_regclass('auth.users')" 2>/dev/null )" || _rc=$?

  if (( _rc == 2 )); then
    # Authentifizierungsfehler — falsches Passwort, kein Retry-Sinn
    err "psql-Authentifizierung fehlgeschlagen (rc=2) — falsches Passwort?
  Pruefen: PGPASSWORD / ${STACK_LABEL^^}_POSTGRES_PASSWORD in .env
  docker logs ${DB_HOST}"
  elif (( _rc != 0 )); then
    # rc=1 oder anderer transienter Fehler — DB noch nicht bereit (Connection refused,
    # Postgres startet noch, GoTrue hat auth-Schema noch nicht migriert).
    warn "psql rc=${_rc} bei ${DB_HOST}:${PGPORT} — transient, retry in ${WAIT_INTERVAL}s (${waited}s / ${WAIT_MAX}s)"
    sleep "$WAIT_INTERVAL"
    waited=$(( waited + WAIT_INTERVAL ))
    continue
  fi

  # Leerzeichen entfernen; nicht-leeres Ergebnis = Tabelle existiert
  _result="${_result//[[:space:]]/}"
  if [[ -n "$_result" ]]; then
    auth_ready=1
    break
  fi

  printf '[db-init-%s]   ... %ds / %ds — auth.users noch nicht vorhanden\n' \
    "$STACK_LABEL" "$waited" "$WAIT_MAX"
  sleep "$WAIT_INTERVAL"
  waited=$(( waited + WAIT_INTERVAL ))
done

if (( auth_ready == 0 )); then
  err "Timeout: auth.users nach ${WAIT_MAX}s noch nicht gefunden.
  GoTrue (auth-${STACK_LABEL}-Container) hat seine Migrationen noch nicht abgeschlossen.
  Massnahmen:
    1. docker logs auth-${STACK_LABEL}  (GoTrue-Migrations-Fehler pruefen)
    2. docker compose ps                (Container-Status)
    3. Init-Container neu starten: docker compose start db-init-${STACK_LABEL}"
fi

ok "auth.users vorhanden (nach ${waited}s)"

# ---------------------------------------------------------------- Schritt 2: Baseline-Gate
# Baseline anwenden wenn:
#   (a) public.schema_migrations nicht existiert, ODER
#   (b) Version '000' nicht vorhanden
log "Baseline-Gate pruefen"

_sm_exists=""
_rc=0
_sm_exists="$( _psql_query "SELECT to_regclass('public.schema_migrations')" 2>/dev/null )" || _rc=$?
if (( _rc != 0 )); then
  err "psql-Abfrage (schema_migrations-Check) fehlgeschlagen (rc=${_rc})"
fi
_sm_exists="${_sm_exists//[[:space:]]/}"

_need_baseline=0
if [[ -z "$_sm_exists" ]]; then
  info "public.schema_migrations nicht vorhanden → Baseline anwenden"
  _need_baseline=1
else
  _v000=""
  _rc=0
  _v000="$( _psql_query "SELECT version FROM public.schema_migrations WHERE version='000'" 2>/dev/null )" || _rc=$?
  if (( _rc != 0 )); then
    err "psql-Abfrage (Version-000-Check) fehlgeschlagen (rc=${_rc})"
  fi
  _v000="${_v000//[[:space:]]/}"
  if [[ -z "$_v000" ]]; then
    info "Version '000' fehlt in schema_migrations → Baseline anwenden"
    _need_baseline=1
  else
    ok "Baseline bereits angewendet (Version '000' vorhanden) — Baseline-Gate: No-op"
  fi
fi

is_fresh_db=0
if (( _need_baseline == 1 )); then
  is_fresh_db=1
  [[ -f "$BASELINE_FILE" ]] \
    || err "BASELINE_FILE nicht gefunden: ${BASELINE_FILE}
  Stelle sicher, dass das App-Repo korrekt geklont wurde und der Volume-Mount stimmt."

  info "Wende Baseline an: ${BASELINE_FILE}"
  # KEIN --single-transaction hier: die rapt-Baseline enthält
  # 'CREATE EXTENSION timescaledb' welches AUSSERHALB einer Transaktion laufen muss.
  # ON_ERROR_STOP=1 bleibt (sofort abbrechen bei erstem SQL-Fehler).
  psql --no-psqlrc \
       --variable=ON_ERROR_STOP=1 \
       --file="$BASELINE_FILE"
  ok "Baseline angewendet: ${BASELINE_FILE}"
fi

# ---------------------------------------------------------------- Schritt 3: Pending-Discovery
# Applied-Set aus schema_migrations lesen
log "Pending-Migrationen ermitteln (${MIGRATIONS_DIR})"

# Applied-Set: Newline-getrennte Liste der bereits angewendeten Versionen
applied_versions=""
_rc=0
applied_versions="$( _psql_query "SELECT version FROM public.schema_migrations ORDER BY version" 2>/dev/null )" || _rc=$?
if (( _rc != 0 )); then
  err "psql-Abfrage (applied versions) fehlgeschlagen (rc=${_rc})"
fi

# Migrations-Dateien sammeln (nur direkt in MIGRATIONS_DIR, NICHT archive/ o.ä.)
declare -a pending_files=()

if [[ -d "$MIGRATIONS_DIR" ]]; then
  # Dateien via glob sammeln (kein ls|grep — shellcheck-sauber)
  # MIGRATIONS_PATTERN ist readonly-Konstant (Vertrag NNN_*.sql).
  # Keine Anführungszeichen → bewusste Glob-Expansion.
  # shellcheck disable=SC2231
  for f in "$MIGRATIONS_DIR"/${MIGRATIONS_PATTERN}; do
    [[ -f "$f" ]] || continue  # kein Match → Glob-Literal; Verzeichnis leer → überspringen

    filename="$(basename "$f")"

    # Defense-in-depth: nur Dateien mit dem Muster NNN_*.sql zulassen
    if [[ ! "$filename" =~ ^[0-9]{3}_.*\.sql$ ]]; then
      warn "Dateiname entspricht nicht dem Muster ^[0-9]{3}_.*\\.sql$ — übersprungen: ${filename}"
      continue
    fi

    # 3-stellige Versions-Nummer aus dem Dateinamen extrahieren
    version="${filename:0:3}"

    # Prüfen ob diese Version bereits applied ist (Mengen-Differenz)
    # grep -xF: exakter Zeilenvergleich (kein Regex), -F = fixed string
    if printf '%s\n' "$applied_versions" | grep -qxF "$version"; then
      info "Version ${version} bereits applied — übersprungen: ${filename}"
      continue
    fi

    pending_files+=("$f")
  done
else
  info "MIGRATIONS_DIR existiert nicht (${MIGRATIONS_DIR}) — keine Pending-Migrationen"
fi

if (( ${#pending_files[@]} == 0 )); then
  ok "Keine pending Migrationen — Nothing to do (idempotent)"
else
  # Numerisch aufsteigend sortieren (nach Dateiname — NNN-Präfix garantiert Reihenfolge)
  # mapfile liest sorted output in Array
  mapfile -t pending_files < <( printf '%s\n' "${pending_files[@]}" | sort )
  info "${#pending_files[@]} pending Migration(en) gefunden:"
  for f in "${pending_files[@]}"; do
    info "  $(basename "$f")"
  done
fi

# ---------------------------------------------------------------- Schritt 5 (vor Apply): Pre-Migration-Backup-Gate
# Nur relevant wenn:
#   - REQUIRE_PREMIGRATION_BACKUP=1
#   - DB ist NICHT frisch (is_fresh_db=0) → echte Schema-Änderung auf bestehender DB
#   - mind. eine neue Migration wird angewendet (${#pending_files[@]} > 0)
#   - Stateful-Unit-Marker für diesen Stack vorhanden
#
# Phase-4-Handoff: der konkrete backup.sh-Aufruf wird in Phase 4 finalisiert.
# Hier nur der Gate-Aufrufpunkt + Env-Schalter-Check.
if (( REQUIRE_PREMIGRATION_BACKUP == 1 )) \
   && (( is_fresh_db == 0 )) \
   && (( ${#pending_files[@]} > 0 )); then

  local_unit_marker="/etc/brewing/stateful-units.d/db-${STACK_LABEL}"

  if [[ -f "$local_unit_marker" ]]; then
    warn "REQUIRE_PREMIGRATION_BACKUP=1 + stateful Unit '${STACK_LABEL}' erkannt."
    warn "Pre-Migration-Backup-Gate aktiv (Phase 4)."
    # TODO Phase 4 (cicd-coder): hier backup.sh aufrufen und Backup-Marker prüfen.
    # Beispiel (Phase 4 einsetzen):
    #   /path/to/backup.sh --label "pre-migration-${STACK_LABEL}"
    #   oder: prüfe Marker /etc/brewing/backups/db-${STACK_LABEL}-latest-ok
    err "Pre-Migration-Backup-Gate: noch nicht implementiert (Phase 4).
  Setze REQUIRE_PREMIGRATION_BACKUP=0 um das Gate zu deaktivieren (Default für Phase 1-3)."
  else
    info "Kein Stateful-Unit-Marker für db-${STACK_LABEL} — Pre-Migration-Backup-Gate übersprungen."
  fi
fi

# ---------------------------------------------------------------- Schritt 4: Apply
if (( ${#pending_files[@]} == 0 )); then
  ok "Runner abgeschlossen — Stack '${STACK_LABEL}' ist aktuell"
  exit 0
fi

log "Wende ${#pending_files[@]} Migration(en) an"

for f in "${pending_files[@]}"; do
  filename="$(basename "$f")"
  version="${filename:0:3}"

  printf '\n\033[1;34m[db-init-%s]   ▶ Applying: %s\033[0m\n' "$STACK_LABEL" "$filename"

  # Apply: Fail-Fast (ON_ERROR_STOP=1); Transaktion liegt im Migrations-File.
  _rc=0
  _psql_file "$f" || _rc=$?

  if (( _rc != 0 )); then
    printf '\n\033[1;31m[db-init-%s] ✖ FEHLER bei %s (Exit-Code %d)\033[0m\n' \
      "$STACK_LABEL" "$filename" "$_rc" >&2
    printf '[db-init-%s]   Folgemigrationen wurden NICHT angewendet.\n' "$STACK_LABEL" >&2
    printf '[db-init-%s]   schema_migrations enthält den Stand VOR dieser Migration.\n' "$STACK_LABEL" >&2
    exit "$_rc"
  fi

  # Post-Apply-Verifikation: Die Migration trägt ihre eigene Version in schema_migrations ein.
  # Wir lesen zurück und prüfen, dass die Version jetzt vorhanden ist.
  _verify=""
  _vrc=0
  _verify="$( _psql_query "SELECT version FROM public.schema_migrations WHERE version='${version}'" 2>/dev/null )" || _vrc=$?
  if (( _vrc != 0 )) || [[ -z "${_verify//[[:space:]]/}" ]]; then
    printf '\n\033[1;31m[db-init-%s] ✖ Post-Apply-Verifikation fehlgeschlagen:\033[0m\n' "$STACK_LABEL" >&2
    printf '[db-init-%s]   Version '"'"'%s'"'"' nach Apply nicht in schema_migrations gefunden.\n' \
      "$STACK_LABEL" "$version" >&2
    printf '[db-init-%s]   Die Migration muss am Ende ihrer Transaktion die Version eintragen:\n' "$STACK_LABEL" >&2
    printf "[db-init-%s]   INSERT INTO public.schema_migrations(version) VALUES('%s')\n" \
      "$STACK_LABEL" "$version" >&2
    printf '[db-init-%s]     ON CONFLICT DO NOTHING;\n' "$STACK_LABEL" >&2
    exit 1
  fi

  ok "Migration applied: ${filename} (Version ${version})"
done

# ---------------------------------------------------------------- Abschluss
echo
log "Runner abgeschlossen — Stack '${STACK_LABEL}'"
ok "schema_migrations-Stand:"
# 2>&1: psql-Fehler sichtbar machen (nicht schlucken).
# Kein || true: bei Fehler warn ausgeben statt still exit 0 mit leerer Summary.
_summary_rc=0
_psql_query "SELECT version, applied_at FROM public.schema_migrations ORDER BY version" \
  2>&1 || _summary_rc=$?
if (( _summary_rc != 0 )); then
  warn "schema_migrations-Abfrage fehlgeschlagen (rc=${_summary_rc}) — Summary nicht verfuegbar"
fi
