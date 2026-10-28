// Shared fixtures for integration tests. THROWAWAY database only (see supabase/tests/README.md).
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type JWK } from 'jose';
import postgres from 'postgres';
import type { AuthConfig } from '@/app/_lib/auth-config';

export const ISSUER = 'http://supabase.test/auth/v1';

export const enabled = Boolean(process.env.DATABASE_URL && process.env.PGHOST);

let signingKey: CryptoKey | undefined;

export async function makeAuthConfig(): Promise<AuthConfig> {
  const pair = await generateKeyPair('ES256');
  signingKey = pair.privateKey;
  const jwk: JWK = { ...(await exportJWK(pair.publicKey)), kid: 'test', alg: 'ES256', use: 'sig' };
  return { jwks: createLocalJWKSet({ keys: [jwk] }), issuer: ISSUER };
}

export async function tokenFor(sub: string): Promise<string> {
  if (!signingKey) throw new Error('call makeAuthConfig first');
  return new SignJWT({ role: 'authenticated' })
    .setProtectedHeader({ alg: 'ES256', kid: 'test' })
    .setSubject(sub)
    .setIssuer(ISSUER)
    .setAudience('authenticated')
    .setIssuedAt()
    .setExpirationTime('10m')
    .sign(signingKey);
}

/** Superuser connection for fixtures (PG* variables), never used by the code under test. */
export function adminSql() {
  return postgres({ database: process.env.PGDATABASE ?? 'pd_test', max: 1, onnotice: () => {} });
}

/** A Supabase auth user (as Supabase Auth would create it on Google sign-in). */
export async function createAuthUser(admin: postgres.Sql, name: string): Promise<string> {
  const id = crypto.randomUUID();
  await admin`INSERT INTO auth.users (id, email, raw_user_meta_data)
              VALUES (${id}, ${id + '@example.test'}, ${admin.json({ full_name: name })})`;
  return id;
}

export function request(
  path: string,
  init: { method?: string; token?: string; tenant?: string; key?: string; body?: unknown; headers?: Record<string, string> } = {},
): Request {
  const headers: Record<string, string> = { ...init.headers };
  if (init.token !== undefined) headers.authorization = `Bearer ${init.token}`;
  if (init.tenant) headers['x-tenant-id'] = init.tenant;
  if (init.key) headers['idempotency-key'] = init.key;
  if (init.body !== undefined) headers['content-type'] = 'application/json';
  return new Request(`http://localhost/api/v1${path}`, {
    method: init.method ?? 'GET',
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
}
