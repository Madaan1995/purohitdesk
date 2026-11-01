'use client';

import { addDays, isValidLocalTime, zonedDateTimeToUtc } from '@/domain/time';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useRef, useState, type FormEvent } from 'react';
import { apiWrite, type WriteResult } from './api-client';
import { BookingError } from './booking-errors';

const input = 'min-h-11 rounded-lg border border-neutral-300 px-3 text-base';

/** Blocks a priest's time (spec §05 §8): a date, from–to (or the whole day), an optional note. */
export function BlockForm({
  tenantId,
  timeZone,
  date: initialDate,
  priests,
}: {
  tenantId: string;
  timeZone: string;
  date: string;
  priests: { id: string; display_name: string }[];
}) {
  const t = useTranslations('agenda');
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(initialDate);
  const [from, setFrom] = useState('14:00');
  const [to, setTo] = useState('16:00');
  const [allDay, setAllDay] = useState(false);
  const [note, setNote] = useState('');
  const [priestId, setPriestId] = useState(priests[0]?.id ?? '');
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<Extract<WriteResult<unknown>, { ok: false }> | null>(null);

  const invalid = !allDay && (!isValidLocalTime(from) || !isValidLocalTime(to) || to <= from);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy || invalid) return;
    setBusy(true);
    setFailure(null);
    const start = zonedDateTimeToUtc(date, allDay ? '00:00' : from, timeZone);
    const end = allDay ? zonedDateTimeToUtc(addDays(date, 1), '00:00', timeZone) : zonedDateTimeToUtc(date, to, timeZone);
    const result = await apiWrite('/blocks', {
      method: 'POST',
      tenantId,
      idempotencyKey: key.current,
      body: { priest_id: priestId, starts_at: start.toISOString(), ends_at: end.toISOString(), note: note.trim() || null },
    });
    setBusy(false);
    if (!result.ok) {
      setFailure(result);
      return;
    }
    key.current = crypto.randomUUID();
    setOpen(false);
    setNote('');
    router.refresh();
  }

  if (!open) {
    return (
      <button type="button" onClick={() => setOpen(true)} className="min-h-11 rounded-lg border border-brand px-4 text-lg text-brand">
        {t('addBlock')}
      </button>
    );
  }
  return (
    <form onSubmit={submit} className="flex flex-col gap-3 rounded-lg border border-neutral-200 p-3">
      <label className="flex flex-col gap-2">
        <span className="text-base font-semibold">{t('blockDate')}</span>
        <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required className={input} />
      </label>
      <label className="flex min-h-11 items-center gap-3">
        <input type="checkbox" checked={allDay} onChange={(e) => setAllDay(e.target.checked)} className="h-6 w-6" />
        <span className="text-base">{t('allDay')}</span>
      </label>
      {!allDay && (
        <div className="flex flex-wrap gap-3">
          <label className="flex min-w-32 flex-1 flex-col gap-2">
            <span className="text-base font-semibold">{t('blockFrom')}</span>
            <input type="time" value={from} onChange={(e) => setFrom(e.target.value)} required className={input} />
          </label>
          <label className="flex min-w-32 flex-1 flex-col gap-2">
            <span className="text-base font-semibold">{t('blockTo')}</span>
            <input type="time" value={to} onChange={(e) => setTo(e.target.value)} required className={input} />
          </label>
        </div>
      )}
      {invalid && <p className="text-base text-red-700">{t('invalidRange')}</p>}
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
        <span className="text-base font-semibold">{t('blockNote')}</span>
        <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} className={input} />
      </label>
      <BookingError failure={failure} timeZone={timeZone} />
      <button type="submit" disabled={busy || invalid} className="min-h-11 rounded-lg bg-brand px-4 text-lg font-semibold text-white disabled:opacity-60">
        {busy ? t('blockSaving') : t('blockSave')}
      </button>
    </form>
  );
}
