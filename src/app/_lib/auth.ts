import { DomainError } from '@/db';
import { apiError } from '@/domain/errors';
import { jwtVerify } from 'jose';
import type { AuthConfig } from './auth-config';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A verified Supabase identity. */
export interface Identity {
  /** The token's `sub`: the only identity the API trusts. */
  actorId: string;
  /** The name in the token's user_metadata: untrusted display text, never used for authorization. */
  displayName: string | null;
}

function unauthenticated(reason: string): DomainError {
  return new DomainError(apiError('UNAUTHENTICATED', { reason }));
}

// Google sign-in puts the person's name in user_metadata (full_name, else name). The database cleans and caps it.
function metadataName(meta: unknown): string | null {
  if (typeof meta !== 'object' || meta === null) return null;
  const { full_name: fullName, name } = meta as Record<string, unknown>;
  if (typeof fullName === 'string') return fullName;
  return typeof name === 'string' ? name : null;
}

/**
 * Verifies a Supabase access token: signature against the project's JWKS (asymmetric keys only), expiry, issuer and
 * audience. Returns the actor id (`sub`) and the display name. Any failure is 401 INVALID_TOKEN (spec §08 §1,
 * API-SEC-1).
 */
export async function verifyAccessToken(token: string | null | undefined, config: AuthConfig | null): Promise<Identity> {
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
    return { actorId: payload.sub.toLowerCase(), displayName: metadataName(payload.user_metadata) };
  } catch {
    throw unauthenticated('INVALID_TOKEN');
  }
}
