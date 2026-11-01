import { describe, expect, it } from 'vitest';
import {
  addDays,
  addMinutes,
  isKnownTimeZone,
  isValidLocalDate,
  isValidLocalTime,
  localDateInZone,
  localTimeInZone,
  minutesBetween,
  todayInZone,
  zonedDateTimeToUtc,
} from './time';

describe('local dates in the practice time zone', () => {
  it('20:00 UTC is already the next day in IST', () => {
    const t = new Date('2027-01-10T20:00:00Z');
    expect(localDateInZone(t, 'Asia/Kolkata')).toBe('2027-01-11');
    expect(localTimeInZone(t, 'Asia/Kolkata')).toBe('01:30');
    expect(localDateInZone(t, 'UTC')).toBe('2027-01-10');
  });

  it('"today" comes from the org time zone, not the server clock zone', () => {
    const now = new Date('2026-11-01T19:00:00Z'); // 00:30 IST on 2 Nov
    expect(todayInZone('Asia/Kolkata', now)).toBe('2026-11-02');
    expect(todayInZone('America/New_York', now)).toBe('2026-11-01');
  });
});

describe('zonedDateTimeToUtc', () => {
  it('converts IST wall-clock times to instants', () => {
    expect(zonedDateTimeToUtc('2027-01-10', '10:00', 'Asia/Kolkata').toISOString()).toBe('2027-01-10T04:30:00.000Z');
    expect(zonedDateTimeToUtc('2027-01-11', '01:30', 'Asia/Kolkata').toISOString()).toBe('2027-01-10T20:00:00.000Z');
    expect(zonedDateTimeToUtc('2027-01-10', '00:00', 'Asia/Kolkata').toISOString()).toBe('2027-01-09T18:30:00.000Z');
  });

  it('handles daylight saving time (summer and winter offsets, a gap)', () => {
    expect(zonedDateTimeToUtc('2027-07-01', '09:00', 'America/New_York').toISOString()).toBe('2027-07-01T13:00:00.000Z');
    expect(zonedDateTimeToUtc('2027-01-01', '09:00', 'America/New_York').toISOString()).toBe('2027-01-01T14:00:00.000Z');
    // 02:30 does not exist on 14 Mar 2027 in New York: it moves forward to 03:30 EDT.
    expect(zonedDateTimeToUtc('2027-03-14', '02:30', 'America/New_York').toISOString()).toBe('2027-03-14T07:30:00.000Z');
  });

  it('round-trips with localDateInZone/localTimeInZone', () => {
    const t = zonedDateTimeToUtc('2027-12-31', '23:45', 'Asia/Kolkata');
    expect([localDateInZone(t, 'Asia/Kolkata'), localTimeInZone(t, 'Asia/Kolkata')]).toEqual(['2027-12-31', '23:45']);
  });

  it('rejects malformed input', () => {
    expect(() => zonedDateTimeToUtc('2027-02-30', '10:00', 'Asia/Kolkata')).toThrow(RangeError);
    expect(() => zonedDateTimeToUtc('2027-02-01', '24:00', 'Asia/Kolkata')).toThrow(RangeError);
  });
});

describe('validation and arithmetic', () => {
  it('validates local dates and times', () => {
    expect(isValidLocalDate('2028-02-29')).toBe(true);
    expect(isValidLocalDate('2027-02-29')).toBe(false);
    expect(isValidLocalDate('2027-1-5')).toBe(false);
    expect(isValidLocalTime('09:05')).toBe(true);
    expect(isValidLocalTime('9:05')).toBe(false);
  });

  it('accepts IANA names only', () => {
    expect(isKnownTimeZone('Asia/Kolkata')).toBe(true);
    expect(isKnownTimeZone('UTC')).toBe(true);
    expect(isKnownTimeZone('IST')).toBe(false);
    expect(isKnownTimeZone('Mars/Olympus')).toBe(false);
  });

  it('adds days across months and years, and minutes', () => {
    expect(addDays('2027-01-31', 1)).toBe('2027-02-01');
    expect(addDays('2027-12-31', 1)).toBe('2028-01-01');
    expect(addDays('2027-03-01', -1)).toBe('2027-02-28');
    const t = new Date('2027-01-10T04:30:00Z');
    expect(addMinutes(t, 150).toISOString()).toBe('2027-01-10T07:00:00.000Z');
    expect(minutesBetween(t, addMinutes(t, 480))).toBe(480);
  });
});
