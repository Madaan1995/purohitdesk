import { apiError } from '@/domain/errors';
import type postgres from 'postgres';
import { getSql } from './client';
import { DomainError, toDomainError } from './domain-error';

export type Tx = postgres.TransactionSql;

export interface TxContext {
  /** Verified Supabase JWT `sub`. */
  actorId: string;
  /** X-Tenant-ID; omitted for identity endpoints (session, profile, onboarding). */
  tenantId?: string | null;
}

/**
 * Runs fn in one transaction with the request context set transaction-locally (spec §04 §9), so a pooled
 * connection never carries a previous request's identity. With a tenant, the actor's ACTIVE membership is probed
 * first: non-members get 404 on reads and writes alike. Database errors leave as DomainError.
 */
export async function withTenantTx<T>(
  ctx: TxContext,
  fn: (tx: Tx, role: string | null) => Promise<T>,
  sql: postgres.Sql = getSql(),
): Promise<T> {
  try {
    const result = await sql.begin(async (tx) => {
      await tx`SELECT set_config('app.actor_user_id', ${ctx.actorId}, true),
                      set_config('app.tenant_id', ${ctx.tenantId ?? ''}, true)`;
      let role: string | null = null;
      if (ctx.tenantId) {
        const [row] = await tx<{ role: string | null }[]>`SELECT app.current_member_role() AS role`;
        role = row?.role ?? null;
        if (!role) throw new DomainError(apiError('NOT_FOUND', { details: { resource: 'organization' } }));
      }
      return fn(tx, role);
    });
    return result as T;
  } catch (error) {
    throw toDomainError(error);
  }
}

/** Runs `SELECT app.<command>(…) AS result` and returns the command's JSON result. */
export async function command<T>(query: postgres.PendingQuery<postgres.Row[]>): Promise<T> {
  const [row] = await query;
  return row?.result as T;
}
