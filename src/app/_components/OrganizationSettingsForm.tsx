'use client';

import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState, type FormEvent } from 'react';
import { apiWrite } from './api-client';
import { FormStatus } from './FormStatus';

const ZONES = ['Asia/Kolkata', 'Asia/Kathmandu', 'Asia/Dubai', 'Asia/Singapore', 'Europe/London', 'America/New_York', 'UTC'];

export function OrganizationSettingsForm(props: { tenantId: string; name: string; timezone: string; version: number }) {
  const t = useTranslations();
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [name, setName] = useState(props.name);
  const [timezone, setTimezone] = useState(props.timezone);
  const [version, setVersion] = useState(props.version);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    setSaved(null);
    const result = await apiWrite<{ version: number }>('/organization', {
      method: 'PATCH',
      tenantId: props.tenantId,
      idempotencyKey: key.current,
      ifMatch: version,
      body: { name, timezone },
    });
    setBusy(false);
    if (!result.ok) {
      setError(t(`errors.${result.code}` as 'errors.INTERNAL'));
      return;
    }
    key.current = crypto.randomUUID();
    setVersion(result.data.version);
    setSaved(t('settings.saved'));
    router.refresh();
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('settings.practiceName')}</span>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          required
          maxLength={120}
          className="min-h-11 rounded-lg border border-neutral-300 px-3 text-base"
        />
      </label>
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('settings.timezone')}</span>
        <input
          value={timezone}
          onChange={(e) => setTimezone(e.target.value)}
          list="pd-zones"
          required
          maxLength={64}
          placeholder={t('settings.timezoneHint')}
          className="min-h-11 rounded-lg border border-neutral-300 px-3 text-base"
        />
        <datalist id="pd-zones">
          {ZONES.map((z) => (
            <option key={z} value={z} />
          ))}
        </datalist>
      </label>
      <FormStatus error={error} saved={saved} />
      <button
        type="submit"
        disabled={busy || !name.trim()}
        className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60"
      >
        {busy ? t('settings.saving') : t('settings.save')}
      </button>
    </form>
  );
}
