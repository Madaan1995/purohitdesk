-- Assertion helpers for supabase/tests/NN_*.sql (throwaway test database only).
-- Each assertion prints a NOTICE "ok N - name" or "not ok N - name # detail"; run.sh counts them.
SET client_min_messages = warning;
CREATE SCHEMA test;
GRANT USAGE ON SCHEMA test TO PUBLIC;

CREATE FUNCTION test.ok(p_ok boolean, p_name text, p_detail text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  n int := coalesce(nullif(current_setting('test.n', true), ''), '0')::int + 1;
BEGIN
  PERFORM set_config('test.n', n::text, false);
  IF coalesce(p_ok, false) THEN
    RAISE NOTICE 'ok % - %', n, p_name;
  ELSE
    RAISE NOTICE 'not ok % - %', n, p_name || coalesce(' # ' || p_detail, '');
  END IF;
END $$;

CREATE FUNCTION test.is(p_got anyelement, p_want anyelement, p_name text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM test.ok(p_got IS NOT DISTINCT FROM p_want, p_name, format('got %s, want %s', p_got, p_want));
END $$;

-- Runs p_sql as the current role; passes if it raises p_sqlstate (and p_reason as the message, if given).
CREATE FUNCTION test.throws(p_sql text, p_sqlstate text, p_name text, p_reason text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_state text;
  v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    PERFORM test.ok(v_state = p_sqlstate AND (p_reason IS NULL OR v_msg = p_reason), p_name,
                    format('got %s %s', v_state, v_msg));
    RETURN;
  END;
  PERFORM test.ok(false, p_name, 'no error raised');
END $$;

-- Runs p_sql as the current role; passes if it raises nothing.
CREATE FUNCTION test.lives(p_sql text, p_name text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_state text;
  v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    PERFORM test.ok(false, p_name, format('raised %s %s', v_state, v_msg));
    RETURN;
  END;
  PERFORM test.ok(true, p_name);
END $$;

-- Request context exactly as withTenantTx sets it (transaction-local).
CREATE FUNCTION test.ctx(p_actor uuid, p_tenant uuid DEFAULT NULL) RETURNS void
LANGUAGE sql AS $$
  SELECT set_config('app.actor_user_id', coalesce(p_actor::text, ''), true),
         set_config('app.tenant_id', coalesce(p_tenant::text, ''), true);
$$;

-- Fixture (superuser only): a Supabase auth user plus its app user row.
CREATE FUNCTION test.make_user(p_name text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, email, raw_user_meta_data)
  VALUES (v_id, lower(replace(p_name, ' ', '.')) || '@example.test', jsonb_build_object('full_name', p_name));
  INSERT INTO app.app_users (id, auth_user_id, display_name) VALUES (v_id, v_id, p_name);
  RETURN v_id;
END $$;
