-- Run by run.sh as a superuser on the throwaway database, before any migration.
-- Mimics the Supabase objects the migrations depend on. Never part of a real deployment.
SET client_min_messages = warning;

-- Supabase Auth's users table (only the columns PurohitDesk reads).
CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id                 uuid PRIMARY KEY,
  email              text,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now()
);
-- Like Supabase's postgres: it may use auth.users (SELECT, and REFERENCES for the app_users FK) but holds no
-- GRANT OPTION, so a migration's GRANT on auth objects only raises a WARNING and grants nothing.
GRANT USAGE ON SCHEMA auth TO pd_migrator;
GRANT SELECT, REFERENCES ON auth.users TO pd_migrator;

-- Supabase API roles, with a worst-case default: everything pd_migrator creates is granted to them.
-- The migrations must revoke it (the Data API stays off for schema app).
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
ALTER DEFAULT PRIVILEGES FOR ROLE pd_migrator GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE pd_migrator GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE pd_migrator GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE pd_migrator GRANT ALL ON SCHEMAS TO anon, authenticated, service_role;
