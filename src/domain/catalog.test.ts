import { describe, expect, it } from 'vitest';
import { isValidBuffer, isValidDuration } from './catalog';
import { CreateOfferingRequest, ReplaceSamagriTemplateRequest, UpdatePriestSettingsRequest } from './schemas/catalog';

describe('duration bounds 15–1440', () => {
  it.each([15, 60, 1440])('accepts %i', (m) => expect(isValidDuration(m)).toBe(true));
  it.each([14, 1441, 0, 90.5, '60', NaN])('rejects %j', (m) => expect(isValidDuration(m)).toBe(false));
});

describe('buffer bounds 0–240', () => {
  it.each([0, 45, 240])('accepts %i', (m) => expect(isValidBuffer(m)).toBe(true));
  it.each([-1, 241, 30.5])('rejects %j', (m) => expect(isValidBuffer(m)).toBe(false));
});

describe('catalog schemas', () => {
  it('an offering from the catalog needs only the ceremony id', () => {
    expect(CreateOfferingRequest.safeParse({ ceremony_type_id: '0f8fad5b-d9cb-469f-a165-70867728950e' }).success).toBe(true);
  });
  it('a custom offering needs both names and a duration', () => {
    expect(CreateOfferingRequest.safeParse({ name_hi: 'कथा', name_en: 'Katha' }).success).toBe(false);
    expect(CreateOfferingRequest.safeParse({ name_hi: 'कथा', name_en: 'Katha', duration_min: 60 }).success).toBe(true);
  });
  it('rejects money as rupees text and unknown fields', () => {
    expect(CreateOfferingRequest.safeParse({ name_hi: 'x', name_en: 'x', duration_min: 60, suggested_dakshina_paise: '5100' }).success).toBe(false);
    expect(CreateOfferingRequest.safeParse({ name_hi: 'x', name_en: 'x', duration_min: 60, price: 1 }).success).toBe(false);
  });
  it('samagri items: FAMILY or PRIEST, blank quantity becomes null, at most 100', () => {
    expect(
      ReplaceSamagriTemplateRequest.parse({ items: [{ name: ' Ghee ', quantity: ' ', provided_by: 'FAMILY' }] }),
    ).toEqual({ items: [{ name: 'Ghee', quantity: null, provided_by: 'FAMILY' }] });
    expect(ReplaceSamagriTemplateRequest.safeParse({ items: [{ name: 'x', provided_by: 'TEMPLE' }] }).success).toBe(false);
    const many = Array.from({ length: 101 }, (_, i) => ({ name: `i${i}`, provided_by: 'FAMILY' }));
    expect(ReplaceSamagriTemplateRequest.safeParse({ items: many }).success).toBe(false);
  });
  it('priest settings need at least one buffer within 0–240', () => {
    expect(UpdatePriestSettingsRequest.safeParse({}).success).toBe(false);
    expect(UpdatePriestSettingsRequest.safeParse({ default_buffer_before_min: 45 }).success).toBe(true);
    expect(UpdatePriestSettingsRequest.safeParse({ default_buffer_after_min: 300 }).success).toBe(false);
  });
});
