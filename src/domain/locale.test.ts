import { describe, expect, it } from 'vitest';
import { resolveLocale } from './locale';

describe('resolveLocale', () => {
  it('uses the profile language after sign-in, even if the cookie differs', () => {
    expect(resolveLocale({ profile: 'en', cookie: 'hi' })).toBe('en');
  });
  it('uses the cookie before sign-in', () => {
    expect(resolveLocale({ profile: null, cookie: 'en' })).toBe('en');
  });
  it('defaults to Hindi', () => {
    expect(resolveLocale({})).toBe('hi');
  });
  it('ignores unsupported values', () => {
    expect(resolveLocale({ profile: 'pa', cookie: 'fr' })).toBe('hi');
  });
});
