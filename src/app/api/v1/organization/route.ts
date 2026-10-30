// GET /api/v1/organization — ORG_READ (every role); SELECT under RLS for the X-Tenant-ID organization.
// PATCH — ORG_SETTINGS (app.update_organization); If-Match required.
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, parseIfMatch, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, DomainError, withTenantTx } from '@/db';
import { apiError } from '@/domain/errors';
import { UpdateOrganizationRequest } from '@/domain/schemas/catalog';

export interface Organization {
  id: string;
  kind: 'SOLO' | 'COLLECTIVE';
  name: string;
  slug: string;
  timezone: string;
  plan: string;
  status: string;
  version: number;
}

export const GET = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true });
  const org = await withTenantTx(ctx, async (tx) => {
    const [row] = await tx<Organization[]>`
      SELECT id, kind, name, slug, timezone, plan, status, version
      FROM app.organizations WHERE id = app.current_tenant_id()`;
    if (!row) throw new DomainError(apiError('NOT_FOUND', { details: { resource: 'organization' } }));
    return row;
  });
  return json(org, 200, { ETag: `"${org.version}"` });
});

export const PATCH = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  const version = parseIfMatch(req);
  const body = await parseBody(req, UpdateOrganizationRequest);
  const hash = requestHash('PATCH', '/organization', body);
  const org = await withTenantTx(ctx, (tx) =>
    command<Organization & { idempotent_replay: boolean }>(
      tx`SELECT app.update_organization(${version}::int, ${tx.json(body)}::jsonb, ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(org, 200, etag(org.version));
});
