-- Operator script (STAGING): add an existing user to a practice with a non-owner role, or change their role.
-- The person must have signed in to PurohitDesk once (so their app user exists).
-- 1. Edit the four values below.  2. Run the whole script in the Supabase SQL editor (as postgres).
--
-- One call to app.ops_add_member (owner app_operator, executable only by postgres). It never touches the OWNER and
-- never changes row-level security. The result shows ids, role and status only.
SELECT app.ops_add_member(
  (SELECT id FROM auth.users WHERE lower(email) = lower('owner@example.com')),   -- the practice owner's Google e-mail
  'Practice name',                                                               -- exactly as shown on the home page
  (SELECT id FROM auth.users WHERE lower(email) = lower('member@example.com')),  -- the person to add (Google e-mail)
  'STAFF'                                                                        -- ADMIN, STAFF or READ_ONLY
) AS result;
