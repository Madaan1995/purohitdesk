// GET /api/v1/organization — ORG_READ (every role); SELECT under RLS for the X-Tenant-ID organization.
import { requireContext } from '@/app/_lib/context';
import { json, route } from '@/app/_lib/http';
import { DomainError, withTenantTx } from '@/db';
import { apiError } from '@/domain/errors';

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
