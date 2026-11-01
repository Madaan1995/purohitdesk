'use client';

import type { BookingConflict } from '@/domain/booking';
import { formatLocalDate, localDateInZone, localTimeInZone } from '@/domain/time';
import { useLocale, useTranslations } from 'next-intl';
import type { WriteResult } from './api-client';

type Failure = Extract<WriteResult<unknown>, { ok: false }>;

/** The plain-language message for a failed booking write, plus the busy times of a conflict (never other practices' details). */
export function BookingError({ failure, timeZone }: { failure: Failure | null; timeZone: string }) {
  const t = useTranslations();
  const locale = useLocale() as 'hi' | 'en';
  if (!failure) return null;
  const reasons: Record<string, string> = {
    TIME_REQUIRED: t('bookings.timeRequired'),
    LEAD_REQUIRED: t('bookings.leadRequired'),
    NOT_STARTED: t('bookings.notStarted'),
    USE_RESCHEDULE: t('bookings.scheduleLocked'),
  };
  const message =
    (failure.reason && reasons[failure.reason]) ||
    (failure.code === 'VALIDATION_FAILED' && failure.field === 'reason' ? t('bookings.cancelReasonRequired') : null) ||
    t(`errors.${failure.code}` as 'errors.INTERNAL');
  const conflicts = failure.code === 'BOOKING_CONFLICT' ? ((failure.details?.conflicts as BookingConflict[]) ?? []) : [];
  const span = (c: BookingConflict) => {
    const start = new Date(c.starts_at);
    const end = new Date(c.ends_at);
    return `${formatLocalDate(localDateInZone(start, timeZone), locale)}, ${localTimeInZone(start, timeZone)}–${localTimeInZone(end, timeZone)}`;
  };
  return (
    <div role="alert" className="flex flex-col gap-1 rounded-lg bg-red-50 px-3 py-2 text-base text-red-800">
      <p className="font-semibold">{message}</p>
      {conflicts.length > 0 && (
        <>
          <p>{t('bookings.busyAt')}</p>
          <ul className="list-disc pl-5">
            {conflicts.map((c, i) => (
              <li key={i}>
                {span(c)}
                {!c.same_org && ` (${t('bookings.otherPractice')})`}
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}
