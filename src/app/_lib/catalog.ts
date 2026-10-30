// Catalog and settings reads (SELECT under RLS as app_runtime), shared by the API routes and the pages.
import type { Tx } from '@/db';
import type { ProvidedBy } from '@/domain/catalog';

export interface Offering {
  id: string;
  ceremony_type_id: string | null;
  name_hi: string;
  name_en: string;
  duration_min: number;
  suggested_dakshina_paise: number | null;
  is_active: boolean;
  version: number;
}

export interface SamagriItem {
  position: number;
  name: string;
  quantity: string | null;
  provided_by: ProvidedBy;
}

export interface SamagriTemplate {
  id: string;
  offering_id: string;
  version: number;
  items: SamagriItem[];
}

export interface PriestLink {
  id: string;
  priest_profile_id: string;
  display_name: string;
  default_buffer_before_min: number;
  default_buffer_after_min: number;
}

export async function listOfferings(tx: Tx): Promise<Offering[]> {
  return [
    ...(await tx<Offering[]>`
      SELECT id, ceremony_type_id, name_hi, name_en, duration_min,
             -- bigint as a JSON integer (postgres.js returns raw int8 as a string; money never becomes a float)
             to_jsonb(suggested_dakshina_paise) AS suggested_dakshina_paise, is_active, version
      FROM app.offerings
      WHERE org_id = app.current_tenant_id()
      ORDER BY is_active DESC, lower(name_en), id`),
  ];
}

export async function listTemplates(tx: Tx, offeringId?: string): Promise<SamagriTemplate[]> {
  return [
    ...(await tx<SamagriTemplate[]>`
      SELECT t.id, t.offering_id, t.version,
             coalesce((SELECT jsonb_agg(jsonb_build_object('position', i.position, 'name', i.name,
                                                           'quantity', i.quantity, 'provided_by', i.provided_by)
                                        ORDER BY i.position)
                       FROM app.samagri_template_items i WHERE i.template_id = t.id), '[]'::jsonb) AS items
      FROM app.samagri_templates t
      WHERE t.org_id = app.current_tenant_id()
        AND (${offeringId ?? null}::uuid IS NULL OR t.offering_id = ${offeringId ?? null}::uuid)
      ORDER BY t.created_at, t.id`),
  ];
}

export async function listPriests(tx: Tx): Promise<PriestLink[]> {
  return [
    ...(await tx<PriestLink[]>`
      SELECT op.id, op.priest_profile_id, p.display_name, op.default_buffer_before_min, op.default_buffer_after_min
      FROM app.organization_priests op
      JOIN app.priest_profiles p ON p.id = op.priest_profile_id
      WHERE op.org_id = app.current_tenant_id()
      ORDER BY op.created_at, op.id`),
  ];
}
