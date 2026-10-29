import { authConfig } from './auth-config';
import { verifyAccessToken, type Identity } from './auth';
import { sessionAccessToken } from './supabase';

/** The verified identity for server components, or null when signed out or the token is invalid. */
export async function currentIdentity(): Promise<Identity | null> {
  const token = await sessionAccessToken();
  if (!token) return null;
  try {
    return await verifyAccessToken(token, authConfig());
  } catch {
    return null;
  }
}

/** The verified actor id for server components, or null when signed out or the token is invalid. */
export async function currentActor(): Promise<string | null> {
  return (await currentIdentity())?.actorId ?? null;
}
