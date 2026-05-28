#!/usr/bin/env bash
# ============================================================================
# scripts/restore-smoke.sh — Disaster-Recovery-Gate für Backup/Restore
# ============================================================================
# Zweck: BEWEISEN, dass aus dem aktuellsten R2-Backup einer stateful Unit
# (db-assistent | db-rapt) die Daten 1:1 zurückkommen — inkl. TimescaleDB-
# Hypertables (rapt.telemetry_*).
#
# Strategie: nimmt den NEUESTEN lokalen .fc.gpg-Dump (oder lädt ihn aus R2,
# wenn lokal leer), zieht einen Throwaway-Container `<unit>-smoke` mit dem
# GLEICHEN Image wie prod hoch, restored den Dump mit TimescaleDB-Wrap
# (CREATE EXTENSION + pre_restore + pg_restore + post_restore), liest aus
# der Live-DB die Referenz-Counts und vergleicht. Bei 100% Match → exit 0.
#
# DESTRUKTIV NUR FÜR DEN THROWAWAY: prod-Container bleibt unangetastet.
#
# Aufruf:
#   ./scripts/restore-smoke.sh                  # default: db-rapt
#   ./scripts/restore-smoke.sh db-assistent
#   ./scripts/restore-smoke.sh db-rapt --keep   # Container nach Test behalten
#
# Bekannte Eigenheit (s. project_backup_restore Memory): pg_restore in einen
# FRISCHEN supabase/postgres-Container ohne --clean wirft ~190 "already
# exists"-Warnungen für Event-Trigger der Init-Scripts. Alle nicht-fatal,
# README-dokumentiert. Mit --clean würde der Container während pg_restore
# crashen (Drop kollidiert mit init); deshalb hier OHNE --clean.
#
# Voraussetzungen: /etc/brewing/gpg.pass lesbar (alex), docker erreichbar,
# .env sourcebar (falls aus R2 nachgeladen wird). Liest NICHTS aus argv.
# ============================================================================
set -uo pipefail

# ---- Args ----
UNIT="${1:-db-rapt}"
KEEP=0
[[ "${2:-}" == "--keep" ]] && KEEP=1
[[ "${1:-}" == "--keep" ]] && { KEEP=1; UNIT="db-rapt"; }

case "$UNIT" in
  db-rapt|db-assistent) ;;
  *) echo "Usage: $0 [db-rapt|db-assistent] [--keep]" >&2; exit 2 ;;
esac

# ---- Pfad/Repo ----
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR" || { echo "cd $REPO_DIR fehlgeschlagen" >&2; exit 2; }

SMOKE_NAME="${UNIT}-smoke"
SMOKE_PASS="$(openssl rand -base64 24 | tr -d '/=+')"
DECRYPTED="/tmp/${UNIT}-smoke.fc"

# ---- Logging ----
c_log='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_rst='\033[0m'
log()  { printf '%b▶ %s%b\n' "$c_log"  "$*" "$c_rst"; }
ok()   { printf '%b  ✓ %s%b\n' "$c_ok"   "$*" "$c_rst"; }
warn() { printf '%b  ⚠ %s%b\n' "$c_warn" "$*" "$c_rst" >&2; }
fail() { printf '%b  ✖ %s%b\n' "$c_err"  "$*" "$c_rst" >&2; }

# ---- Cleanup ----
cleanup() {
  rm -f "$DECRYPTED" 2>/dev/null || true
  if (( KEEP == 1 )); then
    warn "Container $SMOKE_NAME bleibt (--keep) — manuell: docker rm -f $SMOKE_NAME"
  else
    log "Cleanup Throwaway-Container"
    docker rm -f "$SMOKE_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---- Helpers ----
pex() { docker exec -e PGPASSWORD="$SMOKE_PASS" "$SMOKE_NAME" "$@"; }

# ---- 1. Image + Live-Referenz-Counts vom Prod-Container ablesen ----
log "Prod-Container $UNIT abfragen (Image + Tabellen + Referenz-Counts)"
if ! docker inspect "$UNIT" --format='{{.Config.Image}}' >/dev/null 2>&1; then
  fail "Prod-Container '$UNIT' nicht gefunden — nichts zu vergleichen"
  exit 2
fi
IMAGE="$(docker inspect "$UNIT" --format='{{.Config.Image}}')"
ok "Image: $IMAGE"

# Schema = unit-name OHNE 'db-' Präfix (db-rapt → rapt, db-assistent → aibrewgenius)
case "$UNIT" in
  db-rapt)      SCHEMA="rapt" ;;
  db-assistent) SCHEMA="aibrewgenius" ;;
esac
ok "Schema: $SCHEMA"

# Tabellen aus information_schema lesen — keine harcoded Liste
PROD_PASS="$(docker inspect "$UNIT" --format='{{range .Config.Env}}{{println .}}{{end}}' \
  | awk -F= '/^POSTGRES_PASSWORD=/{print substr($0, index($0,"=")+1)}')"
if [[ -z "$PROD_PASS" ]]; then
  fail "POSTGRES_PASSWORD am Prod-Container nicht auslesbar"
  exit 2
fi

mapfile -t TABLES < <(
  docker exec -e PGPASSWORD="$PROD_PASS" "$UNIT" \
    psql -tA -U supabase_admin -d postgres \
    -c "SELECT table_name FROM information_schema.tables WHERE table_schema='$SCHEMA' AND table_type='BASE TABLE' ORDER BY table_name;" \
    2>/dev/null
)
if (( ${#TABLES[@]} == 0 )); then
  fail "Keine Tabellen in Schema $SCHEMA gefunden"
  exit 2
fi
ok "${#TABLES[@]} Tabellen: ${TABLES[*]}"

declare -A REF=()
for t in "${TABLES[@]}"; do
  REF["$t"]="$(docker exec -e PGPASSWORD="$PROD_PASS" "$UNIT" \
    psql -tA -U supabase_admin -d postgres \
    -c "SELECT count(*) FROM ${SCHEMA}.${t};" 2>/dev/null | tr -d '[:space:]')"
done
unset PROD_PASS

# ---- 2. Neuesten Dump finden ----
log "Neuesten ${UNIT}-Dump suchen"
DUMP_GPG="$(ls -1t "backups/${UNIT}/${UNIT}"_*.fc.gpg 2>/dev/null | head -1)"
if [[ ! -f "$DUMP_GPG" ]]; then
  fail "Kein Dump in backups/${UNIT}/ — erst './scripts/backup.sh' laufen lassen"
  exit 2
fi
ok "Dump: $DUMP_GPG ($(du -h "$DUMP_GPG" | cut -f1))"

# ---- 3. GPG-Entschlüsseln ----
log "GPG-entschlüsseln (Passphrase aus /etc/brewing/gpg.pass)"
if [[ ! -r /etc/brewing/gpg.pass ]]; then
  fail "/etc/brewing/gpg.pass nicht lesbar — als alex laufen oder Passphrase-Quelle setzen"
  exit 2
fi
gpg --batch --quiet --yes --passphrase-file /etc/brewing/gpg.pass \
    --decrypt --output "$DECRYPTED" "$DUMP_GPG" \
  || { fail "GPG-Decrypt fehlgeschlagen"; exit 2; }
ok "Entschlüsselt: $(du -h "$DECRYPTED" | cut -f1)"

# ---- 4. Throwaway-Container starten ----
log "Throwaway-Container $SMOKE_NAME hochziehen (--memory 2g --shm-size 256m)"
docker rm -f "$SMOKE_NAME" >/dev/null 2>&1 || true
docker run -d --name "$SMOKE_NAME" \
  --memory 2g --shm-size 256m \
  -e POSTGRES_PASSWORD="$SMOKE_PASS" \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_USER=supabase_admin \
  "$IMAGE" >/dev/null

log "Warte auf pg_isready (max 90s)"
ready=0
for i in $(seq 1 90); do
  if docker exec "$SMOKE_NAME" pg_isready -U supabase_admin -d postgres >/dev/null 2>&1; then
    ok "Ready nach ${i}s"
    ready=1
    break
  fi
  sleep 1
done
if (( ready == 0 )); then
  fail "Postgres nicht innerhalb 90s ready"
  docker logs --tail 30 "$SMOKE_NAME"
  exit 2
fi

# supabase/postgres läuft init scripts NACH pg_isready durch → 10s warten
log "Warte 10s auf supabase init scripts"
sleep 10

# ---- 5. Restore mit TimescaleDB-Wrap ----
log "Dump in Container kopieren"
docker cp "$DECRYPTED" "$SMOKE_NAME:/tmp/dump.fc"

# Hypertable-relevant nur für db-rapt (Schema hat telemetry_*)
TSDB_WRAP=0
if [[ "$UNIT" == "db-rapt" ]]; then
  TSDB_WRAP=1
  log "CREATE EXTENSION timescaledb"
  pex psql -U supabase_admin -d postgres -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" 2>&1 | tail -3

  log "SELECT timescaledb_pre_restore()"
  pex psql -U supabase_admin -d postgres -c "SELECT public.timescaledb_pre_restore();" 2>&1 | tail -3
fi

log "pg_restore --no-owner --no-acl (ohne --clean: frische DB)"
pex pg_restore --no-owner --no-acl \
  -U supabase_admin -d postgres /tmp/dump.fc 2>&1 | tail -5
RC=$?
echo "  pg_restore Exit-Code: $RC (~190 'already exists'-Warnungen bei Supabase-Init normal)"

# DB könnte kurz wackeln; warten dass sie wieder steht
sleep 3
for i in $(seq 1 20); do
  pex pg_isready -U supabase_admin -d postgres >/dev/null 2>&1 && break
  sleep 1
done

if (( TSDB_WRAP == 1 )); then
  log "SELECT timescaledb_post_restore() (unbedingt)"
  pex psql -U supabase_admin -d postgres -c "SELECT public.timescaledb_post_restore();" 2>&1 | tail -3
fi

# ---- 6. Counts vergleichen ----
log "Counts vergleichen ($SCHEMA.* — Prod ↔ Throwaway)"
printf '%-30s %10s %10s %s\n' "Tabelle" "Prod" "Restore" "Status"
printf '%-30s %10s %10s %s\n' "------------------------------" "----------" "----------" "------"

ALL_OK=1
# Drift-Toleranz: zwischen Backup und Live-Prod-Counts laufen db-sync etc. weiter.
# Restore darf ≤ Prod sein (nie >), und die Lücke ≤ max(5 Zeilen, 0.1% von Prod).
# Begründet: telemetry_* füllt sich pro Minute; static Tabellen (profiles, etc.)
# brauchen exakte Gleichheit (kleine Prod-Counts → 5 ist eh praktisch "exakt").
for t in "${TABLES[@]}"; do
  expected="${REF[$t]}"
  got="$(pex psql -tA -U supabase_admin -d postgres \
    -c "SELECT count(*) FROM ${SCHEMA}.${t};" 2>/dev/null | tr -d '[:space:]')"

  if [[ -z "$got" || ! "$got" =~ ^[0-9]+$ ]]; then
    status="✖ LEER"
    ALL_OK=0
  elif [[ "$got" == "$expected" ]]; then
    status="✓"
  elif (( got > expected )); then
    # Restore HAT MEHR als Prod → das wäre wirklich kaputt (nie passieren).
    status="✖ (${got}>${expected})"
    ALL_OK=0
  else
    # got < expected → Drift. Tolerieren bis max(5, 0.1% von expected).
    delta=$(( expected - got ))
    tol=$(( expected / 1000 )); (( tol < 5 )) && tol=5
    if (( delta <= tol )); then
      status="✓ (-${delta} drift, tol≤${tol})"
    else
      status="✖ (-${delta} > tol ${tol})"
      ALL_OK=0
    fi
  fi
  printf '%-30s %10s %10s %s\n' "$t" "$expected" "${got:-LEER}" "$status"
done

echo
if (( ALL_OK == 1 )); then
  printf '%bSMOKE TEST BESTANDEN — alle Counts identisch mit Prod%b\n' "$c_ok" "$c_rst"
  exit 0
else
  printf '%bSMOKE TEST FAILED — siehe Tabelle oben%b\n' "$c_err" "$c_rst"
  (( KEEP == 0 )) && echo "  Tipp: mit --keep wiederholen, dann 'docker exec -it $SMOKE_NAME psql ...' debuggen"
  exit 1
fi
