import { describe, expect, it } from 'vitest';
import { formatPhone, normalizeIndianPhone, phoneDigits } from './phone';

describe('normalizeIndianPhone', () => {
  it.each([
    ['9876543210', '+919876543210'],
    ['98765 43210', '+919876543210'],
    ['98765-43210', '+919876543210'],
    ['09876543210', '+919876543210'],
    ['919876543210', '+919876543210'],
    ['+91 98765 43210', '+919876543210'],
    ['+91-98765-43210', '+919876543210'],
    ['0091 9876543210', '+919876543210'],
    ['(0172) 2345678', '+911722345678'],
    ['0172-2345678', '+911722345678'],
    ['+1 415 555 0100', '+14155550100'],
    ['+44 20 7946 0958', '+442079460958'],
  ])('%s -> %s', (input, expected) => {
    expect(normalizeIndianPhone(input)).toBe(expected);
  });

  it.each(['', '   ', '12345', '98765432', '987654321012', '+91 98765', '+91 98765432101', 'call me', '98765abcde', '+0123456789'])(
    'rejects %j',
    (input) => {
      expect(normalizeIndianPhone(input)).toBeNull();
    },
  );

  it('extracts digits for contains-search', () => {
    expect(phoneDigits('+91 98765-43210')).toBe('919876543210');
  });
});

describe('formatPhone', () => {
  it('groups Indian numbers as +91 98765 43210', () => {
    expect(formatPhone('+919876543210')).toBe('+91 98765 43210');
  });
  it('leaves other numbers unchanged', () => {
    expect(formatPhone('+14155550100')).toBe('+14155550100');
  });
});
