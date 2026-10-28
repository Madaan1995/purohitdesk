import { authConfig } from './auth-config';
import { verifyAccessToken } from './auth';
import { sessionAccessToken } from './supabase';

/** The verified actor id for server components, or null when signed out or the token is invalid. */
export async function currentActor(): Promise<string | null> {
  const token = await sessionAccessToken();
  if (!token) return null;
  try {
    return await verifyAccessToken(token, authConfig());
  } catch {
    return null;
  }
}
