-- M8 verification: run in the Supabase SQL editor after applying the M8 migration. Read-only; every row must say
-- PASS. M8 adds no table (blocks are calendar_reservations rows); m6_checks.sql still covers row-level security.
WITH f AS (
  SELECT p.oid, p.proname, p.prosecdef, o.rolname AS owner, p.proconfig
  FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_roles o ON o.oid = p.proowner
  WHERE p.pronamespace = 'app'::regnamespace AND p.proname IN ('priest_busy', 'create_block', 'release_block')
),
checks (n, check_name, ok) AS (
  VALUES
  (1, 'priest_busy is SECURITY DEFINER, owned by app_freebusy, search_path pinned',
    (SELECT count(*) FROM f WHERE proname = 'priest_busy' AND prosecdef AND owner = 'app_freebusy'
       AND 'search_path=""' = ANY (coalesce(proconfig, '{}'::text[]))) = 1),
  (2, 'create_block and release_block are SECURITY DEFINER, owned by app_domain, search_path pinned',
    (SELECT count(*) FROM f WHERE proname IN ('create_block', 'release_block') AND prosecdef AND owner = 'app_domain'
       AND 'search_path=""' = ANY (coalesce(proconfig, '{}'::text[]))) = 2),
  (3, 'app_runtime may execute priest_busy, create_block and release_block, still not _priest_conflicts',
    (SELECT count(*) FROM f WHERE pg_catalog.has_function_privilege('app_runtime', oid, 'EXECUTE')) = 3
    AND NOT pg_catalog.has_function_privilege('app_runtime', 'app._priest_conflicts(uuid,tstzrange,tstzrange,uuid)',
                                              'EXECUTE')),
  (4, 'app_freebusy still cannot read reservation notes, creators or priest-link ids',
    NOT pg_catalog.has_column_privilege('app_freebusy', 'app.calendar_reservations', 'note', 'SELECT')
    AND NOT pg_catalog.has_column_privilege('app_freebusy', 'app.calendar_reservations', 'created_by', 'SELECT')
    AND NOT pg_catalog.has_column_privilege('app_freebusy', 'app.calendar_reservations', 'organization_priest_id',
                                            'SELECT')),
  (5, 'no app function is executable by PUBLIC',
    NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                WHERE p.pronamespace = 'app'::regnamespace
                  AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a
                                                   WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))),
  (6, 'audit_log accepts BLOCK_RELEASED (action CHECK widened by the M8 migration)',
    EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con
            WHERE con.conrelid = 'app.audit_log'::regclass AND con.conname = 'audit_log_action_check'
              AND pg_catalog.pg_get_constraintdef(con.oid) LIKE '%BLOCK_RELEASED%'))
)
SELECT n, check_name AS "check", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks ORDER BY n;
