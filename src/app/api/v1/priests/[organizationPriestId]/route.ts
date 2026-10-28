// PATCH /api/v1/priests/{organizationPriestId} — ORG_SETTINGS, or the priest himself (app.update_priest_settings).
import type { PriestLink } from '@/app/_lib/catalog';
import { requireContext } from '@/app/_lib/context';
import { json, parseBody, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, DomainError, withTenantTx } from '@/db';
import { apiError } from '@/domain/errors';
import { UpdatePriestSettingsRequest } from '@/domain/schemas/catalog';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const PATCH = route(
  async (req: Request, { params }: { params: Promise<{ organizationPriestId: string }> }) => {
    const { organizationPriestId } = await params;
    const ctx = await requireContext(req, { tenant: true, idempotency: true });
    if (!UUID.test(organizationPriestId)) throw new DomainError(apiError('NOT_FOUND', { details: { resource: 'priest' } }));
    const body = await parseBody(req, UpdatePriestSettingsRequest);
    const hash = requestHash('PATCH', `/priests/${organizationPriestId}`, body);
    const result = await withTenantTx(ctx, (tx) =>
      command<PriestLink & { idempotent_replay: boolean }>(
        tx`SELECT app.update_priest_settings(${organizationPriestId}::uuid, ${body.default_buffer_before_min ?? null}::int,
                                             ${body.default_buffer_after_min ?? null}::int, ${ctx.idempotencyKey},
                                             ${hash}) AS result`,
      ),
    );
    return json(result);
  },
);
