-- M2 verification. Read-only: run in the Supabase SQL editor after applying the M2 migration.
-- Returns one row per check; every row must say PASS.
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
  (5, 'app_runtime cannot execute internal helpers (_idem_begin, _idem_finish, _slugify)',
    NOT pg_catalog.has_function_privilege('app_runtime', 'app._idem_begin(text,text,text)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('app_runtime', 'app._idem_finish(text,jsonb)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('app_runtime', 'app._slugify(text)', 'EXECUTE')),
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
  (12, 'the migration user (you) is not a member of any application role',
    (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = CURRENT_USER)
    OR NOT EXISTS (SELECT 1 FROM app_roles r
                   WHERE pg_catalog.pg_has_role(CURRENT_USER, r.oid, 'USAGE')
                      OR CASE WHEN pg_catalog.current_setting('server_version_num')::int >= 160000
                              THEN pg_catalog.pg_has_role(CURRENT_USER, r.oid, 'SET')
                              ELSE pg_catalog.pg_has_role(CURRENT_USER, r.oid, 'MEMBER') END))
)
SELECT n, check_name AS "check", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
ORDER BY n;
