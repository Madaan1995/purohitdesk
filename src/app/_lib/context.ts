import { DomainError } from '@/db';
import { apiError } from '@/domain/errors';
import { isValidIdempotencyKey } from '@/domain/idempotency';
import { authConfig } from './auth-config';
import { verifyAccessToken } from './auth';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface RequestContext {
  actorId: string;
  tenantId: string | null;
  idempotencyKey: string | null;
}

/**
 * Authenticates the request and reads the per-request headers (spec §11 §1):
 * - token: `Authorization: Bearer …`, else the Supabase session cookie (the PWA's own pages);
 * - `X-Tenant-ID` (uuid) when the endpoint is tenant-scoped; membership is checked by withTenantTx;
 * - `Idempotency-Key` (8–128 chars) when the command takes one.
 */
export async function requireContext(
  req: Request,
  opts: { tenant?: boolean; idempotency?: boolean } = {},
): Promise<RequestContext> {
  const header = req.headers.get('authorization');
  let token: string | null = null;
  if (header) {
    const match = /^Bearer\s+(\S+)$/i.exec(header);
    token = match ? match[1] : '';
  } else {
    const { sessionAccessToken } = await import('./supabase');
    token = await sessionAccessToken();
  }
  const actorId = await verifyAccessToken(token, authConfig());

  let tenantId: string | null = null;
  if (opts.tenant) {
    tenantId = req.headers.get('x-tenant-id');
    if (!tenantId || !UUID.test(tenantId)) {
      throw new DomainError(apiError('VALIDATION_FAILED', { reason: 'TENANT_REQUIRED', details: { field: 'X-Tenant-ID' } }));
    }
    tenantId = tenantId.toLowerCase();
  }

  let idempotencyKey: string | null = null;
  if (opts.idempotency) {
    idempotencyKey = req.headers.get('idempotency-key');
    if (idempotencyKey === null) {
      throw new DomainError(
        apiError('VALIDATION_FAILED', { reason: 'IDEMPOTENCY_KEY_REQUIRED', details: { field: 'Idempotency-Key' } }),
      );
    }
    if (!isValidIdempotencyKey(idempotencyKey)) {
      throw new DomainError(apiError('VALIDATION_FAILED', { details: { field: 'Idempotency-Key' } }));
    }
  }

  return { actorId, tenantId, idempotencyKey };
}
