// Request schemas for offerings, samagri templates, organization and priest settings (mirror api/openapi.yaml).
import { z } from 'zod';
import { BUFFER_MAX, DURATION_MAX, DURATION_MIN, MAX_SAMAGRI_ITEMS, PROVIDED_BY } from '../catalog';
import { MAX_PAISE } from '../money';

const name = z.string().trim().min(1).max(120);
const duration = z.number().int().min(DURATION_MIN).max(DURATION_MAX);
const paise = z.number().int().min(0).max(MAX_PAISE);
const buffer = z.number().int().min(0).max(BUFFER_MAX);
const nonEmpty = (b: object) => Object.keys(b).length > 0;

export const CreateOfferingRequest = z
  .strictObject({
    ceremony_type_id: z.uuid().optional(),
    name_hi: name.optional(),
    name_en: name.optional(),
    duration_min: duration.optional(),
    suggested_dakshina_paise: paise.nullable().optional(),
    is_active: z.boolean().optional(),
  })
  .refine(
    (b) => b.ceremony_type_id !== undefined || (b.name_hi && b.name_en && b.duration_min !== undefined),
    { message: 'a custom offering needs name_hi, name_en and duration_min', path: ['name_en'] },
  );

export const UpdateOfferingRequest = z
  .strictObject({
    name_hi: name.optional(),
    name_en: name.optional(),
    duration_min: duration.optional(),
    suggested_dakshina_paise: paise.nullable().optional(),
    is_active: z.boolean().optional(),
  })
  .refine(nonEmpty, { message: 'empty body' });

export const SamagriItem = z.strictObject({
  name: z.string().trim().min(1).max(120),
  quantity: z
    .string()
    .trim()
    .max(60)
    .transform((s) => s || null)
    .nullish(),
  provided_by: z.enum(PROVIDED_BY),
});

export const CreateSamagriTemplateRequest = z.strictObject({
  offering_id: z.uuid(),
  items: z.array(SamagriItem).max(MAX_SAMAGRI_ITEMS),
});

export const ReplaceSamagriTemplateRequest = z.strictObject({
  items: z.array(SamagriItem).max(MAX_SAMAGRI_ITEMS),
});

export const UpdateOrganizationRequest = z
  .strictObject({ name: name.optional(), timezone: z.string().trim().min(1).max(64).optional() })
  .refine(nonEmpty, { message: 'empty body' });

export const UpdatePriestSettingsRequest = z
  .strictObject({ default_buffer_before_min: buffer.optional(), default_buffer_after_min: buffer.optional() })
  .refine(nonEmpty, { message: 'empty body' });
