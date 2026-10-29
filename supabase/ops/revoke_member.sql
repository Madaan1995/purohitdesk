-- Operator script (STAGING): revoke a member's access to a practice. Takes effect on their next request.
-- 1. Edit the three values below.  2. Run the whole script in the Supabase SQL editor (as postgres).
--
-- One call to app.ops_revoke_member (owner app_operator, executable only by postgres). It never revokes the OWNER and
-- never changes row-level security. The result shows ids, role and status only.
SELECT app.ops_revoke_member(
  (SELECT id FROM auth.users WHERE lower(email) = lower('owner@example.com')),   -- the practice owner's Google e-mail
  'Practice name',                                                               -- exactly as shown on the home page
  (SELECT id FROM auth.users WHERE lower(email) = lower('member@example.com'))   -- the person to revoke
) AS result;
