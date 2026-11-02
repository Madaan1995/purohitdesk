// GET /api/v1/ceremony-types — authenticated; the global ceremony catalog (read-only).
import { requireContext } from '@/app/_lib/context';
import { json, route } from '@/app/_lib/http';
import { withTenantTx } from '@/db';

export interface CeremonyType {
  id: string;
  slug: string;
  name_en: string;
  name_hi: string;
  default_duration_min: number;
}

export const GET = route(async (req: Request) => {
  const ctx = await requireContext(req);
  const data = await withTenantTx({ actorId: ctx.actorId }, (tx) =>
    tx<CeremonyType[]>`SELECT id, slug, name_en, name_hi, default_duration_min
                       FROM app.ceremony_types ORDER BY name_en`,
  );
  return json({ data: [...data] });
});
