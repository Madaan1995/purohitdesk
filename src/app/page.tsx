import { AppHeader } from '@/app/_components/AppHeader';
import { PracticeSwitcher } from '@/app/_components/PracticeSwitcher';
import { currentActor } from '@/app/_lib/page-auth';
import { loadSession } from '@/app/_lib/session';
import { getTranslations } from 'next-intl/server';
import { cookies } from 'next/headers';
import Link from 'next/link';
import { redirect } from 'next/navigation';

export default async function Home() {
  const actorId = await currentActor();
  if (!actorId) redirect('/sign-in');
  const store = await cookies();
  const session = await loadSession(actorId, store.get('NEXT_LOCALE')?.value ?? null);
  if (session.memberships.length === 0) redirect('/onboarding');

  const selected = store.get('pd_tenant')?.value;
  const current = session.memberships.find((m) => m.organization.id === selected) ?? session.memberships[0];
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
    </>
  );
}
