-- Security gates over the whole schema (spec §08 §3 gates). Exact whitelists: update them when a milestone adds
-- a command or changes ownership, never to make a failing gate pass without review.
BEGIN;

SELECT test.is((
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text)
  FROM pg_proc p
  WHERE p.pronamespace = 'app'::regnamespace AND has_function_privilege('app_runtime', p.oid, 'EXECUTE')),
  'app.bootstrap_practice(text,uuid[],text,text), app.current_actor_id(), app.current_member_role(), '
  'app.current_tenant_id(), app.ensure_current_user(text,text), app.is_active_member_of(uuid), '
  'app.update_my_profile(text,text)',
  'every function app_runtime may EXECUTE is an endpoint command or used by its RLS policies');

SELECT test.is((
  SELECT string_agg(p.proname || '=' || o.rolname, ', ' ORDER BY p.proname)
  FROM pg_proc p JOIN pg_roles o ON o.oid = p.proowner
  WHERE p.pronamespace = 'app'::regnamespace AND p.prosecdef),
  'assert_permission=app_authz, bootstrap_practice=app_bootstrap, current_member_has=app_authz, '
  'current_member_role=app_authz, current_priest_profile_id=app_authz, ensure_current_user=app_bootstrap, '
  'is_active_member_of=app_authz, ops_add_member=app_operator, ops_revoke_member=app_operator, '
  'update_my_profile=app_domain',
  'SECURITY DEFINER functions and their NOLOGIN owners');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_roles o ON o.oid = p.proowner
  WHERE p.pronamespace = 'app'::regnamespace AND p.prosecdef
    AND (NOT ('search_path=""' = ANY (coalesce(p.proconfig, '{}'))) OR o.rolcanlogin OR o.rolbypassrls OR o.rolsuper)),
  'every SECURITY DEFINER function pins search_path = '''' and has a NOLOGIN, non-BYPASSRLS owner');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'app'::regnamespace
    AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                                     WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))),
  'no app function is executable by PUBLIC');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c WHERE c.relnamespace = 'app'::regnamespace AND c.relkind = 'r'
    AND (has_table_privilege('app_runtime', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
         OR has_any_column_privilege('app_runtime', c.oid, 'INSERT, UPDATE'))),
  'app_runtime has no INSERT/UPDATE/DELETE/TRUNCATE on any app relation');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c WHERE c.relnamespace = 'app'::regnamespace AND c.relkind = 'r'
    AND (NOT c.relrowsecurity
         OR (NOT c.relforcerowsecurity AND c.relname NOT IN ('role_permissions', 'ceremony_types')))),
  'RLS enabled on every app table and forced on every tenant/identity table');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
  WHERE c.relnamespace = 'app'::regnamespace AND 0::oid = ANY (p.polroles)),
  'no RLS policy applies to PUBLIC');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname LIKE 'app\_%' AND (rolsuper OR rolbypassrls)),
  'no application role has BYPASSRLS or SUPERUSER');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_class c, (VALUES ('anon'), ('authenticated'), ('service_role')) AS r (rolname)
  WHERE c.relnamespace = 'app'::regnamespace
    AND has_table_privilege(r.rolname, c.oid, 'SELECT, INSERT, UPDATE, DELETE')),
  'Supabase API roles have no privilege on any app relation');

ROLLBACK;
