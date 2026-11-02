// Idempotency-Key rules and the canonical JSON used for request hashes (spec §11 §1, §05 §9).

const KEY = /^[\x21-\x7e]{8,128}$/;

/** 8–128 visible ASCII characters (no spaces or control characters). */
export function isValidIdempotencyKey(key: unknown): key is string {
  return typeof key === 'string' && KEY.test(key);
}

/** JSON with object keys sorted at every level, so equal bodies hash equally whatever the key order. */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortKeys(value)) ?? 'null';
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === 'object' && value.constructor === Object) {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort()) {
      out[key] = sortKeys((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return value;
}
