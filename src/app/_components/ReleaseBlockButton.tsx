'use client';

import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState } from 'react';
import { apiWrite } from './api-client';

/** Releases a calendar block after a confirmation (it stays in history as RELEASED). */
export function ReleaseBlockButton({ tenantId, blockId }: { tenantId: string; blockId: string }) {
  const t = useTranslations();
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function release() {
    if (busy || !window.confirm(t('agenda.confirmRelease'))) return;
    setBusy(true);
    setError(null);
    const result = await apiWrite(`/blocks/${blockId}`, { method: 'DELETE', tenantId, idempotencyKey: key.current });
    setBusy(false);
    if (!result.ok) {
      setError(t(`errors.${result.code}` as 'errors.INTERNAL'));
      return;
    }
    router.refresh();
  }

  return (
    <span className="flex flex-col items-end gap-1">
      <button type="button" onClick={release} disabled={busy} className="min-h-11 rounded-lg border border-red-700 px-3 text-base text-red-800">
        {t('agenda.release')}
      </button>
      {error && (
        <span role="alert" className="text-base text-red-800">
          {error}
        </span>
      )}
    </span>
  );
}
