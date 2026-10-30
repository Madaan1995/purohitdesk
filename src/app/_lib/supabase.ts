import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';
import { supabaseEnv } from './env';

/** Supabase auth cookies: httpOnly, so page scripts never see the tokens (spec §08 §1). */
export const AUTH_COOKIE_OPTIONS = {
  httpOnly: true,
  sameSite: 'lax' as const,
  secure: process.env.NODE_ENV === 'production',
  path: '/',
};

/** Server-side Supabase client bound to the request cookies (route handlers and server components). */
export async function supabaseServer() {
  const env = supabaseEnv();
  if (!env) return null;
  const store = await cookies();
  return createServerClient(env.url, env.publishableKey, {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => {
        try {
          for (const { name, value, options } of list) store.set(name, value, { ...options, ...AUTH_COOKIE_OPTIONS });
        } catch {
          // Server components cannot set cookies; src/proxy.ts refreshes the session on the next request.
        }
      },
    },
  });
}

/** The access token from the session cookie (refreshed if expired). Not trusted until verifyAccessToken. */
export async function sessionAccessToken(): Promise<string | null> {
  const supabase = await supabaseServer();
  if (!supabase) return null;
  const { data } = await supabase.auth.getSession();
  return data.session?.access_token ?? null;
}
