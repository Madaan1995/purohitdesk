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
INSERT INTO app.customers (id, org_id, display_name) VALUES
  ('c0000000-0000-0000-0000-0000000000c1', '$OA', 'Race Customer A'),
  ('c0000000-0000-0000-0000-0000000000c2', '$OB', 'Race Customer B');
INSERT INTO app.offerings (id, org_id, name_hi, name_en, duration_min) VALUES
  ('c0000000-0000-0000-0000-0000000000d1', '$OA', 'हवन', 'Havan', 60),
  ('c0000000-0000-0000-0000-0000000000d2', '$OB', 'हवन', 'Havan', 60);
SQL

# fields <practice A|B> <start> <end> [extra json]: create_booking fields for P in that practice.
fields() {
  local c=c0000000-0000-0000-0000-0000000000c1 o=c0000000-0000-0000-0000-0000000000d1 l=$LA
  if [ "$1" = B ]; then c=c0000000-0000-0000-0000-0000000000c2; o=c0000000-0000-0000-0000-0000000000d2; l=$LB; fi
  echo "{\"customer_id\": \"$c\", \"offering_id\": \"$o\", \"starts_at\": \"$2\", \"ends_at\": \"$3\",
         \"buffer_before_min\": 0, \"buffer_after_min\": 0, \"priest_ids\": [\"$l\"]${4:-}}"
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

DUP="SELECT app.create_booking('$(fields A "2028-01-06T04:30:00Z" "2028-01-06T05:30:00Z" ', "title": "dup race"')',
  false, false, 'race-dup-key', repeat('b', 64)) ->> 'idempotent_replay';"
race "same Idempotency-Key sent twice concurrently -> one booking, one replay" "$DUP" COMMIT "$UA" "$OA" "$DUP" '^true$'

count="$(psql -X -At -d "$DB" -c "SELECT count(*) FROM app.bookings WHERE title = 'dup race'")"
[ "$count" = 1 ]
check "exactly one 'dup race' booking stored" $? "count=$count"

overlaps="$(psql -X -At -d "$DB" -c "
  SELECT count(*) FROM app.calendar_reservations r1 JOIN app.calendar_reservations r2
    ON r1.priest_profile_id = r2.priest_profile_id AND r1.id < r2.id AND r1.span && r2.span
  WHERE r1.status = 'ACTIVE' AND r2.status = 'ACTIVE'")"
[ "$overlaps" = 0 ]
check "zero overlapping ACTIVE reservations in the whole database" $? "overlaps=$overlaps"

confirmed="$(psql -X -At -d "$DB" -c "
  SELECT count(*) FROM app.bookings b JOIN app.calendar_reservations r ON r.booking_id = b.id AND r.status = 'ACTIVE'
  WHERE b.org_id IN ('$OA', '$OB') AND b.status = 'CONFIRMED'")"
[ "$confirmed" = 4 ]
check "four confirmed race bookings hold exactly one ACTIVE reservation each" $? "confirmed=$confirmed"

echo "concurrency: $((n - fails)) passed, $fails failed"
[ "$fails" -eq 0 ]
