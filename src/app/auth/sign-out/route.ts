// POST /auth/sign-out — ends the Supabase session and clears the selected practice.
import { supabaseServer } from '@/app/_lib/supabase';
import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function POST(req: Request) {
  const supabase = await supabaseServer();
  if (supabase) await supabase.auth.signOut();
  (await cookies()).delete('pd_tenant');
  return NextResponse.redirect(new URL('/sign-in', new URL(req.url).origin), 303);
}
