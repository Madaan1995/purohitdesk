-- M7 travel buffers and reschedule (spec §14 §5.1 file 04: buffers and reschedule; §12 defect 10).
-- Fixtures: practice A (OWNER ua with profile pa, link la; PRIEST up with profile pp, link lp; STAFF us); practice B
-- (OWNER ub) where pa is also linked (lab). Default buffers 30/30 everywhere. Times are UTC (IST = UTC + 5:30).
BEGIN;
SET LOCAL TIME ZONE 'UTC';

INSERT INTO auth.users (id, email) VALUES
  ('a8000000-0000-0000-0000-000000000001', 'ua8@example.test'),
  ('a8000000-0000-0000-0000-000000000002', 'up8@example.test'),
  ('a8000000-0000-0000-0000-000000000003', 'us8@example.test'),
  ('b8000000-0000-0000-0000-000000000001', 'ub8@example.test');
INSERT INTO app.app_users (id, auth_user_id) SELECT id, id FROM auth.users WHERE email LIKE 'u_8@example.test';
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('a8000000-0000-0000-0000-0000000000aa', 'A8', 'a8', 'a8000000-0000-0000-0000-000000000001'),
  ('b8000000-0000-0000-0000-0000000000bb', 'B8', 'b8', 'b8000000-0000-0000-0000-000000000001');
INSERT INTO app.org_sequences (org_id) VALUES ('a8000000-0000-0000-0000-0000000000aa'),
  ('b8000000-0000-0000-0000-0000000000bb');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('a8000000-0000-0000-0000-0000000000aa', 'a8000000-0000-0000-0000-000000000001', 'OWNER'),
  ('a8000000-0000-0000-0000-0000000000aa', 'a8000000-0000-0000-0000-000000000002', 'PRIEST'),
  ('a8000000-0000-0000-0000-0000000000aa', 'a8000000-0000-0000-0000-000000000003', 'STAFF'),
  ('b8000000-0000-0000-0000-0000000000bb', 'b8000000-0000-0000-0000-000000000001', 'OWNER');
INSERT INTO app.priest_profiles (id, user_id, display_name) VALUES
  ('a8000000-0000-0000-0000-0000000000f1', 'a8000000-0000-0000-0000-000000000001', 'Pandit A8'),
  ('a8000000-0000-0000-0000-0000000000f2', 'a8000000-0000-0000-0000-000000000002', 'Pandit P8');
INSERT INTO app.organization_priests (id, org_id, priest_profile_id, linked_via) VALUES
  ('a8000000-0000-0000-0000-0000000000e1', 'a8000000-0000-0000-0000-0000000000aa', 'a8000000-0000-0000-0000-0000000000f1', 'BOOTSTRAP'),
  ('a8000000-0000-0000-0000-0000000000e2', 'a8000000-0000-0000-0000-0000000000aa', 'a8000000-0000-0000-0000-0000000000f2', 'BOOTSTRAP'),
  ('b8000000-0000-0000-0000-0000000000e3', 'b8000000-0000-0000-0000-0000000000bb', 'a8000000-0000-0000-0000-0000000000f1', 'INVITATION');
INSERT INTO app.customers (id, org_id, display_name) VALUES
  ('a8000000-0000-0000-0000-0000000000c1', 'a8000000-0000-0000-0000-0000000000aa', 'Customer A8'),
  ('b8000000-0000-0000-0000-0000000000c1', 'b8000000-0000-0000-0000-0000000000bb', 'Customer B8');
INSERT INTO app.offerings (id, org_id, name_hi, name_en, duration_min) VALUES
  ('a8000000-0000-0000-0000-0000000000d1', 'a8000000-0000-0000-0000-0000000000aa', 'हवन', 'Havan', 60),
  ('b8000000-0000-0000-0000-0000000000d1', 'b8000000-0000-0000-0000-0000000000bb', 'हवन', 'Havan', 60);

-- Shorthands, called as app_runtime. tb(start, end, extra, confirm, ack) books priest la (or lab in practice B).
CREATE FUNCTION test.tb(p_start text, p_end text, p jsonb DEFAULT '{}', p_confirm boolean DEFAULT true,
                        p_ack boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.create_booking(
    CASE WHEN app.current_tenant_id() = 'b8000000-0000-0000-0000-0000000000bb'
         THEN '{"customer_id": "b8000000-0000-0000-0000-0000000000c1", "offering_id": "b8000000-0000-0000-0000-0000000000d1",
                "priest_ids": ["b8000000-0000-0000-0000-0000000000e3"]}'::jsonb
         ELSE '{"customer_id": "a8000000-0000-0000-0000-0000000000c1", "offering_id": "a8000000-0000-0000-0000-0000000000d1",
                "priest_ids": ["a8000000-0000-0000-0000-0000000000e1"]}'::jsonb END
    || jsonb_build_object('starts_at', p_start, 'ends_at', p_end) || p,
    p_confirm, p_ack, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
CREATE FUNCTION test.ver(p_id uuid) RETURNS integer LANGUAGE sql AS $$ SELECT version FROM app.bookings WHERE id = p_id $$;
CREATE FUNCTION test.confirm(p_id uuid, p_ack boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.confirm_booking(p_id, test.ver(p_id), NULL, p_ack, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
CREATE FUNCTION test.move(p_id uuid, p jsonb, p_code text DEFAULT 'CUSTOMER_REQUEST', p_ack boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.reschedule_booking(p_id, test.ver(p_id), p, p_code, p_ack, 'k-' || gen_random_uuid(), repeat('a', 64))
    -> 'booking' $$;
CREATE FUNCTION test.invariants() RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
END $$;

SET ROLE app_runtime;
SELECT test.ctx('a8000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-0000000000aa');

-- ---------------------------------------------------------------- travel buffers (AC-04)
SELECT test.tb('2027-06-01T04:30:00Z', '2027-06-01T05:30:00Z') ->> 'id' AS a1 \gset
SELECT test.tb('2027-06-01T05:45:00Z', '2027-06-01T06:45:00Z', p_confirm => false) ->> 'id' AS a2 \gset
DO $$
DECLARE v_detail text;
BEGIN
  PERFORM test.confirm((SELECT id FROM app.bookings WHERE starts_at = '2027-06-01T05:45:00Z'));
  PERFORM test.ok(false, 'buffer-only overlap requires explicit acknowledgement', 'no error raised');
EXCEPTION WHEN SQLSTATE 'PD449' THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  PERFORM test.ok(true, 'buffer-only overlap requires explicit acknowledgement');
  PERFORM test.is((v_detail::jsonb -> 'conflicts' -> 0) - 'booking_id',
    '{"organization_priest_id": "a8000000-0000-0000-0000-0000000000e1", "starts_at": "2027-06-01T04:30:00+00:00",
      "ends_at": "2027-06-01T05:30:00+00:00", "same_org": true}'::jsonb, 'BUFFER_CONFLICT lists the busy span');
END $$;
SELECT test.is((SELECT count(*) FROM app.calendar_reservations WHERE booking_id = :'a2'), 0::bigint,
  'nothing is reserved until the overlap is acknowledged');
SELECT test.is(test.confirm(:'a2', true) ->> 'buffer_overlap_ack', 'true', 'acknowledged overlap is recorded');
SELECT test.is((SELECT string_agg(event, ',' ORDER BY id) FROM app.booking_events WHERE booking_id = :'a2'),
  'CREATED,CONFIRMED,BUFFER_OVERLAP_ACKNOWLEDGED', 'acknowledgement is in the booking history');
SELECT test.is((SELECT data FROM app.booking_events WHERE booking_id = :'a2' AND event = 'BUFFER_OVERLAP_ACKNOWLEDGED'),
  '{"conflicts": [{"organization_priest_id": "a8000000-0000-0000-0000-0000000000e1",
    "starts_at": "2027-06-01T04:30:00+00:00", "ends_at": "2027-06-01T05:30:00+00:00", "same_org": true}]}'::jsonb,
  'the history keeps the acknowledged span by time only');
SELECT test.throws($$SELECT test.tb('2027-06-01T05:00:00Z', '2027-06-01T06:00:00Z', p_ack => true)$$, '23P01',
  'ceremony overlap is a hard conflict even when acknowledged', 'BOOKING_CONFLICT');
SELECT test.throws($$SELECT test.tb('2027-06-01T06:55:00Z', '2027-06-01T07:30:00Z',
  '{"buffer_before_min": 0, "buffer_after_min": 0}')$$, 'PD449',
  'another booking''s travel time counts too (05:45-06:45 + 30 min after)', 'BUFFER_CONFLICT');
SELECT test.lives($$SELECT test.tb('2027-06-01T08:00:00Z', '2027-06-01T09:00:00Z',
  '{"buffer_before_min": 0, "buffer_after_min": 0}'), test.tb('2027-06-01T09:00:00Z', '2027-06-01T10:00:00Z',
  '{"buffer_before_min": 0, "buffer_after_min": 0}')$$, 'no travel time, touching ceremonies: no conflict');
SELECT test.lives($$SELECT test.tb('2027-06-01T11:00:00Z', '2027-06-01T12:00:00Z'),
  test.tb('2027-06-01T13:00:00Z', '2027-06-01T14:00:00Z')$$,
  'buffers that only touch each other are no conflict (12:00 + 30 = 12:30 = 13:00 - 30)');
SELECT test.is(test.tb('2027-06-01T15:00:00Z', '2027-06-01T15:30:00Z', p_ack => true) ->> 'buffer_overlap_ack', 'false',
  'an acknowledgement without an overlap stores nothing');

SELECT test.ctx('b8000000-0000-0000-0000-000000000001', 'b8000000-0000-0000-0000-0000000000bb');
DO $$
DECLARE v_detail text;
BEGIN
  PERFORM test.tb('2027-06-01T07:00:00Z', '2027-06-01T07:45:00Z');
  PERFORM test.ok(false, 'a buffer overlap across practices needs the acknowledgement too', 'no error raised');
EXCEPTION WHEN SQLSTATE 'PD449' THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  PERFORM test.ok(true, 'a buffer overlap across practices needs the acknowledgement too');
  PERFORM test.is(v_detail::jsonb -> 'conflicts',
    '[{"organization_priest_id": "b8000000-0000-0000-0000-0000000000e3", "starts_at": "2027-06-01T05:45:00+00:00",
       "ends_at": "2027-06-01T06:45:00+00:00", "same_org": false},
      {"organization_priest_id": "b8000000-0000-0000-0000-0000000000e3", "starts_at": "2027-06-01T08:00:00+00:00",
       "ends_at": "2027-06-01T09:00:00+00:00", "same_org": false}]'::jsonb,
    'the other practice''s spans (before and after) come without their booking ids');
END $$;
SELECT test.is(test.tb('2027-06-01T07:00:00Z', '2027-06-01T07:45:00Z', p_ack => true) ->> 'buffer_overlap_ack', 'true',
  'acknowledged across practices');

-- ---------------------------------------------------------------- reschedule (AC-07)
SELECT test.ctx('a8000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-0000000000aa');
SELECT test.tb('2027-06-02T04:30:00Z', '2027-06-02T05:30:00Z') ->> 'id' AS r1 \gset
SELECT test.tb('2027-06-02T08:30:00Z', '2027-06-02T09:30:00Z') ->> 'id' AS r2 \gset
SELECT test.ver(:'r1') AS r1v \gset
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-02T08:00:00Z", "ends_at": "2027-06-02T09:00:00Z"}')$$,
  :'r1'), '23P01', 'reschedule into a conflict is rejected', 'BOOKING_CONFLICT');
SELECT test.ok((SELECT span = '[2027-06-02 04:30+00,2027-06-02 05:30+00)' AND status = 'ACTIVE'
                FROM app.calendar_reservations WHERE booking_id = :'r1')
  AND test.ver(:'r1') = :r1v AND (SELECT starts_at FROM app.bookings WHERE id = :'r1') = '2027-06-02T04:30:00Z',
  'failed reschedule leaves the original reservation');
SELECT test.move(:'r1', '{"starts_at": "2027-06-02T11:00:00Z", "ends_at": "2027-06-02T12:00:00Z"}') AS r1m \gset
SELECT test.ok((:'r1m'::jsonb ->> 'starts_at') = '2027-06-02T11:00:00+00:00' AND (:'r1m'::jsonb ->> 'status') = 'CONFIRMED',
  'reschedule moves a CONFIRMED booking (status stays CONFIRMED)');
SELECT test.is((SELECT string_agg(status || ' ' || lower(span)::text, ', ' ORDER BY lower(span))
                FROM app.calendar_reservations WHERE booking_id = :'r1'),
  'RELEASED 2027-06-02 04:30:00+00, ACTIVE 2027-06-02 11:00:00+00', 'reschedule releases old and holds new');
SELECT test.is((SELECT data FROM app.booking_events WHERE booking_id = :'r1' AND event = 'RESCHEDULED'),
  '{"from": {"local_date": "2027-06-02", "starts_at": "2027-06-02T04:30:00+00:00", "ends_at": "2027-06-02T05:30:00+00:00",
             "organization_priest_ids": ["a8000000-0000-0000-0000-0000000000e1"]},
    "to": {"local_date": "2027-06-02", "starts_at": "2027-06-02T11:00:00+00:00", "ends_at": "2027-06-02T12:00:00+00:00",
           "organization_priest_ids": ["a8000000-0000-0000-0000-0000000000e1"]},
    "reason_code": "CUSTOMER_REQUEST", "released": 1}'::jsonb, 'RESCHEDULED holds times, priests and the reason code');
SELECT test.is(test.tb('2027-06-02T04:30:00Z', '2027-06-02T05:30:00Z') ->> 'status', 'CONFIRMED',
  'the old slot is free for another booking');
SELECT test.is(test.move(:'r1', '{"starts_at": "2027-06-02T20:00:00Z", "ends_at": "2027-06-02T21:00:00Z"}',
  'CORRECTION') ->> 'local_date', '2027-06-03', 'local_date follows the new start (01:30 IST next day)');

SELECT test.throws(format($$SELECT app.reschedule_booking(%L, %s, '{"starts_at": "2027-06-04T04:30:00Z",
  "ends_at": "2027-06-04T05:30:00Z"}', NULL, false, 'k-noreason-01', repeat('a', 64))$$, :'r1', test.ver(:'r1')),
  'PD422', 'a reschedule needs a reason code', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-04T04:30:00Z", "ends_at": "2027-06-04T05:30:00Z"}',
  'LATE')$$, :'r1'), 'PD422', 'only the listed reason codes', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-04T04:30:00Z", "ends_at": "2027-06-04T05:30:00Z",
  "reason": "Sharma ji ki beti ki shaadi"}')$$, :'r1'), 'PD422',
  'free-text reasons cannot enter the append-only history (reason_code only)', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT test.move(%L, '{"title": "x"}')$$, :'r1'), 'PD422',
  'only schedule fields move with a reschedule', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": null, "ends_at": null}')$$, :'r1'), 'PD422',
  'a confirmed booking keeps a time', 'TIME_REQUIRED');
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-02T20:00:00Z", "ends_at": "2027-06-02T21:00:00Z"}')$$,
  :'r1'), 'PD422', 'a reschedule must change something', 'NOTHING_TO_CHANGE');
SELECT test.throws(format($$SELECT app.reschedule_booking(%L, 1, '{"starts_at": "2027-06-04T04:30:00Z",
  "ends_at": "2027-06-04T05:30:00Z"}', 'OTHER', false, 'k-stale-001', repeat('a', 64))$$, :'r1'), 'PD409',
  'stale version is rejected', 'VERSION_CONFLICT');
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-04T04:30:00Z", "ends_at": "2027-06-04T05:30:00Z"}')$$,
  test.tb('2027-06-05T04:30:00Z', '2027-06-05T05:30:00Z', p_confirm => false) ->> 'id'), 'PD410',
  'a DRAFT is not rescheduled (edit it instead)', 'INVALID_TRANSITION');
SELECT test.tb('2026-01-02T04:30:00Z', '2026-01-02T05:30:00Z') ->> 'id' AS old \gset
SELECT app.complete_booking(:'old', test.ver(:'old'), 'k-complete-08', repeat('a', 64)) IS NOT NULL AS done \gset
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-04T04:30:00Z", "ends_at": "2027-06-04T05:30:00Z"}')$$,
  :'old'), 'PD410', 'a COMPLETED booking cannot be rescheduled', 'INVALID_TRANSITION');

-- The acknowledgement belongs to one schedule only.
SELECT test.tb('2027-06-06T04:30:00Z', '2027-06-06T05:30:00Z') ->> 'id' AS n1 \gset
SELECT test.tb('2027-06-06T05:45:00Z', '2027-06-06T06:30:00Z', p_ack => true) ->> 'id' AS n2 \gset
SELECT test.tb('2027-06-06T10:00:00Z', '2027-06-06T11:00:00Z') ->> 'id' AS n3 \gset
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-06T11:10:00Z", "ends_at": "2027-06-06T11:40:00Z"}')$$,
  :'n2'), 'PD449', 'reschedule resets the acknowledgement: a new overlap must be acknowledged again', 'BUFFER_CONFLICT');
SELECT test.is(test.move(:'n2', '{"starts_at": "2027-06-06T07:30:00Z", "ends_at": "2027-06-06T08:00:00Z"}')
  ->> 'buffer_overlap_ack', 'false', 'moved clear of every buffer: no acknowledgement any more');
SELECT test.is(test.move(:'n2', '{"starts_at": "2027-06-06T11:10:00Z", "ends_at": "2027-06-06T11:40:00Z"}', 'OTHER', true)
  ->> 'buffer_overlap_ack', 'true', 'a reschedule with a new acknowledgement');

-- Tentative window -> exact muhurat; change of priest.
SELECT test.tb('2027-06-07T03:30:00Z', '2027-06-07T07:30:00Z', '{"is_time_tentative": true}') ->> 'id' AS w \gset
SELECT test.ok((test.move(:'w', '{"starts_at": "2027-06-07T04:30:00Z", "ends_at": "2027-06-07T05:30:00Z",
  "is_time_tentative": false}', 'MUHURAT_FIXED') ->> 'is_time_tentative')::boolean = false,
  'a tentative window becomes the exact muhurat');
SELECT test.move(:'w', '{"priest_ids": ["a8000000-0000-0000-0000-0000000000e2"]}', 'PRIEST_CHANGED') AS wp \gset
SELECT test.is(:'wp'::jsonb -> 'priests' -> 0 ->> 'organization_priest_id', 'a8000000-0000-0000-0000-0000000000e2',
  'reschedule can change the priest');
SELECT test.is((SELECT string_agg(status, ',' ORDER BY status) FROM app.calendar_reservations
                WHERE booking_id = :'w' AND organization_priest_id = 'a8000000-0000-0000-0000-0000000000e2'), 'ACTIVE',
  'the new priest is reserved');
SELECT test.is((SELECT count(*) FROM app.calendar_reservations WHERE booking_id = :'w' AND status = 'ACTIVE'
                AND organization_priest_id = 'a8000000-0000-0000-0000-0000000000e1'), 0::bigint,
  'the old priest is free again');
SELECT test.throws(format($$SELECT test.move(%L, '{"priest_ids": []}')$$, :'w'), 'PD422',
  'a confirmed booking keeps a LEAD', 'LEAD_REQUIRED');

-- Permissions: PRIEST only his own bookings, and he keeps leading them; STAFF never.
SELECT test.ctx('a8000000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-08T04:30:00Z", "ends_at": "2027-06-08T05:30:00Z"}')$$,
  :'r2'), 'PD403', 'PRIEST cannot reschedule another priest''s booking', 'FORBIDDEN');
SELECT test.is(test.move(:'w', '{"starts_at": "2027-06-08T04:30:00Z", "ends_at": "2027-06-08T05:30:00Z"}',
  'PRIEST_REQUEST') ->> 'local_date', '2027-06-08', 'PRIEST reschedules a booking he leads');
SELECT test.throws(format($$SELECT test.move(%L, '{"priest_ids": ["a8000000-0000-0000-0000-0000000000e1"]}', 'PRIEST_CHANGED')$$,
  :'w'), 'PD403', 'PRIEST cannot hand his booking to another priest', 'FORBIDDEN');
SELECT test.ctx('a8000000-0000-0000-0000-000000000003', 'a8000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format($$SELECT test.move(%L, '{"starts_at": "2027-06-09T04:30:00Z", "ends_at": "2027-06-09T05:30:00Z"}')$$,
  :'w'), 'PD403', 'STAFF cannot reschedule', 'FORBIDDEN');
SELECT test.ctx('b8000000-0000-0000-0000-000000000001', 'b8000000-0000-0000-0000-0000000000bb');
SELECT test.throws(format($$SELECT app.reschedule_booking(%L, 1, '{"starts_at": "2027-06-09T04:30:00Z",
  "ends_at": "2027-06-09T05:30:00Z"}', 'OTHER', false, 'k-foreign-01', repeat('a', 64))$$, :'w'), 'PD404',
  'another practice''s booking is not found', 'NOT_FOUND');

-- Idempotency.
SELECT test.ctx('a8000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-0000000000aa');
SELECT test.ver(:'r2') AS r2v \gset
SELECT app.reschedule_booking(:'r2', :r2v, '{"starts_at": "2027-06-10T04:30:00Z", "ends_at": "2027-06-10T05:30:00Z"}',
  'OTHER', false, 'resched-key-01', repeat('c', 64)) AS m1 \gset
SELECT app.reschedule_booking(:'r2', :r2v, '{"starts_at": "2027-06-10T04:30:00Z", "ends_at": "2027-06-10T05:30:00Z"}',
  'OTHER', false, 'resched-key-01', repeat('c', 64)) AS m2 \gset
SELECT test.ok((:'m2'::jsonb ->> 'idempotent_replay')::boolean
  AND (:'m2'::jsonb -> 'booking' ->> 'version') = (:'m1'::jsonb -> 'booking' ->> 'version'),
  'a retried reschedule replays the first result');
SELECT test.is((SELECT count(*) FROM app.booking_events WHERE booking_id = :'r2' AND event = 'RESCHEDULED'), 1::bigint,
  'and is recorded once');

SELECT test.ok(NOT EXISTS (SELECT 1 FROM app.booking_events e WHERE e.event IN ('RESCHEDULED', 'BUFFER_OVERLAP_ACKNOWLEDGED')
  AND e.data::text ~ 'reason"|title|location|notes|Customer'), 'no free text in the new history entries');
SELECT test.lives($$SELECT test.invariants()$$, 'every booking above satisfies the deferred invariants');

ROLLBACK;
