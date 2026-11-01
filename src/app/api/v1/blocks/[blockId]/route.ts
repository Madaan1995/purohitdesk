// DELETE /api/v1/blocks/{blockId} — BLOCK_MANAGE, or BLOCK_MANAGE_OWN for the actor's own calendar
// (app.release_block). Idempotency-Key required; no If-Match (spec §11 §2). The block is kept as RELEASED history.
import { UUID } from '@/app/_lib/bookings';
import { requireContext } from '@/app/_lib/context';
import { json, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, DomainError, withTenantTx } from '@/db';
import { apiError } from '@/domain/errors';

type Params = { params: Promise<{ blockId: string }> };

export const DELETE = route(async (req: Request, { params }: Params) => {
  const { blockId } = await params;
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  if (!UUID.test(blockId)) throw new DomainError(apiError('NOT_FOUND', { details: { resource: 'block' } }));
  const hash = requestHash('DELETE', `/blocks/${blockId}`, null);
  const result = await withTenantTx(ctx, (tx) =>
    command<{ block: unknown; idempotent_replay: boolean }>(
      tx`SELECT app.release_block(${blockId}::uuid, ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result);
});
