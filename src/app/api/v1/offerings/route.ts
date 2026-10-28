// GET /api/v1/offerings — ORG_READ; POST — CATALOG_WRITE (app.save_offering, create).
import { listOfferings, type Offering } from '@/app/_lib/catalog';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, withTenantTx } from '@/db';
import { CreateOfferingRequest } from '@/domain/schemas/catalog';

export const GET = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true });
  return json({ data: await withTenantTx(ctx, listOfferings) });
});

export const POST = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  const body = await parseBody(req, CreateOfferingRequest);
  const hash = requestHash('POST', '/offerings', body);
  const result = await withTenantTx(ctx, (tx) =>
    command<Offering & { idempotent_replay: boolean }>(
      tx`SELECT app.save_offering(NULL, NULL, ${tx.json(body)}::jsonb, ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, result.idempotent_replay ? 200 : 201, etag(result.version));
});
