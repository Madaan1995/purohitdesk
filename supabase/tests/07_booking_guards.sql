-- M6 database guards (spec §14 §5.1 file 05): the database itself rejects inconsistent bookings even if a command were
-- buggy. Writes go directly to the tables as app_domain (the command owner) inside the tenant, so RLS and grants apply.
-- Fixtures: practice A (OWNER ua, priest link la), practice B (OWNER ub).
BEGIN;
SET LOCAL TIME ZONE 'UTC';

INSERT INTO auth.users (id, email) VALUES
  ('a7000000-0000-0000-0000-000000000001', 'ua7@example.test'),
  ('b7000000-0000-0000-0000-000000000001', 'ub7@example.test');
INSERT INTO app.app_users (id, auth_user_id) SELECT id, id FROM auth.users WHERE email LIKE 'u_7@example.test';
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('a7000000-0000-0000-0000-0000000000aa', 'A7', 'a7', 'a7000000-0000-0000-0000-000000000001'),
  ('b7000000-0000-0000-0000-0000000000bb', 'B7', 'b7', 'b7000000-0000-0000-0000-000000000001');
INSERT INTO app.org_sequences (org_id) VALUES ('a7000000-0000-0000-0000-0000000000aa'),
  ('b7000000-0000-0000-0000-0000000000bb');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('a7000000-0000-0000-0000-0000000000aa', 'a7000000-0000-0000-0000-000000000001', 'OWNER'),
  ('b7000000-0000-0000-0000-0000000000bb', 'b7000000-0000-0000-0000-000000000001', 'OWNER');
INSERT INTO app.priest_profiles (id, user_id, display_name) VALUES
  ('a7000000-0000-0000-0000-0000000000f1', 'a7000000-0000-0000-0000-000000000001', 'Pandit A7');
INSERT INTO app.organization_priests (id, org_id, priest_profile_id, linked_via) VALUES
  ('a7000000-0000-0000-0000-0000000000e1', 'a7000000-0000-0000-0000-0000000000aa', 'a7000000-0000-0000-0000-0000000000f1', 'BOOTSTRAP');
INSERT INTO app.customers (id, org_id, display_name) VALUES
  ('a7000000-0000-0000-0000-0000000000c1', 'a7000000-0000-0000-0000-0000000000aa', 'Customer A7'),
  ('b7000000-0000-0000-0000-0000000000c1', 'b7000000-0000-0000-0000-0000000000bb', 'Customer B7');
INSERT INTO app.offerings (id, org_id, name_hi, name_en, duration_min) VALUES
  ('a7000000-0000-0000-0000-0000000000d1', 'a7000000-0000-0000-0000-0000000000aa', 'हवन', 'Havan', 120);

-- Runs p_sql, then fires the deferred invariant triggers at once (as the current role), then defers them again.
CREATE FUNCTION test.at_commit(p_sql text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
END $$;

-- Three bookings made through the commands: a draft with a time, a confirmed one, a completed one.
SET ROLE app_runtime;
SELECT test.ctx('a7000000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-0000000000aa');
SELECT app.create_booking('{"customer_id": "a7000000-0000-0000-0000-0000000000c1", "offering_id":
  "a7000000-0000-0000-0000-0000000000d1", "starts_at": "2027-01-10T04:30:00Z", "ends_at": "2027-01-10T06:30:00Z",
  "buffer_before_min": 0, "buffer_after_min": 0}', false, 'g-key-0001', repeat('a', 64)) -> 'booking' ->> 'id' AS draft \gset
SELECT app.create_booking('{"customer_id": "a7000000-0000-0000-0000-0000000000c1", "offering_id":
  "a7000000-0000-0000-0000-0000000000d1", "starts_at": "2027-01-11T04:30:00Z", "ends_at": "2027-01-11T06:30:00Z",
  "priest_ids": ["a7000000-0000-0000-0000-0000000000e1"]}', true, 'g-key-0002', repeat('a', 64)) -> 'booking' ->> 'id' AS conf \gset
SELECT app.create_booking('{"customer_id": "a7000000-0000-0000-0000-0000000000c1", "offering_id":
  "a7000000-0000-0000-0000-0000000000d1", "starts_at": "2026-01-11T04:30:00Z", "ends_at": "2026-01-11T06:30:00Z",
  "priest_ids": ["a7000000-0000-0000-0000-0000000000e1"]}', true, 'g-key-0003', repeat('a', 64)) -> 'booking' AS done \gset
SELECT (:'done'::jsonb ->> 'id') AS done \gset
SELECT app.complete_booking(:'done', 2, 'g-key-0004', repeat('a', 64)) IS NOT NULL AS ok \gset
SELECT test.lives($$SELECT test.at_commit('SELECT 1')$$, 'bookings made by the commands satisfy the invariants');
RESET ROLE;

SET ROLE app_domain;
SELECT test.ctx('a7000000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-0000000000aa');

-- ---------------------------------------------------------------- deferred invariants (PD500 at COMMIT)
SELECT test.throws(format($$SELECT test.at_commit(%L)$$, format(
  $q$UPDATE app.bookings SET status = 'CONFIRMED', confirmed_at = now() WHERE id = %L$q$, :'draft')),
  'PD500', 'CONFIRMED booking without lead/reservation is rejected by the database', 'INVARIANT_VIOLATION');
SELECT test.throws(format($$SELECT test.at_commit(%L)$$, format(
  $q$UPDATE app.bookings SET starts_at = starts_at + interval '1 hour', ends_at = ends_at + interval '1 hour' WHERE id = %L$q$,
  :'conf')), 'PD500', 'moving a confirmed booking without moving its reservation is rejected', 'INVARIANT_VIOLATION');
SELECT test.throws(format($$SELECT test.at_commit(%L)$$, format(
  $q$UPDATE app.bookings SET status = 'CANCELLED', cancelled_at = now() WHERE id = %L$q$, :'conf')),
  'PD500', 'cancelling without releasing the reservation is rejected', 'INVARIANT_VIOLATION');
SELECT test.throws(format($$SELECT test.at_commit(%L)$$, format(
  $q$UPDATE app.calendar_reservations SET status = 'RELEASED', released_at = now() WHERE booking_id = %L$q$, :'conf')),
  'PD500', 'releasing the reservation of a confirmed booking is rejected', 'INVARIANT_VIOLATION');
SELECT test.throws(format($$SELECT test.at_commit(%L)$$, format(
  $q$DELETE FROM app.booking_assignments WHERE booking_id = %L$q$, :'conf')),
  'PD500', 'a confirmed booking cannot lose its LEAD', 'INVARIANT_VIOLATION');
SELECT test.throws(format($$SELECT test.at_commit(%L)$$, format(
  $q$INSERT INTO app.calendar_reservations (org_id, kind, booking_id, organization_priest_id, priest_profile_id, span,
     buffer_span, created_by) VALUES ('a7000000-0000-0000-0000-0000000000aa', 'BOOKING', %L,
     'a7000000-0000-0000-0000-0000000000e1', 'a7000000-0000-0000-0000-0000000000f1',
     '[2027-01-10 04:30+00,2027-01-10 06:30+00)', '[2027-01-10 04:30+00,2027-01-10 06:30+00)',
     'a7000000-0000-0000-0000-000000000001')$q$, :'draft')),
  'PD500', 'a DRAFT cannot hold a reservation', 'INVARIANT_VIOLATION');
SET CONSTRAINTS ALL DEFERRED;

-- ---------------------------------------------------------------- state guard and immutable columns
SELECT test.throws(format($$UPDATE app.bookings SET status = 'DRAFT', confirmed_at = NULL, completed_at = NULL
  WHERE id = %L$$, :'done'), 'PD410', 'COMPLETED -> DRAFT is not a valid transition', 'INVALID_TRANSITION');
SELECT test.throws(format($$UPDATE app.bookings SET status = 'CONFIRMED' WHERE id = %L$$, :'done'), 'PD410',
  'COMPLETED -> CONFIRMED is not a valid transition', 'INVALID_TRANSITION');
SELECT test.throws(format($$UPDATE app.bookings SET agreed_dakshina_paise = 100 WHERE id = %L$$, :'done'), 'PD410',
  'a COMPLETED booking keeps its terms', 'INVALID_TRANSITION');
SELECT test.lives(format($$UPDATE app.bookings SET title = NULL, location = NULL WHERE id = %L$$, :'done'),
  'free text of a terminal booking can be erased');
RESET ROLE;
SELECT test.throws(format($$UPDATE app.bookings SET created_via = 'VOICE' WHERE id = %L$$, :'draft'), 'PD422',
  'booking channel is immutable', 'IMMUTABLE_FIELD');
SELECT test.throws(format($$UPDATE app.bookings SET org_id = 'b7000000-0000-0000-0000-0000000000bb' WHERE id = %L$$,
  :'draft'), 'PD422', 'a booking cannot move to another organization', 'IMMUTABLE_FIELD');
SELECT test.throws(format($$UPDATE app.bookings SET booking_number = 'PD-26-9999' WHERE id = %L$$, :'draft'), 'PD422',
  'the booking number is immutable', 'IMMUTABLE_FIELD');
SELECT test.throws(format($$UPDATE app.bookings SET source = 'PRIEST_DIRECT', created_by = 'b7000000-0000-0000-0000-000000000001'
  WHERE id = %L$$, :'draft'), 'PD422', 'the creator is immutable', 'IMMUTABLE_FIELD');
SELECT test.throws(format($$DELETE FROM app.bookings WHERE id = %L$$, :'draft'), 'PD405', 'bookings are never deleted',
  'APPEND_ONLY');
SET ROLE app_domain;
SELECT test.ctx('a7000000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-0000000000aa');

-- ---------------------------------------------------------------- reservations and history
SELECT test.throws(format($$INSERT INTO app.calendar_reservations (org_id, kind, booking_id, organization_priest_id,
  priest_profile_id, span, buffer_span, created_by) SELECT org_id, kind, booking_id, organization_priest_id,
  priest_profile_id, '[2030-01-01 00:00+00,2030-01-01 01:00+00)', '[2030-01-01 00:00+00,2030-01-01 01:00+00)', created_by
  FROM app.calendar_reservations WHERE booking_id = %L$$, :'conf'), '23505',
  'one ACTIVE reservation per (booking, priest)');
SELECT test.throws($$INSERT INTO app.calendar_reservations (org_id, kind, organization_priest_id, priest_profile_id,
  span, buffer_span, created_by) VALUES ('a7000000-0000-0000-0000-0000000000aa', 'BLOCK',
  'a7000000-0000-0000-0000-0000000000e1', 'a7000000-0000-0000-0000-0000000000f1',
  '[2027-01-11 05:00+00,2027-01-11 05:30+00)', '[2027-01-11 05:00+00,2027-01-11 05:30+00)',
  'a7000000-0000-0000-0000-000000000001')$$, '23P01',
  'the exclusion constraint itself refuses overlapping ceremony time');
SELECT test.throws($$INSERT INTO app.calendar_reservations (org_id, kind, organization_priest_id, priest_profile_id,
  span, buffer_span, created_by, note) SELECT 'a7000000-0000-0000-0000-0000000000aa', 'BOOKING', organization_priest_id,
  priest_profile_id, '[2030-02-01 00:00+00,2030-02-01 01:00+00)', '[2030-02-01 00:00+00,2030-02-01 01:00+00)',
  created_by, 'family name' FROM app.calendar_reservations LIMIT 1$$, '23514',
  'free-text notes are allowed only on BLOCK reservations');
SELECT test.throws($$INSERT INTO app.calendar_reservations (org_id, kind, organization_priest_id, priest_profile_id,
  span, buffer_span, created_by) VALUES ('a7000000-0000-0000-0000-0000000000aa', 'BLOCK',
  'a7000000-0000-0000-0000-0000000000e1', 'a7000000-0000-0000-0000-0000000000f1',
  '[2030-03-01 00:00+00,2030-03-01 01:00+00)', '[2030-03-01 00:30+00,2030-03-01 01:00+00)',
  'a7000000-0000-0000-0000-000000000001')$$, '23514', 'the buffered span must cover the ceremony span');
SELECT test.throws($$INSERT INTO app.calendar_reservations (org_id, kind, organization_priest_id, priest_profile_id,
  span, buffer_span, created_by) VALUES ('a7000000-0000-0000-0000-0000000000aa', 'BLOCK',
  'a7000000-0000-0000-0000-0000000000e1', 'b7000000-0000-0000-0000-0000000000f9',
  '[2030-03-01 00:00+00,2030-03-01 01:00+00)', '[2030-03-01 00:00+00,2030-03-01 01:00+00)',
  'a7000000-0000-0000-0000-000000000001')$$, '23503', 'a reservation''s profile must match its priest link');
RESET ROLE;
SELECT test.throws(format($$UPDATE app.calendar_reservations SET span = '[2027-01-11 05:00+00,2027-01-11 07:00+00)'
  WHERE booking_id = %L$$, :'conf'), 'PD405', 'reservation spans are immutable', 'APPEND_ONLY');
SELECT test.throws(format($$UPDATE app.calendar_reservations SET status = 'ACTIVE' WHERE booking_id = %L$$, :'conf'),
  'PD405', 'the only change to a reservation is ACTIVE -> RELEASED', 'APPEND_ONLY');
SELECT test.throws(format($$DELETE FROM app.calendar_reservations WHERE booking_id = %L$$, :'conf'), 'PD405',
  'reservations are never deleted', 'APPEND_ONLY');
SELECT test.throws($$TRUNCATE app.calendar_reservations CASCADE$$, 'PD405', 'reservations cannot be truncated',
  'APPEND_ONLY');
SELECT test.throws(format($$UPDATE app.booking_events SET data = '{}' WHERE booking_id = %L$$, :'conf'), 'PD405',
  'booking history is append-only (UPDATE)', 'APPEND_ONLY');
SELECT test.throws(format($$DELETE FROM app.booking_events WHERE booking_id = %L$$, :'conf'), 'PD405',
  'booking history is append-only (DELETE)', 'APPEND_ONLY');
SELECT test.throws($$INSERT INTO app.bookings (org_id, seq_no, booking_number, customer_id, offering_id, timezone,
  local_date, starts_at, ends_at, created_by) VALUES ('a7000000-0000-0000-0000-0000000000aa', 99, 'PD-26-0099',
  'a7000000-0000-0000-0000-0000000000c1', 'a7000000-0000-0000-0000-0000000000d1', 'Asia/Kolkata', '2027-03-01',
  '2027-03-01T04:30:00Z', '2027-03-08T04:31:00Z', 'a7000000-0000-0000-0000-000000000001')$$, '23514',
  'bookings longer than 7 days are rejected by a CHECK');
SELECT test.throws($$INSERT INTO app.bookings (org_id, seq_no, booking_number, customer_id, offering_id, timezone,
  local_date, starts_at, ends_at, created_by) VALUES ('a7000000-0000-0000-0000-0000000000aa', 98, 'PD-26-0098',
  'a7000000-0000-0000-0000-0000000000c1', 'a7000000-0000-0000-0000-0000000000d1', 'Asia/Kolkata', '2027-03-01',
  '2027-03-01T20:00:00Z', '2027-03-01T21:00:00Z', 'a7000000-0000-0000-0000-000000000001')$$, '23514',
  'local_date must be the start''s date in the booking''s time zone (CHECK: 20:00 UTC is 2 Mar in IST)');
SELECT test.throws($$INSERT INTO app.bookings (org_id, seq_no, booking_number, customer_id, offering_id, timezone,
  local_date, created_by) VALUES ('a7000000-0000-0000-0000-0000000000aa', 97, 'PD-26-0097',
  'b7000000-0000-0000-0000-0000000000c1', 'a7000000-0000-0000-0000-0000000000d1', 'Asia/Kolkata', '2027-03-02',
  'a7000000-0000-0000-0000-000000000001')$$, '23503', 'composite FK blocks a cross-tenant customer reference');

SET ROLE app_domain;
SELECT test.ctx('a7000000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-0000000000aa');
SELECT test.throws($$INSERT INTO app.bookings (org_id, seq_no, booking_number, customer_id, offering_id, timezone,
  local_date, created_by) VALUES ('b7000000-0000-0000-0000-0000000000bb', 1, 'PD-26-0001',
  'b7000000-0000-0000-0000-0000000000c1', 'a7000000-0000-0000-0000-0000000000d1', 'Asia/Kolkata', '2027-03-02',
  'a7000000-0000-0000-0000-000000000001')$$, '42501', 'even app_domain cannot write into another tenant');
SELECT test.throws(format($$UPDATE app.bookings SET seq_no = 5 WHERE id = %L$$, :'draft'), '42501',
  'app_domain has no UPDATE on the immutable columns');
SELECT test.throws(format($$UPDATE app.calendar_reservations SET span = span WHERE booking_id = %L$$, :'conf'), '42501',
  'app_domain may only release reservations (column grant)');
SELECT test.throws($$UPDATE app.booking_events SET data = '{}'$$, '42501', 'app_domain has no UPDATE on history');
RESET ROLE;

-- app_freebusy reads busy-time columns of ACTIVE reservations only while the actor is a member of the tenant.
SET ROLE app_freebusy;
SELECT test.ctx(NULL, NULL);
SELECT test.is((SELECT count(id) FROM app.calendar_reservations), 0::bigint, 'app_freebusy sees nothing without context');
SELECT test.ctx('b7000000-0000-0000-0000-000000000001', 'b7000000-0000-0000-0000-0000000000bb');
SELECT test.is((SELECT count(id) FROM app.calendar_reservations), 2::bigint,
  'app_freebusy sees the ACTIVE busy time of every organization (for a member of one)');
SELECT test.throws($$SELECT note FROM app.calendar_reservations$$, '42501', 'app_freebusy cannot read reservation notes');
SELECT test.throws($$SELECT count(*) FROM app.bookings$$, '42501', 'app_freebusy cannot read bookings');
SELECT test.throws($$SELECT count(*) FROM app.customers$$, '42501', 'app_freebusy cannot read customers');
RESET ROLE;

-- ---------------------------------------------------------------- supabase/checks/m6_checks.sql row-level checks
-- The script tests whichever ACTIVE member sorts first (random ids): give practice B a booking too, so a leaking
-- policy is visible whichever member it picks.
INSERT INTO app.offerings (id, org_id, name_hi, name_en, duration_min) VALUES
  ('b7000000-0000-0000-0000-0000000000d1', 'b7000000-0000-0000-0000-0000000000bb', 'कथा', 'Katha', 60);
INSERT INTO app.bookings (org_id, seq_no, booking_number, customer_id, offering_id, timezone, local_date, created_by)
VALUES ('b7000000-0000-0000-0000-0000000000bb', 1, 'PD-26-0001', 'b7000000-0000-0000-0000-0000000000c1',
        'b7000000-0000-0000-0000-0000000000d1', 'Asia/Kolkata', '2027-03-02', 'b7000000-0000-0000-0000-000000000001');
SELECT test.ctx(NULL, NULL);
\o /dev/null
\i supabase/checks/m6_checks.sql
\o
SELECT test.is(current_setting('pd_checks.m6_rls')::jsonb - '{no_context_seen,forged_seen,member_seen}'::text[],
  '{"no_context": "PASS", "forged": "PASS", "member": "PASS"}'::jsonb,
  'm6_checks.sql: the row-level checks pass on real bookings (as the application roles)');
CREATE POLICY test_leak ON app.bookings FOR SELECT TO app_runtime USING (true);
\o /dev/null
\i supabase/checks/m6_checks.sql
\o
SELECT test.is(current_setting('pd_checks.m6_rls')::jsonb ->> 'no_context_seen', 'app_runtime app.bookings',
  'm6_checks.sql reports bookings visible without a request context');
SELECT test.is(current_setting('pd_checks.m6_rls')::jsonb ->> 'member', 'FAIL',
  'm6_checks.sql reports bookings a member may not see');
DROP POLICY test_leak ON app.bookings;

ROLLBACK;
