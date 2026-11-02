# Overnight report 2 — 1 Nov 2026 (M6, M7, M8)

Built M6, M7 and M8 as stacked branches and pull requests on top of `m5-catalog-settings`. Every PR's base is the
previous milestone's branch, so each diff shows one milestone. Nothing was pushed to or merged into `main`, nothing
was applied to Supabase, nothing was deployed, and no real credential was used. Database work ran only on a throwaway
local PostgreSQL **17.11** (Docker `postgres:17.11`, same as CI and staging) and in CI's container.

## 1. Milestones

| Milestone | PR | Base | Tests (local, real output in each PR) | CI |
| --- | --- | --- | --- | --- |
| M6 Bookings: draft → confirm → cancel / complete | [#8](https://github.com/Madaan1995/purohitdesk/pull/8) | `m5-catalog-settings` | 203 unit, 440 SQL (incl. 8 concurrency), 40 integration; browser 12/12 | green |
| M7 Reschedule and travel buffers | [#9](https://github.com/Madaan1995/purohitdesk/pull/9) | `m6-bookings` | 207 unit, 488 SQL (incl. 9 concurrency), 46 integration; browser 9/9 | green |
| M8 Agenda, availability and calendar blocks | [#10](https://github.com/Madaan1995/purohitdesk/pull/10) | `m7-reschedule-buffers` | 211 unit, 524 SQL (incl. 9 concurrency), 51 integration; browser 10/10 | see PR |

Final state on `m8-agenda-availability` (everything above, cumulative):

```
$ npm run lint             -> exit=0
$ npm run typecheck        -> exit=0
$ npm test                 -> Test Files 21 passed (21), Tests 211 passed (211)
$ npm run build            -> exit=0
$ npm run test:db          -> checks m1..m8: 67 PASS, 15 NO DATA (row-level rows on the empty harness DB), 0 FAIL
                              01 29, 02 58, 03_bootstrap 56, 03_ops 25, 04 40, 05 57, 06 107, 07 42, 08 47, 09 36, gates 27
                              concurrency: 9 passed, 0 failed; ops: 9 passed, 0 failed
                              == SQL tests: 524 passed, 0 failed; checks/aborts with problems: 0
$ npm run test:integration -> Test Files 6 passed (6), Tests 51 passed (51)
```

What is new in the test tooling:
- `supabase/tests/concurrency.sh` (run by `run.sh`): two real psql sessions as `app_runtime` with a real COMMIT —
  three cross-practice races on the same priest, a rollback variant, a buffer-only race and an idempotency race. The
  second session waits ~1.3 s on the per-priest lock and then gets `BOOKING_CONFLICT` / `BUFFER_CONFLICT`; zero
  overlapping ACTIVE reservations remain. This matches the spec's §14 §5.2 harness.
- HTTP races in the integration suite: API-CON-1 (50 × two concurrent confirms → exactly one 200 and one 409),
  API-CON-3 (same If-Match twice → 200 + 409), API-SEC-5 (a cross-practice 409 body holds no foreign id).

Merge order: #8 → #9 → #10 after #6 (and the earlier stack). I noticed `main` received "Merge pull request #7"
(privacy pages) at 05:36 today; the M6–M8 branches already contain those pages through the M5 base, so nothing to do.

## 2. AUTO-DECIDED items needing your review (schema and security first)

Details: `docs/proposals/m6.md`, `m7.md`, `m8.md`.

**Roles, RLS and privileges**
1. *(M6)* `app_freebusy` may read the busy-time columns of **ACTIVE reservations in every practice**, but only while
   the actor is an ACTIVE member of the current tenant (no context → no rows). Only `_priest_conflicts` and
   `priest_busy` run as it, and both strip other practices' ids. Column grant excludes `note` and `created_by`.
2. *(M8)* `priest_busy` hides even *what* another practice's busy time is (`kind = BUSY`, not BOOKING/BLOCK).
3. *(M6)* `btree_gist` is created in schema `extensions` if it exists (Supabase), else `public`. **VERIFY** on
   staging that `postgres` may create it (it is a trusted extension; the non-superuser test migrator could).
4. *(M6)* The deferred invariant triggers run as whichever role commits (normally `app_runtime`, under RLS, with the
   request context still set). They raise directly instead of calling `app.raise_error`, so they need no EXECUTE.
5. *(M7)* `create_booking`/`confirm_booking` signatures are **dropped and replaced** to add the buffer
   acknowledgement (no wrappers). Apply the M7 migration together with the M7 deploy; between the two, booking
   creation/confirmation would fail. Nothing is applied yet, so this only matters for order.
6. *(M6, on #8)* `m6_checks.sql` finds the commands by name so it still runs after M7.

**Tables and columns**
7. *(M6)* `bookings`: customer and offering **required**; a draft needs at least a **date**; `created_via` only
   `MANUAL`; `source` only `PRIEST_DIRECT`; title ≤ 120, place ≤ 500, notes ≤ 2000; buffers 0–360, NULL until the LEAD is
   assigned and then copied from his link; `seq_no` + `booking_number` (YY = creation year **in the practice's time
   zone**); bookings are never deleted.
8. *(M6)* `booking_events` CHECK lists all 12 event types now; the `data` fields of each (no free text).
9. *(M6/M7)* Reschedule reason codes: `CUSTOMER_REQUEST, PRIEST_REQUEST, MUHURAT_FIXED, PRIEST_CHANGED, CORRECTION, OTHER`.
10. *(M6)* `calendar_reservations` as in the spec; block notes ≤ 500; guard allows only ACTIVE→RELEASED.

**Behaviour and API**
11. *(M7)* Calendar blocks count as **travel-time** conflicts for a nearby booking (blocks themselves never check
    buffers). Changing priests on reschedule keeps the booking's buffers.
12. *(M8)* Conflict details carry `"block": true` for the practice's own blocks ("पंडित जी ने यह समय रोका हुआ है").
13. *(M8)* Releasing a block is **not audited** (spec lists only BLOCK_CREATED); the row keeps `released_at/by`.
14. *(M6)* Past bookings are allowed; a ceremony can be completed once it has started (not ended).
15. All response shapes (`Booking`, `BookingSummary`, conflict details, `Availability`, `Block`); list order
    `(local_date, seq_no)`; availability `from`/`to` are local dates; weeks start on Monday.

**UI and content**
16. Hindi wording of all new screens (bookings, the travel-time question, reason labels, agenda) needs a native
    check.
17. The travel-time dialog names minutes and times, not places.
18. **Agenda JS is 189.3 KB gzipped** (budget 200 KB) — mostly framework chunks; little headroom for M9+.

## 3. What you need to do (Supabase / Vercel)

Runbook §1 lists the files in order. For each milestone: apply the migration in the SQL editor as `postgres`, run the
checks script, then the plan's checklist (also in each PR).

- **M6** — `20261101100000_m6_bookings.sql`; `m6_checks.sql`: rows 1–10 PASS (11–13 NO DATA until a booking exists).
  If `CREATE EXTENSION btree_gist` is refused, send me the error.
- **M7** — `20261101200000_m7_reschedule_buffers.sql` **with the M7 deploy**; `m7_checks.sql`: 5 × PASS.
- **M8** — `20261101300000_m8_agenda_blocks.sql`; `m8_checks.sql`: 5 × PASS.

## 4. Failures, fixes and caveats

- **No milestone failed its checks.** Things found and fixed along the way:
  - A **flaky M5 test** on the base branch: `05_catalog_settings.sql`'s leak check failed 2 of 6 runs, because
    `m5_checks.sql` tests a random member. Fixed in a separate commit on M6 (`d28d05e`); 6/6 runs pass after. M6's
    and M8's own leak tests were written to avoid the same trap.
  - Next.js rejects extra exports from route files: shared helpers moved to `src/app/_lib`.
  - M7 enforces buffers, so two M6 test fixtures that relied on buffers being ignored were changed (zero travel time /
    a later slot). Their assertions are unchanged.
  - My own test scripts had several mistakes (operator precedence in a JSON assertion, a wrong expected local date,
    ambiguous ordering of rows created in one transaction, the route announcer matching `role=alert`); each was fixed
    and re-run.
- **Not verified anywhere real**: `btree_gist` on Supabase; deferred triggers and advisory locks through Supavisor's
  transaction pooler (M3 is still skipped); real JWKS tokens; the `bom1` region.
- **Browser smoke tests** ran only here, with a local JWKS stand-in and a hand-made session cookie; the scripts are
  scratch files and not committed (a committed e2e suite would be a new decision for you).
- **`docs/spec.md` was not updated**, as last time: nothing is approved yet. After approval it needs: the event data
  fields, reason codes, the ack argument in the command signatures, `priest_busy`'s BUSY kind, and the `block` flag.
- Blocks and the agenda use only P0 features; nothing from P1/P2 was built. No new env vars, roles or packages.
