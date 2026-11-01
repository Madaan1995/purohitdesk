'use client';

import type { Booking } from '@/domain/booking';
import { paiseToRupeeInput, parseRupees } from '@/domain/money';
import {
  addMinutes,
  isValidLocalTime,
  localTimeInZone,
  minutesBetween,
  zonedDateTimeToUtc,
} from '@/domain/time';
import { useLocale, useTranslations } from 'next-intl';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useRef, useState, type FormEvent } from 'react';
import { apiWrite, type WriteResult } from './api-client';
import { BookingError } from './booking-errors';

export interface FormOffering {
  id: string;
  name_hi: string;
  name_en: string;
  duration_min: number;
  suggested_dakshina_paise: number | null;
}

interface Props {
  tenantId: string;
  timeZone: string;
  today: string;
  offerings: FormOffering[];
  priests: { id: string; display_name: string }[];
  canConfirm: boolean;
  initialCustomer?: { id: string; display_name: string };
  booking?: Booking;
}

const input = 'min-h-11 rounded-lg border border-neutral-300 px-3 text-base disabled:bg-neutral-100';
const MAX_MINUTES = 7 * 24 * 60;

/**
 * New booking (POST, optionally confirming at once) or edit (PATCH with If-Match). Times are typed as the practice's
 * local date and wall-clock time and converted to instants in its time zone (src/domain/time.ts). Once a booking is
 * confirmed its schedule fields are read-only here; a closed booking keeps only its notes editable.
 */
export function BookingForm({ tenantId, timeZone, today, offerings, priests, canConfirm, initialCustomer, booking }: Props) {
  const t = useTranslations('bookings');
  const locale = useLocale();
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const status = booking?.status ?? 'DRAFT';
  const scheduleLocked = status !== 'DRAFT';
  const detailsLocked = status === 'COMPLETED' || status === 'CANCELLED';

  const firstOffering = offerings.find((o) => o.id === booking?.offering.id) ?? offerings[0];
  const [customer, setCustomer] = useState(booking?.customer ?? initialCustomer ?? null);
  const [q, setQ] = useState('');
  const [matches, setMatches] = useState<{ id: string; display_name: string }[] | null>(null);
  const [offeringId, setOfferingId] = useState(firstOffering?.id ?? '');
  const [date, setDate] = useState(booking?.local_date ?? today);
  const [time, setTime] = useState(booking?.starts_at ? localTimeInZone(new Date(booking.starts_at), timeZone) : '');
  const [duration, setDuration] = useState(
    String(
      booking?.starts_at && booking.ends_at
        ? minutesBetween(new Date(booking.starts_at), new Date(booking.ends_at))
        : (firstOffering?.duration_min ?? 60),
    ),
  );
  const [tentative, setTentative] = useState(booking?.is_time_tentative ?? false);
  const [place, setPlace] = useState(booking?.location ?? '');
  const [title, setTitle] = useState(booking?.title ?? '');
  const [notes, setNotes] = useState(booking?.notes ?? '');
  const [dakshina, setDakshina] = useState(
    booking
      ? booking.agreed_dakshina_paise === null ? '' : paiseToRupeeInput(booking.agreed_dakshina_paise)
      : firstOffering?.suggested_dakshina_paise != null ? paiseToRupeeInput(firstOffering.suggested_dakshina_paise) : '',
  );
  const [priestId, setPriestId] = useState(booking?.priests[0]?.organization_priest_id ?? priests[0]?.id ?? '');
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<Extract<WriteResult<unknown>, { ok: false }> | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const dakshinaInvalid = dakshina.trim() !== '' && parseRupees(dakshina) === null;
  const minutes = Number(duration);
  const timeInvalid =
    time !== '' && (!isValidLocalTime(time) || !Number.isInteger(minutes) || minutes < 15 || minutes > MAX_MINUTES);

  function chooseOffering(id: string) {
    setOfferingId(id);
    const o = offerings.find((x) => x.id === id);
    if (!o) return;
    setDuration(String(o.duration_min));
    if (dakshina.trim() === '' && o.suggested_dakshina_paise != null) setDakshina(paiseToRupeeInput(o.suggested_dakshina_paise));
  }

  async function search() {
    setMatches(null);
    try {
      const res = await fetch(`/api/v1/customers?${new URLSearchParams({ q: q.trim(), limit: '10' })}`, {
        headers: { 'x-tenant-id': tenantId },
      });
      const json = await res.json();
      setMatches(res.ok ? json.data.map((c: { id: string; display_name: string }) => ({ id: c.id, display_name: c.display_name })) : []);
    } catch {
      setMatches([]);
    }
  }

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const confirmNow = (e.nativeEvent as SubmitEvent).submitter?.getAttribute('value') === 'confirm';
    if (busy || dakshinaInvalid || timeInvalid) return;
    if (!customer) {
      setLocalError(t('noCustomer'));
      return;
    }
    setBusy(true);
    setFailure(null);
    setLocalError(null);
    setSaved(false);

    const start = time ? zonedDateTimeToUtc(date, time, timeZone) : null;
    const schedule = {
      local_date: date,
      starts_at: start ? start.toISOString() : null,
      ends_at: start ? addMinutes(start, minutes).toISOString() : null,
      is_time_tentative: start ? tentative : false,
      priest_ids: priestId ? [priestId] : [],
    };
    const details = {
      customer_id: customer.id,
      offering_id: offeringId,
      title: title.trim() || null,
      location: place.trim() || null,
      notes: notes.trim() || null,
      agreed_dakshina_paise: dakshina.trim() ? parseRupees(dakshina) : null,
    };
    const body = detailsLocked
      ? { notes: details.notes }
      : scheduleLocked
        ? details
        : { ...details, ...schedule, ...(booking ? {} : { confirm: confirmNow }) };

    const result = await apiWrite<{ booking: Booking }>(booking ? `/bookings/${booking.id}` : '/bookings', {
      method: booking ? 'PATCH' : 'POST',
      tenantId,
      idempotencyKey: key.current,
      body,
      ...(booking ? { ifMatch: booking.version } : {}),
    });
    setBusy(false);
    if (!result.ok) {
      setFailure(result);
      return;
    }
    key.current = crypto.randomUUID();
    if (booking) {
      setSaved(true);
      router.push(`/bookings/${booking.id}`);
      router.refresh();
    } else {
      router.push(`/bookings/${result.data.booking.id}`);
    }
  }

  const name = (o: FormOffering) => (locale === 'hi' ? o.name_hi : o.name_en);

  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <fieldset className="flex flex-col gap-2" disabled={detailsLocked}>
        <legend className="text-base font-semibold">{t('customer')}</legend>
        {customer ? (
          <div className="flex items-center justify-between gap-2 rounded-lg border border-neutral-200 px-3 py-2">
            <span className="text-base">{customer.display_name}</span>
            {!detailsLocked && (
              <button type="button" onClick={() => setCustomer(null)} className="min-h-11 px-2 text-base text-brand underline">
                {t('change')}
              </button>
            )}
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            <div className="flex gap-2">
              <input
                value={q}
                onChange={(e) => setQ(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault();
                    void search();
                  }
                }}
                aria-label={t('searchCustomer')}
                placeholder={t('searchCustomer')}
                maxLength={60}
                className={`${input} min-w-0 flex-1`}
              />
              <button type="button" onClick={search} className="min-h-11 rounded-lg border border-brand px-4 text-base text-brand">
                {t('search')}
              </button>
            </div>
            {matches && matches.length === 0 && <p className="text-base text-neutral-600">{t('noMatches')}</p>}
            {matches && matches.length > 0 && (
              <ul className="flex flex-col gap-1">
                {matches.map((m) => (
                  <li key={m.id}>
                    <button
                      type="button"
                      onClick={() => setCustomer(m)}
                      className="min-h-11 w-full rounded-lg border border-neutral-200 px-3 text-left text-base"
                    >
                      {m.display_name}
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <Link href="/customers/new" className="text-base text-brand underline">
              {t('addCustomer')}
            </Link>
          </div>
        )}
      </fieldset>

      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('ceremony')}</span>
        <select value={offeringId} onChange={(e) => chooseOffering(e.target.value)} disabled={detailsLocked} className={input}>
          {offerings.map((o) => (
            <option key={o.id} value={o.id}>
              {name(o)} — {t('minutes', { count: o.duration_min })}
            </option>
          ))}
        </select>
      </label>

      <fieldset className="flex flex-col gap-3" disabled={scheduleLocked}>
        {scheduleLocked && <p className="text-base text-neutral-600">{detailsLocked ? t('terminalLocked') : t('scheduleLocked')}</p>}
        <label className="flex flex-col gap-2">
          <span className="text-base font-semibold">{t('date')}</span>
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required className={input} />
        </label>
        <div className="flex flex-wrap gap-3">
          <label className="flex min-w-36 flex-1 flex-col gap-2">
            <span className="text-base font-semibold">{t('startTime')}</span>
            <input type="time" value={time} onChange={(e) => setTime(e.target.value)} className={input} />
          </label>
          {time && (
            <label className="flex min-w-36 flex-1 flex-col gap-2">
              <span className="text-base font-semibold">{t('duration')}</span>
              <input
                inputMode="numeric"
                value={duration}
                onChange={(e) => setDuration(e.target.value.replace(/\D/g, ''))}
                aria-invalid={timeInvalid}
                className={`${input} aria-[invalid=true]:border-red-600`}
              />
            </label>
          )}
        </div>
        {timeInvalid && <p className="text-base text-red-700">{t('invalidTime')}</p>}
        {time && (
          <label className="flex min-h-11 items-center gap-3">
            <input type="checkbox" checked={tentative} onChange={(e) => setTentative(e.target.checked)} className="h-6 w-6" />
            <span className="text-base">{t('tentative')}</span>
          </label>
        )}
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
      </fieldset>

      <fieldset className="flex flex-col gap-3" disabled={detailsLocked}>
        <label className="flex flex-col gap-2">
          <span className="text-base font-semibold">{t('place')}</span>
          <input value={place} onChange={(e) => setPlace(e.target.value)} maxLength={500} className={input} />
        </label>
        <label className="flex flex-col gap-2">
          <span className="text-base font-semibold">{t('dakshina')}</span>
          <input
            value={dakshina}
            onChange={(e) => setDakshina(e.target.value)}
            inputMode="decimal"
            aria-invalid={dakshinaInvalid}
            className={`${input} aria-[invalid=true]:border-red-600`}
          />
          {dakshinaInvalid && <span className="text-base text-red-700">{t('invalidDakshina')}</span>}
        </label>
        <label className="flex flex-col gap-2">
          <span className="text-base font-semibold">{t('titleField')}</span>
          <input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={120} className={input} />
        </label>
      </fieldset>
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('notes')}</span>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          maxLength={2000}
          rows={3}
          className="rounded-lg border border-neutral-300 px-3 py-2 text-base"
        />
      </label>

      {localError && (
        <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-base text-red-800">
          {localError}
        </p>
      )}
      <BookingError failure={failure} timeZone={timeZone} />
      {saved && (
        <p role="status" className="rounded-lg bg-green-50 px-3 py-2 text-base text-green-800">
          {t('saved')}
        </p>
      )}

      <div className="flex flex-col gap-2">
        <button
          type="submit"
          value="draft"
          disabled={busy || dakshinaInvalid || timeInvalid || !offeringId}
          className="min-h-11 rounded-lg border border-brand px-4 text-lg font-semibold text-brand disabled:opacity-60"
        >
          {busy ? t('saving') : booking ? t('save') : t('saveDraft')}
        </button>
        {!booking && canConfirm && (
          <button
            type="submit"
            value="confirm"
            disabled={busy || dakshinaInvalid || timeInvalid || !offeringId}
            className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60"
          >
            {busy ? t('saving') : t('saveConfirm')}
          </button>
        )}
      </div>
    </form>
  );
}
