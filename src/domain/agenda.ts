// Agenda helpers (spec §01 §3 Agenda, ADR-013): local dates in the practice's time zone, Monday-to-Sunday weeks,
// and spans placed on every local day they touch (overnight ceremonies appear on both days).
import { addDays, isValidLocalDate, localDateInZone, zonedDateTimeToUtc } from './time';

/** 0 = Monday … 6 = Sunday. */
function weekdayIndex(localDate: string): number {
  const [y, m, d] = localDate.split('-').map(Number);
  return (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7;
}

/** The Monday of the week containing the date (weeks start on Monday). */
export function weekStart(localDate: string): string {
  if (!isValidLocalDate(localDate)) throw new RangeError('invalid local date');
  return addDays(localDate, -weekdayIndex(localDate));
}

/** The seven dates, Monday to Sunday, of the week containing the date. */
export function weekDays(localDate: string): string[] {
  const monday = weekStart(localDate);
  return Array.from({ length: 7 }, (_, i) => addDays(monday, i));
}

/** [00:00 of the first date, 00:00 after the last date) as instants in the time zone. */
export function localRangeBounds(first: string, last: string, timeZone: string): { from: Date; to: Date } {
  return { from: zonedDateTimeToUtc(first, '00:00', timeZone), to: zonedDateTimeToUtc(addDays(last, 1), '00:00', timeZone) };
}

/** Whole days from a to b ("2027-01-01" → "2027-01-03" = 2). */
export function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);
}

/**
 * Groups spans by each local day they touch among `days`, sorted by start then end within a day.
 * A span [start, end) touches a day when it overlaps that day's [00:00, next 00:00) in the time zone.
 */
export function spansByDay<T extends { starts_at: string; ends_at: string }>(
  items: readonly T[],
  days: readonly string[],
  timeZone: string,
): Map<string, T[]> {
  const out = new Map<string, T[]>(days.map((d) => [d, []]));
  for (const item of items) {
    const start = Date.parse(item.starts_at);
    const end = Date.parse(item.ends_at);
    let day = localDateInZone(new Date(start), timeZone);
    const last = localDateInZone(new Date(end - 1), timeZone);
    for (let guard = 0; guard < 400 && day <= last; guard++, day = addDays(day, 1)) out.get(day)?.push(item);
  }
  for (const list of out.values()) {
    list.sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at) || Date.parse(a.ends_at) - Date.parse(b.ends_at));
  }
  return out;
}
