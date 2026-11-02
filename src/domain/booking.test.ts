import { describe, expect, it } from 'vitest';
import {
  BOOKING_STATUSES,
  BOOKING_TRANSITIONS,
  canTransition,
  formatBookingNumber,
  isTerminal,
  RESCHEDULE_REASON_CODES,
  travelGapMinutes,
} from './booking';

describe('BOOKING_TRANSITIONS (mirror of app.tg_booking_guard)', () => {
  it('allows exactly the four P0 transitions', () => {
    const allowed = BOOKING_STATUSES.flatMap((from) => BOOKING_STATUSES.filter((to) => canTransition(from, to)).map((to) => `${from}->${to}`));
    expect(allowed.sort()).toEqual(['CONFIRMED->CANCELLED', 'CONFIRMED->COMPLETED', 'DRAFT->CANCELLED', 'DRAFT->CONFIRMED']);
  });

  it('terminal states are closed', () => {
    expect(isTerminal('COMPLETED')).toBe(true);
    expect(isTerminal('CANCELLED')).toBe(true);
    expect(isTerminal('DRAFT')).toBe(false);
    expect(canTransition('COMPLETED', 'DRAFT')).toBe(false);
    expect(BOOKING_TRANSITIONS.CANCELLED).toEqual([]);
  });
});

describe('formatBookingNumber', () => {
  it('formats PD-YY-NNNN and grows past 9999', () => {
    expect(formatBookingNumber(2026, 1)).toBe('PD-26-0001');
    expect(formatBookingNumber(2027, 9999)).toBe('PD-27-9999');
    expect(formatBookingNumber(2027, 10000)).toBe('PD-27-10000');
    expect(formatBookingNumber(2100, 42)).toBe('PD-00-0042');
  });

  it('refuses non-positive or fractional numbers', () => {
    expect(() => formatBookingNumber(2026, 0)).toThrow(RangeError);
    expect(() => formatBookingNumber(2026, 1.5)).toThrow(RangeError);
  });
});

describe('travelGapMinutes', () => {
  const at = (h: string) => `2027-06-01T${h}:00Z`;
  it('finds the shortest gap before or after the ceremony', () => {
    expect(travelGapMinutes([{ starts_at: at('04:30'), ends_at: at('05:30') }], at('05:45'), at('06:45'))).toBe(15);
    expect(
      travelGapMinutes(
        [
          { starts_at: at('04:30'), ends_at: at('05:30') },
          { starts_at: at('06:55'), ends_at: at('07:30') },
        ],
        at('05:45'),
        at('06:45'),
      ),
    ).toBe(10);
  });
  it('is 0 for touching spans and null without spans', () => {
    expect(travelGapMinutes([{ starts_at: at('06:45'), ends_at: at('07:00') }], at('05:45'), at('06:45'))).toBe(0);
    expect(travelGapMinutes([], at('05:45'), at('06:45'))).toBeNull();
  });
});

describe('RESCHEDULE_REASON_CODES', () => {
  it('matches the reason_code enum of api/openapi.yaml', async () => {
    const { readFileSync } = await import('node:fs');
    const yaml = readFileSync('api/openapi.yaml', 'utf8');
    const m = /RescheduleReasonCode:\s*\n\s*type: string\s*\n\s*enum: \[([^\]]+)\]/.exec(yaml);
    expect(m?.[1].split(',').map((s) => s.trim())).toEqual([...RESCHEDULE_REASON_CODES]);
  });
});
