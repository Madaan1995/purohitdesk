'use client';

import { DURATION_MAX, DURATION_MIN } from '@/domain/catalog';
import { paiseToRupeeInput, parseRupees } from '@/domain/money';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState, type FormEvent } from 'react';
import { apiWrite } from './api-client';
import { FormStatus } from './FormStatus';

interface Initial {
  id: string;
  name_hi: string;
  name_en: string;
  duration_min: number;
  suggested_dakshina_paise: number | null;
  is_active: boolean;
  version: number;
}

/** Custom offering (POST) or edit an existing one (PATCH with If-Match). Dakshina is typed in rupees, sent in paise. */
export function OfferingForm({ tenantId, initial }: { tenantId: string; initial?: Initial }) {
  const t = useTranslations();
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [nameHi, setNameHi] = useState(initial?.name_hi ?? '');
  const [nameEn, setNameEn] = useState(initial?.name_en ?? '');
  const [duration, setDuration] = useState(String(initial?.duration_min ?? 60));
  const [dakshina, setDakshina] = useState(
    initial?.suggested_dakshina_paise != null ? paiseToRupeeInput(initial.suggested_dakshina_paise) : '',
  );
  const [active, setActive] = useState(initial?.is_active ?? true);
  const [version, setVersion] = useState(initial?.version ?? 1);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);

  const paise = dakshina.trim() === '' ? null : parseRupees(dakshina);
  const dakshinaInvalid = dakshina.trim() !== '' && paise === null;

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy || dakshinaInvalid) return;
    setBusy(true);
    setError(null);
    setSaved(null);
    const body = {
      name_hi: nameHi,
      name_en: nameEn,
      duration_min: Number(duration),
      suggested_dakshina_paise: paise,
      is_active: active,
    };
    const result = await apiWrite<{ id: string; version: number }>(initial ? `/offerings/${initial.id}` : '/offerings', {
      method: initial ? 'PATCH' : 'POST',
      tenantId,
      idempotencyKey: key.current,
      ifMatch: initial ? version : undefined,
      body,
    });
    setBusy(false);
    if (!result.ok) {
      setError(t(`errors.${result.code}` as 'errors.INTERNAL'));
      return;
    }
    key.current = crypto.randomUUID();
    if (initial) {
      setVersion(result.data.version);
      setSaved(t('settings.saved'));
      router.refresh();
    } else {
      router.push(`/settings/offerings/${result.data.id}`);
    }
  }

  const input = 'min-h-11 rounded-lg border border-neutral-300 px-3 text-base';
  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('offerings.nameHi')}</span>
        <input lang="hi" value={nameHi} onChange={(e) => setNameHi(e.target.value)} required maxLength={120} className={input} />
      </label>
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('offerings.nameEn')}</span>
        <input lang="en" value={nameEn} onChange={(e) => setNameEn(e.target.value)} required maxLength={120} className={input} />
      </label>
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('offerings.duration')}</span>
        <input type="number" inputMode="numeric" min={DURATION_MIN} max={DURATION_MAX} step={15} required value={duration}
          onChange={(e) => setDuration(e.target.value)} className={`${input} w-32`} />
      </label>
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('offerings.dakshina')}</span>
        <input inputMode="decimal" value={dakshina} onChange={(e) => setDakshina(e.target.value)}
          placeholder={t('offerings.dakshinaHint')} aria-invalid={dakshinaInvalid}
          className={`${input} w-40 aria-[invalid=true]:border-red-600`} />
        {dakshinaInvalid && <span className="text-base text-red-700">{t('offerings.invalidDakshina')}</span>}
      </label>
      <label className="flex min-h-11 items-center gap-3 text-base">
        <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} className="h-5 w-5 accent-brand" />
        {t('offerings.active')}
      </label>
      <FormStatus error={error} saved={saved} />
      <button type="submit" disabled={busy || dakshinaInvalid || !nameHi.trim() || !nameEn.trim()}
        className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60">
        {busy ? t('settings.saving') : t('settings.save')}
      </button>
    </form>
  );
}
