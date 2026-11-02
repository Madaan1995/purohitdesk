'use client';

import { isBlockedTimeConflict, travelGapMinutes, type BookingConflict } from '@/domain/booking';
import { formatLocalDate, localDateInZone, localTimeInZone } from '@/domain/time';
import { useLocale, useTranslations } from 'next-intl';
import type { WriteResult } from './api-client';

type Failure = Extract<WriteResult<unknown>, { ok: false }>;

interface Props {
  failure: Failure | null;
  timeZone: string;
  /** The ceremony being saved, for "only N minutes to travel". */
  span?: { starts_at: string; ends_at: string } | null;
  /** Shown for BUFFER_CONFLICT: resend with ack_buffer_overlap = true. */
  onAcknowledge?: () => void;
  onDismiss?: () => void;
}

/**
 * The plain-language message for a failed booking write and the busy times of a conflict (never other practices'
 * details). A travel-time overlap asks whether to continue (spec §05 §6).
 */
export function BookingError({ failure, timeZone, span, onAcknowledge, onDismiss }: Props) {
  const t = useTranslations();
  const locale = useLocale() as 'hi' | 'en';
  if (!failure) return null;
  const conflicts =
    failure.code === 'BOOKING_CONFLICT' || failure.code === 'BUFFER_CONFLICT'
      ? ((failure.details?.conflicts as BookingConflict[]) ?? [])
      : [];
  const reasons: Record<string, string> = {
    TIME_REQUIRED: t('bookings.timeRequired'),
    LEAD_REQUIRED: t('bookings.leadRequired'),
    NOT_STARTED: t('bookings.notStarted'),
    USE_RESCHEDULE: t('bookings.scheduleLocked'),
  };
  let message =
    (failure.reason && reasons[failure.reason]) ||
    (failure.code === 'VALIDATION_FAILED' && failure.field === 'reason' ? t('bookings.cancelReasonRequired') : null) ||
    t(`errors.${failure.code}` as 'errors.INTERNAL');
  if (failure.code === 'BOOKING_CONFLICT' && isBlockedTimeConflict(conflicts)) {
    message = t('bookings.blockedTime');
  }
  const asking = failure.code === 'BUFFER_CONFLICT' && onAcknowledge;
  if (asking) {
    const gap = span ? travelGapMinutes(conflicts, span.starts_at, span.ends_at) : null;
    message = gap !== null && gap > 0 ? t('bookings.bufferQuestion', { minutes: gap }) : t('bookings.bufferOverlap');
  }
  const when = (c: BookingConflict) => {
    const start = new Date(c.starts_at);
    const end = new Date(c.ends_at);
    return `${formatLocalDate(localDateInZone(start, timeZone), locale)}, ${localTimeInZone(start, timeZone)}–${localTimeInZone(end, timeZone)}`;
  };
  return (
    <div
      role="alert"
      className={`flex flex-col gap-2 rounded-lg px-3 py-2 text-base ${asking ? 'bg-amber-50 text-amber-900' : 'bg-red-50 text-red-800'}`}
    >
      <p className="font-semibold">{message}</p>
      {conflicts.length > 0 && (
        <>
          <p>{t('bookings.busyAt')}</p>
          <ul className="list-disc pl-5">
            {conflicts.map((c, i) => (
              <li key={i}>
                {when(c)}
                {!c.same_org && ` (${t('bookings.otherPractice')})`}
                {c.block && ` (${t('bookings.blockLabel')})`}
              </li>
            ))}
          </ul>
        </>
      )}
      {asking && (
        <div className="flex flex-col gap-2">
          <button type="button" onClick={onAcknowledge} className="min-h-11 rounded-lg bg-amber-700 px-4 text-lg font-semibold text-white">
            {t('bookings.bufferContinue')}
          </button>
          {onDismiss && (
            <button type="button" onClick={onDismiss} className="min-h-11 rounded-lg border border-amber-700 px-4 text-lg">
              {t('bookings.bufferBack')}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
