-- M8 agenda, availability and calendar blocks: priest_busy (owner app_freebusy), create_block and release_block
-- (owner app_domain); conflict details name same-practice blocks; _priest_conflicts also sees blocks when no booking
-- is excluded; audit_log gains BLOCK_RELEASED. No new tables: blocks are calendar_reservations rows of kind BLOCK (M6).
-- Spec: docs/spec.md ADR-006, §04 §7, §05 §2/§4/§8, §08 §3, §11 §2/§5. Proposal: docs/proposals/m8.md.

-- The migration user is a member of the function-owning roles only until the end of this file (spec U1).
GRANT app_authz, app_bootstrap, app_domain, app_operator, app_freebusy TO CURRENT_USER;

-- ---------------------------------------------------------------------------
-- _priest_conflicts (owner app_freebusy, M6): M6's filter `booking_id IS DISTINCT FROM p_exclude_booking` dropped
-- every BLOCK row (booking_id NULL) when p_exclude_booking is NULL, which is how create_block calls it, so a block over
-- a block reached the exclusion constraint instead of BOOKING_CONFLICT with details. Exclude only the given booking.
-- CREATE OR REPLACE keeps the owner (app_freebusy) and the EXECUTE grant (app_domain only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app._priest_conflicts(
  p_priest_profile_id uuid, p_span tstzrange, p_buffer_span tstzrange, p_exclude_booking uuid
) RETURNS TABLE (conflict text, reservation_kind text, starts_at timestamptz, ends_at timestamptz,
                 same_org boolean, booking_id uuid)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_tenant uuid := app.current_tenant_id();
BEGIN
  IF app.current_actor_id() IS NULL OR v_tenant IS NULL THEN
    PERFORM app.raise_error('PD401', 'CONTEXT_MISSING');
  END IF;
  IF app.current_member_role() IS NULL THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "organization"}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.organization_priests op
                 WHERE op.org_id = v_tenant AND op.priest_profile_id = p_priest_profile_id) THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "priest"}');
  END IF;
  RETURN QUERY
  SELECT CASE WHEN r.span && p_span THEN 'CEREMONY' ELSE 'BUFFER' END,
         r.kind, lower(r.span), upper(r.span), r.org_id = v_tenant,
         CASE WHEN r.org_id = v_tenant THEN r.booking_id END
  FROM app.calendar_reservations r
  WHERE r.priest_profile_id = p_priest_profile_id AND r.status = 'ACTIVE'
    AND (p_exclude_booking IS NULL OR r.booking_id IS DISTINCT FROM p_exclude_booking)
    AND (r.span && p_buffer_span OR r.buffer_span && p_span)
  ORDER BY lower(r.span);
END
$$;

-- ---------------------------------------------------------------------------
-- audit_log (M5 table): releasing a block is audited too (founder review, 2 Nov 2026). M5 is applied and is not
-- edited; the action CHECK is widened here.
-- ---------------------------------------------------------------------------
ALTER TABLE app.audit_log DROP CONSTRAINT audit_log_action_check;
ALTER TABLE app.audit_log ADD CONSTRAINT audit_log_action_check
  CHECK (action IN ('ORG_UPDATED', 'BLOCK_CREATED', 'BLOCK_RELEASED', 'CUSTOMER_ERASED', 'EXPORT'));

-- ---------------------------------------------------------------------------
-- priest_busy (owner app_freebusy): the busy time of one priest of this practice, in every practice he serves.
-- Other practices' rows are anonymous: kind BUSY, no reservation or booking id (and app_freebusy cannot read notes).
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.priest_busy(p_organization_priest_id uuid, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (reservation_id uuid, kind text, starts_at timestamptz, ends_at timestamptz, same_org boolean,
               booking_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_tenant  uuid := app.current_tenant_id();
  v_profile uuid;
BEGIN
  PERFORM app.assert_permission('ORG_READ');
  SELECT op.priest_profile_id INTO v_profile
  FROM app.organization_priests op
  WHERE op.id = p_organization_priest_id AND op.org_id = v_tenant;
  IF v_profile IS NULL THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "priest"}');
  END IF;
  IF p_from IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "from"}');
  END IF;
  IF p_to IS NULL OR p_to <= p_from OR p_to - p_from > interval '62 days' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "to"}');
  END IF;
  RETURN QUERY
  SELECT CASE WHEN r.org_id = v_tenant THEN r.id END,
         CASE WHEN r.org_id = v_tenant THEN r.kind ELSE 'BUSY' END,
         lower(r.span), upper(r.span), r.org_id = v_tenant,
         CASE WHEN r.org_id = v_tenant THEN r.booking_id END
  FROM app.calendar_reservations r
  WHERE r.priest_profile_id = v_profile AND r.status = 'ACTIVE'
    AND r.span && tstzrange(p_from, p_to, '[)')
  ORDER BY lower(r.span), upper(r.span);
END
$$;

-- ---------------------------------------------------------------------------
-- Blocks (spec §05 §8): BLOCK_MANAGE, or BLOCK_MANAGE_OWN for the actor's own calendar.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app._assert_block_permission(p_organization_priest_id uuid) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF app.current_member_has('BLOCK_MANAGE') THEN
    RETURN;
  END IF;
  IF app.current_member_has('BLOCK_MANAGE_OWN') AND EXISTS (
    SELECT 1 FROM app.organization_priests op
    WHERE op.id = p_organization_priest_id AND op.org_id = app.current_tenant_id()
      AND op.priest_profile_id = app.current_priest_profile_id()) THEN
    RETURN;
  END IF;
  PERFORM app.raise_error('PD403', 'FORBIDDEN', '{"permission": "BLOCK_MANAGE"}');
END
$$;

CREATE FUNCTION app._block_out(r app.calendar_reservations) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', r.id, 'organization_priest_id', r.organization_priest_id, 'starts_at', lower(r.span),
    'ends_at', upper(r.span), 'note', r.note, 'status', r.status, 'created_at', r.created_at,
    'released_at', r.released_at, 'released_by', r.released_by)
$$;

CREATE FUNCTION app.create_block(
  p_organization_priest_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_note text, p_idem_key text,
  p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay  jsonb;
  v_profile uuid;
  v_note    text := nullif(btrim(p_note), '');
  v_span    tstzrange;
  v_conf    jsonb;
  v_r       app.calendar_reservations%ROWTYPE;
BEGIN
  PERFORM app._assert_any(ARRAY['BLOCK_MANAGE', 'BLOCK_MANAGE_OWN']);
  SELECT op.priest_profile_id INTO v_profile
  FROM app.organization_priests op
  WHERE op.id = p_organization_priest_id AND op.org_id = app.current_tenant_id();
  IF v_profile IS NULL THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "priest"}');
  END IF;
  PERFORM app._assert_block_permission(p_organization_priest_id);
  v_replay := app._idem_begin('create_block', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  IF p_starts_at IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "starts_at"}');
  END IF;
  IF p_ends_at IS NULL OR p_ends_at <= p_starts_at OR p_ends_at - p_starts_at > interval '31 days' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "ends_at"}');
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "note"}');
  END IF;
  v_span := tstzrange(p_starts_at, p_ends_at, '[)');

  -- Same per-human lock as bookings; ceremony time only (no buffer check for blocks, spec ADR-006).
  PERFORM pg_advisory_xact_lock(hashtextextended('priest:' || v_profile::text, 0));
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'organization_priest_id', p_organization_priest_id, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
           'same_org', c.same_org, 'booking_id', c.booking_id,
           'block', CASE WHEN c.same_org AND c.reservation_kind = 'BLOCK' THEN true END)) ORDER BY c.starts_at),
         '[]'::jsonb)
  INTO v_conf
  FROM app._priest_conflicts(v_profile, v_span, v_span, NULL) c
  WHERE c.conflict = 'CEREMONY';
  IF jsonb_array_length(v_conf) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = '23P01', MESSAGE = 'BOOKING_CONFLICT',
      DETAIL = jsonb_build_object('conflicts', v_conf)::text;
  END IF;

  INSERT INTO app.calendar_reservations
    (org_id, kind, organization_priest_id, priest_profile_id, span, buffer_span, note, created_by)
  VALUES (app.current_tenant_id(), 'BLOCK', p_organization_priest_id, v_profile, v_span, v_span, v_note,
          app.current_actor_id())
  RETURNING * INTO v_r;
  -- Audit: ids and times only, never the note (golden rule 8).
  PERFORM app._audit('BLOCK_CREATED', v_r.id, jsonb_build_object(
    'organization_priest_id', p_organization_priest_id, 'starts_at', p_starts_at, 'ends_at', p_ends_at));

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('block', app._block_out(v_r)));
END
$$;

CREATE FUNCTION app.release_block(p_block_id uuid, p_idem_key text, p_request_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay jsonb;
  v_r      app.calendar_reservations%ROWTYPE;
BEGIN
  PERFORM app._assert_any(ARRAY['BLOCK_MANAGE', 'BLOCK_MANAGE_OWN']);
  v_replay := app._idem_begin('release_block', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  SELECT * INTO v_r FROM app.calendar_reservations r
  WHERE r.id = p_block_id AND r.org_id = app.current_tenant_id() AND r.kind = 'BLOCK'
  FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "block"}');
  END IF;
  PERFORM app._assert_block_permission(v_r.organization_priest_id);
  IF v_r.status <> 'ACTIVE' THEN
    PERFORM app.raise_error('PD410', 'INVALID_TRANSITION', '{"from": "RELEASED", "to": "RELEASED"}');
  END IF;
  UPDATE app.calendar_reservations r
  SET status = 'RELEASED', released_at = now(), released_by = app.current_actor_id()
  WHERE r.id = v_r.id
  RETURNING * INTO v_r;
  -- Audit: ids and times only, never the note (golden rule 8).
  PERFORM app._audit('BLOCK_RELEASED', v_r.id, jsonb_build_object(
    'organization_priest_id', v_r.organization_priest_id, 'starts_at', lower(v_r.span), 'ends_at', upper(v_r.span)));
  RETURN app._idem_finish(p_idem_key, jsonb_build_object('block', app._block_out(v_r)));
END
$$;

-- ---------------------------------------------------------------------------
-- Conflict details name a same-practice block ("block": true); other practices stay anonymous.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app._reserve_booking(p_booking_id uuid, p_ack_buffer_overlap boolean) RETURNS jsonb
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
             'same_org', c.same_org, 'booking_id', c.booking_id,
             'block', CASE WHEN c.same_org AND c.reservation_kind = 'BLOCK' THEN true END))
             ORDER BY c.starts_at, a.position)
           FILTER (WHERE c.conflict = 'CEREMONY'), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'organization_priest_id', a.organization_priest_id, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
             'same_org', c.same_org, 'booking_id', c.booking_id,
             'block', CASE WHEN c.same_org AND c.reservation_kind = 'BLOCK' THEN true END))
             ORDER BY c.starts_at, a.position)
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


-- ---------------------------------------------------------------------------
-- Ownership hand-over and EXECUTE grants
-- ---------------------------------------------------------------------------
GRANT CREATE ON SCHEMA app TO app_domain, app_freebusy;
ALTER FUNCTION app.priest_busy(uuid, timestamptz, timestamptz) OWNER TO app_freebusy;
ALTER FUNCTION app.create_block(uuid, timestamptz, timestamptz, text, text, text) OWNER TO app_domain;
ALTER FUNCTION app.release_block(uuid, text, text) OWNER TO app_domain;
REVOKE CREATE ON SCHEMA app FROM app_domain, app_freebusy;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app._assert_block_permission(uuid), app._block_out(app.calendar_reservations) TO app_domain;
GRANT EXECUTE ON FUNCTION
  app.priest_busy(uuid, timestamptz, timestamptz),
  app.create_block(uuid, timestamptz, timestamptz, text, text, text),
  app.release_block(uuid, text, text)
  TO app_runtime;

-- These functions are owned by app_domain and app_freebusy. A GRANT by a user without the owner's rights only warns
-- and grants nothing, so check that every EXECUTE grant above is really in the ACL.
DO $$
DECLARE
  v record;
BEGIN
  FOR v IN
    SELECT x.fn, x.grantee
    FROM (VALUES
      ('app.priest_busy(uuid,timestamptz,timestamptz)', 'app_runtime'),
      ('app.create_block(uuid,timestamptz,timestamptz,text,text,text)', 'app_runtime'),
      ('app.release_block(uuid,text,text)', 'app_runtime')
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
