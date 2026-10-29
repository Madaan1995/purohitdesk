import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { authConfig } from './auth-config';
import { verifyAccessToken, type Identity } from './auth';
import { loadSession, type Membership, type Session } from './session';
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

/**
 * For pages inside a practice: the signed-in actor, their session and the current practice (the `pd_tenant` cookie if
 * it names one of their ACTIVE memberships, else the first). Redirects to sign-in or onboarding when needed.
 */
export async function requirePractice(): Promise<{ actorId: string; session: Session; current: Membership }> {
  const identity = await currentIdentity();
  if (!identity) redirect('/sign-in');
  const store = await cookies();
  const session = await loadSession(identity, store.get('NEXT_LOCALE')?.value ?? null);
  if (session.memberships.length === 0) redirect('/onboarding');
  const selected = store.get('pd_tenant')?.value;
  const current = session.memberships.find((m) => m.organization.id === selected) ?? session.memberships[0];
  return { actorId: identity.actorId, session, current };
}
