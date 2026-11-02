import { canonicalJson } from '@/domain/idempotency';
import { createHash } from 'node:crypto';

/** SHA-256 hex of METHOD + path (relative to /api/v1) + canonical JSON body (spec §11 §1). */
export function requestHash(method: string, path: string, body: unknown): string {
  return createHash('sha256').update(`${method.toUpperCase()}${path}${canonicalJson(body ?? null)}`).digest('hex');
}
