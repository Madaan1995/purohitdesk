#!/usr/bin/env bash
# Runs the operator scripts in supabase/ops against the throwaway database as pd_migrator (the table owner, no
# SUPERUSER, no BYPASSRLS), with their placeholder values replaced. Called by run.sh; prints ok/not ok lines.
set -uo pipefail
DB=pd_test
n=0
fails=0
check() { # check "<name>" "<sql returning t/f>"
  n=$((n + 1))
  if [ "$(psql -X -At -d "$DB" -c "$2")" = "t" ]; then echo "ok $n - $1"; else echo "not ok $n - $1"; fails=$((fails + 1)); fi
}
run_ops() { # run_ops <script> <member e-mail> [role]
  sed -e "s/owner@example.com/ops-owner@example.test/" \
      -e "s/'Practice name'/'Ops Practice'/" \
      -e "s/member@example.com/$2/" \
      -e "s/'STAFF';               -- ADMIN/'${3:-STAFF}';               -- ADMIN/" "supabase/ops/$1" |
    PGOPTIONS="-c role=pd_migrator" psql -X -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null 2>&1
}

psql -X -q -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
INSERT INTO auth.users (id, email) VALUES
  ('0e000000-0000-0000-0000-000000000001', 'ops-owner@example.test'),
  ('0e000000-0000-0000-0000-000000000002', 'ops-member@example.test'),
  ('0e000000-0000-0000-0000-000000000003', 'ops-never-signed-in@example.test');
INSERT INTO app.app_users (id, auth_user_id) VALUES
  ('0e000000-0000-0000-0000-000000000001', '0e000000-0000-0000-0000-000000000001'),
  ('0e000000-0000-0000-0000-000000000002', '0e000000-0000-0000-0000-000000000002');
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('0e000000-0000-0000-0000-0000000000a1', 'Ops Practice', 'ops-practice', '0e000000-0000-0000-0000-000000000001');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('0e000000-0000-0000-0000-0000000000a1', '0e000000-0000-0000-0000-000000000001', 'OWNER');
SQL

FORCED="SELECT bool_and(relforcerowsecurity) FROM pg_class WHERE relnamespace = 'app'::regnamespace AND relname IN ('organizations', 'org_members')"
MEMBER="SELECT role || ':' || status FROM app.org_members WHERE user_id = '0e000000-0000-0000-0000-000000000002'"

run_ops add_member.sql ops-member@example.test STAFF
check "add_member.sql adds the member as STAFF" "SELECT ($MEMBER) = 'STAFF:ACTIVE'"
check "add_member.sql restores FORCE RLS" "$FORCED"
run_ops add_member.sql ops-member@example.test READ_ONLY
check "add_member.sql changes an existing member's role" "SELECT ($MEMBER) = 'READ_ONLY:ACTIVE'"
run_ops add_member.sql ops-owner@example.test STAFF
check "add_member.sql refuses to demote the OWNER" "SELECT role = 'OWNER' FROM app.org_members WHERE user_id = '0e000000-0000-0000-0000-000000000001'"
run_ops add_member.sql ops-member@example.test OWNER
check "add_member.sql refuses the OWNER role" "SELECT ($MEMBER) = 'READ_ONLY:ACTIVE'"
run_ops add_member.sql ops-never-signed-in@example.test STAFF
check "add_member.sql refuses someone who never signed in" "SELECT NOT EXISTS (SELECT 1 FROM app.org_members WHERE user_id = '0e000000-0000-0000-0000-000000000003')"
check "FORCE RLS still on after failed runs" "$FORCED"
run_ops revoke_member.sql ops-member@example.test
check "revoke_member.sql revokes the member" "SELECT ($MEMBER) = 'READ_ONLY:REVOKED'"
run_ops revoke_member.sql ops-owner@example.test
check "revoke_member.sql never revokes the OWNER" "SELECT status = 'ACTIVE' FROM app.org_members WHERE user_id = '0e000000-0000-0000-0000-000000000001'"
check "revoke_member.sql restores FORCE RLS" "$FORCED"

echo "ops: $((n - fails)) passed, $fails failed"
[ "$fails" -eq 0 ]
