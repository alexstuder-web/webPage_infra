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

# Single-quote guard: a literal ' in either password would break the interpolated SQL string
# (heredoc label is intentionally unquoted — see comment below).
[[ "${POSTGRES_PASSWORD}"   != *"'"* ]] || { echo "FATAL: POSTGRES_PASSWORD darf kein einfaches Anführungszeichen enthalten"   >&2; exit 1; }
[[ "${PROXY_SYNC_PASSWORD}" != *"'"* ]] || { echo "FATAL: PROXY_SYNC_PASSWORD darf kein einfaches Anführungszeichen enthalten" >&2; exit 1; }

# INTENTIONAL: the heredoc label EOSQL is deliberately UNQUOTED so that the shell expands
# ${POSTGRES_PASSWORD} and ${PROXY_SYNC_PASSWORD} into the SQL text before it is handed to
# psql.  The \$\$ delimiters in the DO block are escaped to prevent premature shell
# expansion of the dollar-signs.  Do NOT quote EOSQL — that would suppress the expansion.
psql -v ON_ERROR_STOP=1 --username "supabase_admin" --dbname "postgres" <<-EOSQL
  ALTER ROLE authenticator              WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_auth_admin        WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_storage_admin     WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_replication_admin WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE pgbouncer                  WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE postgres                   WITH PASSWORD '${POSTGRES_PASSWORD}';
  -- proxy_sync: minimale Lese-Rolle für api_proxy (Phase 1 dba-coder Migration 004).
  --
  -- Zweck dieses Blocks: Rolle idempotent anlegen und Passwort setzen.
  --   - Frische DB (kein 004_proxy_role.sql gelaufen): CREATE ROLE mit den exakten
  --     Attributen aus der Migration, damit api_proxy sich beim ersten Boot verbinden kann.
  --   - Bestehende DB (Rolle existiert bereits, z.B. nach Restore oder nach 004): ALTER ROLE
  --     setzt Login + Passwort sicher neu (idempotent).
  --
  -- Grants kommen NICHT hier: zum db-init-Zeitpunkt existieren die Schemata
  -- aibrewgenius/rapt noch nicht (sie entstehen erst beim restore.sh-Lauf).
  -- Die Tabellen-Grants für proxy_sync werden über den wiederhergestellten
  -- rapt-Dump eingespielt — die Rolle existiert dann bereits und die GRANTs greifen.
  -- Das quell-seitige Pendant ist brew_assistent-new/db_scripts/migrations/004_proxy_role.sql.
  --
  -- Rollen-Attribute exakt spiegelnd aus 004_proxy_role.sql (Section 1):
  --   LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS INHERIT
  --
  -- Dediziertes Passwort PROXY_SYNC_PASSWORD (NICHT POSTGRES_PASSWORD) —
  -- least-privilege: ein geleakter proxy_sync-Key öffnet nicht den Master-Account.
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'proxy_sync') THEN
      CREATE ROLE proxy_sync
        WITH LOGIN
             NOSUPERUSER
             NOCREATEROLE
             NOCREATEDB
             NOREPLICATION
             NOBYPASSRLS
             INHERIT
             PASSWORD '${PROXY_SYNC_PASSWORD}';
      RAISE NOTICE 'proxy_sync: Rolle neu angelegt (frische DB — 004_proxy_role.sql noch nicht gelaufen).';
    ELSE
      -- Re-assert full attribute set (mirrors CREATE above and Migration 004) so this
      -- script is self-contained and does not rely on 004_proxy_role.sql having run.
      ALTER ROLE proxy_sync
        WITH LOGIN
             NOSUPERUSER
             NOCREATEROLE
             NOCREATEDB
             NOREPLICATION
             NOBYPASSRLS
             INHERIT
             PASSWORD '${PROXY_SYNC_PASSWORD}';
      RAISE NOTICE 'proxy_sync: Rolle existiert bereits — Attribute + Passwort neu gesetzt (idempotent).';
    END IF;
  END
  \$\$;
EOSQL
