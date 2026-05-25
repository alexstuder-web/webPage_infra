#!/bin/bash
# Init-Script für die brew_assistent-DB (assistent-db).
# Setzt das Passwort für Supabase-Service-Roles auf $ASSISTENT_POSTGRES_PASSWORD.
# Die Roles werden vom supabase/postgres-Image angelegt, aber ohne Passwort —
# GoTrue und PostgREST können sich sonst nicht einloggen.
# Läuft EINMALIG beim ersten DB-Start (docker-entrypoint-initdb.d/).
#
# KEIN proxy_sync hier: proxy_sync wird nur in der rapt-DB gebraucht
# (db-sync schreibt nur rapt — Konzept §3 / Entscheidung 4).
# Cross-Team-Handoff: die proxy_sync-Rolle + Grants sind dba-coder-Territorium (Phase 2).
#
# Warum optional-Wrapping für supabase_storage_admin / supabase_replication_admin / pgbouncer:
#   Diese Rollen werden vom supabase/postgres-Image-Entrypoint angelegt — aber nur wenn
#   die entsprechenden Supabase-Services (Storage, Replication, PgBouncer) im Image aktiviert
#   sind. In unserem Lean-Stack (kein Storage, kein PgBouncer) können diese Rollen beim
#   nächsten Image-Bump fehlen. "ALTER ROLE <nicht-existierende-rolle>" schlägt mit
#   "role does not exist" fehl und bricht den ganzen init-Lauf ab.
#   Lösung: IF EXISTS-Guard (idempotent, robust gegen Image-Varianten).

set -euo pipefail

# --- Guards: Pflicht-Variable muss gesetzt und nicht leer sein. ----------
# ASSISTENT_POSTGRES_PASSWORD: nötig für alle Supabase-Service-Roles dieser DB.
# Wird vom db-assistent-Service explizit im environment:-Block gesetzt —
# ein leerer Wert deutet auf ein Compose/Bootstrap-Problem hin und muss laut scheitern.
[[ -n "${ASSISTENT_POSTGRES_PASSWORD:-}" ]] || { echo "FATAL: ASSISTENT_POSTGRES_PASSWORD is unset or empty" >&2; exit 1; }

# Single-quote guard: ein literal ' im Passwort würde die interpolierte SQL-Zeile brechen.
[[ "${ASSISTENT_POSTGRES_PASSWORD}" != *"'"* ]] || {
  echo "FATAL: ASSISTENT_POSTGRES_PASSWORD darf kein einfaches Anführungszeichen enthalten" >&2
  exit 1
}

# INTENTIONAL: Heredoc-Label EOSQL ist bewusst UNQUOTED, damit die Shell
# ${ASSISTENT_POSTGRES_PASSWORD} expandiert, bevor es an psql übergeben wird.
# \$\$ schützt die DO-Block-Dollar-Signs vor Shell-Expansion.
# NICHT EOSQL quoten — das würde die Expansion verhindern.
psql -v ON_ERROR_STOP=1 --username "supabase_admin" --dbname "postgres" <<-EOSQL
  -- Pflicht-Rollen: in JEDEM supabase/postgres-Image vorhanden.
  ALTER ROLE authenticator       WITH PASSWORD '${ASSISTENT_POSTGRES_PASSWORD}';
  ALTER ROLE supabase_auth_admin WITH PASSWORD '${ASSISTENT_POSTGRES_PASSWORD}';
  ALTER ROLE postgres            WITH PASSWORD '${ASSISTENT_POSTGRES_PASSWORD}';

  -- Optionale Rollen: nur in bestimmten Image-Varianten / Image-Versionen vorhanden.
  -- Lean-Stack hat kein Storage und keinen PgBouncer — diese Rollen können fehlen.
  -- IF EXISTS-Guard: robust gegen "role does not exist"-Fehler bei Image-Wechsel.
  --
  -- supabase_storage_admin: Supabase Storage-Service-Rolle (kein Storage in diesem Stack,
  --   aber Image legt sie möglicherweise trotzdem an — Passwort setzen falls vorhanden).
  DO \$\$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
      ALTER ROLE supabase_storage_admin WITH PASSWORD '${ASSISTENT_POSTGRES_PASSWORD}';
      RAISE NOTICE 'supabase_storage_admin: Passwort gesetzt.';
    END IF;
  END
  \$\$;

  -- supabase_replication_admin: Replikations-Rolle (kein Replication-Service in diesem Stack).
  DO \$\$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_replication_admin') THEN
      ALTER ROLE supabase_replication_admin WITH PASSWORD '${ASSISTENT_POSTGRES_PASSWORD}';
      RAISE NOTICE 'supabase_replication_admin: Passwort gesetzt.';
    END IF;
  END
  \$\$;

  -- pgbouncer: Connection-Pooler-Rolle (kein PgBouncer in diesem Lean-Stack).
  DO \$\$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer') THEN
      ALTER ROLE pgbouncer WITH PASSWORD '${ASSISTENT_POSTGRES_PASSWORD}';
      RAISE NOTICE 'pgbouncer: Passwort gesetzt.';
    END IF;
  END
  \$\$;
EOSQL
