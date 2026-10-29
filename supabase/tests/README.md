# SQL tests

Run only against a **throwaway** PostgreSQL **17** server (staging runs 17.11; `run.sh` refuses another major
version). Locally, for example `docker run -d --network host -e POSTGRES_PASSWORD=… postgres:17.11`; CI uses the
`postgres:17.11` service image. The harness drops and recreates the database `pd_test` and the application roles on
that server.

```bash
PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=… npm run test:db
```

What `run.sh` does:

1. Resets `pd_test` and creates `pd_migrator`, the stand-in for Supabase's `postgres` (staging probe, 29 Oct 2026:
   CREATEROLE, not SUPERUSER, **BYPASSRLS**). It logs in as itself (throwaway password), like `postgres` in the SQL
   editor.
2. `_setup_superuser.sql` stubs the Supabase objects the migrations rely on: `auth.users` with the same privileges
   staging's `postgres` has (USAGE on schema `auth` without GRANT OPTION, SELECT on `auth.users` with it), and the
   `anon`, `authenticated` and `service_role` roles with worst-case default privileges (the migrations must revoke
   them).
3. Applies `supabase/migrations/*.sql` in filename order as `pd_migrator`, one transaction per file, stopping at the
   first error.
   Migrations run while `pd_migrator` is still NOBYPASSRLS: stricter than Supabase, so no migration can depend on
   bypassing RLS. Then `pd_migrator` gets BYPASSRLS for the remaining steps it runs, as in the SQL editor.
4. Applies `supabase/seed/*.sql` twice (must be idempotent).
5. Runs every `supabase/checks/*.sql`; any `FAIL` row fails the run.
6. Loads `_harness.sql` (a `test` schema with `test.ok`, `test.is`, `test.throws`, `test.lives`, `test.ctx`) and runs
   each `NN_*.sql` file. Files run as the superuser inside `BEGIN … ROLLBACK`, create fixtures directly, and switch
   to the application roles with `SET ROLE` for every assertion, so RLS and grants apply exactly as in production.

Each assertion prints `ok N - name` or `not ok N - name # detail`. The script exits 1 if any assertion fails, a file
aborts, or a check fails.
