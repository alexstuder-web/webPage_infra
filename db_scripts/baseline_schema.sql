-- =============================================================================
-- baseline_schema.sql — Konsolidierter Schema-Baseline
-- =============================================================================
-- Zweck: End-Zustand der gesamten Migrations-Kette auf einer FRISCHEN
--   supabase/postgres:15.8.1.060-Base in EINEM Apply reproduzieren.
--   Keine historischen Create-then-Drop-Zyklen; direkt der getestete Soll-Zustand.
--
-- Abgedeckter Stand: alle 14 Migrationen
--   aibrewgenius: 001_init_schema … 009_drop_aibrewgenius_rapt_shims
--   rapt:         001_init_rapt_schema … 005_rapt_telemetry_owner
--
-- Nicht enthalten (absichtlich):
--   - Seed-Daten (aibrewgenius_seed.sql ist dev-only)
--   - proxy_sync-ROLLE selbst (wird von zz-set-role-passwords.sh beim Init angelegt)
--   - POSTGRES_PASSWORD / PROXY_SYNC_PASSWORD (Secrets, nie in SQL)
--   - Bootstrap-User alex@alexstuder.ch — kein Prod-Seed-User im Baseline;
--     wird nach Deploy via Supabase-Auth-API / integrations_page angelegt.
--     Trigger handle_new_user / on_rapt_user_created legen user_profiles-Rows
--     automatisch bei jedem neuen auth.users-INSERT an.
--
-- Zielimage-Hinweis:
--   supabase/postgres:15.8.1.060 hat die ältere GoTrue-Schema-Version:
--     - auth.users.confirmed_at (NICHT email_confirmed_at)
--     - KEIN auth.identities
--   Der Baseline ist gegen dieses Image getestet.
--
-- Voraussetzungen (bereits vom Image / zz-set-role-passwords.sh erledigt):
--   - Extensions: pgcrypto, pgjwt, supabase_vault, uuid-ossp, pg_graphql
--   - Rollen: anon, authenticated, service_role, supabase_admin, proxy_sync
--   - vault.secrets Tabelle + vault.decrypted_secrets View + vault.create_secret/update_secret
--   - auth.users Tabelle (GoTrue-Core)
--
-- Idempotenz:
--   Dieser Baseline ist für FRISCHE DBs optimiert. Auf einer bereits bespielten
--   DB (partial state): CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
--   DROP POLICY IF EXISTS + CREATE POLICY, CREATE OR REPLACE FUNCTION sind
--   idempotent. PKs/FKs und CREATE SCHEMA würden bei Conflict error geben —
--   für Re-Apply auf existing DB apply-db-migrations.sh verwenden.
--
-- Anwenden (frische DB):
--   cat webPage_infra/db_scripts/baseline_schema.sql \
--     | docker exec -i supabase-db psql -U supabase_admin -d postgres \
--         --variable=ON_ERROR_STOP=1
--
-- Bestehende Migrations-Dateien bleiben UNVERÄNDERT (historische Referenz).
-- apply-db-migrations.sh bleibt für Forward-Migrationen auf bestehenden DBs.
-- =============================================================================

-- TimescaleDB Extension — muss VOR der Transaktion aktiviert werden
-- (CREATE EXTENSION braucht search_path; wird danach zurückgesetzt)
SET search_path = public;
CREATE EXTENSION IF NOT EXISTS timescaledb;

BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

-- =============================================================================
-- ABSCHNITT 1: aibrewgenius-Schema
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS aibrewgenius;
ALTER SCHEMA aibrewgenius OWNER TO supabase_admin;

-- ---------------------------------------------------------------------------
-- 1a. Hilfsfunktion: set_updated_at (Trigger-Funktion, kein SECURITY DEFINER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aibrewgenius.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = TIMEZONE('utc', NOW());
  RETURN NEW;
END
$$;
ALTER FUNCTION aibrewgenius.set_updated_at() OWNER TO supabase_admin;

-- ---------------------------------------------------------------------------
-- 1b. user_profiles — finale Struktur (nach 002_auth + 003_vault + 008_drop)
--     id: uuid PK, FK → auth.users(id) ON DELETE CASCADE
--     brewfather_secret_id: FK → vault.secrets
--     brewfather_configured: GENERATED ALWAYS AS (brewfather_secret_id IS NOT NULL)
--     brewfather_api_key: immer NULL seit 003_vault; Spalte bleibt für Compat
--     KEINE rapt_*-Spalten (gedroppt in 008)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aibrewgenius.user_profiles (
  id                      uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name                    text,
  avatar_blob             text,
  default_batch_liters    double precision,
  brewfather_user_id      text,
  brewfather_api_key      text,           -- immer NULL seit 003_vault; Spalte bleibt für Compat
  brewfather_sync_enabled boolean         NOT NULL DEFAULT false,
  language                text,
  brewfather_secret_id    uuid            REFERENCES vault.secrets(id) ON DELETE SET NULL,
  brewfather_configured   boolean         GENERATED ALWAYS AS (brewfather_secret_id IS NOT NULL) STORED
);
ALTER TABLE aibrewgenius.user_profiles OWNER TO supabase_admin;

-- ---------------------------------------------------------------------------
-- 1c. Kind-Tabellen (alle mit user_profile_id uuid FK → user_profiles.id)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS aibrewgenius.ai_generated_recipes_v2 (
  id                          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id             uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  basis_bier                  text,
  bier_typ                    text,
  stammwuerze_sg              double precision,
  restextrakt_sg              double precision,
  alkoholgehalt               double precision,
  notizen                     text[],
  generated_image             text,
  yeast_name                  text,
  yeast_type                  text,
  yeast_amount                text,
  yeast_procurement_needed    boolean,
  water_ca                    integer,
  water_mg                    integer,
  water_na                    integer,
  water_cl                    integer,
  water_so4                   integer,
  water_hco3                  integer,
  water_salt_timing           text,
  mash_water_l                double precision,
  mash_in_temp_c              double precision,
  lauter_sparge_water_l       double precision,
  lauter_target_ph            text,
  boil_pre_vol_l              double precision,
  boil_duration_min           integer,
  fermentation_pitch_temp_c   double precision,
  packaging_type              text,
  packaging_co2_target        double precision,
  packaging_keg_pressure      double precision,
  packaging_keg_temp          double precision,
  packaging_bottle_sugar      double precision,
  packaging_bottle_temp       double precision,
  packaging_storage_temp      double precision,
  packaging_storage_weeks     integer,
  packaging_maturation_note   text,
  packaging_serving_gas       text,
  packaging_carb_days         integer,
  can_pressurize              boolean     DEFAULT false,
  fermentation_pressure_note  text,
  bjcp_stil                   jsonb,
  ibu                         double precision,
  created_at                  timestamptz DEFAULT now(),
  updated_at                  timestamptz DEFAULT now(),
  malts                       jsonb       DEFAULT '[]'::jsonb,
  hops                        jsonb       DEFAULT '[]'::jsonb,
  specials                    jsonb       DEFAULT '[]'::jsonb,
  finings                     jsonb       DEFAULT '[]'::jsonb,
  mash_steps                  jsonb       DEFAULT '[]'::jsonb,
  fermentation_steps          jsonb       DEFAULT '[]'::jsonb
);
ALTER TABLE aibrewgenius.ai_generated_recipes_v2 OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.batches (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  brewfather_id   text,
  name            text        NOT NULL,
  batch_no        integer,
  status          text,
  brew_date       bigint,
  recipe_name     text,
  analysis_data   jsonb,
  rapt_data       jsonb,
  data            jsonb,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.batches OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.brew_kettles (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id         uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  brand                   text        NOT NULL,
  model                   text,
  is_default              boolean     NOT NULL DEFAULT false,
  volume_liters           double precision,
  post_boil_loss_liters   double precision DEFAULT 0,
  boil_off_percentage     double precision DEFAULT 0,
  bh_efficiency           double precision DEFAULT 70,
  has_condenser_hat       boolean     NOT NULL DEFAULT false,
  notes                   text,
  created_at              timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at              timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.brew_kettles OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.fermentables (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  brewfather_id   text,
  name            text        NOT NULL,
  supplier        text,
  amount          double precision,
  unit            text,
  type            text,
  potential       double precision,
  yield           double precision,
  attenuation     double precision,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.fermentables OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.fermenter_controllers (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  name            text        NOT NULL,
  is_default      boolean     NOT NULL DEFAULT false,
  username        text,
  api_key         text,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.fermenter_controllers OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.fermenters (
  id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id          uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  brand                    text        NOT NULL,
  type                     text,
  is_default               boolean     NOT NULL DEFAULT false,
  volume_liters            double precision,
  has_heating              boolean     NOT NULL DEFAULT false,
  has_cooling              boolean     NOT NULL DEFAULT false,
  has_dry_hopping_port     boolean     NOT NULL DEFAULT false,
  can_pressurize           boolean     NOT NULL DEFAULT false,
  fermentation_loss_liters double precision NOT NULL DEFAULT 0,
  notes                    text,
  created_at               timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at               timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.fermenters OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.fining_agents (
  user_profile_id  uuid        PRIMARY KEY REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  irish_moss       boolean     NOT NULL DEFAULT false,
  whirlfloc        boolean     NOT NULL DEFAULT false,
  gelatin          boolean     NOT NULL DEFAULT false,
  biersol          boolean     NOT NULL DEFAULT false,
  polyclar         boolean     NOT NULL DEFAULT false,
  isinglass        boolean     NOT NULL DEFAULT false,
  bentonite        boolean     NOT NULL DEFAULT false,
  egg_whites       boolean     NOT NULL DEFAULT false,
  activated_carbon boolean     NOT NULL DEFAULT false,
  extras           jsonb       NOT NULL DEFAULT '[]'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at       timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.fining_agents OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.hops (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  brewfather_id   text,
  name            text        NOT NULL,
  alpha           double precision,
  origin          text,
  year            text,
  amount          double precision,
  unit            text,
  type            text,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.hops OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.how_to_topics (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  title           text        NOT NULL,
  content         text        DEFAULT '',
  pages           jsonb       DEFAULT '[]'::jsonb,
  position        integer     DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.how_to_topics OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.keezer_configs (
  user_profile_id uuid        PRIMARY KEY REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  num_taps        integer     DEFAULT 0,
  taps            jsonb       DEFAULT '[]'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.keezer_configs OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.malt_depots (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  name            text        NOT NULL,
  url             text,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.malt_depots OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.miscs (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  brewfather_id   text,
  name            text        NOT NULL,
  amount          double precision,
  unit            text,
  type            text,
  use             text,
  time            double precision,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.miscs OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.packaging_profiles (
  id                        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id           uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  name                      text        NOT NULL,
  target_volume             double precision,
  bottle_enabled            boolean     NOT NULL DEFAULT false,
  bottle_carbonation_temp_c double precision,
  bottle_storage_temp_c     double precision,
  keg_enabled               boolean     NOT NULL DEFAULT false,
  keg_carbonation_temp_c    double precision,
  keg_storage_temp_c        double precision,
  keg_volume_l              double precision,
  has_co2                   boolean     NOT NULL DEFAULT true,
  has_nitro                 boolean     NOT NULL DEFAULT false,
  is_default                boolean     NOT NULL DEFAULT false,
  created_at                timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at                timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.packaging_profiles OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.recipes (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  brewfather_id   text,
  name            text        NOT NULL,
  style           text,
  abv             double precision,
  ibu             double precision,
  color           double precision,
  data            jsonb,
  image           bytea,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.recipes OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.video_instructions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  title           text        NOT NULL,
  youtube_url     text        NOT NULL,
  description     text,
  position        integer     DEFAULT 0,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);
ALTER TABLE aibrewgenius.video_instructions OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.water_profiles (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  name            text        NOT NULL,
  is_default      boolean     NOT NULL DEFAULT false,
  ph              double precision,
  calcium_ppm     double precision DEFAULT 0,
  magnesium_ppm   double precision DEFAULT 0,
  sodium_ppm      double precision DEFAULT 0,
  chloride_ppm    double precision DEFAULT 0,
  sulfate_ppm     double precision DEFAULT 0,
  bicarbonate_ppm double precision DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at      timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.water_profiles OWNER TO supabase_admin;

CREATE TABLE IF NOT EXISTS aibrewgenius.yeast_bank_entries (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_profile_id    uuid        NOT NULL REFERENCES aibrewgenius.user_profiles(id) ON DELETE CASCADE,
  brewfather_id      text,
  brand              text        NOT NULL,
  strain             text        NOT NULL,
  product_id         text,
  form               text,
  inventory          double precision,
  unit               text,
  style              text,
  attenuation_min    double precision,
  attenuation_max    double precision,
  temperature_min    double precision,
  temperature_max    double precision,
  url                text,
  notes              text,
  zucht_generationen jsonb       DEFAULT '[]'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at         timestamptz NOT NULL DEFAULT timezone('utc', now())
);
ALTER TABLE aibrewgenius.yeast_bank_entries OWNER TO supabase_admin;

-- ---------------------------------------------------------------------------
-- 1d. Unique Indizes auf Child-Tabellen
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS batches_user_brewfather_unique
  ON aibrewgenius.batches (user_profile_id, brewfather_id);
CREATE UNIQUE INDEX IF NOT EXISTS brew_kettles_default_unique
  ON aibrewgenius.brew_kettles (user_profile_id) WHERE is_default;
CREATE UNIQUE INDEX IF NOT EXISTS fermentables_user_brewfather_unique
  ON aibrewgenius.fermentables (user_profile_id, brewfather_id);
CREATE UNIQUE INDEX IF NOT EXISTS fermenter_controllers_default_unique
  ON aibrewgenius.fermenter_controllers (user_profile_id) WHERE is_default;
CREATE UNIQUE INDEX IF NOT EXISTS fermenters_default_unique
  ON aibrewgenius.fermenters (user_profile_id) WHERE is_default;
CREATE UNIQUE INDEX IF NOT EXISTS hops_user_brewfather_unique
  ON aibrewgenius.hops (user_profile_id, brewfather_id);
CREATE UNIQUE INDEX IF NOT EXISTS miscs_user_brewfather_unique
  ON aibrewgenius.miscs (user_profile_id, brewfather_id);
CREATE UNIQUE INDEX IF NOT EXISTS packaging_profiles_default_unique
  ON aibrewgenius.packaging_profiles (user_profile_id) WHERE is_default;
CREATE UNIQUE INDEX IF NOT EXISTS recipes_user_brewfather_unique
  ON aibrewgenius.recipes (user_profile_id, brewfather_id);
CREATE UNIQUE INDEX IF NOT EXISTS water_profiles_default_unique
  ON aibrewgenius.water_profiles (user_profile_id) WHERE is_default;

-- RLS-Filter-Indizes auf user_profile_id (RLS macht diese zu Per-Query-Prädikaten)
CREATE INDEX IF NOT EXISTS idx_abg_ai_recipes_v2_upid
  ON aibrewgenius.ai_generated_recipes_v2 (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_batches_upid
  ON aibrewgenius.batches (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_brew_kettles_upid
  ON aibrewgenius.brew_kettles (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_fermentables_upid
  ON aibrewgenius.fermentables (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_fermenter_controllers_upid
  ON aibrewgenius.fermenter_controllers (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_fermenters_upid
  ON aibrewgenius.fermenters (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_hops_upid
  ON aibrewgenius.hops (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_how_to_topics_upid
  ON aibrewgenius.how_to_topics (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_malt_depots_upid
  ON aibrewgenius.malt_depots (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_miscs_upid
  ON aibrewgenius.miscs (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_packaging_profiles_upid
  ON aibrewgenius.packaging_profiles (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_recipes_upid
  ON aibrewgenius.recipes (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_video_instructions_upid
  ON aibrewgenius.video_instructions (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_water_profiles_upid
  ON aibrewgenius.water_profiles (user_profile_id);
CREATE INDEX IF NOT EXISTS idx_abg_yeast_bank_entries_upid
  ON aibrewgenius.yeast_bank_entries (user_profile_id);

-- ---------------------------------------------------------------------------
-- 1e. Trigger (set_updated_at auf Kind-Tabellen)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER batches_set_updated_at
  BEFORE UPDATE ON aibrewgenius.batches
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER brew_kettles_set_updated_at
  BEFORE UPDATE ON aibrewgenius.brew_kettles
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER fermentables_set_updated_at
  BEFORE UPDATE ON aibrewgenius.fermentables
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER fermenter_controllers_set_updated_at
  BEFORE UPDATE ON aibrewgenius.fermenter_controllers
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER fermenters_set_updated_at
  BEFORE UPDATE ON aibrewgenius.fermenters
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER fining_agents_set_updated_at
  BEFORE UPDATE ON aibrewgenius.fining_agents
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER hops_set_updated_at
  BEFORE UPDATE ON aibrewgenius.hops
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER how_to_topics_set_updated_at
  BEFORE UPDATE ON aibrewgenius.how_to_topics
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER malt_depots_set_updated_at
  BEFORE UPDATE ON aibrewgenius.malt_depots
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER miscs_set_updated_at
  BEFORE UPDATE ON aibrewgenius.miscs
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER packaging_profiles_set_updated_at
  BEFORE UPDATE ON aibrewgenius.packaging_profiles
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER recipes_set_updated_at
  BEFORE UPDATE ON aibrewgenius.recipes
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER video_instructions_set_updated_at
  BEFORE UPDATE ON aibrewgenius.video_instructions
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER water_profiles_set_updated_at
  BEFORE UPDATE ON aibrewgenius.water_profiles
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();
CREATE OR REPLACE TRIGGER yeast_bank_entries_set_updated_at
  BEFORE UPDATE ON aibrewgenius.yeast_bank_entries
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.set_updated_at();

-- ---------------------------------------------------------------------------
-- 1f. RLS aktivieren
-- ---------------------------------------------------------------------------
ALTER TABLE aibrewgenius.ai_generated_recipes_v2  ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.batches                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.brew_kettles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.fermentables             ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.fermenter_controllers    ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.fermenters               ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.fining_agents            ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.hops                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.how_to_topics            ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.keezer_configs           ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.malt_depots              ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.miscs                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.packaging_profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.recipes                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.user_profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.video_instructions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.water_profiles           ENABLE ROW LEVEL SECURITY;
ALTER TABLE aibrewgenius.yeast_bank_entries       ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 1g. RLS-Policies (auth.uid()-basiert, authenticated only)
--     Finale Policies aus 002_auth.sql — kein anon-Zugriff
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS user_owns_profile ON aibrewgenius.user_profiles;
CREATE POLICY user_owns_profile ON aibrewgenius.user_profiles
  FOR ALL TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.ai_generated_recipes_v2;
CREATE POLICY user_owns_rows ON aibrewgenius.ai_generated_recipes_v2
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.batches;
CREATE POLICY user_owns_rows ON aibrewgenius.batches
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.brew_kettles;
CREATE POLICY user_owns_rows ON aibrewgenius.brew_kettles
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.fermentables;
CREATE POLICY user_owns_rows ON aibrewgenius.fermentables
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.fermenter_controllers;
CREATE POLICY user_owns_rows ON aibrewgenius.fermenter_controllers
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.fermenters;
CREATE POLICY user_owns_rows ON aibrewgenius.fermenters
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.fining_agents;
CREATE POLICY user_owns_rows ON aibrewgenius.fining_agents
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.hops;
CREATE POLICY user_owns_rows ON aibrewgenius.hops
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.how_to_topics;
CREATE POLICY user_owns_rows ON aibrewgenius.how_to_topics
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.keezer_configs;
CREATE POLICY user_owns_rows ON aibrewgenius.keezer_configs
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.malt_depots;
CREATE POLICY user_owns_rows ON aibrewgenius.malt_depots
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.miscs;
CREATE POLICY user_owns_rows ON aibrewgenius.miscs
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.packaging_profiles;
CREATE POLICY user_owns_rows ON aibrewgenius.packaging_profiles
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.recipes;
CREATE POLICY user_owns_rows ON aibrewgenius.recipes
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.video_instructions;
CREATE POLICY user_owns_rows ON aibrewgenius.video_instructions
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.water_profiles;
CREATE POLICY user_owns_rows ON aibrewgenius.water_profiles
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

DROP POLICY IF EXISTS user_owns_rows ON aibrewgenius.yeast_bank_entries;
CREATE POLICY user_owns_rows ON aibrewgenius.yeast_bank_entries
  FOR ALL TO authenticated
  USING (user_profile_id = auth.uid())
  WITH CHECK (user_profile_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 1h. Schema + Tabellen-Grants
-- ---------------------------------------------------------------------------
-- anon intentionally excluded: both apps are fully behind AuthGate; anon needs
-- no schema introspection rights on aibrewgenius (Fix 2: remove anon USAGE).
GRANT USAGE ON SCHEMA aibrewgenius TO authenticated, service_role, postgres;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON aibrewgenius.ai_generated_recipes_v2,
     aibrewgenius.batches,
     aibrewgenius.brew_kettles,
     aibrewgenius.fermentables,
     aibrewgenius.fermenter_controllers,
     aibrewgenius.fermenters,
     aibrewgenius.fining_agents,
     aibrewgenius.hops,
     aibrewgenius.how_to_topics,
     aibrewgenius.keezer_configs,
     aibrewgenius.malt_depots,
     aibrewgenius.miscs,
     aibrewgenius.packaging_profiles,
     aibrewgenius.recipes,
     aibrewgenius.user_profiles,
     aibrewgenius.video_instructions,
     aibrewgenius.water_profiles,
     aibrewgenius.yeast_bank_entries
  TO authenticated;

GRANT ALL
  ON aibrewgenius.ai_generated_recipes_v2,
     aibrewgenius.batches,
     aibrewgenius.brew_kettles,
     aibrewgenius.fermentables,
     aibrewgenius.fermenter_controllers,
     aibrewgenius.fermenters,
     aibrewgenius.fining_agents,
     aibrewgenius.hops,
     aibrewgenius.how_to_topics,
     aibrewgenius.keezer_configs,
     aibrewgenius.malt_depots,
     aibrewgenius.miscs,
     aibrewgenius.packaging_profiles,
     aibrewgenius.recipes,
     aibrewgenius.user_profiles,
     aibrewgenius.video_instructions,
     aibrewgenius.water_profiles,
     aibrewgenius.yeast_bank_entries
  TO service_role;

-- Fix 1: was "FOR ROLE postgres" — postgres is non-superuser and creates no
-- app tables; supabase_admin does. Omitting FOR ROLE runs as the executing role
-- (supabase_admin), matching the rapt section at ~line 1144.
ALTER DEFAULT PRIVILEGES IN SCHEMA aibrewgenius
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA aibrewgenius
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA aibrewgenius
  GRANT ALL ON SEQUENCES TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1i. Realtime-Publication (idempotent: only add if not already member)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  tables_to_add text[] := ARRAY[
    'aibrewgenius.ai_generated_recipes_v2',
    'aibrewgenius.batches',
    'aibrewgenius.recipes',
    'aibrewgenius.fermenter_controllers'
  ];
  t text;
  pub_oid oid;
BEGIN
  SELECT oid INTO pub_oid FROM pg_publication WHERE pubname = 'supabase_realtime';
  IF pub_oid IS NULL THEN
    RETURN; -- publication does not exist, skip silently
  END IF;

  FOREACH t IN ARRAY tables_to_add LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = split_part(t, '.', 1)
        AND tablename  = split_part(t, '.', 2)
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %s', t);
    END IF;
  END LOOP;
END $$;

-- =============================================================================
-- ABSCHNITT 2: aibrewgenius SECURITY DEFINER RPCs
-- =============================================================================
-- Alle mit SET search_path = '' und vollqualifizierten Objekten.
-- KEINE rapt-RPCs (get_my_rapt_creds / set_my_rapt_creds gedroppt in 009).

-- ---------------------------------------------------------------------------
-- 2a. aibrewgenius.handle_new_user() — Trigger-Funktion für auth.users
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aibrewgenius.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO aibrewgenius.user_profiles (id, name, language, brewfather_sync_enabled)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'name', pg_catalog.split_part(NEW.email, '@', 1)),
    'de',
    false
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END $$;

REVOKE EXECUTE ON FUNCTION aibrewgenius.handle_new_user() FROM PUBLIC;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION aibrewgenius.handle_new_user();

-- ---------------------------------------------------------------------------
-- 2b. aibrewgenius.get_my_brewfather_creds()
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aibrewgenius.get_my_brewfather_creds()
RETURNS TABLE (user_id text, api_key text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_secret_id uuid;
  v_user_id   text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT up.brewfather_user_id, up.brewfather_secret_id
    INTO v_user_id, v_secret_id
  FROM aibrewgenius.user_profiles up
  WHERE up.id = v_uid;

  IF v_secret_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT v_user_id, ds.decrypted_secret::text
    FROM vault.decrypted_secrets ds
    WHERE ds.id = v_secret_id;
END $$;

REVOKE EXECUTE ON FUNCTION aibrewgenius.get_my_brewfather_creds() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION aibrewgenius.get_my_brewfather_creds() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2c. aibrewgenius.set_my_brewfather_creds(text)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aibrewgenius.set_my_brewfather_creds(p_api_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid           uuid := auth.uid();
  v_secret_id     uuid;
  v_new_secret_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT up.brewfather_secret_id INTO v_secret_id
  FROM aibrewgenius.user_profiles up
  WHERE up.id = v_uid;

  IF p_api_key IS NULL OR p_api_key = '' THEN
    IF v_secret_id IS NOT NULL THEN
      UPDATE aibrewgenius.user_profiles
        SET brewfather_secret_id = NULL
      WHERE id = v_uid;
      DELETE FROM vault.secrets WHERE id = v_secret_id;
    END IF;
    RETURN;
  END IF;

  IF v_secret_id IS NULL THEN
    v_new_secret_id := vault.create_secret(
      new_secret      => p_api_key,
      new_name        => 'bf_' || v_uid::text,
      new_description => 'Brewfather API key for user ' || v_uid::text
    );
    UPDATE aibrewgenius.user_profiles
      SET brewfather_secret_id = v_new_secret_id
    WHERE id = v_uid;
  ELSE
    PERFORM vault.update_secret(secret_id => v_secret_id, new_secret => p_api_key);
  END IF;
END $$;

REVOKE EXECUTE ON FUNCTION aibrewgenius.set_my_brewfather_creds(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION aibrewgenius.set_my_brewfather_creds(text) TO authenticated;

-- =============================================================================
-- ABSCHNITT 3: rapt-Schema
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS rapt;
ALTER SCHEMA rapt OWNER TO supabase_admin;

-- anon intentionally excluded: both apps are fully behind AuthGate; anon needs
-- no schema introspection rights on rapt (Fix 2: remove anon USAGE).
GRANT USAGE ON SCHEMA rapt TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3a. rapt.user_profiles — finale Struktur (nach rapt/004)
--     id: uuid PK, FK → auth.users(id) ON DELETE CASCADE
--     rapt_configured: GENERATED; rapt_api_key: immer NULL seit 004
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.user_profiles (
  id              uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name            text        NOT NULL,
  avatar_blob     text,
  rapt_user_id    text,
  rapt_api_key    text,           -- immer NULL seit 004; Spalte bleibt für Compat
  updated_at      timestamptz NOT NULL DEFAULT now(),
  rapt_secret_id  uuid            REFERENCES vault.secrets(id) ON DELETE SET NULL,
  rapt_configured boolean         GENERATED ALWAYS AS (rapt_secret_id IS NOT NULL) STORED
);
ALTER TABLE rapt.user_profiles OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_user_profiles_rapt_secret_id
  ON rapt.user_profiles (rapt_secret_id)
  WHERE rapt_secret_id IS NOT NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON rapt.user_profiles TO authenticated;
GRANT ALL ON rapt.user_profiles TO service_role;

ALTER TABLE rapt.user_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_user_owns_profile_select ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_select
  ON rapt.user_profiles FOR SELECT TO authenticated
  USING (id = auth.uid());

DROP POLICY IF EXISTS rapt_user_owns_profile_insert ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_insert
  ON rapt.user_profiles FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

DROP POLICY IF EXISTS rapt_user_owns_profile_update ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_update
  ON rapt.user_profiles FOR UPDATE TO authenticated
  USING  (id = auth.uid())
  WITH CHECK (id = auth.uid());

DROP POLICY IF EXISTS rapt_user_owns_profile_delete ON rapt.user_profiles;
CREATE POLICY rapt_user_owns_profile_delete
  ON rapt.user_profiles FOR DELETE TO authenticated
  USING (id = auth.uid());

-- ---------------------------------------------------------------------------
-- 3b. rapt.controllers — finale Struktur (nach rapt/005): PK (owner, rapt_id)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.controllers (
  owner      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rapt_id    text        NOT NULL,
  name       text        NOT NULL,
  last_seen  timestamptz,
  raw        jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner, rapt_id)
);
ALTER TABLE rapt.controllers OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_controllers_owner ON rapt.controllers (owner);

ALTER TABLE rapt.controllers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_controllers_select ON rapt.controllers;
CREATE POLICY rapt_owner_controllers_select
  ON rapt.controllers FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.controllers TO authenticated;
GRANT ALL    ON rapt.controllers TO service_role;

-- ---------------------------------------------------------------------------
-- 3c. rapt.hydrometers — finale Struktur (nach rapt/005): PK (owner, rapt_id)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.hydrometers (
  owner      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rapt_id    text        NOT NULL,
  name       text        NOT NULL,
  last_seen  timestamptz,
  raw        jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner, rapt_id)
);
ALTER TABLE rapt.hydrometers OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_hydrometers_owner ON rapt.hydrometers (owner);

ALTER TABLE rapt.hydrometers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_hydrometers_select ON rapt.hydrometers;
CREATE POLICY rapt_owner_hydrometers_select
  ON rapt.hydrometers FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.hydrometers TO authenticated;
GRANT ALL    ON rapt.hydrometers TO service_role;

-- ---------------------------------------------------------------------------
-- 3d. rapt.profiles — finale Struktur (nach rapt/005): PK (owner, id)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.profiles (
  owner       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  id          text        NOT NULL,
  name        text        NOT NULL,
  deleted     boolean     DEFAULT false,
  is_public   boolean     DEFAULT false,
  created_on  timestamptz,
  modified_on timestamptz,
  raw         jsonb,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner, id)
);
ALTER TABLE rapt.profiles OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_profiles_owner ON rapt.profiles (owner);

ALTER TABLE rapt.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_profiles_select ON rapt.profiles;
CREATE POLICY rapt_owner_profiles_select
  ON rapt.profiles FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.profiles TO authenticated;
GRANT ALL    ON rapt.profiles TO service_role;

-- ---------------------------------------------------------------------------
-- 3e. rapt.telemetry_controllers — Hypertable; PK (owner, device_id, created_on)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.telemetry_controllers (
  owner                              uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id                          text        NOT NULL,
  created_on                         timestamptz NOT NULL,
  id                                 text,
  row_key                            text,
  mac_address                        text,
  rssi                               double precision,
  control_device_type                text,
  control_device_mac_address         text,
  control_device_temperature         double precision,
  temperature                        double precision,
  target_temperature                 double precision,
  min_target_temperature             double precision,
  max_target_temperature             double precision,
  total_run_time                     double precision,
  cooling_run_time                   double precision,
  cooling_starts                     double precision,
  heating_run_time                   double precision,
  heating_starts                     double precision,
  profile_id                         text,
  profile_step_id                    text,
  profile_session_start_date         timestamptz,
  profile_session_time               integer,
  profile_step_progress              integer,
  raw                                jsonb,
  PRIMARY KEY (owner, device_id, created_on)
);
ALTER TABLE rapt.telemetry_controllers OWNER TO supabase_admin;

SELECT public.create_hypertable('rapt.telemetry_controllers'::regclass, 'created_on'::name, if_not_exists => true);

CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_owner
  ON rapt.telemetry_controllers (owner);
CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_owner_time
  ON rapt.telemetry_controllers (owner, created_on DESC);
CREATE INDEX IF NOT EXISTS idx_telemetry_controllers_profile
  ON rapt.telemetry_controllers (profile_id, created_on DESC)
  WHERE profile_id IS NOT NULL;

ALTER TABLE rapt.telemetry_controllers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_telemetry_controllers_select ON rapt.telemetry_controllers;
CREATE POLICY rapt_owner_telemetry_controllers_select
  ON rapt.telemetry_controllers FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.telemetry_controllers TO authenticated;
GRANT ALL    ON rapt.telemetry_controllers TO service_role;

-- ---------------------------------------------------------------------------
-- 3f. rapt.telemetry_hydrometers — Hypertable; PK (owner, hydrometer_id, created_on)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.telemetry_hydrometers (
  owner            uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  hydrometer_id    text        NOT NULL,
  created_on       timestamptz NOT NULL,
  id               text,
  row_key          text,
  mac_address      text,
  rssi             double precision,
  temperature      double precision,
  gravity          double precision,
  gravity_velocity double precision,
  battery          double precision,
  version          text,
  raw              jsonb,
  PRIMARY KEY (owner, hydrometer_id, created_on)
);
ALTER TABLE rapt.telemetry_hydrometers OWNER TO supabase_admin;

SELECT public.create_hypertable('rapt.telemetry_hydrometers'::regclass, 'created_on'::name, if_not_exists => true);

CREATE INDEX IF NOT EXISTS idx_telemetry_hydrometers_owner
  ON rapt.telemetry_hydrometers (owner);
CREATE INDEX IF NOT EXISTS idx_telemetry_hydrometers_owner_time
  ON rapt.telemetry_hydrometers (owner, created_on DESC);

ALTER TABLE rapt.telemetry_hydrometers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_telemetry_hydrometers_select ON rapt.telemetry_hydrometers;
CREATE POLICY rapt_owner_telemetry_hydrometers_select
  ON rapt.telemetry_hydrometers FOR SELECT TO authenticated
  USING (owner = auth.uid());

GRANT SELECT ON rapt.telemetry_hydrometers TO authenticated;
GRANT ALL    ON rapt.telemetry_hydrometers TO service_role;

-- ---------------------------------------------------------------------------
-- 3g. rapt.brew_sessions — PK uuid; owner + RLS; Client schreibt direkt
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rapt.brew_sessions (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  owner             uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  profile_id        text,
  name              text        NOT NULL,
  start_date        timestamptz NOT NULL,
  end_date          timestamptz NOT NULL,
  custom_start_date timestamptz,
  custom_end_date   timestamptz,
  temp_key          text,
  is_hydrometer_only boolean,
  is_manual         boolean     DEFAULT false,
  updated_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE rapt.brew_sessions OWNER TO supabase_admin;

CREATE INDEX IF NOT EXISTS idx_brew_sessions_owner
  ON rapt.brew_sessions (owner);
CREATE INDEX IF NOT EXISTS idx_brew_sessions_profile_start
  ON rapt.brew_sessions (profile_id, start_date);
CREATE INDEX IF NOT EXISTS idx_brew_sessions_start
  ON rapt.brew_sessions (start_date DESC);

ALTER TABLE rapt.brew_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rapt_owner_brew_sessions_select ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_select
  ON rapt.brew_sessions FOR SELECT TO authenticated
  USING (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_insert ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_insert
  ON rapt.brew_sessions FOR INSERT TO authenticated
  WITH CHECK (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_update ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_update
  ON rapt.brew_sessions FOR UPDATE TO authenticated
  USING  (owner = auth.uid())
  WITH CHECK (owner = auth.uid());

DROP POLICY IF EXISTS rapt_owner_brew_sessions_delete ON rapt.brew_sessions;
CREATE POLICY rapt_owner_brew_sessions_delete
  ON rapt.brew_sessions FOR DELETE TO authenticated
  USING (owner = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON rapt.brew_sessions TO authenticated;
GRANT ALL ON rapt.brew_sessions TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA rapt
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon;

-- ---------------------------------------------------------------------------
-- 3h. View: rapt.device_activity_controllers (finale Version aus rapt/005)
--     security_invoker=true: RLS der Basistabellen greift für den abfragenden User
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS rapt.device_activity_controllers;
CREATE VIEW rapt.device_activity_controllers
  WITH (security_invoker = true)
AS
WITH ordered AS (
  SELECT
    owner, device_id, created_on, profile_id,
    LAG(created_on) OVER (
      PARTITION BY owner, device_id, profile_id ORDER BY created_on
    ) AS prev
  FROM rapt.telemetry_controllers
),
marked AS (
  SELECT
    owner, device_id, created_on, profile_id,
    SUM(
      CASE WHEN prev IS NULL OR created_on - prev > INTERVAL '7 days' THEN 1 ELSE 0 END
    ) OVER (
      PARTITION BY owner, device_id, profile_id ORDER BY created_on
    ) AS sess_n
  FROM ordered
)
SELECT
  m.owner,
  m.device_id,
  m.profile_id,
  p.name       AS profile_name,
  m.sess_n     AS session_index,
  MIN(m.created_on) AS first_seen,
  MAX(m.created_on) AS last_seen,
  COUNT(*)::int     AS point_count
FROM marked m
LEFT JOIN rapt.profiles p ON p.id = m.profile_id AND p.owner = m.owner
GROUP BY m.owner, m.device_id, m.profile_id, p.name, m.sess_n;

REVOKE SELECT ON rapt.device_activity_controllers FROM anon;
GRANT  SELECT ON rapt.device_activity_controllers TO authenticated;
GRANT  SELECT ON rapt.device_activity_controllers TO service_role;

-- =============================================================================
-- ABSCHNITT 4: rapt SECURITY DEFINER RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 4a. rapt.handle_new_user() — Trigger bei neuem auth.users-INSERT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO rapt.user_profiles (id, name, updated_at)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'name', pg_catalog.split_part(NEW.email, '@', 1), 'Brewer'),
    now()
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.handle_new_user() FROM PUBLIC;

DROP TRIGGER IF EXISTS on_rapt_user_created ON auth.users;
CREATE TRIGGER on_rapt_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION rapt.handle_new_user();

-- ---------------------------------------------------------------------------
-- 4b. rapt.get_my_rapt_creds()
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.get_my_rapt_creds()
RETURNS TABLE (username text, api_key text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_secret_id uuid;
  v_username  text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT up.rapt_user_id, up.rapt_secret_id
    INTO v_username, v_secret_id
  FROM rapt.user_profiles up
  WHERE up.id = v_uid;

  IF v_secret_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT v_username, ds.decrypted_secret::text
    FROM vault.decrypted_secrets ds
    WHERE ds.id = v_secret_id;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.get_my_rapt_creds() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rapt.get_my_rapt_creds() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4c. rapt.set_my_rapt_creds(p_rapt_user_id text, p_api_key text)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.set_my_rapt_creds(
  p_rapt_user_id text,
  p_api_key      text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_secret_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  INSERT INTO rapt.user_profiles (id, name, updated_at)
  VALUES (v_uid, COALESCE(p_rapt_user_id, 'Brewer'), now())
  ON CONFLICT (id) DO NOTHING;

  SELECT up.rapt_secret_id INTO v_secret_id
  FROM rapt.user_profiles up
  WHERE up.id = v_uid;

  IF p_api_key IS NULL OR p_api_key = '' THEN
    IF v_secret_id IS NOT NULL THEN
      UPDATE rapt.user_profiles
        SET rapt_secret_id = NULL, rapt_user_id = NULL, updated_at = now()
      WHERE id = v_uid;
      DELETE FROM vault.secrets WHERE id = v_secret_id;
    ELSE
      UPDATE rapt.user_profiles
        SET rapt_user_id = NULL, updated_at = now()
      WHERE id = v_uid;
    END IF;
    RETURN;
  END IF;

  IF v_secret_id IS NULL THEN
    v_secret_id := vault.create_secret(
      new_secret      => p_api_key,
      new_name        => 'rapt_dash_' || v_uid::text,
      new_description => 'RAPT API key for user ' || v_uid::text
    );
    UPDATE rapt.user_profiles
      SET rapt_secret_id = v_secret_id, rapt_user_id = p_rapt_user_id,
          rapt_api_key = NULL, updated_at = now()
    WHERE id = v_uid;
  ELSE
    PERFORM vault.update_secret(secret_id => v_secret_id, new_secret => p_api_key);
    UPDATE rapt.user_profiles
      SET rapt_user_id = p_rapt_user_id, rapt_api_key = NULL, updated_at = now()
    WHERE id = v_uid;
  END IF;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.set_my_rapt_creds(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rapt.set_my_rapt_creds(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4d. rapt.get_all_rapt_creds_for_sync() — headless Worker, kein auth.uid()
--     EXECUTE: strikt nur proxy_sync
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.get_all_rapt_creds_for_sync()
RETURNS TABLE (owner uuid, rapt_user_id text, rapt_api_key text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
    SELECT up.id, up.rapt_user_id, ds.decrypted_secret::text
    FROM rapt.user_profiles up
    JOIN vault.decrypted_secrets ds ON ds.id = up.rapt_secret_id
    WHERE up.rapt_secret_id IS NOT NULL;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.get_all_rapt_creds_for_sync() TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 4e. rapt.upsert_controller_for — proxy_sync Schreib-RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_controller_for(
  p_owner uuid, p_rapt_id text, p_name text, p_last_seen timestamptz, p_raw jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO rapt.controllers (owner, rapt_id, name, last_seen, raw, updated_at)
  VALUES (p_owner, p_rapt_id, p_name, p_last_seen, p_raw, now())
  ON CONFLICT (owner, rapt_id) DO UPDATE
    SET name = EXCLUDED.name, last_seen = EXCLUDED.last_seen,
        raw = EXCLUDED.raw, updated_at = now();
END $$;

REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_controller_for(uuid, text, text, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 4f. rapt.upsert_hydrometer_for — proxy_sync Schreib-RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_hydrometer_for(
  p_owner uuid, p_rapt_id text, p_name text, p_last_seen timestamptz, p_raw jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO rapt.hydrometers (owner, rapt_id, name, last_seen, raw, updated_at)
  VALUES (p_owner, p_rapt_id, p_name, p_last_seen, p_raw, now())
  ON CONFLICT (owner, rapt_id) DO UPDATE
    SET name = EXCLUDED.name, last_seen = EXCLUDED.last_seen,
        raw = EXCLUDED.raw, updated_at = now();
END $$;

REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_hydrometer_for(uuid, text, text, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 4g. rapt.upsert_profile_for — proxy_sync Schreib-RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.upsert_profile_for(
  p_owner uuid, p_id text, p_name text, p_deleted boolean, p_is_public boolean,
  p_created_on timestamptz, p_modified_on timestamptz, p_raw jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO rapt.profiles
    (owner, id, name, deleted, is_public, created_on, modified_on, raw, updated_at)
  VALUES
    (p_owner, p_id, p_name, p_deleted, p_is_public, p_created_on, p_modified_on, p_raw, now())
  ON CONFLICT (owner, id) DO UPDATE
    SET name = EXCLUDED.name, deleted = EXCLUDED.deleted, is_public = EXCLUDED.is_public,
        modified_on = EXCLUDED.modified_on, raw = EXCLUDED.raw, updated_at = now();
END $$;

REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.upsert_profile_for(uuid, text, text, boolean, boolean, timestamptz, timestamptz, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 4h. rapt.insert_controller_telemetry_for — jsonb-Batch-Insert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.insert_controller_telemetry_for(
  p_owner uuid, p_device_id text, p_rows jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    INSERT INTO rapt.telemetry_controllers (
      owner, device_id, created_on, id, row_key, mac_address, rssi,
      control_device_type, control_device_mac_address, control_device_temperature,
      temperature, target_temperature, min_target_temperature, max_target_temperature,
      total_run_time, cooling_run_time, cooling_starts, heating_run_time, heating_starts,
      profile_id, profile_step_id, profile_session_start_date,
      profile_session_time, profile_step_progress, raw
    ) VALUES (
      p_owner, p_device_id, (r->>'createdOn')::timestamptz,
      r->>'id', r->>'rowKey', r->>'macAddress', (r->>'rssi')::double precision,
      r->>'controlDeviceType', r->>'controlDeviceMacAddress',
      (r->>'controlDeviceTemperature')::double precision,
      (r->>'temperature')::double precision, (r->>'targetTemperature')::double precision,
      (r->>'minTargetTemperature')::double precision, (r->>'maxTargetTemperature')::double precision,
      (r->>'totalRunTime')::double precision, (r->>'coolingRunTime')::double precision,
      (r->>'coolingStarts')::double precision, (r->>'heatingRunTime')::double precision,
      (r->>'heatingStarts')::double precision, r->>'profileId', r->>'profileStepId',
      (r->>'profileSessionStartDate')::timestamptz,
      (r->>'profileSessionTime')::int, (r->>'profileStepProgress')::int, r
    )
    ON CONFLICT (owner, device_id, created_on) DO NOTHING;
  END LOOP;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.insert_controller_telemetry_for(uuid, text, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 4i. rapt.insert_hydrometer_telemetry_for — jsonb-Batch-Insert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.insert_hydrometer_telemetry_for(
  p_owner uuid, p_hydrometer_id text, p_rows jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE r jsonb;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    INSERT INTO rapt.telemetry_hydrometers (
      owner, hydrometer_id, created_on, id, row_key, mac_address, rssi,
      temperature, gravity, gravity_velocity, battery, version, raw
    ) VALUES (
      p_owner, p_hydrometer_id, (r->>'createdOn')::timestamptz,
      r->>'id', r->>'rowKey', r->>'macAddress', (r->>'rssi')::double precision,
      (r->>'temperature')::double precision, (r->>'gravity')::double precision,
      (r->>'gravityVelocity')::double precision, (r->>'battery')::double precision,
      r->>'version', r
    )
    ON CONFLICT (owner, hydrometer_id, created_on) DO NOTHING;
  END LOOP;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.insert_hydrometer_telemetry_for(uuid, text, jsonb) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 4j. rapt.derive_brew_sessions_for — Gap-Detection für proxy_sync
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.derive_brew_sessions_for(p_owner uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE s record; m record; rc integer;
BEGIN
  FOR s IN
    WITH ordered AS (
      SELECT created_on, profile_id,
             LAG(created_on) OVER (PARTITION BY profile_id ORDER BY created_on) AS prev
      FROM rapt.telemetry_controllers
      WHERE profile_id IS NOT NULL AND owner = p_owner
    ),
    marked AS (
      SELECT created_on, profile_id,
        SUM(CASE WHEN prev IS NULL OR created_on - prev > INTERVAL '7 days' THEN 1 ELSE 0 END)
          OVER (PARTITION BY profile_id ORDER BY created_on) AS sess_n
      FROM ordered
    )
    SELECT profile_id, sess_n AS session_index,
           MIN(created_on) AS first_seen, MAX(created_on) AS last_seen
    FROM marked GROUP BY profile_id, sess_n
  LOOP
    SELECT id INTO m
    FROM rapt.brew_sessions
    WHERE owner = p_owner AND profile_id = s.profile_id
      AND ABS(EXTRACT(EPOCH FROM (start_date - s.first_seen))) < 86400
    LIMIT 1;

    IF FOUND THEN
      UPDATE rapt.brew_sessions
        SET end_date = s.last_seen, updated_at = now()
      WHERE id = m.id AND owner = p_owner AND NOT is_manual AND end_date <> s.last_seen;
      GET DIAGNOSTICS rc = ROW_COUNT;
    ELSE
      INSERT INTO rapt.brew_sessions (owner, profile_id, name, start_date, end_date, is_manual)
      VALUES (
        p_owner, s.profile_id,
        COALESCE((SELECT name FROM rapt.profiles WHERE owner = p_owner AND id = s.profile_id),
                 '(unbenannter Sud)'),
        s.first_seen, s.last_seen, false
      );
    END IF;
  END LOOP;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.derive_brew_sessions_for(uuid) TO proxy_sync;

-- ---------------------------------------------------------------------------
-- 4k. rapt.last_telemetry_ts_for — Watermark-Abfrage für proxy_sync
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rapt.last_telemetry_ts_for(
  p_owner uuid, p_kind text, p_device text
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_ts timestamptz;
BEGIN
  IF p_kind = 'controller' THEN
    SELECT MAX(created_on) INTO v_ts
    FROM rapt.telemetry_controllers
    WHERE owner = p_owner AND device_id = p_device;
  ELSIF p_kind = 'hydrometer' THEN
    SELECT MAX(created_on) INTO v_ts
    FROM rapt.telemetry_hydrometers
    WHERE owner = p_owner AND hydrometer_id = p_device;
  ELSE
    RAISE EXCEPTION 'last_telemetry_ts_for: unbekannter p_kind %. Erlaubt: controller, hydrometer.', p_kind;
  END IF;
  RETURN v_ts;
END $$;

REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION rapt.last_telemetry_ts_for(uuid, text, text) TO proxy_sync;

-- =============================================================================
-- ABSCHNITT 5: proxy_sync-Grants
-- =============================================================================
-- Die Rolle selbst wird von zz-set-role-passwords.sh beim Init angelegt.
-- Hier NUR die DB-Ebene-Grants und Schema-USAGE.
-- KEIN direkter Tabellenzugriff (nach rapt/005 alles über RPCs).
-- =============================================================================

GRANT CONNECT ON DATABASE postgres TO proxy_sync;
GRANT USAGE ON SCHEMA rapt TO proxy_sync;
-- Suggestion B: no direct sequence grants for proxy_sync — sequences are managed
-- internally by the SECURITY DEFINER RPCs (which run as supabase_admin/owner).
-- proxy_sync has RPC-only access; direct USAGE/SELECT on sequences is unnecessary.

COMMENT ON ROLE proxy_sync IS
  'Minimal-privilegierte Rolle für den brew-proxy db-sync-Worker. '
  'Kein BYPASSRLS, kein Zugriff auf aibrewgenius.*/auth.*/vault.*. '
  'Passwort wird via zz-set-role-passwords.sh mit dedizierter PROXY_SYNC_PASSWORD-Variable gesetzt '
  '(NICHT ${POSTGRES_PASSWORD} — geteiltes Master-Passwort hebt least-privilege auf). '
  'Ab rapt/005_rapt_telemetry_owner.sql: KEIN direkter Tabellenzugriff mehr auf rapt.*; '
  'Schreibweg ausschliesslich via SECURITY DEFINER rapt.*_for()-RPCs. '
  'RAPT-Creds via rapt.get_all_rapt_creds_for_sync(). '
  'Baseline: webPage_infra/db_scripts/baseline_schema.sql.';

COMMIT;

-- =============================================================================
-- Sanity Checks (ausserhalb der Transaktion, read-only)
-- =============================================================================
\echo ''
\echo '=== BASELINE SANITY CHECKS ==='

\echo ''
\echo '== TimescaleDB-Extension =='
SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';

\echo ''
\echo '== Hypertables =='
SELECT hypertable_schema, hypertable_name, num_dimensions
FROM timescaledb_information.hypertables
ORDER BY hypertable_name;

\echo ''
\echo '== Schemas =='
SELECT schema_name FROM information_schema.schemata
WHERE schema_name IN ('aibrewgenius', 'rapt')
ORDER BY schema_name;

\echo ''
\echo '== aibrewgenius Tabellen =='
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'aibrewgenius' AND table_type = 'BASE TABLE'
ORDER BY table_name;

\echo ''
\echo '== rapt Tabellen =='
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'rapt' AND table_type = 'BASE TABLE'
ORDER BY table_name;

\echo ''
\echo '== RLS-Status =='
SELECT schemaname, tablename, rowsecurity
FROM pg_tables
WHERE schemaname IN ('aibrewgenius', 'rapt')
ORDER BY schemaname, tablename;

\echo ''
\echo '== Policy-Anzahl pro Schema =='
SELECT schemaname, COUNT(*) AS policy_count
FROM pg_policies
WHERE schemaname IN ('aibrewgenius', 'rapt')
GROUP BY schemaname ORDER BY schemaname;

\echo ''
\echo '== SECURITY DEFINER Funktionen (search_path soll leer sein) =='
SELECT n.nspname AS schema, p.proname AS function, p.prosecdef, p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('aibrewgenius', 'rapt') AND p.prosecdef = true
ORDER BY n.nspname, p.proname;

\echo ''
\echo '== Trigger auf auth.users =='
SELECT tgname, tgrelid::regclass, tgfoid::regproc
FROM pg_trigger
WHERE tgrelid = 'auth.users'::regclass
  AND tgname IN ('on_auth_user_created', 'on_rapt_user_created');

\echo ''
\echo '== proxy_sync Tabellen-Grants auf rapt.* (soll LEER sein) =='
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'proxy_sync' AND table_schema = 'rapt'
ORDER BY table_name, privilege_type;

\echo ''
\echo '== proxy_sync Function-Grants auf rapt.* =='
SELECT grantee, routine_schema, routine_name
FROM information_schema.role_routine_grants
WHERE grantee = 'proxy_sync' AND routine_schema = 'rapt'
ORDER BY routine_name;

\echo ''
\echo '== aibrewgenius RAPT-Shims (soll LEER sein) =='
SELECT proname FROM pg_proc
WHERE pronamespace = 'aibrewgenius'::regnamespace
  AND proname IN ('get_my_rapt_creds', 'set_my_rapt_creds');

\echo ''
\echo '== aibrewgenius user_profiles Spalten (keine rapt_*) =='
SELECT column_name, data_type, is_generated
FROM information_schema.columns
WHERE table_schema = 'aibrewgenius' AND table_name = 'user_profiles'
ORDER BY ordinal_position;
