-- M1 foundation: schema `app`, the six application roles, shared helpers and triggers.
-- Spec: docs/spec.md §04 §1, §04 §7, §04 §9, §11 §3. Proposal: docs/proposals/m1.md.
-- Apply as the migration user (Supabase: `postgres`) as one script. No BEGIN/COMMIT here on purpose.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
CREATE SCHEMA app;
REVOKE ALL ON SCHEMA app FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Roles: all NOLOGIN, none BYPASSRLS. app_runtime gets LOGIN from the founder in M2.
-- ---------------------------------------------------------------------------
CREATE ROLE app_runtime     NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
CREATE ROLE app_domain      NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
CREATE ROLE app_authz       NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
CREATE ROLE app_bootstrap   NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
CREATE ROLE app_freebusy    NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
CREATE ROLE app_maintenance NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;

-- The migration user is never left a member of an application role. A migration that hands function ownership to
-- a role grants that role to CURRENT_USER, hands over, and revokes it again before it ends (spec U1; PostgreSQL
-- requires membership in the new owner).

GRANT USAGE ON SCHEMA app TO app_runtime, app_domain, app_authz, app_bootstrap, app_freebusy, app_maintenance;

-- ---------------------------------------------------------------------------
-- Request context (spec §04 §9). Set per transaction by withTenantTx with is_local = true.
-- Missing or empty settings yield NULL, so every tenant policy is false.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.current_actor_id() RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT nullif(pg_catalog.current_setting('app.actor_user_id', true), '')::uuid
$$;

CREATE FUNCTION app.current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT nullif(pg_catalog.current_setting('app.tenant_id', true), '')::uuid
$$;

-- ---------------------------------------------------------------------------
-- Errors (spec §11 §3): SQLSTATE PDxxx carries the class, MESSAGE the reason, DETAIL our JSON.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.raise_error(p_sqlstate text, p_reason text, p_details jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF p_sqlstate IS NULL OR p_sqlstate !~ '^PD[0-9]{3}$' THEN
    RAISE EXCEPTION USING ERRCODE = 'PD500', MESSAGE = 'BAD_ERROR_CODE',
      DETAIL = pg_catalog.jsonb_build_object('sqlstate', p_sqlstate)::text;
  END IF;
  RAISE EXCEPTION USING ERRCODE = p_sqlstate, MESSAGE = p_reason,
    DETAIL = coalesce(p_details, '{}'::jsonb)::text;
END
$$;

-- ---------------------------------------------------------------------------
-- Time zones (spec ADR-013, defect R6): IANA Area/Location (or UTC) recognised by PostgreSQL.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.is_valid_timezone(p text) RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce(
    p ~ '^(UTC|[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+)+)$'
    AND EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names tz WHERE tz.name = p),
    false)
$$;

-- ---------------------------------------------------------------------------
-- Shared triggers
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.tg_bump_version() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.version := OLD.version + 1;
  NEW.updated_at := pg_catalog.now();
  RETURN NEW;
END
$$;

CREATE FUNCTION app.tg_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := pg_catalog.now();
  RETURN NEW;
END
$$;

CREATE FUNCTION app.tg_append_only() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  PERFORM app.raise_error('PD405', 'APPEND_ONLY', pg_catalog.jsonb_build_object('table', TG_TABLE_NAME));
  RETURN NULL;
END
$$;

-- Usage: CREATE TRIGGER … EXECUTE FUNCTION app.tg_validate_timezone('<column name>')
CREATE FUNCTION app.tg_validate_timezone() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NOT app.is_valid_timezone(pg_catalog.to_jsonb(NEW) ->> TG_ARGV[0]) THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', pg_catalog.jsonb_build_object('field', TG_ARGV[0]));
  END IF;
  RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.current_actor_id(), app.current_tenant_id()
  TO app_runtime, app_domain, app_authz, app_bootstrap, app_freebusy, app_maintenance;
GRANT EXECUTE ON FUNCTION app.raise_error(text, text, jsonb), app.is_valid_timezone(text)
  TO app_domain, app_authz, app_bootstrap, app_freebusy, app_maintenance;

-- Supabase API roles never touch schema app (the Data API stays off for it).
DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
      EXECUTE pg_catalog.format('REVOKE ALL ON SCHEMA app FROM %I', r);
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL TABLES IN SCHEMA app FROM %I', r);
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM %I', r);
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA app FROM %I', r);
    END IF;
  END LOOP;
END
$$;
