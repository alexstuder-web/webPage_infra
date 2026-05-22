#!/bin/bash
# Setzt das Passwort für die Supabase-Service-Roles auf $POSTGRES_PASSWORD.
# Die Roles selbst werden vom supabase/postgres Image automatisch erstellt,
# aber ohne Passwort — Auth/Storage/PostgREST/Realtime können sich nicht einloggen.
# Läuft EINMALIG beim ersten DB-Start (docker-entrypoint-initdb.d/).

set -e

psql -v ON_ERROR_STOP=1 --username "supabase_admin" --dbname "postgres" <<-EOSQL
  ALTER ROLE authenticator              WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_auth_admin        WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_storage_admin     WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE supabase_replication_admin WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE pgbouncer                  WITH PASSWORD '${POSTGRES_PASSWORD}';
  ALTER ROLE postgres                   WITH PASSWORD '${POSTGRES_PASSWORD}';
EOSQL
