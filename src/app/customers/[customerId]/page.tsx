import { AppHeader } from '@/app/_components/AppHeader';
import { CustomerForm } from '@/app/_components/CustomerForm';
import { getCustomer, samePhoneCustomers } from '@/app/_lib/customers';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { formatPhone } from '@/domain/phone';
import { getTranslations } from 'next-intl/server';
import Link from 'next/link';
import { notFound } from 'next/navigation';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function CustomerPage({ params }: { params: Promise<{ customerId: string }> }) {
  const { customerId } = await params;
  const { actorId, current } = await requirePractice();
  if (!UUID.test(customerId)) notFound();
  const data = await withTenantTx({ actorId, tenantId: current.organization.id }, async (tx) => {
    const customer = await getCustomer(tx, customerId);
    return customer ? { customer, duplicates: await samePhoneCustomers(tx, customer) } : null;
  });
  if (!data) notFound();
  const { customer, duplicates } = data;
  const t = await getTranslations('customers');
  const canWrite = current.permissions.includes('CUSTOMER_WRITE');

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <Link href="/customers" className="text-base text-brand underline">
          {t('back')}
        </Link>
        <h1 className="text-2xl font-bold">{customer.display_name}</h1>
        <p className="text-base text-neutral-700">{customer.phone_e164 ? formatPhone(customer.phone_e164) : t('noPhone')}</p>
        {customer.address && <p className="whitespace-pre-line text-base text-neutral-700">{customer.address}</p>}
        {duplicates.length > 0 && (
          <section role="note" className="flex flex-col gap-1 rounded-lg bg-amber-50 px-3 py-2 text-amber-900">
            <p className="text-base font-semibold">{t('duplicates')}</p>
            <ul className="flex flex-col">
              {duplicates.map((d) => (
                <li key={d.id}>
                  <Link href={`/customers/${d.id}`} className="text-base underline">
                    {d.display_name}
                  </Link>
                </li>
              ))}
            </ul>
            <p className="text-base">{t('duplicatesHint')}</p>
          </section>
        )}
        {canWrite && (
          <section className="flex flex-col gap-3 border-t border-neutral-200 pt-4">
            <h2 className="text-lg font-semibold">{t('edit')}</h2>
            <CustomerForm tenantId={current.organization.id} initial={customer} />
          </section>
        )}
      </main>
    </>
  );
}
