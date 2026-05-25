#!/bin/bash
# Init-Script für die rapt_dashboard-DB (db-rapt).
# Setzt das Passwort für Supabase-Service-Roles auf $RAPT_POSTGRES_PASSWORD.
# Die Roles werden vom supabase/postgres-Image angelegt, aber ohne Passwort —
# GoTrue und PostgREST können sich sonst nicht einloggen.
# Läuft EINMALIG beim ersten DB-Start (docker-entrypoint-initdb.d/).
#
# proxy_sync wird NUR hier angelegt (rapt-DB), nicht in der assistent-DB —
# db-sync schreibt ausschließlich das rapt-Schema (Konzept §3 / Entscheidung 4).
# Cross-Team-Handoff: die Grants für proxy_sync auf rapt-Tabellen sind
# dba-coder-Territorium (Phase 2 rapt-Baseline). Die Rolle wird hier nur
# angelegt damit db-sync sich beim ersten Start verbinden kann.
#
# Warum optional-Wrapping für supabase_storage_admin / supabase_replication_admin / pgbouncer:
#   Diese Rollen werden vom supabase/postgres-Image-Entrypoint angelegt — aber nur wenn
#   die entsprechenden Supabase-Services (Storage, Replication, PgBouncer) im Image aktiviert
#   sind. In unserem Lean-Stack (kein Storage, kein PgBouncer) können diese Rollen beim
#   nächsten Image-Bump fehlen. "ALTER ROLE <nicht-existierende-rolle>" schlägt mit
#   "role does not exist" fehl und bricht den ganzen init-Lauf ab.
#   Lösung: IF EXISTS-Guard (idempotent, robust gegen Image-Varianten).

set -euo pipefail

# --- Guards: Pflicht-Variablen müssen gesetzt und nicht leer sein. ----------
[[ -n "${RAPT_POSTGRES_PASSWORD:-}" ]]    || { echo "FATAL: RAPT_POSTGRES_PASSWORD is unset or empty"    >&2; exit 1; }
[[ -n "${RAPT_PROXY_SYNC_PASSWORD:-}" ]]  || { echo "FATAL: RAPT_PROXY_SYNC_PASSWORD is unset or empty"  >&2; exit 1; }

# Single-quote guard: ein literal ' im Passwort würde die interpolierte SQL-Zeile brechen.
[[ "${RAPT_POSTGRES_PASSWORD}"   != *"'"* ]] || {
  echo "FATAL: RAPT_POSTGRES_PASSWORD darf kein einfaches Anführungszeichen enthalten" >&2
  exit 1
}
[[ "${RAPT_PROXY_SYNC_PASSWORD}" != *"'"* ]] || {
  echo "FATAL: RAPT_PROXY_SYNC_PASSWORD darf kein einfaches Anführungszeichen enthalten" >&2
  exit 1
}

# INTENTIONAL: Heredoc-Label EOSQL ist bewusst UNQUOTED, damit die Shell
# ${RAPT_POSTGRES_PASSWORD} und ${RAPT_PROXY_SYNC_PASSWORD} expandiert.
# \$\$ schützt die DO-Block-Dollar-Signs vor Shell-Expansion.
psql -v ON_ERROR_STOP=1 --username "supabase_admin" --dbname "postgres" <<-EOSQL
  -- Pflicht-Rollen: in JEDEM supabase/postgres-Image vorhanden.
  ALTER ROLE authenticator       WITH PASSWORD '${RAPT_POSTGRES_PASSWORD}';
  ALTER ROLE supabase_auth_admin WITH PASSWORD '${RAPT_POSTGRES_PASSWORD}';
  ALTER ROLE postgres            WITH PASSWORD '${RAPT_POSTGRES_PASSWORD}';

  -- Optionale Rollen: nur in bestimmten Image-Varianten / Image-Versionen vorhanden.
  -- Lean-Stack hat kein Storage und keinen PgBouncer — diese Rollen können fehlen.
  -- IF EXISTS-Guard: robust gegen "role does not exist"-Fehler bei Image-Wechsel.
  --
  -- supabase_storage_admin: Supabase Storage-Service-Rolle (kein Storage in diesem Stack,
  --   aber Image legt sie möglicherweise trotzdem an — Passwort setzen falls vorhanden).
  DO \$\$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
      ALTER ROLE supabase_storage_admin WITH PASSWORD '${RAPT_POSTGRES_PASSWORD}';
      RAISE NOTICE 'supabase_storage_admin: Passwort gesetzt.';
    END IF;
  END
  \$\$;

  -- supabase_replication_admin: Replikations-Rolle (kein Replication-Service in diesem Stack).
  DO \$\$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_replication_admin') THEN
      ALTER ROLE supabase_replication_admin WITH PASSWORD '${RAPT_POSTGRES_PASSWORD}';
      RAISE NOTICE 'supabase_replication_admin: Passwort gesetzt.';
    END IF;
  END
  \$\$;

  -- pgbouncer: Connection-Pooler-Rolle (kein PgBouncer in diesem Lean-Stack).
  DO \$\$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer') THEN
      ALTER ROLE pgbouncer WITH PASSWORD '${RAPT_POSTGRES_PASSWORD}';
      RAISE NOTICE 'pgbouncer: Passwort gesetzt.';
    END IF;
  END
  \$\$;

  -- proxy_sync: minimale Lese-Rolle für den RAPT-Proxy/db-sync.
  -- Grants auf rapt-Schema-Tabellen kommen NICHT hier (Schema noch nicht angelegt);
  -- sie werden über die dba-coder Phase-2-Baseline eingespielt.
  -- Cross-Team-Handoff: rapt-Baseline-Grants → dba-coder (Phase 2).
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
             PASSWORD '${RAPT_PROXY_SYNC_PASSWORD}';
      RAISE NOTICE 'proxy_sync: Rolle neu angelegt (frische rapt-DB).';
    ELSE
      ALTER ROLE proxy_sync
        WITH LOGIN
             NOSUPERUSER
             NOCREATEROLE
             NOCREATEDB
             NOREPLICATION
             NOBYPASSRLS
             INHERIT
             PASSWORD '${RAPT_PROXY_SYNC_PASSWORD}';
      RAISE NOTICE 'proxy_sync: Rolle existiert bereits — Passwort neu gesetzt (idempotent).';
    END IF;
  END
  \$\$;
EOSQL
