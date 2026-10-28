// UI languages. Hindi first (spec §01 §5); no locale in the URL (revision 2.1 #14).

export const LOCALES = ['hi', 'en'] as const;
export type Locale = (typeof LOCALES)[number];
export const DEFAULT_LOCALE: Locale = 'hi';

export function isLocale(value: unknown): value is Locale {
  return typeof value === 'string' && (LOCALES as readonly string[]).includes(value);
}

/** After sign-in the profile's language wins; before sign-in the cookie; otherwise Hindi. */
export function resolveLocale(input: { profile?: string | null; cookie?: string | null }): Locale {
  if (isLocale(input.profile)) return input.profile;
  if (isLocale(input.cookie)) return input.cookie;
  return DEFAULT_LOCALE;
}
