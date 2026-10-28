// Indian phone numbers to E.164 (spec §01 §3: phone optional, shared household phones allowed).

const E164 = /^\+[1-9]\d{7,14}$/;

/**
 * Normalises what a priest types into E.164, or returns null if it is not a phone number.
 * Spaces, dashes, dots and brackets are ignored. Accepted: +<country><number>, 00<country><number>,
 * 10 digits (India), 0 + 10 digits (trunk prefix, incl. landlines with STD code), 91 + 10 digits.
 */
export function normalizeIndianPhone(input: string): string | null {
  const compact = input.trim().replace(/[\s\-.()]/g, '');
  if (compact === '') return null;
  let candidate: string;
  if (compact.startsWith('+')) candidate = compact;
  else if (!/^\d+$/.test(compact)) return null;
  else if (compact.startsWith('00')) candidate = `+${compact.slice(2)}`;
  else if (compact.length === 10 && /^[1-9]/.test(compact)) candidate = `+91${compact}`;
  else if (compact.length === 11 && compact.startsWith('0')) candidate = `+91${compact.slice(1)}`;
  else if (compact.length === 12 && compact.startsWith('91')) candidate = `+${compact}`;
  else return null;
  if (!E164.test(candidate)) return null;
  if (candidate.startsWith('+91') && candidate.length !== 13) return null;
  return candidate;
}

/** Digits only, for "phone contains" searches. */
export function phoneDigits(input: string): string {
  return input.replace(/\D/g, '');
}
