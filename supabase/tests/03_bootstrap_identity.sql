-- M2: first login, onboarding (bootstrap_practice), idempotency, profile updates.
-- Every command is called as app_runtime, exactly as the API does.
BEGIN;

-- Fixtures (superuser): Supabase auth users only; app users are created by ensure_current_user.
-- raw_user_meta_data differs from the name the API passes in: it must never be read.
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('c1000000-0000-0000-0000-000000000001', 'ramesh@example.test', '{"full_name": "Not Read From auth.users"}'),
  ('c2000000-0000-0000-0000-000000000002', 'second@example.test', '{}'),
  ('c3000000-0000-0000-0000-000000000003', 'third@example.test', '{}'),
  ('c4000000-0000-0000-0000-000000000004', 'fourth@example.test', '{}'),
  ('c5000000-0000-0000-0000-000000000005', 'fifth@example.test', '{}'),
  ('cd000000-0000-0000-0000-00000000000d', 'detached@example.test', '{}');
INSERT INTO app.app_users (id, auth_user_id) VALUES
  ('cd000000-0000-0000-0000-00000000000d', 'cd000000-0000-0000-0000-00000000000d');
DELETE FROM auth.users WHERE id = 'cd000000-0000-0000-0000-00000000000d';  -- identity detached

SET ROLE app_runtime;

-- ---------------------------------------------------------------- first login
SELECT test.ctx('c1000000-0000-0000-0000-000000000001');
SELECT app.ensure_current_user('en', '  Ramesh Sharma  ') AS u1 \gset
SELECT test.is(:'u1'::jsonb, '{"id": "c1000000-0000-0000-0000-000000000001", "display_name": "Ramesh Sharma",
  "preferred_locale": "en"}'::jsonb,
  'first login creates app user (name passed in from the verified token, trimmed; chosen locale)');
SELECT test.is(app.ensure_current_user('hi', 'Someone Else'),
  '{"id": "c1000000-0000-0000-0000-000000000001", "display_name": "Ramesh Sharma", "preferred_locale": "en"}'::jsonb,
  'second login returns the existing user unchanged (name and locale)');

-- The display name is untrusted text: cleaned, capped, and optional.
SELECT test.ctx('c3000000-0000-0000-0000-000000000003');
SELECT test.is(app.ensure_current_user(NULL, E'Ram\n\tesh\u202E  Sharma\u0007') ->> 'display_name', 'Ram esh Sharma',
  'control and bidi-override characters in the token name are replaced, spaces collapsed');
SELECT test.ctx('c5000000-0000-0000-0000-000000000005');
SELECT test.is(app.ensure_current_user(NULL, E'\u0915\u094D\u200D\u0937\u092E\u093E') ->> 'display_name',
  E'\u0915\u094D\u200D\u0937\u092E\u093E', 'a Devanagari name keeps its zero-width joiner');
SELECT test.ctx('c4000000-0000-0000-0000-000000000004');
SELECT test.is(char_length(app.ensure_current_user(NULL, repeat('x', 500)) ->> 'display_name'), 120,
  'a long token name is cut to 120 characters');
SELECT test.ctx('c2000000-0000-0000-0000-000000000002');
SELECT test.is(app.ensure_current_user(NULL, E' \n ') -> 'display_name', 'null'::jsonb,
  'a blank token name is stored as no name');

SELECT test.ctx('c9000000-0000-0000-0000-000000000009');
SELECT test.throws($$SELECT app.ensure_current_user(NULL, 'Ghost')$$, 'PD401',
  'an actor that is not a Supabase auth user cannot sign in (foreign key, no read of auth.users)',
  'CONTEXT_MISSING');
SELECT test.throws($$SELECT app.bootstrap_practice('X', NULL, 'key-ghost-01', repeat('a', 64))$$, 'PD401',
  'an actor that is not a Supabase auth user cannot bootstrap', 'CONTEXT_MISSING');
SELECT test.ctx(NULL);
SELECT test.throws($$SELECT app.ensure_current_user(NULL, NULL)$$, 'PD401', 'missing actor: refused',
  'CONTEXT_MISSING');
SELECT test.ctx('cd000000-0000-0000-0000-00000000000d');
SELECT test.throws($$SELECT app.ensure_current_user(NULL, NULL)$$, 'PD401', 'deleted identity cannot sign back in',
  'CONTEXT_MISSING');

-- ---------------------------------------------------------------- onboarding
SELECT test.ctx('c1000000-0000-0000-0000-000000000001');
SELECT app.bootstrap_practice('Sharma Ji Pooja',
  (SELECT array_agg(id ORDER BY slug) FROM app.ceremony_types WHERE slug IN ('havan', 'vivah', 'mundan')),
  'onboard-key-0001', repeat('a', 64)) AS r1 \gset
SELECT test.ok((:'r1'::jsonb ->> 'role') = 'OWNER' AND (:'r1'::jsonb ->> 'offering_count')::int = 3
  AND (:'r1'::jsonb ->> 'idempotent_replay')::boolean = false
  AND (:'r1'::jsonb -> 'organization' ->> 'timezone') = 'Asia/Kolkata',
  'bootstrap creates practice + the chosen offerings (at least 1) as app_runtime (no BYPASSRLS anywhere)');
SELECT (:'r1'::jsonb -> 'organization' ->> 'id') AS org1 \gset

SELECT test.is(app.bootstrap_practice('Sharma Ji Pooja',
  (SELECT array_agg(id ORDER BY slug) FROM app.ceremony_types WHERE slug IN ('havan', 'vivah', 'mundan')),
  'onboard-key-0001', repeat('a', 64)) - 'idempotent_replay', :'r1'::jsonb - 'idempotent_replay',
  'same Idempotency-Key + same body replays the same org');
SELECT test.is((app.bootstrap_practice('Sharma Ji Pooja',
  (SELECT array_agg(id ORDER BY slug) FROM app.ceremony_types WHERE slug IN ('havan', 'vivah', 'mundan')),
  'onboard-key-0001', repeat('a', 64)) ->> 'idempotent_replay')::boolean, true, 'replay is flagged');
SELECT test.throws($$SELECT app.bootstrap_practice('Another name',
  (SELECT array_agg(id) FROM app.ceremony_types WHERE slug = 'havan'), 'onboard-key-0001', repeat('b', 64))$$,
  'PD412', 'same Idempotency-Key + different body is rejected', 'IDEMPOTENCY_REUSE');
SELECT test.is((SELECT count(*) FROM app.organizations), 1::bigint, 'tenant switcher lists exactly one practice');
SELECT test.is((SELECT slug FROM app.organizations WHERE id = :'org1'), 'sharma-ji-pooja', 'slug generated from the name');

SELECT test.ctx('c1000000-0000-0000-0000-000000000001', :'org1');
SELECT test.is(app.current_member_role(), 'OWNER', 'the creator is the ACTIVE OWNER');
SELECT test.is((SELECT count(*) FROM app.offerings WHERE is_active), 3::bigint, 'the chosen offerings are visible');
SELECT test.is((SELECT string_agg(name_en || '/' || name_hi || '/' || duration_min, ',' ORDER BY name_en)
                FROM app.offerings), 'Havan/हवन/90,Mundan Sanskar/मुंडन संस्कार/90,Vivah/विवाह/360',
  'offerings copy both names and the default duration');
SELECT test.is((SELECT linked_via || ':' || default_buffer_before_min || '/' || default_buffer_after_min
                FROM app.organization_priests), 'BOOTSTRAP:30/30', 'own priest linked via BOOTSTRAP with 30/30 buffers');
SELECT test.is((SELECT display_name FROM app.priest_profiles), 'Ramesh Sharma', 'priest profile named after the user');
SELECT test.throws($$SELECT app.bootstrap_practice('Second', (SELECT array_agg(id) FROM app.ceremony_types
  WHERE slug = 'havan'), 'onboard-key-0002', repeat('c', 64))$$, 'PD422',
  'bootstrap refuses to run inside a tenant context', 'VALIDATION_FAILED');

SELECT test.ctx('c1000000-0000-0000-0000-000000000001');
SELECT app.bootstrap_practice('Sharma Ji Pooja', (SELECT array_agg(id) FROM app.ceremony_types WHERE slug = 'havan'),
  'onboard-key-0003', repeat('d', 64)) -> 'organization' ->> 'id' AS org2 \gset
SELECT test.ok((SELECT slug ~ '^sharma-ji-pooja-[0-9a-f]{6}$' FROM app.organizations WHERE id = :'org2'),
  'a taken slug gets a random suffix instead of failing');
SELECT app.bootstrap_practice('शर्मा जी पूजा', (SELECT array_agg(id) FROM app.ceremony_types WHERE slug = 'havan'),
  'onboard-key-0004', repeat('e', 64)) -> 'organization' ->> 'id' AS org3 \gset
SELECT test.ok((SELECT slug ~ '^practice' AND name = 'शर्मा जी पूजा' FROM app.organizations WHERE id = :'org3'),
  'a Devanagari name keeps its name and gets a practice-… slug');
SELECT test.throws($$SELECT app.bootstrap_practice('Fourth', (SELECT array_agg(id) FROM app.ceremony_types
  WHERE slug = 'havan'), 'onboard-key-0005', repeat('f', 64))$$, 'PD429', 'organization quota per user',
  'QUOTA_EXCEEDED');
SELECT test.is((SELECT count(*) FROM app.organizations), 3::bigint, 'tenant switcher lists the three practices');
RESET ROLE;
SELECT test.is((SELECT count(*) FROM app.priest_profiles WHERE user_id = 'c1000000-0000-0000-0000-000000000001'),
  1::bigint, 'one human keeps ONE global priest profile across his practices');
SELECT test.is((SELECT count(*) FROM app.organization_priests op JOIN app.priest_profiles p ON p.id = op.priest_profile_id
                WHERE p.user_id = 'c1000000-0000-0000-0000-000000000001'), 3::bigint,
  'that profile is linked to each of his practices');
SELECT test.is((SELECT count(*) FROM app.org_sequences s JOIN app.organizations o ON o.id = s.org_id
                WHERE o.created_by = 'c1000000-0000-0000-0000-000000000001'), 3::bigint,
  'each practice gets a booking-number sequence');
SET ROLE app_runtime;

-- ---------------------------------------------------------------- validation (second user)
SELECT test.ctx('c2000000-0000-0000-0000-000000000002');
SELECT test.is(app.ensure_current_user(NULL, NULL) ->> 'preferred_locale', 'hi', 'default language is Hindi');
SELECT test.throws($$SELECT app.bootstrap_practice('   ', (SELECT array_agg(id) FROM app.ceremony_types
  WHERE slug = 'havan'), 'validate-key-01', repeat('a', 64))$$, 'PD422', 'blank practice name rejected',
  'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.bootstrap_practice('P', ARRAY[]::uuid[], 'validate-key-02', repeat('a', 64))$$,
  'PD422', 'at least one ceremony is required', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.bootstrap_practice('P', ARRAY[gen_random_uuid()], 'validate-key-03',
  repeat('a', 64))$$, 'PD422', 'unknown ceremony rejected', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.bootstrap_practice('P', (SELECT array[id, id] FROM app.ceremony_types
  WHERE slug = 'havan'), 'validate-key-04', repeat('a', 64))$$, 'PD422', 'duplicate ceremony rejected',
  'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.bootstrap_practice('P', (SELECT array_agg(id) FROM app.ceremony_types
  WHERE slug = 'havan'), NULL, repeat('a', 64))$$, 'PD422', 'Idempotency-Key is required',
  'IDEMPOTENCY_KEY_REQUIRED');
SELECT test.throws($$SELECT app.bootstrap_practice('P', (SELECT array_agg(id) FROM app.ceremony_types
  WHERE slug = 'havan'), 'short-7', repeat('a', 64))$$, '23514', 'keys shorter than 8 chars rejected');
SELECT test.throws($$SELECT app.bootstrap_practice('', (SELECT array_agg(id) FROM app.ceremony_types
  WHERE slug = 'havan'), 'retry-key-0001', repeat('a', 64))$$, 'PD422', 'failing command', 'VALIDATION_FAILED');
SELECT test.lives($$SELECT app.bootstrap_practice('Second Practice', (SELECT array_agg(id) FROM app.ceremony_types
  WHERE slug = 'havan'), 'retry-key-0001', repeat('b', 64))$$, 'key is free again after a failed attempt');
SELECT test.lives($$SELECT app.bootstrap_practice('Other user, same key', (SELECT array_agg(id) FROM app.ceremony_types
  WHERE slug = 'havan'), 'onboard-key-0001', repeat('a', 64))$$, 'another user may use the same key string');

SELECT test.ctx('c2000000-0000-0000-0000-000000000002', :'org1');
SELECT test.is((SELECT count(*) FROM app.offerings) + (SELECT count(*) FROM app.organization_priests), 0::bigint,
  'forged tenant header: zero offerings and priest links');

-- ---------------------------------------------------------------- profile
SELECT test.ctx('c1000000-0000-0000-0000-000000000001');
SELECT test.is(app.update_my_profile(NULL, 'hi'),
  '{"id": "c1000000-0000-0000-0000-000000000001", "display_name": "Ramesh Sharma", "preferred_locale": "hi"}'::jsonb,
  'update_my_profile changes the language only');
SELECT test.is(app.update_my_profile('  Pandit Ramesh  ', NULL) ->> 'display_name', 'Pandit Ramesh',
  'update_my_profile trims and saves the name');
SELECT test.throws($$SELECT app.update_my_profile(NULL, 'pa')$$, 'PD422', 'unsupported language rejected',
  'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.update_my_profile(repeat('x', 121), NULL)$$, 'PD422', 'name over 120 chars rejected',
  'VALIDATION_FAILED');
SELECT test.ctx(NULL);
SELECT test.throws($$SELECT app.update_my_profile('x', NULL)$$, 'PD401', 'profile update needs an actor',
  'CONTEXT_MISSING');

-- ---------------------------------------------------------------- the API role cannot touch the new tables directly
SELECT test.ctx('c1000000-0000-0000-0000-000000000001', :'org1');
SELECT test.throws($$SELECT * FROM app.idempotency_keys$$, '42501', 'runtime cannot read idempotency keys');
SELECT test.throws($$SELECT * FROM app.org_sequences$$, '42501', 'runtime cannot read booking sequences');
SELECT test.throws($$INSERT INTO app.offerings (org_id, name_hi, name_en, duration_min)
  VALUES (app.current_tenant_id(), 'x', 'x', 60)$$, '42501', 'runtime cannot INSERT offerings directly');
SELECT test.throws($$UPDATE app.app_users SET preferred_locale = 'en'$$, '42501',
  'runtime cannot UPDATE its own user row directly');
RESET ROLE;

-- ---------------------------------------------------------------- no application role reads Supabase Auth
SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_roles r WHERE r.rolname LIKE 'app\_%'
    AND (has_schema_privilege(r.oid, 'auth', 'USAGE')
         OR has_table_privilege(r.oid, 'auth.users', 'SELECT')
         OR has_any_column_privilege(r.oid, 'auth.users', 'SELECT'))),
  'no application role can use schema auth or read auth.users');

-- ---------------------------------------------------------------- app_bootstrap's policies only admit the actor's own rows
SELECT id AS p1 FROM app.priest_profiles WHERE user_id = 'c1000000-0000-0000-0000-000000000001' \gset
SET ROLE app_bootstrap;
SELECT test.ctx('c2000000-0000-0000-0000-000000000002');
SELECT test.throws($$INSERT INTO app.organizations (name, slug, created_by)
  VALUES ('Hijack', 'hijack', 'c1000000-0000-0000-0000-000000000001')$$, '42501',
  'bootstrap role cannot create an organization for someone else');
SELECT test.throws(format($$INSERT INTO app.organization_priests (org_id, priest_profile_id, linked_via)
  SELECT o.id, %L::uuid, 'BOOTSTRAP' FROM app.organizations o LIMIT 1$$, :'p1'), '42501',
  'bootstrap role cannot link another person''s priest profile');
SELECT test.throws(format($$INSERT INTO app.org_members (org_id, user_id, role) VALUES (%L, %L, 'OWNER')$$,
  :'org1', 'c2000000-0000-0000-0000-000000000002'), '42501',
  'bootstrap role cannot join an organization it did not create');
RESET ROLE;

-- ---------------------------------------------------------------- supabase/checks/m2_checks.sql row-level checks
-- The founder's checks script, run on the practices created above: it must pass, and it must catch leaking policies.
SELECT test.ctx(NULL, NULL);
\o /dev/null
\i supabase/checks/m2_checks.sql
\o
SELECT test.is(current_setting('pd_checks.m2_rls')::jsonb - '{no_context_seen,forged_seen,member_seen}'::text[],
  '{"no_context": "PASS", "forged": "PASS", "member": "PASS"}'::jsonb,
  'm2_checks.sql: the row-level checks pass on real rows (as the application roles)');
CREATE POLICY test_leak_runtime ON app.offerings FOR SELECT TO app_runtime USING (true);
CREATE POLICY test_leak_domain ON app.idempotency_keys FOR SELECT TO app_domain USING (true);
\o /dev/null
\i supabase/checks/m2_checks.sql
\o
SELECT test.is(current_setting('pd_checks.m2_rls')::jsonb ->> 'no_context_seen',
  'app_domain app.idempotency_keys, app_runtime app.offerings',
  'm2_checks.sql names each role and table that leaks rows without a request context');
SELECT test.is(current_setting('pd_checks.m2_rls')::jsonb ->> 'member', 'FAIL',
  'm2_checks.sql reports a member who sees another practice''s offerings');
DROP POLICY test_leak_runtime ON app.offerings;
DROP POLICY test_leak_domain ON app.idempotency_keys;

ROLLBACK;
