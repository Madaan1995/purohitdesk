# src/db

The only place that imports the database driver (`postgres`). ESLint blocks `postgres` everywhere else in `src/`.

- `getSql()`: one `postgres.js` pool per server instance (`prepare: false`, Supavisor transaction mode),
  connected as `app_runtime` with `DATABASE_URL`.
- `withTenantTx(ctx, fn)`: the only way to open a transaction. Sets `app.actor_user_id` and `app.tenant_id`
  transaction-locally, probes membership when a tenant is given (non-member → 404), and turns PostgreSQL errors
  into `DomainError` through `mapDatabaseError`.
- `command(tx\`SELECT app.<command>(…) AS result\`)`: writes go only through `app.*` command functions; no
  INSERT/UPDATE/DELETE in TypeScript (the login role cannot run them anyway).
- Never `SET` anything outside `withTenantTx`.
