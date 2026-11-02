'use client';

import { normalizeIndianPhone } from '@/domain/phone';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState, type FormEvent } from 'react';

interface Initial {
  id: string;
  display_name: string;
  phone_e164: string | null;
  address: string | null;
  version: number;
}

/** Create (POST, one Idempotency-Key per form) or edit (PATCH with If-Match; a stale version shows a conflict). */
export function CustomerForm({ tenantId, initial }: { tenantId: string; initial?: Initial }) {
  const t = useTranslations();
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [name, setName] = useState(initial?.display_name ?? '');
  const [phone, setPhone] = useState(initial?.phone_e164 ?? '');
  const [address, setAddress] = useState(initial?.address ?? '');
  const [version, setVersion] = useState(initial?.version ?? 1);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const phoneInvalid = phone.trim() !== '' && normalizeIndianPhone(phone) === null;

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy || phoneInvalid) return;
    setBusy(true);
    setError(null);
    setSaved(false);
    try {
      const body = { display_name: name, phone: phone.trim() || null, address: address.trim() || null };
      const res = await fetch(initial ? `/api/v1/customers/${initial.id}` : '/api/v1/customers', {
        method: initial ? 'PATCH' : 'POST',
        headers: {
          'content-type': 'application/json',
          'x-tenant-id': tenantId,
          'idempotency-key': key.current,
          ...(initial ? { 'if-match': `"${version}"` } : {}),
        },
        body: JSON.stringify(body),
      });
      const result = await res.json();
      if (!res.ok) {
        const code: string = result?.error?.code ?? 'INTERNAL';
        const field: string | undefined = result?.error?.details?.field;
        setError(field === 'phone' ? t('customers.invalidPhone') : t(`errors.${code}` as 'errors.INTERNAL'));
        return;
      }
      key.current = crypto.randomUUID();
      if (initial) {
        setVersion(result.customer.version);
        setSaved(true);
        router.refresh();
      } else {
        router.push(`/customers/${result.customer.id}`);
      }
    } catch {
      setError(t('errors.NETWORK'));
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('customers.name')}</span>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          required
          maxLength={120}
          className="min-h-11 rounded-lg border border-neutral-300 px-3 text-base"
        />
      </label>
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('customers.phone')}</span>
        <input
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          inputMode="tel"
          autoComplete="tel"
          maxLength={32}
          placeholder={t('customers.phoneHint')}
          aria-invalid={phoneInvalid}
          className="min-h-11 rounded-lg border border-neutral-300 px-3 text-base aria-[invalid=true]:border-red-600"
        />
        {phoneInvalid && <span className="text-base text-red-700">{t('customers.invalidPhone')}</span>}
      </label>
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('customers.address')}</span>
        <textarea
          value={address}
          onChange={(e) => setAddress(e.target.value)}
          maxLength={500}
          rows={2}
          className="rounded-lg border border-neutral-300 px-3 py-2 text-base"
        />
      </label>
      {error && (
        <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-base text-red-800">
          {error}
        </p>
      )}
      {saved && (
        <p role="status" className="rounded-lg bg-green-50 px-3 py-2 text-base text-green-800">
          {t('customers.saved')}
        </p>
      )}
      <button
        type="submit"
        disabled={busy || !name.trim() || phoneInvalid}
        className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60"
      >
        {busy ? t('customers.saving') : t('customers.save')}
      </button>
    </form>
  );
}
