'use client';

import { useLocale, useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState, type FormEvent } from 'react';
import { apiWrite } from './api-client';
import { FormStatus } from './FormStatus';

interface Ceremony {
  id: string;
  name_hi: string;
  name_en: string;
}

export function AddOfferingFromCatalog({ tenantId, ceremonies }: { tenantId: string; ceremonies: Ceremony[] }) {
  const t = useTranslations();
  const locale = useLocale();
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [selected, setSelected] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy || !selected) return;
    setBusy(true);
    setError(null);
    const result = await apiWrite<{ id: string }>('/offerings', {
      method: 'POST',
      tenantId,
      idempotencyKey: key.current,
      body: { ceremony_type_id: selected },
    });
    setBusy(false);
    if (!result.ok) {
      setError(t(`errors.${result.code}` as 'errors.INTERNAL'));
      return;
    }
    router.push(`/settings/offerings/${result.data.id}`);
  }

  if (ceremonies.length === 0) return <p className="text-base text-neutral-600">{t('offerings.allAdded')}</p>;
  return (
    <form onSubmit={submit} className="flex flex-col gap-3">
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('offerings.addFromCatalog')}</span>
        <select value={selected} onChange={(e) => setSelected(e.target.value)} required
          className="min-h-11 rounded-lg border border-neutral-300 bg-white px-3 text-base">
          <option value="">{t('offerings.choose')}</option>
          {ceremonies.map((c) => (
            <option key={c.id} value={c.id}>
              {locale === 'hi' ? `${c.name_hi} · ${c.name_en}` : `${c.name_en} · ${c.name_hi}`}
            </option>
          ))}
        </select>
      </label>
      <FormStatus error={error} saved={null} />
      <button type="submit" disabled={busy || !selected}
        className="min-h-11 rounded-lg border border-brand px-4 text-base text-brand disabled:opacity-60">
        {t('offerings.add')}
      </button>
    </form>
  );
}
