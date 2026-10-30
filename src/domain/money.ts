// Money is integer paise everywhere (golden rule 6). Rupees exist only as text typed or shown in the UI.

export type Paise = number & { readonly __brand: 'Paise' };

/** ₹1,00,00,00,000 — the largest amount any money column accepts. */
export const MAX_PAISE = 100_000_000_000;

export function isPaise(value: unknown): value is Paise {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= MAX_PAISE;
}

/** 1234567 → "12,34,567" (Indian digit grouping: last three digits, then groups of two). */
function groupIndian(digits: string): string {
  if (digits.length <= 3) return digits;
  const last3 = digits.slice(-3);
  const head = digits.slice(0, -3);
  const groups: string[] = [];
  for (let end = head.length; end > 0; end -= 2) groups.unshift(head.slice(Math.max(0, end - 2), end));
  return `${groups.join(',')},${last3}`;
}

/** 10000000 paise → "₹1,00,000"; 510050 → "₹5,100.50"; negatives (refunds) → "-₹1,100". */
export function formatPaise(paise: number): string {
  if (!Number.isSafeInteger(paise)) throw new RangeError('paise must be an integer');
  const sign = paise < 0 ? '-' : '';
  const abs = Math.abs(paise);
  const rupees = Math.floor(abs / 100);
  const rest = abs % 100;
  return `${sign}₹${groupIndian(String(rupees))}${rest ? `.${String(rest).padStart(2, '0')}` : ''}`;
}

/**
 * Parses rupees typed by a person into paise, without floating point: "5,100" → 510000, "₹ 5100.5" → 510050.
 * Returns null for anything else (negative, more than two decimals, text, above MAX_PAISE).
 */
export function parseRupees(input: string): Paise | null {
  const s = input.trim().replace(/^₹/, '').replace(/[,\s]/g, '');
  if (!/^\d{1,10}(\.\d{1,2})?$/.test(s)) return null;
  const [rupees, fraction = ''] = s.split('.');
  const paise = Number(rupees) * 100 + Number(fraction.padEnd(2, '0'));
  return paise <= MAX_PAISE ? (paise as Paise) : null;
}

/** Paise → the plain rupee text a form field starts with: 510000 → "5100", 510050 → "5100.50". */
export function paiseToRupeeInput(paise: number): string {
  const rupees = Math.floor(paise / 100);
  const rest = paise % 100;
  return rest ? `${rupees}.${String(rest).padStart(2, '0')}` : String(rupees);
}
