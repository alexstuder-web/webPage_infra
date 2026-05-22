-- supabase/realtime Service erwartet zusätzlich ein _realtime Schema
-- (für seinen internen Migrationszustand). Das supabase/postgres Image
-- legt nur "realtime" (ohne Underscore) an.
CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION supabase_admin;
