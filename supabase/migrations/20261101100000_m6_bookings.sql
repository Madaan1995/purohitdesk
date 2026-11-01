-- M6 bookings: bookings, booking_assignments, calendar_reservations, booking_events; state guard, deferred
-- invariants, the exclusion constraint on the global priest identity; commands create_booking, update_booking,
-- confirm_booking, cancel_booking, complete_booking; read model get_booking; _reserve_booking and _priest_conflicts
-- (owner app_freebusy).
-- Spec: docs/spec.md ADR-006, ADR-007, ADR-013, §04 §3–§8, §05 §1–§5/§7/§9–§11, §08 §2–§3, §11 §2–§3.
-- Proposal: docs/proposals/m6.md. Travel-buffer conflicts and reschedule arrive in M7, blocks in M8.

-- ---------------------------------------------------------------------------
-- btree_gist: `priest_profile_id WITH =` in a GiST exclusion constraint. Supabase keeps extensions in the schema
-- `extensions`; elsewhere (the test harness) it goes to public. An extension that is already enabled is kept.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'extensions') THEN
    CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;
  ELSE
    CREATE EXTENSION IF NOT EXISTS btree_gist;
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- bookings
-- ---------------------------------------------------------------------------
CREATE TABLE app.bookings (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                uuid NOT NULL REFERENCES app.organizations (id),
  seq_no                bigint NOT NULL CHECK (seq_no >= 1),
  booking_number        text NOT NULL CHECK (booking_number ~ '^PD-[0-9]{2}-[0-9]{4,}$'),
  customer_id           uuid NOT NULL,
  offering_id           uuid NOT NULL,
  title                 text CHECK (char_length(btrim(title)) BETWEEN 1 AND 120),
  location              text CHECK (char_length(btrim(location)) BETWEEN 1 AND 500),
  notes                 text CHECK (char_length(btrim(notes)) BETWEEN 1 AND 2000),
  agreed_dakshina_paise bigint CHECK (agreed_dakshina_paise BETWEEN 0 AND 100000000000),
  status                text NOT NULL DEFAULT 'DRAFT'
                        CHECK (status IN ('DRAFT', 'CONFIRMED', 'COMPLETED', 'CANCELLED')),
  timezone              text NOT NULL,
  local_date            date NOT NULL,
  starts_at             timestamptz,
  ends_at               timestamptz,
  is_time_tentative     boolean NOT NULL DEFAULT false,
  buffer_before_min     integer CHECK (buffer_before_min BETWEEN 0 AND 360),
  buffer_after_min      integer CHECK (buffer_after_min BETWEEN 0 AND 360),
  buffer_overlap_ack    boolean NOT NULL DEFAULT false,
  source                text NOT NULL DEFAULT 'PRIEST_DIRECT' CHECK (source IN ('PRIEST_DIRECT')),
  created_via           text NOT NULL DEFAULT 'MANUAL' CHECK (created_via IN ('MANUAL')),
  cancel_reason         text CHECK (char_length(btrim(cancel_reason)) BETWEEN 3 AND 500),
  created_by            uuid NOT NULL REFERENCES app.app_users (id),
  confirmed_at          timestamptz,
  completed_at          timestamptz,
  cancelled_at          timestamptz,
  version               integer NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, org_id),
  UNIQUE (org_id, seq_no),
  UNIQUE (org_id, booking_number),
  FOREIGN KEY (customer_id, org_id) REFERENCES app.customers (id, org_id),
  FOREIGN KEY (offering_id, org_id) REFERENCES app.offerings (id, org_id),
  CONSTRAINT bookings_times_together CHECK ((starts_at IS NULL) = (ends_at IS NULL)),
  CONSTRAINT bookings_max_7_days CHECK (ends_at > starts_at AND ends_at - starts_at <= interval '7 days'),
  CONSTRAINT bookings_local_date CHECK (starts_at IS NULL OR local_date = (starts_at AT TIME ZONE timezone)::date),
  CONSTRAINT bookings_tentative_needs_time CHECK (NOT is_time_tentative OR starts_at IS NOT NULL),
  CONSTRAINT bookings_confirmed_has_schedule CHECK (
    status IN ('DRAFT', 'CANCELLED')
    OR (starts_at IS NOT NULL AND buffer_before_min IS NOT NULL AND buffer_after_min IS NOT NULL)),
  CONSTRAINT bookings_status_timestamps CHECK (CASE status
    WHEN 'DRAFT' THEN confirmed_at IS NULL AND completed_at IS NULL AND cancelled_at IS NULL
    WHEN 'CONFIRMED' THEN confirmed_at IS NOT NULL AND completed_at IS NULL AND cancelled_at IS NULL
    WHEN 'COMPLETED' THEN confirmed_at IS NOT NULL AND completed_at IS NOT NULL AND cancelled_at IS NULL
    ELSE cancelled_at IS NOT NULL AND completed_at IS NULL END),
  CONSTRAINT bookings_cancel_reason_only_cancelled CHECK (cancel_reason IS NULL OR status = 'CANCELLED')
);
CREATE INDEX bookings_org_starts_idx ON app.bookings (org_id, starts_at);
CREATE INDEX bookings_org_customer_idx ON app.bookings (org_id, customer_id, created_at DESC);
CREATE INDEX bookings_org_status_date_idx ON app.bookings (org_id, status, local_date);
CREATE INDEX bookings_org_date_seq_idx ON app.bookings (org_id, local_date, seq_no);

-- State machine and immutable columns (spec §05 §1, ADR-007). Raised directly (not via app.raise_error) so the
-- trigger works whichever role fires it.
CREATE FUNCTION app.tg_booking_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_field text;
BEGIN
  v_field := CASE
    WHEN NEW.id IS DISTINCT FROM OLD.id OR NEW.org_id IS DISTINCT FROM OLD.org_id THEN 'org_id'
    WHEN NEW.seq_no IS DISTINCT FROM OLD.seq_no OR NEW.booking_number IS DISTINCT FROM OLD.booking_number
      THEN 'booking_number'
    WHEN NEW.source IS DISTINCT FROM OLD.source THEN 'source'
    WHEN NEW.created_via IS DISTINCT FROM OLD.created_via THEN 'created_via'
    WHEN NEW.created_by IS DISTINCT FROM OLD.created_by THEN 'created_by'
    WHEN NEW.created_at IS DISTINCT FROM OLD.created_at THEN 'created_at'
  END;
  IF v_field IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'PD422', MESSAGE = 'IMMUTABLE_FIELD',
      DETAIL = pg_catalog.jsonb_build_object('field', v_field)::text;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status
     AND (OLD.status, NEW.status) NOT IN (('DRAFT', 'CONFIRMED'), ('DRAFT', 'CANCELLED'),
                                          ('CONFIRMED', 'COMPLETED'), ('CONFIRMED', 'CANCELLED')) THEN
    RAISE EXCEPTION USING ERRCODE = 'PD410', MESSAGE = 'INVALID_TRANSITION',
      DETAIL = pg_catalog.jsonb_build_object('from', OLD.status, 'to', NEW.status)::text;
  END IF;

  -- Terminal bookings: only notes may change, and free text may only be erased (spec ADR-007, §08 §5).
  IF OLD.status IN ('COMPLETED', 'CANCELLED')
     AND ((NEW.title IS DISTINCT FROM OLD.title AND NEW.title IS NOT NULL)
          OR (NEW.location IS DISTINCT FROM OLD.location AND NEW.location IS NOT NULL)
          OR (NEW.cancel_reason IS DISTINCT FROM OLD.cancel_reason AND NEW.cancel_reason IS NOT NULL)
          OR (NEW.customer_id, NEW.offering_id, NEW.agreed_dakshina_paise, NEW.status, NEW.timezone, NEW.local_date,
              NEW.starts_at, NEW.ends_at, NEW.is_time_tentative, NEW.buffer_before_min, NEW.buffer_after_min,
              NEW.buffer_overlap_ack, NEW.confirmed_at, NEW.completed_at, NEW.cancelled_at)
             IS DISTINCT FROM
             (OLD.customer_id, OLD.offering_id, OLD.agreed_dakshina_paise, OLD.status, OLD.timezone, OLD.local_date,
              OLD.starts_at, OLD.ends_at, OLD.is_time_tentative, OLD.buffer_before_min, OLD.buffer_after_min,
              OLD.buffer_overlap_ack, OLD.confirmed_at, OLD.completed_at, OLD.cancelled_at)) THEN
    RAISE EXCEPTION USING ERRCODE = 'PD410', MESSAGE = 'INVALID_TRANSITION',
      DETAIL = pg_catalog.jsonb_build_object('from', OLD.status, 'to', NEW.status)::text;
  END IF;
  RETURN NEW;
END
$$;

-- Bookings are never deleted (history, ledger and busy time refer to them).
CREATE FUNCTION app.tg_no_delete() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'PD405', MESSAGE = 'APPEND_ONLY',
    DETAIL = pg_catalog.jsonb_build_object('table', TG_TABLE_NAME)::text;
END
$$;

CREATE TRIGGER bookings_bump_version BEFORE UPDATE ON app.bookings
  FOR EACH ROW EXECUTE FUNCTION app.tg_bump_version();
CREATE TRIGGER bookings_guard BEFORE UPDATE ON app.bookings
  FOR EACH ROW EXECUTE FUNCTION app.tg_booking_guard();
CREATE TRIGGER bookings_validate_timezone BEFORE INSERT OR UPDATE OF timezone ON app.bookings
  FOR EACH ROW EXECUTE FUNCTION app.tg_validate_timezone('timezone');
CREATE TRIGGER bookings_no_delete BEFORE DELETE ON app.bookings
  FOR EACH ROW EXECUTE FUNCTION app.tg_no_delete();
CREATE TRIGGER bookings_no_truncate BEFORE TRUNCATE ON app.bookings
  FOR EACH STATEMENT EXECUTE FUNCTION app.tg_no_delete();

-- ---------------------------------------------------------------------------
-- booking_assignments: LEAD (position 1) + ASSISTANTs, at most 11 (spec §05 §5)
-- ---------------------------------------------------------------------------
CREATE TABLE app.booking_assignments (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL,
  booking_id             uuid NOT NULL,
  organization_priest_id uuid NOT NULL,
  role                   text NOT NULL CHECK (role IN ('LEAD', 'ASSISTANT')),
  position               smallint NOT NULL CHECK (position BETWEEN 1 AND 11),
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT booking_assignments_lead_first CHECK ((role = 'LEAD') = (position = 1)),
  UNIQUE (id, org_id),
  UNIQUE (booking_id, organization_priest_id),
  UNIQUE (booking_id, position),
  FOREIGN KEY (booking_id, org_id) REFERENCES app.bookings (id, org_id),
  FOREIGN KEY (organization_priest_id, org_id) REFERENCES app.organization_priests (id, org_id)
);
CREATE UNIQUE INDEX booking_assignments_one_lead ON app.booking_assignments (booking_id) WHERE role = 'LEAD';
CREATE INDEX booking_assignments_priest_idx ON app.booking_assignments (org_id, organization_priest_id);

-- ---------------------------------------------------------------------------
-- calendar_reservations: busy time of one human (BOOKING rows from M6, BLOCK rows from M8)
-- ---------------------------------------------------------------------------
CREATE TABLE app.calendar_reservations (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL,
  kind                   text NOT NULL CHECK (kind IN ('BOOKING', 'BLOCK')),
  booking_id             uuid,
  organization_priest_id uuid NOT NULL,
  priest_profile_id      uuid NOT NULL,
  span                   tstzrange NOT NULL,
  buffer_span            tstzrange NOT NULL,
  status                 text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'RELEASED')),
  note                   text CHECK (char_length(btrim(note)) BETWEEN 1 AND 500),
  created_by             uuid NOT NULL REFERENCES app.app_users (id),
  created_at             timestamptz NOT NULL DEFAULT now(),
  released_at            timestamptz,
  released_by            uuid REFERENCES app.app_users (id),
  CONSTRAINT calendar_reservations_booking_kind CHECK ((kind = 'BOOKING') = (booking_id IS NOT NULL)),
  CONSTRAINT calendar_reservations_note_only_block CHECK (note IS NULL OR kind = 'BLOCK'),
  CONSTRAINT calendar_reservations_span_valid CHECK (
    NOT isempty(span) AND lower_inc(span) AND NOT upper_inc(span) AND NOT lower_inf(span) AND NOT upper_inf(span)),
  CONSTRAINT calendar_reservations_buffer_covers CHECK (
    buffer_span @> span AND lower_inc(buffer_span) AND NOT upper_inc(buffer_span)),
  CONSTRAINT calendar_reservations_release CHECK ((status = 'RELEASED') = (released_at IS NOT NULL)),
  UNIQUE (id, org_id),
  FOREIGN KEY (org_id, organization_priest_id, priest_profile_id)
    REFERENCES app.organization_priests (org_id, id, priest_profile_id),
  FOREIGN KEY (booking_id, org_id) REFERENCES app.bookings (id, org_id),
  -- The hard guarantee (spec §05 §2): one human, no overlapping ceremony time, across every organization.
  CONSTRAINT calendar_reservations_no_overlap
    EXCLUDE USING gist (priest_profile_id WITH =, span WITH &&) WHERE (status = 'ACTIVE')
);
CREATE UNIQUE INDEX calendar_reservations_one_active_per_assignment
  ON app.calendar_reservations (booking_id, organization_priest_id) WHERE status = 'ACTIVE';
CREATE INDEX calendar_reservations_buffer_idx
  ON app.calendar_reservations USING gist (priest_profile_id, buffer_span) WHERE status = 'ACTIVE';
CREATE INDEX calendar_reservations_booking_idx ON app.calendar_reservations (org_id, booking_id);

-- Reservations are history: the only change is ACTIVE -> RELEASED (spec §04 §5).
CREATE FUNCTION app.tg_reservation_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status = 'ACTIVE' AND NEW.status = 'RELEASED'
     AND (NEW.id, NEW.org_id, NEW.kind, NEW.booking_id, NEW.organization_priest_id, NEW.priest_profile_id, NEW.span,
          NEW.buffer_span, NEW.note, NEW.created_by, NEW.created_at)
         IS NOT DISTINCT FROM
         (OLD.id, OLD.org_id, OLD.kind, OLD.booking_id, OLD.organization_priest_id, OLD.priest_profile_id, OLD.span,
          OLD.buffer_span, OLD.note, OLD.created_by, OLD.created_at) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'PD405', MESSAGE = 'APPEND_ONLY',
    DETAIL = '{"table": "calendar_reservations"}';
END
$$;
CREATE TRIGGER calendar_reservations_guard BEFORE UPDATE OR DELETE ON app.calendar_reservations
  FOR EACH ROW EXECUTE FUNCTION app.tg_reservation_guard();
CREATE TRIGGER calendar_reservations_no_truncate BEFORE TRUNCATE ON app.calendar_reservations
  FOR EACH STATEMENT EXECUTE FUNCTION app.tg_no_delete();

-- ---------------------------------------------------------------------------
-- booking_events: append-only history; ids, times, amounts, counts and codes only (golden rule 8)
-- ---------------------------------------------------------------------------
CREATE TABLE app.booking_events (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id        uuid NOT NULL,
  booking_id    uuid NOT NULL,
  event         text NOT NULL CHECK (event IN (
                  'CREATED', 'EDITED', 'CONFIRMED', 'RESCHEDULED', 'CANCELLED', 'COMPLETED',
                  'BUFFER_OVERLAP_ACKNOWLEDGED', 'SAMAGRI_ATTACHED', 'SHARE_PREPARED',
                  'PAYMENT_RECORDED', 'PAYMENT_REVERSED', 'PII_ERASED')),
  actor_user_id uuid REFERENCES app.app_users (id),
  data          jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(data) = 'object'),
  created_at    timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (booking_id, org_id) REFERENCES app.bookings (id, org_id)
);
CREATE INDEX booking_events_booking_idx ON app.booking_events (org_id, booking_id, created_at);
CREATE TRIGGER booking_events_append_only BEFORE UPDATE OR DELETE ON app.booking_events
  FOR EACH ROW EXECUTE FUNCTION app.tg_no_delete();
CREATE TRIGGER booking_events_no_truncate BEFORE TRUNCATE ON app.booking_events
  FOR EACH STATEMENT EXECUTE FUNCTION app.tg_no_delete();

-- ---------------------------------------------------------------------------
-- Deferred invariants (spec §04 §5): checked at COMMIT for every booking a statement touched.
-- CONFIRMED/COMPLETED: exactly one LEAD, at most 11 priests, and exactly one ACTIVE reservation per assigned priest
-- covering [starts_at, ends_at) with the booking's buffers; no ACTIVE reservation of an unassigned priest.
-- DRAFT/CANCELLED: no ACTIVE reservation. Runs as whichever role commits, under its RLS (the request context is still
-- set at COMMIT); raised directly so it does not depend on EXECUTE grants.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.tg_booking_invariants() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_id    uuid;
  v_b     app.bookings%ROWTYPE;
  v_lead  bigint;
  v_n     bigint;
  v_span  tstzrange;
  v_buf   tstzrange;
  v_bad   boolean;
BEGIN
  IF TG_TABLE_NAME = 'bookings' THEN
    v_id := NEW.id;
  ELSIF TG_OP = 'DELETE' THEN
    v_id := OLD.booking_id;
  ELSE
    v_id := NEW.booking_id;
  END IF;
  IF v_id IS NULL THEN
    RETURN NULL;  -- a BLOCK reservation
  END IF;
  SELECT * INTO v_b FROM app.bookings b WHERE b.id = v_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_b.status IN ('CONFIRMED', 'COMPLETED') THEN
    SELECT count(*) FILTER (WHERE a.role = 'LEAD'), count(*) INTO v_lead, v_n
    FROM app.booking_assignments a WHERE a.booking_id = v_id;
    v_span := tstzrange(v_b.starts_at, v_b.ends_at, '[)');
    v_buf  := tstzrange(v_b.starts_at - make_interval(mins => v_b.buffer_before_min),
                        v_b.ends_at + make_interval(mins => v_b.buffer_after_min), '[)');
    v_bad := v_lead <> 1 OR v_n > 11
      OR EXISTS (
        SELECT 1 FROM app.booking_assignments a
        WHERE a.booking_id = v_id
          AND (SELECT count(*) FROM app.calendar_reservations r
               WHERE r.booking_id = v_id AND r.organization_priest_id = a.organization_priest_id
                 AND r.kind = 'BOOKING' AND r.status = 'ACTIVE' AND r.span = v_span AND r.buffer_span = v_buf) <> 1)
      OR EXISTS (
        SELECT 1 FROM app.calendar_reservations r
        WHERE r.booking_id = v_id AND r.status = 'ACTIVE'
          AND NOT EXISTS (SELECT 1 FROM app.booking_assignments a
                          WHERE a.booking_id = v_id AND a.organization_priest_id = r.organization_priest_id));
  ELSE
    v_bad := EXISTS (SELECT 1 FROM app.calendar_reservations r WHERE r.booking_id = v_id AND r.status = 'ACTIVE');
  END IF;

  IF v_bad THEN
    RAISE EXCEPTION USING ERRCODE = 'PD500', MESSAGE = 'INVARIANT_VIOLATION',
      DETAIL = pg_catalog.jsonb_build_object('booking_id', v_id, 'status', v_b.status)::text;
  END IF;
  RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER bookings_invariants AFTER INSERT OR UPDATE ON app.bookings
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app.tg_booking_invariants();
CREATE CONSTRAINT TRIGGER booking_assignments_invariants AFTER INSERT OR UPDATE OR DELETE ON app.booking_assignments
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app.tg_booking_invariants();
CREATE CONSTRAINT TRIGGER calendar_reservations_invariants AFTER INSERT OR UPDATE ON app.calendar_reservations
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app.tg_booking_invariants();

-- ---------------------------------------------------------------------------
-- Row-level security (T = org_id is the current tenant and the actor is an ACTIVE member)
-- ---------------------------------------------------------------------------
ALTER TABLE app.bookings              ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.bookings              FORCE ROW LEVEL SECURITY;
ALTER TABLE app.booking_assignments   ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.booking_assignments   FORCE ROW LEVEL SECURITY;
ALTER TABLE app.calendar_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.calendar_reservations FORCE ROW LEVEL SECURITY;
ALTER TABLE app.booking_events        ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.booking_events        FORCE ROW LEVEL SECURITY;

CREATE POLICY bookings_read ON app.bookings
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY bookings_domain_insert ON app.bookings
  FOR INSERT TO app_domain
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL
              AND created_by = (SELECT app.current_actor_id()));
CREATE POLICY bookings_domain_update ON app.bookings
  FOR UPDATE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

CREATE POLICY booking_assignments_read ON app.booking_assignments
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY booking_assignments_domain_insert ON app.booking_assignments
  FOR INSERT TO app_domain
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY booking_assignments_domain_delete ON app.booking_assignments
  FOR DELETE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

CREATE POLICY calendar_reservations_read ON app.calendar_reservations
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY calendar_reservations_domain_insert ON app.calendar_reservations
  FOR INSERT TO app_domain
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL
              AND created_by = (SELECT app.current_actor_id()));
CREATE POLICY calendar_reservations_domain_update ON app.calendar_reservations
  FOR UPDATE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
-- Busy time across organizations (spec §08 §3): ACTIVE rows of every organization, but only while the actor is an
-- ACTIVE member of the current tenant, and only the busy-time columns (grant below). app_freebusy is NOLOGIN and is
-- reachable only through _priest_conflicts (and priest_busy in M8), which check the priest link and strip ids.
CREATE POLICY calendar_reservations_freebusy_read ON app.calendar_reservations
  FOR SELECT TO app_freebusy
  USING (status = 'ACTIVE' AND (SELECT app.current_member_role()) IS NOT NULL);

CREATE POLICY booking_events_read ON app.booking_events
  FOR SELECT TO app_runtime, app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY booking_events_domain_insert ON app.booking_events
  FOR INSERT TO app_domain
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL
              AND actor_user_id = (SELECT app.current_actor_id()));

-- Booking numbers (M2 table): app_domain reads and advances the current tenant's counter.
CREATE POLICY org_sequences_domain_read ON app.org_sequences
  FOR SELECT TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);
CREATE POLICY org_sequences_domain_update ON app.org_sequences
  FOR UPDATE TO app_domain
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL)
  WITH CHECK (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

-- app_freebusy verifies that the priest is linked to the caller's organization (M1 table).
CREATE POLICY organization_priests_freebusy_read ON app.organization_priests
  FOR SELECT TO app_freebusy
  USING (org_id = (SELECT app.current_tenant_id()) AND (SELECT app.current_member_role()) IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Grants (tables). app_runtime: SELECT only.
-- ---------------------------------------------------------------------------
REVOKE ALL ON app.bookings, app.booking_assignments, app.calendar_reservations, app.booking_events FROM PUBLIC;
GRANT SELECT ON app.bookings, app.booking_assignments, app.calendar_reservations, app.booking_events TO app_runtime;
GRANT SELECT, INSERT ON app.bookings TO app_domain;
GRANT UPDATE (customer_id, offering_id, title, location, notes, agreed_dakshina_paise, status, timezone, local_date,
              starts_at, ends_at, is_time_tentative, buffer_before_min, buffer_after_min, buffer_overlap_ack,
              cancel_reason, confirmed_at, completed_at, cancelled_at)
  ON app.bookings TO app_domain;
GRANT SELECT, INSERT, DELETE ON app.booking_assignments TO app_domain;
GRANT SELECT, INSERT ON app.calendar_reservations TO app_domain;
GRANT UPDATE (status, released_at, released_by) ON app.calendar_reservations TO app_domain;
GRANT INSERT ON app.booking_events TO app_domain;
GRANT SELECT, UPDATE (next_booking_no) ON app.org_sequences TO app_domain;
GRANT SELECT (id, org_id, organization_priest_id, priest_profile_id, booking_id, kind, status, span, buffer_span)
  ON app.calendar_reservations TO app_freebusy;
GRANT SELECT (id, org_id, priest_profile_id) ON app.organization_priests TO app_freebusy;

-- ---------------------------------------------------------------------------
-- JSON request readers (invoker). A wrong type or format is PD422 with details.field. JSON null -> NULL.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app._json_uuid(p jsonb, p_key text, p_field text) RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v text := app._json_text(p, p_key, p_field);
BEGIN
  IF v IS NULL THEN
    RETURN NULL;
  END IF;
  IF v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', p_field));
  END IF;
  RETURN v::uuid;
END
$$;

CREATE FUNCTION app._json_uuid_array(p jsonb, p_key text, p_field text) RETURNS uuid[]
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v   jsonb := p -> p_key;
  e   jsonb;
  out uuid[] := '{}';
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(v) <> 'array' THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', p_field));
  END IF;
  FOR e IN SELECT x FROM jsonb_array_elements(v) AS x LOOP
    IF jsonb_typeof(e) <> 'string'
       OR (e #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', p_field));
    END IF;
    out := array_append(out, (e #>> '{}')::uuid);
  END LOOP;
  RETURN out;
END
$$;

CREATE FUNCTION app._json_date(p jsonb, p_key text, p_field text) RETURNS date
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v text := app._json_text(p, p_key, p_field);
  d date;
BEGIN
  IF v IS NULL THEN
    RETURN NULL;
  END IF;
  IF v ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    BEGIN
      d := v::date;
    EXCEPTION WHEN others THEN
      d := NULL;
    END;
  END IF;
  IF d IS NULL OR to_char(d, 'YYYY-MM-DD') <> v THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', p_field));
  END IF;
  RETURN d;
END
$$;

-- RFC 3339 instant with an explicit offset ("Z" or ±hh:mm).
CREATE FUNCTION app._json_instant(p jsonb, p_key text, p_field text) RETURNS timestamptz
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v text := app._json_text(p, p_key, p_field);
  t timestamptz;
BEGIN
  IF v IS NULL THEN
    RETURN NULL;
  END IF;
  IF v ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}:[0-9]{2})$' THEN
    BEGIN
      t := v::timestamptz;
    EXCEPTION WHEN others THEN
      t := NULL;
    END;
  END IF;
  IF t IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', p_field));
  END IF;
  RETURN t;
END
$$;

-- ---------------------------------------------------------------------------
-- Booking helpers (invoker; run as the calling command's owner app_domain, under its RLS)
-- ---------------------------------------------------------------------------
-- PD-YY-NNNN; the number keeps growing after 9999 (spec revision 2.1 #16).
CREATE FUNCTION app._format_booking_number(p_year_2 text, p_seq bigint) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT 'PD-' || p_year_2 || '-' || CASE WHEN p_seq < 10000 THEN lpad(p_seq::text, 4, '0') ELSE p_seq::text END
$$;

-- Membership (PD401/PD404 via assert_permission) and then any of the permissions, before any validation (defect #4).
CREATE FUNCTION app._assert_any(p_permissions text[]) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  PERFORM app.assert_permission('BOOKING_READ');
  IF NOT EXISTS (SELECT 1 FROM unnest(p_permissions) AS p (name) WHERE app.current_member_has(p.name)) THEN
    PERFORM app.raise_error('PD403', 'FORBIDDEN', jsonb_build_object('permission', p_permissions[1]));
  END IF;
END
$$;

-- Is the actor the LEAD priest of this booking (his own global priest profile)?
CREATE FUNCTION app._is_booking_lead(p_booking_id uuid) RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM app.booking_assignments a
    JOIN app.organization_priests op ON op.id = a.organization_priest_id AND op.org_id = a.org_id
    WHERE a.booking_id = p_booking_id AND a.role = 'LEAD'
      AND op.priest_profile_id = app.current_priest_profile_id())
$$;

-- p_permission (e.g. BOOKING_CONFIRM), or its _OWN variant when the actor leads the booking (spec §05 §1).
CREATE FUNCTION app._assert_booking_permission(p_booking_id uuid, p_permission text) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF app.current_member_has(p_permission) THEN
    RETURN;
  END IF;
  IF app.current_member_has(p_permission || '_OWN') AND app._is_booking_lead(p_booking_id) THEN
    RETURN;
  END IF;
  PERFORM app.raise_error('PD403', 'FORBIDDEN', jsonb_build_object('permission', p_permission));
END
$$;

CREATE FUNCTION app._lock_booking(p_booking_id uuid, p_expected_version integer) RETURNS app.bookings
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v app.bookings%ROWTYPE;
BEGIN
  SELECT * INTO v FROM app.bookings b
  WHERE b.id = p_booking_id AND b.org_id = app.current_tenant_id()
  FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "booking"}');
  END IF;
  IF p_expected_version IS NULL OR v.version <> p_expected_version THEN
    PERFORM app.raise_error('PD409', 'VERSION_CONFLICT', jsonb_build_object('current_version', v.version));
  END IF;
  RETURN v;
END
$$;

CREATE FUNCTION app._event(p_booking_id uuid, p_event text, p_data jsonb) RETURNS void
LANGUAGE sql
SET search_path = ''
AS $$
  INSERT INTO app.booking_events (org_id, booking_id, event, actor_user_id, data)
  VALUES (app.current_tenant_id(), p_booking_id, p_event, app.current_actor_id(), coalesce(p_data, '{}'::jsonb));
$$;

CREATE FUNCTION app._booking_priest_ids(p_booking_id uuid) RETURNS uuid[]
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT coalesce(array_agg(a.organization_priest_id ORDER BY a.position), '{}')
  FROM app.booking_assignments a WHERE a.booking_id = p_booking_id
$$;

-- Validates p_priest_ids (organization_priest ids of this practice, distinct, at most 11; first = LEAD) and replaces
-- the booking's assignments with them.
CREATE FUNCTION app._set_assignments(p_booking_id uuid, p_priest_ids uuid[]) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF p_priest_ids IS NULL OR cardinality(p_priest_ids) > 11
     OR (SELECT count(DISTINCT x) FROM unnest(p_priest_ids) AS x) <> cardinality(p_priest_ids)
     OR (SELECT count(*) FROM app.organization_priests op
         WHERE op.id = ANY (p_priest_ids) AND op.org_id = app.current_tenant_id()) <> cardinality(p_priest_ids) THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "priest_ids"}');
  END IF;
  DELETE FROM app.booking_assignments a WHERE a.booking_id = p_booking_id;
  INSERT INTO app.booking_assignments (org_id, booking_id, organization_priest_id, role, position)
  SELECT app.current_tenant_id(), p_booking_id, x.id, CASE WHEN x.n = 1 THEN 'LEAD' ELSE 'ASSISTANT' END, x.n
  FROM unnest(p_priest_ids) WITH ORDINALITY AS x (id, n);
END
$$;

-- Applies the request fields onto p_b (DRAFT defaults or the current row) and validates them. Field rules:
-- docs/proposals/m6.md §3. local_date is derived from starts_at in the booking's time zone; a given local_date must
-- match it. Returns the new row values (not yet written).
CREATE FUNCTION app._booking_apply(p_b app.bookings, p_fields jsonb) RETURNS app.bookings
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v      app.bookings%ROWTYPE := p_b;
  v_text text;
  v_id   uuid;
  v_date date;
BEGIN
  IF p_fields ? 'customer_id' THEN
    v_id := app._json_uuid(p_fields, 'customer_id', 'customer_id');
    IF v_id IS NULL THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "customer_id"}');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM app.customers c
                                   WHERE c.id = v_id AND c.org_id = app.current_tenant_id() AND c.erased_at IS NULL) THEN
      PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "customer"}');
    END IF;
    v.customer_id := v_id;
  END IF;
  IF p_fields ? 'offering_id' THEN
    v_id := app._json_uuid(p_fields, 'offering_id', 'offering_id');
    IF v_id IS NULL THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "offering_id"}');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM app.offerings o
                                   WHERE o.id = v_id AND o.org_id = app.current_tenant_id()) THEN
      PERFORM app.raise_error('PD404', 'NOT_FOUND', '{"resource": "offering"}');
    END IF;
    v.offering_id := v_id;
  END IF;
  IF p_fields ? 'title' THEN
    v.title := nullif(btrim(app._json_text(p_fields, 'title', 'title')), '');
    IF char_length(v.title) > 120 THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "title"}');
    END IF;
  END IF;
  IF p_fields ? 'location' THEN
    v.location := nullif(btrim(app._json_text(p_fields, 'location', 'location')), '');
    IF char_length(v.location) > 500 THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "location"}');
    END IF;
  END IF;
  IF p_fields ? 'notes' THEN
    v.notes := nullif(btrim(app._json_text(p_fields, 'notes', 'notes')), '');
    IF char_length(v.notes) > 2000 THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "notes"}');
    END IF;
  END IF;
  IF p_fields ? 'agreed_dakshina_paise' THEN
    v.agreed_dakshina_paise := app._json_int(p_fields, 'agreed_dakshina_paise', 'agreed_dakshina_paise');
    IF v.agreed_dakshina_paise NOT BETWEEN 0 AND 100000000000 THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "agreed_dakshina_paise"}');
    END IF;
  END IF;
  IF p_fields ? 'timezone' THEN
    v_text := app._json_text(p_fields, 'timezone', 'timezone');
    IF NOT app.is_valid_timezone(v_text) THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "timezone"}');
    END IF;
    v.timezone := v_text;
  END IF;
  IF p_fields ? 'starts_at' THEN
    v.starts_at := app._json_instant(p_fields, 'starts_at', 'starts_at');
  END IF;
  IF p_fields ? 'ends_at' THEN
    v.ends_at := app._json_instant(p_fields, 'ends_at', 'ends_at');
  END IF;
  IF p_fields ? 'is_time_tentative' THEN
    v.is_time_tentative := coalesce(app._json_bool(p_fields, 'is_time_tentative', 'is_time_tentative'), false);
  END IF;
  IF p_fields ? 'buffer_before_min' THEN
    v.buffer_before_min := app._json_int(p_fields, 'buffer_before_min', 'buffer_before_min');
    IF v.buffer_before_min NOT BETWEEN 0 AND 360 THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "buffer_before_min"}');
    END IF;
  END IF;
  IF p_fields ? 'buffer_after_min' THEN
    v.buffer_after_min := app._json_int(p_fields, 'buffer_after_min', 'buffer_after_min');
    IF v.buffer_after_min NOT BETWEEN 0 AND 360 THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "buffer_after_min"}');
    END IF;
  END IF;

  -- Times: both or neither, end after start, at most 7 days (spec ADR-013).
  IF (v.starts_at IS NULL) <> (v.ends_at IS NULL) THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED',
      jsonb_build_object('field', CASE WHEN v.starts_at IS NULL THEN 'starts_at' ELSE 'ends_at' END));
  END IF;
  IF v.starts_at IS NOT NULL AND (v.ends_at <= v.starts_at OR v.ends_at - v.starts_at > interval '7 days') THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "ends_at"}');
  END IF;
  IF v.is_time_tentative AND v.starts_at IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "is_time_tentative"}');
  END IF;

  -- The local date is the start's date in the booking's time zone; without times the request names the date.
  v_date := CASE WHEN p_fields ? 'local_date' THEN app._json_date(p_fields, 'local_date', 'local_date')
                 ELSE v.local_date END;
  IF v.starts_at IS NOT NULL THEN
    IF p_fields ? 'local_date' AND v_date IS NOT NULL
       AND v_date <> (v.starts_at AT TIME ZONE v.timezone)::date THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "local_date"}');
    END IF;
    v_date := (v.starts_at AT TIME ZONE v.timezone)::date;
  END IF;
  IF v_date IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "local_date"}');
  END IF;
  v.local_date := v_date;

  IF v.customer_id IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "customer_id"}');
  END IF;
  IF v.offering_id IS NULL THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "offering_id"}');
  END IF;
  RETURN v;
END
$$;

-- The default travel buffers of a priest link of this practice (NULLs when it is not one): a booking copies its
-- LEAD's defaults for every buffer the request leaves unset (spec §05 §6).
CREATE FUNCTION app._link_buffers(p_organization_priest_id uuid, OUT before_min integer, OUT after_min integer)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT op.default_buffer_before_min, op.default_buffer_after_min
  FROM app.organization_priests op
  WHERE op.id = p_organization_priest_id AND op.org_id = app.current_tenant_id()
$$;

-- The booking read model (spec: get_booking / _booking_out). Invoker: the caller's RLS decides what it sees.
CREATE FUNCTION app._booking_out(p_booking_id uuid) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', b.id, 'booking_number', b.booking_number, 'status', b.status,
    'customer', jsonb_build_object('id', c.id, 'display_name', c.display_name),
    'offering', jsonb_build_object('id', o.id, 'name_hi', o.name_hi, 'name_en', o.name_en,
                                   'duration_min', o.duration_min),
    'title', b.title, 'location', b.location, 'notes', b.notes,
    'agreed_dakshina_paise', b.agreed_dakshina_paise,
    'timezone', b.timezone, 'local_date', b.local_date, 'starts_at', b.starts_at, 'ends_at', b.ends_at,
    'is_time_tentative', b.is_time_tentative,
    'buffer_before_min', b.buffer_before_min, 'buffer_after_min', b.buffer_after_min,
    'buffer_overlap_ack', b.buffer_overlap_ack,
    'source', b.source, 'created_via', b.created_via, 'cancel_reason', b.cancel_reason,
    'priests', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'organization_priest_id', a.organization_priest_id, 'priest_profile_id', op.priest_profile_id,
               'display_name', pp.display_name, 'role', a.role) ORDER BY a.position)
      FROM app.booking_assignments a
      JOIN app.organization_priests op ON op.id = a.organization_priest_id AND op.org_id = a.org_id
      JOIN app.priest_profiles pp ON pp.id = op.priest_profile_id
      WHERE a.booking_id = b.id), '[]'::jsonb),
    'confirmed_at', b.confirmed_at, 'completed_at', b.completed_at, 'cancelled_at', b.cancelled_at,
    'created_at', b.created_at, 'updated_at', b.updated_at, 'version', b.version)
  FROM app.bookings b
  JOIN app.customers c ON c.id = b.customer_id AND c.org_id = b.org_id
  JOIN app.offerings o ON o.id = b.offering_id AND o.org_id = b.org_id
  WHERE b.id = p_booking_id
$$;

-- ---------------------------------------------------------------------------
-- _priest_conflicts (owner app_freebusy): busy time of one human in every organization.
-- Verifies the priest is linked to the caller's organization; other organizations' rows come back without ids.
-- VOLATILE on purpose: each call takes a fresh snapshot, so it sees what committed while the caller waited on the
-- priest's advisory lock (spec §05 §3).
-- ---------------------------------------------------------------------------
CREATE FUNCTION app._priest_conflicts(
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
    AND r.booking_id IS DISTINCT FROM p_exclude_booking
    AND (r.span && p_buffer_span OR r.buffer_span && p_span)
  ORDER BY lower(r.span);
END
$$;

-- ---------------------------------------------------------------------------
-- _reserve_booking (invoker, run by the commands as app_domain): spec §05 §3. M6 checks ceremony overlap only;
-- buffer-only overlaps are detected from M7.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app._reserve_booking(p_booking_id uuid) RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_b     app.bookings%ROWTYPE;
  v_span  tstzrange;
  v_buf   tstzrange;
  v_prof  uuid;
  v_conf  jsonb;
  v_n     integer;
BEGIN
  SELECT * INTO v_b FROM app.bookings b WHERE b.id = p_booking_id AND b.org_id = app.current_tenant_id();
  v_span := tstzrange(v_b.starts_at, v_b.ends_at, '[)');
  v_buf  := tstzrange(v_b.starts_at - make_interval(mins => v_b.buffer_before_min),
                      v_b.ends_at + make_interval(mins => v_b.buffer_after_min), '[)');

  -- One human at a time, always in the same order (no deadlocks).
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
           'same_org', c.same_org, 'booking_id', c.booking_id)) ORDER BY c.starts_at, a.position), '[]'::jsonb)
  INTO v_conf
  FROM app.booking_assignments a
  JOIN app.organization_priests op ON op.id = a.organization_priest_id AND op.org_id = a.org_id
  CROSS JOIN LATERAL app._priest_conflicts(op.priest_profile_id, v_span, v_buf, p_booking_id) c
  WHERE a.booking_id = p_booking_id AND c.conflict = 'CEREMONY';
  IF jsonb_array_length(v_conf) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = '23P01', MESSAGE = 'BOOKING_CONFLICT',
      DETAIL = jsonb_build_object('conflicts', v_conf)::text;
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
  RETURN v_n;
END
$$;

-- DRAFT -> CONFIRMED for a locked booking whose permission was checked: needs a time and a LEAD.
CREATE FUNCTION app._confirm(p_booking_id uuid) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_b app.bookings%ROWTYPE;
  v_n integer;
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
  v_n := app._reserve_booking(p_booking_id);
  PERFORM app._event(p_booking_id, 'CONFIRMED', jsonb_build_object(
    'starts_at', v_b.starts_at, 'ends_at', v_b.ends_at,
    'organization_priest_ids', to_jsonb(app._booking_priest_ids(p_booking_id)), 'reservations', v_n));
END
$$;

-- ---------------------------------------------------------------------------
-- create_booking (BOOKING_CREATE; with p_confirm also BOOKING_CONFIRM, or BOOKING_CONFIRM_OWN as LEAD)
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.create_booking(p_fields jsonb, p_confirm boolean, p_idem_key text, p_request_hash text)
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
    PERFORM app._confirm(v_b.id);
  END IF;

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('booking', app._booking_out(v_b.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- update_booking (BOOKING_EDIT): JSON patch, optimistic version check (spec §05 §1 editing rules).
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.update_booking(
  p_booking_id uuid, p_expected_version integer, p_patch jsonb, p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay  jsonb;
  v_key     text;
  v_old     app.bookings%ROWTYPE;
  v_new     app.bookings%ROWTYPE;
  v_priests uuid[];
  v_changed text[] := '{}';
BEGIN
  PERFORM app.assert_permission('BOOKING_EDIT');
  v_replay := app._idem_begin('update_booking', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_old := app._lock_booking(p_booking_id, p_expected_version);

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' OR p_patch = '{}'::jsonb THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "body"}');
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_patch) LOOP
    IF v_key IN ('id', 'org_id', 'booking_number', 'seq_no', 'status', 'source', 'created_via', 'created_by',
                 'version', 'cancel_reason', 'buffer_overlap_ack', 'confirmed_at', 'completed_at', 'cancelled_at',
                 'created_at', 'updated_at') THEN
      PERFORM app.raise_error('PD422', 'IMMUTABLE_FIELD', jsonb_build_object('field', v_key));
    ELSIF v_key NOT IN ('customer_id', 'offering_id', 'title', 'location', 'notes', 'agreed_dakshina_paise',
                        'timezone', 'local_date', 'starts_at', 'ends_at', 'is_time_tentative', 'buffer_before_min',
                        'buffer_after_min', 'priest_ids') THEN
      PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', jsonb_build_object('field', v_key));
    ELSIF v_old.status IN ('COMPLETED', 'CANCELLED') AND v_key <> 'notes' THEN
      PERFORM app.raise_error('PD410', 'INVALID_TRANSITION', jsonb_build_object('from', v_old.status, 'to', v_old.status));
    ELSIF v_old.status = 'CONFIRMED'
          AND v_key IN ('timezone', 'local_date', 'starts_at', 'ends_at', 'is_time_tentative', 'buffer_before_min',
                        'buffer_after_min', 'priest_ids') THEN
      PERFORM app.raise_error('PD422', 'USE_RESCHEDULE', jsonb_build_object('field', v_key));
    END IF;
  END LOOP;

  v_new := app._booking_apply(v_old, p_patch);

  IF p_patch ? 'priest_ids' THEN
    v_priests := coalesce(app._json_uuid_array(p_patch, 'priest_ids', 'priest_ids'), '{}');
    -- A PRIEST (BOOKING_CONFIRM_OWN only) may reassign only a booking he leads, and must still lead it (R1).
    IF NOT app.current_member_has('BOOKING_CONFIRM') AND app.current_member_has('BOOKING_CONFIRM_OWN')
       AND (NOT app._is_booking_lead(v_old.id)
            OR cardinality(v_priests) = 0
            OR NOT EXISTS (SELECT 1 FROM app.organization_priests op
                           WHERE op.id = v_priests[1] AND op.org_id = app.current_tenant_id()
                             AND op.priest_profile_id = app.current_priest_profile_id())) THEN
      PERFORM app.raise_error('PD403', 'FORBIDDEN', '{"permission": "BOOKING_CONFIRM"}');
    END IF;
    IF v_priests IS DISTINCT FROM app._booking_priest_ids(v_old.id) THEN
      v_changed := array_append(v_changed, 'priest_ids');
    END IF;
    IF cardinality(v_priests) > 0 THEN
      SELECT coalesce(v_new.buffer_before_min, l.before_min), coalesce(v_new.buffer_after_min, l.after_min)
      INTO v_new.buffer_before_min, v_new.buffer_after_min
      FROM app._link_buffers(v_priests[1]) l;
    END IF;
  END IF;

  SELECT coalesce(array_agg(f ORDER BY f), '{}') || v_changed INTO v_changed
  FROM (VALUES
    ('customer_id', v_new.customer_id::text IS DISTINCT FROM v_old.customer_id::text),
    ('offering_id', v_new.offering_id::text IS DISTINCT FROM v_old.offering_id::text),
    ('title', v_new.title IS DISTINCT FROM v_old.title),
    ('location', v_new.location IS DISTINCT FROM v_old.location),
    ('notes', v_new.notes IS DISTINCT FROM v_old.notes),
    ('agreed_dakshina_paise', v_new.agreed_dakshina_paise IS DISTINCT FROM v_old.agreed_dakshina_paise),
    ('timezone', v_new.timezone IS DISTINCT FROM v_old.timezone),
    ('local_date', v_new.local_date IS DISTINCT FROM v_old.local_date),
    ('starts_at', v_new.starts_at IS DISTINCT FROM v_old.starts_at),
    ('ends_at', v_new.ends_at IS DISTINCT FROM v_old.ends_at),
    ('is_time_tentative', v_new.is_time_tentative IS DISTINCT FROM v_old.is_time_tentative),
    ('buffer_before_min', v_new.buffer_before_min IS DISTINCT FROM v_old.buffer_before_min),
    ('buffer_after_min', v_new.buffer_after_min IS DISTINCT FROM v_old.buffer_after_min)
  ) AS x (f, changed)
  WHERE x.changed;

  IF cardinality(v_changed) > 0 THEN
    UPDATE app.bookings b
    SET customer_id = v_new.customer_id, offering_id = v_new.offering_id, title = v_new.title,
        location = v_new.location, notes = v_new.notes, agreed_dakshina_paise = v_new.agreed_dakshina_paise,
        timezone = v_new.timezone, local_date = v_new.local_date, starts_at = v_new.starts_at,
        ends_at = v_new.ends_at, is_time_tentative = v_new.is_time_tentative,
        buffer_before_min = v_new.buffer_before_min, buffer_after_min = v_new.buffer_after_min
    WHERE b.id = v_old.id;
    IF 'priest_ids' = ANY (v_changed) THEN
      IF cardinality(v_priests) = 0 THEN
        DELETE FROM app.booking_assignments a WHERE a.booking_id = v_old.id;
      ELSE
        PERFORM app._set_assignments(v_old.id, v_priests);
      END IF;
    END IF;
    PERFORM app._event(v_old.id, 'EDITED', jsonb_build_object('fields', to_jsonb(v_changed)));
  END IF;

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('booking', app._booking_out(v_old.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- confirm_booking (BOOKING_CONFIRM, or BOOKING_CONFIRM_OWN as LEAD before and after any priest change)
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.confirm_booking(
  p_booking_id uuid, p_expected_version integer, p_priest_ids uuid[], p_idem_key text, p_request_hash text
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
  PERFORM app._confirm(v_b.id);

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('booking', app._booking_out(v_b.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- cancel_booking (BOOKING_CANCEL, or BOOKING_CANCEL_OWN as LEAD): from DRAFT or CONFIRMED; releases the slots.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.cancel_booking(
  p_booking_id uuid, p_expected_version integer, p_reason text, p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay jsonb;
  v_b      app.bookings%ROWTYPE;
  v_reason text := nullif(btrim(p_reason), '');
  v_n      integer;
BEGIN
  PERFORM app._assert_any(ARRAY['BOOKING_CANCEL', 'BOOKING_CANCEL_OWN']);
  v_replay := app._idem_begin('cancel_booking', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_b := app._lock_booking(p_booking_id, p_expected_version);
  PERFORM app._assert_booking_permission(v_b.id, 'BOOKING_CANCEL');
  IF v_b.status NOT IN ('DRAFT', 'CONFIRMED') THEN
    PERFORM app.raise_error('PD410', 'INVALID_TRANSITION', jsonb_build_object('from', v_b.status, 'to', 'CANCELLED'));
  END IF;
  IF (v_b.status = 'CONFIRMED' AND v_reason IS NULL)
     OR (v_reason IS NOT NULL AND char_length(v_reason) NOT BETWEEN 3 AND 500) THEN
    PERFORM app.raise_error('PD422', 'VALIDATION_FAILED', '{"field": "reason"}');
  END IF;

  UPDATE app.calendar_reservations r
  SET status = 'RELEASED', released_at = now(), released_by = app.current_actor_id()
  WHERE r.booking_id = v_b.id AND r.org_id = v_b.org_id AND r.status = 'ACTIVE';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE app.bookings b SET status = 'CANCELLED', cancelled_at = now(), cancel_reason = v_reason
  WHERE b.id = v_b.id;
  PERFORM app._event(v_b.id, 'CANCELLED', jsonb_build_object('from', v_b.status, 'released', v_n));

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('booking', app._booking_out(v_b.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- complete_booking (BOOKING_COMPLETE, or BOOKING_COMPLETE_OWN as LEAD): CONFIRMED and already started; the
-- reservations stay ACTIVE as historical busy time.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.complete_booking(
  p_booking_id uuid, p_expected_version integer, p_idem_key text, p_request_hash text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_replay jsonb;
  v_b      app.bookings%ROWTYPE;
BEGIN
  PERFORM app._assert_any(ARRAY['BOOKING_COMPLETE', 'BOOKING_COMPLETE_OWN']);
  v_replay := app._idem_begin('complete_booking', p_idem_key, p_request_hash);
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_b := app._lock_booking(p_booking_id, p_expected_version);
  PERFORM app._assert_booking_permission(v_b.id, 'BOOKING_COMPLETE');
  IF v_b.status <> 'CONFIRMED' THEN
    PERFORM app.raise_error('PD410', 'INVALID_TRANSITION', jsonb_build_object('from', v_b.status, 'to', 'COMPLETED'));
  END IF;
  IF now() < v_b.starts_at THEN
    PERFORM app.raise_error('PD422', 'NOT_STARTED', '{"field": "starts_at"}');
  END IF;

  UPDATE app.bookings b SET status = 'COMPLETED', completed_at = now() WHERE b.id = v_b.id;
  PERFORM app._event(v_b.id, 'COMPLETED', '{}');

  RETURN app._idem_finish(p_idem_key, jsonb_build_object('booking', app._booking_out(v_b.id)));
END
$$;

-- ---------------------------------------------------------------------------
-- get_booking (BOOKING_READ: every role; SECURITY INVOKER, so RLS decides): the read model or NULL.
-- ---------------------------------------------------------------------------
CREATE FUNCTION app.get_booking(p_booking_id uuid) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT app._booking_out(b.id) FROM app.bookings b
  WHERE b.id = p_booking_id AND b.org_id = app.current_tenant_id()
$$;

-- ---------------------------------------------------------------------------
-- Ownership hand-over and EXECUTE grants.
-- The migration user is a member of the function-owning roles only until the end of this file: the hand-over and the
-- schema-wide REVOKE ... FROM PUBLIC need the owners' rights (spec U1).
-- ---------------------------------------------------------------------------
GRANT app_authz, app_bootstrap, app_domain, app_operator, app_freebusy TO CURRENT_USER;

GRANT CREATE ON SCHEMA app TO app_domain, app_freebusy;
ALTER FUNCTION app._priest_conflicts(uuid, tstzrange, tstzrange, uuid) OWNER TO app_freebusy;
ALTER FUNCTION app.create_booking(jsonb, boolean, text, text) OWNER TO app_domain;
ALTER FUNCTION app.update_booking(uuid, integer, jsonb, text, text) OWNER TO app_domain;
ALTER FUNCTION app.confirm_booking(uuid, integer, uuid[], text, text) OWNER TO app_domain;
ALTER FUNCTION app.cancel_booking(uuid, integer, text, text, text) OWNER TO app_domain;
ALTER FUNCTION app.complete_booking(uuid, integer, text, text) OWNER TO app_domain;
REVOKE CREATE ON SCHEMA app FROM app_domain, app_freebusy;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  app._json_uuid(jsonb, text, text), app._json_uuid_array(jsonb, text, text), app._json_date(jsonb, text, text),
  app._json_instant(jsonb, text, text), app._format_booking_number(text, bigint), app._assert_any(text[]),
  app._is_booking_lead(uuid), app._assert_booking_permission(uuid, text), app._lock_booking(uuid, integer),
  app._event(uuid, text, jsonb), app._booking_priest_ids(uuid), app._set_assignments(uuid, uuid[]),
  app._booking_apply(app.bookings, jsonb), app._link_buffers(uuid), app._booking_out(uuid),
  app._priest_conflicts(uuid, tstzrange, tstzrange, uuid), app._reserve_booking(uuid), app._confirm(uuid),
  app.get_booking(uuid)
  TO app_domain;
GRANT EXECUTE ON FUNCTION
  app.create_booking(jsonb, boolean, text, text),
  app.update_booking(uuid, integer, jsonb, text, text),
  app.confirm_booking(uuid, integer, uuid[], text, text),
  app.cancel_booking(uuid, integer, text, text, text),
  app.complete_booking(uuid, integer, text, text),
  app.get_booking(uuid), app._booking_out(uuid)
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
      ('app._priest_conflicts(uuid,tstzrange,tstzrange,uuid)', 'app_domain'),
      ('app.create_booking(jsonb,boolean,text,text)', 'app_runtime'),
      ('app.update_booking(uuid,integer,jsonb,text,text)', 'app_runtime'),
      ('app.confirm_booking(uuid,integer,uuid[],text,text)', 'app_runtime'),
      ('app.cancel_booking(uuid,integer,text,text,text)', 'app_runtime'),
      ('app.complete_booking(uuid,integer,text,text)', 'app_runtime'),
      ('app.get_booking(uuid)', 'app_runtime'),
      ('app._booking_out(uuid)', 'app_runtime')
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
