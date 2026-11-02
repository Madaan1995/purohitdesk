import { formatLocalDate, localTimeInZone } from '@/domain/time';

/** "10:00–12:00" in the booking's time zone, "≈ 09:00–13:00" for a tentative window, or "time not fixed". */
export function timeRange(
  b: { starts_at: string | null; ends_at: string | null; timezone: string; is_time_tentative: boolean },
  labels: { notFixed: string },
): string {
  if (!b.starts_at || !b.ends_at) return labels.notFixed;
  const range = `${localTimeInZone(new Date(b.starts_at), b.timezone)}–${localTimeInZone(new Date(b.ends_at), b.timezone)}`;
  return b.is_time_tentative ? `≈ ${range}` : range;
}

export function dateLabel(localDate: string, locale: string): string {
  return formatLocalDate(localDate, locale === 'hi' ? 'hi' : 'en');
}
