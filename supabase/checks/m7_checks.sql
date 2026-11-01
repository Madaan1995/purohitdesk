-- M7 verification: run in the Supabase SQL editor after applying the M7 migration. Read-only; every row must say
-- PASS. M7 adds no table, so there is no row-level check here (m6_checks.sql still covers the booking tables).
WITH cmd AS (
  SELECT p.oid, p.proname, p.prosecdef, o.rolname AS owner, p.proconfig, p.oid::regprocedure::text AS sig
  FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_roles o ON o.oid = p.proowner
  WHERE p.pronamespace = 'app'::regnamespace
    AND p.proname IN ('create_booking', 'confirm_booking', 'reschedule_booking', '_reserve_booking', '_confirm')
),
checks (n, check_name, ok) AS (
  VALUES
  (1, 'create_booking, confirm_booking and reschedule_booking take the buffer acknowledgement (one version each)',
    (SELECT pg_catalog.string_agg(sig, ', ' ORDER BY sig) FROM cmd WHERE proname NOT LIKE '\_%')
    = 'app.confirm_booking(uuid,integer,uuid[],boolean,text,text), app.create_booking(jsonb,boolean,boolean,text,text), '
      'app.reschedule_booking(uuid,integer,jsonb,text,boolean,text,text)'),
  (2, 'the three commands are SECURITY DEFINER, owned by app_domain, search_path pinned',
    (SELECT count(*) FROM cmd WHERE proname NOT LIKE '\_%' AND prosecdef AND owner = 'app_domain'
       AND 'search_path=""' = ANY (coalesce(proconfig, '{}'::text[]))) = 3),
  (3, 'app_runtime may execute the three commands but not _reserve_booking or _confirm',
    (SELECT count(*) FROM cmd WHERE proname NOT LIKE '\_%'
       AND pg_catalog.has_function_privilege('app_runtime', oid, 'EXECUTE')) = 3
    AND NOT EXISTS (SELECT 1 FROM cmd WHERE proname LIKE '\_%'
                    AND pg_catalog.has_function_privilege('app_runtime', oid, 'EXECUTE'))),
  (4, '_reserve_booking and _confirm are internal helpers (not SECURITY DEFINER) taking the acknowledgement',
    (SELECT pg_catalog.string_agg(sig, ', ' ORDER BY sig) FROM cmd WHERE proname LIKE '\_%' AND NOT prosecdef)
    = 'app._confirm(uuid,boolean), app._reserve_booking(uuid,boolean)'),
  (5, 'no app function is executable by PUBLIC',
    NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                WHERE p.pronamespace = 'app'::regnamespace
                  AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a
                                                   WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))))
)
SELECT n, check_name AS "check", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks ORDER BY n;
