'use client';

import { RESCHEDULE_REASON_CODES, type Booking, type RescheduleReasonCode } from '@/domain/booking';
import { addMinutes, isValidLocalTime, localDateInZone, localTimeInZone, minutesBetween, zonedDateTimeToUtc } from '@/domain/time';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState, type FormEvent } from 'react';
import { apiWrite, type WriteResult } from './api-client';
import { BookingError } from './booking-errors';

const input = 'min-h-11 rounded-lg border border-neutral-300 px-3 text-base';
const MAX_MINUTES = 7 * 24 * 60;

/** Moves a CONFIRMED booking: new date/time/duration/window and priest, with a reason code (no free text). */
export function RescheduleForm({
  tenantId,
  booking,
  priests,
}: {
  tenantId: string;
  booking: Booking & { starts_at: string; ends_at: string };
  priests: { id: string; display_name: string }[];
}) {
  const t = useTranslations('bookings');
  const tr = useTranslations('rescheduleReason');
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const tz = booking.timezone;
  const [date, setDate] = useState(localDateInZone(new Date(booking.starts_at), tz));
  const [time, setTime] = useState(localTimeInZone(new Date(booking.starts_at), tz));
  const [duration, setDuration] = useState(String(minutesBetween(new Date(booking.starts_at), new Date(booking.ends_at))));
  const [tentative, setTentative] = useState(booking.is_time_tentative);
  const [priestId, setPriestId] = useState(booking.priests[0]?.organization_priest_id ?? '');
  const [reason, setReason] = useState<RescheduleReasonCode | ''>('');
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<Extract<WriteResult<unknown>, { ok: false }> | null>(null);

  const minutes = Number(duration);
  const invalid = !isValidLocalTime(time) || !Number.isInteger(minutes) || minutes < 15 || minutes > MAX_MINUTES;
  const span = () => {
    const start = zonedDateTimeToUtc(date, time, tz);
    return { starts_at: start.toISOString(), ends_at: addMinutes(start, minutes).toISOString() };
  };

  async function send(ack: boolean) {
    if (busy || invalid || !reason) return;
    setBusy(true);
    setFailure(null);
    const priestChanged = priestId && priestId !== booking.priests[0]?.organization_priest_id;
    const result = await apiWrite(`/bookings/${booking.id}/reschedule`, {
      method: 'POST',
      tenantId,
      idempotencyKey: key.current,
      ifMatch: booking.version,
      body: {
        ...span(),
        is_time_tentative: tentative,
        ...(priestChanged ? { priest_ids: [priestId] } : {}),
        reason_code: reason,
        ...(ack ? { ack_buffer_overlap: true } : {}),
      },
    });
    setBusy(false);
    if (!result.ok) {
      setFailure(result);
      return;
    }
    key.current = crypto.randomUUID();
    router.push(`/bookings/${booking.id}`);
    router.refresh();
  }

  return (
    <form
      onSubmit={(e: FormEvent) => {
        e.preventDefault();
        void send(false);
      }}
      className="flex flex-col gap-4"
    >
      <p className="text-base text-neutral-600">{t('rescheduleHint')}</p>
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('date')}</span>
        <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required className={input} />
      </label>
      <div className="flex flex-wrap gap-3">
        <label className="flex min-w-36 flex-1 flex-col gap-2">
          <span className="text-base font-semibold">{t('startTime')}</span>
          <input type="time" value={time} onChange={(e) => setTime(e.target.value)} required className={input} />
        </label>
        <label className="flex min-w-36 flex-1 flex-col gap-2">
          <span className="text-base font-semibold">{t('duration')}</span>
          <input inputMode="numeric" value={duration} onChange={(e) => setDuration(e.target.value.replace(/\D/g, ''))} className={input} />
        </label>
      </div>
      {invalid && <p className="text-base text-red-700">{t('invalidTime')}</p>}
      <label className="flex min-h-11 items-center gap-3">
        <input type="checkbox" checked={tentative} onChange={(e) => setTentative(e.target.checked)} className="h-6 w-6" />
        <span className="text-base">{t('tentative')}</span>
      </label>
      {priests.length > 1 && (
        <label className="flex flex-col gap-2">
          <span className="text-base font-semibold">{t('priest')}</span>
          <select value={priestId} onChange={(e) => setPriestId(e.target.value)} className={input}>
            {priests.map((p) => (
              <option key={p.id} value={p.id}>
                {p.display_name}
              </option>
            ))}
          </select>
        </label>
      )}
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('reasonCode')}</span>
        <select value={reason} onChange={(e) => setReason(e.target.value as RescheduleReasonCode)} required className={input}>
          <option value="" disabled>
            —
          </option>
          {RESCHEDULE_REASON_CODES.map((code) => (
            <option key={code} value={code}>
              {tr(code)}
            </option>
          ))}
        </select>
      </label>
      <BookingError
        failure={failure}
        timeZone={tz}
        span={invalid ? null : span()}
        onAcknowledge={() => void send(true)}
        onDismiss={() => setFailure(null)}
      />
      <button
        type="submit"
        disabled={busy || invalid || !reason}
        className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60"
      >
        {busy ? t('saving') : t('reschedule')}
      </button>
    </form>
  );
}
