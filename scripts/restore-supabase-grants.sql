-- Standard-Supabase-Grants nach pg_restore --no-acl wiederherstellen
-- Idempotent: alle Statements sind ON CONFLICT-safe oder GRANTs (GRANT überschreibt).
-- Quelle: supabase/postgres docker entrypoint init-scripts

-- ============================== auth ==============================
ALTER SCHEMA auth OWNER TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON SCHEMA auth TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA auth TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA auth TO supabase_auth_admin;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA auth TO supabase_auth_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth
  GRANT ALL ON TABLES TO supabase_auth_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth
  GRANT ALL ON SEQUENCES TO supabase_auth_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth
  GRANT ALL ON FUNCTIONS TO supabase_auth_admin;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='auth'
  LOOP
    EXECUTE format('ALTER TABLE auth.%I OWNER TO supabase_auth_admin', r.tablename);
  END LOOP;
  FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='auth'
  LOOP
    EXECUTE format('ALTER SEQUENCE auth.%I OWNER TO supabase_auth_admin', r.sequence_name);
  END LOOP;
END $$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon, authenticated, service_role;
GRANT SELECT ON auth.users, auth.refresh_tokens, auth.identities TO authenticated, service_role;

-- ============================== storage ==============================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='storage') THEN
    EXECUTE 'ALTER SCHEMA storage OWNER TO supabase_storage_admin';
    EXECUTE 'GRANT ALL PRIVILEGES ON SCHEMA storage TO supabase_storage_admin';
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA storage TO supabase_storage_admin';
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA storage TO supabase_storage_admin';
    EXECUTE 'GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA storage TO supabase_storage_admin';
    EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT ALL ON TABLES TO supabase_storage_admin';
    EXECUTE 'GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA storage TO anon, authenticated, service_role';
  END IF;
END $$;

DO $$
DECLARE r record;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='storage') THEN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='storage'
    LOOP
      EXECUTE format('ALTER TABLE storage.%I OWNER TO supabase_storage_admin', r.tablename);
    END LOOP;
  END IF;
END $$;

-- ============================== realtime ==============================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='realtime') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA realtime TO anon, authenticated, service_role';
    EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA realtime TO anon, authenticated, service_role';
  END IF;
END $$;

-- ============================== App-Schema (rapt | aibrewgenius) ==============================
DO $$
DECLARE
  app_schema text;
  app_schema_count int;
BEGIN
  SELECT count(*) INTO app_schema_count
  FROM pg_namespace
  WHERE nspname IN ('rapt','aibrewgenius');

  -- S1: Per-App-DB-Architektur verbietet mehr als ein App-Schema pro Cluster.
  -- Expliziter Guard statt LIMIT 1: bei Multi-Match hart abbrechen statt still
  -- das erste zu nehmen (undefinierte Reihenfolge), was einen Bug verschleiern würde.
  IF app_schema_count > 1 THEN
    RAISE EXCEPTION 'Mehrere App-Schemas (rapt + aibrewgenius) im selben Cluster — '
      'das verletzt die Per-App-DB-Architektur. Grants wurden NICHT gesetzt.'
      USING HINT = 'Prüfe pg_namespace, entferne das überzählige Schema '
                   '(rapt vs aibrewgenius gehören in getrennte DBs).';
  END IF;

  SELECT nspname INTO app_schema
  FROM pg_namespace
  WHERE nspname IN ('rapt','aibrewgenius');

  IF app_schema IS NULL THEN
    RAISE NOTICE 'Kein App-Schema (rapt|aibrewgenius) gefunden — überspringe App-Grants';
    RETURN;
  END IF;

  RAISE NOTICE 'App-Schema-Grants: %', app_schema;
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated, service_role', app_schema);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO authenticated, service_role', app_schema);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO anon', app_schema);
  EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO authenticated, anon, service_role', app_schema);
  EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO authenticated, anon, service_role', app_schema);
  -- DEFAULT PRIVILEGES für supabase_admin-erzeugte Objekte (z.B. via psql-Migration als supabase_admin):
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated, service_role', app_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO anon', app_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO authenticated, anon, service_role', app_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO authenticated, anon, service_role', app_schema);
  -- DEFAULT PRIVILEGES für postgres-erzeugte Objekte (Migrations-Pfad: viele Toolchains
  -- laufen als 'postgres', nicht als supabase_admin → ohne diesen Block fehlen Auto-Grants
  -- für alle zukünftigen Migrations-Tabellen):
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated, service_role', app_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON TABLES TO anon', app_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO authenticated, anon, service_role', app_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO authenticated, anon, service_role', app_schema);
END $$;

-- ============================== public ==============================
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, anon, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, anon, service_role;
-- DEFAULT PRIVILEGES für supabase_admin-erzeugte Objekte:
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO authenticated, anon, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO authenticated, anon, service_role;
-- DEFAULT PRIVILEGES für postgres-erzeugte Objekte (Migrations-Pfad: viele Toolchains
-- laufen als 'postgres', nicht als supabase_admin → ohne diesen Block fehlen Auto-Grants
-- für alle zukünftigen Migrations-Tabellen):
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO authenticated, anon, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO authenticated, anon, service_role;
