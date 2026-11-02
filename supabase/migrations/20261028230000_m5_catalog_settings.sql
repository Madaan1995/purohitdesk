-- M5 catalog and settings: samagri templates and items, audit_log; commands save_offering, save_samagri_template,
-- update_organization, update_priest_settings (owner app_domain).
-- Spec: docs/spec.md §01 §3, §04 §3–§5/§8, §05 §9–§11, §08 §2, §11 §2/§5. Proposal: docs/proposals/m5.md.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE app.samagri_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES app.organizations (id),
  offering_id uuid NOT NULL,
  version     integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, offering_id),
  UNIQUE (id, org_id),
  FOREIGN KEY (offering_id, org_id) REFERENCES app.offerings (id, org_id)
);
CREATE TRIGGER samagri_templates_bump_version BEFORE UPDATE ON app.samagri_templates
  FOR EACH ROW EXECUTE FUNCTION app.tg_bump_version();

CREATE TABLE app.samagri_template_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  template_id uuid NOT NULL,
  position    integer NOT NULL CHECK (position BETWEEN 1 AND 100),
  name        text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
  quantity    text CHECK (char_length(btrim(quantity)) BETWEEN 1 AND 60),
  provided_by text NOT NULL CHECK (provided_by IN ('FAMILY', 'PRIEST')),
  UNIQUE (template_id, position),
  FOREIGN KEY (template_id, org_id) REFERENCES app.samagri_templates (id, org_id) ON DELETE CASCADE
);

-- Organization-level audit: ids, codes and field names only, never free text (golden rule 8).
CREATE TABLE app.audit_log (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id        uuid NOT NULL REFERENCES app.organizations (id),
  actor_user_id uuid REFERENCES app.app_users (id),
  action        text NOT NULL CHECK (action IN ('ORG_UPDATED', 'BLOCK_CREATED', 'CUSTOMER_ERASED', 'EXPORT')),
  target_id     uuid,
  data          jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(data) = 'object'),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_org_created_idx ON app.audit_log (org_id, created_at);

-- Append-only; only app_maintenance may delete rows older than 12 months (retention, M12).
CREATE FUNCTION app.tg_audit_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' AND current_user = 'app_maintenance' AND OLD.created_at < now() - interval '12 months' THEN
    RETURN OLD;
  END IF;
  PERFORM app.raise_error('PD405', 'APPEND_ONLY', '{"table": "audit_log"}');
  RETURN NULL;
END
$$;
CREATE TRIGGER audit_log_guard BEFORE UPDATE OR DELETE ON app.audit_log
  FOR EACH ROW EXECUTE FUNCTION app.tg_audit_guard();
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON app.audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION app.tg_append_only();

ALTER TABLE app.samagri_templates      ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.samagri_templates      FORCE ROW LEVEL SECURITY;
ALTER TABLE app.samagri_template_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.samagri_template_items FORCE ROW LEVEL SECURITY;
ALTER TABLE app.audit_log              ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.audit_log              FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Policies (T = org_id is the current tenant and the actor is an ACTIVE member)
-- ---------------------------------------------------------------------------
CREATE POLICY samagri_templates_read ON app.samagri_templates
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY samagri_templates_domain_insert ON app.samagri_templates
  FOR INSERT TO app_domain
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY samagri_templates_domain_update ON app.samagri_templates
  FOR UPDATE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

CREATE POLICY samagri_items_read ON app.samagri_template_items
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY samagri_items_domain_insert ON app.samagri_template_items
  FOR INSERT TO app_domain
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY samagri_items_domain_delete ON app.samagri_template_items
  FOR DELETE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

CREATE POLICY audit_log_read ON app.audit_log
  FOR SELECT TO app_runtime
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_has('AUDIT_READ')));
CREATE POLICY audit_log_domain_insert ON app.audit_log
  FOR INSERT TO app_domain
  WITH CHECK (
    org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL
    AND actor_user_id = (SELECT app.current_actor_id()));

CREATE POLICY offerings_domain_insert ON app.offerings
  FOR INSERT TO app_domain
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY offerings_domain_update ON app.offerings
  FOR UPDATE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

CREATE POLICY organizations_domain_update ON app.organizations
  FOR UPDATE TO app_domain
  USING (id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL)
  WITH CHECK (id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

CREATE POLICY organization_priests_domain_update ON app.organization_priests
  FOR UPDATE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Grants (tables). app_runtime: SELECT only.
-- ---------------------------------------------------------------------------
REVOKE ALL ON app.samagri_templates, app.samagri_template_items, app.audit_log FROM PUBLIC;
GRANT SELECT ON app.samagri_templates, app.samagri_template_items, app.audit_log TO app_runtime;
GRANT SELECT, INSERT ON app.samagri_templates TO app_domain;
GRANT UPDATE (updated_at) ON app.samagri_templates TO app_domain;
GRANT SELECT, INSERT, DELETE ON app.samagri_template_items TO app_domain;
GRANT INSERT ON app.audit_log TO app_domain;
GRANT INSERT ON app.offerings TO app_domain;
GRANT UPDATE (name_hi, name_en, duration_min, suggested_dakshina_paise, is_active) ON app.offerings TO app_domain;
GRANT UPDATE (name, timezone) ON app.organizations TO app_domain;
GRANT UPDATE (default_buffer_before_min, default_buffer_after_min) ON app.organization_priests TO app_domain;

-- ---------------------------------------------------------------------------
-- Internal helpers (invoker)
-- ---------------------------------------------------------------------------
-- Typed reads from a JSON request object; a wrong type is PD422 with details.field = p_field. JSON null → NULL.
CREATE FUNCTION app._json_text(p jsonb, p_key text, p_field text) RETURNS text
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v jsonb := p -> p_key;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(v) <> 'string' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', p_field));
  END IF;
  RETURN v #>> '{}';
END
$$;

CREATE FUNCTION app._json_int(p jsonb, p_key text, p_field text) RETURNS bigint
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v jsonb := p -> p_key;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(v) <> 'number' OR (v #>> '{}') !~ '^-?[0-9]{1,15}$' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', p_field));
  END IF;
  RETURN (v #>> '{}')::bigint;
END
$$;

CREATE FUNCTION app._json_bool(p jsonb, p_key text, p_field text) RETURNS boolean
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v jsonb := p -> p_key;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(v) <> 'boolean' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', p_field));
  END IF;
  RETURN (v #>> '{}')::boolean;
END
$$;

CREATE FUNCTION app._audit(p_action text, p_target uuid, p_data jsonb) RETURNS void
LANGUAGE sql
SET search_path = ''
AS $$
  INSERT INTO app.audit_log (org_id, actor_user_id, action, target_id, data)
  VALUES (app.current_tenant_id(), app.current_actor_id(), p_action, p_target, coalesce(p_data, '{}'::jsonb));
$$;

CREATE FUNCTION app._offering_out(o app.offerings) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', o.id, 'ceremony_type_id', o.ceremony_type_id, 'name_hi', o.name_hi, 'name_en', o.name_en,
    'duration_min', o.duration_min, 'suggested_dakshina_paise', o.suggested_dakshina_paise,
    'is_active', o.is_active, 'version', o.version)
$$;

CREATE FUNCTION app._template_out(p_template_id uuid) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', t.id, 'offering_id', t.offering_id, 'version', t.version,
    'items', coalesce((
      SELECT jsonb_agg(jsonb_build_object('position', i.position, 'name', i.name, 'quantity', i.quantity,
                                          'provided_by', i.provided_by) ORDER BY i.position)
      FROM app.samagri_template_items i WHERE i.template_id = t.id), '[]'::jsonb))
  FROM app.samagri_templates t
  WHERE t.id = p_template_id
$$;

CREATE FUNCTION app._organization_out(o app.organizations) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', o.id, 'kind', o.kind, 'name', o.name, 'slug', o.slug, 'timezone', o.timezone,
    'plan', o.plan, 'status', o.status, 'version', o.version)
$$;

-- ---------------------------------------------------------------------------
-- save_offering (CATALOG_WRITE): create (from the catalog or custom) or update with a version check.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.save_offering(
  p_offering_id uuid, p_expected_version integer, p_fields jsonb, p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay  jsonb;
  v_key     text;
  v_o       app.offerings%ROWTYPE;
  v_ct      app.ceremony_types%ROWTYPE;
  v_ct_id   text;
  v_name_hi text;
  v_name_en text;
  v_dur     bigint;
  v_dak     bigint;
  v_active  boolean;
BEGIN
  PERFORM app.assert_permission('CATALOG_WRITE');
  v_replay := app._idem_begin('save_offering', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "body"}');
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_fields) LOOP
    IF v_key = 'ceremony_type_id' AND p_offering_id IS NOT NULL THEN
      PERFORM app.raise_error('PD422', 'IMMUTABLE_FIELD', '{"field": "ceremony_type_id"}');
    ELSIF v_key NOT IN ('ceremony_type_id', 'name_hi', 'name_en', 'duration_min', 'suggested_dakshina_paise',
                        'is_active') THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', v_key));
    END IF;
  END LOOP;

  IF p_offering_id IS NULL THEN
    v_ct_id := app._json_text(p_fields, 'ceremony_type_id', 'ceremony_type_id');
    IF v_ct_id IS NOT NULL THEN
      IF v_ct_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "ceremony_type_id"}');
      END IF;
      SELECT * INTO v_ct FROM app.ceremony_types c WHERE c.id = v_ct_id::uuid;
      IF NOT FOUND THEN
        PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "ceremony_type_id"}');
      END IF;
    END IF;
    v_name_hi := coalesce(btrim(app._json_text(p_fields, 'name_hi', 'name_hi')), v_ct.name_hi);
    v_name_en := coalesce(btrim(app._json_text(p_fields, 'name_en', 'name_en')), v_ct.name_en);
    v_dur     := coalesce(app._json_int(p_fields, 'duration_min', 'duration_min'), v_ct.default_duration_min);
    v_dak     := app._json_int(p_fields, 'suggested_dakshina_paise', 'suggested_dakshina_paise');
    v_active  := coalesce(app._json_bool(p_fields, 'is_active', 'is_active'), true);
  ELSE
    SELECT * INTO v_o FROM app.offerings o
    WHERE o.id = p_offering_id AND o.org_id = app.current_tenant_id()
    FOR UPDATE;
    IF NOT FOUND THEN
      PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "offering"}');
    END IF;
    IF p_expected_version IS NULL OR v_o.version <> p_expected_version THEN
      PERFORM app.raise_error('PD409', 'VERSION_CONFLICT', jsonb_build_object('current_version', v_o.version));
    END IF;
    IF p_fields = '{}'::jsonb THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "body"}');
    END IF;
    v_name_hi := CASE WHEN p_fields ? 'name_hi' THEN btrim(app._json_text(p_fields, 'name_hi', 'name_hi')) ELSE v_o.name_hi END;
    v_name_en := CASE WHEN p_fields ? 'name_en' THEN btrim(app._json_text(p_fields, 'name_en', 'name_en')) ELSE v_o.name_en END;
    v_dur     := CASE WHEN p_fields ? 'duration_min' THEN app._json_int(p_fields, 'duration_min', 'duration_min')
                      ELSE v_o.duration_min END;
    v_dak     := CASE WHEN p_fields ? 'suggested_dakshina_paise'
                      THEN app._json_int(p_fields, 'suggested_dakshina_paise', 'suggested_dakshina_paise')
                      ELSE v_o.suggested_dakshina_paise END;
    v_active  := CASE WHEN p_fields ? 'is_active' THEN app._json_bool(p_fields, 'is_active', 'is_active')
                      ELSE v_o.is_active END;
  END IF;

  IF v_name_hi IS NULL OR char_length(v_name_hi) NOT BETWEEN 1 AND 120 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "name_hi"}');
  END IF;
  IF v_name_en IS NULL OR char_length(v_name_en) NOT BETWEEN 1 AND 120 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "name_en"}');
  END IF;
  IF v_dur IS NULL OR v_dur NOT BETWEEN 15 AND 1440 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "duration_min"}');
  END IF;
  IF v_dak IS NOT NULL AND v_dak NOT BETWEEN 0 AND 100000000000 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "suggested_dakshina_paise"}');
  END IF;
  IF v_active IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "is_active"}');
  END IF;

  IF p_offering_id IS NULL THEN
    INSERT INTO app.offerings (org_id, ceremony_type_id, name_hi, name_en, duration_min, suggested_dakshina_paise, is_active)
    VALUES (app.current_tenant_id(), v_ct.id, v_name_hi, v_name_en, v_dur, v_dak, v_active)
    RETURNING * INTO v_o;
  ELSE
    UPDATE app.offerings o
    SET name_hi = v_name_hi, name_en = v_name_en, duration_min = v_dur, suggested_dakshina_paise = v_dak,
        is_active = v_active
    WHERE o.id = v_o.id
    RETURNING * INTO v_o;
  END IF;

  RETURN app._idem_finish(p_idem_key, app._offering_out(v_o));
END
$$;

-- ---------------------------------------------------------------------------
-- save_samagri_template (CATALOG_WRITE): one template per offering; items replaced as a whole, in array order.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.save_samagri_template(
  p_template_id uuid, p_expected_version integer, p_offering_id uuid, p_items jsonb, p_idem_key text,
  p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay jsonb;
  v_t      app.samagri_templates%ROWTYPE;
  v_item   jsonb;
  v_pos    bigint;
  v_key    text;
  v_name   text;
  v_qty    text;
  v_by     text;
BEGIN
  PERFORM app.assert_permission('CATALOG_WRITE');
  v_replay := app._idem_begin('save_samagri_template', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) > 100 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "items"}');
  END IF;

  IF p_template_id IS NULL THEN
    IF p_offering_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM app.offerings o WHERE o.id = p_offering_id AND o.org_id = app.current_tenant_id()
    ) THEN
      PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "offering"}');
    END IF;
    INSERT INTO app.samagri_templates (org_id, offering_id)
    VALUES (app.current_tenant_id(), p_offering_id)
    RETURNING * INTO v_t;
  ELSE
    SELECT * INTO v_t FROM app.samagri_templates t
    WHERE t.id = p_template_id AND t.org_id = app.current_tenant_id()
    FOR UPDATE;
    IF NOT FOUND THEN
      PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "samagri_template"}');
    END IF;
    IF p_expected_version IS NULL OR v_t.version <> p_expected_version THEN
      PERFORM app.raise_error('PD409', 'VERSION_CONFLICT', jsonb_build_object('current_version', v_t.version));
    END IF;
    IF p_offering_id IS NOT NULL AND p_offering_id <> v_t.offering_id THEN
      PERFORM app.raise_error('PD422', 'IMMUTABLE_FIELD', '{"field": "offering_id"}');
    END IF;
    DELETE FROM app.samagri_template_items i WHERE i.template_id = v_t.id;
    UPDATE app.samagri_templates t SET updated_at = now() WHERE t.id = v_t.id RETURNING * INTO v_t;
  END IF;

  FOR v_item, v_pos IN SELECT e.value, e.ordinality FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', format('items[%s]', v_pos - 1)));
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(v_item) LOOP
      IF v_key NOT IN ('name', 'quantity', 'provided_by') THEN
        PERFORM app.raise_error('PD422', 'VALIDATION_FAILED',
          jsonb_build_object('field', format('items[%s].%s', v_pos - 1, v_key)));
      END IF;
    END LOOP;
    v_name := btrim(app._json_text(v_item, 'name', format('items[%s].name', v_pos - 1)));
    v_qty  := nullif(btrim(app._json_text(v_item, 'quantity', format('items[%s].quantity', v_pos - 1))), '');
    v_by   := app._json_text(v_item, 'provided_by', format('items[%s].provided_by', v_pos - 1));
    IF v_name IS NULL OR char_length(v_name) NOT BETWEEN 1 AND 120 THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', format('items[%s].name', v_pos - 1)));
    END IF;
    IF v_qty IS NOT NULL AND char_length(v_qty) > 60 THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED',
        jsonb_build_object('field', format('items[%s].quantity', v_pos - 1)));
    END IF;
    IF v_by IS NULL OR v_by NOT IN ('FAMILY', 'PRIEST') THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED',
        jsonb_build_object('field', format('items[%s].provided_by', v_pos - 1)));
    END IF;
    INSERT INTO app.samagri_template_items (org_id, template_id, position, name, quantity, provided_by)
    VALUES (v_t.org_id, v_t.id, v_pos, v_name, v_qty, v_by);
  END LOOP;

  RETURN app._idem_finish(p_idem_key, app._template_out(v_t.id));
END
$$;

-- ---------------------------------------------------------------------------
-- update_organization (ORG_SETTINGS): name and time zone; audited as ORG_UPDATED with field names only.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.update_organization(
  p_expected_version integer, p_patch jsonb, p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay  jsonb;
  v_org     app.organizations%ROWTYPE;
  v_key     text;
  v_name    text;
  v_tz      text;
  v_changed text[] := '{}';
BEGIN
  PERFORM app.assert_permission('ORG_SETTINGS');
  v_replay := app._idem_begin('update_organization', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  SELECT * INTO v_org FROM app.organizations o WHERE o.id = app.current_tenant_id() FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "organization"}');
  END IF;
  IF p_expected_version IS NULL OR v_org.version <> p_expected_version THEN
    PERFORM app.raise_error('PD409', 'VERSION_CONFLICT', jsonb_build_object('current_version', v_org.version));
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' OR p_patch = '{}'::jsonb THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "body"}');
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_patch) LOOP
    IF v_key IN ('id', 'kind', 'slug', 'plan', 'status', 'created_by', 'version') THEN
      PERFORM app.raise_error('PD422', 'IMMUTABLE_FIELD', jsonb_build_object('field', v_key));
    ELSIF v_key NOT IN ('name', 'timezone') THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', v_key));
    END IF;
  END LOOP;

  v_name := CASE WHEN p_patch ? 'name' THEN btrim(app._json_text(p_patch, 'name', 'name')) ELSE v_org.name END;
  v_tz   := CASE WHEN p_patch ? 'timezone' THEN app._json_text(p_patch, 'timezone', 'timezone') ELSE v_org.timezone END;
  IF v_name IS NULL OR char_length(v_name) NOT BETWEEN 1 AND 120 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "name"}');
  END IF;
  IF NOT app.is_valid_timezone(v_tz) THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "timezone"}');
  END IF;
  IF v_name IS DISTINCT FROM v_org.name THEN
    v_changed := array_append(v_changed, 'name');
  END IF;
  IF v_tz IS DISTINCT FROM v_org.timezone THEN
    v_changed := array_append(v_changed, 'timezone');
  END IF;

  UPDATE app.organizations o SET name = v_name, timezone = v_tz WHERE o.id = v_org.id RETURNING * INTO v_org;
  IF cardinality(v_changed) > 0 THEN
    PERFORM app._audit('ORG_UPDATED', v_org.id, jsonb_build_object('fields', to_jsonb(v_changed)));
  END IF;

  RETURN app._idem_finish(p_idem_key, app._organization_out(v_org));
END
$$;

-- ---------------------------------------------------------------------------
-- update_priest_settings (ORG_SETTINGS, or the priest himself): default travel buffers of a priest link.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.update_priest_settings(
  p_organization_priest_id uuid, p_default_buffer_before_min integer, p_default_buffer_after_min integer,
  p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay  jsonb;
  v_link    app.organization_priests%ROWTYPE;
  v_profile uuid;
  v_name    text;
BEGIN
  -- Membership first (PD401 / PD404), then ORG_SETTINGS or "this is my own calendar".
  PERFORM app.assert_permission('ORG_READ');
  SELECT op.priest_profile_id INTO v_profile
  FROM app.organization_priests op
  WHERE op.id = p_organization_priest_id AND op.org_id = app.current_tenant_id();
  IF NOT app.current_member_has('ORG_SETTINGS')
     AND (v_profile IS NULL OR v_profile IS DISTINCT FROM app.current_priest_profile_id()) THEN
    PERFORM app.raise_error('PD403', 'FORBIDDEN', '{"permission": "ORG_SETTINGS"}');
  END IF;

  v_replay := app._idem_begin('update_priest_settings', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  SELECT * INTO v_link FROM app.organization_priests op
  WHERE op.id = p_organization_priest_id AND op.org_id = app.current_tenant_id()
  FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "priest"}');
  END IF;
  IF p_default_buffer_before_min IS NOT NULL AND p_default_buffer_before_min NOT BETWEEN 0 AND 240 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "default_buffer_before_min"}');
  END IF;
  IF p_default_buffer_after_min IS NOT NULL AND p_default_buffer_after_min NOT BETWEEN 0 AND 240 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "default_buffer_after_min"}');
  END IF;

  UPDATE app.organization_priests op
  SET default_buffer_before_min = coalesce(p_default_buffer_before_min, op.default_buffer_before_min),
      default_buffer_after_min  = coalesce(p_default_buffer_after_min, op.default_buffer_after_min)
  WHERE op.id = v_link.id
  RETURNING * INTO v_link;
  SELECT p.display_name INTO v_name FROM app.priest_profiles p WHERE p.id = v_link.priest_profile_id;

  RETURN app._idem_finish(p_idem_key, jsonb_build_object(
    'id', v_link.id, 'priest_profile_id', v_link.priest_profile_id, 'display_name', v_name,
    'default_buffer_before_min', v_link.default_buffer_before_min,
    'default_buffer_after_min', v_link.default_buffer_after_min));
END
$$;

-- ---------------------------------------------------------------------------
-- Ownership hand-over and EXECUTE grants.
-- The migration user is a member of the function-owning roles only until the end of this file: the hand-over, the
-- grant on app_authz's current_member_has and the schema-wide REVOKE ... FROM PUBLIC need the owners' rights (spec U1).
-- ---------------------------------------------------------------------------
GRANT app_authz, app_bootstrap, app_domain, app_operator TO CURRENT_USER;

GRANT CREATE ON SCHEMA app TO app_domain;
ALTER FUNCTION app.save_offering(uuid, integer, jsonb, text, text) OWNER TO app_domain;
ALTER FUNCTION app.save_samagri_template(uuid, integer, uuid, jsonb, text, text) OWNER TO app_domain;
ALTER FUNCTION app.update_organization(integer, jsonb, text, text) OWNER TO app_domain;
ALTER FUNCTION app.update_priest_settings(uuid, integer, integer, text, text) OWNER TO app_domain;
REVOKE CREATE ON SCHEMA app FROM app_domain;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  app._json_text(jsonb, text, text), app._json_int(jsonb, text, text), app._json_bool(jsonb, text, text),
  app._audit(text, uuid, jsonb), app._offering_out(app.offerings), app._template_out(uuid),
  app._organization_out(app.organizations)
  TO app_domain;
-- app_runtime's audit_log policy uses current_member_has (spec §04 §7).
GRANT EXECUTE ON FUNCTION app.current_member_has(text) TO app_runtime;
GRANT EXECUTE ON FUNCTION
  app.save_offering(uuid, integer, jsonb, text, text),
  app.save_samagri_template(uuid, integer, uuid, jsonb, text, text),
  app.update_organization(integer, jsonb, text, text),
  app.update_priest_settings(uuid, integer, integer, text, text)
  TO app_runtime;

-- These functions are owned by app_domain and app_authz. A GRANT by a user without the owner's rights only warns and
-- grants nothing, so check that every EXECUTE grant above is really in the ACL.
DO $$
DECLARE
  v record;
BEGIN
  FOR v IN
    SELECT x.fn, x.grantee
    FROM (VALUES
      ('app.current_member_has(text)', 'app_runtime'),
      ('app.save_offering(uuid,integer,jsonb,text,text)', 'app_runtime'),
      ('app.save_samagri_template(uuid,integer,uuid,jsonb,text,text)', 'app_runtime'),
      ('app.update_organization(integer,jsonb,text,text)', 'app_runtime'),
      ('app.update_priest_settings(uuid,integer,integer,text,text)', 'app_runtime')
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
