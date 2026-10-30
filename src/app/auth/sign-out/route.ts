// POST /auth/sign-out — ends the Supabase session and clears the selected practice. Same-origin only (CSRF).
import { errorResponse } from '@/app/_lib/http';
import { isSameOriginRequest } from '@/app/_lib/same-origin';
import { supabaseServer } from '@/app/_lib/supabase';
import { DomainError } from '@/db';
import { apiError } from '@/domain/errors';
import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function POST(req: Request) {
  if (!isSameOriginRequest(req)) {
    return errorResponse(new DomainError(apiError('FORBIDDEN', { reason: 'CROSS_ORIGIN_REQUEST' })));
  }
  const supabase = await supabaseServer();
  if (supabase) await supabase.auth.signOut();
  (await cookies()).delete('pd_tenant');
  return NextResponse.redirect(new URL('/sign-in', new URL(req.url).origin), 303);
}
