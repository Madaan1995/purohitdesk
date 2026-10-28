-- M5 catalog and settings: offerings, samagri templates, organization settings, priest buffers, audit log.
-- Fixtures: practice A with OWNER ua, PRIEST up (own profile linked), STAFF us, READ_ONLY ur; practice B (OWNER ub).
BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('a5000000-0000-0000-0000-000000000001', 'ua5@example.test'),
  ('a5000000-0000-0000-0000-000000000002', 'up5@example.test'),
  ('a5000000-0000-0000-0000-000000000003', 'us5@example.test'),
  ('a5000000-0000-0000-0000-000000000004', 'ur5@example.test'),
  ('b5000000-0000-0000-0000-000000000001', 'ub5@example.test');
INSERT INTO app.app_users (id, auth_user_id) SELECT id, id FROM auth.users WHERE email LIKE 'u_5@example.test';
INSERT INTO app.organizations (id, name, slug, created_by) VALUES
  ('a5000000-0000-0000-0000-0000000000aa', 'A5', 'a5', 'a5000000-0000-0000-0000-000000000001'),
  ('b5000000-0000-0000-0000-0000000000bb', 'B5', 'b5', 'b5000000-0000-0000-0000-000000000001');
INSERT INTO app.org_members (org_id, user_id, role) VALUES
  ('a5000000-0000-0000-0000-0000000000aa', 'a5000000-0000-0000-0000-000000000001', 'OWNER'),
  ('a5000000-0000-0000-0000-0000000000aa', 'a5000000-0000-0000-0000-000000000002', 'PRIEST'),
  ('a5000000-0000-0000-0000-0000000000aa', 'a5000000-0000-0000-0000-000000000003', 'STAFF'),
  ('a5000000-0000-0000-0000-0000000000aa', 'a5000000-0000-0000-0000-000000000004', 'READ_ONLY'),
  ('b5000000-0000-0000-0000-0000000000bb', 'b5000000-0000-0000-0000-000000000001', 'OWNER');
INSERT INTO app.priest_profiles (id, user_id, display_name) VALUES
  ('a5000000-0000-0000-0000-0000000000f1', 'a5000000-0000-0000-0000-000000000001', 'Owner Pandit'),
  ('a5000000-0000-0000-0000-0000000000f2', 'a5000000-0000-0000-0000-000000000002', 'Assistant Pandit');
INSERT INTO app.organization_priests (id, org_id, priest_profile_id, linked_via) VALUES
  ('a5000000-0000-0000-0000-0000000000e1', 'a5000000-0000-0000-0000-0000000000aa', 'a5000000-0000-0000-0000-0000000000f1', 'BOOTSTRAP'),
  ('a5000000-0000-0000-0000-0000000000e2', 'a5000000-0000-0000-0000-0000000000aa', 'a5000000-0000-0000-0000-0000000000f2', 'BOOTSTRAP');

SET ROLE app_runtime;
SELECT test.ctx('a5000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-0000000000aa');

-- ---------------------------------------------------------------- offerings
SELECT app.save_offering(NULL, NULL, jsonb_build_object('ceremony_type_id',
  (SELECT id FROM app.ceremony_types WHERE slug = 'griha-pravesh')), 'off-key-0001', repeat('a', 64)) AS o1 \gset
SELECT test.ok((:'o1'::jsonb ->> 'name_hi') = 'गृह प्रवेश' AND (:'o1'::jsonb ->> 'name_en') = 'Griha Pravesh'
  AND (:'o1'::jsonb ->> 'duration_min')::int = 180 AND (:'o1'::jsonb ->> 'is_active')::boolean
  AND (:'o1'::jsonb -> 'suggested_dakshina_paise') = 'null'::jsonb AND (:'o1'::jsonb ->> 'version')::int = 1,
  'offering from the catalog takes both names and the default duration');
SELECT (:'o1'::jsonb ->> 'id') AS off1 \gset

SELECT test.is(app.save_offering(:'off1', 1, '{"duration_min": 150, "suggested_dakshina_paise": 510000}',
  'off-key-0002', repeat('a', 64)) - 'idempotent_replay' - 'id' - 'ceremony_type_id',
  '{"name_hi": "गृह प्रवेश", "name_en": "Griha Pravesh", "duration_min": 150, "suggested_dakshina_paise": 510000,
    "is_active": true, "version": 2}'::jsonb, 'duration and suggested dakshina (paise) saved; version bumped');
SELECT test.throws(format($$SELECT app.save_offering(%L, 1, '{"duration_min": 120}', 'off-key-0003', repeat('a', 64))$$,
  :'off1'), 'PD409', 'stale offering version rejected', 'VERSION_CONFLICT');
SELECT test.throws(format($$SELECT app.save_offering(%L, 2, '{"duration_min": 10}', 'off-key-0004', repeat('a', 64))$$,
  :'off1'), 'PD422', 'duration below 15 minutes rejected', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT app.save_offering(%L, 2, '{"duration_min": 1441}', 'off-key-0005', repeat('a', 64))$$,
  :'off1'), 'PD422', 'duration above 1440 minutes rejected', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT app.save_offering(%L, 2, '{"duration_min": 90.5}', 'off-key-0006', repeat('a', 64))$$,
  :'off1'), 'PD422', 'fractional minutes rejected', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT app.save_offering(%L, 2, '{"suggested_dakshina_paise": -1}', 'off-key-0007',
  repeat('a', 64))$$, :'off1'), 'PD422', 'negative dakshina rejected', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT app.save_offering(%L, 2, '{"suggested_dakshina_paise": "5100"}', 'off-key-0008',
  repeat('a', 64))$$, :'off1'), 'PD422', 'dakshina must be a JSON integer (paise)', 'VALIDATION_FAILED');
SELECT test.throws(format($$SELECT app.save_offering(%L, 2, '{"ceremony_type_id": null}', 'off-key-0009', repeat('a', 64))$$,
  :'off1'), 'PD422', 'ceremony type of an offering is immutable', 'IMMUTABLE_FIELD');
SELECT test.is(app.save_offering(:'off1', 2, '{"suggested_dakshina_paise": null, "is_active": false}', 'off-key-0010',
  repeat('a', 64)) -> 'suggested_dakshina_paise', 'null'::jsonb, 'null clears the suggested dakshina');
SELECT test.throws($$SELECT app.save_offering(NULL, NULL, '{"name_hi": "कथा"}', 'off-key-0011', repeat('a', 64))$$,
  'PD422', 'custom offering needs both names and a duration', 'VALIDATION_FAILED');
SELECT app.save_offering(NULL, NULL, '{"name_hi": "अखंड रामायण", "name_en": "Akhand Ramayan", "duration_min": 1440}',
  'off-key-0012', repeat('a', 64)) ->> 'id' AS off2 \gset
SELECT test.ok(:'off2' IS NOT NULL, 'custom offering created');
SELECT test.throws($$SELECT app.save_offering(NULL, NULL, '{"name_hi": "x", "name_en": "akhand ramayan", "duration_min": 60}',
  'off-key-0013', repeat('a', 64))$$, '23505', 'offering names are unique per practice (case-insensitive)');
SELECT test.throws($$SELECT app.save_offering(NULL, NULL, '{"name_hi": "x", "name_en": "y", "duration_min": 60, "price": 1}',
  'off-key-0014', repeat('a', 64))$$, 'PD422', 'unknown offering fields rejected', 'VALIDATION_FAILED');

-- ---------------------------------------------------------------- samagri templates
SELECT app.save_samagri_template(NULL, NULL, :'off2', '[
  {"name": "Ghee", "quantity": "1 kg", "provided_by": "FAMILY"},
  {"name": "Ramayan granth", "provided_by": "PRIEST"},
  {"name": "फूल माला", "quantity": "5", "provided_by": "FAMILY"}]', 'tpl-key-0001', repeat('a', 64)) AS t1 \gset
SELECT test.is(:'t1'::jsonb -> 'items', '[
  {"position": 1, "name": "Ghee", "quantity": "1 kg", "provided_by": "FAMILY"},
  {"position": 2, "name": "Ramayan granth", "quantity": null, "provided_by": "PRIEST"},
  {"position": 3, "name": "फूल माला", "quantity": "5", "provided_by": "FAMILY"}]'::jsonb,
  'template stores FAMILY and PRIEST items in order');
SELECT (:'t1'::jsonb ->> 'id') AS tpl1 \gset
SELECT app.save_samagri_template(:'tpl1', 1, NULL, '[
  {"name": "फूल माला", "quantity": "5", "provided_by": "FAMILY"},
  {"name": "Ghee", "quantity": "1 kg", "provided_by": "FAMILY"},
  {"name": "Ramayan granth", "provided_by": "PRIEST"}]', 'tpl-key-0002', repeat('a', 64)) AS t2 \gset
SELECT test.is((SELECT string_agg(name, ' > ' ORDER BY position) FROM app.samagri_template_items
                WHERE template_id = :'tpl1'), 'फूल माला > Ghee > Ramayan granth', 'reorder is kept');
SELECT test.is((:'t2'::jsonb ->> 'version')::int, 2, 'every save bumps the template version');
SELECT test.throws(format($$SELECT app.save_samagri_template(%L, 1, NULL, '[]', 'tpl-key-0003', repeat('a', 64))$$,
  :'tpl1'), 'PD409', 'stale template version rejected', 'VERSION_CONFLICT');
SELECT test.throws(format($$SELECT app.save_samagri_template(NULL, NULL, %L, '[]', 'tpl-key-0004', repeat('a', 64))$$,
  :'off2'), '23505', 'one template per offering');
SELECT test.throws(format($$SELECT app.save_samagri_template(%L, 2, NULL, '[{"name": "x", "provided_by": "TEMPLE"}]',
  'tpl-key-0005', repeat('a', 64))$$, :'tpl1'), 'PD422', 'provided_by must be FAMILY or PRIEST', 'VALIDATION_FAILED');
DO $$
DECLARE v_detail text;
BEGIN
  PERFORM app.save_samagri_template((SELECT id FROM app.samagri_templates LIMIT 1), 2, NULL,
    '[{"name": "ok", "provided_by": "FAMILY"}, {"name": "  ", "provided_by": "FAMILY"}]', 'tpl-key-0006', repeat('a', 64));
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
  PERFORM test.is(v_detail::jsonb, '{"field": "items[1].name"}'::jsonb, 'item errors point at the item and field');
END $$;
SELECT test.throws(format($$SELECT app.save_samagri_template(%L, 2, NULL,
  (SELECT jsonb_agg(jsonb_build_object('name', 'i' || g, 'provided_by', 'FAMILY')) FROM generate_series(1, 101) g),
  'tpl-key-0007', repeat('a', 64))$$, :'tpl1'), 'PD422', 'at most 100 items', 'VALIDATION_FAILED');
SELECT test.is((SELECT count(*) FROM app.samagri_template_items WHERE template_id = :'tpl1'), 3::bigint,
  'a failed save leaves the items untouched');

-- ---------------------------------------------------------------- organization settings + audit
SELECT test.is(app.update_organization(1, '{"name": "  A5 Pooja Kendra "}', 'org-key-0001', repeat('a', 64)) ->> 'name',
  'A5 Pooja Kendra', 'practice renamed');
SELECT test.throws($$SELECT app.update_organization(2, '{"timezone": "IST"}', 'org-key-0002', repeat('a', 64))$$, 'PD422',
  'time-zone abbreviations are rejected (IANA names only)', 'VALIDATION_FAILED');
SELECT test.throws($$SELECT app.update_organization(1, '{"name": "x"}', 'org-key-0003', repeat('a', 64))$$, 'PD409',
  'stale organization version rejected', 'VERSION_CONFLICT');
SELECT test.throws($$SELECT app.update_organization(2, '{"slug": "mine"}', 'org-key-0004', repeat('a', 64))$$, 'PD422',
  'slug is not editable', 'IMMUTABLE_FIELD');
SELECT test.is(app.update_organization(2, '{"timezone": "Asia/Kathmandu"}', 'org-key-0005', repeat('a', 64)) ->> 'version',
  '3', 'time zone changed (version 3)');
SELECT test.is((SELECT jsonb_agg(data ORDER BY id) FROM app.audit_log),
  '[{"fields": ["name"]}, {"fields": ["timezone"]}]'::jsonb, 'ORG_UPDATED audit rows hold field names only');
SELECT test.is((SELECT count(*) FROM app.audit_log WHERE action = 'ORG_UPDATED'
                AND actor_user_id = 'a5000000-0000-0000-0000-000000000001'), 2::bigint, 'audit rows record the actor');

-- ---------------------------------------------------------------- priest buffers
SELECT test.is(app.update_priest_settings('a5000000-0000-0000-0000-0000000000e1', 45, 30, 'pr-key-0001', repeat('a', 64))
  - 'idempotent_replay', '{"id": "a5000000-0000-0000-0000-0000000000e1", "priest_profile_id":
  "a5000000-0000-0000-0000-0000000000f1", "display_name": "Owner Pandit", "default_buffer_before_min": 45,
  "default_buffer_after_min": 30}'::jsonb, 'OWNER changes default buffers to 45/30');
SELECT test.throws($$SELECT app.update_priest_settings('a5000000-0000-0000-0000-0000000000e1', 241, NULL, 'pr-key-0002',
  repeat('a', 64))$$, 'PD422', 'buffer above 240 minutes rejected', 'VALIDATION_FAILED');

SELECT test.ctx('a5000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-0000000000aa');
SELECT test.is(app.update_priest_settings('a5000000-0000-0000-0000-0000000000e2', NULL, 15, 'pr-key-0101', repeat('a', 64))
  ->> 'default_buffer_after_min', '15', 'a PRIEST may change his own buffers');
SELECT test.throws($$SELECT app.update_priest_settings('a5000000-0000-0000-0000-0000000000e1', 0, 0, 'pr-key-0102',
  repeat('a', 64))$$, 'PD403', 'a PRIEST cannot change another priest''s buffers', 'FORBIDDEN');
SELECT test.throws($$SELECT app.save_offering(NULL, NULL, '{"name_hi": "x", "name_en": "x", "duration_min": 60}',
  'pr-key-0103', repeat('a', 64))$$, 'PD403', 'PRIEST cannot edit the catalog', 'FORBIDDEN');
SELECT test.is((SELECT count(*) FROM app.audit_log), 0::bigint, 'PRIEST cannot read the audit log');

SELECT test.ctx('a5000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-0000000000aa');
SELECT test.throws($$SELECT app.update_priest_settings('a5000000-0000-0000-0000-0000000000e1', 0, 0, 'st-key-0001',
  repeat('a', 64))$$, 'PD403', 'STAFF cannot change buffers', 'FORBIDDEN');
SELECT test.throws($$SELECT app.update_organization(3, '{"name": "x"}', 'st-key-0002', repeat('a', 64))$$, 'PD403',
  'STAFF cannot change practice settings', 'FORBIDDEN');
SELECT test.is((SELECT count(*) FROM app.audit_log), 0::bigint, 'STAFF cannot read the audit log');

SELECT test.ctx('a5000000-0000-0000-0000-000000000004', 'a5000000-0000-0000-0000-0000000000aa');
SELECT test.throws(format($$SELECT app.save_offering(%L, 3, '{"duration_min": 60}', 'ro-key-0001', repeat('a', 64))$$,
  :'off1'), 'PD403', 'READ_ONLY cannot edit offerings', 'FORBIDDEN');
SELECT test.throws(format($$SELECT app.save_samagri_template(%L, 2, NULL, '[]', 'ro-key-0002', repeat('a', 64))$$,
  :'tpl1'), 'PD403', 'READ_ONLY cannot edit samagri lists', 'FORBIDDEN');
SELECT test.is((SELECT count(*) FROM app.offerings) + (SELECT count(*) FROM app.samagri_template_items), 5::bigint,
  'READ_ONLY can read offerings and samagri');

-- ---------------------------------------------------------------- another practice
SELECT test.ctx('b5000000-0000-0000-0000-000000000001', 'b5000000-0000-0000-0000-0000000000bb');
SELECT test.throws(format($$SELECT app.save_samagri_template(NULL, NULL, %L, '[]', 'b-key-0001', repeat('a', 64))$$,
  :'off2'), 'PD404', 'cannot attach a template to another practice''s offering', 'NOT_FOUND');
SELECT test.throws(format($$SELECT app.save_offering(%L, 3, '{"duration_min": 60}', 'b-key-0002', repeat('a', 64))$$,
  :'off1'), 'PD404', 'cannot edit another practice''s offering', 'NOT_FOUND');
SELECT test.throws($$SELECT app.update_priest_settings('a5000000-0000-0000-0000-0000000000e1', 0, 0, 'b-key-0003',
  repeat('a', 64))$$, 'PD404', 'another practice''s priest link is not found (404)', 'NOT_FOUND');
SELECT test.is((SELECT count(*) FROM app.samagri_templates) + (SELECT count(*) FROM app.audit_log), 0::bigint,
  'tenant B sees no templates or audit rows of A');

-- ---------------------------------------------------------------- the API role cannot write directly
SELECT test.ctx('a5000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-0000000000aa');
SELECT test.throws($$INSERT INTO app.audit_log (org_id, action) VALUES (app.current_tenant_id(), 'EXPORT')$$, '42501',
  'runtime cannot write the audit log');
SELECT test.throws($$DELETE FROM app.samagri_template_items$$, '42501', 'runtime cannot delete samagri items');
SELECT test.throws($$UPDATE app.offerings SET duration_min = 60$$, '42501', 'runtime cannot update offerings directly');
SELECT test.is((SELECT count(*) FROM app.audit_log), 2::bigint, 'OWNER reads the audit log (AUDIT_READ)');
RESET ROLE;

-- ---------------------------------------------------------------- audit log is append-only, even for app_domain
SET ROLE app_domain;
SELECT test.throws($$UPDATE app.audit_log SET data = '{}'$$, '42501', 'app_domain has no UPDATE on the audit log');
RESET ROLE;
SELECT test.throws($$UPDATE app.audit_log SET data = '{}'$$, 'PD405', 'audit entries are append-only (UPDATE)',
  'APPEND_ONLY');
SELECT test.throws($$DELETE FROM app.audit_log$$, 'PD405', 'recent audit entries cannot be deleted', 'APPEND_ONLY');
SELECT test.throws($$TRUNCATE app.audit_log$$, 'PD405', 'the audit log cannot be truncated', 'APPEND_ONLY');

ROLLBACK;
