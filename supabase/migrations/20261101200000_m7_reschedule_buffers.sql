-- M7 reschedule and travel buffers: buffer-only overlaps need an explicit, recorded acknowledgement (PD449
-- BUFFER_CONFLICT); reschedule_booking moves a CONFIRMED booking atomically. No new tables.
-- Spec: docs/spec.md ADR-006, §01 AC-04/AC-07, §05 §1/§3/§6/§11, §12 defect 10. Proposal: docs/proposals/m7.md.
-- create_booking and confirm_booking gain p_ack_buffer_overlap: the M6 signatures are dropped and replaced here
-- (deploy the M7 code together with this migration).

-- The migration user is a member of the function-owning roles only until the end of this file: dropping app_domain's
-- functions, the hand-over and the schema-wide REVOKE ... FROM PUBLIC need the owners' rights (spec U1).
GRANT app_authz, app_bootstrap, app_domain, app_operator, app_freebusy TO CURRENT_USER;

DROP FUNCTION app.create_booking(jsonb, boolean, text, text);
DROP FUNCTION app.confirm_booking(uuid, integer, uuid[], text, text);
DROP FUNCTION app._confirm(uuid);
DROP FUNCTION app._reserve_booking(uuid);

-- ---------------------------------------------------------------------------
-- _reserve_booking (invoker, run by the commands as app_domain): spec §05 §3 with travel buffers.
-- CEREMONY overlap -> 23P01 BOOKING_CONFLICT (never overridable). BUFFER-only overlap -> PD449 BUFFER_CONFLICT unless
-- acknowledged; an acknowledged overlap sets bookings.buffer_overlap_ack (cleared again when there is none, so a
-- reschedule needs a new acknowledgement). Returns {reservations, acknowledged}; the caller writes the history.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app._reserve_booking(p_booking_id uuid, p_ack_buffer_overlap boolean) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_b      app.bookings%ROWTYPE;
  v_span   tstzrange;
  v_buf    tstzrange;
  v_prof   uuid;
  v_hard   jsonb;
  v_soft   jsonb;
  v_n      integer;
BEGIN
  SELECT * INTO v_b FROM app.bookings b WHERE b.id = p_booking_id AND b.org_id = app.current_tenant_id();
  v_span := tstzrange(v_b.starts_at, v_b.ends_at, '[)');
  v_buf  := tstzrange(v_b.starts_at - make_interval(mins => v_b.buffer_before_min),
                      v_b.ends_at + make_interval(mins => v_b.buffer_after_min), '[)');

  -- One human at a time, always in the same order (no deadlocks); serialises the buffer checks per human.
  FOR v_prof IN
    SELECT op.priest_profile_id
    FROM app.booking_assignments a
    JOIN app.organization_priests op ON op.id = a.organization_priest_id AND op.org_id = a.org_id
    WHERE a.booking_id = p_booking_id
    ORDER BY op.priest_profile_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended('priest:' || v_prof::text, 0));
  END LOOP;

  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'organization_priest_id', a.organization_priest_id, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
             'same_org', c.same_org, 'booking_id', c.booking_id)) ORDER BY c.starts_at, a.position)
           FILTER (WHERE c.conflict = 'CEREMONY'), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'organization_priest_id', a.organization_priest_id, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
             'same_org', c.same_org, 'booking_id', c.booking_id)) ORDER BY c.starts_at, a.position)
           FILTER (WHERE c.conflict = 'BUFFER'), '[]'::jsonb)
  INTO v_hard, v_soft
  FROM app.booking_assignments a
  JOIN app.organization_priests op ON op.id = a.organization_priest_id AND op.org_id = a.org_id
  CROSS JOIN LATERAL app._priest_conflicts(op.priest_profile_id, v_span, v_buf, p_booking_id) c
  WHERE a.booking_id = p_booking_id;

  IF jsonb_array_length(v_hard) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = '23P01', MESSAGE = 'BOOKING_CONFLICT',
      DETAIL = jsonb_build_object('conflicts', v_hard)::text;
  END IF;
  IF jsonb_array_length(v_soft) > 0 AND NOT coalesce(p_ack_buffer_overlap, false) THEN
    PERFORM app.raise_error('PD449', 'BUFFER_CONFLICT', jsonb_build_object('conflicts', v_soft));
  END IF;

  -- The exclusion constraint stays the final arbiter.
  INSERT INTO app.calendar_reservations
    (org_id, kind, booking_id, organization_priest_id, priest_profile_id, span, buffer_span, created_by)
  SELECT v_b.org_id, 'BOOKING', v_b.id, a.organization_priest_id, op.priest_profile_id, v_span, v_buf,
         app.current_actor_id()
  FROM app.booking_assignments a
  JOIN app.organization_priests op ON op.id = a.organization_priest_id AND op.org_id = a.org_id
  WHERE a.booking_id = p_booking_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE app.bookings b SET buffer_overlap_ack = (jsonb_array_length(v_soft) > 0)
  WHERE b.id = p_booking_id AND b.buffer_overlap_ack IS DISTINCT FROM (jsonb_array_length(v_soft) > 0);

  -- History keeps the acknowledged spans by time only (no other booking's id).
  RETURN jsonb_build_object('reservations', v_n, 'acknowledged',
    (SELECT coalesce(jsonb_agg(x - 'booking_id'), '[]'::jsonb) FROM jsonb_array_elements(v_soft) AS x));
END
$$;

-- DRAFT -> CONFIRMED for a locked booking whose permission was checked: needs a time and a LEAD.
CREATE FUNCTION app._confirm(p_booking_id uuid, p_ack_buffer_overlap boolean) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_b app.bookings%ROWTYPE;
  v_r jsonb;
BEGIN
  SELECT * INTO v_b FROM app.bookings b WHERE b.id = p_booking_id AND b.org_id = app.current_tenant_id();
  IF v_b.starts_at IS NULL THEN
    PERFORM app.raise_error('PD422', 'TIME_REQUIRED', '{"field": "starts_at"}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.booking_assignments a WHERE a.booking_id = p_booking_id AND a.role = 'LEAD') THEN
    PERFORM app.raise_error('PD422', 'LEAD_REQUIRED', '{"field": "priest_ids"}');
  END IF;
  UPDATE app.bookings b
  SET status = 'CONFIRMED', confirmed_at = now(),
      buffer_before_min = coalesce(b.buffer_before_min, l.before_min),
      buffer_after_min  = coalesce(b.buffer_after_min, l.after_min)
  FROM app.booking_assignments a
  CROSS JOIN LATERAL app._link_buffers(a.organization_priest_id) l
  WHERE b.id = p_booking_id AND a.booking_id = b.id AND a.role = 'LEAD'
  RETURNING b.* INTO v_b;
  v_r := app._reserve_booking(p_booking_id, p_ack_buffer_overlap);
  PERFORM app._event(p_booking_id, 'CONFIRMED', jsonb_build_object(
    'starts_at', v_b.starts_at, 'ends_at', v_b.ends_at,
    'organization_priest_ids', to_jsonb(app._booking_priest_ids(p_booking_id)), 'reservations', v_r -> 'reservations'));
  IF jsonb_array_length(v_r -> 'acknowledged') > 0 THEN
    PERFORM app._event(p_booking_id, 'BUFFER_OVERLAP_ACKNOWLEDGED', jsonb_build_object('conflicts', v_r -> 'acknowledged'));
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- create_booking (BOOKING_CREATE; with p_confirm also BOOKING_CONFIRM, or BOOKING_CONFIRM_OWN as LEAD)
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.create_booking(
  p_fields jsonb, p_confirm boolean, p_ack_buffer_overlap boolean, p_idem_key text, p_request_hash text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay jsonb;
  v_key    text;
  v_org    app.organizations%ROWTYPE;
  v_b      app.bookings%ROWTYPE;
  v_priests uuid[];
  v_seq    bigint;
BEGIN
  PERFORM app.assert_permission('BOOKING_CREATE');
  IF coalesce(p_confirm, false) THEN
    PERFORM app._assert_any(ARRAY['BOOKING_CONFIRM', 'BOOKING_CONFIRM_OWN']);
  END IF;
  v_replay := app._idem_begin('create_booking', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "body"}');
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_fields) LOOP
    IF v_key NOT IN ('customer_id', 'offering_id', 'title', 'location', 'notes', 'agreed_dakshina_paise', 'timezone',
                     'local_date', 'starts_at', 'ends_at', 'is_time_tentative', 'buffer_before_min',
                     'buffer_after_min', 'priest_ids') THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', v_key));
    END IF;
  END LOOP;

  SELECT * INTO v_org FROM app.organizations o WHERE o.id = app.current_tenant_id();
  v_b.org_id := v_org.id;
  v_b.timezone := v_org.timezone;
  v_b.is_time_tentative := false;
  v_b := app._booking_apply(v_b, p_fields);
  v_priests := app._json_uuid_array(p_fields, 'priest_ids', 'priest_ids');
  IF cardinality(v_priests) > 0 THEN
    SELECT coalesce(v_b.buffer_before_min, l.before_min), coalesce(v_b.buffer_after_min, l.after_min)
    INTO v_b.buffer_before_min, v_b.buffer_after_min
    FROM app._link_buffers(v_priests[1]) l;
  END IF;

  -- The practice's counter, row-locked: numbers are never reused and never reset (spec revision 2.1 #16).
  UPDATE app.org_sequences s SET next_booking_no = s.next_booking_no + 1
  WHERE s.org_id = v_org.id
  RETURNING s.next_booking_no - 1 INTO v_seq;
  IF v_seq IS NULL THEN
    PERFORM app.raise_error('PD500', 'SEQUENCE_MISSING');
  END IF;

  INSERT INTO app.bookings (org_id, seq_no, booking_number, customer_id, offering_id, title, location, notes,
                            agreed_dakshina_paise, timezone, local_date, starts_at, ends_at, is_time_tentative,
                            buffer_before_min, buffer_after_min, created_by)
  VALUES (v_org.id, v_seq, app._format_booking_number(to_char(now() AT TIME ZONE v_org.timezone, 'YY'), v_seq),
          v_b.customer_id, v_b.offering_id, v_b.title, v_b.location, v_b.notes, v_b.agreed_dakshina_paise,
          v_b.timezone, v_b.local_date, v_b.starts_at, v_b.ends_at, v_b.is_time_tentative, v_b.buffer_before_min,
          v_b.buffer_after_min, app.current_actor_id())
  RETURNING * INTO v_b;

  IF v_priests IS NOT NULL AND cardinality(v_priests) > 0 THEN
    PERFORM app._set_assignments(v_b.id, v_priests);
  END IF;
  PERFORM app._event(v_b.id, 'CREATED', jsonb_build_object(
    'status', 'DRAFT', 'local_date', v_b.local_date, 'starts_at', v_b.starts_at, 'ends_at', v_b.ends_at,
    'customer_id', v_b.customer_id, 'offering_id', v_b.offering_id,
    'organization_priest_ids', to_jsonb(app._booking_priest_ids(v_b.id))));

  IF coalesce(p_confirm, false) THEN
    PERFORM app._assert_booking_permission(v_b.id, 'BOOKING_CONFIRM');
    PERFORM app._confirm(v_b.id, coalesce(p_ack_buffer_overlap, false));
  END IF;

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('booking', app._booking_out(v_b.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- confirm_booking (BOOKING_CONFIRM, or BOOKING_CONFIRM_OWN as LEAD before and after any priest change)
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.confirm_booking(
  p_booking_id uuid, p_expected_version integer, p_priest_ids uuid[], p_ack_buffer_overlap boolean, p_idem_key text,
  p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay jsonb;
  v_b      app.bookings%ROWTYPE;
BEGIN
  PERFORM app._assert_any(ARRAY['BOOKING_CONFIRM', 'BOOKING_CONFIRM_OWN']);
  v_replay := app._idem_begin('confirm_booking', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_b := app._lock_booking(p_booking_id, p_expected_version);
  PERFORM app._assert_booking_permission(v_b.id, 'BOOKING_CONFIRM');
  IF v_b.status <> 'DRAFT' THEN
    PERFORM app.raise_error('PD410', 'INVALID_TRANSITION', jsonb_build_object('from', v_b.status, 'to', 'CONFIRMED'));
  END IF;

  IF p_priest_ids IS NOT NULL AND p_priest_ids IS DISTINCT FROM app._booking_priest_ids(v_b.id) THEN
    PERFORM app._set_assignments(v_b.id, p_priest_ids);
    PERFORM app._assert_booking_permission(v_b.id, 'BOOKING_CONFIRM');  -- still his own booking (R1)
    PERFORM app._event(v_b.id, 'EDITED', '{"fields": ["priest_ids"]}');
  END IF;
  PERFORM app._confirm(v_b.id, coalesce(p_ack_buffer_overlap, false));

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('booking', app._booking_out(v_b.id)));
END
$$;


-- ---------------------------------------------------------------------------
-- reschedule_booking (BOOKING_CONFIRM, or BOOKING_CONFIRM_OWN as LEAD before and after any priest change): moves a
-- CONFIRMED booking (times, time zone, tentative flag, buffers, priests) atomically. A conflict rolls everything back,
-- so the original slot is untouched (spec AC-07). Reason codes only, never free text (spec defect 10).
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.reschedule_booking(
  p_booking_id uuid, p_expected_version integer, p_changes jsonb, p_reason_code text, p_ack_buffer_overlap boolean,
  p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay   jsonb;
  v_key      text;
  v_old      app.bookings%ROWTYPE;
  v_new      app.bookings%ROWTYPE;
  v_from     uuid[];
  v_to       uuid[];
  v_released integer;
  v_r        jsonb;
BEGIN
  PERFORM app._assert_any(ARRAY['BOOKING_CONFIRM', 'BOOKING_CONFIRM_OWN']);
  v_replay := app._idem_begin('reschedule_booking', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_old := app._lock_booking(p_booking_id, p_expected_version);
  PERFORM app._assert_booking_permission(v_old.id, 'BOOKING_CONFIRM');
  IF v_old.status <> 'CONFIRMED' THEN
    PERFORM app.raise_error('PD410', 'INVALID_TRANSITION', jsonb_build_object('from', v_old.status, 'to', 'CONFIRMED'));
  END IF;

  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "body"}');
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_changes) LOOP
    IF v_key NOT IN ('starts_at', 'ends_at', 'timezone', 'is_time_tentative', 'buffer_before_min', 'buffer_after_min',
                     'priest_ids') THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', v_key));
    END IF;
  END LOOP;
  IF p_reason_code IS NULL OR p_reason_code NOT IN ('CUSTOMER_REQUEST', 'PRIEST_REQUEST', 'MUHURAT_FIXED',
                                                    'PRIEST_CHANGED', 'CORRECTION', 'OTHER') THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "reason_code"}');
  END IF;

  v_new := app._booking_apply(v_old, p_changes);
  IF v_new.starts_at IS NULL THEN
    PERFORM app.raise_error('PD422', 'TIME_REQUIRED', '{"field": "starts_at"}');
  END IF;
  IF v_new.buffer_before_min IS NULL OR v_new.buffer_after_min IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED',
      jsonb_build_object('field', CASE WHEN v_new.buffer_before_min IS NULL THEN 'buffer_before_min'
                                       ELSE 'buffer_after_min' END));
  END IF;

  v_from := app._booking_priest_ids(v_old.id);
  v_to := CASE WHEN p_changes ? 'priest_ids'
               THEN coalesce(app._json_uuid_array(p_changes, 'priest_ids', 'priest_ids'), '{}') ELSE v_from END;
  IF cardinality(v_to) = 0 THEN
    PERFORM app.raise_error('PD422', 'LEAD_REQUIRED', '{"field": "priest_ids"}');
  END IF;
  -- A PRIEST (BOOKING_CONFIRM_OWN only) keeps leading the bookings he moves (R1).
  IF v_to IS DISTINCT FROM v_from AND NOT app.current_member_has('BOOKING_CONFIRM')
     AND NOT EXISTS (SELECT 1 FROM app.organization_priests op
                     WHERE op.id = v_to[1] AND op.org_id = app.current_tenant_id()
                       AND op.priest_profile_id = app.current_priest_profile_id()) THEN
    PERFORM app.raise_error('PD403', 'FORBIDDEN', '{"permission": "BOOKING_CONFIRM"}');
  END IF;
  IF v_to IS NOT DISTINCT FROM v_from
     AND (v_new.timezone, v_new.local_date, v_new.starts_at, v_new.ends_at, v_new.is_time_tentative,
          v_new.buffer_before_min, v_new.buffer_after_min)
         IS NOT DISTINCT FROM
         (v_old.timezone, v_old.local_date, v_old.starts_at, v_old.ends_at, v_old.is_time_tentative,
          v_old.buffer_before_min, v_old.buffer_after_min) THEN
    PERFORM app.raise_error('PD422', 'NOTHING_TO_CHANGE', '{"field": "body"}');
  END IF;

  UPDATE app.calendar_reservations r
  SET status = 'RELEASED', released_at = now(), released_by = app.current_actor_id()
  WHERE r.booking_id = v_old.id AND r.org_id = v_old.org_id AND r.status = 'ACTIVE';
  GET DIAGNOSTICS v_released = ROW_COUNT;
  UPDATE app.bookings b
  SET timezone = v_new.timezone, local_date = v_new.local_date, starts_at = v_new.starts_at, ends_at = v_new.ends_at,
      is_time_tentative = v_new.is_time_tentative, buffer_before_min = v_new.buffer_before_min,
      buffer_after_min = v_new.buffer_after_min
  WHERE b.id = v_old.id;
  IF v_to IS DISTINCT FROM v_from THEN
    PERFORM app._set_assignments(v_old.id, v_to);
  END IF;
  v_r := app._reserve_booking(v_old.id, coalesce(p_ack_buffer_overlap, false));

  PERFORM app._event(v_old.id, 'RESCHEDULED', jsonb_build_object(
    'from', jsonb_build_object('local_date', v_old.local_date, 'starts_at', v_old.starts_at, 'ends_at', v_old.ends_at,
                               'organization_priest_ids', to_jsonb(v_from)),
    'to', jsonb_build_object('local_date', v_new.local_date, 'starts_at', v_new.starts_at, 'ends_at', v_new.ends_at,
                             'organization_priest_ids', to_jsonb(v_to)),
    'reason_code', p_reason_code, 'released', v_released));
  IF jsonb_array_length(v_r -> 'acknowledged') > 0 THEN
    PERFORM app._event(v_old.id, 'BUFFER_OVERLAP_ACKNOWLEDGED', jsonb_build_object('conflicts', v_r -> 'acknowledged'));
  END IF;

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('booking', app._booking_out(v_old.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- Ownership hand-over and EXECUTE grants
-- ---------------------------------------------------------------------------
GRANT CREATE ON SCHEMA app TO app_domain;
ALTER FUNCTION app.create_booking(jsonb, boolean, boolean, text, text) OWNER TO app_domain;
ALTER FUNCTION app.confirm_booking(uuid, integer, uuid[], boolean, text, text) OWNER TO app_domain;
ALTER FUNCTION app.reschedule_booking(uuid, integer, jsonb, text, boolean, text, text) OWNER TO app_domain;
REVOKE CREATE ON SCHEMA app FROM app_domain;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app._reserve_booking(uuid, boolean), app._confirm(uuid, boolean) TO app_domain;
GRANT EXECUTE ON FUNCTION
  app.create_booking(jsonb, boolean, boolean, text, text),
  app.confirm_booking(uuid, integer, uuid[], boolean, text, text),
  app.reschedule_booking(uuid, integer, jsonb, text, boolean, text, text)
  TO app_runtime;

-- These functions are owned by app_domain. A GRANT by a user without the owner's rights only warns and grants
-- nothing, so check that every EXECUTE grant above is really in the ACL.
DO $$
DECLARE
  v record;
BEGIN
  FOR v IN
    SELECT x.fn, x.grantee
    FROM (VALUES
      ('app.create_booking(jsonb,boolean,boolean,text,text)', 'app_runtime'),
      ('app.confirm_booking(uuid,integer,uuid[],boolean,text,text)', 'app_runtime'),
      ('app.reschedule_booking(uuid,integer,jsonb,text,boolean,text,text)', 'app_runtime')
    ) AS x (fn, grantee)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_proc p CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) a
      WHERE p.oid = v.fn::regprocedure AND a.grantee = v.grantee::regrole AND a.privilege_type = 'EXECUTE'
    ) THEN
      RAISE EXCEPTION 'GRANT EXECUTE ON FUNCTION % TO % did not take effect', v.fn, v.grantee;
    END IF;
  END LOOP;
END
$$;

DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL TABLES IN SCHEMA app FROM %I', r);
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM %I', r);
      EXECUTE pg_catalog.format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA app FROM %I', r);
    END IF;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- End of the hand-over: the migration user keeps no application role's privileges (as after M1).
-- ---------------------------------------------------------------------------
REVOKE app_authz, app_bootstrap, app_domain, app_operator, app_freebusy FROM CURRENT_USER;

DO $$
DECLARE
  r     text;
  v_set boolean;
BEGIN
  IF (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = CURRENT_USER) THEN
    RETURN;
  END IF;
  FOREACH r IN ARRAY ARRAY['app_runtime', 'app_domain', 'app_authz', 'app_bootstrap', 'app_freebusy',
                           'app_maintenance', 'app_operator'] LOOP
    IF pg_catalog.current_setting('server_version_num')::int >= 160000 THEN
      v_set := pg_catalog.pg_has_role(CURRENT_USER, r, 'SET');
    ELSE
      v_set := pg_catalog.pg_has_role(CURRENT_USER, r, 'MEMBER');
    END IF;
    IF v_set OR pg_catalog.pg_has_role(CURRENT_USER, r, 'USAGE') THEN
      RAISE EXCEPTION 'migration user % is still a member of %', CURRENT_USER, r;
    END IF;
  END LOOP;
END
$$;
