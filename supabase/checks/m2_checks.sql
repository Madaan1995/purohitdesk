-- M2 verification: run in the Supabase SQL editor after applying the M2 migration.
-- Returns one row per check; every row must say PASS (or NO DATA, see below).
--
-- Row-level security is checked AS THE APPLICATION ROLES: Supabase's postgres has BYPASSRLS, so rows read as yourself
-- prove nothing. The DO block becomes each application role in turn (SET ROLE). For that it grants you the roles
-- WITH INHERIT FALSE (SET ROLE only, none of their privileges) and revokes them before it ends; nothing else is
-- written, and any error rolls the whole script back. A row-level check says NO DATA while there are no rows (or no
-- ACTIVE member) to test with: run the script again once there are.
DO $$
DECLARE
  -- The M2 tables, and the rows app_runtime may see when acting for member $1 in practice $2 (the policies
  -- of 20261028210000_m2_auth_onboarding.sql, evaluated here without RLS; NULL: app_runtime cannot read the table).
  v_tables  text[] := ARRAY['app.offerings', 'app.org_sequences', 'app.idempotency_keys'];
  v_expect  text[] := ARRAY[
    'org_id = $2',
    NULL,
    NULL];
  v_roles   text[];
  v_granted text[] := '{}';
  v_role    text;
  v_actor   uuid;
  v_org     uuid;
  v_total   bigint := 0;
  v_n       bigint;
  v_want    bigint;
  v_open    text[] := '{}';
  v_forged  text[] := '{}';
  v_member  text[] := '{}';
BEGIN
  FOR i IN 1 .. cardinality(v_tables) LOOP
    EXECUTE pg_catalog.format('SELECT count(*) FROM %s', v_tables[i]) INTO v_n;
    v_total := v_total + v_n;
  END LOOP;
  SELECT m.user_id, m.org_id INTO v_actor, v_org
  FROM app.org_members m JOIN app.organizations o ON o.id = m.org_id
  WHERE m.status = 'ACTIVE' AND o.status = 'ACTIVE'
  ORDER BY m.created_at, m.id
  LIMIT 1;

  -- Every application role that can read one of the tables. app_operator is left out: its read policies admit every
  -- row by design (only the operator commands, executable by postgres alone, run as it).
  SELECT pg_catalog.array_agg(r.rolname ORDER BY r.rolname) INTO v_roles
  FROM pg_catalog.pg_roles r
  WHERE r.rolname IN ('app_runtime', 'app_domain', 'app_authz', 'app_bootstrap', 'app_freebusy', 'app_maintenance')
    AND EXISTS (SELECT 1 FROM pg_catalog.unnest(v_tables) AS t (name)
                WHERE pg_catalog.has_table_privilege(r.oid, t.name, 'SELECT'));
  FOREACH v_role IN ARRAY coalesce(v_roles, '{}') LOOP
    IF NOT pg_catalog.pg_has_role(SESSION_USER, v_role, 'SET') THEN
      EXECUTE pg_catalog.format('GRANT %I TO SESSION_USER WITH INHERIT FALSE', v_role);
      v_granted := v_granted || v_role;
    END IF;
  END LOOP;

  -- 1. No request context, and 2. an actor who is no member, in a real practice: no row at all, for every role.
  FOR pass IN 1 .. 2 LOOP
    PERFORM pg_catalog.set_config('app.actor_user_id', CASE WHEN pass = 2 THEN gen_random_uuid()::text ELSE '' END, true),
            pg_catalog.set_config('app.tenant_id',
              CASE WHEN pass = 2 THEN coalesce(v_org, gen_random_uuid())::text ELSE '' END, true);
    FOREACH v_role IN ARRAY coalesce(v_roles, '{}') LOOP
      EXECUTE pg_catalog.format('SET LOCAL ROLE %I', v_role);
      FOR i IN 1 .. cardinality(v_tables) LOOP
        IF pg_catalog.has_table_privilege(v_role, v_tables[i], 'SELECT') THEN
          EXECUTE pg_catalog.format('SELECT count(*) FROM %s', v_tables[i]) INTO v_n;
          IF v_n > 0 AND pass = 1 THEN v_open := v_open || (v_role || ' ' || v_tables[i]); END IF;
          IF v_n > 0 AND pass = 2 THEN v_forged := v_forged || (v_role || ' ' || v_tables[i]); END IF;
        END IF;
      END LOOP;
      RESET ROLE;
    END LOOP;
  END LOOP;

  -- 3. app_runtime acting for a real ACTIVE member sees exactly the rows its policies allow.
  IF v_actor IS NOT NULL AND 'app_runtime' = ANY (coalesce(v_roles, '{}')) THEN
    PERFORM pg_catalog.set_config('app.actor_user_id', v_actor::text, true),
            pg_catalog.set_config('app.tenant_id', v_org::text, true);
    FOR i IN 1 .. cardinality(v_tables) LOOP
      CONTINUE WHEN v_expect[i] IS NULL;
      EXECUTE pg_catalog.format('SELECT count(*) FROM %s WHERE %s', v_tables[i], v_expect[i])
        INTO v_want USING v_actor, v_org;
      SET LOCAL ROLE app_runtime;
      EXECUTE pg_catalog.format('SELECT count(*) FROM %s', v_tables[i]) INTO v_n;
      RESET ROLE;
      IF v_n <> v_want THEN v_member := v_member || (v_tables[i] || ' ' || v_n || '/' || v_want); END IF;
    END LOOP;
  END IF;

  PERFORM pg_catalog.set_config('app.actor_user_id', '', true), pg_catalog.set_config('app.tenant_id', '', true);
  FOREACH v_role IN ARRAY v_granted LOOP
    EXECUTE pg_catalog.format('REVOKE %I FROM SESSION_USER', v_role);
  END LOOP;

  PERFORM pg_catalog.set_config('pd_checks.m2_rls', pg_catalog.jsonb_build_object(
    'no_context', CASE WHEN v_total = 0 THEN 'NO DATA' WHEN cardinality(v_open) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'no_context_seen', pg_catalog.array_to_string(v_open, ', '),
    'forged', CASE WHEN v_total = 0 THEN 'NO DATA' WHEN cardinality(v_forged) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'forged_seen', pg_catalog.array_to_string(v_forged, ', '),
    'member', CASE WHEN v_actor IS NULL THEN 'NO DATA' WHEN cardinality(v_member) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'member_seen', pg_catalog.array_to_string(v_member, ', '))::text, false);
END
$$;

WITH app_tables AS (
  SELECT c.oid, c.relname, c.relrowsecurity, c.relforcerowsecurity
  FROM pg_catalog.pg_class c
  WHERE c.relnamespace = 'app'::regnamespace AND c.relkind IN ('r', 'p')
),
app_funcs AS (
  SELECT p.oid, p.oid::regprocedure::text AS signature, p.prosecdef, p.proconfig, p.proowner, p.proacl
  FROM pg_catalog.pg_proc p
  WHERE p.pronamespace = 'app'::regnamespace
),
app_roles AS (
  SELECT r.oid, r.rolname FROM pg_catalog.pg_roles r
  WHERE r.rolname IN ('app_runtime', 'app_domain', 'app_authz', 'app_bootstrap', 'app_freebusy', 'app_maintenance',
                      'app_operator')
),
owners AS (
  SELECT f.signature, o.rolname AS owner FROM app_funcs f JOIN pg_catalog.pg_roles o ON o.oid = f.proowner
),
checks (n, check_name, ok) AS (
  VALUES
  (1, 'M2 tables exist with RLS enabled and forced (offerings, org_sequences, idempotency_keys)',
    (SELECT count(*) FROM app_tables
     WHERE relname IN ('offerings', 'org_sequences', 'idempotency_keys') AND relrowsecurity AND relforcerowsecurity) = 3),
  (2, 'ensure_current_user and bootstrap_practice are owned by app_bootstrap',
    (SELECT count(*) FROM owners WHERE owner = 'app_bootstrap'
       AND signature IN ('app.ensure_current_user(text,text)', 'app.bootstrap_practice(text,uuid[],text,text)')) = 2),
  (3, 'update_my_profile is owned by app_domain',
    EXISTS (SELECT 1 FROM owners WHERE owner = 'app_domain' AND signature = 'app.update_my_profile(text,text)')),
  (4, 'app_runtime may execute the three M2 commands',
    pg_catalog.has_function_privilege('app_runtime', 'app.ensure_current_user(text,text)', 'EXECUTE')
    AND pg_catalog.has_function_privilege('app_runtime', 'app.update_my_profile(text,text)', 'EXECUTE')
    AND pg_catalog.has_function_privilege('app_runtime', 'app.bootstrap_practice(text,uuid[],text,text)', 'EXECUTE')),
  (5, 'app_runtime cannot execute internal helpers (_idem_begin, _idem_finish, _slugify, _ops_practice)',
    NOT pg_catalog.has_function_privilege('app_runtime', 'app._idem_begin(text,text,text)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('app_runtime', 'app._idem_finish(text,jsonb)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('app_runtime', 'app._slugify(text)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('app_runtime', 'app._ops_practice(uuid,text)', 'EXECUTE')),
  (6, 'app_runtime has no privilege on idempotency_keys or org_sequences',
    NOT pg_catalog.has_table_privilege('app_runtime', 'app.idempotency_keys', 'SELECT, INSERT, UPDATE, DELETE')
    AND NOT pg_catalog.has_table_privilege('app_runtime', 'app.org_sequences', 'SELECT, INSERT, UPDATE, DELETE')),
  (7, 'no application role can read auth.users (first login is proven by the app_users foreign key)',
    NOT EXISTS (SELECT 1 FROM app_roles r
                WHERE pg_catalog.has_table_privilege(r.oid, 'auth.users', 'SELECT, INSERT, UPDATE, DELETE')
                   OR pg_catalog.has_any_column_privilege(r.oid, 'auth.users', 'SELECT, INSERT, UPDATE'))),
  (8, 'no app function is executable by PUBLIC',
    NOT EXISTS (SELECT 1 FROM app_funcs f
                WHERE f.proacl IS NULL
                   OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(f.proacl) a
                              WHERE a.grantee = 0::oid AND a.privilege_type = 'EXECUTE'))),
  (9, 'SECURITY DEFINER functions pin search_path and have NOLOGIN, non-BYPASSRLS owners',
    NOT EXISTS (SELECT 1 FROM app_funcs f JOIN pg_catalog.pg_roles o ON o.oid = f.proowner
                WHERE f.prosecdef
                  AND (NOT ('search_path=""' = ANY (coalesce(f.proconfig, '{}'::text[])))
                       OR o.rolcanlogin OR o.rolbypassrls OR o.rolsuper))),
  (10, 'app_runtime has no INSERT/UPDATE/DELETE/TRUNCATE on any app table',
    NOT EXISTS (SELECT 1 FROM app_tables t
                WHERE pg_catalog.has_table_privilege('app_runtime', t.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
                   OR pg_catalog.has_any_column_privilege('app_runtime', t.oid, 'INSERT, UPDATE'))),
  (11, 'RLS enabled on every app table and no policy applies to PUBLIC',
    NOT EXISTS (SELECT 1 FROM app_tables WHERE NOT relrowsecurity)
    AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN app_tables t ON t.oid = pol.polrelid
                    WHERE 0::oid = ANY (pol.polroles))),
  (12, 'ops_add_member and ops_revoke_member are owned by app_operator',
    (SELECT count(*) FROM owners WHERE owner = 'app_operator'
       AND signature IN ('app.ops_add_member(uuid,text,uuid,text)', 'app.ops_revoke_member(uuid,text,uuid)')) = 2),
  (13, 'only the migration user (you) may execute the operator commands; no application role can',
    pg_catalog.has_function_privilege(CURRENT_USER, 'app.ops_add_member(uuid,text,uuid,text)', 'EXECUTE')
    AND pg_catalog.has_function_privilege(CURRENT_USER, 'app.ops_revoke_member(uuid,text,uuid)', 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM app_roles r
                    WHERE r.rolname <> 'app_operator'
                      AND (pg_catalog.has_function_privilege(r.oid, 'app.ops_add_member(uuid,text,uuid,text)', 'EXECUTE')
                           OR pg_catalog.has_function_privilege(r.oid, 'app.ops_revoke_member(uuid,text,uuid)',
                                                                'EXECUTE')))),
  (14, 'the migration user (you) is not a member of any application role',
    (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = CURRENT_USER)
    OR NOT EXISTS (SELECT 1 FROM app_roles r
                   WHERE pg_catalog.pg_has_role(CURRENT_USER, r.oid, 'USAGE')
                      OR CASE WHEN pg_catalog.current_setting('server_version_num')::int >= 160000
                              THEN pg_catalog.pg_has_role(CURRENT_USER, r.oid, 'SET')
                              ELSE pg_catalog.pg_has_role(CURRENT_USER, r.oid, 'MEMBER') END))
),
rls AS (
  -- FAIL, not an empty result, if the DO block above did not run in this session.
  SELECT coalesce(nullif(pg_catalog.current_setting('pd_checks.m2_rls', true), ''), '{}')::jsonb AS r
),
rls_checks (n, check_name, result) AS (
  SELECT 15, 'RLS as the application roles, no request context: no row of the M2 tables is visible'
             || coalesce(' (seen: ' || nullif(r ->> 'no_context_seen', '') || ')', ''),
         coalesce(r ->> 'no_context', 'FAIL') FROM rls
  UNION ALL
  SELECT 16, 'RLS as the application roles, an actor who is no member in a real practice: no row is visible'
             || coalesce(' (seen: ' || nullif(r ->> 'forged_seen', '') || ')', ''),
         coalesce(r ->> 'forged', 'FAIL') FROM rls
  UNION ALL
  SELECT 17, 'RLS as app_runtime for a real ACTIVE member: exactly the rows the policies allow'
             || coalesce(' (seen/allowed: ' || nullif(r ->> 'member_seen', '') || ')', ''),
         coalesce(r ->> 'member', 'FAIL') FROM rls
)
SELECT n, check_name AS "check", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
UNION ALL
SELECT n, check_name, result FROM rls_checks
ORDER BY n;
