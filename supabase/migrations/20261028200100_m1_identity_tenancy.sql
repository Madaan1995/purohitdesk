-- M1 identity and tenancy: role_permissions, app_users, organizations, org_members, priest_profiles,
-- organization_priests, ceremony_types; RLS, policies and grants; membership helpers owned by app_authz.
-- Spec: docs/spec.md §04 §3–§8, §08 §2. Proposal: docs/proposals/m1.md.
-- No write grants in M1: write policies arrive with the command functions that need them (M2).

-- ---------------------------------------------------------------------------
-- role_permissions: the RBAC matrix (spec §08 §2). Global reference table.
-- ---------------------------------------------------------------------------
CREATE TABLE app.role_permissions (
  role       text NOT NULL CHECK (role IN ('OWNER', 'ADMIN', 'PRIEST', 'STAFF', 'READ_ONLY')),
  permission text NOT NULL CHECK (permission IN (
    'ORG_READ', 'ORG_SETTINGS', 'MEMBER_MANAGE', 'AUDIT_READ', 'EXPORT_DATA',
    'CUSTOMER_READ', 'CUSTOMER_WRITE', 'CUSTOMER_ERASE', 'CATALOG_WRITE',
    'BOOKING_READ', 'BOOKING_CREATE', 'BOOKING_EDIT',
    'BOOKING_CONFIRM', 'BOOKING_CONFIRM_OWN', 'BOOKING_CANCEL', 'BOOKING_CANCEL_OWN',
    'BOOKING_COMPLETE', 'BOOKING_COMPLETE_OWN', 'BLOCK_MANAGE', 'BLOCK_MANAGE_OWN',
    'PAYMENT_RECORD', 'PAYMENT_REVERSE', 'SHARE_MESSAGE', 'VOICE_USE')),
  PRIMARY KEY (role, permission)
);

INSERT INTO app.role_permissions (role, permission)
SELECT r.role, p.permission
FROM (VALUES
  ('ORG_READ',             true,  true,  true,  true,  true),
  ('ORG_SETTINGS',         true,  true,  false, false, false),
  ('MEMBER_MANAGE',        true,  false, false, false, false),
  ('AUDIT_READ',           true,  true,  false, false, false),
  ('EXPORT_DATA',          true,  true,  false, false, false),
  ('CUSTOMER_READ',        true,  true,  true,  true,  true),
  ('CUSTOMER_WRITE',       true,  true,  true,  true,  false),
  ('CUSTOMER_ERASE',       true,  true,  false, false, false),
  ('CATALOG_WRITE',        true,  true,  false, false, false),
  ('BOOKING_READ',         true,  true,  true,  true,  true),
  ('BOOKING_CREATE',       true,  true,  true,  true,  false),
  ('BOOKING_EDIT',         true,  true,  true,  true,  false),
  ('BOOKING_CONFIRM',      true,  true,  false, false, false),
  ('BOOKING_CONFIRM_OWN',  false, false, true,  false, false),
  ('BOOKING_CANCEL',       true,  true,  false, false, false),
  ('BOOKING_CANCEL_OWN',   false, false, true,  false, false),
  ('BOOKING_COMPLETE',     true,  true,  false, false, false),
  ('BOOKING_COMPLETE_OWN', false, false, true,  false, false),
  ('BLOCK_MANAGE',         true,  true,  false, false, false),
  ('BLOCK_MANAGE_OWN',     false, false, true,  false, false),
  ('PAYMENT_RECORD',       true,  true,  true,  true,  false),
  ('PAYMENT_REVERSE',      true,  true,  false, false, false),
  ('SHARE_MESSAGE',        true,  true,  true,  true,  false),
  ('VOICE_USE',            true,  true,  true,  true,  false)
) AS p (permission, owner, admin, priest, staff, read_only)
CROSS JOIN LATERAL (VALUES
  ('OWNER', p.owner), ('ADMIN', p.admin), ('PRIEST', p.priest), ('STAFF', p.staff), ('READ_ONLY', p.read_only)
) AS r (role, granted)
WHERE r.granted;

-- ---------------------------------------------------------------------------
-- app_users: one row per human; id = Supabase auth uid at creation, identity detachable.
-- ---------------------------------------------------------------------------
CREATE TABLE app.app_users (
  id               uuid PRIMARY KEY,
  auth_user_id     uuid UNIQUE REFERENCES auth.users (id) ON DELETE SET NULL,
  display_name     text CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 120),
  preferred_locale text NOT NULL DEFAULT 'hi' CHECK (preferred_locale IN ('hi', 'en')),
  status           text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'DELETED')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- organizations: the tenant.
-- ---------------------------------------------------------------------------
CREATE TABLE app.organizations (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind       text NOT NULL DEFAULT 'SOLO' CHECK (kind IN ('SOLO', 'COLLECTIVE')),
  name       text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
  slug       text NOT NULL UNIQUE
             CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(slug) <= 80),
  timezone   text NOT NULL DEFAULT 'Asia/Kolkata',
  plan       text NOT NULL DEFAULT 'PILOT' CHECK (plan IN ('PILOT')),
  status     text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CLOSED')),
  created_by uuid NOT NULL REFERENCES app.app_users (id),
  version    integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- org_members: membership with role; one ACTIVE OWNER per organization.
-- ---------------------------------------------------------------------------
CREATE TABLE app.org_members (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL REFERENCES app.organizations (id),
  user_id    uuid NOT NULL REFERENCES app.app_users (id),
  role       text NOT NULL CHECK (role IN ('OWNER', 'ADMIN', 'PRIEST', 'STAFF', 'READ_ONLY')),
  status     text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('INVITED', 'ACTIVE', 'REVOKED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, user_id),
  UNIQUE (id, org_id)
);
CREATE UNIQUE INDEX org_members_one_active_owner ON app.org_members (org_id)
  WHERE role = 'OWNER' AND status = 'ACTIVE';
CREATE INDEX org_members_active_user_idx ON app.org_members (user_id) WHERE status = 'ACTIVE';

-- ---------------------------------------------------------------------------
-- priest_profiles: global, one per human (the exclusion key for busy time from M6).
-- ---------------------------------------------------------------------------
CREATE TABLE app.priest_profiles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL UNIQUE REFERENCES app.app_users (id),
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 120),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- organization_priests: consented link organization <-> priest profile.
-- ---------------------------------------------------------------------------
CREATE TABLE app.organization_priests (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                    uuid NOT NULL REFERENCES app.organizations (id),
  priest_profile_id         uuid NOT NULL REFERENCES app.priest_profiles (id),
  linked_via                text NOT NULL CHECK (linked_via IN ('BOOTSTRAP', 'INVITATION')),
  default_buffer_before_min integer NOT NULL DEFAULT 30 CHECK (default_buffer_before_min BETWEEN 0 AND 240),
  default_buffer_after_min  integer NOT NULL DEFAULT 30 CHECK (default_buffer_after_min BETWEEN 0 AND 240),
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, priest_profile_id),
  UNIQUE (org_id, id, priest_profile_id),
  UNIQUE (id, org_id)
);
CREATE INDEX organization_priests_profile_idx ON app.organization_priests (priest_profile_id);

-- ---------------------------------------------------------------------------
-- ceremony_types: global catalog, read-only for the API; filled by supabase/seed/ceremony_types.sql.
-- ---------------------------------------------------------------------------
CREATE TABLE app.ceremony_types (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                 text NOT NULL UNIQUE
                       CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(slug) <= 80),
  name_en              text NOT NULL CHECK (char_length(btrim(name_en)) BETWEEN 1 AND 120),
  name_hi              text NOT NULL CHECK (char_length(btrim(name_hi)) BETWEEN 1 AND 120),
  name_pa              text CHECK (char_length(btrim(name_pa)) BETWEEN 1 AND 120),
  default_duration_min integer NOT NULL CHECK (default_duration_min BETWEEN 15 AND 1440),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
CREATE TRIGGER organizations_bump_version BEFORE UPDATE ON app.organizations
  FOR EACH ROW EXECUTE FUNCTION app.tg_bump_version();
CREATE TRIGGER organizations_validate_timezone BEFORE INSERT OR UPDATE OF timezone ON app.organizations
  FOR EACH ROW EXECUTE FUNCTION app.tg_validate_timezone('timezone');
CREATE TRIGGER app_users_touch BEFORE UPDATE ON app.app_users
  FOR EACH ROW EXECUTE FUNCTION app.tg_touch_updated_at();
CREATE TRIGGER org_members_touch BEFORE UPDATE ON app.org_members
  FOR EACH ROW EXECUTE FUNCTION app.tg_touch_updated_at();
CREATE TRIGGER priest_profiles_touch BEFORE UPDATE ON app.priest_profiles
  FOR EACH ROW EXECUTE FUNCTION app.tg_touch_updated_at();
CREATE TRIGGER organization_priests_touch BEFORE UPDATE ON app.organization_priests
  FOR EACH ROW EXECUTE FUNCTION app.tg_touch_updated_at();
CREATE TRIGGER ceremony_types_touch BEFORE UPDATE ON app.ceremony_types
  FOR EACH ROW EXECUTE FUNCTION app.tg_touch_updated_at();

-- ---------------------------------------------------------------------------
-- Membership helpers (owner app_authz). They read only the actor's own memberships and profile.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.current_member_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT m.role
  FROM app.org_members m
  WHERE m.org_id = app.current_tenant_id()
    AND m.user_id = app.current_actor_id()
    AND m.status = 'ACTIVE'
$$;

CREATE FUNCTION app.current_member_has(p_permission text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM app.role_permissions rp
    WHERE rp.role = app.current_member_role() AND rp.permission = p_permission)
$$;

CREATE FUNCTION app.is_active_member_of(p_org uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM app.org_members m
    WHERE m.org_id = p_org AND m.user_id = app.current_actor_id() AND m.status = 'ACTIVE')
$$;

CREATE FUNCTION app.current_priest_profile_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.id FROM app.priest_profiles p WHERE p.user_id = app.current_actor_id()
$$;

CREATE FUNCTION app.assert_permission(p_permission text) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text;
BEGIN
  IF app.current_actor_id() IS NULL OR app.current_tenant_id() IS NULL THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.role_permissions rp WHERE rp.permission = p_permission) THEN
    PERFORM app.raise_error('PD500', 'UNKNOWN_PERMISSION', pg_catalog.jsonb_build_object('permission', p_permission));
  END IF;
  v_role := app.current_member_role();
  IF v_role IS NULL THEN
    -- Not a member of the requested tenant: answer 404, never 403 (spec §08 §2).
    PERFORM app.raise_error('PD404', 'NOT_FOUND', pg_catalog.jsonb_build_object('resource', 'organization'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM app.role_permissions rp WHERE rp.role = v_role AND rp.permission = p_permission
  ) THEN
    PERFORM app.raise_error('PD403', 'FORBIDDEN', pg_catalog.jsonb_build_object('permission', p_permission));
  END IF;
END
$$;

GRANT CREATE ON SCHEMA app TO app_authz;
ALTER FUNCTION app.current_member_role() OWNER TO app_authz;
ALTER FUNCTION app.current_member_has(text) OWNER TO app_authz;
ALTER FUNCTION app.is_active_member_of(uuid) OWNER TO app_authz;
ALTER FUNCTION app.current_priest_profile_id() OWNER TO app_authz;
ALTER FUNCTION app.assert_permission(text) OWNER TO app_authz;
REVOKE CREATE ON SCHEMA app FROM app_authz;

-- ---------------------------------------------------------------------------
-- Row-level security. Reference tables: ENABLE only (read-only policies). Tenant/identity: ENABLE + FORCE.
-- Tenant predicate: org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL
-- ---------------------------------------------------------------------------
ALTER TABLE app.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.ceremony_types   ENABLE ROW LEVEL SECURITY;

ALTER TABLE app.app_users            ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.app_users            FORCE ROW LEVEL SECURITY;
ALTER TABLE app.organizations        ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.organizations        FORCE ROW LEVEL SECURITY;
ALTER TABLE app.org_members          ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.org_members          FORCE ROW LEVEL SECURITY;
ALTER TABLE app.priest_profiles      ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.priest_profiles      FORCE ROW LEVEL SECURITY;
ALTER TABLE app.organization_priests ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.organization_priests FORCE ROW LEVEL SECURITY;

CREATE POLICY role_permissions_read ON app.role_permissions
  FOR SELECT TO app_runtime, app_domain, app_authz
  USING (true);

CREATE POLICY ceremony_types_read ON app.ceremony_types
  FOR SELECT TO app_runtime, app_domain
  USING (true);

-- Tenant switcher: an organization is visible to its ACTIVE members, without a selected tenant.
CREATE POLICY organizations_member_read ON app.organizations
  FOR SELECT TO app_runtime, app_domain
  USING (app.is_active_member_of(id));

CREATE POLICY org_members_read ON app.org_members
  FOR SELECT TO app_runtime, app_domain
  USING (
    user_id = (SELECT app.current_actor_id())
    OR (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL));

CREATE POLICY org_members_authz_own ON app.org_members
  FOR SELECT TO app_authz
  USING (user_id = (SELECT app.current_actor_id()));

-- Own row anywhere, plus members of the current tenant (the subquery is itself under org_members RLS).
CREATE POLICY app_users_read ON app.app_users
  FOR SELECT TO app_runtime, app_domain
  USING (
    id = (SELECT app.current_actor_id())
    OR id IN (SELECT m.user_id FROM app.org_members m WHERE m.org_id = (SELECT app.current_tenant_id())));

-- Own profile anywhere, plus profiles linked to the current tenant.
CREATE POLICY priest_profiles_read ON app.priest_profiles
  FOR SELECT TO app_runtime, app_domain
  USING (
    user_id = (SELECT app.current_actor_id())
    OR id IN (
      SELECT op.priest_profile_id FROM app.organization_priests op
      WHERE op.org_id = (SELECT app.current_tenant_id())));

CREATE POLICY priest_profiles_authz_own ON app.priest_profiles
  FOR SELECT TO app_authz
  USING (user_id = (SELECT app.current_actor_id()));

CREATE POLICY organization_priests_read ON app.organization_priests
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Grants: SELECT only. app_runtime never gets INSERT/UPDATE/DELETE/TRUNCATE.
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA app FROM PUBLIC;

GRANT SELECT ON app.role_permissions, app.ceremony_types, app.organizations, app.org_members,
                app.app_users, app.priest_profiles, app.organization_priests
  TO app_runtime, app_domain;
GRANT SELECT ON app.role_permissions, app.org_members, app.priest_profiles TO app_authz;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;

-- Used by app_runtime's own policies (spec §04 §7; defect #9: nothing else).
GRANT EXECUTE ON FUNCTION app.current_member_role(), app.is_active_member_of(uuid) TO app_runtime;
GRANT EXECUTE ON FUNCTION
  app.current_member_role(), app.current_member_has(text), app.is_active_member_of(uuid),
  app.current_priest_profile_id(), app.assert_permission(text)
  TO app_domain, app_bootstrap, app_freebusy, app_maintenance;

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
