-- M1 verification. Read-only: run in the Supabase SQL editor after applying the M1 migrations and the seed.
-- Returns one row per check; every row must say PASS.
WITH app_tables AS (
  SELECT c.oid, c.relname, c.relrowsecurity, c.relforcerowsecurity
  FROM pg_catalog.pg_class c
  WHERE c.relnamespace = 'app'::regnamespace AND c.relkind IN ('r', 'p')
),
app_roles AS (
  SELECT r.*
  FROM pg_catalog.pg_roles r
  WHERE r.rolname IN ('app_runtime', 'app_domain', 'app_authz', 'app_bootstrap', 'app_freebusy', 'app_maintenance',
                      'app_operator')
),
app_funcs AS (
  SELECT p.oid, p.proname, p.prosecdef, p.proconfig, p.proowner, p.proacl
  FROM pg_catalog.pg_proc p
  WHERE p.pronamespace = 'app'::regnamespace
),
api_roles AS (
  SELECT r.oid, r.rolname
  FROM pg_catalog.pg_roles r
  WHERE r.rolname IN ('anon', 'authenticated', 'service_role')
),
checks (n, check_name, ok) AS (
  VALUES
  (1, 'schema app exists',
    EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'app')),
  (2, 'M1 tables exist (7)',
    (SELECT count(*) FROM app_tables WHERE relname IN ('role_permissions', 'app_users', 'organizations',
      'org_members', 'priest_profiles', 'organization_priests', 'ceremony_types')) = 7),
  (3, 'seven application roles exist',
    (SELECT count(*) FROM app_roles) = 7),
  (4, 'no application role is SUPERUSER or BYPASSRLS',
    NOT EXISTS (SELECT 1 FROM app_roles WHERE rolsuper OR rolbypassrls)),
  (5, 'every application role except app_runtime is NOLOGIN',
    NOT EXISTS (SELECT 1 FROM app_roles WHERE rolname <> 'app_runtime' AND rolcanlogin)),
  (6, 'RLS enabled on every app table',
    NOT EXISTS (SELECT 1 FROM app_tables WHERE NOT relrowsecurity)),
  (7, 'RLS forced on every tenant/identity table',
    NOT EXISTS (SELECT 1 FROM app_tables
                WHERE relname NOT IN ('role_permissions', 'ceremony_types') AND NOT relforcerowsecurity)),
  (8, 'no RLS policy applies to PUBLIC',
    NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN app_tables t ON t.oid = pol.polrelid
                WHERE 0::oid = ANY (pol.polroles))),
  (9, 'no app function is executable by PUBLIC',
    NOT EXISTS (SELECT 1 FROM app_funcs f
                WHERE f.proacl IS NULL
                   OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(f.proacl) a
                              WHERE a.grantee = 0::oid AND a.privilege_type = 'EXECUTE'))),
  (10, 'SECURITY DEFINER functions pin search_path and have NOLOGIN, non-BYPASSRLS owners',
    NOT EXISTS (SELECT 1 FROM app_funcs f JOIN pg_catalog.pg_roles o ON o.oid = f.proowner
                WHERE f.prosecdef
                  AND (NOT ('search_path=""' = ANY (coalesce(f.proconfig, '{}'::text[])))
                       OR o.rolcanlogin OR o.rolbypassrls OR o.rolsuper))),
  (11, 'app_runtime has no INSERT/UPDATE/DELETE/TRUNCATE on any app table',
    NOT EXISTS (SELECT 1 FROM app_tables t
                WHERE pg_catalog.has_table_privilege('app_runtime', t.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
                   OR pg_catalog.has_any_column_privilege('app_runtime', t.oid, 'INSERT, UPDATE'))),
  (12, 'Supabase API roles (anon, authenticated, service_role) have no privilege on schema app',
    NOT EXISTS (SELECT 1 FROM api_roles r
                WHERE pg_catalog.has_schema_privilege(r.oid, 'app', 'USAGE, CREATE')
                   OR EXISTS (SELECT 1 FROM app_tables t
                              WHERE pg_catalog.has_table_privilege(r.oid, t.oid,
                                      'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')))),
  (13, 'membership helpers are owned by app_authz (5)',
    (SELECT count(*) FROM app_funcs f JOIN pg_catalog.pg_roles o ON o.oid = f.proowner
     WHERE o.rolname = 'app_authz'
       AND f.proname IN ('current_member_role', 'current_member_has', 'is_active_member_of',
                         'current_priest_profile_id', 'assert_permission')) = 5),
  (14, 'role_permissions holds the spec matrix (64 rows)',
    (SELECT count(*) FROM app.role_permissions) = 64),
  (15, 'ceremony_types seeded (20 rows)',
    (SELECT count(*) FROM app.ceremony_types) = 20),
  (16, 'time zones: Asia/Kolkata accepted, IST rejected',
    app.is_valid_timezone('Asia/Kolkata') AND NOT app.is_valid_timezone('IST')),
  (17, 'the migration user (you) is not a member of any application role',
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
