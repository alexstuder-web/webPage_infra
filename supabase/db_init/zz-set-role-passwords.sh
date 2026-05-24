#!/bin/bash
# Setzt das Passwort für die Supabase-Service-Roles auf $POSTGRES_PASSWORD.
# Die Roles selbst werden vom supabase/postgres Image automatisch erstellt,
# aber ohne Passwort — Auth/Storage/PostgREST/Realtime können sich nicht einloggen.
# Läuft EINMALIG beim ersten DB-Start (docker-entrypoint-initdb.d/).

set -euo pipefail

# --- Guards: Pflicht-Variablen müssen gesetzt und nicht leer sein. ----------
# POSTGRES_PASSWORD: nötig für alle Supabase-Service-Roles.
# PROXY_SYNC_PASSWORD: dediziertes Passwort für proxy_sync (least-privilege).
# Beide werden vom supabase-db-Service explizit im environment:-Block
# gesetzt (docker-compose.yml) — ein leerer Wert deutet auf ein
# Compose/Bootstrap-Problem hin und muss laut scheitern.
[[ -n "${POSTGRES_PASSWORD:-}" ]]    || { echo "FATAL: POSTGRES_PASSWORD is unset or empty"    >&2; exit 1; }
[[ -n "${PROXY_SYNC_PASSWORD:-}" ]]  || { echo "FATAL: PROXY_SYNC_PASSWORD is unset or empty"  >&2; exit 1; }

psql -v ON_ERROR_STOP=1 --username "supabase_admin" --dbname "postgres" <<-EOSQL
  ALTER ROLE authenticator              WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_auth_admin        WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_storage_admin     WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_replication_admin WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE pgbouncer                  WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE postgres                   WITH PASSWORD '${POSTGRES_PASSWORD}';
  -- proxy_sync: minimale Lese-Rolle für api_proxy (Phase 1 dba-coder Migration 004).
  -- Rolle wird durch 004_proxy_role.sql angelegt; hier nur Passwort setzen.
  -- Dediziertes Passwort PROXY_SYNC_PASSWORD (nicht POSTGRES_PASSWORD) —
  -- least-privilege: ein kompromittierter proxy_sync-Key öffnet nicht den
  -- Master-Account. PROXY_SYNC_PASSWORD muss in .env gesetzt sein.
  -- DO-Block schützt gegen Fehler falls die Rolle noch nicht existiert
  -- (z.B. auf altem VPS ohne Migration 004).
  DO \$\$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'proxy_sync') THEN
      ALTER ROLE proxy_sync WITH PASSWORD '${PROXY_SYNC_PASSWORD}';
    END IF;
  END
  \$\$;
EOSQL
