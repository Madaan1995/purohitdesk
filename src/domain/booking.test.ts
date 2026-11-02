import { describe, expect, it } from 'vitest';
import { BOOKING_STATUSES, BOOKING_TRANSITIONS, canTransition, formatBookingNumber, isTerminal } from './booking';

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
