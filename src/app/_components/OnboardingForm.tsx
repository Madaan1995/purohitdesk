'use client';

import { useLocale, useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useState, type FormEvent } from 'react';

interface Ceremony {
  id: string;
  name_en: string;
  name_hi: string;
  default_duration_min: number;
}

export function OnboardingForm({ ceremonies }: { ceremonies: Ceremony[] }) {
  const t = useTranslations();
  const locale = useLocale();
  const router = useRouter();
  // One key per form: a double tap or a retry after a network drop creates one practice (spec AC-01).
  const [idempotencyKey] = useState(() => crypto.randomUUID());
  const [name, setName] = useState('');
  const [selected, setSelected] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function toggle(id: string) {
    setSelected((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]));
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/v1/onboarding/practice', {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'idempotency-key': idempotencyKey },
        body: JSON.stringify({ name, ceremony_type_ids: selected }),
      });
      const body = await res.json();
      if (!res.ok) {
        const code: string = body?.error?.code ?? 'INTERNAL';
        setError(code === 'QUOTA_EXCEEDED' ? t('onboarding.quota') : t(`errors.${code}` as 'errors.INTERNAL'));
        return;
      }
      document.cookie = `pd_tenant=${body.organization.id}; path=/; max-age=31536000; samesite=lax`;
      router.replace('/');
      router.refresh();
    } catch {
      setError(t('errors.NETWORK'));
    } finally {
      setBusy(false);
    }
  }

  const valid = name.trim().length > 0 && name.trim().length <= 120 && selected.length > 0;

  return (
    <form onSubmit={submit} className="flex flex-col gap-6">
      <label className="flex flex-col gap-2">
        <span className="text-lg font-semibold">{t('onboarding.practiceName')}</span>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          maxLength={120}
          required
          placeholder={t('onboarding.practiceNameHint')}
          className="min-h-11 rounded-lg border border-neutral-300 px-3 text-base"
        />
      </label>

      <fieldset className="flex flex-col gap-2">
        <legend className="text-lg font-semibold">{t('onboarding.ceremonies')}</legend>
        <p className="text-base text-neutral-600">{t('onboarding.ceremoniesHint')}</p>
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
          {ceremonies.map((c) => {
            const primary = locale === 'hi' ? c.name_hi : c.name_en;
            const secondary = locale === 'hi' ? c.name_en : c.name_hi;
            return (
              <label
                key={c.id}
                className="flex min-h-11 items-center gap-3 rounded-lg border border-neutral-300 px-3 py-2 has-[:checked]:border-brand"
              >
                <input
                  type="checkbox"
                  checked={selected.includes(c.id)}
                  onChange={() => toggle(c.id)}
                  className="h-5 w-5 accent-brand"
                />
                <span className="flex flex-col">
                  <span className="text-base">{primary}</span>
                  <span className="text-base text-neutral-600">
                    {secondary} · {t('onboarding.minutes', { count: c.default_duration_min })}
                  </span>
                </span>
              </label>
            );
          })}
        </div>
      </fieldset>

      {error && (
        <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-base text-red-800">
          {error}
        </p>
      )}

      <button
        type="submit"
        disabled={!valid || busy}
        className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60"
      >
        {busy ? t('onboarding.saving') : t('onboarding.submit')}
      </button>
    </form>
  );
}
