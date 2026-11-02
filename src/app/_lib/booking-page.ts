// Data the booking form pages need: active offerings (plus the booking's own), the practice's priests, and whether
// the actor may confirm. Read as app_runtime under RLS.
import type { FormOffering } from '@/app/_components/BookingForm';
import type { Tx } from '@/db';
import { listPriests } from './bookings';

export async function bookingFormData(tx: Tx, keepOfferingId?: string) {
  const offerings = [
    ...(await tx<FormOffering[]>`
      SELECT id, name_hi, name_en, duration_min, suggested_dakshina_paise
      FROM app.offerings
      WHERE org_id = app.current_tenant_id() AND (is_active OR id = ${keepOfferingId ?? null}::uuid)
      ORDER BY lower(name_en), id`),
  ].map((o) => ({ ...o, suggested_dakshina_paise: o.suggested_dakshina_paise === null ? null : Number(o.suggested_dakshina_paise) }));
  return { offerings, priests: await listPriests(tx) };
}

/** The actor's own global priest profile (for the _OWN permissions), or null. */
export async function ownPriestProfile(tx: Tx): Promise<string | null> {
  const [row] = await tx<{ id: string }[]>`SELECT id FROM app.priest_profiles WHERE user_id = app.current_actor_id()`;
  return row?.id ?? null;
}
