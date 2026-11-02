// POST /api/v1/blocks — BLOCK_MANAGE, or BLOCK_MANAGE_OWN for the actor's own calendar (app.create_block).
import type { Block } from '@/app/_lib/agenda';
import { requireContext } from '@/app/_lib/context';
import { json, parseBody, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, withTenantTx } from '@/db';
import { CreateBlockRequest } from '@/domain/schemas/agenda';

export const POST = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  const body = await parseBody(req, CreateBlockRequest);
  const hash = requestHash('POST', '/blocks', body);
  const result = await withTenantTx(ctx, (tx) =>
    command<{ block: Block; idempotent_replay: boolean }>(
      tx`SELECT app.create_block(${body.priest_id}::uuid, ${body.starts_at}::timestamptz, ${body.ends_at}::timestamptz,
                                 ${body.note ?? null}, ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, result.idempotent_replay ? 200 : 201);
});
