'use client';

import type { BookingStatus } from '@/domain/booking';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState } from 'react';
import { apiWrite, type WriteResult } from './api-client';
import { BookingError } from './booking-errors';

interface Props {
  tenantId: string;
  timeZone: string;
  bookingId: string;
  version: number;
  status: BookingStatus;
  span: { starts_at: string; ends_at: string } | null;
  can: { confirm: boolean; cancel: boolean; complete: boolean };
}

/** Confirm, cancel (with a reason once confirmed) and complete. Destructive actions ask first. */
export function BookingActions({ tenantId, timeZone, bookingId, version, status, span, can }: Props) {
  const t = useTranslations('bookings');
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<Extract<WriteResult<unknown>, { ok: false }> | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [reason, setReason] = useState('');

  async function run(action: 'confirm' | 'cancel' | 'complete', body: unknown) {
    setBusy(true);
    setFailure(null);
    const result = await apiWrite(`/bookings/${bookingId}/${action}`, {
      method: 'POST',
      tenantId,
      idempotencyKey: key.current,
      body,
      ifMatch: version,
    });
    setBusy(false);
    if (!result.ok) {
      setFailure(result);
      return;
    }
    key.current = crypto.randomUUID();
    setCancelling(false);
    router.refresh();
  }

  const button = 'min-h-11 rounded-lg px-4 text-lg font-semibold disabled:opacity-60';
  const needsReason = status === 'CONFIRMED';

  return (
    <section className="flex flex-col gap-3">
      <BookingError
        failure={failure}
        timeZone={timeZone}
        span={span}
        onAcknowledge={() => void run('confirm', { ack_buffer_overlap: true })}
        onDismiss={() => setFailure(null)}
      />
      {status === 'DRAFT' && can.confirm && (
        <button type="button" disabled={busy} onClick={() => run('confirm', {})} className={`${button} bg-brand text-white`}>
          {busy ? t('saving') : t('confirm')}
        </button>
      )}
      {status === 'CONFIRMED' && can.complete && (
        <button
          type="button"
          disabled={busy}
          onClick={() => window.confirm(t('confirmComplete')) && run('complete', {})}
          className={`${button} border border-green-700 text-green-800`}
        >
          {t('complete')}
        </button>
      )}
      {(status === 'DRAFT' || status === 'CONFIRMED') && can.cancel && !cancelling && (
        <button type="button" disabled={busy} onClick={() => setCancelling(true)} className={`${button} border border-red-700 text-red-800`}>
          {t('cancel')}
        </button>
      )}
      {cancelling && (
        <form
          className="flex flex-col gap-2 rounded-lg border border-red-200 p-3"
          onSubmit={(e) => {
            e.preventDefault();
            if (window.confirm(t('confirmCancel'))) void run('cancel', { reason: reason.trim() || null });
          }}
        >
          <label className="flex flex-col gap-2">
            <span className="text-base font-semibold">{t('cancelReason')}</span>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              required={needsReason}
              minLength={needsReason ? 3 : undefined}
              maxLength={500}
              rows={2}
              className="rounded-lg border border-neutral-300 px-3 py-2 text-base"
            />
          </label>
          <button type="submit" disabled={busy} className={`${button} bg-red-700 text-white`}>
            {busy ? t('saving') : t('cancel')}
          </button>
        </form>
      )}
    </section>
  );
}
