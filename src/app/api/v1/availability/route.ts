// GET /api/v1/availability?priest_id=&from=&to= — ORG_READ (app.priest_busy). from/to are local dates (inclusive) in
// the practice's time zone, at most 62 days. Other practices' busy time comes back as BUSY, without ids or details.
import { priestBusy } from '@/app/_lib/agenda';
import { requireContext } from '@/app/_lib/context';
import { json, route } from '@/app/_lib/http';
import { withTenantTx } from '@/db';
import { localRangeBounds } from '@/domain/agenda';
import { AvailabilityQuery } from '@/domain/schemas/agenda';

export const GET = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true });
  const q = AvailabilityQuery.parse(Object.fromEntries(new URL(req.url).searchParams));
  const result = await withTenantTx(ctx, async (tx) => {
    const [org] = await tx<{ timezone: string }[]>`SELECT timezone FROM app.organizations WHERE id = app.current_tenant_id()`;
    const { from, to } = localRangeBounds(q.from, q.to, org.timezone);
    const spans = await priestBusy(tx, q.priest_id, from, to);
    return {
      priest_id: q.priest_id,
      timezone: org.timezone,
      from: q.from,
      to: q.to,
      busy: spans.map((s) => ({
        kind: s.kind,
        starts_at: s.starts_at,
        ends_at: s.ends_at,
        same_org: s.same_org,
        ...(s.booking_id ? { booking_id: s.booking_id } : {}),
        ...(s.kind === 'BLOCK' && s.reservation_id ? { block_id: s.reservation_id } : {}),
      })),
    };
  });
  return json(result);
});
