import { AppHeader } from '@/app/_components/AppHeader';
import { currentActor } from '@/app/_lib/page-auth';
import { getTranslations } from 'next-intl/server';
import { redirect } from 'next/navigation';

export default async function SignInPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  if (await currentActor()) redirect('/');
  const { error } = await searchParams;
  const t = await getTranslations('signIn');
  return (
    <>
      <AppHeader signedIn={false} />
      <main className="mx-auto flex max-w-md flex-col gap-6 px-4 py-10">
        <h1 className="text-2xl font-bold">{t('title')}</h1>
        <p className="text-lg text-neutral-700">{t('intro')}</p>
        {error && (
          <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-base text-red-800">
            {error === 'config' ? t('notConfigured') : t('failed')}
          </p>
        )}
        <a
          href="/auth/sign-in"
          className="flex min-h-11 items-center justify-center rounded-lg bg-brand px-4 text-lg font-semibold text-white"
        >
          {t('google')}
        </a>
      </main>
    </>
  );
}
