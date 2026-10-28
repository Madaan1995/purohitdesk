-- Operator script (STAGING): revoke a member's access to a practice. Takes effect on their next request.
-- 1. Edit the three values below.  2. Run the whole script in the Supabase SQL editor (as postgres).
-- Same FORCE-lift technique as add_member.sql (restored before the transaction ends; rolled back on any error).
DO $$
DECLARE
  v_owner_email   text := 'owner@example.com';   -- the practice owner's Google e-mail
  v_practice_name text := 'Practice name';       -- exactly as shown on the home page
  v_member_email  text := 'member@example.com';  -- the person to revoke
  v_org_id        uuid;
BEGIN
  ALTER TABLE app.organizations NO FORCE ROW LEVEL SECURITY;
  ALTER TABLE app.org_members NO FORCE ROW LEVEL SECURITY;

  SELECT o.id INTO STRICT v_org_id
  FROM app.organizations o JOIN auth.users u ON u.id = o.created_by
  WHERE lower(u.email) = lower(v_owner_email) AND o.name = v_practice_name AND o.status = 'ACTIVE';

  UPDATE app.org_members m
  SET status = 'REVOKED'
  FROM auth.users u
  WHERE m.org_id = v_org_id AND m.user_id = u.id AND lower(u.email) = lower(v_member_email)
    AND m.role <> 'OWNER' AND m.status = 'ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no ACTIVE non-owner membership for that e-mail in this practice; nothing changed';
  END IF;

  ALTER TABLE app.org_members FORCE ROW LEVEL SECURITY;
  ALTER TABLE app.organizations FORCE ROW LEVEL SECURITY;
  RAISE NOTICE 'revoked % from practice %', v_member_email, v_org_id;
EXCEPTION
  WHEN no_data_found THEN RAISE EXCEPTION 'practice not found (check the owner e-mail and the practice name)';
  WHEN too_many_rows THEN RAISE EXCEPTION 'that owner has more than one practice with this name';
END
$$;

-- Must show force_rls_restored = true for both tables.
SELECT c.relname AS "table", c.relforcerowsecurity AS force_rls_restored
FROM pg_catalog.pg_class c
WHERE c.relnamespace = 'app'::regnamespace AND c.relname IN ('organizations', 'org_members');
