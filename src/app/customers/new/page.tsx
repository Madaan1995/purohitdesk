import { AppHeader } from '@/app/_components/AppHeader';
import { CustomerForm } from '@/app/_components/CustomerForm';
import { requirePractice } from '@/app/_lib/page-auth';
import { getTranslations } from 'next-intl/server';
import Link from 'next/link';
import { redirect } from 'next/navigation';

export default async function NewCustomerPage() {
  const { current } = await requirePractice();
  if (!current.permissions.includes('CUSTOMER_WRITE')) redirect('/customers');
  const t = await getTranslations('customers');
  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <h1 className="text-2xl font-bold">{t('newTitle')}</h1>
        <CustomerForm tenantId={current.organization.id} />
        <Link href="/customers" className="text-base text-brand underline">
          {t('back')}
        </Link>
      </main>
    </>
  );
}
