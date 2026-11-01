-- M6 verification: run in the Supabase SQL editor after applying the M6 migration.
-- Returns one row per check; every row must say PASS (or NO DATA, see below).
--
-- Row-level security is checked AS THE APPLICATION ROLES: Supabase's postgres has BYPASSRLS, so rows read as yourself
-- prove nothing. The DO block becomes each application role in turn (SET ROLE). For that it grants you the roles
-- WITH INHERIT FALSE (SET ROLE only, none of their privileges) and revokes them before it ends; nothing else is
-- written, and any error rolls the whole script back. A row-level check says NO DATA while there are no rows (or no
-- ACTIVE member) to test with: run the script again once there are.
DO $$
DECLARE
  -- The M6 tables, and the rows app_runtime may see when acting for member $1 in practice $2 (the policies of
  -- 20261101100000_m6_bookings.sql, evaluated here without RLS).
  v_tables  text[] := ARRAY['app.bookings', 'app.booking_assignments', 'app.calendar_reservations',
                            'app.booking_events'];
  v_expect  text[] := ARRAY['org_id = $2', 'org_id = $2', 'org_id = $2', 'org_id = $2'];
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

  -- Every application role that can read one of the tables (app_freebusy reads columns only). app_operator is left
  -- out: it cannot read these tables at all.
  SELECT pg_catalog.array_agg(r.rolname ORDER BY r.rolname) INTO v_roles
  FROM pg_catalog.pg_roles r
  WHERE r.rolname IN ('app_runtime', 'app_domain', 'app_authz', 'app_bootstrap', 'app_freebusy', 'app_maintenance')
    AND EXISTS (SELECT 1 FROM pg_catalog.unnest(v_tables) AS t (name)
                WHERE pg_catalog.has_any_column_privilege(r.oid, t.name, 'SELECT'));
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
        IF pg_catalog.has_column_privilege(v_role, v_tables[i], 'id', 'SELECT') THEN
          EXECUTE pg_catalog.format('SELECT count(id) FROM %s', v_tables[i]) INTO v_n;
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

  PERFORM pg_catalog.set_config('pd_checks.m6_rls', pg_catalog.jsonb_build_object(
    'no_context', CASE WHEN v_total = 0 THEN 'NO DATA' WHEN cardinality(v_open) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'no_context_seen', pg_catalog.array_to_string(v_open, ', '),
    'forged', CASE WHEN v_total = 0 THEN 'NO DATA' WHEN cardinality(v_forged) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'forged_seen', pg_catalog.array_to_string(v_forged, ', '),
    'member', CASE WHEN v_actor IS NULL THEN 'NO DATA' WHEN cardinality(v_member) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'member_seen', pg_catalog.array_to_string(v_member, ', '))::text, false);
END
$$;

WITH m6_tables AS (
  SELECT c.oid, c.relname, c.relrowsecurity, c.relforcerowsecurity
  FROM pg_catalog.pg_class c
  WHERE c.relnamespace = 'app'::regnamespace
    AND c.relname IN ('bookings', 'booking_assignments', 'calendar_reservations', 'booking_events')
),
m6_commands (sig) AS (
  VALUES ('app.create_booking(jsonb,boolean,text,text)'),
         ('app.update_booking(uuid,integer,jsonb,text,text)'),
         ('app.confirm_booking(uuid,integer,uuid[],text,text)'),
         ('app.cancel_booking(uuid,integer,text,text,text)'),
         ('app.complete_booking(uuid,integer,text,text)')
),
checks (n, check_name, ok) AS (
  VALUES
  (1, 'bookings, booking_assignments, calendar_reservations, booking_events exist with RLS enabled and forced',
    (SELECT count(*) FROM m6_tables WHERE relrowsecurity AND relforcerowsecurity) = 4),
  (2, 'the five booking commands are SECURITY DEFINER, owned by app_domain, search_path pinned',
    (SELECT count(*) FROM m6_commands m
     JOIN pg_catalog.pg_proc p ON p.oid = m.sig::regprocedure
     JOIN pg_catalog.pg_roles o ON o.oid = p.proowner
     WHERE p.prosecdef AND o.rolname = 'app_domain'
       AND 'search_path=""' = ANY (coalesce(p.proconfig, '{}'::text[]))) = 5),
  (3, 'app_runtime may execute the five commands and get_booking, but not _reserve_booking or _priest_conflicts',
    NOT EXISTS (SELECT 1 FROM m6_commands m
                WHERE NOT pg_catalog.has_function_privilege('app_runtime', m.sig, 'EXECUTE'))
    AND pg_catalog.has_function_privilege('app_runtime', 'app.get_booking(uuid)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('app_runtime', 'app._reserve_booking(uuid)', 'EXECUTE')
    AND NOT pg_catalog.has_function_privilege('app_runtime',
                                              'app._priest_conflicts(uuid,tstzrange,tstzrange,uuid)', 'EXECUTE')),
  (4, '_priest_conflicts is SECURITY DEFINER, owned by app_freebusy, search_path pinned, executable by app_domain',
    EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_roles o ON o.oid = p.proowner
            WHERE p.oid = 'app._priest_conflicts(uuid,tstzrange,tstzrange,uuid)'::regprocedure
              AND p.prosecdef AND o.rolname = 'app_freebusy' AND p.provolatile = 'v'
              AND 'search_path=""' = ANY (coalesce(p.proconfig, '{}'::text[])))
    AND pg_catalog.has_function_privilege('app_domain', 'app._priest_conflicts(uuid,tstzrange,tstzrange,uuid)',
                                          'EXECUTE')),
  (5, 'app_runtime can read but not write the M6 tables',
    NOT EXISTS (SELECT 1 FROM m6_tables t
                WHERE NOT pg_catalog.has_table_privilege('app_runtime', t.oid, 'SELECT')
                   OR pg_catalog.has_table_privilege('app_runtime', t.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
                   OR pg_catalog.has_any_column_privilege('app_runtime', t.oid, 'INSERT, UPDATE'))),
  (6, 'exclusion constraint calendar_reservations_no_overlap on (priest_profile_id, span) for ACTIVE rows (btree_gist)',
    EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con
            WHERE con.conrelid = 'app.calendar_reservations'::regclass AND con.conname = 'calendar_reservations_no_overlap'
              AND con.contype = 'x'
              AND pg_catalog.pg_get_constraintdef(con.oid) LIKE '%priest_profile_id WITH =, span WITH &&%status%ACTIVE%')
    AND EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'btree_gist')),
  (7, 'deferred invariant triggers on bookings, booking_assignments and calendar_reservations',
    (SELECT count(*) FROM pg_catalog.pg_trigger t
     WHERE t.tgname IN ('bookings_invariants', 'booking_assignments_invariants', 'calendar_reservations_invariants')
       AND t.tgdeferrable AND t.tginitdeferred AND t.tgenabled = 'O') = 3),
  (8, 'state guard, reservation guard and append-only history triggers are installed',
    (SELECT count(*) FROM pg_catalog.pg_trigger t
     WHERE t.tgname IN ('bookings_guard', 'bookings_no_delete', 'calendar_reservations_guard',
                        'calendar_reservations_no_truncate', 'booking_events_append_only',
                        'booking_events_no_truncate')
       AND t.tgenabled = 'O') = 6),
  (9, 'app_freebusy reads only busy-time columns of reservations, and no booking or customer',
    NOT pg_catalog.has_column_privilege('app_freebusy', 'app.calendar_reservations', 'note', 'SELECT')
    AND NOT pg_catalog.has_column_privilege('app_freebusy', 'app.calendar_reservations', 'created_by', 'SELECT')
    AND pg_catalog.has_column_privilege('app_freebusy', 'app.calendar_reservations', 'span', 'SELECT')
    AND NOT pg_catalog.has_any_column_privilege('app_freebusy', 'app.bookings', 'SELECT')
    AND NOT pg_catalog.has_any_column_privilege('app_freebusy', 'app.customers', 'SELECT')
    AND NOT pg_catalog.has_any_column_privilege('app_freebusy', 'app.calendar_reservations', 'INSERT, UPDATE')),
  (10, 'no policy on the M6 tables applies to PUBLIC',
    NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy pol JOIN m6_tables t ON t.oid = pol.polrelid
                WHERE 0::oid = ANY (pol.polroles)))
),
rls AS (
  -- FAIL, not an empty result, if the DO block above did not run in this session.
  SELECT coalesce(nullif(pg_catalog.current_setting('pd_checks.m6_rls', true), ''), '{}')::jsonb AS r
),
rls_checks (n, check_name, result) AS (
  SELECT 11, 'RLS as the application roles, no request context: no row of the M6 tables is visible'
             || coalesce(' (seen: ' || nullif(r ->> 'no_context_seen', '') || ')', ''),
         coalesce(r ->> 'no_context', 'FAIL') FROM rls
  UNION ALL
  SELECT 12, 'RLS as the application roles, an actor who is no member in a real practice: no row is visible'
             || coalesce(' (seen: ' || nullif(r ->> 'forged_seen', '') || ')', ''),
         coalesce(r ->> 'forged', 'FAIL') FROM rls
  UNION ALL
  SELECT 13, 'RLS as app_runtime for a real ACTIVE member: exactly the rows the policies allow'
             || coalesce(' (seen/allowed: ' || nullif(r ->> 'member_seen', '') || ')', ''),
         coalesce(r ->> 'member', 'FAIL') FROM rls
)
SELECT n, check_name AS "check", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
UNION ALL
SELECT n, check_name, result FROM rls_checks
ORDER BY n;
