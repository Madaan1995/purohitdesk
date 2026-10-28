PurohitDesk
Priest-services app. Full spec: docs/spec.md. Build plan: docs/plan.md.
Read both before planning any work.
Stack
Next.js (App Router), TypeScript strict, Supabase (Postgres, Auth, RLS), Vercel.
Commands
npm run dev
npm run lint
npm run typecheck   (tsc --noEmit)
npm test
npm run build
Rules
Do not invent tables, columns, env vars, roles or features. If the spec doesn't cover it, stop and ask me.
Never connect to any real or shared database or use real DB credentials. A throwaway Postgres (local sandbox or CI container) for tests is allowed. Write migrations as new SQL files in supabase/migrations/ only; I review and apply them. Never edit a migration that has been applied.
Every new table has RLS enabled with explicit policies in the same migration.
Secrets never go in code. List every new env variable (no values) in .env.example.
Work only on the current milestone. No drive-by refactors.
Before calling anything done: run lint, typecheck and tests, and show me the real output.
Commit in small steps with clear messages, on a feature branch. Never push to or merge into main.
Anything marked PROPOSED (columns, function bodies, response shapes, seed data, file names) needs my approval before it is built on.

Architecture in one paragraph
One Next.js app at the repo root is a thin shell on Vercel bom1: it verifies the Supabase JWT (JWKS), validates input with Zod, and calls one PostgreSQL command function per write through withTenantTx. All business invariants live in PostgreSQL: tenant isolation (FORCE RLS + membership), permissions (app.role_permissions), the booking state machine, the double-booking exclusion constraint, idempotency, append-only history. The API login role app_runtime can SELECT (under RLS) and EXECUTE commands; it cannot INSERT, UPDATE or DELETE anything.

Repository map
src/app/              Next.js App Router pages and /api/v1 route handlers
src/domain/           pure TS: types, errors, permissions, money, share/whatsapp (no I/O, no framework imports)
src/db/               withTenantTx, command(), DomainError (the only place that imports the database driver)
src/adapters/         vendor SDK adapters (voice is out of scope until M14)
supabase/migrations/  SQL migrations, applied by the founder in filename order
supabase/seed/        reference data (ceremony catalog)
supabase/checks/      read-only verification scripts the founder runs after applying a migration
supabase/ops/         operator scripts and runbooks (e.g. adding test members with other roles)
supabase/tests/       SQL tests, run only against a throwaway Postgres
api/openapi.yaml      API contract, written per milestone
docs/                 spec.md (architecture), plan.md (build plan)

Golden rules (from the spec; never break)
1. Database access only through src/db (withTenantTx). Never import postgres elsewhere. Never open a transaction yourself. Never SET anything except via withTenantTx.
2. Writes only through app.* command functions. Never write INSERT/UPDATE/DELETE in TypeScript. A new write = a new or changed SQL function + SQL test + OpenAPI x-db-function + route handler.
3. Never use the Supabase service-role key, BYPASSRLS, SECURITY DEFINER owned by a login role, or the Data API for the app schema.
4. Every new tenant table: org_id + UNIQUE (id, org_id) + composite FKs to other tenant tables + ENABLE and FORCE RLS + role-scoped policies (TO app_domain, TO app_runtime ..., never PUBLIC) + grants, all in the same migration, plus a tenant-swap test.
5. Every SECURITY DEFINER function: SET search_path = '', schema-qualified names, owner is a NOLOGIN role, REVOKE EXECUTE ... FROM PUBLIC, explicit GRANT.
6. Money is integer paise (bigint / number branded Paise). Never floats, never rupees in storage.
7. Time is timestamptz (UTC) + IANA timezone + local_date. Never naive timestamps. Never compute "today" from the server clock for a user; use the org time zone.
8. No new free text in append-only tables. booking_events and audit_log hold ids, times, amounts and codes only. The only free-text columns in append-only tables are payment_entries.note/external_ref (erasable to NULL) and calendar_reservations.note (BLOCK rows only). Do not add others.
9. AI never writes. Voice produces a draft; only create_booking called after the priest confirms may save. The LLM receives the transcript and offering names only. Dates, times and amounts are resolved by src/domain, never by the model.
10. No PII in logs, errors or analytics (names, phones, addresses, transcripts, message text).
11. Migrations are forward-only. Never use an ORM migration generator.
12. Don't build P1/P2 features (invitations, public pages, WhatsApp API, reminders, billing, marketplace) or anything outside the current milestone in docs/plan.md.

How to add or change a write (recipe)
1. SQL, in a new migration: app.<command>(..., p_idem_key text, p_request_hash text). Pattern: _require_ctx() -> assert_permission() (or _assert_any + _assert_booking_permission for _OWN) -> _idem_begin() -> lock row (_lock_booking / FOR UPDATE) -> version check -> validate (raise PD422 with details.field) -> write -> _event()/_audit() -> RETURN _idem_finish(key, result).
2. Ownership, same migration: GRANT CREATE ON SCHEMA app TO app_domain; ALTER FUNCTION ... OWNER TO app_domain; REVOKE CREATE ON SCHEMA app FROM app_domain; then REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC; and GRANT EXECUTE ON FUNCTION ... TO app_runtime;
3. Tests in supabase/tests: positive, permission-denied, cross-tenant, version conflict, idempotent replay; for scheduling, a two-session race.
4. Contract: add the operation to api/openapi.yaml with operationId, x-db-function, x-permission, typed request/response and error responses.
5. TS: Zod schema mirroring the OpenAPI component; route handler following docs/spec.md section 11 §4; map errors only through mapDatabaseError.
6. Run lint, typecheck, tests (and the SQL suite on a throwaway Postgres) and show the real output.

Error handling
Database errors carry SQLSTATE PDxxx (ours) or 23xxx (constraints). Map them with mapDatabaseError (docs/spec.md section 11 §3). Never expose PostgreSQL DETAIL except our own JSON (PD-class and 23P01). PD405, PD500 and 42501 mean a bug: log with request_id, return 500.

UI rules (pandits on cheap Android phones)
Hindi first, English toggle (next-intl, no locale in the URL); Devanagari font subset; 16 px min text, 44 px tap targets; works at 360 px; agenda route <= 200 KB JS gzipped; no blocking spinners over 1 s without text; every destructive action confirms; conflicts explained in plain Hindi ("इस समय पंडित जी की दूसरी पूजा है").

When to stop and ask
A change needs BYPASSRLS, the service-role key, a new login role, a policy TO PUBLIC, storing audio, sending data to a new vendor, a new env var, a P1/P2 feature, a breaking API change, or editing an applied migration.
