// GET /api/v1/samagri-templates — ORG_READ; POST — CATALOG_WRITE (app.save_samagri_template, create).
import { listTemplates, type SamagriTemplate } from '@/app/_lib/catalog';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, withTenantTx } from '@/db';
import { CreateSamagriTemplateRequest } from '@/domain/schemas/catalog';

export const GET = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true });
  return json({ data: await withTenantTx(ctx, (tx) => listTemplates(tx)) });
});

export const POST = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  const body = await parseBody(req, CreateSamagriTemplateRequest);
  const hash = requestHash('POST', '/samagri-templates', body);
  const result = await withTenantTx(ctx, (tx) =>
    command<SamagriTemplate & { idempotent_replay: boolean }>(
      tx`SELECT app.save_samagri_template(NULL, NULL, ${body.offering_id}::uuid, ${tx.json(body.items)}::jsonb,
                                          ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, result.idempotent_replay ? 200 : 201, etag(result.version));
});
