import { DomainError } from '@/db';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type JWK } from 'jose';
import { beforeAll, describe, expect, it } from 'vitest';
import { verifyAccessToken } from './auth';
import type { AuthConfig } from './auth-config';

const ISSUER = 'https://project.supabase.test/auth/v1';
const SUB = '6f1c2a9e-4b7d-4c1e-9a3b-2d5e8f7a1b0c';

let config: AuthConfig;
let signingKey: CryptoKey;
let otherKey: CryptoKey;

beforeAll(async () => {
  const pair = await generateKeyPair('ES256');
  const other = await generateKeyPair('ES256');
  signingKey = pair.privateKey;
  otherKey = other.privateKey;
  const jwk: JWK = { ...(await exportJWK(pair.publicKey)), kid: 'k1', alg: 'ES256', use: 'sig' };
  config = { jwks: createLocalJWKSet({ keys: [jwk] }), issuer: ISSUER };
});

function token(overrides: { aud?: string; iss?: string; exp?: string | number; sub?: string; key?: CryptoKey } = {}) {
  return new SignJWT({ role: 'authenticated' })
    .setProtectedHeader({ alg: 'ES256', kid: 'k1' })
    .setSubject(overrides.sub ?? SUB)
    .setIssuer(overrides.iss ?? ISSUER)
    .setAudience(overrides.aud ?? 'authenticated')
    .setIssuedAt()
    .setExpirationTime(overrides.exp ?? '1h')
    .sign(overrides.key ?? signingKey);
}

async function reason(promise: Promise<unknown>): Promise<string | undefined> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(DomainError);
    const api = (error as DomainError).api;
    expect(api.status).toBe(401);
    return api.reason;
  }
  throw new Error('expected a 401');
}

describe('verifyAccessToken (spec API-SEC-1)', () => {
  it('accepts a valid Supabase token and returns its sub', async () => {
    await expect(verifyAccessToken(await token(), config)).resolves.toBe(SUB);
  });

  it('rejects a missing token', async () => {
    expect(await reason(verifyAccessToken(null, config))).toBe('TOKEN_MISSING');
    expect(await reason(verifyAccessToken('', config))).toBe('TOKEN_MISSING');
  });

  it('rejects a malformed token', async () => {
    expect(await reason(verifyAccessToken('not.a.jwt', config))).toBe('INVALID_TOKEN');
  });

  it('rejects an expired token', async () => {
    const expired = await token({ exp: Math.floor(Date.now() / 1000) - 60 });
    expect(await reason(verifyAccessToken(expired, config))).toBe('INVALID_TOKEN');
  });

  it('rejects the wrong audience', async () => {
    expect(await reason(verifyAccessToken(await token({ aud: 'anon' }), config))).toBe('INVALID_TOKEN');
  });

  it('rejects the wrong issuer', async () => {
    expect(await reason(verifyAccessToken(await token({ iss: 'https://evil.test/auth/v1' }), config))).toBe('INVALID_TOKEN');
  });

  it('rejects a token signed by another key', async () => {
    expect(await reason(verifyAccessToken(await token({ key: otherKey }), config))).toBe('INVALID_TOKEN');
  });

  it('rejects a modified payload', async () => {
    const [h, , s] = (await token()).split('.');
    const forged = Buffer.from(JSON.stringify({ sub: SUB, aud: 'authenticated', iss: ISSUER, exp: 9999999999 })).toString('base64url');
    expect(await reason(verifyAccessToken(`${h}.${forged}.${s}`, config))).toBe('INVALID_TOKEN');
  });

  it('rejects symmetric (HS256) tokens', async () => {
    const hs = await new SignJWT({})
      .setProtectedHeader({ alg: 'HS256', kid: 'k1' })
      .setSubject(SUB)
      .setIssuer(ISSUER)
      .setAudience('authenticated')
      .setExpirationTime('1h')
      .sign(new TextEncoder().encode('a-shared-secret-that-is-long-enough-123'));
    expect(await reason(verifyAccessToken(hs, config))).toBe('INVALID_TOKEN');
  });

  it('rejects a sub that is not a uuid', async () => {
    expect(await reason(verifyAccessToken(await token({ sub: 'admin' }), config))).toBe('INVALID_TOKEN');
  });

  it('fails closed when auth is not configured', async () => {
    expect(await reason(verifyAccessToken(await token(), null))).toBe('AUTH_NOT_CONFIGURED');
  });
});
