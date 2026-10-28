import { describe, expect, it } from 'vitest';
import en from '../messages/en.json';
import hi from '../messages/hi.json';
import { ERROR_CODES } from '../src/domain/errors';
import { PERMISSIONS, ROLES } from '../src/domain/permissions';

function keys(obj: object, prefix = ''): string[] {
  return Object.entries(obj).flatMap(([k, v]) =>
    v && typeof v === 'object' ? keys(v, `${prefix}${k}.`) : [`${prefix}${k}`],
  );
}

describe('message catalogs', () => {
  it('Hindi and English have exactly the same keys', () => {
    expect(keys(hi).sort()).toEqual(keys(en).sort());
  });

  it.each([
    ['roles', ROLES],
    ['permissions', PERMISSIONS],
    ['errors', ERROR_CODES],
  ] as const)('every %s value has a label in both languages', (group, values) => {
    for (const value of values) {
      expect((hi as Record<string, Record<string, string>>)[group][value]).toBeTruthy();
      expect((en as Record<string, Record<string, string>>)[group][value]).toBeTruthy();
    }
  });

  it('shows both app names', () => {
    expect([hi.app.name, hi.app.nameLatin].sort()).toEqual(['PurohitDesk', 'पुरोहित डेस्क'].sort());
    expect([en.app.name, en.app.nameLatin].sort()).toEqual(['PurohitDesk', 'पुरोहित डेस्क'].sort());
  });
});
