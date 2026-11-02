// PUT /api/v1/samagri-templates/{templateId} — CATALOG_WRITE (app.save_samagri_template, replace items); If-Match.
import type { SamagriTemplate } from '@/app/_lib/catalog';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, parseIfMatch, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, DomainError, withTenantTx } from '@/db';
import { apiError } from '@/domain/errors';
import { ReplaceSamagriTemplateRequest } from '@/domain/schemas/catalog';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const PUT = route(async (req: Request, { params }: { params: Promise<{ templateId: string }> }) => {
  const { templateId } = await params;
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  if (!UUID.test(templateId)) throw new DomainError(apiError('NOT_FOUND', { details: { resource: 'samagri_template' } }));
  const version = parseIfMatch(req);
  const body = await parseBody(req, ReplaceSamagriTemplateRequest);
  const hash = requestHash('PUT', `/samagri-templates/${templateId}`, body);
  const result = await withTenantTx(ctx, (tx) =>
    command<SamagriTemplate & { idempotent_replay: boolean }>(
      tx`SELECT app.save_samagri_template(${templateId}::uuid, ${version}::int, NULL, ${tx.json(body.items)}::jsonb,
                                          ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, 200, etag(result.version));
});
