import postgres from 'postgres';

let client: postgres.Sql | undefined;

/**
 * One pool per server instance, connected as app_runtime through Supavisor's transaction pooler.
 * prepare: false is required in transaction mode (spec ADR-002).
 */
export function getSql(): postgres.Sql {
  if (!client) {
    const url = process.env.DATABASE_URL;
    if (!url) throw new Error('DATABASE_URL is not set');
    client = postgres(url, { prepare: false, max: 3, idle_timeout: 20, connect_timeout: 10 });
  }
  return client;
}

/** Closes the pool (tests and scripts only). */
export async function closeSql(): Promise<void> {
  if (client) {
    const closing = client;
    client = undefined;
    await closing.end({ timeout: 5 });
  }
}
