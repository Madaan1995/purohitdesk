-- M8 calendar blocks and free/busy (spec §05 §8, §05 §4, §08 §3; §14 §5.1 file 04: blocks).
-- Fixtures: practice A (OWNER ua with profile pa, link la; PRIEST up with profile pp, link lp; STAFF us; READ_ONLY ur);
-- practice B (OWNER ub) where pa is also linked (lab); practice C (OWNER ub) where ua is no member. Times are UTC.
BEGIN;
SET LOCAL TIME ZONE 'UTC';

INSERT INTO auth.users (id, email) VALUES
  ('a9000000-0000-0000-0000-000000000001', 'ua9@example.test'),
  ('a9000000-0000-0000-0000-000000000002', 'up9@example.test'),
  ('a9000000-0000-0000-0000-000000000003', 'us9@example.test'),
  ('a9000000-0000-0000-0000-000000000004', 'ur9@example.test'),
  ('b9000000-0000-0000-0000-000000000001', 'ub9@example.test');
INSERT INTO app.app_users (id, auth_user_id) SELECT id, id FROM auth.users WHERE email LIKE 'u_9@example.test';
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('a9000000-0000-0000-0000-0000000000aa', 'A9', 'a9', 'a9000000-0000-0000-0000-000000000001'),
  ('b9000000-0000-0000-0000-0000000000bb', 'B9', 'b9', 'b9000000-0000-0000-0000-000000000001'),
  ('c9000000-0000-0000-0000-0000000000cc', 'C9', 'c9', 'b9000000-0000-0000-0000-000000000001');
INSERT INTO app.org_sequences (org_id) VALUES ('a9000000-0000-0000-0000-0000000000aa'),
  ('b9000000-0000-0000-0000-0000000000bb'), ('c9000000-0000-0000-0000-0000000000cc');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('a9000000-0000-0000-0000-0000000000aa', 'a9000000-0000-0000-0000-000000000001', 'OWNER'),
  ('a9000000-0000-0000-0000-0000000000aa', 'a9000000-0000-0000-0000-000000000002', 'PRIEST'),
  ('a9000000-0000-0000-0000-0000000000aa', 'a9000000-0000-0000-0000-000000000003', 'STAFF'),
  ('a9000000-0000-0000-0000-0000000000aa', 'a9000000-0000-0000-0000-000000000004', 'READ_ONLY'),
  ('b9000000-0000-0000-0000-0000000000bb', 'b9000000-0000-0000-0000-000000000001', 'OWNER'),
  ('c9000000-0000-0000-0000-0000000000cc', 'b9000000-0000-0000-0000-000000000001', 'OWNER');
INSERT INTO app.priest_profiles (id, user_id, display_name) VALUES
  ('a9000000-0000-0000-0000-0000000000f1', 'a9000000-0000-0000-0000-000000000001', 'Pandit A9'),
  ('a9000000-0000-0000-0000-0000000000f2', 'a9000000-0000-0000-0000-000000000002', 'Pandit P9');
INSERT INTO app.organization_priests (id, org_id, priest_profile_id, linked_via) VALUES
  ('a9000000-0000-0000-0000-0000000000e1', 'a9000000-0000-0000-0000-0000000000aa', 'a9000000-0000-0000-0000-0000000000f1', 'BOOTSTRAP'),
  ('a9000000-0000-0000-0000-0000000000e2', 'a9000000-0000-0000-0000-0000000000aa', 'a9000000-0000-0000-0000-0000000000f2', 'BOOTSTRAP'),
  ('b9000000-0000-0000-0000-0000000000e3', 'b9000000-0000-0000-0000-0000000000bb', 'a9000000-0000-0000-0000-0000000000f1', 'INVITATION');
INSERT INTO app.customers (id, org_id, display_name) VALUES
  ('a9000000-0000-0000-0000-0000000000c1', 'a9000000-0000-0000-0000-0000000000aa', 'Customer A9'),
  ('b9000000-0000-0000-0000-0000000000c1', 'b9000000-0000-0000-0000-0000000000bb', 'Customer B9');
INSERT INTO app.offerings (id, org_id, name_hi, name_en, duration_min) VALUES
  ('a9000000-0000-0000-0000-0000000000d1', 'a9000000-0000-0000-0000-0000000000aa', 'हवन', 'Havan', 60),
  ('b9000000-0000-0000-0000-0000000000d1', 'b9000000-0000-0000-0000-0000000000bb', 'हवन', 'Havan', 60);

CREATE FUNCTION test.block(p_link uuid, p_start text, p_end text, p_note text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.create_block(p_link, p_start::timestamptz, p_end::timestamptz, p_note, 'k-' || gen_random_uuid(),
                          repeat('a', 64)) -> 'block' $$;
CREATE FUNCTION test.release(p_id uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT app.release_block(p_id, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'block' $$;
CREATE FUNCTION test.tb(p_start text, p_end text, p jsonb DEFAULT '{}', p_ack boolean DEFAULT false) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT app.create_booking(
    CASE WHEN app.current_tenant_id() = 'b9000000-0000-0000-0000-0000000000bb'
         THEN '{"customer_id": "b9000000-0000-0000-0000-0000000000c1", "offering_id": "b9000000-0000-0000-0000-0000000000d1",
                "priest_ids": ["b9000000-0000-0000-0000-0000000000e3"]}'::jsonb
         ELSE '{"customer_id": "a9000000-0000-0000-0000-0000000000c1", "offering_id": "a9000000-0000-0000-0000-0000000000d1",
                "priest_ids": ["a9000000-0000-0000-0000-0000000000e1"]}'::jsonb END
    || jsonb_build_object('starts_at', p_start, 'ends_at', p_end) || p,
    true, p_ack, 'k-' || gen_random_uuid(), repeat('a', 64)) -> 'booking' $$;
CREATE FUNCTION test.invariants() RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
END $$;

\set la 'a9000000-0000-0000-0000-0000000000e1'
\set lp 'a9000000-0000-0000-0000-0000000000e2'
\set lab 'b9000000-0000-0000-0000-0000000000e3'

SET ROLE app_runtime;
SELECT test.ctx('a9000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-0000000000aa');

-- ---------------------------------------------------------------- blocks (14:00-16:00 IST = 08:30-10:30 UTC)
SELECT test.block(:'la', '2027-09-01T08:30:00Z', '2027-09-01T10:30:00Z', '  Doctor visit ') AS b1 \gset
SELECT (:'b1'::jsonb ->> 'id') AS b1id \gset
SELECT test.ok((:'b1'::jsonb ->> 'status') = 'ACTIVE' AND (:'b1'::jsonb ->> 'note') = 'Doctor visit'
  AND (:'b1'::jsonb ->> 'starts_at') = '2027-09-01T08:30:00+00:00', 'OWNER blocks 2-4 pm with a note');
SELECT test.is((SELECT kind || ' ' || (buffer_span = span)::text FROM app.calendar_reservations WHERE id = :'b1id'),
  'BLOCK true', 'a block is a BLOCK reservation without travel time');
RESET ROLE;
SELECT test.is((SELECT data FROM app.audit_log WHERE action = 'BLOCK_CREATED' AND target_id = :'b1id'),
  '{"organization_priest_id": "a9000000-0000-0000-0000-0000000000e1", "starts_at": "2027-09-01T08:30:00+00:00",
    "ends_at": "2027-09-01T10:30:00+00:00"}'::jsonb, 'BLOCK_CREATED audit: ids and times, never the note');
SET ROLE app_runtime;
SELECT test.ctx('a9000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-0000000000aa');
DO $$
DECLARE v_detail text;
BEGIN
  PERFORM test.tb('2027-09-01T09:00:00Z', '2027-09-01T09:30:00Z');
  PERFORM test.ok(false, 'blocked time cannot be booked', 'no error raised');
EXCEPTION WHEN exclusion_violation THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  PERFORM test.ok(true, 'blocked time cannot be booked');
  PERFORM test.is(v_detail::jsonb -> 'conflicts',
    '[{"organization_priest_id": "a9000000-0000-0000-0000-0000000000e1", "starts_at": "2027-09-01T08:30:00+00:00",
       "ends_at": "2027-09-01T10:30:00+00:00", "same_org": true, "block": true}]'::jsonb,
    'the conflict says it is the practice''s own block');
END $$;
SELECT test.throws($$SELECT test.tb('2027-09-01T10:45:00Z', '2027-09-01T11:15:00Z')$$, 'PD449',
  'a booking''s travel time next to a block needs the acknowledgement', 'BUFFER_CONFLICT');
SELECT test.tb('2027-09-02T04:30:00Z', '2027-09-02T05:30:00Z') ->> 'id' AS bk \gset
SELECT test.throws(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-02T05:00:00Z', '2027-09-02T06:00:00Z'),
  '23P01', 'a block over a ceremony is refused', 'BOOKING_CONFLICT');
SELECT test.lives(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-02T05:30:00Z', '2027-09-02T06:00:00Z'),
  'blocks do not check travel time (right after a ceremony)');
SELECT test.throws(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-03T00:00:00Z', '2027-10-04T00:00:01Z'),
  'PD422', 'a block lasts at most 31 days', 'VALIDATION_FAILED');
SELECT test.throws(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-03T05:00:00Z', '2027-09-03T05:00:00Z'),
  'PD422', 'a block must end after it starts', 'VALIDATION_FAILED');
SELECT test.throws(format('SELECT test.block(%L, %L, %L, %L)', :'la', '2027-09-03T05:00:00Z', '2027-09-03T06:00:00Z',
  repeat('x', 501)), 'PD422', 'a block note is at most 500 characters', 'VALIDATION_FAILED');
SELECT test.throws(format('SELECT test.block(%L, %L, %L)', :'lab', '2027-09-03T05:00:00Z', '2027-09-03T06:00:00Z'),
  'PD404', 'another practice''s priest link is not found', 'NOT_FOUND');

SELECT test.release(:'b1id') AS rel1 \gset
SELECT test.is(:'rel1'::jsonb ->> 'status', 'RELEASED', 'release a block');
SELECT test.is(:'rel1'::jsonb ->> 'released_by', 'a9000000-0000-0000-0000-000000000001',
  'the released block says who released it (released_by)');
RESET ROLE;
SELECT test.is((SELECT jsonb_build_object('actor', actor_user_id, 'data', data) FROM app.audit_log
                WHERE action = 'BLOCK_RELEASED' AND target_id = :'b1id'),
  '{"actor": "a9000000-0000-0000-0000-000000000001", "data": {"organization_priest_id":
    "a9000000-0000-0000-0000-0000000000e1", "starts_at": "2027-09-01T08:30:00+00:00",
    "ends_at": "2027-09-01T10:30:00+00:00"}}'::jsonb, 'BLOCK_RELEASED audit: actor, ids and times, never the note');
SELECT test.ok(NOT EXISTS (SELECT 1 FROM app.audit_log a, jsonb_each(a.data) d
                           WHERE a.action IN ('BLOCK_CREATED', 'BLOCK_RELEASED')
                             AND d.key NOT IN ('organization_priest_id', 'starts_at', 'ends_at')),
  'block audit rows hold only the priest link id and the times');
SET ROLE app_runtime;
SELECT test.ctx('a9000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-0000000000aa');
SELECT test.is((SELECT status || ' ' || (released_at IS NOT NULL)::text FROM app.calendar_reservations WHERE id = :'b1id'),
  'RELEASED true', 'the released block stays as history');
SELECT test.is(test.tb('2027-09-01T09:00:00Z', '2027-09-01T09:30:00Z', '{"buffer_before_min": 0, "buffer_after_min": 0}')
  ->> 'status', 'CONFIRMED', 'released block frees the time');
SELECT test.throws(format('SELECT test.release(%L)', :'b1id'), 'PD410', 'a block is released once', 'INVALID_TRANSITION');
SELECT test.throws(format('SELECT test.release(%L)', (SELECT id FROM app.calendar_reservations WHERE booking_id = :'bk')),
  'PD404', 'a booking''s reservation is not a block', 'NOT_FOUND');
SELECT app.create_block(:'la', '2027-09-05T04:30:00Z', '2027-09-05T05:30:00Z', NULL, 'block-key-01', repeat('b', 64)) AS r1 \gset
SELECT app.create_block(:'la', '2027-09-05T04:30:00Z', '2027-09-05T05:30:00Z', NULL, 'block-key-01', repeat('b', 64)) AS r2 \gset
SELECT test.ok((:'r2'::jsonb ->> 'idempotent_replay')::boolean
  AND (:'r2'::jsonb -> 'block' ->> 'id') = (:'r1'::jsonb -> 'block' ->> 'id'), 'a retried block replays the first one');

-- Block over block (r1 = 04:30-05:30 on 5 Sep): BOOKING_CONFLICT with details, never the bare exclusion constraint.
DO $$
DECLARE v_detail text; v_msg text;
BEGIN
  PERFORM test.block('a9000000-0000-0000-0000-0000000000e1', '2027-09-05T05:00:00Z', '2027-09-05T06:00:00Z');
  PERFORM test.ok(false, 'a block over the practice''s own block is refused', 'no error raised');
EXCEPTION WHEN exclusion_violation THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL, v_msg = MESSAGE_TEXT;
  PERFORM test.is(v_msg, 'BOOKING_CONFLICT', 'a block over the practice''s own block is refused as BOOKING_CONFLICT');
  PERFORM test.is(v_detail::jsonb -> 'conflicts',
    '[{"organization_priest_id": "a9000000-0000-0000-0000-0000000000e1", "starts_at": "2027-09-05T04:30:00+00:00",
       "ends_at": "2027-09-05T05:30:00+00:00", "same_org": true, "block": true}]'::jsonb,
    'block over block: the conflict lists the existing block ("time is blocked")');
END $$;
SELECT test.is((SELECT count(*) FROM app.calendar_reservations
                WHERE organization_priest_id = :'la' AND status = 'ACTIVE'
                  AND span && tstzrange('2027-09-05T04:00:00Z', '2027-09-05T07:00:00Z')), 1::bigint,
  'the refused block wrote nothing');
SELECT test.lives(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-05T05:30:00Z', '2027-09-05T06:00:00Z'),
  'a block may start exactly when another block ends');
SELECT test.ctx('b9000000-0000-0000-0000-000000000001', 'b9000000-0000-0000-0000-0000000000bb');
DO $$
DECLARE v_detail text; v_msg text;
BEGIN
  PERFORM test.block('b9000000-0000-0000-0000-0000000000e3', '2027-09-05T05:00:00Z', '2027-09-05T05:15:00Z');
  PERFORM test.ok(false, 'a block over another practice''s block is refused', 'no error raised');
EXCEPTION WHEN exclusion_violation THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL, v_msg = MESSAGE_TEXT;
  PERFORM test.is(v_msg, 'BOOKING_CONFLICT', 'a block over another practice''s block is refused as BOOKING_CONFLICT');
  PERFORM test.is(v_detail::jsonb -> 'conflicts',
    '[{"organization_priest_id": "b9000000-0000-0000-0000-0000000000e3", "starts_at": "2027-09-05T04:30:00+00:00",
       "ends_at": "2027-09-05T05:30:00+00:00", "same_org": false}]'::jsonb,
    'block over another practice''s block: busy time only, no block flag, no ids');
END $$;
SELECT test.ctx('a9000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-0000000000aa');

-- ---------------------------------------------------------------- free/busy across practices
SELECT test.ctx('b9000000-0000-0000-0000-000000000001', 'b9000000-0000-0000-0000-0000000000bb');
SELECT test.block(:'lab', '2027-09-04T04:30:00Z', '2027-09-04T05:30:00Z', 'private matter') ->> 'id' AS bb \gset
SELECT test.tb('2027-09-04T08:00:00Z', '2027-09-04T09:00:00Z') ->> 'id' AS bbook \gset
SELECT test.ctx('a9000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-0000000000aa');
SELECT test.is((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.starts_at) FROM app.priest_busy(:'la', '2027-09-04T00:00:00Z',
  '2027-09-05T00:00:00Z') x),
  '[{"reservation_id": null, "kind": "BUSY", "starts_at": "2027-09-04T04:30:00+00:00", "ends_at": "2027-09-04T05:30:00+00:00",
     "same_org": false, "booking_id": null},
    {"reservation_id": null, "kind": "BUSY", "starts_at": "2027-09-04T08:00:00+00:00", "ends_at": "2027-09-04T09:00:00+00:00",
     "same_org": false, "booking_id": null}]'::jsonb,
  'another practice''s block and booking appear as BUSY without ids or details');
SELECT test.ok((SELECT bool_and(x.reservation_id IS NOT NULL AND x.same_org
                                AND (x.kind = 'BLOCK' OR (x.kind = 'BOOKING' AND x.booking_id IS NOT NULL)))
                FROM app.priest_busy(:'la', '2027-09-01T00:00:00Z', '2027-09-03T00:00:00Z') x)
  AND (SELECT count(*) FROM app.priest_busy(:'la', '2027-09-01T00:00:00Z', '2027-09-03T00:00:00Z')) = 3,
  'own bookings and blocks come with their ids; the released block is gone');
SELECT test.throws($$SELECT test.tb('2027-09-04T05:00:00Z', '2027-09-04T05:15:00Z', '{"buffer_before_min": 0,
  "buffer_after_min": 0}')$$, '23P01', 'a block in practice B stops a booking of the same priest in practice A',
  'BOOKING_CONFLICT');
SELECT test.throws(format($$SELECT * FROM app.priest_busy(%L, '2027-09-01T00:00:00Z', '2027-11-02T00:00:01Z')$$, :'la'),
  'PD422', 'availability covers at most 62 days', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT * FROM app.priest_busy(%L, '2027-09-02T00:00:00Z', '2027-09-01T00:00:00Z')$$, :'la'),
  'PD422', 'availability needs from before to', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT * FROM app.priest_busy(%L, '2027-09-01T00:00:00Z', '2027-09-02T00:00:00Z')$$, :'lab'),
  'PD404', 'free/busy only for priests of this practice', 'NOT_FOUND');
SELECT test.ctx('a9000000-0000-0000-0000-000000000001', 'c9000000-0000-0000-0000-0000000000cc');
SELECT test.throws(format($$SELECT * FROM app.priest_busy(%L, '2027-09-01T00:00:00Z', '2027-09-02T00:00:00Z')$$, :'la'),
  'PD404', 'forged tenant header: free/busy answers 404', 'NOT_FOUND');
SELECT test.throws(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-06T05:00:00Z', '2027-09-06T06:00:00Z'),
  'PD404', 'forged tenant header: blocks answer 404', 'NOT_FOUND');

-- ---------------------------------------------------------------- permissions
SELECT test.ctx('a9000000-0000-0000-0000-000000000002', 'a9000000-0000-0000-0000-0000000000aa');
SELECT test.block(:'lp', '2027-09-07T04:30:00Z', '2027-09-07T05:30:00Z') ->> 'id' AS pblock \gset
SELECT test.ok(:'pblock' IS NOT NULL, 'PRIEST blocks his own time');
SELECT test.throws(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-07T04:30:00Z', '2027-09-07T05:30:00Z'),
  'PD403', 'PRIEST cannot block another priest''s time', 'FORBIDDEN');
SELECT test.throws(format('SELECT test.release(%L)', (:'r1'::jsonb -> 'block' ->> 'id')), 'PD403',
  'PRIEST cannot release another priest''s block', 'FORBIDDEN');
SELECT test.is(test.release(:'pblock') ->> 'status', 'RELEASED', 'PRIEST releases his own block');
SELECT test.ctx('a9000000-0000-0000-0000-000000000003', 'a9000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-08T04:30:00Z', '2027-09-08T05:30:00Z'),
  'PD403', 'STAFF cannot block time', 'FORBIDDEN');
SELECT test.ctx('a9000000-0000-0000-0000-000000000004', 'a9000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format('SELECT test.block(%L, %L, %L)', :'la', '2027-09-08T04:30:00Z', '2027-09-08T05:30:00Z'),
  'PD403', 'READ_ONLY cannot block time', 'FORBIDDEN');
SELECT test.throws(format('SELECT test.release(%L)', (:'r1'::jsonb -> 'block' ->> 'id')), 'PD403',
  'READ_ONLY cannot release a block', 'FORBIDDEN');
SELECT test.ok((SELECT count(*) FROM app.priest_busy(:'la', '2027-09-01T00:00:00Z', '2027-09-30T00:00:00Z')) > 0,
  'READ_ONLY sees free/busy (ORG_READ)');
SELECT test.is((SELECT count(*) FROM app.calendar_reservations WHERE org_id <> app.current_tenant_id()), 0::bigint,
  'the practice''s own reservation rows (with notes) are the only ones readable directly');
RESET ROLE;
SELECT test.lives($$SELECT test.invariants()$$, 'every booking above satisfies the deferred invariants');

ROLLBACK;
