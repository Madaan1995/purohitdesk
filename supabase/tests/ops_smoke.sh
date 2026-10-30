#!/usr/bin/env bash
# Runs the operator scripts in supabase/ops against the throwaway database logged in as pd_migrator (like postgres in
# the Supabase SQL editor: no SUPERUSER, BYPASSRLS), with their placeholder values replaced. Called by run.sh, which
# exports DB and MIGRATOR_PASSWORD; prints ok/not ok lines.
# The functions themselves are tested in 03_ops_members.sql; this checks the script files as the founder runs them.
set -uo pipefail
DB="${DB:-pd_test}"
n=0
fails=0
out=""
check() { # check "<name>" "<sql returning t/f>"
  n=$((n + 1))
  if [ "$(psql -X -At -d "$DB" -c "$2")" = "t" ]; then echo "ok $n - $1"; else echo "not ok $n - $1"; fails=$((fails + 1)); fi
}
run_ops() { # run_ops <script> <member e-mail> [role]; leaves the script's output (or error) in $out
  out="$(sed -e "s/owner@example.com/ops-owner@example.test/" \
             -e "s/'Practice name'/'Ops Practice'/" \
             -e "s/member@example.com/$2/" \
             -e "s/'STAFF'\( *-- ADMIN\)/'${3:-STAFF}'\1/" "supabase/ops/$1" |
         PGUSER=pd_migrator PGPASSWORD="$MIGRATOR_PASSWORD" psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" 2>&1)"
}

psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
INSERT INTO auth.users (id, email) VALUES
  ('0f000000-0000-0000-0000-000000000001', 'ops-owner@example.test'),
  ('0f000000-0000-0000-0000-000000000002', 'ops-member@example.test'),
  ('0f000000-0000-0000-0000-000000000003', 'ops-never-signed-in@example.test');
INSERT INTO app.app_users (id, auth_user_id) VALUES
  ('0f000000-0000-0000-0000-000000000001', '0f000000-0000-0000-0000-000000000001'),
  ('0f000000-0000-0000-0000-000000000002', '0f000000-0000-0000-0000-000000000002');
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('0f000000-0000-0000-0000-0000000000a1', 'Ops Practice', 'ops-practice', '0f000000-0000-0000-0000-000000000001');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('0f000000-0000-0000-0000-0000000000a1', '0f000000-0000-0000-0000-000000000001', 'OWNER');
SQL

MEMBER="SELECT role || ':' || status FROM app.org_members WHERE user_id = '0f000000-0000-0000-0000-000000000002'"
OWNER="SELECT role || ':' || status FROM app.org_members WHERE user_id = '0f000000-0000-0000-0000-000000000001'"
no_email() { # the script output never shows an e-mail
  n=$((n + 1))
  if [ -n "$out" ] && ! echo "$out" | grep -q '@'; then echo "ok $n - $1"; else echo "not ok $n - $1"; fails=$((fails + 1)); fi
}

run_ops add_member.sql ops-member@example.test STAFF
check "add_member.sql adds the member as STAFF" "SELECT ($MEMBER) = 'STAFF:ACTIVE'"
no_email "add_member.sql output shows no e-mail"
run_ops add_member.sql ops-member@example.test READ_ONLY
check "add_member.sql changes an existing member's role" "SELECT ($MEMBER) = 'READ_ONLY:ACTIVE'"
run_ops add_member.sql ops-owner@example.test STAFF
check "add_member.sql refuses to touch the OWNER" "SELECT ($OWNER) = 'OWNER:ACTIVE'"
no_email "add_member.sql error output shows no e-mail"
run_ops add_member.sql ops-never-signed-in@example.test STAFF
check "add_member.sql refuses someone who never signed in" \
  "SELECT NOT EXISTS (SELECT 1 FROM app.org_members WHERE user_id = '0f000000-0000-0000-0000-000000000003')"
run_ops revoke_member.sql ops-member@example.test
check "revoke_member.sql revokes the member" "SELECT ($MEMBER) = 'READ_ONLY:REVOKED'"
no_email "revoke_member.sql output shows no e-mail"
run_ops revoke_member.sql ops-owner@example.test
check "revoke_member.sql never revokes the OWNER" "SELECT ($OWNER) = 'OWNER:ACTIVE'"

echo "ops: $((n - fails)) passed, $fails failed"
[ "$fails" -eq 0 ]
