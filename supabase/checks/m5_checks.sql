-- M5 verification: run in the Supabase SQL editor after applying the M5 migration.
-- Returns one row per check; every row must say PASS (or NO DATA, see below).
--
-- Row-level security is checked AS THE APPLICATION ROLES: Supabase's postgres has BYPASSRLS, so rows read as yourself
-- prove nothing. The DO block becomes each application role in turn (SET ROLE). For that it grants you the roles
-- WITH INHERIT FALSE (SET ROLE only, none of their privileges) and revokes them before it ends; nothing else is
-- written, and any error rolls the whole script back. A row-level check says NO DATA while there are no rows (or no
-- ACTIVE member) to test with: run the script again once there are.
DO $$
DECLARE
  -- The M5 tables, and the rows app_runtime may see when acting for member $1 in practice $2 (the policies
  -- of 20261028230000_m5_catalog_settings.sql, evaluated here without RLS; NULL: app_runtime cannot read the table).
  v_tables  text[] := ARRAY['app.samagri_templates', 'app.samagri_template_items', 'app.audit_log'];
  v_expect  text[] := ARRAY[
    'org_id = $2',
    'org_id = $2',
    'org_id = $2 AND EXISTS (SELECT 1 FROM app.org_members m JOIN app.role_permissions rp ON rp.role = m.role WHERE m.user_id = $1 AND m.org_id = $2 AND m.status = ''ACTIVE'' AND rp.permission = ''AUDIT_READ'')'];
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

  PERFORM pg_catalog.set_config('pd_checks.m5_rls', pg_catalog.jsonb_build_object(
    'no_context', CASE WHEN v_total = 0 THEN 'NO DATA' WHEN cardinality(v_open) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'no_context_seen', pg_catalog.array_to_string(v_open, ', '),
    'forged', CASE WHEN v_total = 0 THEN 'NO DATA' WHEN cardinality(v_forged) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'forged_seen', pg_catalog.array_to_string(v_forged, ', '),
    'member', CASE WHEN v_actor IS NULL THEN 'NO DATA' WHEN cardinality(v_member) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'member_seen', pg_catalog.array_to_string(v_member, ', '))::text, false);
END
$$;

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
),
rls AS (
  SELECT pg_catalog.current_setting('pd_checks.m5_rls')::jsonb AS r
),
rls_checks (n, check_name, result) AS (
  SELECT 9, 'RLS as the application roles, no request context: no row of the M5 tables is visible'
             || coalesce(' (seen: ' || nullif(r ->> 'no_context_seen', '') || ')', ''), r ->> 'no_context' FROM rls
  UNION ALL
  SELECT 10, 'RLS as the application roles, an actor who is no member in a real practice: no row is visible'
             || coalesce(' (seen: ' || nullif(r ->> 'forged_seen', '') || ')', ''), r ->> 'forged' FROM rls
  UNION ALL
  SELECT 11, 'RLS as app_runtime for a real ACTIVE member: exactly the rows the policies allow'
             || coalesce(' (seen/allowed: ' || nullif(r ->> 'member_seen', '') || ')', ''), r ->> 'member' FROM rls
)
SELECT n, check_name AS "check", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
UNION ALL
SELECT n, check_name, result FROM rls_checks
ORDER BY n;
