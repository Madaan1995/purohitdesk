import { describe, expect, it } from 'vitest';
import { formatPaise, isPaise, MAX_PAISE, paiseToRupeeInput, parseRupees } from './money';

describe('formatPaise (Indian grouping)', () => {
  it.each([
    [0, '₹0'],
    [100, '₹1'],
    [110000, '₹1,100'],
    [510000, '₹5,100'],
    [10000000, '₹1,00,000'],
    [1234567890505, '₹12,34,56,78,905.05'],
    [123456789, '₹12,34,567.89'],
    [510050, '₹5,100.50'],
    [5, '₹0.05'],
    [-110000, '-₹1,100'],
  ])('%i paise -> %s', (paise, text) => {
    expect(formatPaise(paise)).toBe(text);
  });

  it('refuses non-integers (no float money)', () => {
    expect(() => formatPaise(10.5)).toThrow(RangeError);
  });
});

describe('parseRupees', () => {
  it.each([
    ['5100', 510000],
    ['5,100', 510000],
    ['₹5,100', 510000],
    ['₹ 1,00,000', 10000000],
    ['5100.5', 510050],
    ['5100.05', 510005],
    ['0', 0],
    ['  21  ', 2100],
    ['1000000000', MAX_PAISE],
  ])('%j -> %i paise', (input, paise) => {
    expect(parseRupees(input)).toBe(paise);
  });

  it.each(['', '-100', '5100.555', '5.1.0', 'abc', '१००', '1e5', '1000000000.01', '99999999999'])('rejects %j', (input) => {
    expect(parseRupees(input)).toBeNull();
  });

  it('round-trips through the form representation without float error', () => {
    for (const paise of [0, 1, 99, 100, 510050, 123456789, 999999999999 % MAX_PAISE]) {
      expect(parseRupees(paiseToRupeeInput(paise))).toBe(paise);
    }
    expect(parseRupees('0.1')! + parseRupees('0.2')!).toBe(30);
  });

  it('isPaise accepts only safe non-negative integers up to the cap', () => {
    expect(isPaise(510000)).toBe(true);
    expect(isPaise(1.5)).toBe(false);
    expect(isPaise(-1)).toBe(false);
    expect(isPaise(MAX_PAISE + 1)).toBe(false);
  });
});
