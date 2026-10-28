import { DomainError } from '@/db';
import { apiError } from '@/domain/errors';
import { jwtVerify } from 'jose';
import type { AuthConfig } from './auth-config';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function unauthenticated(reason: string): DomainError {
  return new DomainError(apiError('UNAUTHENTICATED', { reason }));
}

/**
 * Verifies a Supabase access token: signature against the project's JWKS (asymmetric keys only), expiry, issuer and
 * audience. Returns the actor id (`sub`). Any failure is 401 INVALID_TOKEN (spec §08 §1, API-SEC-1).
 */
export async function verifyAccessToken(token: string | null | undefined, config: AuthConfig | null): Promise<string> {
  if (!token) throw unauthenticated('TOKEN_MISSING');
  if (!config) throw unauthenticated('AUTH_NOT_CONFIGURED');
  try {
    const { payload } = await jwtVerify(token, config.jwks, {
      issuer: config.issuer,
      audience: 'authenticated',
      algorithms: ['ES256', 'RS256'],
      requiredClaims: ['sub', 'exp'],
    });
    if (typeof payload.sub !== 'string' || !UUID.test(payload.sub)) throw new Error('bad sub');
    return payload.sub.toLowerCase();
  } catch {
    throw unauthenticated('INVALID_TOKEN');
  }
}
