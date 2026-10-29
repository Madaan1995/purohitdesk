-- M2 auth, session and onboarding: offerings, org_sequences, idempotency_keys; identity commands
-- ensure_current_user, update_my_profile, bootstrap_practice; idempotency helpers.
-- Spec: docs/spec.md §04 §3/§7–§9, §05 §9, §08 §1–§3. Proposal: docs/proposals/m2.md.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE app.offerings (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                   uuid NOT NULL REFERENCES app.organizations (id),
  ceremony_type_id         uuid REFERENCES app.ceremony_types (id),
  name_hi                  text NOT NULL CHECK (char_length(btrim(name_hi)) BETWEEN 1 AND 120),
  name_en                  text NOT NULL CHECK (char_length(btrim(name_en)) BETWEEN 1 AND 120),
  duration_min             integer NOT NULL CHECK (duration_min BETWEEN 15 AND 1440),
  suggested_dakshina_paise bigint CHECK (suggested_dakshina_paise BETWEEN 0 AND 100000000000),
  is_active                boolean NOT NULL DEFAULT true,
  version                  integer NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id)
);
CREATE UNIQUE INDEX offerings_org_name_en_key ON app.offerings (org_id, lower(name_en));
CREATE TRIGGER offerings_bump_version BEFORE UPDATE ON app.offerings
  FOR EACH ROW EXECUTE FUNCTION app.tg_bump_version();

-- Per-organization booking counter for PD-YY-NNNN (used from M6; row created at onboarding).
CREATE TABLE app.org_sequences (
  org_id          uuid PRIMARY KEY REFERENCES app.organizations (id),
  next_booking_no bigint NOT NULL DEFAULT 1 CHECK (next_booking_no >= 1)
);

-- Idempotency keys, claimed inside the command's transaction (spec §05 §9).
CREATE TABLE app.idempotency_keys (
  actor_user_id uuid NOT NULL REFERENCES app.app_users (id),
  key           text NOT NULL CONSTRAINT idempotency_keys_key_check CHECK (char_length(key) BETWEEN 8 AND 128),
  command       text NOT NULL,
  request_hash  text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  org_id        uuid REFERENCES app.organizations (id),
  response      jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY (actor_user_id, key)
);

ALTER TABLE app.offerings        ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.offerings        FORCE ROW LEVEL SECURITY;
ALTER TABLE app.org_sequences    ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.org_sequences    FORCE ROW LEVEL SECURITY;
ALTER TABLE app.idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.idempotency_keys FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Policies: tenant reads
-- ---------------------------------------------------------------------------
CREATE POLICY offerings_read ON app.offerings
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Policies: app_bootstrap creates only rows owned by the verified actor (spec §08 §3)
-- ---------------------------------------------------------------------------
CREATE POLICY app_users_bootstrap_own ON app.app_users
  FOR SELECT TO app_bootstrap
  USING (id = (SELECT app.current_actor_id()));
CREATE POLICY app_users_bootstrap_insert ON app.app_users
  FOR INSERT TO app_bootstrap
  WITH CHECK (id = (SELECT app.current_actor_id()) AND auth_user_id = id);

CREATE POLICY organizations_bootstrap_own ON app.organizations
  FOR SELECT TO app_bootstrap
  USING (created_by = (SELECT app.current_actor_id()));
CREATE POLICY organizations_bootstrap_insert ON app.organizations
  FOR INSERT TO app_bootstrap
  WITH CHECK (created_by = (SELECT app.current_actor_id()));

CREATE POLICY org_members_bootstrap_own ON app.org_members
  FOR SELECT TO app_bootstrap
  USING (user_id = (SELECT app.current_actor_id()));
CREATE POLICY org_members_bootstrap_insert ON app.org_members
  FOR INSERT TO app_bootstrap
  WITH CHECK (
    user_id = (SELECT app.current_actor_id()) AND role = 'OWNER' AND status = 'ACTIVE'
    AND org_id IN (SELECT o.id FROM app.organizations o WHERE o.created_by = (SELECT app.current_actor_id())));

CREATE POLICY priest_profiles_bootstrap_own ON app.priest_profiles
  FOR SELECT TO app_bootstrap
  USING (user_id = (SELECT app.current_actor_id()));
CREATE POLICY priest_profiles_bootstrap_insert ON app.priest_profiles
  FOR INSERT TO app_bootstrap
  WITH CHECK (user_id = (SELECT app.current_actor_id()));

CREATE POLICY organization_priests_bootstrap_own ON app.organization_priests
  FOR SELECT TO app_bootstrap
  USING (org_id IN (SELECT o.id FROM app.organizations o WHERE o.created_by = (SELECT app.current_actor_id())));
CREATE POLICY organization_priests_bootstrap_insert ON app.organization_priests
  FOR INSERT TO app_bootstrap
  WITH CHECK (
    linked_via = 'BOOTSTRAP'
    AND priest_profile_id IN (SELECT p.id FROM app.priest_profiles p WHERE p.user_id = (SELECT app.current_actor_id()))
    AND org_id IN (SELECT o.id FROM app.organizations o WHERE o.created_by = (SELECT app.current_actor_id())));

CREATE POLICY org_sequences_bootstrap ON app.org_sequences
  FOR ALL TO app_bootstrap
  USING (org_id IN (SELECT o.id FROM app.organizations o WHERE o.created_by = (SELECT app.current_actor_id())))
  WITH CHECK (org_id IN (SELECT o.id FROM app.organizations o WHERE o.created_by = (SELECT app.current_actor_id())));

CREATE POLICY offerings_bootstrap ON app.offerings
  FOR ALL TO app_bootstrap
  USING (org_id IN (SELECT o.id FROM app.organizations o WHERE o.created_by = (SELECT app.current_actor_id())))
  WITH CHECK (org_id IN (SELECT o.id FROM app.organizations o WHERE o.created_by = (SELECT app.current_actor_id())));

CREATE POLICY ceremony_types_bootstrap_read ON app.ceremony_types
  FOR SELECT TO app_bootstrap
  USING (true);

-- ---------------------------------------------------------------------------
-- Policies: own profile edits and own idempotency keys
-- ---------------------------------------------------------------------------
CREATE POLICY app_users_domain_update_own ON app.app_users
  FOR UPDATE TO app_domain
  USING (id = (SELECT app.current_actor_id()))
  WITH CHECK (id = (SELECT app.current_actor_id()));

CREATE POLICY idempotency_keys_own ON app.idempotency_keys
  FOR ALL TO app_domain, app_bootstrap
  USING (actor_user_id = (SELECT app.current_actor_id()))
  WITH CHECK (actor_user_id = (SELECT app.current_actor_id()));

-- ---------------------------------------------------------------------------
-- Grants (tables)
-- ---------------------------------------------------------------------------
REVOKE ALL ON app.offerings, app.org_sequences, app.idempotency_keys FROM PUBLIC;
GRANT SELECT ON app.offerings TO app_runtime, app_domain;
GRANT SELECT, INSERT ON app.app_users, app.organizations, app.org_members, app.priest_profiles,
                        app.organization_priests, app.org_sequences, app.offerings
  TO app_bootstrap;
GRANT SELECT ON app.ceremony_types TO app_bootstrap;
GRANT UPDATE (display_name, preferred_locale) ON app.app_users TO app_domain;
GRANT SELECT, INSERT, UPDATE ON app.idempotency_keys TO app_domain, app_bootstrap;

-- ---------------------------------------------------------------------------
-- Internal helpers (SECURITY INVOKER: they run with the privileges of the calling command's owner)
-- ---------------------------------------------------------------------------
CREATE FUNCTION app._slugify(p text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT coalesce(
    nullif(btrim(left(btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '-', 'g'), '-'), 60), '-'), ''),
    'practice')
$$;

CREATE FUNCTION app._idem_begin(p_command text, p_key text, p_hash text) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := app.current_actor_id();
  v_row   app.idempotency_keys%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;
  IF p_key IS NULL THEN
    PERFORM app.raise_error('PD422', 'IDEMPOTENCY_KEY_REQUIRED', '{"field": "idempotency_key"}');
  END IF;
  IF p_hash IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "request_hash"}');
  END IF;

  INSERT INTO app.idempotency_keys (actor_user_id, key, command, request_hash, org_id)
  VALUES (v_actor, p_key, p_command, p_hash, app.current_tenant_id())
  ON CONFLICT (actor_user_id, key) DO NOTHING;
  IF FOUND THEN
    RETURN NULL;  -- claimed: the caller does the work, then calls _idem_finish
  END IF;

  SELECT * INTO v_row FROM app.idempotency_keys k WHERE k.actor_user_id = v_actor AND k.key = p_key;
  IF v_row.command IS DISTINCT FROM p_command
     OR v_row.request_hash IS DISTINCT FROM p_hash
     OR v_row.org_id IS DISTINCT FROM app.current_tenant_id() THEN
    PERFORM app.raise_error('PD412', 'IDEMPOTENCY_REUSE');
  END IF;
  IF v_row.response IS NULL THEN
    PERFORM app.raise_error('PD412', 'IDEMPOTENCY_REUSE', '{"reason": "original_response_erased"}');
  END IF;
  RETURN v_row.response || '{"idempotent_replay": true}'::jsonb;
END
$$;

CREATE FUNCTION app._idem_finish(p_key text, p_result jsonb) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  UPDATE app.idempotency_keys k
  SET response = p_result
  WHERE k.actor_user_id = app.current_actor_id() AND k.key = p_key;
  RETURN p_result || '{"idempotent_replay": false}'::jsonb;
END
$$;

-- ---------------------------------------------------------------------------
-- ensure_current_user (owner app_bootstrap): first login creates the app user.
-- No application role reads auth.users: the foreign key app_users.auth_user_id -> auth.users(id) proves the actor is
-- a Supabase auth user (the check runs with the rights of auth.users' owner). p_display_name comes from the verified
-- JWT's user_metadata; it is untrusted display text, cleaned here and never used for authorization.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.ensure_current_user(p_locale text DEFAULT NULL, p_display_name text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := app.current_actor_id();
  v_user  app.app_users%ROWTYPE;
  v_name  text;
BEGIN
  IF v_actor IS NULL THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;

  SELECT * INTO v_user FROM app.app_users u WHERE u.id = v_actor;
  IF NOT FOUND THEN
    -- Control and bidi-override characters become spaces; runs of space collapse; at most 120 characters.
    v_name := nullif(btrim(left(btrim(pg_catalog.regexp_replace(coalesce(p_display_name, ''),
                '[[:cntrl:][:space:]\u200B-\u200F\u202A-\u202E\u2066-\u2069]+', ' ', 'g')), 120)), '');
    BEGIN
      INSERT INTO app.app_users (id, auth_user_id, display_name, preferred_locale)
      VALUES (v_actor, v_actor, v_name, CASE WHEN p_locale IN ('hi', 'en') THEN p_locale ELSE 'hi' END)
      ON CONFLICT (id) DO NOTHING;
    EXCEPTION WHEN foreign_key_violation THEN
      -- Not a Supabase auth user (spec §08 §1).
      PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
    END;
    SELECT * INTO v_user FROM app.app_users u WHERE u.id = v_actor;
  END IF;

  -- A deleted or detached identity can never act again (spec §08 §1).
  IF v_user.status <> 'ACTIVE' OR v_user.auth_user_id IS NULL THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;

  RETURN jsonb_build_object(
    'id', v_user.id, 'display_name', v_user.display_name, 'preferred_locale', v_user.preferred_locale);
END
$$;

-- ---------------------------------------------------------------------------
-- update_my_profile (owner app_domain): own name and language; last write wins, no idempotency key.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.update_my_profile(p_display_name text, p_preferred_locale text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := app.current_actor_id();
  v_user  app.app_users%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;
  IF p_display_name IS NOT NULL AND char_length(btrim(p_display_name)) NOT BETWEEN 1 AND 120 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "display_name"}');
  END IF;
  IF p_preferred_locale IS NOT NULL AND p_preferred_locale NOT IN ('hi', 'en') THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "preferred_locale"}');
  END IF;

  UPDATE app.app_users u
  SET display_name     = coalesce(btrim(p_display_name), u.display_name),
      preferred_locale = coalesce(p_preferred_locale, u.preferred_locale)
  WHERE u.id = v_actor AND u.status = 'ACTIVE' AND u.auth_user_id IS NOT NULL
  RETURNING u.* INTO v_user;
  IF NOT FOUND THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;

  RETURN jsonb_build_object(
    'id', v_user.id, 'display_name', v_user.display_name, 'preferred_locale', v_user.preferred_locale);
END
$$;

-- ---------------------------------------------------------------------------
-- bootstrap_practice (owner app_bootstrap): the first (or 2nd/3rd) practice in one step.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.bootstrap_practice(
  p_name text, p_ceremony_type_ids uuid[], p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor      uuid := app.current_actor_id();
  v_user       app.app_users%ROWTYPE;
  v_replay     jsonb;
  v_name       text := btrim(p_name);
  v_org        app.organizations%ROWTYPE;
  v_slug_base  text;
  v_slug       text;
  v_created    boolean := false;
  v_profile_id uuid;
  v_link_id    uuid;
  v_offerings  integer;
BEGIN
  IF v_actor IS NULL THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;
  IF app.current_tenant_id() IS NOT NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "tenant"}');
  END IF;
  SELECT * INTO v_user FROM app.app_users u WHERE u.id = v_actor;
  IF NOT FOUND OR v_user.status <> 'ACTIVE' OR v_user.auth_user_id IS NULL THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;

  -- One onboarding at a time per human: serialises the quota check and the priest profile creation.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bootstrap_practice:' || v_actor::text, 0));

  v_replay := app._idem_begin('bootstrap_practice', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF v_name IS NULL OR char_length(v_name) NOT BETWEEN 1 AND 120 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "name"}');
  END IF;
  IF p_ceremony_type_ids IS NULL
     OR cardinality(p_ceremony_type_ids) NOT BETWEEN 1 AND 20
     OR (SELECT count(DISTINCT x) FROM unnest(p_ceremony_type_ids) AS x) <> cardinality(p_ceremony_type_ids)
     OR (SELECT count(*) FROM app.ceremony_types c WHERE c.id = ANY (p_ceremony_type_ids))
        <> cardinality(p_ceremony_type_ids) THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "ceremony_type_ids"}');
  END IF;
  IF (SELECT count(*) FROM app.organizations o WHERE o.created_by = v_actor AND o.status = 'ACTIVE') >= 3 THEN
    PERFORM app.raise_error('PD429', 'QUOTA_EXCEEDED', '{"limit": 3}');
  END IF;

  -- The slug is generated, unique and never shown: collisions get a random suffix.
  v_slug_base := app._slugify(v_name);
  FOR i IN 0..9 LOOP
    v_slug := CASE WHEN i = 0 THEN v_slug_base
                   ELSE rtrim(left(v_slug_base, 53), '-') || '-' || substr(md5(gen_random_uuid()::text), 1, 6) END;
    BEGIN
      INSERT INTO app.organizations (name, slug, created_by)
      VALUES (v_name, v_slug, v_actor)
      RETURNING * INTO v_org;
      v_created := true;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      NULL;  -- slug taken; try the next candidate
    END;
  END LOOP;
  IF NOT v_created THEN
    PERFORM app.raise_error('PD500', 'SLUG_UNAVAILABLE');
  END IF;

  INSERT INTO app.org_members (org_id, user_id, role, status) VALUES (v_org.id, v_actor, 'OWNER', 'ACTIVE');

  -- One global priest profile per human, reused across practices.
  SELECT p.id INTO v_profile_id FROM app.priest_profiles p WHERE p.user_id = v_actor;
  IF v_profile_id IS NULL THEN
    INSERT INTO app.priest_profiles (user_id, display_name)
    VALUES (v_actor, coalesce(v_user.display_name, v_name))
    RETURNING id INTO v_profile_id;
  END IF;

  INSERT INTO app.organization_priests (org_id, priest_profile_id, linked_via)
  VALUES (v_org.id, v_profile_id, 'BOOTSTRAP')
  RETURNING id INTO v_link_id;

  INSERT INTO app.org_sequences (org_id) VALUES (v_org.id);

  INSERT INTO app.offerings (org_id, ceremony_type_id, name_hi, name_en, duration_min)
  SELECT v_org.id, c.id, c.name_hi, c.name_en, c.default_duration_min
  FROM app.ceremony_types c
  WHERE c.id = ANY (p_ceremony_type_ids);
  GET DIAGNOSTICS v_offerings = ROW_COUNT;

  RETURN app._idem_finish(p_idem_key, jsonb_build_object(
    'organization', jsonb_build_object(
      'id', v_org.id, 'name', v_org.name, 'kind', v_org.kind, 'timezone', v_org.timezone,
      'status', v_org.status, 'version', v_org.version),
    'role', 'OWNER',
    'organization_priest_id', v_link_id,
    'offering_count', v_offerings));
END
$$;

-- ---------------------------------------------------------------------------
-- Ownership hand-over (temporary CREATE on the schema, spec defect #2) and EXECUTE grants.
-- The migration user is a member of the function-owning roles only until the end of this file: the hand-over and the
-- schema-wide REVOKE ... FROM PUBLIC need the owners' rights (app_authz owns the M1 helpers).
-- ---------------------------------------------------------------------------
GRANT app_authz, app_bootstrap, app_domain TO CURRENT_USER;

GRANT CREATE ON SCHEMA app TO app_bootstrap, app_domain;
ALTER FUNCTION app.ensure_current_user(text, text) OWNER TO app_bootstrap;
ALTER FUNCTION app.bootstrap_practice(text, uuid[], text, text) OWNER TO app_bootstrap;
ALTER FUNCTION app.update_my_profile(text, text) OWNER TO app_domain;
REVOKE CREATE ON SCHEMA app FROM app_bootstrap, app_domain;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app._idem_begin(text, text, text), app._idem_finish(text, jsonb)
  TO app_domain, app_bootstrap;
GRANT EXECUTE ON FUNCTION app._slugify(text) TO app_bootstrap;
GRANT EXECUTE ON FUNCTION
  app.ensure_current_user(text, text),
  app.update_my_profile(text, text),
  app.bootstrap_practice(text, uuid[], text, text)
  TO app_runtime;

-- These functions are owned by app_bootstrap and app_domain. A GRANT by a user without the owner's
-- rights only warns and grants nothing, so check that every EXECUTE grant above is really in the ACL.
DO $$
DECLARE
  v record;
BEGIN
  FOR v IN
    SELECT x.fn, x.grantee
    FROM (VALUES
      ('app.ensure_current_user(text,text)', 'app_runtime'),
      ('app.update_my_profile(text,text)', 'app_runtime'),
      ('app.bootstrap_practice(text,uuid[],text,text)', 'app_runtime')
    ) AS x (fn, grantee)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_proc p CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) a
      WHERE p.oid = v.fn::regprocedure AND a.grantee = v.grantee::regrole AND a.privilege_type = 'EXECUTE'
    ) THEN
      RAISE EXCEPTION 'GRANT EXECUTE ON FUNCTION % TO % did not take effect', v.fn, v.grantee;
    END IF;
  END LOOP;
END
$$;

DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL TABLES IN SCHEMA app FROM %I', r);
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM %I', r);
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA app FROM %I', r);
    END IF;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- End of the hand-over: the migration user keeps no application role's privileges (as after M1).
-- ---------------------------------------------------------------------------
REVOKE app_authz, app_bootstrap, app_domain FROM CURRENT_USER;

DO $$
DECLARE
  r     text;
  v_set boolean;
BEGIN
  IF (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = CURRENT_USER) THEN
    RETURN;
  END IF;
  FOREACH r IN ARRAY ARRAY['app_runtime', 'app_domain', 'app_authz', 'app_bootstrap', 'app_freebusy',
                           'app_maintenance', 'app_operator'] LOOP
    IF pg_catalog.current_setting('server_version_num')::int >= 160000 THEN
      v_set := pg_catalog.pg_has_role(CURRENT_USER, r, 'SET');
    ELSE
      v_set := pg_catalog.pg_has_role(CURRENT_USER, r, 'MEMBER');
    END IF;
    IF v_set OR pg_catalog.pg_has_role(CURRENT_USER, r, 'USAGE') THEN
      RAISE EXCEPTION 'migration user % is still a member of %', CURRENT_USER, r;
    END IF;
  END LOOP;
END
$$;
