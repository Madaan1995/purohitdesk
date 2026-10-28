import { describe, expect, it } from 'vitest';
import { requestHash } from './request-hash';

describe('requestHash', () => {
  it('is a 64-char hex SHA-256', () => {
    expect(requestHash('POST', '/onboarding/practice', { name: 'x' })).toMatch(/^[0-9a-f]{64}$/);
  });
  it('is stable for reordered JSON keys', () => {
    const a = requestHash('POST', '/onboarding/practice', { name: 'Sharma', ceremony_type_ids: ['1', '2'] });
    const b = requestHash('post', '/onboarding/practice', { ceremony_type_ids: ['1', '2'], name: 'Sharma' });
    expect(a).toBe(b);
  });
  it('changes with the method, path or body', () => {
    const base = requestHash('POST', '/onboarding/practice', { name: 'x' });
    expect(requestHash('PATCH', '/onboarding/practice', { name: 'x' })).not.toBe(base);
    expect(requestHash('POST', '/customers', { name: 'x' })).not.toBe(base);
    expect(requestHash('POST', '/onboarding/practice', { name: 'y' })).not.toBe(base);
  });
});
