-- M4 customers: table with forced RLS, provenance guard, create_customer / update_customer (owner app_domain).
-- Spec: docs/spec.md §01 §3, §04 §3/§5/§6, §05 §9–§10, ADR-012. Proposal: docs/proposals/m4.md.

CREATE TABLE app.customers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES app.organizations (id),
  display_name       text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 120),
  phone_e164         text CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  address            text CHECK (char_length(btrim(address)) BETWEEN 1 AND 500),
  acquisition_source text NOT NULL DEFAULT 'PRIEST_DIRECT' CHECK (acquisition_source IN ('PRIEST_DIRECT', 'IMPORT')),
  erased_at          timestamptz,
  version            integer NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id)
);
CREATE INDEX customers_name_prefix_idx ON app.customers (org_id, lower(display_name) text_pattern_ops);
CREATE INDEX customers_phone_idx ON app.customers (org_id, phone_e164) WHERE phone_e164 IS NOT NULL;

-- Provenance and tenant are immutable (spec ADR-012, defect A6).
CREATE FUNCTION app.tg_customer_source_immutable() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.acquisition_source IS DISTINCT FROM OLD.acquisition_source THEN
    PERFORM app.raise_error('PD422', 'IMMUTABLE_FIELD', '{"field": "acquisition_source"}');
  END IF;
  IF NEW.org_id IS DISTINCT FROM OLD.org_id OR NEW.id IS DISTINCT FROM OLD.id THEN
    PERFORM app.raise_error('PD422', 'IMMUTABLE_FIELD', '{"field": "org_id"}');
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER customers_bump_version BEFORE UPDATE ON app.customers
  FOR EACH ROW EXECUTE FUNCTION app.tg_bump_version();
CREATE TRIGGER customers_source_immutable BEFORE UPDATE ON app.customers
  FOR EACH ROW EXECUTE FUNCTION app.tg_customer_source_immutable();

ALTER TABLE app.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.customers FORCE ROW LEVEL SECURITY;

CREATE POLICY customers_read ON app.customers
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY customers_domain_insert ON app.customers
  FOR INSERT TO app_domain
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY customers_domain_update ON app.customers
  FOR UPDATE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

REVOKE ALL ON app.customers FROM PUBLIC;
GRANT SELECT ON app.customers TO app_runtime;
GRANT SELECT, INSERT, UPDATE ON app.customers TO app_domain;

-- ---------------------------------------------------------------------------
-- Internal helpers (invoker; run as the calling command's owner, under its RLS)
-- ---------------------------------------------------------------------------
CREATE FUNCTION app._customer_out(c app.customers) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', c.id, 'display_name', c.display_name, 'phone_e164', c.phone_e164, 'address', c.address,
    'acquisition_source', c.acquisition_source, 'version', c.version,
    'created_at', c.created_at, 'updated_at', c.updated_at)
$$;

-- Other non-erased customers of the organization with the same phone (shared household phones are allowed).
CREATE FUNCTION app._customer_duplicates(p_org uuid, p_phone text, p_exclude uuid) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'display_name', c.display_name)
                            ORDER BY c.created_at, c.id), '[]'::jsonb)
  FROM app.customers c
  WHERE p_phone IS NOT NULL AND c.org_id = p_org AND c.phone_e164 = p_phone
    AND c.id <> p_exclude AND c.erased_at IS NULL
$$;

CREATE FUNCTION app._check_customer_fields(p_display_name text, p_phone_e164 text, p_address text) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF p_display_name IS NULL OR char_length(p_display_name) NOT BETWEEN 1 AND 120 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "display_name"}');
  END IF;
  IF p_phone_e164 IS NOT NULL AND p_phone_e164 !~ '^\+[1-9][0-9]{7,14}$' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "phone_e164"}');
  END IF;
  IF p_address IS NOT NULL AND char_length(p_address) > 500 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "address"}');
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- create_customer (CUSTOMER_WRITE)
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.create_customer(
  p_display_name text, p_phone_e164 text, p_address text, p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay  jsonb;
  v_name    text := btrim(p_display_name);
  v_address text := nullif(btrim(p_address), '');
  v_c       app.customers%ROWTYPE;
BEGIN
  PERFORM app.assert_permission('CUSTOMER_WRITE');
  v_replay := app._idem_begin('create_customer', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  PERFORM app._check_customer_fields(v_name, p_phone_e164, v_address);

  INSERT INTO app.customers (org_id, display_name, phone_e164, address)
  VALUES (app.current_tenant_id(), v_name, p_phone_e164, v_address)
  RETURNING * INTO v_c;

  RETURN app._idem_finish(p_idem_key, jsonb_build_object(
    'customer', app._customer_out(v_c),
    'possible_duplicates', app._customer_duplicates(v_c.org_id, v_c.phone_e164, v_c.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- update_customer (CUSTOMER_WRITE): JSON patch of display_name / phone_e164 / address, optimistic version check.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.update_customer(
  p_customer_id uuid, p_expected_version integer, p_patch jsonb, p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay  jsonb;
  v_c       app.customers%ROWTYPE;
  v_key     text;
  v_name    text;
  v_phone   text;
  v_address text;
BEGIN
  PERFORM app.assert_permission('CUSTOMER_WRITE');
  v_replay := app._idem_begin('update_customer', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  SELECT * INTO v_c
  FROM app.customers c
  WHERE c.id = p_customer_id AND c.org_id = app.current_tenant_id() AND c.erased_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "customer"}');
  END IF;
  IF p_expected_version IS NULL OR v_c.version <> p_expected_version THEN
    PERFORM app.raise_error('PD409', 'VERSION_CONFLICT', jsonb_build_object('current_version', v_c.version));
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' OR p_patch = '{}'::jsonb THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "body"}');
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_patch) LOOP
    IF v_key IN ('id', 'org_id', 'acquisition_source', 'version', 'erased_at', 'created_at', 'updated_at') THEN
      PERFORM app.raise_error('PD422', 'IMMUTABLE_FIELD', jsonb_build_object('field', v_key));
    ELSIF v_key NOT IN ('display_name', 'phone_e164', 'address') THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', v_key));
    END IF;
  END LOOP;

  v_name    := CASE WHEN p_patch ? 'display_name' THEN btrim(p_patch ->> 'display_name') ELSE v_c.display_name END;
  v_phone   := CASE WHEN p_patch ? 'phone_e164' THEN p_patch ->> 'phone_e164' ELSE v_c.phone_e164 END;
  v_address := CASE WHEN p_patch ? 'address' THEN nullif(btrim(p_patch ->> 'address'), '') ELSE v_c.address END;
  PERFORM app._check_customer_fields(v_name, v_phone, v_address);

  UPDATE app.customers c
  SET display_name = v_name, phone_e164 = v_phone, address = v_address
  WHERE c.id = v_c.id
  RETURNING * INTO v_c;

  RETURN app._idem_finish(p_idem_key, jsonb_build_object(
    'customer', app._customer_out(v_c),
    'possible_duplicates', app._customer_duplicates(v_c.org_id, v_c.phone_e164, v_c.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- Ownership hand-over and EXECUTE grants.
-- The migration user is a member of the function-owning roles only until the end of this file: the hand-over and the
-- schema-wide REVOKE ... FROM PUBLIC need the owners' rights (spec U1).
-- ---------------------------------------------------------------------------
GRANT app_authz, app_bootstrap, app_domain, app_operator TO CURRENT_USER;

GRANT CREATE ON SCHEMA app TO app_domain;
ALTER FUNCTION app.create_customer(text, text, text, text, text) OWNER TO app_domain;
ALTER FUNCTION app.update_customer(uuid, integer, jsonb, text, text) OWNER TO app_domain;
REVOKE CREATE ON SCHEMA app FROM app_domain;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  app._customer_out(app.customers), app._customer_duplicates(uuid, text, uuid),
  app._check_customer_fields(text, text, text)
  TO app_domain;
GRANT EXECUTE ON FUNCTION
  app.create_customer(text, text, text, text, text),
  app.update_customer(uuid, integer, jsonb, text, text)
  TO app_runtime;

-- These functions are owned by app_domain. A GRANT by a user without the owner's rights only warns and grants
-- nothing, so check that every EXECUTE grant above is really in the ACL.
DO $$
DECLARE
  v record;
BEGIN
  FOR v IN
    SELECT x.fn, x.grantee
    FROM (VALUES
      ('app.create_customer(text,text,text,text,text)', 'app_runtime'),
      ('app.update_customer(uuid,integer,jsonb,text,text)', 'app_runtime')
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
REVOKE app_authz, app_bootstrap, app_domain, app_operator FROM CURRENT_USER;

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
