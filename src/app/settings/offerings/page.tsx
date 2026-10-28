import { AddOfferingFromCatalog } from '@/app/_components/AddOfferingFromCatalog';
import { AppHeader } from '@/app/_components/AppHeader';
import { OfferingForm } from '@/app/_components/OfferingForm';
import { listOfferings } from '@/app/_lib/catalog';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { formatPaise } from '@/domain/money';
import { getLocale, getTranslations } from 'next-intl/server';
import Link from 'next/link';

export default async function OfferingsPage() {
  const { actorId, current } = await requirePractice();
  const tenantId = current.organization.id;
  const { offerings, catalog } = await withTenantTx({ actorId, tenantId }, async (tx) => ({
    offerings: await listOfferings(tx),
    catalog: [
      ...(await tx<{ id: string; name_hi: string; name_en: string }[]>`
        SELECT c.id, c.name_hi, c.name_en FROM app.ceremony_types c
        WHERE NOT EXISTS (SELECT 1 FROM app.offerings o
                          WHERE o.org_id = app.current_tenant_id() AND o.ceremony_type_id = c.id)
        ORDER BY c.name_en`),
    ],
  }));
  const t = await getTranslations('offerings');
  const locale = await getLocale();
  const canWrite = current.permissions.includes('CATALOG_WRITE');

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-6 px-4 py-6">
        <Link href="/settings" className="text-base text-brand underline">
          ← {(await getTranslations('settings'))('title')}
        </Link>
        <h1 className="text-2xl font-bold">{t('title')}</h1>
        {offerings.length === 0 ? (
          <p className="text-base text-neutral-600">{t('none')}</p>
        ) : (
          <ul className="flex flex-col gap-2">
            {offerings.map((o) => (
              <li key={o.id}>
                <Link href={`/settings/offerings/${o.id}`}
                  className="flex min-h-11 flex-col rounded-lg border border-neutral-200 px-3 py-2">
                  <span className="text-base font-semibold">
                    {locale === 'hi' ? o.name_hi : o.name_en}
                    {!o.is_active && <span className="ml-2 text-base font-normal text-neutral-500">({t('inactive')})</span>}
                  </span>
                  <span className="text-base text-neutral-600">
                    {t('minutes', { count: o.duration_min })} ·{' '}
                    {o.suggested_dakshina_paise != null ? formatPaise(o.suggested_dakshina_paise) : t('noDakshina')}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
        {canWrite && (
          <>
            <section className="flex flex-col gap-3 border-t border-neutral-200 pt-4">
              <AddOfferingFromCatalog tenantId={tenantId} ceremonies={catalog} />
            </section>
            <section className="flex flex-col gap-3 border-t border-neutral-200 pt-4">
              <h2 className="text-lg font-semibold">{t('addCustom')}</h2>
              <OfferingForm tenantId={tenantId} />
            </section>
          </>
        )}
      </main>
    </>
  );
}
