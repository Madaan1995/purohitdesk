import { AppHeader } from '@/app/_components/AppHeader';
import { OfferingForm } from '@/app/_components/OfferingForm';
import { SamagriEditor } from '@/app/_components/SamagriEditor';
import { listOfferings, listTemplates } from '@/app/_lib/catalog';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { formatPaise } from '@/domain/money';
import { getLocale, getTranslations } from 'next-intl/server';
import Link from 'next/link';
import { notFound } from 'next/navigation';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function OfferingPage({ params }: { params: Promise<{ offeringId: string }> }) {
  const { offeringId } = await params;
  const { actorId, current } = await requirePractice();
  if (!UUID.test(offeringId)) notFound();
  const tenantId = current.organization.id;
  const data = await withTenantTx({ actorId, tenantId }, async (tx) => {
    const offering = (await listOfferings(tx)).find((o) => o.id === offeringId);
    return offering ? { offering, template: (await listTemplates(tx, offeringId))[0] ?? null } : null;
  });
  if (!data) notFound();
  const { offering, template } = data;
  const t = await getTranslations();
  const locale = await getLocale();
  const canWrite = current.permissions.includes('CATALOG_WRITE');

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-6 px-4 py-6">
        <Link href="/settings/offerings" className="text-base text-brand underline">
          {t('offerings.back')}
        </Link>
        <h1 className="text-2xl font-bold">{locale === 'hi' ? offering.name_hi : offering.name_en}</h1>

        <section className="flex flex-col gap-3">
          <h2 className="text-lg font-semibold">{t('offerings.edit')}</h2>
          {canWrite ? (
            <OfferingForm tenantId={tenantId} initial={offering} />
          ) : (
            <p className="text-base">
              {t('offerings.minutes', { count: offering.duration_min })} ·{' '}
              {offering.suggested_dakshina_paise != null ? formatPaise(offering.suggested_dakshina_paise) : t('offerings.noDakshina')}
            </p>
          )}
        </section>

        <section className="flex flex-col gap-3 border-t border-neutral-200 pt-4">
          <h2 className="text-lg font-semibold">{t('samagri.title')}</h2>
          {canWrite ? (
            <SamagriEditor tenantId={tenantId} offeringId={offering.id} template={template} />
          ) : template && template.items.length > 0 ? (
            <ol className="flex flex-col gap-1">
              {template.items.map((i) => (
                <li key={i.position} className="rounded-lg bg-neutral-50 px-3 py-2 text-base">
                  {i.name}
                  {i.quantity ? ` — ${i.quantity}` : ''} · {i.provided_by === 'FAMILY' ? t('samagri.family') : t('samagri.priest')}
                </li>
              ))}
            </ol>
          ) : (
            <p className="text-base text-neutral-600">{t('samagri.empty')}</p>
          )}
        </section>
      </main>
    </>
  );
}
