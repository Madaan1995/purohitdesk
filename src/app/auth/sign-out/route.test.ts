import { beforeEach, describe, expect, it, vi } from 'vitest';

const signOut = vi.hoisted(() => vi.fn(async () => ({ error: null })));
const deleteCookie = vi.hoisted(() => vi.fn());
vi.mock('@/app/_lib/supabase', () => ({ supabaseServer: async () => ({ auth: { signOut } }) }));
vi.mock('next/headers', () => ({ cookies: async () => ({ delete: deleteCookie }) }));

const { POST } = await import('./route');

beforeEach(() => {
  signOut.mockClear();
  deleteCookie.mockClear();
});

function req(headers: Record<string, string>): Request {
  return new Request('https://pd.example.test/auth/sign-out', { method: 'POST', headers });
}

describe('POST /auth/sign-out (CSRF)', () => {
  it('signs out a same-origin form post and redirects to /sign-in', async () => {
    const res = await POST(req({ 'sec-fetch-site': 'same-origin', origin: 'https://pd.example.test' }));
    expect(res.status).toBe(303);
    expect(res.headers.get('location')).toBe('https://pd.example.test/sign-in');
    expect(signOut).toHaveBeenCalledOnce();
  });

  it('accepts a matching Origin when the browser sends no Fetch Metadata', async () => {
    expect((await POST(req({ origin: 'https://pd.example.test' }))).status).toBe(303);
  });

  it('refuses a cross-site post with 403 and keeps the session', async () => {
    const res = await POST(req({ 'sec-fetch-site': 'cross-site', origin: 'https://evil.example.test' }));
    expect(res.status).toBe(403);
    expect((await res.json()).error).toMatchObject({ code: 'FORBIDDEN', reason: 'CROSS_ORIGIN_REQUEST' });
    expect(signOut).not.toHaveBeenCalled();
    expect(deleteCookie).not.toHaveBeenCalled();
  });

  it('refuses a post with no Origin and no Fetch Metadata', async () => {
    expect((await POST(req({}))).status).toBe(403);
    expect(signOut).not.toHaveBeenCalled();
  });
});
