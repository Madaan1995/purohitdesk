-- M5 verification. Read-only: run in the Supabase SQL editor after applying the M5 migration.
-- Returns one row per check; every row must say PASS.
WITH m5_tables AS (
  SELECT c.oid, c.relname, c.relrowsecurity, c.relforcerowsecurity
  FROM pg_catalog.pg_class c
  WHERE c.relnamespace = 'app'::regnamespace AND c.relname IN ('samagri_templates', 'samagri_template_items', 'audit_log')
),
m5_commands (sig) AS (
  VALUES ('app.save_offering(uuid,integer,jsonb,text,text)'),
         ('app.save_samagri_template(uuid,integer,uuid,jsonb,text,text)'),
         ('app.update_organization(integer,jsonb,text,text)'),
         ('app.update_priest_settings(uuid,integer,integer,text,text)')
),
checks (n, check_name, ok) AS (
  VALUES
  (1, 'samagri_templates, samagri_template_items, audit_log exist with RLS enabled and forced',
    (SELECT count(*) FROM m5_tables WHERE relrowsecurity AND relforcerowsecurity) = 3),
  (2, 'the four M5 commands are SECURITY DEFINER, owned by app_domain, search_path pinned',
    (SELECT count(*) FROM m5_commands m
     JOIN pg_catalog.pg_proc p ON p.oid = m.sig::regprocedure
     JOIN pg_catalog.pg_roles o ON o.oid = p.proowner
     WHERE p.prosecdef AND o.rolname = 'app_domain'
       AND 'search_path=""' = ANY (coalesce(p.proconfig, '{}'::text[]))) = 4),
  (3, 'app_runtime may execute the four M5 commands',
    NOT EXISTS (SELECT 1 FROM m5_commands m
                WHERE NOT pg_catalog.has_function_privilege('app_runtime', m.sig, 'EXECUTE'))),
  (4, 'app_runtime can read but not write the M5 tables',
    NOT EXISTS (SELECT 1 FROM m5_tables t
                WHERE NOT pg_catalog.has_table_privilege('app_runtime', t.oid, 'SELECT')
                   OR pg_catalog.has_table_privilege('app_runtime', t.oid, 'INSERT, UPDATE, DELETE, TRUNCATE'))),
  (5, 'audit_log: app_domain may only INSERT (no UPDATE/DELETE grant)',
    pg_catalog.has_table_privilege('app_domain', 'app.audit_log', 'INSERT')
    AND NOT pg_catalog.has_table_privilege('app_domain', 'app.audit_log', 'UPDATE, DELETE, TRUNCATE')),
  (6, 'audit_log append-only guards are installed (row and TRUNCATE triggers)',
    (SELECT count(*) FROM pg_catalog.pg_trigger t
     WHERE t.tgrelid = 'app.audit_log'::regclass AND t.tgname IN ('audit_log_guard', 'audit_log_no_truncate')
       AND t.tgenabled = 'O') = 2),
  (7, 'audit_log is readable by app_runtime only through an AUDIT_READ policy',
    EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol
            WHERE pol.polrelid = 'app.audit_log'::regclass AND pol.polcmd = 'r'
              AND pg_catalog.pg_get_expr(pol.polqual, pol.polrelid) LIKE '%AUDIT_READ%')),
  (8, 'no policy on the M5 tables applies to PUBLIC',
    NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN m5_tables t ON t.oid = pol.polrelid
                WHERE 0::oid = ANY (pol.polroles)))
)
SELECT n, check_name AS "check", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
ORDER BY n;
