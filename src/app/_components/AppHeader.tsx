import { getTranslations } from 'next-intl/server';
import Link from 'next/link';
import { LanguageToggle } from './LanguageToggle';

export async function AppHeader({ signedIn }: { signedIn: boolean }) {
  const t = await getTranslations();
  return (
    <header className="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-200 px-4 py-3">
      <div className="flex flex-col">
        <span className="text-xl font-bold text-brand">{t('app.name')}</span>
        <span className="text-base text-neutral-600">{t('app.nameLatin')}</span>
      </div>
      <div className="flex items-center gap-2">
        <LanguageToggle signedIn={signedIn} />
        {signedIn && (
          <form action="/auth/sign-out" method="post">
            <button type="submit" className="min-h-11 rounded-lg border border-neutral-300 px-4 text-base">
              {t('nav.signOut')}
            </button>
          </form>
        )}
      </div>
      {signedIn && (
        <nav className="flex w-full gap-2">
          <Link href="/" className="flex min-h-11 items-center rounded-lg px-3 text-base text-brand underline">
            {t('nav.home')}
          </Link>
          <Link href="/customers" className="flex min-h-11 items-center rounded-lg px-3 text-base text-brand underline">
            {t('nav.customers')}
          </Link>
          <Link href="/settings" className="flex min-h-11 items-center rounded-lg px-3 text-base text-brand underline">
            {t('nav.settings')}
          </Link>
        </nav>
      )}
    </header>
  );
}
