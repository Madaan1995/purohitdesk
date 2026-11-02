-- M4 customers: commands, RLS, provenance guard, optimistic concurrency, idempotency.
-- Fixtures: practice A (OWNER ua, STAFF us, READ_ONLY ur), practice B (OWNER ub).
BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('a4000000-0000-0000-0000-000000000001', 'ua4@example.test'),
  ('a4000000-0000-0000-0000-000000000002', 'us4@example.test'),
  ('a4000000-0000-0000-0000-000000000003', 'ur4@example.test'),
  ('b4000000-0000-0000-0000-000000000001', 'ub4@example.test');
INSERT INTO app.app_users (id, auth_user_id) SELECT id, id FROM auth.users WHERE email LIKE 'u_4@example.test';
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('a4000000-0000-0000-0000-0000000000aa', 'A4', 'a4', 'a4000000-0000-0000-0000-000000000001'),
  ('b4000000-0000-0000-0000-0000000000bb', 'B4', 'b4', 'b4000000-0000-0000-0000-000000000001');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('a4000000-0000-0000-0000-0000000000aa', 'a4000000-0000-0000-0000-000000000001', 'OWNER'),
  ('a4000000-0000-0000-0000-0000000000aa', 'a4000000-0000-0000-0000-000000000002', 'STAFF'),
  ('a4000000-0000-0000-0000-0000000000aa', 'a4000000-0000-0000-0000-000000000003', 'READ_ONLY'),
  ('b4000000-0000-0000-0000-0000000000bb', 'b4000000-0000-0000-0000-000000000001', 'OWNER');

SET ROLE app_runtime;

-- ---------------------------------------------------------------- create
SELECT test.ctx('a4000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-0000000000aa');
SELECT app.create_customer('  Ramesh Sharma ', NULL, NULL, 'cust-key-0001', repeat('a', 64)) AS c1 \gset
SELECT test.ok((:'c1'::jsonb -> 'customer' ->> 'display_name') = 'Ramesh Sharma'
  AND (:'c1'::jsonb -> 'customer' ->> 'phone_e164') IS NULL
  AND (:'c1'::jsonb -> 'customer' ->> 'acquisition_source') = 'PRIEST_DIRECT'
  AND (:'c1'::jsonb -> 'customer' ->> 'version')::int = 1
  AND (:'c1'::jsonb -> 'possible_duplicates') = '[]'::jsonb,
  'customer without a phone is saved (name trimmed, PRIEST_DIRECT, version 1)');
SELECT (:'c1'::jsonb -> 'customer' ->> 'id') AS cust1 \gset

SELECT app.create_customer('Suresh Sharma', '+919876543210', 'Sector 70, Mohali', 'cust-key-0002', repeat('b', 64))
  -> 'customer' ->> 'id' AS cust2 \gset
SELECT app.create_customer('Sunita Sharma', '+919876543210', NULL, 'cust-key-0003', repeat('c', 64)) AS c3 \gset
SELECT test.is(:'c3'::jsonb -> 'possible_duplicates',
  jsonb_build_array(jsonb_build_object('id', :'cust2'::uuid, 'display_name', 'Suresh Sharma')),
  'same phone twice: both saved, the second lists the first as a possible duplicate');
SELECT test.is((SELECT count(*) FROM app.customers WHERE phone_e164 = '+919876543210'), 2::bigint,
  'shared household phone: two customers stored');

SELECT test.is(app.create_customer('  Ramesh Sharma ', NULL, NULL, 'cust-key-0001', repeat('a', 64)) - 'idempotent_replay',
  :'c1'::jsonb - 'idempotent_replay', 'retry with the same key returns the same customer');
SELECT test.is((SELECT count(*) FROM app.customers WHERE display_name = 'Ramesh Sharma'), 1::bigint,
  'retry does not create a second customer');
SELECT test.throws($$SELECT app.create_customer('Other', NULL, NULL, 'cust-key-0001', repeat('d', 64))$$, 'PD412',
  'same key, different body', 'IDEMPOTENCY_REUSE');
SELECT test.throws($$SELECT app.create_customer('  ', NULL, NULL, 'cust-key-0004', repeat('a', 64))$$, 'PD422',
  'blank name rejected', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.create_customer('X', '9876543210', NULL, 'cust-key-0005', repeat('a', 64))$$, 'PD422',
  'phone must be E.164 (normalised by the API)', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.create_customer('X', NULL, repeat('a', 501), 'cust-key-0006', repeat('a', 64))$$, 'PD422',
  'address over 500 chars rejected', 'VALIDATION_FAILED');

SELECT test.ctx('a4000000-0000-0000-0000-000000000002', 'a4000000-0000-0000-0000-0000000000aa');
SELECT test.lives($$SELECT app.create_customer('Staff Added', NULL, NULL, 'cust-key-0101', repeat('a', 64))$$,
  'STAFF can create customers');
SELECT test.ctx('a4000000-0000-0000-0000-000000000003', 'a4000000-0000-0000-0000-0000000000aa');
SELECT test.throws($$SELECT app.create_customer('X', NULL, NULL, 'cust-key-0201', repeat('a', 64))$$, 'PD403',
  'READ_ONLY cannot write', 'FORBIDDEN');
SELECT test.is((SELECT count(*) FROM app.customers), 4::bigint, 'READ_ONLY member can read tenant customers');
SELECT test.ctx('b4000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-0000000000aa');
SELECT test.throws($$SELECT app.create_customer('X', NULL, NULL, 'cust-key-0301', repeat('a', 64))$$, 'PD404',
  'forged tenant header: commands answer 404, not 403', 'NOT_FOUND');
SELECT test.is((SELECT count(*) FROM app.customers), 0::bigint, 'forged tenant header: zero customers');
SELECT test.ctx('a4000000-0000-0000-0000-000000000001', NULL);
SELECT test.throws($$SELECT app.create_customer('X', NULL, NULL, 'cust-key-0401', repeat('a', 64))$$, 'PD401',
  'missing context: commands refuse', 'CONTEXT_MISSING');

-- ---------------------------------------------------------------- tenant B
SELECT test.ctx('b4000000-0000-0000-0000-000000000001', 'b4000000-0000-0000-0000-0000000000bb');
SELECT test.lives($$SELECT app.create_customer('B Customer', '+919876543210', NULL, 'cust-key-0001', repeat('a', 64))$$,
  'another practice may reuse the same key and phone');
SELECT test.is((SELECT array_agg(display_name) FROM app.customers), ARRAY['B Customer'],
  'tenant B sees only its own customers');
SELECT test.is(app.create_customer('B Two', '+919876543210', NULL, 'cust-key-0002', repeat('a', 64)) -> 'possible_duplicates'
  -> 0 ->> 'display_name', 'B Customer', 'duplicate check never looks into another practice');
SELECT test.throws(format($$SELECT app.update_customer(%L, 1, '{"display_name": "Hijack"}', 'cust-key-0003', repeat('a', 64))$$,
  :'cust1'), 'PD404', 'cannot update another practice''s customer (404)', 'NOT_FOUND');

-- ---------------------------------------------------------------- update
SELECT test.ctx('a4000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-0000000000aa');
SELECT app.update_customer(:'cust1', 1, '{"display_name": "Ramesh Kumar Sharma", "phone_e164": "+919876543210"}',
  'cust-upd-0001', repeat('a', 64)) AS u1 \gset
SELECT test.ok((:'u1'::jsonb -> 'customer' ->> 'version')::int = 2
  AND (:'u1'::jsonb -> 'customer' ->> 'display_name') = 'Ramesh Kumar Sharma'
  AND jsonb_array_length(:'u1'::jsonb -> 'possible_duplicates') = 2,
  'update changes fields, bumps the version and reports duplicates');
SELECT test.throws(format($$SELECT app.update_customer(%L, 1, '{"address": "x"}', 'cust-upd-0002', repeat('a', 64))$$,
  :'cust1'), 'PD409', 'stale expected version is rejected', 'VERSION_CONFLICT');
DO $$
DECLARE v_detail text;
BEGIN
  PERFORM app.update_customer((SELECT id FROM app.customers WHERE display_name = 'Ramesh Kumar Sharma'), 1,
    '{"address": "x"}', 'cust-upd-0003', repeat('a', 64));
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  PERFORM test.is(v_detail::jsonb, '{"current_version": 2}'::jsonb, 'version conflict reports the current version');
END $$;
SELECT test.is(app.update_customer(:'cust1', 2, '{"phone_e164": null, "address": "  "}', 'cust-upd-0004', repeat('a', 64))
  -> 'customer' -> 'phone_e164', 'null'::jsonb, 'JSON null clears the phone');
SELECT test.throws(format($$SELECT app.update_customer(%L, 3, '{"acquisition_source": "IMPORT"}', 'cust-upd-0005',
  repeat('a', 64))$$, :'cust1'), 'PD422', 'acquisition_source cannot be patched', 'IMMUTABLE_FIELD');
SELECT test.throws(format($$SELECT app.update_customer(%L, 3, '{"nickname": "x"}', 'cust-upd-0006', repeat('a', 64))$$,
  :'cust1'), 'PD422', 'unknown fields rejected', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT app.update_customer(%L, 3, '{}', 'cust-upd-0007', repeat('a', 64))$$, :'cust1'),
  'PD422', 'empty patch rejected', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT app.update_customer(%L, 3, '{"display_name": null}', 'cust-upd-0008', repeat('a', 64))$$,
  :'cust1'), 'PD422', 'name cannot be cleared', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.update_customer(gen_random_uuid(), 1, '{"display_name": "x"}', 'cust-upd-0009',
  repeat('a', 64))$$, 'PD404', 'unknown customer id → 404', 'NOT_FOUND');
SELECT test.ctx('a4000000-0000-0000-0000-000000000003', 'a4000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format($$SELECT app.update_customer(%L, 3, '{"display_name": "x"}', 'cust-upd-0010', repeat('a', 64))$$,
  :'cust1'), 'PD403', 'READ_ONLY cannot edit', 'FORBIDDEN');
RESET ROLE;

UPDATE app.customers SET erased_at = now() WHERE id = :'cust2';
SET ROLE app_runtime;
SELECT test.ctx('a4000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format($$SELECT app.update_customer(%L, 1, '{"display_name": "Back"}', 'cust-upd-0011', repeat('a', 64))$$,
  :'cust2'), 'PD404', 'erased customer cannot be edited back', 'NOT_FOUND');

-- ---------------------------------------------------------------- the API role cannot write directly
SELECT test.throws($$INSERT INTO app.customers (org_id, display_name) VALUES (app.current_tenant_id(), 'x')$$, '42501',
  'runtime cannot INSERT customers directly');
SELECT test.throws($$UPDATE app.customers SET display_name = 'x'$$, '42501', 'runtime cannot UPDATE customers directly');
SELECT test.throws($$DELETE FROM app.customers$$, '42501', 'runtime cannot DELETE customers');
RESET ROLE;

-- ---------------------------------------------------------------- even the command owner is held by RLS and the guard
SET ROLE app_domain;
SELECT test.ctx('a4000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-0000000000aa');
SELECT test.throws($$INSERT INTO app.customers (org_id, display_name) VALUES ('b4000000-0000-0000-0000-0000000000bb', 'x')$$,
  '42501', 'even app_domain cannot write into another tenant');
SELECT test.throws(format($$UPDATE app.customers SET acquisition_source = 'IMPORT' WHERE id = %L$$, :'cust1'), 'PD422',
  'customer acquisition_source is immutable', 'IMMUTABLE_FIELD');
SELECT test.throws(format($$UPDATE app.customers SET org_id = 'b4000000-0000-0000-0000-0000000000bb' WHERE id = %L$$,
  :'cust1'), 'PD422', 'a customer cannot move to another organization', 'IMMUTABLE_FIELD');
SELECT test.throws($$DELETE FROM app.customers$$, '42501', 'nobody deletes customers (erasure is an update)');
RESET ROLE;

-- ---------------------------------------------------------------- supabase/checks/m4_checks.sql row-level checks
-- The founder's checks script, run on the customers of A4 and B4: it must pass, and it must catch a leaking policy.
SELECT test.ctx(NULL, NULL);
\o /dev/null
\i supabase/checks/m4_checks.sql
\o
SELECT test.is(current_setting('pd_checks.m4_rls')::jsonb - '{no_context_seen,forged_seen,member_seen}'::text[],
  '{"no_context": "PASS", "forged": "PASS", "member": "PASS"}'::jsonb,
  'm4_checks.sql: the row-level checks pass on real customers (as the application roles)');
CREATE POLICY test_leak ON app.customers FOR SELECT TO app_domain USING (true);
\o /dev/null
\i supabase/checks/m4_checks.sql
\o
SELECT test.is(current_setting('pd_checks.m4_rls')::jsonb ->> 'forged_seen', 'app_domain app.customers',
  'm4_checks.sql reports customers visible to a non-member');
DROP POLICY test_leak ON app.customers;
CREATE POLICY test_leak ON app.customers FOR SELECT TO app_runtime USING (true);
\o /dev/null
\i supabase/checks/m4_checks.sql
\o
SELECT test.is(current_setting('pd_checks.m4_rls')::jsonb ->> 'member', 'FAIL',
  'm4_checks.sql reports a member who sees another practice''s customers');
DROP POLICY test_leak ON app.customers;

ROLLBACK;
