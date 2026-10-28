# SQL tests

Run only against a **throwaway** PostgreSQL server (local sandbox or the CI service container). The harness drops
and recreates the database `pd_test` and the application roles on that server.

```bash
PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=… npm run test:db
```

What `run.sh` does:

1. Resets `pd_test` and creates `pd_migrator` (CREATEROLE, not SUPERUSER, not BYPASSRLS), which behaves like
   Supabase's `postgres` role.
2. `_setup_superuser.sql` stubs the Supabase objects the migrations rely on: `auth.users`, and the `anon`,
   `authenticated` and `service_role` roles with worst-case default privileges (the migrations must revoke them).
3. Applies `supabase/migrations/*.sql` in filename order as `pd_migrator`, one transaction per file, stopping at the
   first error.
4. Applies `supabase/seed/*.sql` twice (must be idempotent).
5. Runs every `supabase/checks/*.sql`; any `FAIL` row fails the run.
6. Loads `_harness.sql` (a `test` schema with `test.ok`, `test.is`, `test.throws`, `test.lives`, `test.ctx`) and runs
   each `NN_*.sql` file. Files run as the superuser inside `BEGIN … ROLLBACK`, create fixtures directly, and switch
   to the application roles with `SET ROLE` for every assertion, so RLS and grants apply exactly as in production.

Each assertion prints `ok N - name` or `not ok N - name # detail`. The script exits 1 if any assertion fails, a file
aborts, or a check fails.
