// GET /auth/sign-in — starts Google sign-in through Supabase Auth (server-side PKCE; tokens stay in httpOnly cookies).
import { supabaseServer } from '@/app/_lib/supabase';
import { NextResponse } from 'next/server';

export async function GET(req: Request) {
  const origin = new URL(req.url).origin;
  const supabase = await supabaseServer();
  if (!supabase) return NextResponse.redirect(new URL('/sign-in?error=config', origin), 303);
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: 'google',
    options: { redirectTo: `${origin}/auth/callback` },
  });
  if (error || !data.url) return NextResponse.redirect(new URL('/sign-in?error=1', origin), 303);
  return NextResponse.redirect(data.url, 303);
}
