-- M1 identity and tenancy: RLS, grants, membership helpers, constraints.
-- Fixtures (created as superuser): practice A (owner ua, READ_ONLY ur, REVOKED uv), practice B (owner ub).
BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'ua@example.test'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'ur@example.test'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'uv@example.test'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'ub@example.test');
INSERT INTO app.app_users (id, auth_user_id, display_name)
SELECT id, id, email FROM auth.users;
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('0a000000-0000-0000-0000-00000000000a', 'Pandit A', 'pandit-a', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('0b000000-0000-0000-0000-00000000000b', 'Pandit B', 'pandit-b', 'bbbbbbbb-0000-0000-0000-000000000001');
INSERT INTO app.org_members (org_id, user_id, role, status) VALUES
  ('0a000000-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001', 'OWNER', 'ACTIVE'),
  ('0a000000-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000002', 'READ_ONLY', 'ACTIVE'),
  ('0a000000-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000003', 'STAFF', 'REVOKED'),
  ('0b000000-0000-0000-0000-00000000000b', 'bbbbbbbb-0000-0000-0000-000000000001', 'OWNER', 'ACTIVE');
INSERT INTO app.priest_profiles (id, user_id, display_name) VALUES
  ('9a000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'Pandit A'),
  ('9b000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Pandit B');
INSERT INTO app.organization_priests (org_id, priest_profile_id, linked_via) VALUES
  ('0a000000-0000-0000-0000-00000000000a', '9a000000-0000-0000-0000-000000000001', 'BOOTSTRAP'),
  ('0b000000-0000-0000-0000-00000000000b', '9b000000-0000-0000-0000-000000000001', 'BOOTSTRAP');

-- ---------------------------------------------------------------- catalog-level guarantees
SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c WHERE c.relnamespace = 'app'::regnamespace AND c.relkind = 'r' AND NOT c.relrowsecurity),
  'RLS enabled on every app table');
SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c WHERE c.relnamespace = 'app'::regnamespace AND c.relkind = 'r'
    AND c.relname NOT IN ('role_permissions', 'ceremony_types') AND NOT c.relforcerowsecurity),
  'FORCE RLS on every tenant/identity table');
SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
  WHERE c.relnamespace = 'app'::regnamespace AND 0::oid = ANY (p.polroles)),
  'no RLS policy applies to PUBLIC');
SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c WHERE c.relnamespace = 'app'::regnamespace AND c.relkind = 'r'
    AND (has_table_privilege('app_runtime', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
         OR has_any_column_privilege('app_runtime', c.oid, 'INSERT, UPDATE'))),
  'app_runtime has no INSERT/UPDATE/DELETE/TRUNCATE on any app table');

-- ---------------------------------------------------------------- app_runtime cannot write or call internals
SET ROLE app_runtime;
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000001', '0a000000-0000-0000-0000-00000000000a');
SELECT test.throws($$INSERT INTO app.org_members (org_id, user_id, role)
  VALUES ('0b000000-0000-0000-0000-00000000000b', 'aaaaaaaa-0000-0000-0000-000000000001', 'OWNER')$$,
  '42501', 'runtime cannot grant itself memberships');
SELECT test.throws($$INSERT INTO app.organization_priests (org_id, priest_profile_id, linked_via)
  VALUES ('0a000000-0000-0000-0000-00000000000a', '9b000000-0000-0000-0000-000000000001', 'INVITATION')$$,
  '42501', 'runtime cannot link a priest without his consent');
SELECT test.throws($$UPDATE app.organizations SET name = 'x'$$, '42501', 'runtime cannot UPDATE organizations');
SELECT test.throws($$DELETE FROM app.app_users$$, '42501', 'runtime cannot DELETE app_users');
SELECT test.throws($$TRUNCATE app.org_members$$, '42501', 'runtime cannot TRUNCATE org_members');
SELECT test.throws($$INSERT INTO app.ceremony_types (slug, name_en, name_hi, default_duration_min)
  VALUES ('x', 'x', 'x', 60)$$, '42501', 'runtime cannot write the ceremony catalog');
SELECT test.throws($$INSERT INTO app.role_permissions VALUES ('READ_ONLY', 'CUSTOMER_WRITE')$$, '42501',
  'runtime cannot change the permission matrix');
SELECT test.throws($$SELECT app.assert_permission('ORG_READ')$$, '42501', 'runtime cannot call assert_permission');
SELECT test.throws($$SELECT app.current_priest_profile_id()$$, '42501', 'runtime cannot call current_priest_profile_id');
-- current_member_has became runtime-executable in M5 (its audit_log policy uses it); see 90_security_gates.sql.
RESET ROLE;

SET ROLE app_domain;
SELECT test.throws($$INSERT INTO app.org_members (org_id, user_id, role)
  VALUES ('0a000000-0000-0000-0000-00000000000a', 'bbbbbbbb-0000-0000-0000-000000000001', 'ADMIN')$$,
  '42501', 'app_domain has no write grants in M1');
RESET ROLE;

-- ---------------------------------------------------------------- missing context
SET ROLE app_runtime;
SELECT test.ctx(NULL, NULL);
SELECT test.is((SELECT count(*) FROM app.organizations)
             + (SELECT count(*) FROM app.org_members)
             + (SELECT count(*) FROM app.app_users)
             + (SELECT count(*) FROM app.priest_profiles)
             + (SELECT count(*) FROM app.organization_priests), 0::bigint,
  'missing context: zero rows in every tenant/identity table');
SELECT test.is((SELECT count(*) FROM app.ceremony_types), 20::bigint, 'ceremony catalog readable without context');
SELECT test.is((SELECT count(*) FROM app.role_permissions), 64::bigint, 'permission matrix readable without context');

-- ---------------------------------------------------------------- owner A in tenant A
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000001', '0a000000-0000-0000-0000-00000000000a');
SELECT test.is(app.current_member_role(), 'OWNER', 'current_member_role: owner of A');
SELECT test.is((SELECT count(*) FROM app.org_members), 3::bigint, 'owner A sees the 3 memberships of A');
SELECT test.is((SELECT count(*) FROM app.org_members WHERE org_id = '0b000000-0000-0000-0000-00000000000b'), 0::bigint,
  'owner A sees no membership of B');
SELECT test.is((SELECT count(*) FROM app.app_users), 3::bigint, 'owner A sees the 3 users of A');
SELECT test.is((SELECT array_agg(id) FROM app.priest_profiles), ARRAY['9a000000-0000-0000-0000-000000000001'::uuid],
  'owner A sees only the priest profile linked to A');
SELECT test.is((SELECT count(*) FROM app.organization_priests), 1::bigint, 'owner A sees only A''s priest link');

-- ---------------------------------------------------------------- forged tenant header (owner A claims B)
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000001', '0b000000-0000-0000-0000-00000000000b');
SELECT test.ok(app.current_member_role() IS NULL, 'forged tenant: no role');
SELECT test.is((SELECT count(*) FROM app.org_members WHERE org_id = '0b000000-0000-0000-0000-00000000000b')
             + (SELECT count(*) FROM app.organization_priests)
             + (SELECT count(*) FROM app.organizations WHERE id = '0b000000-0000-0000-0000-00000000000b'), 0::bigint,
  'forged tenant header: zero rows of B');
SELECT test.is((SELECT array_agg(id) FROM app.app_users), ARRAY['aaaaaaaa-0000-0000-0000-000000000001'::uuid],
  'forged tenant header: only own user row');

-- ---------------------------------------------------------------- tenant switcher (no tenant selected)
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000001', NULL);
SELECT test.is((SELECT array_agg(id) FROM app.organizations), ARRAY['0a000000-0000-0000-0000-00000000000a'::uuid],
  'tenant switcher lists only own organizations');
SELECT test.is((SELECT count(*) FROM app.organization_priests), 0::bigint, 'no tenant selected -> no tenant data');

-- ---------------------------------------------------------------- READ_ONLY member of A
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000002', '0a000000-0000-0000-0000-00000000000a');
SELECT test.is(app.current_member_role(), 'READ_ONLY', 'current_member_role: READ_ONLY');
SELECT test.is((SELECT count(*) FROM app.org_members) + (SELECT count(*) FROM app.organization_priests), 4::bigint,
  'READ_ONLY member can read tenant data');

-- ---------------------------------------------------------------- revoked member of A
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000003', '0a000000-0000-0000-0000-00000000000a');
SELECT test.ok(app.current_member_role() IS NULL, 'revoked member has no role');
SELECT test.is((SELECT count(*) FROM app.org_members WHERE user_id <> app.current_actor_id())
             + (SELECT count(*) FROM app.organization_priests)
             + (SELECT count(*) FROM app.priest_profiles), 0::bigint,
  'revoked member sees nothing of the tenant');
SELECT test.is((SELECT count(*) FROM app.organizations), 0::bigint, 'revoked member no longer lists the org');
RESET ROLE;

-- ---------------------------------------------------------------- assert_permission (as a command owner would call it)
SET ROLE app_domain;
SELECT test.ctx(NULL, NULL);
SELECT test.throws($$SELECT app.assert_permission('ORG_READ')$$, 'PD401', 'missing context: assert_permission refuses',
  'CONTEXT_MISSING');
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000001', '0b000000-0000-0000-0000-00000000000b');
SELECT test.throws($$SELECT app.assert_permission('ORG_READ')$$, 'PD404',
  'forged tenant header: commands answer 404, not 403', 'NOT_FOUND');
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000003', '0a000000-0000-0000-0000-00000000000a');
SELECT test.throws($$SELECT app.assert_permission('ORG_READ')$$, 'PD404', 'revoked member: 404', 'NOT_FOUND');
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000002', '0a000000-0000-0000-0000-00000000000a');
SELECT test.throws($$SELECT app.assert_permission('CUSTOMER_WRITE')$$, 'PD403', 'READ_ONLY cannot write', 'FORBIDDEN');
SELECT test.lives($$SELECT app.assert_permission('CUSTOMER_READ')$$, 'READ_ONLY may read customers');
SELECT test.ctx('aaaaaaaa-0000-0000-0000-000000000001', '0a000000-0000-0000-0000-00000000000a');
SELECT test.lives($$SELECT app.assert_permission('ORG_SETTINGS')$$, 'OWNER has ORG_SETTINGS');
SELECT test.ok(app.current_member_has('MEMBER_MANAGE') AND NOT app.current_member_has('BOOKING_CONFIRM_OWN'),
  'current_member_has follows the matrix');
SELECT test.throws($$SELECT app.assert_permission('MAKE_COFFEE')$$, 'PD500', 'unknown permission is a bug (PD500)',
  'UNKNOWN_PERMISSION');
SELECT test.is(app.current_priest_profile_id(), '9a000000-0000-0000-0000-000000000001'::uuid,
  'current_priest_profile_id returns the actor''s own profile');
RESET ROLE;

-- ---------------------------------------------------------------- permission matrix (spec §08)
SELECT test.is((SELECT string_agg(role || '=' || n, ',' ORDER BY role) FROM (
  SELECT role, count(*) AS n FROM app.role_permissions GROUP BY role) s),
  'ADMIN=19,OWNER=20,PRIEST=13,READ_ONLY=3,STAFF=9', 'permission counts per role match spec §08');
SELECT test.is((SELECT array_agg(permission ORDER BY permission) FROM app.role_permissions WHERE role = 'READ_ONLY'),
  ARRAY['BOOKING_READ', 'CUSTOMER_READ', 'ORG_READ'], 'READ_ONLY has read permissions only');
SELECT test.ok(NOT EXISTS (SELECT 1 FROM app.role_permissions WHERE role = 'STAFF'
  AND permission IN ('BOOKING_CONFIRM', 'BOOKING_CONFIRM_OWN', 'PAYMENT_REVERSE', 'AUDIT_READ')),
  'STAFF cannot confirm, reverse payments or read the audit log');

-- ---------------------------------------------------------------- constraints
SELECT test.throws($$INSERT INTO app.org_members (org_id, user_id, role)
  VALUES ('0a000000-0000-0000-0000-00000000000a', 'bbbbbbbb-0000-0000-0000-000000000001', 'OWNER')$$,
  '23505', 'one ACTIVE OWNER per organization');
SELECT test.throws($$INSERT INTO app.organizations (name, slug, created_by)
  VALUES ('X', 'Bad Slug', 'aaaaaaaa-0000-0000-0000-000000000001')$$, '23514', 'slug must be lowercase-hyphenated');
SELECT test.throws($$INSERT INTO app.organizations (name, slug, created_by)
  VALUES ('X', 'pandit-a', 'aaaaaaaa-0000-0000-0000-000000000001')$$, '23505', 'slug already taken');
SELECT test.throws($$INSERT INTO app.organizations (name, slug, timezone, created_by)
  VALUES ('X', 'pandit-x', 'IST', 'aaaaaaaa-0000-0000-0000-000000000001')$$, 'PD422',
  'organization time zone must be an IANA name', 'VALIDATION_FAILED');
SELECT test.is((SELECT timezone FROM app.organizations WHERE id = '0a000000-0000-0000-0000-00000000000a'),
  'Asia/Kolkata', 'default organization time zone is Asia/Kolkata');
SELECT test.throws($$UPDATE app.organization_priests SET default_buffer_after_min = 241$$, '23514',
  'travel buffer above 240 minutes rejected');
SELECT test.throws($$INSERT INTO app.priest_profiles (user_id, display_name)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'Second profile')$$, '23505', 'one priest profile per human');
SELECT test.throws($$INSERT INTO app.app_users (id, preferred_locale) VALUES (gen_random_uuid(), 'pa')$$, '23514',
  'preferred_locale is hi or en');
UPDATE app.organizations SET name = 'Pandit A Ji' WHERE id = '0a000000-0000-0000-0000-00000000000a';
SELECT test.is((SELECT version FROM app.organizations WHERE id = '0a000000-0000-0000-0000-00000000000a'), 2,
  'organization version bumps on update');

-- ---------------------------------------------------------------- identity detaches when the auth user is deleted
DELETE FROM auth.users WHERE id = 'aaaaaaaa-0000-0000-0000-000000000003';
SELECT test.ok((SELECT auth_user_id IS NULL FROM app.app_users WHERE id = 'aaaaaaaa-0000-0000-0000-000000000003'),
  'deleting the auth user detaches app_users.auth_user_id (row and history kept)');

ROLLBACK;
