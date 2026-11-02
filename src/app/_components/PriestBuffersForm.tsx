'use client';

import { BUFFER_MAX } from '@/domain/catalog';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState, type FormEvent } from 'react';
import { apiWrite } from './api-client';
import { FormStatus } from './FormStatus';

export function PriestBuffersForm(props: {
  tenantId: string;
  linkId: string;
  displayName: string;
  before: number;
  after: number;
}) {
  const t = useTranslations();
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [before, setBefore] = useState(String(props.before));
  const [after, setAfter] = useState(String(props.after));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    setSaved(null);
    const result = await apiWrite(`/priests/${props.linkId}`, {
      method: 'PATCH',
      tenantId: props.tenantId,
      idempotencyKey: key.current,
      body: { default_buffer_before_min: Number(before), default_buffer_after_min: Number(after) },
    });
    setBusy(false);
    if (!result.ok) {
      setError(t(`errors.${result.code}` as 'errors.INTERNAL'));
      return;
    }
    key.current = crypto.randomUUID();
    setSaved(t('settings.saved'));
    router.refresh();
  }

  const input = 'min-h-11 w-24 rounded-lg border border-neutral-300 px-3 text-base';
  return (
    <form onSubmit={submit} className="flex flex-col gap-3">
      <p className="text-base font-semibold">{props.displayName}</p>
      <div className="flex flex-wrap gap-4">
        <label className="flex flex-col gap-1 text-base">
          <span>{t('settings.before')}</span>
          <input type="number" inputMode="numeric" min={0} max={BUFFER_MAX} step={5} required value={before}
            onChange={(e) => setBefore(e.target.value)} className={input} />
        </label>
        <label className="flex flex-col gap-1 text-base">
          <span>{t('settings.after')}</span>
          <input type="number" inputMode="numeric" min={0} max={BUFFER_MAX} step={5} required value={after}
            onChange={(e) => setAfter(e.target.value)} className={input} />
        </label>
      </div>
      <FormStatus error={error} saved={saved} />
      <button type="submit" disabled={busy}
        className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60">
        {busy ? t('settings.saving') : t('settings.save')}
      </button>
    </form>
  );
}
