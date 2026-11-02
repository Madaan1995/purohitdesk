import { describe, expect, it } from 'vitest';
import { daysBetween, localRangeBounds, spansByDay, weekDays, weekStart } from './agenda';

describe('weeks start on Monday', () => {
  it('finds the Monday and the seven days', () => {
    expect(weekStart('2027-01-10')).toBe('2027-01-04'); // a Sunday → its Monday
    expect(weekStart('2027-01-04')).toBe('2027-01-04');
    expect(weekDays('2026-12-31')).toEqual(['2026-12-28', '2026-12-29', '2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02', '2027-01-03']);
  });
});

describe('localRangeBounds', () => {
  it('gives IST midnights as instants', () => {
    const { from, to } = localRangeBounds('2027-01-10', '2027-01-16', 'Asia/Kolkata');
    expect(from.toISOString()).toBe('2027-01-09T18:30:00.000Z');
    expect(to.toISOString()).toBe('2027-01-16T18:30:00.000Z');
    expect(daysBetween('2027-01-10', '2027-03-12')).toBe(61);
  });
});

describe('spansByDay', () => {
  const tz = 'Asia/Kolkata';
  it('puts an overnight ceremony on both days and sorts each day', () => {
    const jagran = { id: 'j', starts_at: '2027-01-10T16:30:00Z', ends_at: '2027-01-11T00:30:00Z' }; // 22:00–06:00 IST
    const morning = { id: 'm', starts_at: '2027-01-11T04:30:00Z', ends_at: '2027-01-11T05:30:00Z' };
    const early = { id: 'e', starts_at: '2027-01-10T01:30:00Z', ends_at: '2027-01-10T02:00:00Z' };
    const byDay = spansByDay([jagran, morning, early], ['2027-01-10', '2027-01-11', '2027-01-12'], tz);
    expect(byDay.get('2027-01-10')?.map((x) => x.id)).toEqual(['e', 'j']);
    expect(byDay.get('2027-01-11')?.map((x) => x.id)).toEqual(['j', 'm']);
    expect(byDay.get('2027-01-12')).toEqual([]);
  });

  it('a span ending exactly at midnight stays on its day', () => {
    const late = { id: 'l', starts_at: '2027-01-10T17:30:00Z', ends_at: '2027-01-10T18:30:00Z' }; // 23:00–00:00 IST
    const byDay = spansByDay([late], ['2027-01-10', '2027-01-11'], tz);
    expect(byDay.get('2027-01-10')?.length).toBe(1);
    expect(byDay.get('2027-01-11')?.length).toBe(0);
  });
});
