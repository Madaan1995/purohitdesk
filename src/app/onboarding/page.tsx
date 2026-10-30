import { AppHeader } from '@/app/_components/AppHeader';
import { OnboardingForm } from '@/app/_components/OnboardingForm';
import { currentIdentity } from '@/app/_lib/page-auth';
import { loadSession } from '@/app/_lib/session';
import { withTenantTx } from '@/db';
import { getTranslations } from 'next-intl/server';
import { cookies } from 'next/headers';
import Link from 'next/link';
import { redirect } from 'next/navigation';

export default async function OnboardingPage() {
  const identity = await currentIdentity();
  if (!identity) redirect('/sign-in');
  const store = await cookies();
  const session = await loadSession(identity, store.get('NEXT_LOCALE')?.value ?? null);
  const ceremonies = await withTenantTx({ actorId: identity.actorId }, (tx) =>
    tx<{ id: string; name_en: string; name_hi: string; default_duration_min: number }[]>`
      SELECT id, name_en, name_hi, default_duration_min FROM app.ceremony_types ORDER BY name_en`,
  );
  const t = await getTranslations('onboarding');
  const owned = session.memberships.filter((m) => m.role === 'OWNER').length;

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-6 px-4 py-6">
        <h1 className="text-2xl font-bold">{t('title')}</h1>
        {owned >= 3 ? (
          <p role="alert" className="rounded-lg bg-amber-50 px-3 py-2 text-base text-amber-900">
            {t('quota')}
          </p>
        ) : (
          <OnboardingForm ceremonies={[...ceremonies]} />
        )}
        {session.memberships.length > 0 && (
          <Link href="/" className="text-base text-brand underline">
            {t('back')}
          </Link>
        )}
      </main>
    </>
  );
}
