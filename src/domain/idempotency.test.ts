import { describe, expect, it } from 'vitest';
import { canonicalJson, isValidIdempotencyKey } from './idempotency';

describe('isValidIdempotencyKey', () => {
  it('accepts 8 to 128 visible ASCII characters', () => {
    expect(isValidIdempotencyKey('a'.repeat(8))).toBe(true);
    expect(isValidIdempotencyKey('a'.repeat(128))).toBe(true);
    expect(isValidIdempotencyKey(crypto.randomUUID())).toBe(true);
  });
  it('rejects shorter, longer, spaced, non-ASCII or missing keys', () => {
    expect(isValidIdempotencyKey('a'.repeat(7))).toBe(false);
    expect(isValidIdempotencyKey('a'.repeat(129))).toBe(false);
    expect(isValidIdempotencyKey('has space 123')).toBe(false);
    expect(isValidIdempotencyKey('कुंजी-12345678')).toBe(false);
    expect(isValidIdempotencyKey(undefined)).toBe(false);
  });
});

describe('canonicalJson', () => {
  it('is stable for reordered keys at every level', () => {
    const a = { name: 'x', ids: ['b', 'a'], nested: { z: 1, a: { y: 2, b: 3 } } };
    const b = { nested: { a: { b: 3, y: 2 }, z: 1 }, ids: ['b', 'a'], name: 'x' };
    expect(canonicalJson(a)).toBe(canonicalJson(b));
    expect(canonicalJson(a)).toBe('{"ids":["b","a"],"name":"x","nested":{"a":{"b":3,"y":2},"z":1}}');
  });
  it('keeps array order (it is meaningful)', () => {
    expect(canonicalJson([2, 1])).not.toBe(canonicalJson([1, 2]));
  });
  it('drops undefined like JSON.stringify and handles null bodies', () => {
    expect(canonicalJson({ a: undefined, b: 1 })).toBe('{"b":1}');
    expect(canonicalJson(null)).toBe('null');
    expect(canonicalJson(undefined)).toBe('null');
  });
});
