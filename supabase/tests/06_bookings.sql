-- M6 bookings: lifecycle, ceremony conflicts (also across practices), multi-priest, _OWN permissions, tenancy,
-- idempotency. Spec §14 §5.1 files 02/03/04/09 (the booking parts); travel buffers and reschedule are M7.
-- Fixtures: practice A (OWNER ua with priest profile pa, PRIEST up with profile pp, STAFF us, READ_ONLY ur);
-- practice B (OWNER ub with profile pb) where ua's profile pa is ALSO linked (link lab): one human, two practices;
-- practice C (OWNER ub) where ua is no member.
BEGIN;
SET LOCAL TIME ZONE 'UTC';

INSERT INTO auth.users (id, email) VALUES
  ('a6000000-0000-0000-0000-000000000001', 'ua6@example.test'),
  ('a6000000-0000-0000-0000-000000000002', 'up6@example.test'),
  ('a6000000-0000-0000-0000-000000000003', 'us6@example.test'),
  ('a6000000-0000-0000-0000-000000000004', 'ur6@example.test'),
  ('b6000000-0000-0000-0000-000000000001', 'ub6@example.test');
INSERT INTO app.app_users (id, auth_user_id) SELECT id, id FROM auth.users WHERE email LIKE 'u_6@example.test';
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('a6000000-0000-0000-0000-0000000000aa', 'A6', 'a6', 'a6000000-0000-0000-0000-000000000001'),
  ('b6000000-0000-0000-0000-0000000000bb', 'B6', 'b6', 'b6000000-0000-0000-0000-000000000001'),
  ('c6000000-0000-0000-0000-0000000000cc', 'C6', 'c6', 'b6000000-0000-0000-0000-000000000001');
INSERT INTO app.org_sequences (org_id) VALUES
  ('a6000000-0000-0000-0000-0000000000aa'), ('b6000000-0000-0000-0000-0000000000bb'),
  ('c6000000-0000-0000-0000-0000000000cc');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('a6000000-0000-0000-0000-0000000000aa', 'a6000000-0000-0000-0000-000000000001', 'OWNER'),
  ('a6000000-0000-0000-0000-0000000000aa', 'a6000000-0000-0000-0000-000000000002', 'PRIEST'),
  ('a6000000-0000-0000-0000-0000000000aa', 'a6000000-0000-0000-0000-000000000003', 'STAFF'),
  ('a6000000-0000-0000-0000-0000000000aa', 'a6000000-0000-0000-0000-000000000004', 'READ_ONLY'),
  ('b6000000-0000-0000-0000-0000000000bb', 'b6000000-0000-0000-0000-000000000001', 'OWNER'),
  ('c6000000-0000-0000-0000-0000000000cc', 'b6000000-0000-0000-0000-000000000001', 'OWNER');
INSERT INTO app.priest_profiles (id, user_id, display_name) VALUES
  ('a6000000-0000-0000-0000-0000000000f1', 'a6000000-0000-0000-0000-000000000001', 'Pandit A'),
  ('a6000000-0000-0000-0000-0000000000f2', 'a6000000-0000-0000-0000-000000000002', 'Pandit P'),
  ('b6000000-0000-0000-0000-0000000000f1', 'b6000000-0000-0000-0000-000000000001', 'Pandit B');
INSERT INTO app.organization_priests (id, org_id, priest_profile_id, linked_via) VALUES
  ('a6000000-0000-0000-0000-0000000000e1', 'a6000000-0000-0000-0000-0000000000aa', 'a6000000-0000-0000-0000-0000000000f1', 'BOOTSTRAP'),
  ('a6000000-0000-0000-0000-0000000000e2', 'a6000000-0000-0000-0000-0000000000aa', 'a6000000-0000-0000-0000-0000000000f2', 'BOOTSTRAP'),
  ('b6000000-0000-0000-0000-0000000000e1', 'b6000000-0000-0000-0000-0000000000bb', 'b6000000-0000-0000-0000-0000000000f1', 'BOOTSTRAP'),
  ('b6000000-0000-0000-0000-0000000000e3', 'b6000000-0000-0000-0000-0000000000bb', 'a6000000-0000-0000-0000-0000000000f1', 'INVITATION');
INSERT INTO app.customers (id, org_id, display_name) VALUES
  ('a6000000-0000-0000-0000-0000000000c1', 'a6000000-0000-0000-0000-0000000000aa', 'Ramesh Sharma'),
  ('b6000000-0000-0000-0000-0000000000c1', 'b6000000-0000-0000-0000-0000000000bb', 'Mohan Verma');
INSERT INTO app.offerings (id, org_id, name_hi, name_en, duration_min) VALUES
  ('a6000000-0000-0000-0000-0000000000d1', 'a6000000-0000-0000-0000-0000000000aa', 'हवन', 'Havan', 120),
  ('b6000000-0000-0000-0000-0000000000d1', 'b6000000-0000-0000-0000-0000000000bb', 'कथा', 'Katha', 120);
UPDATE app.organization_priests SET default_buffer_before_min = 45, default_buffer_after_min = 15
WHERE id = 'a6000000-0000-0000-0000-0000000000e1';

-- Shorthands, called as app_runtime: one fresh Idempotency-Key per call; the version is the current one.
CREATE FUNCTION test.bk(p jsonb, p_confirm boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.create_booking(
    jsonb_build_object('customer_id', 'a6000000-0000-0000-0000-0000000000c1',
                       'offering_id', 'a6000000-0000-0000-0000-0000000000d1') || p,
    p_confirm, false, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
CREATE FUNCTION test.bk_b(p jsonb, p_confirm boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.create_booking(
    jsonb_build_object('customer_id', 'b6000000-0000-0000-0000-0000000000c1',
                       'offering_id', 'b6000000-0000-0000-0000-0000000000d1') || p,
    p_confirm, false, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
CREATE FUNCTION test.ver(p_id uuid) RETURNS integer LANGUAGE sql AS $$
  SELECT version FROM app.bookings WHERE id = p_id $$;
CREATE FUNCTION test.confirm(p_id uuid, p_priests uuid[] DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.confirm_booking(p_id, test.ver(p_id), p_priests, false, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
CREATE FUNCTION test.edit(p_id uuid, p jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.update_booking(p_id, test.ver(p_id), p, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
CREATE FUNCTION test.cancel(p_id uuid, p_reason text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.cancel_booking(p_id, test.ver(p_id), p_reason, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
CREATE FUNCTION test.complete(p_id uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.complete_booking(p_id, test.ver(p_id), 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
-- Fires the deferred invariant triggers now, as the superuser (sees every practice), then defers them again.
CREATE FUNCTION test.invariants() RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
END $$;

\set la 'a6000000-0000-0000-0000-0000000000e1'
\set lp 'a6000000-0000-0000-0000-0000000000e2'
\set lab 'b6000000-0000-0000-0000-0000000000e3'
\set lb 'b6000000-0000-0000-0000-0000000000e1'
SELECT to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YY') AS yy \gset

SET ROLE app_runtime;
SELECT test.ctx('a6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-0000000000aa');

-- ---------------------------------------------------------------- 03 lifecycle
SELECT test.bk(jsonb_build_object('local_date', '2027-01-10', 'priest_ids', jsonb_build_array(:'la'))) AS d1 \gset
SELECT (:'d1'::jsonb ->> 'id') AS d1id \gset
SELECT test.is(:'d1'::jsonb ->> 'booking_number', 'PD-' || :'yy' || '-0001',
  'human-readable booking number per org (PD-YY-NNNN, YY = creation year in the practice''s time zone)');
SELECT test.ok((:'d1'::jsonb ->> 'status') = 'DRAFT' AND (:'d1'::jsonb ->> 'version')::int = 1,
  'new booking is a DRAFT (version 1)');
SELECT test.ok((:'d1'::jsonb -> 'starts_at') = 'null'::jsonb AND (:'d1'::jsonb ->> 'local_date') = '2027-01-10'
  AND (:'d1'::jsonb ->> 'timezone') = 'Asia/Kolkata', 'date-only draft allowed (org time zone by default)');
SELECT test.ok((:'d1'::jsonb ->> 'buffer_before_min')::int = 45 AND (:'d1'::jsonb ->> 'buffer_after_min')::int = 15,
  'the booking copies its LEAD''s default buffers');
SELECT test.is(:'d1'::jsonb -> 'priests' -> 0 ->> 'role', 'LEAD', 'first priest is the LEAD');
SELECT test.is((test.bk('{"local_date": "2027-01-11"}') ->> 'booking_number'), 'PD-' || :'yy' || '-0002',
  'booking numbers count up per practice');
SELECT test.throws(format('SELECT test.confirm(%L)', :'d1id'), 'PD422', 'cannot confirm without a time',
  'TIME_REQUIRED');
SELECT test.throws(format($$SELECT app.update_booking(%L, 7, '{"notes": "x"}', 'k-stale-0001', repeat('a', 64))$$,
  :'d1id'), 'PD409', 'stale expected version is rejected', 'VERSION_CONFLICT');
SELECT test.throws(format($$SELECT test.edit(%L, '{"local_date": "2027-01-12", "starts_at": "2027-01-10T04:30:00Z",
  "ends_at": "2027-01-10T06:30:00Z"}')$$, :'d1id'), 'PD422', 'a local_date that is not the start''s date is rejected',
  'VALIDATION_FAILED');
SELECT test.edit(:'d1id', '{"starts_at": "2027-01-10T04:30:00Z", "ends_at": "2027-01-10T06:30:00Z"}') AS d1e \gset
SELECT test.ok((:'d1e'::jsonb ->> 'version')::int = 2 AND (:'d1e'::jsonb ->> 'local_date') = '2027-01-10',
  'a draft gets its time later (10:00-12:00 IST); version bumped');
SELECT test.is((SELECT data FROM app.booking_events WHERE booking_id = :'d1id' AND event = 'EDITED'),
  '{"fields": ["ends_at", "starts_at"]}'::jsonb, 'EDITED event holds field names only');
SELECT test.is((test.bk('{"starts_at": "2027-01-10T20:00:00Z", "ends_at": "2027-01-10T21:00:00Z"}') ->> 'local_date'),
  '2027-01-11', 'local_date is the IST start date (20:00 UTC = 01:30 IST next day)');

SELECT test.confirm(:'d1id') AS d1c \gset
SELECT test.ok((:'d1c'::jsonb ->> 'status') = 'CONFIRMED' AND (:'d1c'::jsonb ->> 'confirmed_at') IS NOT NULL,
  'confirm DRAFT -> CONFIRMED');
SELECT test.is((SELECT span::text || ' ' || buffer_span::text || ' ' || status FROM app.calendar_reservations
  WHERE booking_id = :'d1id'),
  '["2027-01-10 04:30:00+00","2027-01-10 06:30:00+00") ["2027-01-10 03:45:00+00","2027-01-10 06:45:00+00") ACTIVE',
  'confirm reserves the priest (ceremony span and buffered span)');
SELECT test.throws(format('SELECT test.confirm(%L)', :'d1id'), 'PD410', 'cannot confirm twice', 'INVALID_TRANSITION');
SELECT test.throws(format($$SELECT test.edit(%L, '{"starts_at": "2027-01-10T05:30:00Z", "ends_at": "2027-01-10T07:30:00Z"}')$$,
  :'d1id'), 'PD422', 'schedule of a CONFIRMED booking changes only via reschedule', 'USE_RESCHEDULE');
SELECT test.throws(format($$SELECT test.edit(%L, '{"priest_ids": []}')$$, :'d1id'), 'PD422',
  'priests of a CONFIRMED booking change only via reschedule', 'USE_RESCHEDULE');
SELECT test.is(test.edit(:'d1id', '{"location": "Sector 70, Mohali", "agreed_dakshina_paise": 510000}')
  ->> 'agreed_dakshina_paise', '510000', 'place and dakshina of a CONFIRMED booking can change');
SELECT test.throws(format('SELECT test.complete(%L)', :'d1id'), 'PD422', 'cannot complete before the ceremony starts',
  'NOT_STARTED');

-- Ceremony overlap within the practice; half-open spans.
SELECT (test.bk('{"starts_at": "2027-01-10T05:30:00Z", "ends_at": "2027-01-10T07:00:00Z", "priest_ids":
  ["a6000000-0000-0000-0000-0000000000e1"]}') ->> 'id') AS d2id \gset
SELECT test.throws(format('SELECT test.confirm(%L)', :'d2id'), '23P01', 'overlapping confirmation rejected',
  'BOOKING_CONFLICT');
DO $$
DECLARE v_detail text;
BEGIN
  PERFORM test.confirm((SELECT id FROM app.bookings WHERE starts_at = '2027-01-10T05:30:00Z'));
EXCEPTION WHEN exclusion_violation THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  PERFORM test.is((v_detail::jsonb -> 'conflicts' -> 0) - 'booking_id',
    '{"starts_at": "2027-01-10T04:30:00+00:00", "ends_at": "2027-01-10T06:30:00+00:00", "same_org": true,
      "organization_priest_id": "a6000000-0000-0000-0000-0000000000e1"}'::jsonb,
    'conflict details carry the busy times and the priest; same practice');
  PERFORM test.ok(v_detail::jsonb -> 'conflicts' -> 0 ->> 'booking_id' IS NOT NULL,
    'a conflict in the same practice names its booking');
END $$;
SELECT test.lives($$SELECT test.bk('{"starts_at": "2027-01-12T04:30:00Z", "ends_at": "2027-01-12T06:30:00Z",
  "buffer_after_min": 0, "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}', true),
  test.bk('{"starts_at": "2027-01-12T06:30:00Z", "ends_at": "2027-01-12T07:30:00Z", "buffer_before_min": 0,
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}', true)$$,
  'back-to-back ceremonies without travel time do not conflict (12:00-13:00 after 10:00-12:00; spans are half-open)');

-- Cancel.
SELECT test.throws(format('SELECT test.cancel(%L)', :'d1id'), 'PD422', 'cancelling a CONFIRMED booking needs a reason',
  'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT test.cancel(%L, 'ab')$$, :'d1id'), 'PD422', 'a reason has at least 3 characters',
  'VALIDATION_FAILED');
SELECT test.cancel(:'d1id', 'Family postponed') AS d1x \gset
SELECT test.ok((:'d1x'::jsonb ->> 'status') = 'CANCELLED' AND (:'d1x'::jsonb ->> 'cancel_reason') = 'Family postponed',
  'cancel CONFIRMED -> CANCELLED');
SELECT test.is((SELECT string_agg(status, ',') FROM app.calendar_reservations WHERE booking_id = :'d1id'), 'RELEASED',
  'cancel releases the slot (history kept)');
SELECT test.is((SELECT data FROM app.booking_events WHERE booking_id = :'d1id' AND event = 'CANCELLED'),
  '{"from": "CONFIRMED", "released": 1}'::jsonb, 'CANCELLED event: previous status and count, no reason text');
SELECT test.is(test.confirm(:'d2id') ->> 'status', 'CONFIRMED', 'after the cancel the overlapping booking confirms');
SELECT test.throws(format($$SELECT test.edit(%L, '{"title": "New"}')$$, :'d1id'), 'PD410',
  'terminal booking is immutable', 'INVALID_TRANSITION');
SELECT test.throws(format('SELECT test.confirm(%L)', :'d1id'), 'PD410', 'a cancelled booking cannot be re-opened',
  'INVALID_TRANSITION');
SELECT test.is(test.edit(:'d1id', '{"notes": "call next month"}') ->> 'notes', 'call next month',
  'notes of a terminal booking may still change');
SELECT test.is(test.cancel((test.bk('{"local_date": "2027-02-01"}') ->> 'id')::uuid) ->> 'status', 'CANCELLED',
  'a DRAFT can be cancelled without a reason');

-- Tentative windows, overnight, limits, time zones.
SELECT test.ok((test.bk('{"starts_at": "2027-01-15T03:30:00Z", "ends_at": "2027-01-15T07:30:00Z",
  "is_time_tentative": true, "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}', true) ->> 'is_time_tentative')::boolean,
  'tentative window confirmed (09:00-13:00 IST, exact muhurat later)');
SELECT test.throws($$SELECT test.bk('{"starts_at": "2027-01-15T06:30:00Z", "ends_at": "2027-01-15T07:00:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}', true)$$, '23P01',
  'tentative window blocks the whole window', 'BOOKING_CONFLICT');
SELECT test.lives($$SELECT test.bk('{"starts_at": "2027-01-20T16:30:00Z", "ends_at": "2027-01-21T00:30:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}', true)$$, 'overnight booking (Jagran 22:00-06:00 IST)');
SELECT test.throws($$SELECT test.bk('{"starts_at": "2027-01-20T23:30:00Z", "ends_at": "2027-01-21T01:30:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}', true)$$, '23P01',
  'overnight booking conflicts across midnight', 'BOOKING_CONFLICT');
SELECT test.throws($$SELECT test.bk('{"starts_at": "2027-03-01T04:30:00Z", "ends_at": "2027-03-08T04:31:00Z"}')$$,
  'PD422', 'bookings longer than 7 days are rejected', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"starts_at": "2027-03-01T04:30:00Z", "ends_at": "2027-03-01T04:30:00Z"}')$$,
  'PD422', 'end must be after start', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"starts_at": "2027-03-01T04:30:00Z"}')$$, 'PD422',
  'start and end come together', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01", "is_time_tentative": true}')$$, 'PD422',
  'tentative needs a time window', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01", "timezone": "Mars/Olympus"}')$$, 'PD422',
  'unknown IANA timezone rejected', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01", "timezone": "IST"}')$$, 'PD422',
  'time-zone abbreviations are rejected (IANA names only)', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"starts_at": "2027-03-01 10:00", "ends_at": "2027-03-01T05:30:00Z"}')$$, 'PD422',
  'instants need RFC 3339 with an offset', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-02-30"}')$$, 'PD422', 'impossible dates are rejected',
  'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{}')$$, 'PD422', 'a booking needs at least a date', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01", "colour": "red"}')$$, 'PD422',
  'unknown fields are rejected', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01", "agreed_dakshina_paise": 5100.5}')$$, 'PD422',
  'dakshina is integer paise', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01", "buffer_after_min": 361}')$$, 'PD422',
  'buffers are 0-360 minutes', 'VALIDATION_FAILED');

-- Complete (a ceremony that already started).
SELECT test.bk('{"starts_at": "2026-01-05T04:30:00Z", "ends_at": "2026-01-05T06:30:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}', true) ->> 'id' AS past \gset
SELECT test.is(test.complete(:'past') ->> 'status', 'COMPLETED', 'confirm -> complete (started earlier)');
SELECT test.is((SELECT status FROM app.calendar_reservations WHERE booking_id = :'past'), 'ACTIVE',
  'completed ceremony keeps its busy span');
SELECT test.throws(format($$SELECT test.cancel(%L, 'too late')$$, :'past'), 'PD410', 'COMPLETED cannot be cancelled',
  'INVALID_TRANSITION');
SELECT test.throws(format('SELECT test.complete(%L)', :'d2id' ), 'PD422', 'a future booking cannot be completed',
  'NOT_STARTED');
SELECT test.throws(format('SELECT test.complete(%L)', (test.bk('{"local_date": "2026-01-01"}') ->> 'id')), 'PD410',
  'a DRAFT cannot be completed', 'INVALID_TRANSITION');

-- ---------------------------------------------------------------- 04 across practices (one human, two practices)
SELECT test.ctx('b6000000-0000-0000-0000-000000000001', 'b6000000-0000-0000-0000-0000000000bb');
DO $$
DECLARE v_detail text;
BEGIN
  PERFORM test.bk_b('{"starts_at": "2027-01-10T06:00:00Z", "ends_at": "2027-01-10T07:00:00Z",
    "priest_ids": ["b6000000-0000-0000-0000-0000000000e3"]}', true);
  PERFORM test.ok(false, 'cross-organization double booking of one priest is impossible', 'no error raised');
EXCEPTION WHEN exclusion_violation THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  PERFORM test.ok(true, 'cross-organization double booking of one priest is impossible');
  PERFORM test.is(v_detail::jsonb -> 'conflicts',
    '[{"starts_at": "2027-01-10T05:30:00+00:00", "ends_at": "2027-01-10T07:00:00+00:00", "same_org": false,
       "organization_priest_id": "b6000000-0000-0000-0000-0000000000e3"}]'::jsonb,
    'org B sees only busy spans of org A, never its booking ids');
END $$;
SELECT test.is((SELECT count(*) FROM app.bookings), 0::bigint, 'org B still cannot read org A bookings');
SELECT test.is(app.get_booking(:'d2id'), NULL::jsonb, 'booking read model returns nothing across tenants');
SELECT test.is((SELECT count(*) FROM app.calendar_reservations), 0::bigint, 'org B reads no reservation of org A');
SELECT test.lives($$SELECT test.bk_b('{"starts_at": "2027-01-10T08:00:00Z", "ends_at": "2027-01-10T09:00:00Z",
  "priest_ids": ["b6000000-0000-0000-0000-0000000000e3"]}', true)$$, 'the same priest is free later that day in org B');
SELECT test.is(test.bk_b('{"local_date": "2027-01-10"}') ->> 'booking_number', 'PD-' || :'yy' || '-0002',
  'each practice has its own counter');
SELECT test.throws(format('SELECT test.cancel(%L, %L)', :'d2id', 'not mine'), 'PD404',
  'another practice''s booking is not found (404, not 403)', 'NOT_FOUND');
SELECT test.throws($$SELECT test.bk_b('{"local_date": "2027-01-10", "customer_id": "a6000000-0000-0000-0000-0000000000c1"}')$$,
  'PD404', 'a customer of another practice is not found', 'NOT_FOUND');
SELECT test.throws($$SELECT test.bk_b('{"local_date": "2027-01-10", "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}')$$,
  'PD422', 'a priest link of another organization cannot be assigned', 'VALIDATION_FAILED');

-- ---------------------------------------------------------------- multi-priest (all or nothing)
SELECT test.ctx('a6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-0000000000aa');
SELECT test.bk('{"starts_at": "2027-02-02T04:30:00Z", "ends_at": "2027-02-02T06:30:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e2"]}', true) ->> 'id' AS pbusy \gset
SELECT test.bk('{"starts_at": "2027-02-02T05:00:00Z", "ends_at": "2027-02-02T06:00:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e1", "a6000000-0000-0000-0000-0000000000e2"]}') ->> 'id' AS team \gset
SELECT test.throws(format('SELECT test.confirm(%L)', :'team'), '23P01', 'one busy priest fails the whole team',
  'BOOKING_CONFLICT');
SELECT test.is((SELECT count(*) FROM app.calendar_reservations WHERE booking_id = :'team'), 0::bigint,
  'no partial reservation for the free priest');
SELECT test.edit(:'team', '{"starts_at": "2027-02-02T08:00:00Z", "ends_at": "2027-02-02T09:00:00Z"}') AS teamv \gset
SELECT test.is((SELECT string_agg(role, ',' ORDER BY position) FROM app.booking_assignments WHERE booking_id = :'team'),
  'LEAD,ASSISTANT', 'one LEAD + one ASSISTANT');
SELECT test.confirm(:'team') AS teamc \gset
SELECT test.is((SELECT count(*) FROM app.calendar_reservations WHERE booking_id = :'team' AND status = 'ACTIVE'),
  2::bigint, 'every assigned priest is reserved');
SELECT test.is(jsonb_array_length(:'teamc'::jsonb -> 'priests'), 2, 'the read model lists both priests');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01", "priest_ids": ["a6000000-0000-0000-0000-0000000000e1",
  "a6000000-0000-0000-0000-0000000000e1"]}')$$, 'PD422', 'a priest is assigned at most once', 'VALIDATION_FAILED');

-- ---------------------------------------------------------------- _OWN permissions (PRIEST up leads only his own)
SELECT test.ctx('a6000000-0000-0000-0000-000000000002', 'a6000000-0000-0000-0000-0000000000aa');
SELECT test.is(test.bk('{"starts_at": "2027-02-03T04:30:00Z", "ends_at": "2027-02-03T05:30:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e2"]}', true) ->> 'status', 'CONFIRMED',
  'PRIEST confirms a booking he leads');
SELECT test.bk('{"starts_at": "2027-02-04T04:30:00Z", "ends_at": "2027-02-04T05:30:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}') ->> 'id' AS other \gset
SELECT test.throws(format('SELECT test.confirm(%L)', :'other'), 'PD403', 'PRIEST cannot confirm another priest''s booking',
  'FORBIDDEN');
SELECT test.throws(format('SELECT test.confirm(%L, ARRAY[%L]::uuid[])', :'other', :'lp'), 'PD403',
  'PRIEST cannot take over another priest''s booking by reassigning it while confirming', 'FORBIDDEN');
SELECT test.throws(format($$SELECT test.edit(%L, '{"priest_ids": ["a6000000-0000-0000-0000-0000000000e2"]}')$$, :'other'),
  'PD403', 'PRIEST cannot reassign another priest''s draft to himself', 'FORBIDDEN');
SELECT test.is((SELECT organization_priest_id FROM app.booking_assignments WHERE booking_id = :'other' AND role = 'LEAD'),
  :'la'::uuid, 'the original LEAD is unchanged');
SELECT test.throws(format($$SELECT test.cancel(%L, 'not his')$$, :'other'), 'PD403',
  'PRIEST cannot cancel another priest''s booking', 'FORBIDDEN');
SELECT test.is(test.edit(:'other', '{"location": "Zirakpur"}') ->> 'location', 'Zirakpur',
  'PRIEST may edit details of any booking (BOOKING_EDIT)');
SELECT test.throws($$SELECT test.bk('{"starts_at": "2027-02-05T04:30:00Z", "ends_at": "2027-02-05T05:30:00Z",
  "priest_ids": ["a6000000-0000-0000-0000-0000000000e1"]}', true)$$, 'PD403',
  'PRIEST cannot create+confirm a booking led by another priest', 'FORBIDDEN');

-- STAFF: drafts and assignments, no confirmation.
SELECT test.ctx('a6000000-0000-0000-0000-000000000003', 'a6000000-0000-0000-0000-0000000000aa');
SELECT test.bk('{"starts_at": "2027-02-06T04:30:00Z", "ends_at": "2027-02-06T05:30:00Z"}') ->> 'id' AS sd \gset
SELECT test.is(test.edit(:'sd', '{"priest_ids": ["a6000000-0000-0000-0000-0000000000e2"]}') -> 'priests' -> 0 ->> 'organization_priest_id',
  :'lp', 'STAFF may assign a priest to a draft (but cannot confirm it)');
SELECT test.throws(format('SELECT test.confirm(%L)', :'sd'), 'PD403', 'STAFF cannot confirm', 'FORBIDDEN');
SELECT test.throws(format($$SELECT test.cancel(%L, 'staff')$$, :'sd'), 'PD403', 'STAFF cannot cancel', 'FORBIDDEN');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01"}', true)$$, 'PD403',
  'STAFF cannot create a confirmed booking', 'FORBIDDEN');
SELECT test.bk('{"starts_at": "2027-02-07T04:30:00Z", "ends_at": "2027-02-07T05:30:00Z"}') ->> 'id' AS nolead \gset
SELECT test.ctx('a6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format('SELECT test.confirm(%L)', :'nolead'), 'PD422', 'confirming requires a LEAD priest',
  'LEAD_REQUIRED');
SELECT test.is(test.confirm(:'nolead', ARRAY[:'la']::uuid[]) -> 'priests' -> 0 ->> 'role', 'LEAD',
  'OWNER assigns the LEAD while confirming');

-- READ_ONLY
SELECT test.ctx('a6000000-0000-0000-0000-000000000004', 'a6000000-0000-0000-0000-0000000000aa');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01"}')$$, 'PD403', 'READ_ONLY cannot write', 'FORBIDDEN');
SELECT test.throws(format($$SELECT test.edit(%L, '{"notes": "x"}')$$, :'sd'), 'PD403', 'READ_ONLY cannot edit',
  'FORBIDDEN');
SELECT test.throws(format('SELECT test.confirm(%L)', :'sd'), 'PD403', 'READ_ONLY cannot confirm', 'FORBIDDEN');
SELECT test.ok(app.get_booking(:'sd') IS NOT NULL AND (SELECT count(*) FROM app.bookings) > 0,
  'READ_ONLY reads bookings');

-- ---------------------------------------------------------------- 02 isolation and privileges
SELECT test.ctx('a6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-0000000000cc');
SELECT test.is((SELECT count(*) FROM app.bookings), 0::bigint, 'forged tenant header: zero bookings');
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01"}')$$, 'PD404',
  'forged tenant header: commands answer 404, not 403', 'NOT_FOUND');
SELECT test.throws(format('SELECT test.confirm(%L)', :'sd'), 'PD404', 'forged tenant header: confirm answers 404',
  'NOT_FOUND');
SELECT test.ctx(NULL, NULL);
SELECT test.throws($$SELECT test.bk('{"local_date": "2027-03-01"}')$$, 'PD401', 'missing context: commands refuse',
  'CONTEXT_MISSING');
SELECT test.ctx('a6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format($$UPDATE app.bookings SET notes = 'x' WHERE id = %L$$, :'sd'), '42501',
  'runtime cannot UPDATE bookings directly');
SELECT test.throws(format($$INSERT INTO app.calendar_reservations (org_id, kind, organization_priest_id,
  priest_profile_id, span, buffer_span, created_by) VALUES (%L, 'BLOCK', %L, 'a6000000-0000-0000-0000-0000000000f1',
  tstzrange(now(), now() + interval '1 hour'), tstzrange(now(), now() + interval '1 hour'), %L)$$,
  'a6000000-0000-0000-0000-0000000000aa', :'la', 'a6000000-0000-0000-0000-000000000001'), '42501',
  'runtime cannot INSERT reservations directly');
SELECT test.throws(format('SELECT app._reserve_booking(%L, false)', :'sd'), '42501',
  'runtime cannot call internal helpers (_reserve_booking)');
SELECT test.throws($$SELECT * FROM app._priest_conflicts('a6000000-0000-0000-0000-0000000000f1',
  tstzrange(now(), now() + interval '1 hour'), tstzrange(now(), now() + interval '1 hour'), NULL)$$, '42501',
  'runtime cannot call _priest_conflicts');
SELECT test.throws($$INSERT INTO app.booking_events (org_id, booking_id, event) SELECT org_id, id, 'COMPLETED'
  FROM app.bookings LIMIT 1$$, '42501', 'runtime cannot write booking history');

-- ---------------------------------------------------------------- 09 idempotency
SELECT app.create_booking(jsonb_build_object('customer_id', 'a6000000-0000-0000-0000-0000000000c1',
  'offering_id', 'a6000000-0000-0000-0000-0000000000d1', 'local_date', '2027-04-01', 'title', 'dup race'),
  false, false, 'idem-key-0001', repeat('b', 64)) AS i1 \gset
SELECT app.create_booking(jsonb_build_object('customer_id', 'a6000000-0000-0000-0000-0000000000c1',
  'offering_id', 'a6000000-0000-0000-0000-0000000000d1', 'local_date', '2027-04-01', 'title', 'dup race'),
  false, false, 'idem-key-0001', repeat('b', 64)) AS i2 \gset
SELECT test.ok((:'i2'::jsonb -> 'booking' ->> 'id') = (:'i1'::jsonb -> 'booking' ->> 'id')
  AND (:'i2'::jsonb ->> 'idempotent_replay')::boolean AND NOT (:'i1'::jsonb ->> 'idempotent_replay')::boolean,
  'replay returns the original booking');
SELECT test.is((SELECT count(*) FROM app.bookings WHERE title = 'dup race'), 1::bigint, 'only one booking exists');
SELECT test.throws($$SELECT app.create_booking('{"local_date": "2027-04-02"}', false, false, 'idem-key-0001', repeat('c', 64))$$,
  'PD412', 'same key, different body', 'IDEMPOTENCY_REUSE');
SELECT test.throws(format($$SELECT app.cancel_booking(%L, 1, NULL, 'idem-key-0001', repeat('b', 64))$$,
  :'i1'::jsonb -> 'booking' ->> 'id'), 'PD412', 'same key, different command', 'IDEMPOTENCY_REUSE');
SELECT test.throws($$SELECT app.create_booking('{"local_date": "2027-02-30"}', false, false, 'idem-key-0002', repeat('d', 64))$$,
  'PD422', 'failing command', 'VALIDATION_FAILED');
SELECT test.lives($$SELECT app.create_booking(jsonb_build_object('customer_id', 'a6000000-0000-0000-0000-0000000000c1',
  'offering_id', 'a6000000-0000-0000-0000-0000000000d1', 'local_date', '2027-04-03'), false, false, 'idem-key-0002',
  repeat('e', 64))$$, 'a failed command frees its key for a retry');

-- ---------------------------------------------------------------- history and invariants
SELECT test.is((SELECT string_agg(event, ',' ORDER BY id) FROM app.booking_events WHERE booking_id = :'d1id'),
  'CREATED,EDITED,CONFIRMED,EDITED,CANCELLED,EDITED', 'booking history records every step');
SELECT test.ok(NOT EXISTS (SELECT 1 FROM app.booking_events e, jsonb_each(e.data) d
  WHERE d.key NOT IN ('status', 'local_date', 'starts_at', 'ends_at', 'customer_id', 'offering_id',
                      'organization_priest_ids', 'fields', 'reservations', 'from', 'released')),
  'history data holds only ids, times, counts and codes');
SELECT test.lives($$SELECT test.invariants()$$, 'every booking above satisfies the deferred invariants');

-- Booking numbers grow past 9999.
RESET ROLE;
UPDATE app.org_sequences SET next_booking_no = 10000 WHERE org_id = 'a6000000-0000-0000-0000-0000000000aa';
SET ROLE app_runtime;
SELECT test.is(test.bk('{"local_date": "2027-05-01"}') ->> 'booking_number', 'PD-' || :'yy' || '-10000',
  'booking numbers grow to 5 digits after 9999');

ROLLBACK;
