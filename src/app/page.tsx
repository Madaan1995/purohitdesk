import { AppHeader } from '@/app/_components/AppHeader';
import { PracticeSwitcher } from '@/app/_components/PracticeSwitcher';
import { SiteFooter } from '@/app/_components/SiteFooter';
import { requirePractice } from '@/app/_lib/page-auth';
import { getTranslations } from 'next-intl/server';
import Link from 'next/link';

export default async function Home() {
  const { session, current } = await requirePractice();
  const t = await getTranslations();
  const owned = session.memberships.filter((m) => m.role === 'OWNER').length;

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-6 px-4 py-6">
        <section className="flex flex-col gap-1">
          <h1 className="text-base text-neutral-600">{t('home.currentPractice')}</h1>
          <p className="text-2xl font-bold">{current.organization.name}</p>
          <p className="text-base text-neutral-600">
            {t('home.timezone')}: {current.organization.timezone}
          </p>
        </section>

        {session.memberships.length > 1 && (
          <PracticeSwitcher
            current={current.organization.id}
            practices={session.memberships.map((m) => ({ id: m.organization.id, name: m.organization.name }))}
          />
        )}

        <section className="flex flex-col gap-2">
          <h2 className="text-base text-neutral-600">{t('home.yourRole')}</h2>
          <p className="text-xl font-semibold">
            {t(`roles.${current.role}`)} <span className="text-base text-neutral-500">({current.role})</span>
          </p>
        </section>

        <section className="flex flex-col gap-2">
          <h2 className="text-lg font-semibold">{t('home.permissions')}</h2>
          <ul className="flex flex-col gap-1">
            {current.permissions.map((p) => (
              <li key={p} className="rounded-lg bg-neutral-50 px-3 py-2 text-base">
                {t(`permissions.${p}`)}
              </li>
            ))}
          </ul>
        </section>

        {owned < 3 && (
          <Link
            href="/onboarding"
            className="flex min-h-11 items-center justify-center rounded-lg border border-brand px-4 text-base text-brand"
          >
            {t('nav.addPractice')}
          </Link>
        )}
      </main>
      <SiteFooter />
    </>
  );
}
