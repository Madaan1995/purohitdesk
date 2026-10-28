# PurohitDesk — Build Plan

Source of truth for *what* to build: `docs/spec.md` (revision 2.1). Rules for *how*: `CLAUDE.md`. This file is the build order.
Each milestone is a thin end-to-end slice the founder verifies in a browser on a Vercel preview (Milestone 1, which has no UI, is verified in the Supabase dashboard).
Voice is out of scope for this plan (M14 is a placeholder). No dates: milestones are done in order.

## How every milestone runs

- [ ] Branch from the latest `main` as `m<N>-<topic>`. The founder does all merges; nothing is pushed to `main`.
- [ ] **Proposal first.** Write `docs/proposals/m<N>.md` with everything the spec does not pin down for this milestone: full columns and constraints, function signatures and bodies (in outline), RLS policies and grants, API request/response shapes, UI screens, test list, any new env var. Everything in it is marked PROPOSED. **Stop until the founder approves.**
- [ ] Build only what was approved: migrations in `supabase/migrations/` (RLS, policies and grants in the same migration as their table), `supabase/checks/` verification script, SQL tests in `supabase/tests/` (throwaway Postgres only), `api/openapi.yaml` operations, TypeScript in `src/`, Hindi and English strings.
- [ ] Run `npm run lint`, `npm run typecheck`, `npm test`, `npm run build` (and the SQL suite once it exists) and paste the real output.
- [ ] CI green on the pull request.
- [ ] Update `docs/spec.md` if an approved proposal changed the design; tick this checklist.
- [ ] Push the branch; the founder applies migrations to staging, runs the verification steps below, and merges.

Definition of done for every milestone: all of the above, plus the milestone's verification list passed by the founder.

---

## M0 — Project setup

**Delivers**
- One Next.js app at the repo root (App Router, `src/` directory, Tailwind), npm.
- Module folders `src/domain`, `src/db`, `src/adapters` (each with a short README), and an ESLint rule that stops `src/domain` from importing `next`, `react` or any I/O module.
- TypeScript `strict` (plus `erasableSyntaxOnly`, as the spec's typecheck used), `npm run typecheck` = `tsc --noEmit`.
- ESLint flat config with `eslint-config-next`.
- Vitest with real tests (see below).
- `GET /api/v1/healthz` → `200 {"status":"ok","commit":"<git sha>"}`, never cached.
- Placeholder home page: "PurohitDesk" / "पुरोहित डेस्क" with a placeholder theme colour.
- `vercel.json` pinning functions to `bom1`.
- `.github/workflows/ci.yml`: on every pull request, `npm ci`, lint, typecheck, test, build on Node 22.
- Empty `supabase/migrations/` (`.gitkeep`) and `.env.example`.

**Versions** (stable over newest; checked on npm 28 Oct 2026)

| Package | Version | Why |
| --- | --- | --- |
| next | 16.4.3 | Current stable; spec requires App Router (Next 15+) |
| react, react-dom | 19.3.1 | Current React 19 stable; `create-next-app` 16.4.3 installs `^19` |
| typescript | 5.9.3 | `create-next-app` 16.4.3 pins `^5`, so this is the officially supported line (not 7.x); 5.9 supports `erasableSyntaxOnly` |
| eslint | 9.39.5 | `create-next-app` 16.4.3 pins `^9` (not 10.x) |
| eslint-config-next | 16.4.3 | Matches Next |
| tailwindcss, @tailwindcss/postcss | 4.3.3 | `create-next-app` 16.4.3 pins `^4` |
| vitest | 4.1.12 | Mature, still patched; 5.0 is under two months old |
| @types/node | 22.x | Matches the Node 22 runtime |
| Node | `engines: >=22.18` | Spec ADR-001; Vercel Node 22.x |

**Tables:** none.
**Env vars:** none to set. The health check reads `VERCEL_GIT_COMMIT_SHA`, which Vercel provides automatically; it is listed in `.env.example` as "set by Vercel, do not set", and the route returns `"unknown"` when it is absent (local runs).
**Domain/unit tests (PROPOSED):** health route returns exactly `{status, commit}` with 200 and `Cache-Control: no-store`; commit falls back to `"unknown"`.

**Build checklist**
- [ ] Scaffold app and module folders; lint boundary rule for `src/domain`
- [ ] `typecheck`, `lint`, `test`, `build` scripts; Vitest tests
- [ ] `/api/v1/healthz`
- [ ] Placeholder bilingual home page with Tailwind
- [ ] `vercel.json` (`bom1`), `.env.example`, `supabase/migrations/.gitkeep`
- [ ] `.github/workflows/ci.yml`
- [ ] Real output of lint, typecheck, test, build shown

**Founder verification**
- [ ] In Vercel (Hobby), import the GitHub repo; framework Next.js; root directory `/`.
- [ ] Open the PR's preview URL: the page shows "PurohitDesk" and "पुरोहित डेस्क".
- [ ] Open `<preview>/api/v1/healthz`: `{"status":"ok","commit":"<sha>"}` where `<sha>` matches the branch's latest commit.
- [ ] Vercel deployment → Functions/Runtime logs: the healthz function ran in `bom1`.
- [ ] GitHub PR → Checks: CI is green.
- [ ] Repo has `supabase/migrations/` (empty) and `.env.example`.

---

## M1 — Foundation schema with RLS

**Delivers**
- Earliest migration: schema `app`; the six roles `app_runtime`, `app_domain`, `app_authz`, `app_bootstrap`, `app_freebusy`, `app_maintenance` (NOLOGIN, NOBYPASSRLS; the founder gives `app_runtime` LOGIN and a password in M2); shared helpers `current_actor_id()`, `current_tenant_id()`, `raise_error()`, `is_valid_timezone()`, triggers for version bump and append-only.
- Identity and tenancy migration: tables below, each with ENABLE + FORCE RLS, role-scoped policies and grants in the same file; membership helpers owned by `app_authz` (`current_member_role`, `current_member_has`, `is_active_member_of`, `current_priest_profile_id`, `assert_permission`); the `role_permissions` matrix from spec §08.
- `supabase/seed/ceremony_types.sql` (20 ceremonies, idempotent upsert).
- `supabase/checks/m1_checks.sql`: read-only, prints PASS/FAIL per check.
- SQL test harness run by `npm run test:db` (runner PROPOSED: `supabase/tests/run.sh` via psql) applying migrations to a throwaway Postgres as a non-superuser `pd_migrator`, with a stub `auth.users`; CI job with a Postgres service container of the **same major version as staging**.
- Tests: RLS forced on every table; no PUBLIC policy or EXECUTE; no role BYPASSRLS/SUPERUSER; `app_runtime` has no INSERT/UPDATE/DELETE; missing context → zero rows; `is_valid_timezone` accepts `Asia/Kolkata` and rejects `IST`.

**Tables:** `role_permissions`, `app_users`, `organizations`, `org_members`, `priest_profiles`, `organization_priests`, `ceremony_types`.
**Env vars:** none.

**Seed proposal (PROPOSED — founder to correct names and durations)**

| slug | English | हिन्दी | Default minutes |
| --- | --- | --- | --- |
| griha-pravesh | Griha Pravesh | गृह प्रवेश | 180 |
| satyanarayan-katha | Satyanarayan Katha | सत्यनारायण कथा | 120 |
| mundan | Mundan Sanskar | मुंडन संस्कार | 90 |
| namkaran | Namkaran Sanskar | नामकरण संस्कार | 60 |
| annaprashan | Annaprashan | अन्नप्राशन | 60 |
| upanayan | Upanayan (Janeu) Sanskar | उपनयन (जनेऊ) संस्कार | 180 |
| vivah | Vivah | विवाह | 360 |
| rudrabhishek | Rudrabhishek | रुद्राभिषेक | 120 |
| havan | Havan | हवन | 90 |
| bhoomi-pujan | Bhoomi Pujan | भूमि पूजन | 90 |
| vastu-shanti | Vastu Shanti | वास्तु शांति | 180 |
| navgrah-shanti | Navgrah Shanti | नवग्रह शांति | 180 |
| kaal-sarp-dosh | Kaal Sarp Dosh Puja | कालसर्प दोष पूजा | 180 |
| mahamrityunjay-jaap | Mahamrityunjay Jaap | महामृत्युंजय जाप | 240 |
| sunderkand-path | Sunderkand Path | सुंदरकांड पाठ | 180 |
| mata-ki-chowki | Mata ki Chowki | माता की चौकी | 180 |
| jagran | Jagran | जागरण | 480 |
| bhagwat-katha | Shrimad Bhagwat Katha | श्रीमद्भागवत कथा | 240 |
| shraddh | Shraddh | श्राद्ध | 120 |
| terahvin | Terahvin | तेरहवीं | 180 |

Punjabi names stay NULL until P1.

**Build checklist**
- [ ] Proposal approved (columns, policies, helper bodies, check script, test harness, seed), including a concrete example migration file name for the PROPOSED naming scheme (spec §04 §1)
- [ ] Migrations written; seed written; `m1_checks.sql` written
- [ ] SQL tests pass on a throwaway Postgres; CI database job green
- [ ] Real output shown

**Founder verification**
- [ ] Create the staging Supabase project in `ap-south-1` (Mumbai) if not done; tell me its Postgres version (Dashboard → Settings → Infrastructure) so CI matches it.
- [ ] In the SQL editor, run each migration in filename order, then the seed. If a role or ownership statement fails, stop and send me the exact error (spec risk U1; no BYPASSRLS or service-role workaround).
- [ ] Run `supabase/checks/m1_checks.sql`: every row PASS, `ceremony_types` = 20.
- [ ] Data API check: `curl "https://<ref>.supabase.co/rest/v1/organizations" -H "apikey: <publishable key>" -H "Accept-Profile: app"` returns an error that the schema is not exposed.
- [ ] Table Editor: the `app` tables show RLS enabled.
- [ ] Preview from M0 still works; `/api/v1/healthz` still returns ok.

---

## M2 — Auth, session, onboarding and roles

**Delivers**
- Google sign-in via Supabase Auth with `@supabase/ssr` (httpOnly cookie session); sign-out.
- `src/db`: `withTenantTx` with `postgres.js` (`prepare:false`) as `app_runtime` through Supavisor port 6543; membership probe → 404; ESLint rule: `postgres` importable only in `src/db`.
- `requireContext(req)`: JWT verified against the project's JWKS (asymmetric keys), `X-Tenant-ID`, `Idempotency-Key`; error envelope `{"error":{code, reason?, message, request_id, details?}}` via `mapDatabaseError`.
- SQL: `ensure_current_user`, `update_my_profile`, `bootstrap_practice` (owner `app_bootstrap`; slug generated from the name; default time zone `Asia/Kolkata`; offerings = the ceremonies the priest picks, minimum 1; up to 3 practices per user; idempotent), idempotency helpers.
- Endpoints: `GET /api/v1/session`, `PATCH /api/v1/me`, `POST /api/v1/onboarding/practice`, `GET /api/v1/ceremony-types`, `GET /api/v1/organization`; matching operations in `api/openapi.yaml`.
- next-intl, no locale in the URL: cookie before sign-in; `app_users.preferred_locale` after sign-in, synced to the cookie.
- Pages: sign-in, onboarding (practice name + ceremony picker, Hindi/English names), home showing the current practice, **your role and its permissions**, a practice switcher, a हिन्दी/English toggle.
- `supabase/ops/`: runbook for giving `app_runtime` LOGIN + password; script to add an existing user as a member with another role (ADMIN, PRIEST, STAFF, READ_ONLY) and to revoke a member, on staging.
- Step-by-step instructions for the founder: where to confirm asymmetric JWT signing keys in the Supabase dashboard; Google OAuth client setup; Supabase redirect URLs including the Vercel preview wildcard.

**Tables:** new `offerings`, `org_sequences`, `idempotency_keys`; written through commands: `app_users`, `organizations`, `org_members`, `priest_profiles`, `organization_priests`; read: `role_permissions`, `ceremony_types`, `auth.users`.
**Env vars:** `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `DATABASE_URL` (server-only) — added to `.env.example`.
**Domain/unit tests (PROPOSED):** error mapping for every SQLSTATE in spec §11 §3; request hash is stable for reordered JSON keys; `Idempotency-Key` length 8–128; locale resolution (cookie vs profile); JWT verification rejects missing, expired, wrong-audience and wrong-signature tokens (spec API-SEC-1).
**SQL tests (PROPOSED):** spec `01_bootstrap_identity` assertions (with "the chosen offerings (at least 1)"), forged tenant → zero rows/404, revoked member loses access, bootstrap refuses to run inside a tenant context.

**Build checklist**
- [ ] Proposal approved (columns, function bodies, response shapes for Session/Organization/onboarding, pages, ops scripts)
- [ ] Migrations, checks script, SQL tests
- [ ] Auth, `src/db`, routes, OpenAPI operations, pages, i18n catalogs
- [ ] Ops runbook and member script
- [ ] Founder instructions for JWKS, Google OAuth and redirect URLs
- [ ] Real output shown; CI green

**Founder verification**
- [ ] Apply the M2 migrations; run `supabase/checks/m2_checks.sql`: all PASS.
- [ ] Confirm asymmetric JWT signing keys at the dashboard location I give you.
- [ ] Set `app_runtime` LOGIN + password per the runbook; add the three env vars to Vercel's Preview environment.
- [ ] Configure Google sign-in and redirect URLs per my instructions.
- [ ] Preview: sign in with Google → onboarding. Name a practice, pick 1+ ceremonies, save. Home shows the practice and **OWNER** with its permissions.
- [ ] Submit onboarding twice quickly (or retry after a network drop): still one practice.
- [ ] Create practices until you have 3; a 4th is refused with a clear message. The switcher lists exactly your 3.
- [ ] Switch to हिन्दी, reload, sign out and in again: still Hindi.
- [ ] Run the ops script to add a second Google account to your practice as STAFF; sign in with it: home shows STAFF and STAFF's permissions only. Repeat with READ_ONLY.
- [ ] Run the revoke script; the second account's next request shows no access to that practice.
- [ ] `curl <preview>/api/v1/session` with no token, and with a modified token → 401.
- [ ] `curl` `GET /api/v1/organization` with your token and the `X-Tenant-ID` of a practice you're not a member of → 404.
- [ ] If the app cannot connect through the transaction pooler (spec risk U2), tell me; the spec's fallback is the session pooler (port 5432).

---

## M3 — Platform proof (isolation under pooling, latency)

**Delivers** (spec T-04 (c)–(e), API-SEC-3, API-SEC-4)
- `supabase/checks/platform_smoke.sql`: run by the founder **as `app_runtime` through Supavisor** (transaction-local context gone after COMMIT, API role cannot write, forged tenant sees zero rows / PD404).
- Temporary route `/api/v1/_probe` (spec-named): returns the current tenant id, the rows visible to it and the database round-trip time.
- A script the founder runs locally against the preview (PROPOSED: `scripts/two-tenant-probe.mjs`) with two users' tokens: 1,000 interleaved requests alternating two practices; reports cross-tenant rows (must be 0) and p50/p95 latency.
- Findings recorded in `docs/spec.md` §14 §3 (U2–U4); `_probe` removed once the founder signs off (PROPOSED).

**Tables:** read-only (`organizations`, `org_members`). **Env vars:** none new.

**Build checklist**
- [ ] Proposal approved (probe response shape, script, smoke checks)
- [ ] Smoke script, probe route, load script; real output shown; CI green
- [ ] Findings written into the spec

**Founder verification**
- [ ] Run `psql "$DATABASE_URL" -f supabase/checks/platform_smoke.sql` from your machine: all ok.
- [ ] Open `<preview>/api/v1/_probe` signed in: shows only your current practice; switch practice and reload: only the other one.
- [ ] Run the two-tenant script: 0 cross-tenant rows; note p50/p95 (spec target p95 ≤ 400 ms reads).
- [ ] Revoke the second account between two of its requests: the second request → 404.
- [ ] Approve removal of `_probe`.

---

## M4 — Customers (T-08)

**Delivers:** `create_customer`, `update_customer`; `GET/POST /customers`, `GET/PATCH /customers/{id}` with If-Match/ETag and keyset pagination; customer list with search by name prefix or phone, create/edit form, duplicate-phone warning (`possible_duplicates`); phone optional, shared household phones allowed.
**Tables:** new `customers` (PROPOSED columns in the proposal; `acquisition_source` immutable).
**Env vars:** none.
**Domain tests (PROPOSED):** Indian phone normalisation to E.164; cursor encode/decode round-trip; Zod schemas reject unknown fields.

**Founder verification**
- [ ] Apply migration; `m4_checks.sql` all PASS.
- [ ] Add a customer without a phone; add two with the same phone → duplicate warning, both saved.
- [ ] Search "Sha" finds "Sharma"; search by phone works.
- [ ] Edit the same customer in two tabs; the second save shows a conflict message.
- [ ] Switch practice: the first practice's customers are not visible.

---

## M5 — Catalog and settings (T-11)

**Delivers:** `save_offering`, `save_samagri_template`, `update_organization`, `update_priest_settings`, audit writing; `GET/POST/PATCH /offerings`, `GET/POST/PUT /samagri-templates`, `PATCH /organization`, `PATCH /priests/{id}`; screens to add/edit offerings (duration, suggested dakshina), edit samagri templates (FAMILY/PRIEST items, order), practice settings, default travel buffers.
**Tables:** new `samagri_templates`, `samagri_template_items`, `audit_log`.
**Env vars:** none.
**Domain tests (PROPOSED):** paise ↔ ₹ formatting with Indian grouping (₹1,00,000); rupee input parsing to paise; duration bounds 15–1440.

**Founder verification**
- [ ] Apply migration; checks PASS.
- [ ] Add an offering from the catalog, change its duration and dakshina; reload: saved.
- [ ] Build a samagri template with FAMILY and PRIEST items; reorder; reload: order kept.
- [ ] Change default buffers to 45/30; reload: saved.
- [ ] As the READ_ONLY test member: the edit actions are refused.

---

## M6 — Bookings: draft → confirm → cancel / complete (T-12, T-14 part)

**Delivers:** `create_booking`, `update_booking`, `confirm_booking`, `cancel_booking`, `complete_booking`, `get_booking`, `_reserve_booking`, `_priest_conflicts` (owned by `app_freebusy`); state guard and deferred invariant triggers; exclusion constraint on the global priest identity; booking numbers `PD-YY-NNNN` (YY = creation year, never reset); endpoints `GET/POST /bookings`, `GET/PATCH /bookings/{id}`, `POST …/confirm|cancel|complete`; booking form (offering → default duration, date-only drafts, tentative toggle), booking detail, hard-conflict message in plain Hindi.
**Proposals specific to M6:** reschedule `reason_code` values and the full `booking_events` event types with their data fields (spec §05 §11).
**Tables:** new `bookings`, `booking_assignments`, `calendar_reservations`, `booking_events` (+ `btree_gist` extension).
**Env vars:** none.
**Tests (PROPOSED):** spec `03`/`05` lifecycle and guard assertions; two-session concurrency race on a throwaway Postgres; HTTP race (API-CON-1) and stale edit (API-CON-3) in CI; domain: `BOOKING_TRANSITIONS`, local date in org time zone, booking-number formatting incl. 5 digits.

**Founder verification**
- [ ] Apply migration; checks PASS.
- [ ] Save a draft with only a date; try to confirm → told a time is needed.
- [ ] Add a time; confirm → number `PD-26-0001` style.
- [ ] Create an overlapping booking and confirm → refused with the Hindi conflict message.
- [ ] In your second practice, confirm a booking overlapping the first → refused (same priest across practices).
- [ ] Cancel the first booking with a reason → the second can now be confirmed.
- [ ] Complete a booking whose start is in the future → refused; one that started earlier today → completed and can't be changed.

---

## M7 — Reschedule and travel buffers (T-12, T-14 rest)

**Delivers:** `reschedule_booking` (with `reason_code`), buffer-only overlap → `BUFFER_CONFLICT` and the acknowledgement dialog ("You have 15 minutes to travel… Continue?"), `ack_buffer_overlap` recorded; reschedule UI.
**Tables:** none new. **Env vars:** none.

**Founder verification**
- [ ] Two bookings with 15 minutes between them and 30-minute buffers → acknowledgement dialog; continue → booking shows "buffer acknowledged".
- [ ] Reschedule into a ceremony conflict → refused, original time unchanged.
- [ ] Reschedule to a free slot → old slot frees (another booking can take it).

---

## M8 — Agenda, availability and calendar blocks (T-13, T-16)

**Delivers:** `priest_busy`, `create_block`, `release_block`; `GET /availability` (≤ 62 days), `POST /blocks`, `DELETE /blocks/{id}`; agenda day and week views in local dates, "time to fix" list for date-only drafts, other practices' busy time shown as "Busy" without details; create/release blocks.
**Tables:** none new (blocks are `calendar_reservations` rows). **Env vars:** none.

**Founder verification**
- [ ] Agenda day/week shows your bookings in IST; date-only drafts appear under "time to fix".
- [ ] A booking in your other practice appears as "Busy" with no customer or title.
- [ ] Block 2–4 pm; a booking in that window is refused; release the block; the booking now confirms.

---

## M9 — Dakshina ledger (T-17)

**Delivers:** `record_payment`, `reverse_payment`; `GET/POST /bookings/{id}/payments`, `POST /payments/{id}/reverse`; ledger on the booking (receipt/refund, method, optional UPI reference), reverse with reason, derived balance.
**Tables:** new `payment_entries`, `booking_balances` view. **Env vars:** none.

**Founder verification**
- [ ] Agreed ₹5,100, record advance ₹1,100 → balance ₹4,000.
- [ ] Double-tap Save (or retry) → one entry.
- [ ] Reverse the advance → balance ₹5,100; reversing it again is refused.
- [ ] As the STAFF test member: recording works, reversing is refused.

---

## M10 — Samagri on booking and WhatsApp share (T-18, T-19)

**Delivers:** `attach_samagri`, `prepare_share`; `PUT /bookings/{id}/samagri`, `POST /bookings/{id}/share`; attach a template (snapshot), family vs priest items; `renderBookingMessage` (Hindi/English, ₹ grouping, family items only, 1,800-char cap) and `wa.me` link / Web Share.
**Tables:** new `booking_samagri_items`. **Env vars:** none.
**Domain tests (PROPOSED):** spec AC-14 cases (Hindi rendering, ₹ grouping, family-only samagri, URL encoding, trim samagri before essentials).

**Founder verification**
- [ ] Attach a template; edit the template afterwards → the booking's list is unchanged.
- [ ] Tap Share on an Android phone → WhatsApp opens with correct Hindi text and only family items.
- [ ] Booking without a phone → the Android share sheet opens instead.

---

## M11 — Booking history (T-20)

**Delivers:** `GET /bookings/{id}/events`; history timeline with actor names, no free text other than notes.
**Tables:** none new (reads `booking_events`). **Env vars:** none.

**Founder verification**
- [ ] A booking taken through create → confirm → buffer ack → reschedule → payment → share shows each step, in order, with who did it.

---

## M12 — Data rights and retention (T-09, T-10, retention)

**Delivers:** `erase_customer`, `begin_export`, `run_retention` (owner `app_maintenance`); `POST /customers/{id}/erase` with confirmation dialog, `GET /exports/{customers|bookings|payments}.csv` (formula-escaped, audited); runbook for the hourly Supabase Cron job.
**Tables:** none new (writes `audit_log`, scrubs existing tables). **Env vars:** none.

**Founder verification**
- [ ] Export customers; a customer named `=HYPERLINK(...)` appears as `'=HYPERLINK(...)` in the spreadsheet.
- [ ] Erase a customer with bookings and payments: name, phone and booking notes are gone; amounts and busy times remain.
- [ ] Schedule `app.run_retention()` hourly per the runbook; the Cron job's next run is shown (spec risk U5).

---

## M13 — Production readiness and pilot

**Delivers:** production Supabase project (Mumbai) and Vercel Pro (`bom1`) before real users; error monitoring (Sentry; its env var name proposed for approval); uptime check on `/api/v1/healthz`; weekly encrypted dump and restore drill runbook; account-deletion drill (T-27); PWA manifest + service worker (static assets only) with the app name and icon; performance pass (agenda ≤ 200 KB JS gzipped, Lighthouse mobile ≥ 80, Devanagari font subset); pilot kit (Hindi walkthrough, privacy notice draft, processor terms for counsel review); revisit applying migrations with the Supabase CLI.
**Tables:** none new. **Env vars:** proposed in this milestone (e.g. for Sentry) and approved before use.

**Founder verification**
- [ ] Production deploy reachable; healthz ok; uptime alert fires when a test URL fails.
- [ ] "Add to home screen" on Android installs "पुरोहित डेस्क".
- [ ] Lighthouse mobile ≥ 80 on the agenda; restore drill into staging passes the smoke checks.
- [ ] Account-deletion drill on staging: identity detached, history intact.

---

## M14 — Voice (placeholder; out of scope for this plan)

Not planned. Starts only after P0, with the offline evaluation spike (spec T-15) and its go/no-go gate, then T-24–T-26.

---

## Milestone summary

| # | Milestone | New tables | Env vars |
| --- | --- | --- | --- |
| M0 | Project setup | — | — (reads Vercel's `VERCEL_GIT_COMMIT_SHA`) |
| M1 | Foundation schema with RLS | role_permissions, app_users, organizations, org_members, priest_profiles, organization_priests, ceremony_types | — |
| M2 | Auth, session, onboarding, roles | offerings, org_sequences, idempotency_keys | NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, DATABASE_URL |
| M3 | Platform proof | — | — |
| M4 | Customers | customers | — |
| M5 | Catalog and settings | samagri_templates, samagri_template_items, audit_log | — |
| M6 | Bookings core | bookings, booking_assignments, calendar_reservations, booking_events | — |
| M7 | Reschedule and buffers | — | — |
| M8 | Agenda, availability, blocks | — | — |
| M9 | Dakshina ledger | payment_entries (+ booking_balances view) | — |
| M10 | Samagri on booking + WhatsApp share | booking_samagri_items | — |
| M11 | Booking history | — | — |
| M12 | Data rights and retention | — | — |
| M13 | Production readiness and pilot | — | proposed then (e.g. Sentry) |
| M14 | Voice (placeholder) | voice_extractions (later) | later |
