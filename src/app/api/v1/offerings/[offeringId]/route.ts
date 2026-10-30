// PATCH /api/v1/offerings/{offeringId} — CATALOG_WRITE (app.save_offering, update); If-Match required.
import type { Offering } from '@/app/_lib/catalog';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, parseIfMatch, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, DomainError, withTenantTx } from '@/db';
import { apiError } from '@/domain/errors';
import { UpdateOfferingRequest } from '@/domain/schemas/catalog';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const PATCH = route(async (req: Request, { params }: { params: Promise<{ offeringId: string }> }) => {
  const { offeringId } = await params;
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  if (!UUID.test(offeringId)) throw new DomainError(apiError('NOT_FOUND', { details: { resource: 'offering' } }));
  const version = parseIfMatch(req);
  const body = await parseBody(req, UpdateOfferingRequest);
  const hash = requestHash('PATCH', `/offerings/${offeringId}`, body);
  const result = await withTenantTx(ctx, (tx) =>
    command<Offering & { idempotent_replay: boolean }>(
      tx`SELECT app.save_offering(${offeringId}::uuid, ${version}::int, ${tx.json(body)}::jsonb,
                                  ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, 200, etag(result.version));
});
