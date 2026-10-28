import { AppHeader } from '@/app/_components/AppHeader';
import { BadCursorError, listCustomers } from '@/app/_lib/customers';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { formatPhone } from '@/domain/phone';
import { getTranslations } from 'next-intl/server';
import Link from 'next/link';

export default async function CustomersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string | string[]; cursor?: string | string[] }>;
}) {
  const { actorId, current } = await requirePractice();
  const sp = await searchParams;
  const q = typeof sp.q === 'string' ? sp.q.trim().slice(0, 60) : '';
  const cursor = typeof sp.cursor === 'string' ? sp.cursor : undefined;
  const page = await withTenantTx({ actorId, tenantId: current.organization.id }, async (tx) => {
    try {
      return await listCustomers(tx, { q, limit: 50, cursor });
    } catch (error) {
      if (error instanceof BadCursorError) return listCustomers(tx, { q, limit: 50 });
      throw error;
    }
  });
  const t = await getTranslations('customers');
  const canWrite = current.permissions.includes('CUSTOMER_WRITE');
  const more = page.next_cursor
    ? `/customers?${new URLSearchParams({ ...(q ? { q } : {}), cursor: page.next_cursor })}`
    : null;

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <h1 className="text-2xl font-bold">{t('title')}</h1>
        <form action="/customers" method="get" className="flex gap-2" role="search">
          <label className="sr-only" htmlFor="q">
            {t('searchLabel')}
          </label>
          <input
            id="q"
            name="q"
            defaultValue={q}
            maxLength={60}
            placeholder={t('searchLabel')}
            className="min-h-11 min-w-0 flex-1 rounded-lg border border-neutral-300 px-3 text-base"
          />
          <button type="submit" className="min-h-11 rounded-lg border border-brand px-4 text-base text-brand">
            {t('search')}
          </button>
        </form>
        {canWrite && (
          <Link
            href="/customers/new"
            className="flex min-h-11 items-center justify-center rounded-lg bg-brand px-4 text-lg font-semibold text-white"
          >
            {t('add')}
          </Link>
        )}
        {page.data.length === 0 ? (
          <p className="text-base text-neutral-600">{t('none')}</p>
        ) : (
          <ul className="flex flex-col gap-2">
            {page.data.map((c) => (
              <li key={c.id}>
                <Link
                  href={`/customers/${c.id}`}
                  className="flex min-h-11 flex-col rounded-lg border border-neutral-200 px-3 py-2"
                >
                  <span className="text-base font-semibold">{c.display_name}</span>
                  <span className="text-base text-neutral-600">{c.phone_e164 ? formatPhone(c.phone_e164) : t('noPhone')}</span>
                </Link>
              </li>
            ))}
          </ul>
        )}
        {more && (
          <Link href={more} className="flex min-h-11 items-center justify-center rounded-lg border border-neutral-300 text-base">
            {t('loadMore')}
          </Link>
        )}
      </main>
    </>
  );
}
