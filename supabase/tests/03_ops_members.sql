-- M2 operator commands: app.ops_add_member / app.ops_revoke_member (owner app_operator), called as the migration
-- user exactly as supabase/ops/*.sql do on Supabase (as postgres).
-- Fixtures (superuser): practice "Ops Practice" (owner uo), member um, never-signed-in un, deleted ud; owner uo2 has
-- two practices named "Twin".
BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('0e000000-0000-0000-0000-000000000001', 'ops-owner@example.test'),
  ('0e000000-0000-0000-0000-000000000002', 'ops-member@example.test'),
  ('0e000000-0000-0000-0000-000000000003', 'ops-never-signed-in@example.test'),
  ('0e000000-0000-0000-0000-000000000004', 'ops-deleted@example.test'),
  ('0e000000-0000-0000-0000-000000000005', 'ops-owner-2@example.test');
INSERT INTO app.app_users (id, auth_user_id, status) VALUES
  ('0e000000-0000-0000-0000-000000000001', '0e000000-0000-0000-0000-000000000001', 'ACTIVE'),
  ('0e000000-0000-0000-0000-000000000002', '0e000000-0000-0000-0000-000000000002', 'ACTIVE'),
  ('0e000000-0000-0000-0000-000000000004', '0e000000-0000-0000-0000-000000000004', 'DELETED'),
  ('0e000000-0000-0000-0000-000000000005', '0e000000-0000-0000-0000-000000000005', 'ACTIVE');
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('0e000000-0000-0000-0000-0000000000a1', 'Ops Practice', 'ops-practice', '0e000000-0000-0000-0000-000000000001'),
  ('0e000000-0000-0000-0000-0000000000b1', 'Twin', 'twin', '0e000000-0000-0000-0000-000000000005'),
  ('0e000000-0000-0000-0000-0000000000b2', 'Twin', 'twin-2', '0e000000-0000-0000-0000-000000000005');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('0e000000-0000-0000-0000-0000000000a1', '0e000000-0000-0000-0000-000000000001', 'OWNER'),
  ('0e000000-0000-0000-0000-0000000000b1', '0e000000-0000-0000-0000-000000000005', 'OWNER'),
  ('0e000000-0000-0000-0000-0000000000b2', '0e000000-0000-0000-0000-000000000005', 'OWNER');

-- ---------------------------------------------------------------- as the migration user (Supabase: postgres)
SET ROLE pd_migrator;

SELECT test.is(app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
                                  '0e000000-0000-0000-0000-000000000002', 'STAFF'),
  '{"org_id": "0e000000-0000-0000-0000-0000000000a1", "user_id": "0e000000-0000-0000-0000-000000000002",
    "role": "STAFF", "status": "ACTIVE"}'::jsonb,
  'ops_add_member adds the member as STAFF and returns ids, role and status only');
SELECT test.is(app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
                                  '0e000000-0000-0000-0000-000000000002', 'READ_ONLY') ->> 'role', 'READ_ONLY',
  'ops_add_member changes an existing member''s role');

SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000002', 'OWNER')$$, 'PD422', 'ops_add_member never grants OWNER',
  'ROLE_NOT_ALLOWED');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000002', 'PRIEST')$$, 'PD422', 'ops_add_member refuses PRIEST (needs a priest link)',
  'ROLE_NOT_ALLOWED');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000001', 'STAFF')$$, 'PD422', 'ops_add_member refuses to touch the OWNER',
  'OWNER_UNTOUCHABLE');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000003', 'STAFF')$$, 'PD404',
  'ops_add_member refuses someone who never signed in', 'MEMBER_NOT_SIGNED_IN');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  NULL, 'STAFF')$$, 'PD404', 'ops_add_member refuses an e-mail that matched no auth user', 'MEMBER_NOT_SIGNED_IN');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000004', 'STAFF')$$, 'PD404', 'ops_add_member refuses a deleted identity',
  'MEMBER_NOT_SIGNED_IN');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Other Practice',
  '0e000000-0000-0000-0000-000000000002', 'STAFF')$$, 'PD404', 'ops_add_member: unknown practice name',
  'PRACTICE_NOT_FOUND');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000002', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000002', 'STAFF')$$, 'PD404',
  'ops_add_member: the practice is found only through its OWNER', 'PRACTICE_NOT_FOUND');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000005', 'Twin',
  '0e000000-0000-0000-0000-000000000002', 'STAFF')$$, 'PD422',
  'ops_add_member: an owner with two practices of that name must be told', 'PRACTICE_NAME_AMBIGUOUS');

SELECT test.throws($$SELECT app.ops_revoke_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000001')$$, 'PD422', 'ops_revoke_member never revokes the OWNER',
  'OWNER_UNTOUCHABLE');
SELECT test.is(app.ops_revoke_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
                                     '0e000000-0000-0000-0000-000000000002') ->> 'status', 'REVOKED',
  'ops_revoke_member revokes the member');
SELECT test.throws($$SELECT app.ops_revoke_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000002')$$, 'PD404', 'revoking twice is reported', 'NOT_AN_ACTIVE_MEMBER');
RESET ROLE;

SELECT test.is((SELECT role || ':' || status FROM app.org_members
                WHERE user_id = '0e000000-0000-0000-0000-000000000001'), 'OWNER:ACTIVE',
  'after all of the above the OWNER is still the ACTIVE OWNER');
SELECT test.ok((SELECT bool_and(relforcerowsecurity) FROM pg_class
                WHERE relnamespace = 'app'::regnamespace AND relname IN ('organizations', 'org_members', 'app_users')),
  'row-level security stays forced (the operator commands never lift it)');

-- The revoked member's next request sees nothing of the practice.
SET ROLE app_runtime;
SELECT test.ctx('0e000000-0000-0000-0000-000000000002', '0e000000-0000-0000-0000-0000000000a1');
SELECT test.ok(app.current_member_role() IS NULL AND (SELECT count(*) FROM app.organizations) = 0,
  'a revoked member loses access on the next request');
RESET ROLE;

SET ROLE pd_migrator;
SELECT test.is(app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
                                  '0e000000-0000-0000-0000-000000000002', 'STAFF') ->> 'status', 'ACTIVE',
  'ops_add_member re-activates a revoked member');
RESET ROLE;

-- ---------------------------------------------------------------- nobody else can run them
SET ROLE app_runtime;
SELECT test.ctx('0e000000-0000-0000-0000-000000000001', '0e000000-0000-0000-0000-0000000000a1');
SELECT test.throws($$SELECT app.ops_add_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000002', 'ADMIN')$$, '42501', 'app_runtime cannot execute ops_add_member');
SELECT test.throws($$SELECT app.ops_revoke_member('0e000000-0000-0000-0000-000000000001', 'Ops Practice',
  '0e000000-0000-0000-0000-000000000002')$$, '42501', 'app_runtime cannot execute ops_revoke_member');
RESET ROLE;

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_roles r, (VALUES ('app.ops_add_member(uuid,text,uuid,text)'),
                                    ('app.ops_revoke_member(uuid,text,uuid)')) AS f (fn)
  WHERE r.rolname LIKE 'app\_%' AND r.rolname <> 'app_operator'
    AND has_function_privilege(r.oid, f.fn::regprocedure, 'EXECUTE')),
  'no application role (other than the owner) can execute the operator commands');

-- ---------------------------------------------------------------- app_operator's own policies admit no OWNER row
SET ROLE app_operator;
DO $$
DECLARE
  n bigint;
BEGIN
  UPDATE app.org_members SET role = 'STAFF' WHERE role = 'OWNER';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM test.is(n, 0::bigint, 'app_operator cannot update an OWNER membership (RLS)');
END $$;
SELECT test.throws($$INSERT INTO app.org_members (org_id, user_id, role)
  VALUES ('0e000000-0000-0000-0000-0000000000b1', '0e000000-0000-0000-0000-000000000002', 'OWNER')$$, '42501',
  'app_operator cannot insert an OWNER membership (RLS)');
SELECT test.throws($$DELETE FROM app.org_members$$, '42501', 'app_operator cannot delete memberships');
SELECT test.throws($$SELECT display_name FROM app.app_users$$, '42501', 'app_operator cannot read names');
RESET ROLE;

ROLLBACK;
