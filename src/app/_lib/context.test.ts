import { DomainError } from '@/db';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type JWK } from 'jose';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const ISSUER = 'https://project.supabase.test/auth/v1';
const SUB = '6f1c2a9e-4b7d-4c1e-9a3b-2d5e8f7a1b0c';

const holder = vi.hoisted(() => ({ config: null as unknown, token: null as string | null }));
const sessionAccessToken = vi.hoisted(() => vi.fn(async () => holder.token));
vi.mock('./auth-config', () => ({ authConfig: () => holder.config }));
vi.mock('./supabase', () => ({ sessionAccessToken }));

const { requireContext } = await import('./context');

beforeAll(async () => {
  const pair = await generateKeyPair('ES256');
  const jwk: JWK = { ...(await exportJWK(pair.publicKey)), kid: 'k1', alg: 'ES256', use: 'sig' };
  holder.config = { jwks: createLocalJWKSet({ keys: [jwk] }), issuer: ISSUER };
  holder.token = await new SignJWT({ role: 'authenticated' })
    .setProtectedHeader({ alg: 'ES256', kid: 'k1' })
    .setSubject(SUB)
    .setIssuer(ISSUER)
    .setAudience('authenticated')
    .setExpirationTime('1h')
    .sign(pair.privateKey);
});

beforeEach(() => sessionAccessToken.mockClear());

function req(method: string, headers: Record<string, string> = {}): Request {
  return new Request('https://pd.example.test/api/v1/me', { method, headers });
}

async function status(promise: Promise<unknown>): Promise<{ status: number; reason?: string }> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(DomainError);
    return { status: (error as DomainError).api.status, reason: (error as DomainError).api.reason };
  }
  return { status: 200 };
}

describe('requireContext: cookie-authenticated writes must be same-origin (CSRF)', () => {
  it('refuses a cross-site cookie write with 403 before reading the session', async () => {
    expect(await status(requireContext(req('PATCH', { 'sec-fetch-site': 'cross-site' })))).toEqual({
      status: 403,
      reason: 'CROSS_ORIGIN_REQUEST',
    });
    expect(sessionAccessToken).not.toHaveBeenCalled();
  });

  it('refuses a same-site (sibling subdomain) cookie write', async () => {
    const r = req('POST', { 'sec-fetch-site': 'same-site', origin: 'https://pd.example.test' });
    expect((await status(requireContext(r))).status).toBe(403);
  });

  it('refuses a cookie write with no Fetch Metadata and a foreign or missing Origin', async () => {
    expect((await status(requireContext(req('POST', { origin: 'https://evil.example.test' })))).status).toBe(403);
    expect((await status(requireContext(req('DELETE')))).status).toBe(403);
  });

  it('accepts a cookie write marked same-origin, or with a matching Origin', async () => {
    await expect(requireContext(req('POST', { 'sec-fetch-site': 'same-origin' }))).resolves.toMatchObject({
      actorId: SUB,
    });
    await expect(requireContext(req('PATCH', { origin: 'https://pd.example.test' }))).resolves.toMatchObject({
      actorId: SUB,
    });
  });

  it('does not check cookie reads', async () => {
    await expect(requireContext(req('GET', { 'sec-fetch-site': 'cross-site' }))).resolves.toMatchObject({
      actorId: SUB,
    });
  });

  it('does not check Bearer requests (a browser cannot attach the header cross-site)', async () => {
    const r = req('POST', { authorization: `Bearer ${holder.token}`, 'sec-fetch-site': 'cross-site' });
    await expect(requireContext(r)).resolves.toMatchObject({ actorId: SUB });
    expect(sessionAccessToken).not.toHaveBeenCalled();
  });
});
