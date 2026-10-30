import { createRemoteJWKSet, type JWTVerifyGetKey } from 'jose';
import { supabaseEnv } from './env';

export interface AuthConfig {
  jwks: JWTVerifyGetKey;
  issuer: string;
}

let cached: { url: string; config: AuthConfig } | undefined;

/** Supabase JWKS (asymmetric signing keys) and issuer, derived from NEXT_PUBLIC_SUPABASE_URL. jose caches the keys. */
export function authConfig(): AuthConfig | null {
  const env = supabaseEnv();
  if (!env) return null;
  if (cached?.url !== env.url) {
    cached = {
      url: env.url,
      config: {
        jwks: createRemoteJWKSet(new URL(`${env.url}/auth/v1/.well-known/jwks.json`)),
        issuer: `${env.url}/auth/v1`,
      },
    };
  }
  return cached.config;
}
