-- M1 foundation: schema, roles, context helpers, errors, time zones, shared triggers.
BEGIN;

SELECT test.ok(EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'app'), 'schema app exists');

SELECT test.is((SELECT count(*) FROM pg_roles WHERE rolname IN ('app_runtime', 'app_domain', 'app_authz',
  'app_bootstrap', 'app_freebusy', 'app_maintenance')), 6::bigint, 'six application roles exist');

SELECT test.ok(NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname LIKE 'app\_%' AND (rolsuper OR rolbypassrls)),
  'no application role has BYPASSRLS or SUPERUSER');

SELECT test.ok(NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname LIKE 'app\_%' AND rolcanlogin),
  'all application roles are NOLOGIN after M1 (app_runtime gets LOGIN in M2)');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'app'::regnamespace
    AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                                     WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))),
  'no app function is executable by PUBLIC');

SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_roles o ON o.oid = p.proowner
  WHERE p.pronamespace = 'app'::regnamespace AND p.prosecdef
    AND (NOT ('search_path=""' = ANY (coalesce(p.proconfig, '{}'))) OR o.rolcanlogin OR o.rolbypassrls)),
  'SECURITY DEFINER functions pin search_path and have NOLOGIN, non-BYPASSRLS owners');

SELECT test.ok(NOT has_schema_privilege('anon', 'app', 'USAGE')
           AND NOT has_schema_privilege('authenticated', 'app', 'USAGE')
           AND NOT has_schema_privilege('service_role', 'app', 'USAGE'),
  'Supabase API roles cannot use schema app (despite default privileges granting it)');

-- Ownership hand-over leaves the migration user (Supabase: postgres) without any application role.
SELECT test.ok(NOT EXISTS (
  SELECT 1 FROM pg_roles r WHERE r.rolname LIKE 'app\_%'
    AND (pg_has_role('pd_migrator', r.oid, 'USAGE') OR pg_has_role('pd_migrator', r.oid, 'SET'))),
  'the migration user holds no application role after the ownership hand-over');
SET ROLE pd_migrator;
SELECT test.throws('ALTER FUNCTION app.assert_permission(text) OWNER TO pd_migrator', '42501',
  'the migration user cannot take back a function owned by app_authz');
SELECT test.throws($$SELECT app.assert_permission('ORG_READ')$$, '42501',
  'the migration user does not inherit app_authz''s EXECUTE rights');
RESET ROLE;

-- Context helpers
SELECT test.ctx(NULL, NULL);
SELECT test.ok(app.current_actor_id() IS NULL AND app.current_tenant_id() IS NULL, 'empty context gives NULL actor and tenant');
SELECT test.ctx('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
SELECT test.is(app.current_actor_id(), '11111111-1111-1111-1111-111111111111'::uuid, 'current_actor_id reads app.actor_user_id');
SELECT test.is(app.current_tenant_id(), '22222222-2222-2222-2222-222222222222'::uuid, 'current_tenant_id reads app.tenant_id');
SELECT test.ctx(NULL, NULL);

-- Errors
SELECT test.throws($$SELECT app.raise_error('PD422', 'VALIDATION_FAILED', '{"field":"name"}')$$,
  'PD422', 'raise_error raises the given SQLSTATE and reason', 'VALIDATION_FAILED');
DO $$
DECLARE v_detail text;
BEGIN
  PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource":"organization"}');
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  PERFORM test.is(v_detail::jsonb, '{"resource":"organization"}'::jsonb, 'raise_error puts our JSON in DETAIL');
END $$;
SELECT test.throws($$SELECT app.raise_error('23505', 'DUPLICATE')$$, 'PD500',
  'raise_error refuses non-PD codes', 'BAD_ERROR_CODE');

-- Time zones (IANA names only)
SELECT test.ok(app.is_valid_timezone('Asia/Kolkata'), 'Asia/Kolkata is a valid time zone');
SELECT test.ok(app.is_valid_timezone('UTC'), 'UTC is a valid time zone');
SELECT test.ok(app.is_valid_timezone('America/Argentina/Buenos_Aires'), 'three-part IANA names are valid');
SELECT test.ok(NOT app.is_valid_timezone('IST'), 'time-zone abbreviation IST is rejected');
SELECT test.ok(NOT app.is_valid_timezone('EST5EDT'), 'POSIX-style EST5EDT is rejected');
SELECT test.ok(NOT app.is_valid_timezone('posix/Asia/Kolkata'), 'posix/ prefixed names are rejected');
SELECT test.ok(NOT app.is_valid_timezone('Mars/Phobos'), 'unknown Area/Location is rejected');
SELECT test.ok(NOT app.is_valid_timezone('') AND NOT app.is_valid_timezone(NULL), 'empty and NULL are rejected');

-- Shared triggers, on a scratch table owned by the test superuser
CREATE TABLE test.scratch (
  id int PRIMARY KEY,
  tz text,
  version int NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT now() - interval '1 day'
);
CREATE TRIGGER scratch_tz BEFORE INSERT OR UPDATE ON test.scratch
  FOR EACH ROW EXECUTE FUNCTION app.tg_validate_timezone('tz');
CREATE TRIGGER scratch_version BEFORE UPDATE ON test.scratch
  FOR EACH ROW EXECUTE FUNCTION app.tg_bump_version();
INSERT INTO test.scratch (id, tz) VALUES (1, 'Asia/Kolkata');
UPDATE test.scratch SET tz = 'UTC' WHERE id = 1;
SELECT test.is((SELECT version FROM test.scratch WHERE id = 1), 2, 'tg_bump_version increments version');
SELECT test.ok((SELECT updated_at > now() - interval '1 minute' FROM test.scratch WHERE id = 1),
  'tg_bump_version touches updated_at');
SELECT test.throws($$INSERT INTO test.scratch (id, tz) VALUES (2, 'IST')$$, 'PD422',
  'tg_validate_timezone rejects IST', 'VALIDATION_FAILED');

CREATE TABLE test.history (id int PRIMARY KEY, v text);
CREATE TRIGGER history_append_only BEFORE UPDATE OR DELETE ON test.history
  FOR EACH ROW EXECUTE FUNCTION app.tg_append_only();
INSERT INTO test.history VALUES (1, 'a');
SELECT test.throws($$UPDATE test.history SET v = 'b'$$, 'PD405', 'tg_append_only blocks UPDATE', 'APPEND_ONLY');
SELECT test.throws($$DELETE FROM test.history$$, 'PD405', 'tg_append_only blocks DELETE', 'APPEND_ONLY');

ROLLBACK;
