#!/usr/bin/env bash
# Two real sessions racing on the throwaway database (spec §05 §2, §05 §9, §14 §5.2). Called by run.sh after the SQL
# tests; prints ok/not ok lines. Each session is a separate psql connection that becomes app_runtime (SET ROLE) with
# the request context set transaction-locally, exactly as withTenantTx does, and really COMMITs, so the deferred
# invariant triggers run too.
#
# One human (priest profile P) serves two practices: A (link LA) and B (link LB). Session 1 confirms P in A and holds
# its transaction open for HOLD seconds; session 2 starts 0.3 s later and confirms P in B at an overlapping time.
set -uo pipefail
DB="${DB:-pd_test}"
HOLD=1.5
n=0
fails=0

UA=c0000000-0000-0000-0000-000000000001
UB=c0000000-0000-0000-0000-000000000002
OA=c0000000-0000-0000-0000-0000000000aa
OB=c0000000-0000-0000-0000-0000000000bb
LA=c0000000-0000-0000-0000-0000000000e1
LB=c0000000-0000-0000-0000-0000000000e2
PP=c0000000-0000-0000-0000-0000000000f1
UQ=c0000000-0000-0000-0000-000000000003
PQ=c0000000-0000-0000-0000-0000000000f3
LQA=c0000000-0000-0000-0000-0000000000e3
LQB=c0000000-0000-0000-0000-0000000000e4

psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<SQL
INSERT INTO auth.users (id, email) VALUES ('$UA', 'race-a@example.test'), ('$UB', 'race-b@example.test');
INSERT INTO app.app_users (id, auth_user_id) VALUES ('$UA', '$UA'), ('$UB', '$UB');
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('$OA', 'Race A', 'race-a', '$UA'), ('$OB', 'Race B', 'race-b', '$UB');
INSERT INTO app.org_sequences (org_id) VALUES ('$OA'), ('$OB');
INSERT INTO app.org_members (org_id, user_id, role) VALUES ('$OA', '$UA', 'OWNER'), ('$OB', '$UB', 'OWNER');
INSERT INTO app.priest_profiles (id, user_id, display_name)
  VALUES ('c0000000-0000-0000-0000-0000000000f1', '$UA', 'Race Pandit');
INSERT INTO app.organization_priests (id, org_id, priest_profile_id, linked_via) VALUES
  ('$LA', '$OA', 'c0000000-0000-0000-0000-0000000000f1', 'BOOTSTRAP'),
  ('$LB', '$OB', 'c0000000-0000-0000-0000-0000000000f1', 'INVITATION');
-- A second human Q, also serving both practices (multi-priest races).
INSERT INTO auth.users (id, email) VALUES ('$UQ', 'race-q@example.test');
INSERT INTO app.app_users (id, auth_user_id) VALUES ('$UQ', '$UQ');
INSERT INTO app.priest_profiles (id, user_id, display_name) VALUES ('$PQ', '$UQ', 'Race Pandit Q');
INSERT INTO app.organization_priests (id, org_id, priest_profile_id, linked_via) VALUES
  ('$LQA', '$OA', '$PQ', 'INVITATION'), ('$LQB', '$OB', '$PQ', 'INVITATION');
INSERT INTO app.customers (id, org_id, display_name) VALUES
  ('c0000000-0000-0000-0000-0000000000c1', '$OA', 'Race Customer A'),
  ('c0000000-0000-0000-0000-0000000000c2', '$OB', 'Race Customer B');
INSERT INTO app.offerings (id, org_id, name_hi, name_en, duration_min) VALUES
  ('c0000000-0000-0000-0000-0000000000d1', '$OA', 'हवन', 'Havan', 60),
  ('c0000000-0000-0000-0000-0000000000d2', '$OB', 'हवन', 'Havan', 60);
SQL

# fields <practice A|B> <start> <end> [extra json] [priest_ids json]: create_booking fields for that practice
# (default priest: P's link there).
fields() {
  local c=c0000000-0000-0000-0000-0000000000c1 o=c0000000-0000-0000-0000-0000000000d1 l="[\"$LA\"]"
  if [ "$1" = B ]; then c=c0000000-0000-0000-0000-0000000000c2; o=c0000000-0000-0000-0000-0000000000d2; l="[\"$LB\"]"; fi
  echo "{\"customer_id\": \"$c\", \"offering_id\": \"$o\", \"starts_at\": \"$2\", \"ends_at\": \"$3\",
         \"buffer_before_min\": 0, \"buffer_after_min\": 0, \"priest_ids\": ${5:-$l}${4:-}}"
}

# session <actor> <tenant> <sql> <hold seconds> <COMMIT|ROLLBACK>: prints the query result or the error.
session() {
  psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" 2>&1 <<SQL
BEGIN;
SET ROLE app_runtime;
SELECT set_config('app.actor_user_id', '$1', true), set_config('app.tenant_id', '$2', true) \g /dev/null
$3
SELECT pg_sleep($4) \g /dev/null
$5;
SQL
}

check() { # check <name> <condition exit status> <detail>
  n=$((n + 1))
  if [ "$2" -eq 0 ]; then echo "ok $n - $1 | $3"; else echo "not ok $n - $1 # $3"; fails=$((fails + 1)); fi
}

# race <name> <sql 1> <end 1> <actor 2> <tenant 2> <sql 2> <expected pattern in session 2's output>
race() {
  local s1 out2 t0 t1 waited
  s1="$(mktemp)"
  session "$UA" "$OA" "$2" "$HOLD" "$3" > "$s1" &
  sleep 0.3
  t0=$(date +%s.%N)
  out2="$(session "$4" "$5" "$6" 0 COMMIT)"
  t1=$(date +%s.%N)
  wait
  waited=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  echo "$out2" | grep -q -- "$7"
  local matched=$?
  awk -v w="$waited" 'BEGIN { exit !(w >= 0.9) }'
  local blocked=$?
  check "$1" $((matched + blocked)) "session 2 waited ${waited}s | $(echo "$out2" | head -c 120 | tr '\n' ' ')"
  rm -f "$s1"
}

CONFIRM="SELECT app.create_booking('%s', true, false, '%s', repeat('a', 64)) -> 'booking' ->> 'status';"
for run in 1 2 3; do
  d="2028-01-0${run}"
  race "cross-org same priest, overlapping, run $run" \
    "$(printf "$CONFIRM" "$(fields A "${d}T04:30:00Z" "${d}T06:30:00Z")" "race-a-$run")" COMMIT \
    "$UB" "$OB" "$(printf "$CONFIRM" "$(fields B "${d}T05:30:00Z" "${d}T07:00:00Z")" "race-b-$run")" \
    'ERROR:  BOOKING_CONFLICT'
done

race "first session rolls back -> second confirms" \
  "$(printf "$CONFIRM" "$(fields A "2028-01-05T04:30:00Z" "2028-01-05T06:30:00Z")" "race-a-rb")" ROLLBACK \
  "$UB" "$OB" "$(printf "$CONFIRM" "$(fields B "2028-01-05T05:30:00Z" "2028-01-05T07:00:00Z")" "race-b-rb")" \
  '^CONFIRMED$'

BUF=', "buffer_before_min": 30, "buffer_after_min": 30'
race "buffer-only overlap is evaluated after the first commit (advisory lock)" \
  "$(printf "$CONFIRM" "$(fields A "2028-01-07T04:30:00Z" "2028-01-07T05:30:00Z" "$BUF")" "race-a-buf")" COMMIT \
  "$UB" "$OB" "$(printf "$CONFIRM" "$(fields B "2028-01-07T05:45:00Z" "2028-01-07T06:30:00Z" "$BUF")" "race-b-buf")" \
  'ERROR:  BUFFER_CONFLICT'

DUP="SELECT app.create_booking('$(fields A "2028-01-06T04:30:00Z" "2028-01-06T05:30:00Z" ', "title": "dup race"')',
  false, false, 'race-dup-key', repeat('b', 64)) ->> 'idempotent_replay';"
race "same Idempotency-Key sent twice concurrently -> one booking, one replay" "$DUP" COMMIT "$UA" "$OA" "$DUP" '^true$'

# ---------------------------------------------------------------- M7: reschedule races
# confirmed <actor> <tenant> <fields> <key>: commits a confirmed booking, prints its id.
confirmed() { session "$1" "$2" "$(printf "$CONFIRM_ID" "$3" "$4")" 0 COMMIT; }
CONFIRM_ID="SELECT app.create_booking('%s', true, false, '%s', repeat('a', 64)) -> 'booking' ->> 'id';"
# reschedule sql: <booking id> <changes json> <key>; the expected version is read in the same transaction.
RESCHED="SELECT app.reschedule_booking('%s', (SELECT version FROM app.bookings WHERE id = '%s'), '%s',
  'CUSTOMER_REQUEST', false, '%s', repeat('a', 64)) -> 'booking' ->> 'status';"
resched() { printf "$RESCHED" "$1" "$1" "$2" "$3"; }
# slot_kept <booking id> <start> <end>: the booking is still CONFIRMED at that time and holds exactly that ACTIVE span.
slot_kept() {
  psql -X -At -d "$DB" -c "
    SELECT b.status = 'CONFIRMED' AND b.starts_at = '$2' AND b.ends_at = '$3'
       AND (SELECT count(*) FROM app.calendar_reservations r WHERE r.booking_id = b.id AND r.status = 'ACTIVE'
              AND r.span = tstzrange('$2', '$3', '[)')) = 1
       AND (SELECT count(*) FROM app.calendar_reservations r WHERE r.booking_id = b.id AND r.status = 'ACTIVE') = 1
    FROM app.bookings b WHERE b.id = '$1'"
}

X="$(confirmed "$UA" "$OA" "$(fields A "2028-02-01T01:00:00Z" "2028-02-01T02:00:00Z")" race-pre-x)"
race "reschedule (A) holds the slot -> concurrent confirm (B) waits, then BOOKING_CONFLICT" \
  "$(resched "$X" '{"starts_at": "2028-02-01T04:30:00Z", "ends_at": "2028-02-01T06:30:00Z"}' race-x-move)" COMMIT \
  "$UB" "$OB" "$(printf "$CONFIRM" "$(fields B "2028-02-01T05:30:00Z" "2028-02-01T07:00:00Z")" race-b-x)" \
  'ERROR:  BOOKING_CONFLICT'
[ "$(slot_kept "$X" 2028-02-01T04:30:00Z 2028-02-01T06:30:00Z)" = t ]
check "the rescheduled booking holds only its new slot" $? "booking=$X"

Z="$(confirmed "$UB" "$OB" "$(fields B "2028-02-02T01:00:00Z" "2028-02-02T02:00:00Z")" race-pre-z)"
race "confirm (A) holds the slot -> concurrent reschedule (B) into it waits, then BOOKING_CONFLICT" \
  "$(printf "$CONFIRM" "$(fields A "2028-02-02T04:30:00Z" "2028-02-02T06:30:00Z")" race-a-z)" COMMIT \
  "$UB" "$OB" "$(resched "$Z" '{"starts_at": "2028-02-02T05:30:00Z", "ends_at": "2028-02-02T07:00:00Z"}' race-z-move)" \
  'ERROR:  BOOKING_CONFLICT'
[ "$(slot_kept "$Z" 2028-02-02T01:00:00Z 2028-02-02T02:00:00Z)" = t ]
check "the refused reschedule left its booking and original slot untouched" $? "booking=$Z"

W="$(confirmed "$UB" "$OB" "$(fields B "2028-02-03T01:00:00Z" "2028-02-03T02:00:00Z" "$BUF")" race-pre-w)"
race "reschedule (B) into a buffer-only overlap with a concurrent confirm (A) waits, then BUFFER_CONFLICT" \
  "$(printf "$CONFIRM" "$(fields A "2028-02-03T04:30:00Z" "2028-02-03T05:30:00Z" "$BUF")" race-a-w)" COMMIT \
  "$UB" "$OB" "$(resched "$W" '{"starts_at": "2028-02-03T05:45:00Z", "ends_at": "2028-02-03T06:30:00Z"}' race-w-move)" \
  'ERROR:  BUFFER_CONFLICT'
[ "$(slot_kept "$W" 2028-02-03T01:00:00Z 2028-02-03T02:00:00Z)" = t ]
check "the buffer-refused reschedule left its booking and original slot untouched" $? "booking=$W"

# ---------------------------------------------------------------- M7: multi-priest bookings, overlapping priest sets
# P and Q serve both practices. A lists [P, Q], B lists [Q, P]: the per-priest locks are taken in profile order
# whatever the list order, so the two transactions never deadlock.
race "multi-priest [P,Q] (A) vs [Q,P] (B), overlapping: second waits, then BOOKING_CONFLICT (no deadlock)" \
  "$(printf "$CONFIRM" "$(fields A "2028-02-04T04:30:00Z" "2028-02-04T06:30:00Z" "" "[\"$LA\", \"$LQA\"]")" race-mp-a)" COMMIT \
  "$UB" "$OB" "$(printf "$CONFIRM" "$(fields B "2028-02-04T05:30:00Z" "2028-02-04T07:00:00Z" "" "[\"$LQB\", \"$LB\"]")" race-mp-b)" \
  'ERROR:  BOOKING_CONFLICT'

# Both sessions start at the same moment, five times: exactly one confirms, the other gets BOOKING_CONFLICT, never a
# deadlock (40P01).
for run in 1 2 3 4 5; do
  d="2028-02-1${run}"
  o1="$(mktemp)"; o2="$(mktemp)"
  session "$UA" "$OA" "$(printf "$CONFIRM" "$(fields A "${d}T04:30:00Z" "${d}T06:30:00Z" "" "[\"$LA\", \"$LQA\"]")" "race-sim-a-$run")" 0 COMMIT > "$o1" &
  session "$UB" "$OB" "$(printf "$CONFIRM" "$(fields B "${d}T05:00:00Z" "${d}T07:00:00Z" "" "[\"$LQB\", \"$LB\"]")" "race-sim-b-$run")" 0 COMMIT > "$o2" &
  wait
  ok1=$(grep -c '^CONFIRMED$' "$o1" "$o2" | awk -F: '{s += $2} END {print s}')
  bad=$(cat "$o1" "$o2" | grep -c 'deadlock' || true)
  conf=$(cat "$o1" "$o2" | grep -c 'ERROR:  BOOKING_CONFLICT' || true)
  [ "$ok1" = 1 ] && [ "$conf" = 1 ] && [ "$bad" = 0 ]
  check "multi-priest [P,Q] vs [Q,P] started together, run $run: one CONFIRMED, one BOOKING_CONFLICT, no deadlock" $? \
    "confirmed=$ok1 conflicts=$conf deadlocks=$bad"
  rm -f "$o1" "$o2"
done

# Lock order, deterministically: a third session holds the lower profile's lock; B confirms [Q, P] (higher profile
# listed first). B must wait on the lower lock WITHOUT holding the higher one, so a probe can still take it.
read -r LOW HIGH <<<"$(printf '%s\n%s\n' "$PP" "$PQ" | sort | tr '\n' ' ')"
lock_sql() { echo "SELECT pg_advisory_xact_lock(hashtextextended('priest:' || '$1', 0));"; }
holder="$(mktemp)"; waiter="$(mktemp)"
psql -X -q -At -d "$DB" > "$holder" 2>&1 <<SQL &
BEGIN;
$(lock_sql "$LOW") \g /dev/null
SELECT pg_sleep(2) \g /dev/null
COMMIT;
SQL
sleep 0.3
session "$UB" "$OB" "$(printf "$CONFIRM" "$(fields B "2028-02-20T04:30:00Z" "2028-02-20T05:30:00Z" "" "[\"$LQB\", \"$LB\"]")" race-order)" 0 COMMIT > "$waiter" &
sleep 0.7
probe="$(psql -X -q -At -d "$DB" -c "SELECT pg_try_advisory_xact_lock(hashtextextended('priest:' || '$HIGH', 0))")"
wait
[ "$probe" = t ] && grep -q '^CONFIRMED$' "$waiter"
check "per-priest locks are taken in profile order: a waiter on the lower lock does not hold the higher one" $? \
  "probe higher lock free=$probe | waiter: $(head -c 60 "$waiter")"
rm -f "$holder" "$waiter"

# ---------------------------------------------------------------- M8: calendar blocks (same per-priest lock)
# block sql: <priest link> <start> <end> <key>
BLOCK="SELECT app.create_block('%s', '%s', '%s', NULL, '%s', repeat('a', 64)) -> 'block' ->> 'status';"

race "block (A) holds the time -> concurrent booking (B) waits, then BOOKING_CONFLICT" \
  "$(printf "$BLOCK" "$LA" "2028-03-01T04:30:00Z" "2028-03-01T06:30:00Z" race-blk-1a)" COMMIT \
  "$UB" "$OB" "$(printf "$CONFIRM" "$(fields B "2028-03-01T05:30:00Z" "2028-03-01T07:00:00Z")" race-blk-1b)" \
  'ERROR:  BOOKING_CONFLICT'

race "booking (A) holds the time -> concurrent block (B) waits, then BOOKING_CONFLICT" \
  "$(printf "$CONFIRM" "$(fields A "2028-03-02T04:30:00Z" "2028-03-02T06:30:00Z")" race-blk-2a)" COMMIT \
  "$UB" "$OB" "$(printf "$BLOCK" "$LB" "2028-03-02T05:00:00Z" "2028-03-02T05:30:00Z" race-blk-2b)" \
  'ERROR:  BOOKING_CONFLICT'

race "block (A) vs block (B), overlapping: second waits, then BOOKING_CONFLICT (not the bare constraint)" \
  "$(printf "$BLOCK" "$LA" "2028-03-03T04:30:00Z" "2028-03-03T06:30:00Z" race-blk-3a)" COMMIT \
  "$UB" "$OB" "$(printf "$BLOCK" "$LB" "2028-03-03T05:00:00Z" "2028-03-03T07:00:00Z" race-blk-3b)" \
  'ERROR:  BOOKING_CONFLICT'

race "block vs block in the same practice: second waits, then BOOKING_CONFLICT naming the block" \
  "$(printf "$BLOCK" "$LA" "2028-03-04T04:30:00Z" "2028-03-04T06:30:00Z" race-blk-4a)" COMMIT \
  "$UA" "$OA" "$(printf "$BLOCK" "$LA" "2028-03-04T05:00:00Z" "2028-03-04T07:00:00Z" race-blk-4b)" \
  '"block": true'

blocks="$(psql -X -At -d "$DB" -c "
  SELECT count(*) FROM app.calendar_reservations
  WHERE kind = 'BLOCK' AND status = 'ACTIVE' AND org_id IN ('$OA', '$OB') AND lower(span) >= '2028-03-01'")"
[ "$blocks" = 3 ]
check "exactly the three winning blocks are stored" $? "blocks=$blocks"

count="$(psql -X -At -d "$DB" -c "SELECT count(*) FROM app.bookings WHERE title = 'dup race'")"
[ "$count" = 1 ]
check "exactly one 'dup race' booking stored" $? "count=$count"

overlaps="$(psql -X -At -d "$DB" -c "
  SELECT count(*) FROM app.calendar_reservations r1 JOIN app.calendar_reservations r2
    ON r1.priest_profile_id = r2.priest_profile_id AND r1.id < r2.id AND r1.span && r2.span
  WHERE r1.status = 'ACTIVE' AND r2.status = 'ACTIVE'")"
[ "$overlaps" = 0 ]
check "zero overlapping ACTIVE reservations in the whole database" $? "overlaps=$overlaps"

bad="$(psql -X -At -d "$DB" -c "
  SELECT count(*) FROM app.bookings b
  WHERE b.org_id IN ('$OA', '$OB')
    AND (SELECT count(*) FROM app.calendar_reservations r WHERE r.booking_id = b.id AND r.status = 'ACTIVE')
        <> CASE WHEN b.status IN ('CONFIRMED', 'COMPLETED')
                THEN (SELECT count(*) FROM app.booking_assignments a WHERE a.booking_id = b.id) ELSE 0 END")"
confirmed="$(psql -X -At -d "$DB" -c "
  SELECT count(*) FROM app.bookings b WHERE b.org_id IN ('$OA', '$OB') AND b.status = 'CONFIRMED'")"
[ "$bad" = 0 ] && [ "$confirmed" = 18 ]
check "18 confirmed race bookings, each holding exactly one ACTIVE reservation per assigned priest" $? \
  "confirmed=$confirmed mismatched=$bad"

echo "concurrency: $((n - fails)) passed, $fails failed"
[ "$fails" -eq 0 ]
