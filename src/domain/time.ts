// Time is an instant (UTC) + an IANA time zone + a local date (spec ADR-013, golden rule 7). "Today" for a person is
// always computed in the practice's time zone, never from the server's clock zone. Uses Intl only (no I/O).

const LOCAL_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const LOCAL_TIME = /^([01]\d|2[0-3]):([0-5]\d)$/;

function parts(instant: Date, timeZone: string): Record<string, number> {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
  const out: Record<string, number> = {};
  for (const p of fmt.formatToParts(instant)) if (p.type !== 'literal') out[p.type] = Number(p.value);
  return out;
}

const pad = (n: number, w = 2) => String(n).padStart(w, '0');

/** True for an IANA zone Intl knows (abbreviations such as "IST" are not IANA names and are refused by the DB). */
export function isKnownTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone });
    return /^(UTC|[A-Z][A-Za-z_]+(\/[A-Za-z0-9_+-]+)+)$/.test(timeZone);
  } catch {
    return false;
  }
}

export function isValidLocalDate(value: string): boolean {
  const m = LOCAL_DATE.exec(value);
  if (!m) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]);
}

export function isValidLocalTime(value: string): boolean {
  return LOCAL_TIME.test(value);
}

/** The calendar date ("YYYY-MM-DD") of an instant in a time zone. */
export function localDateInZone(instant: Date, timeZone: string): string {
  const p = parts(instant, timeZone);
  return `${pad(p.year, 4)}-${pad(p.month)}-${pad(p.day)}`;
}

/** The wall-clock time ("HH:MM", 24 h) of an instant in a time zone. */
export function localTimeInZone(instant: Date, timeZone: string): string {
  const p = parts(instant, timeZone);
  return `${pad(p.hour)}:${pad(p.minute)}`;
}

/** Today's date for a person in the practice's time zone. */
export function todayInZone(timeZone: string, now: Date = new Date()): string {
  return localDateInZone(now, timeZone);
}

/** Offset of the zone from UTC at that instant, in milliseconds (IST: +19800000). */
function zoneOffsetMs(instant: Date, timeZone: string): number {
  const p = parts(instant, timeZone);
  const wall = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return wall - Math.floor(instant.getTime() / 1000) * 1000;
}

/**
 * The instant at which the wall clock in timeZone shows localDate + localTime ("2027-01-10", "10:00" in Asia/Kolkata →
 * 2027-01-10T04:30:00Z). A time that does not exist (DST gap) moves forward by the gap; a time that exists twice
 * (DST overlap) gives one of its two instants.
 */
export function zonedDateTimeToUtc(localDate: string, localTime: string, timeZone: string): Date {
  if (!isValidLocalDate(localDate)) throw new RangeError('invalid local date');
  if (!isValidLocalTime(localTime)) throw new RangeError('invalid local time');
  const [y, mo, d] = localDate.split('-').map(Number);
  const [h, mi] = localTime.split(':').map(Number);
  const wall = Date.UTC(y, mo - 1, d, h, mi);
  const first = wall - zoneOffsetMs(new Date(wall), timeZone);
  const second = wall - zoneOffsetMs(new Date(first), timeZone);
  const shows = (t: number) =>
    localDateInZone(new Date(t), timeZone) === localDate && localTimeInZone(new Date(t), timeZone) === localTime;
  if (shows(first) && shows(second)) return new Date(Math.min(first, second));
  if (shows(first)) return new Date(first);
  if (shows(second)) return new Date(second);
  return new Date(Math.max(first, second));
}

export function addMinutes(instant: Date, minutes: number): Date {
  return new Date(instant.getTime() + minutes * 60_000);
}

/** "2027-01-31" + 1 → "2027-02-01" (calendar arithmetic on local dates, no time zone involved). */
export function addDays(localDate: string, days: number): string {
  if (!isValidLocalDate(localDate)) throw new RangeError('invalid local date');
  const [y, m, d] = localDate.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + days));
  return `${pad(t.getUTCFullYear(), 4)}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`;
}

/** Whole minutes from start to end. */
export function minutesBetween(start: Date, end: Date): number {
  return Math.round((end.getTime() - start.getTime()) / 60_000);
}
