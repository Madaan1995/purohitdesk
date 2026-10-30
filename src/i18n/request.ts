import { resolveLocale } from '@/domain/locale';
import { getRequestConfig } from 'next-intl/server';
import { cookies } from 'next/headers';

// No locale in the URL (spec revision 2.1 #14): the NEXT_LOCALE cookie, synced from app_users.preferred_locale
// at sign-in and on every language change.
export default getRequestConfig(async () => {
  const store = await cookies();
  const locale = resolveLocale({ cookie: store.get('NEXT_LOCALE')?.value });
  return { locale, messages: (await import(`../../messages/${locale}.json`)).default };
});
