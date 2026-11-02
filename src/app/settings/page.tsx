import { AppHeader } from '@/app/_components/AppHeader';
import { OrganizationSettingsForm } from '@/app/_components/OrganizationSettingsForm';
import { PriestBuffersForm } from '@/app/_components/PriestBuffersForm';
import { listPriests } from '@/app/_lib/catalog';
import { requirePractice } from '@/app/_lib/page-auth';
import { withTenantTx } from '@/db';
import { getTranslations } from 'next-intl/server';
import Link from 'next/link';

export default async function SettingsPage() {
  const { actorId, current } = await requirePractice();
  const tenantId = current.organization.id;
  const data = await withTenantTx({ actorId, tenantId }, async (tx) => {
    const [org] = await tx<{ name: string; timezone: string; version: number }[]>`
      SELECT name, timezone, version FROM app.organizations WHERE id = app.current_tenant_id()`;
    const [own] = await tx<{ id: string }[]>`SELECT id FROM app.priest_profiles WHERE user_id = app.current_actor_id()`;
    return { org, ownProfileId: own?.id ?? null, priests: await listPriests(tx) };
  });
  const t = await getTranslations('settings');
  const canSettings = current.permissions.includes('ORG_SETTINGS');

  return (
    <>
      <AppHeader signedIn />
      <main className="mx-auto flex max-w-2xl flex-col gap-8 px-4 py-6">
        <h1 className="text-2xl font-bold">{t('title')}</h1>

        <section className="flex flex-col gap-3">
          <h2 className="text-lg font-semibold">{t('practice')}</h2>
          {canSettings ? (
            <OrganizationSettingsForm tenantId={tenantId} name={data.org.name} timezone={data.org.timezone} version={data.org.version} />
          ) : (
            <>
              <p className="text-base">{data.org.name}</p>
              <p className="text-base text-neutral-600">
                {t('timezone')}: {data.org.timezone}
              </p>
            </>
          )}
        </section>

        <section className="flex flex-col gap-3">
          <h2 className="text-lg font-semibold">{t('buffers')}</h2>
          <p className="text-base text-neutral-600">{t('buffersHint')}</p>
          {data.priests.map((p) =>
            canSettings || p.priest_profile_id === data.ownProfileId ? (
              <PriestBuffersForm key={p.id} tenantId={tenantId} linkId={p.id} displayName={p.display_name}
                before={p.default_buffer_before_min} after={p.default_buffer_after_min} />
            ) : (
              <p key={p.id} className="text-base">
                {p.display_name}: {t('before')} {p.default_buffer_before_min} · {t('after')} {p.default_buffer_after_min}
              </p>
            ),
          )}
        </section>

        <Link href="/settings/offerings"
          className="flex min-h-11 items-center justify-center rounded-lg border border-brand px-4 text-base text-brand">
          {t('offeringsLink')}
        </Link>
      </main>
    </>
  );
}
