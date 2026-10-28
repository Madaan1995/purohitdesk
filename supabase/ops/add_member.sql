-- Operator script (STAGING): add an existing user to a practice with a non-owner role.
-- The person must have signed in to PurohitDesk once (so their app user exists).
-- 1. Edit the four values below.  2. Run the whole script in the Supabase SQL editor (as postgres).
--
-- org_members has FORCE ROW LEVEL SECURITY. This script lifts FORCE on two tables for the length of its own
-- transaction (only the table owner can) and restores it before the transaction ends. If anything fails, the whole
-- script rolls back, FORCE included.
DO $$
DECLARE
  v_owner_email   text := 'owner@example.com';   -- the practice owner's Google e-mail
  v_practice_name text := 'Practice name';       -- exactly as shown on the home page
  v_member_email  text := 'member@example.com';  -- the person to add (Google e-mail)
  v_role          text := 'STAFF';               -- ADMIN, STAFF or READ_ONLY
  v_org_id        uuid;
  v_member_id     uuid;
BEGIN
  IF v_role NOT IN ('ADMIN', 'STAFF', 'READ_ONLY') THEN
    RAISE EXCEPTION 'role must be ADMIN, STAFF or READ_ONLY (PRIEST needs a priest link and is not supported here)';
  END IF;

  ALTER TABLE app.organizations NO FORCE ROW LEVEL SECURITY;
  ALTER TABLE app.org_members NO FORCE ROW LEVEL SECURITY;

  SELECT o.id INTO STRICT v_org_id
  FROM app.organizations o JOIN auth.users u ON u.id = o.created_by
  WHERE lower(u.email) = lower(v_owner_email) AND o.name = v_practice_name AND o.status = 'ACTIVE';

  SELECT u.id INTO STRICT v_member_id FROM auth.users u WHERE lower(u.email) = lower(v_member_email);

  INSERT INTO app.org_members (org_id, user_id, role, status)
  VALUES (v_org_id, v_member_id, v_role, 'ACTIVE')
  ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role, status = 'ACTIVE'
  WHERE app.org_members.role <> 'OWNER';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'that person is the OWNER of this practice; nothing changed';
  END IF;

  ALTER TABLE app.org_members FORCE ROW LEVEL SECURITY;
  ALTER TABLE app.organizations FORCE ROW LEVEL SECURITY;
  RAISE NOTICE 'added % to practice % as %', v_member_email, v_org_id, v_role;
EXCEPTION
  WHEN no_data_found THEN RAISE EXCEPTION 'practice or member not found (check the e-mails and the practice name)';
  WHEN too_many_rows THEN RAISE EXCEPTION 'that owner has more than one practice with this name';
  WHEN foreign_key_violation THEN RAISE EXCEPTION 'the member has not signed in to PurohitDesk yet';
END
$$;

-- Must show force_rls_restored = true for both tables.
SELECT c.relname AS "table", c.relforcerowsecurity AS force_rls_restored
FROM pg_catalog.pg_class c
WHERE c.relnamespace = 'app'::regnamespace AND c.relname IN ('organizations', 'org_members');
