-- M4 verification. Read-only: run in the Supabase SQL editor after applying the M4 migration.
-- Returns one row per check; every row must say PASS.
WITH checks (n, check_name, ok) AS (
  VALUES
  (1, 'customers exists with RLS enabled and forced',
    EXISTS (SELECT 1 FROM pg_catalog.pg_class c
            WHERE c.oid = 'app.customers'::regclass AND c.relrowsecurity AND c.relforcerowsecurity)),
  (2, 'create_customer and update_customer are SECURITY DEFINER, owned by app_domain, search_path pinned',
    (SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_roles o ON o.oid = p.proowner
     WHERE p.oid IN ('app.create_customer(text,text,text,text,text)'::regprocedure,
                     'app.update_customer(uuid,integer,jsonb,text,text)'::regprocedure)
       AND p.prosecdef AND o.rolname = 'app_domain'
       AND 'search_path=""' = ANY (coalesce(p.proconfig, '{}'::text[]))) = 2),
  (3, 'app_runtime may execute both customer commands',
    pg_catalog.has_function_privilege('app_runtime', 'app.create_customer(text,text,text,text,text)', 'EXECUTE')
    AND pg_catalog.has_function_privilege('app_runtime', 'app.update_customer(uuid,integer,jsonb,text,text)', 'EXECUTE')),
  (4, 'app_runtime can read customers but not write them',
    pg_catalog.has_table_privilege('app_runtime', 'app.customers', 'SELECT')
    AND NOT pg_catalog.has_table_privilege('app_runtime', 'app.customers', 'INSERT, UPDATE, DELETE, TRUNCATE')),
  (5, 'nobody but the owner can DELETE customers (erasure is an update)',
    NOT pg_catalog.has_table_privilege('app_domain', 'app.customers', 'DELETE')),
  (6, 'acquisition_source guard trigger is installed',
    EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid = 'app.customers'::regclass AND t.tgname = 'customers_source_immutable' AND t.tgenabled = 'O')),
  (7, 'search indexes exist (name prefix, phone)',
    (SELECT count(*) FROM pg_catalog.pg_indexes
     WHERE schemaname = 'app' AND indexname IN ('customers_name_prefix_idx', 'customers_phone_idx')) = 2),
  (8, 'no policy on customers applies to PUBLIC',
    NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol
                WHERE pol.polrelid = 'app.customers'::regclass AND 0::oid = ANY (pol.polroles)))
)
SELECT n, check_name AS "check", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
ORDER BY n;
