# src/db

The only place that imports the database driver (`postgres`, from M2).

- `withTenantTx`, `command()`, `DomainError`.
- Never open a transaction or `SET` anything outside `withTenantTx`.
- Writes go only through `app.*` command functions; no INSERT/UPDATE/DELETE in TypeScript.
