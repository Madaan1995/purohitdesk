// GET /auth/callback — Google returns here; exchange the code, create the app user, sync the language cookie.
import { authConfig } from '@/app/_lib/auth-config';
import { verifyAccessToken } from '@/app/_lib/auth';
import { loadSession } from '@/app/_lib/session';
import { supabaseServer } from '@/app/_lib/supabase';
import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function GET(req: Request) {
  const url = new URL(req.url);
  const code = url.searchParams.get('code');
  const supabase = await supabaseServer();
  if (!supabase || !code) return NextResponse.redirect(new URL('/sign-in?error=1', url.origin), 303);
  try {
    const { data, error } = await supabase.auth.exchangeCodeForSession(code);
    if (error || !data.session) throw new Error('exchange failed');
    const actorId = await verifyAccessToken(data.session.access_token, authConfig());
    const store = await cookies();
    const session = await loadSession(actorId, store.get('NEXT_LOCALE')?.value ?? null);
    store.set('NEXT_LOCALE', session.user.preferred_locale, { path: '/', maxAge: 31536000, sameSite: 'lax' });
  } catch {
    return NextResponse.redirect(new URL('/sign-in?error=1', url.origin), 303);
  }
  return NextResponse.redirect(new URL('/', url.origin), 303);
}
