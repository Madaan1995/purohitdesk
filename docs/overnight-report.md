# Overnight report — 28 Oct 2026

> **Update 29 Oct 2026 — founder review.** Items 3 and 5 below are superseded: no application role reads
> `auth.users` (the `app_users` foreign key proves the auth user), and the operator scripts are single calls to
> `app.ops_add_member` / `app.ops_revoke_member` (role `app_operator`) instead of lifting FORCE RLS. Item 20 now also
> requires same-origin cookie writes and JSON bodies (CSRF). Item 1: the migration user is a member of an application
> role only during the migration that hands it functions. Item 27 is resolved: staging runs PostgreSQL 17.11, and CI
> and the harness use it. Staging's `postgres` has BYPASSRLS, so every checks script tests row-level security as the
> application roles (`SET ROLE`; runbook §0). Details: `docs/proposals/m1.md` §13, `docs/proposals/m2.md` §8, `docs/plan.md` M1/M2/M12/M13.

Built M0, M1, M2, M4 and M5 as stacked branches and pull requests; skipped M3 as instructed. Every PR's base is the
previous milestone's branch, so each diff shows one milestone. Nothing was pushed to or merged into `main`, nothing was
applied to Supabase, nothing was deployed to Vercel, and no real credential was used. Database work ran only on a
throwaway local PostgreSQL 16.15 cluster and in CI's Postgres container.

## 1. Milestones

| Milestone | PR | Base | Tests (local, real output in each PR) | CI |
| --- | --- | --- | --- | --- |
| M0 Project setup | [#2](https://github.com/Madaan1995/purohitdesk/pull/2) | `main` | lint, typecheck, build; 19 unit tests | green |
| M1 Foundation schema with RLS | [#3](https://github.com/Madaan1995/purohitdesk/pull/3) | `m0-setup` | 82 SQL assertions; `m1_checks.sql` 16/16 | green |
| M2 Auth, session, onboarding, roles | [#4](https://github.com/Madaan1995/purohitdesk/pull/4) | `m1-foundation-schema` | 77 unit, 149 SQL (incl. 10 operator-script checks), 14 integration; `m2_checks.sql` 11/11; browser smoke test | green |
| M4 Customers | [#5](https://github.com/Madaan1995/purohitdesk/pull/5) | `m2-auth-onboarding` | 113 unit, 186 SQL, 22 integration; `m4_checks.sql` 8/8; browser smoke test | green |
| M5 Catalog and settings | [#6](https://github.com/Madaan1995/purohitdesk/pull/6) | `m4-customers` | 164 unit, 239 SQL, 27 integration; `m5_checks.sql` 8/8; browser smoke test | see PR |

Final state on `m5-catalog-settings` (everything above, cumulative):

```
$ npm run lint             -> exit=0
$ npm run typecheck        -> exit=0
$ npm run test             -> Test Files 13 passed (13), Tests 164 passed (164)
$ npm run build            -> exit=0
$ npm run test:db          -> checks m1 16/16, m2 11/11, m4 8/8, m5 8/8 PASS
                              == SQL tests: 239 passed, 0 failed; checks/aborts with problems: 0
$ npm run test:integration -> Test Files 3 passed (3), Tests 27 passed (27)
```

How it is tested:
- **SQL**: `supabase/tests/run.sh` (`npm run test:db`) applies every migration as a non-superuser, non-BYPASSRLS
  `pd_migrator` with a stub `auth.users`, seeds twice, runs every checks script, then runs the test files. Each
  assertion runs as the real application role (`SET ROLE app_runtime` / `app_domain` / `app_bootstrap`).
- **Integration**: the real route handlers, through `postgres.js`, logged in as `app_runtime`, against the same
  throwaway database.
- **Browser smoke tests**: Playwright at 360 px against `next start`, with a local stand-in for the Supabase JWKS.
  These ran locally only and are not committed (see §4).
- **CI**: the `database` job runs both the SQL suite and the integration tests.

Merge order: #2 into `main`, then #3, #4, #5, #6. After each merge, change the next PR's base to `main`. GitHub does
this automatically if you delete the merged branch.

## 2. AUTO-DECIDED items needing your review (priority order: schema and security first)

Details are in `docs/proposals/m1.md`, `m2.md`, `m4.md` and `m5.md`.

**Roles, RLS and privileges**
1. *(M1)* The migrations `CREATE ROLE` the six roles (failing loudly if they exist) and `GRANT` the five NOLOGIN roles
   `TO CURRENT_USER`, so function ownership can be handed over. This is exactly spec risk U1: if Supabase refuses it,
   stop and send me the error.
2. *(M1)* FORCE RLS is on every tenant/identity table, but **not** on `role_permissions` or `ceremony_types`, which
   are only ENABLEd so the owner can seed them. This follows the spec; the plan said "every table".
3. *(M2)* `app_bootstrap` gets `USAGE` on schema `auth` and column `SELECT (id, raw_user_meta_data)` on `auth.users`
   for first login (spec U1).
4. *(M5)* `app_runtime` gets EXECUTE on `current_member_has`, because its `audit_log` policy needs it.
5. *(M2)* The operator scripts lift FORCE RLS on `organizations`/`org_members` inside their own transaction and
   restore it before COMMIT. This avoids a new role or an owner policy; harness tests cover it, including FORCE being
   restored after failed runs.
6. *(M1–M2)* Write policies and grants arrive with the functions that use them (M2+), not with the tables in M1.
7. *(M4)* `app_domain` has table-level UPDATE on `customers`, with a trigger guarding `acquisition_source`/`org_id`
   (matches the spec's test). No DELETE on customers for anyone.

**Tables and columns**
8. *(M1)* `app_users`: `display_name`, `preferred_locale` (`hi`/`en`, default `hi`), `status`; no e-mail or phone
   copy.
9. *(M1)* `organizations`: status `ACTIVE`/`CLOSED`. **`voice_daily_limit` is left out until voice (M14).**
10. *(M1)* `priest_profiles.display_name`.
11. *(M1)* `organization_priests` buffers are named `default_buffer_before_min`/`_after_min`, default **30/30**,
    range **0–240** (the spec allows 0–360 on bookings).
12. *(M2)* `offerings` stores both `name_hi` and `name_en`, plus `is_active` and `suggested_dakshina_paise`
    (≤ ₹1,00,00,00,000); the English name is unique per practice. `org_sequences` and `idempotency_keys` follow the
    spec.
13. *(M4)* `customers`: `display_name`, `phone_e164` (not unique), `address` ≤ 500, `acquisition_source`,
    `erased_at`, `version`. **No customer notes.** Erased customers return 404 until M12.
14. *(M5)* **One samagri template per offering.** Items are replaced as a whole on each save; `quantity` is free text
    (≤ 60).
15. *(M5)* `audit_log` columns and its append-only guard (TRUNCATE blocked too). Only `ORG_UPDATED` is written, with
    field names only; catalog and buffer edits are **not** audited.
16. *(M1)* Error shape inside PostgreSQL: SQLSTATE `PDxxx`, message = reason, DETAIL = our JSON.
17. *(M1)* Migration file names follow `YYYYMMDDHHMMSS_m<N>_<topic>.sql`; files contain no BEGIN/COMMIT, so run each
    file as one script.

**Behaviour and API**
18. *(M2)* A slug collision gets a random 6-hex suffix instead of 409. The slug is generated and never shown.
19. *(M2)* The quota counts the 3 ACTIVE organizations the user **created**.
20. *(M2)* The API accepts the httpOnly Supabase session cookie as well as `Authorization: Bearer`, so the PWA's pages
    can call it. Cookies are SameSite=Lax and writes need a JSON body.
21. *(M2–M5)* All response shapes; cookie names `NEXT_LOCALE` and `pd_tenant`; DB pool `max: 3` per serverless
    instance.
22. *(M4)* Customer search matches the start of **any word** of the name ("Sha" finds "Ramesh Sharma"). Phone search:
    exact E.164 match, or "contains" for 4+ digits. Indian phone parsing accepts landlines with STD code.
23. *(M4, M5)* PATCH bodies are JSON patches (`null` clears, absent keeps).
24. *(M5)* A PRIEST may edit **his own** buffers (spec: "ORG_SETTINGS, or the priest himself").

**UI and content**
25. Hindi wording needs a native-speaker check: प्रैक्टिस for "practice", यजमान for "customer", role names मालिक /
    प्रबंधक / पंडित / सहायक / केवल देखना, and all permission labels. Digits are Latin in both languages.
26. The system font stack stays until the Devanagari subset arrives in M13.

**Tooling**
27. CI uses `postgres:16`; tell me staging's major version and I'll match it.
28. `package-lock.json` is generated with npm 11, because npm 10.9.4 (bundled with Node 22) crashes resolving this
    dependency tree. `npm ci` with npm 10 works and is what CI runs.
29. OpenAPI (`api/openapi.yaml`, 18 operations) is hand-written. I checked locally that it parses, operationIds are
    unique, refs resolve, and every operation has `x-permission` and `x-db-function`, but nothing validates it in CI
    and there are no response-contract tests (API-CTR-1) yet.
30. `.env.example` lists the three spec variables, plus the `PG*` test-harness variables as comments.

## 3. What you need to do (Supabase / Vercel / Google)

Step-by-step instructions are in `supabase/ops/runbook.md`. Founder checklists are in `docs/plan.md` and each PR.

**M0** — Vercel (Hobby): import the repo (Next.js, root `/`). The preview shows "PurohitDesk" / "पुरोहित डेस्क";
`<preview>/api/v1/healthz` returns `{"status":"ok","commit":"<sha>"}`; the function logs show `bom1`.

**M1** — Create the staging Supabase project in `ap-south-1` and tell me its Postgres major version. In the SQL editor,
as `postgres`, run `20261028200000_m1_foundation.sql`, `20261028200100_m1_identity_tenancy.sql`, then
`supabase/seed/ceremony_types.sql`. Run `supabase/checks/m1_checks.sql`: 16 × PASS. Confirm the Data API does not
expose `app` (runbook §3 curl). If any role or ownership statement fails, stop and send me the exact error.

**M2** — Apply `20261028210000_m2_auth_onboarding.sql`; `m2_checks.sql`: 11 × PASS. Then:
1. JWT signing keys: rotate to an asymmetric ECC/RSA key; `/auth/v1/.well-known/jwks.json` must list it (runbook §4).
2. `ALTER ROLE app_runtime WITH LOGIN PASSWORD …`, and build the transaction-pooler `DATABASE_URL` with user
   `app_runtime.<ref>` (runbook §2).
3. Google Cloud: create the OAuth consent screen and a Web client with redirect URI
   `https://<ref>.supabase.co/auth/v1/callback`; enable the Google provider in Supabase (runbook §5).
4. Supabase URL Configuration: add `https://*-<your-vercel-slug>.vercel.app/**`, the production URL and
   `http://localhost:3000/**` (runbook §6).
5. Vercel **Preview** env vars: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `DATABASE_URL`;
   then redeploy (runbook §7).
6. Run the plan's M2 checks: sign in → onboarding → home shows OWNER and its permissions; double-submit gives one
   practice; at most 3 practices; Hindi persists; `add_member.sql` (STAFF, READ_ONLY) and `revoke_member.sql`;
   401/404 curls.
7. If `app_runtime` cannot connect through port 6543 (risk U2), tell me.

**M4** — Apply `20261028220000_m4_customers.sql`; `m4_checks.sql`: 8 × PASS. Plan checks: customer without a phone;
two with the same phone → warning, both saved; "Sha" finds Sharma; search by phone; two tabs → conflict message;
switching practice hides the other practice's customers.

**M5** — Apply `20261028230000_m5_catalog_settings.sql`; `m5_checks.sql`: 8 × PASS. Plan checks: offering from the
list with new duration and dakshina survives a reload; samagri list with यजमान/पंडित जी items keeps its order after a
reload; buffers 45/30 survive a reload; a READ_ONLY member gets no edit forms (and the API refuses edits).

## 4. Failures, skips and caveats

- **M3 skipped** as instructed (it needs the real Supabase pooler). Nothing in M4/M5 depends on it, but the platform
  risks it covers (U2 pooler login, U3 context under pooling, U4 latency) are still unverified. Locally, 60
  interleaved two-tenant requests over a 3-connection pool leaked nothing; that is not a substitute for M3.
- **No milestone failed its checks.** Problems hit and fixed along the way:
  - npm 10's install crash: worked around with an npm 11 lockfile.
  - `pg_catalog.nullif`/`coalesce`: these are syntax, not functions; fixed.
  - `text[] || 'literal'`: replaced with `array_append`.
  - A float cast for paise: replaced with `to_jsonb`, so money never becomes a float.
  - Several mistakes in my own test scripts: in one, a `document.querySelector('form')` hit the sign-out form.
    Each was fixed and re-run.
- **One earlier test file changed in a later PR**: M5 removes M1's assertion that `app_runtime` cannot call
  `current_member_has`. M5 grants that intentionally, and `90_security_gates.sql` checks the exact whitelist.
- **Not verified anywhere real**:
  - Supabase role creation and ownership hand-over (U1).
  - `GRANT … ON auth.users`.
  - Supavisor with a custom login (U2).
  - Real JWKS tokens from Supabase.
  - Google OAuth and the redirect allow-list.
  - `@supabase/ssr` cookie behaviour on Vercel.
  - The `bom1` region.
- **Browser smoke tests** ran only in this sandbox, with a local JWKS stand-in and a hand-made session cookie. The
  scripts were scratch files and are not committed. A committed end-to-end suite would be a new test-infrastructure
  decision for you.
- **`docs/spec.md` was not updated.** The plan says to update it when an *approved* proposal changes the design, and
  nothing is approved yet. Once you approve or correct the proposals, the spec needs edits for: one template per
  offering, slug auto-suffix, both offering names, the operator-script technique, and buffer range 0–240.
- The seed's 20 ceremony names and durations are still the plan's PROPOSED list, unchanged.
