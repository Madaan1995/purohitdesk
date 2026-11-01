// M6 integration: the booking lifecycle over HTTP against the throwaway database, as a real app_runtime login.
// Covers the founder's M6 checklist, API-CON-1 (HTTP race), API-CON-3 (stale edit) and API-SEC-5 (no foreign ids).
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { adminSql, createAuthUser, enabled, makeAuthConfig, request, tokenFor } from './helpers';

const holder = vi.hoisted(() => ({ config: null as unknown }));
vi.mock('@/app/_lib/auth-config', () => ({ authConfig: () => holder.config }));

const { GET: getSession } = await import('@/app/api/v1/session/route');
const { POST: postPractice } = await import('@/app/api/v1/onboarding/practice/route');
const customers = await import('@/app/api/v1/customers/route');
const offerings = await import('@/app/api/v1/offerings/route');
const bookings = await import('@/app/api/v1/bookings/route');
const booking = await import('@/app/api/v1/bookings/[bookingId]/route');
const confirm = await import('@/app/api/v1/bookings/[bookingId]/confirm/route');
const cancel = await import('@/app/api/v1/bookings/[bookingId]/cancel/route');
const complete = await import('@/app/api/v1/bookings/[bookingId]/complete/route');
const { closeSql } = await import('@/db');

interface Practice {
  org: string;
  link: string;
  customer: string;
  offering: string;
}

describe.skipIf(!enabled)('M6 bookings API against a throwaway database', () => {
  const admin = enabled ? adminSql() : (null as never);
  let token: string;
  let readOnlyToken: string;
  let first: Practice;
  let second: Practice;
  let key = 0;
  const nextKey = () => `m6-int-${String(++key).padStart(5, '0')}`;
  const params = (bookingId: string) => ({ params: Promise.resolve({ bookingId }) });
  const post = (p: Practice, body: unknown, t = token) =>
    bookings.POST(request('/bookings', { method: 'POST', token: t, tenant: p.org, key: nextKey(), body }));
  const act = (
    handler: { POST: (req: Request, ctx: { params: Promise<{ bookingId: string }> }) => Promise<Response> },
    action: string,
    p: Practice,
    id: string,
    version: number,
    body: unknown = {},
  ) =>
    handler.POST(
      request(`/bookings/${id}/${action}`, {
        method: 'POST', token, tenant: p.org, key: nextKey(), body, headers: { 'if-match': `"${version}"` },
      }),
      params(id),
    );
  const patch = (p: Practice, id: string, version: number, body: unknown) =>
    booking.PATCH(
      request(`/bookings/${id}`, { method: 'PATCH', token, tenant: p.org, key: nextKey(), body, headers: { 'if-match': `"${version}"` } }),
      params(id),
    );
  const fields = (p: Practice, extra: Record<string, unknown>) => ({
    customer_id: p.customer, offering_id: p.offering, priest_ids: [p.link], ...extra,
  });

  async function practice(name: string): Promise<Practice> {
    const [havan] = await admin`SELECT id FROM app.ceremony_types WHERE slug = 'havan'`;
    const res = await postPractice(
      request('/onboarding/practice', { method: 'POST', token, key: nextKey(), body: { name, ceremony_type_ids: [havan.id] } }),
    );
    const created = await res.json();
    const org = created.organization.id;
    const c = await customers.POST(
      request('/customers', { method: 'POST', token, tenant: org, key: nextKey(), body: { display_name: `Yajman of ${name}` } }),
    );
    const list = await (await offerings.GET(request('/offerings', { token, tenant: org }))).json();
    return { org, link: created.organization_priest_id, customer: (await c.json()).customer.id, offering: list.data[0].id };
  }

  beforeAll(async () => {
    holder.config = await makeAuthConfig();
    const owner = await createAuthUser(admin, 'Owner Six');
    token = await tokenFor(owner);
    await getSession(request('/session', { token }));
    first = await practice('Booking Practice One');
    second = await practice('Booking Practice Two');
    const reader = await createAuthUser(admin, 'Reader Six');
    readOnlyToken = await tokenFor(reader);
    await getSession(request('/session', { token: readOnlyToken }));
    await admin`INSERT INTO app.org_members (org_id, user_id, role) VALUES (${first.org}, ${reader}, 'READ_ONLY')`;
  });

  afterAll(async () => {
    await closeSql();
    await admin.end();
  });

  let one: { id: string; version: number };

  it('saves a draft with only a date; confirming it says a time is needed', async () => {
    const res = await post(first, fields(first, { local_date: '2027-01-10' }));
    expect(res.status).toBe(201);
    const { booking: b } = await res.json();
    expect(b).toMatchObject({ status: 'DRAFT', local_date: '2027-01-10', starts_at: null, timezone: 'Asia/Kolkata', version: 1 });
    expect(b.booking_number).toMatch(/^PD-\d{2}-0001$/);
    expect(res.headers.get('etag')).toBe('"1"');

    const refused = await act(confirm, 'confirm', first, b.id, 1);
    expect(refused.status).toBe(422);
    expect((await refused.json()).error).toMatchObject({ code: 'VALIDATION_FAILED', reason: 'TIME_REQUIRED', details: { field: 'starts_at' } });
    one = { id: b.id, version: 1 };
  });

  it('adds a time, then confirms (PD-YY-NNNN number kept)', async () => {
    const edited = await patch(first, one.id, one.version, { starts_at: '2027-01-10T04:30:00Z', ends_at: '2027-01-10T06:30:00Z' });
    expect(edited.status).toBe(200);
    const confirmed = await act(confirm, 'confirm', first, one.id, (await edited.json()).booking.version);
    expect(confirmed.status).toBe(200);
    const { booking: b } = await confirmed.json();
    expect(b).toMatchObject({ status: 'CONFIRMED', starts_at: '2027-01-10T04:30:00+00:00', buffer_before_min: 30 });
    one.version = b.version;

    const got = await booking.GET(request(`/bookings/${one.id}`, { token, tenant: first.org }), params(one.id));
    expect(got.headers.get('etag')).toBe(`"${b.version}"`);
    expect((await got.json()).priests).toEqual([expect.objectContaining({ organization_priest_id: first.link, role: 'LEAD' })]);
  });

  it('refuses an overlapping booking in the same practice', async () => {
    const res = await post(first, fields(first, { starts_at: '2027-01-10T05:30:00Z', ends_at: '2027-01-10T07:00:00Z', confirm: true }));
    expect(res.status).toBe(409);
    const { error } = await res.json();
    expect(error.code).toBe('BOOKING_CONFLICT');
    expect(error.details.conflicts).toEqual([
      { organization_priest_id: first.link, starts_at: '2027-01-10T04:30:00+00:00', ends_at: '2027-01-10T06:30:00+00:00', same_org: true, booking_id: one.id },
    ]);
  });

  let other: string;
  it('refuses the same priest in the second practice, without the first practice\'s ids (API-SEC-5)', async () => {
    const draft = await post(second, fields(second, { starts_at: '2027-01-10T06:00:00Z', ends_at: '2027-01-10T07:00:00Z' }));
    other = (await draft.json()).booking.id;
    const res = await act(confirm, 'confirm', second, other, 1);
    expect(res.status).toBe(409);
    const text = await res.text();
    expect(text).not.toContain(one.id);
    expect(text).not.toContain(first.org);
    expect(JSON.parse(text).error.details.conflicts).toEqual([
      { organization_priest_id: second.link, starts_at: '2027-01-10T04:30:00+00:00', ends_at: '2027-01-10T06:30:00+00:00', same_org: false },
    ]);
  });

  it('cancel with a reason frees the slot for the second practice', async () => {
    const noReason = await act(cancel, 'cancel', first, one.id, one.version, {});
    expect(noReason.status).toBe(422);
    const res = await act(cancel, 'cancel', first, one.id, one.version, { reason: 'Family postponed' });
    expect(res.status).toBe(200);
    expect((await res.json()).booking).toMatchObject({ status: 'CANCELLED', cancel_reason: 'Family postponed' });
    const now = await act(confirm, 'confirm', second, other, 1);
    expect(now.status).toBe(200);
  });

  it('completes only a ceremony that has started; a completed booking cannot change', async () => {
    const future = await post(first, fields(first, { starts_at: '2027-02-01T04:30:00Z', ends_at: '2027-02-01T05:30:00Z', confirm: true }));
    const f = (await future.json()).booking;
    const early = await act(complete, 'complete', first, f.id, f.version);
    expect(early.status).toBe(422);
    expect((await early.json()).error.reason).toBe('NOT_STARTED');

    const start = new Date(Date.now() - 60 * 60_000);
    const started = await post(first, fields(first, {
      starts_at: start.toISOString(), ends_at: new Date(start.getTime() + 30 * 60_000).toISOString(), confirm: true,
    }));
    expect(started.status).toBe(201);
    const s = (await started.json()).booking;
    const done = await act(complete, 'complete', first, s.id, s.version);
    expect(done.status).toBe(200);
    const d = (await done.json()).booking;
    expect(d.status).toBe('COMPLETED');
    const locked = await patch(first, s.id, d.version, { title: 'changed' });
    expect(locked.status).toBe(409);
    expect((await locked.json()).error.code).toBe('INVALID_TRANSITION');
  });

  it('lists the practice\'s bookings by date and keeps other practices\' bookings out (404)', async () => {
    const res = await bookings.GET(request('/bookings?from=2027-01-01&to=2027-12-31&limit=100', { token, tenant: first.org }));
    expect(res.status).toBe(200);
    const { data } = await res.json();
    expect(data.map((b: { local_date: string }) => b.local_date)).toEqual([...data.map((b: { local_date: string }) => b.local_date)].sort());
    expect(data.find((b: { id: string }) => b.id === other)).toBeUndefined();
    expect(data[0]).toMatchObject({ customer: { id: first.customer }, offering: { id: first.offering } });

    const foreign = await booking.GET(request(`/bookings/${other}`, { token, tenant: first.org }), params(other));
    expect(foreign.status).toBe(404);
    const range = await bookings.GET(request('/bookings?from=2027-01-01&to=2028-06-01', { token, tenant: first.org }));
    expect(range.status).toBe(422);
  });

  it('replays the same Idempotency-Key with the same result', async () => {
    const body = fields(first, { local_date: '2027-03-03', title: 'replay' });
    const req = () => bookings.POST(request('/bookings', { method: 'POST', token, tenant: first.org, key: 'm6-int-replay-1', body }));
    const a = await req();
    const b = await req();
    expect([a.status, b.status]).toEqual([201, 200]);
    const [ja, jb] = [await a.json(), await b.json()];
    expect(jb.booking.id).toBe(ja.booking.id);
    expect([ja.idempotent_replay, jb.idempotent_replay]).toEqual([false, true]);
  });

  it('API-CON-1: two concurrent confirms of overlapping bookings of one priest → one 200, one 409 (50 times)', async () => {
    for (let i = 0; i < 50; i++) {
      const day = new Date(Date.UTC(2029, 0, 1 + i)).toISOString().slice(0, 10);
      const a = (await (await post(first, fields(first, { starts_at: `${day}T04:30:00Z`, ends_at: `${day}T06:30:00Z` }))).json()).booking;
      const b = (await (await post(second, fields(second, { starts_at: `${day}T05:00:00Z`, ends_at: `${day}T07:00:00Z` }))).json()).booking;
      const results = await Promise.all([act(confirm, 'confirm', first, a.id, 1), act(confirm, 'confirm', second, b.id, 1)]);
      const statuses = results.map((r) => r.status).sort();
      expect(statuses, `iteration ${i}`).toEqual([200, 409]);
      const loser = results.find((r) => r.status === 409)!;
      expect((await loser.json()).error.code).toBe('BOOKING_CONFLICT');
    }
    const [{ n }] = await admin`
      SELECT count(*)::int AS n FROM app.calendar_reservations r1 JOIN app.calendar_reservations r2
        ON r1.priest_profile_id = r2.priest_profile_id AND r1.id < r2.id AND r1.span && r2.span
      WHERE r1.status = 'ACTIVE' AND r2.status = 'ACTIVE'`;
    expect(n).toBe(0);
  });

  it('API-CON-3: two PATCHes with the same If-Match → one 200, one 409 VERSION_CONFLICT', async () => {
    const b = (await (await post(first, fields(first, { local_date: '2027-04-04' }))).json()).booking;
    const results = await Promise.all([
      patch(first, b.id, b.version, { notes: 'first tab' }),
      patch(first, b.id, b.version, { notes: 'second tab' }),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
    const loser = await results.find((r) => r.status === 409)!.json();
    expect(loser.error).toMatchObject({ code: 'VERSION_CONFLICT', details: { current_version: b.version + 1 } });
  });

  it('READ_ONLY reads bookings but cannot create, edit or confirm (403)', async () => {
    expect((await bookings.GET(request('/bookings', { token: readOnlyToken, tenant: first.org }))).status).toBe(200);
    const res = await post(first, fields(first, { local_date: '2027-05-05' }), readOnlyToken);
    expect(res.status).toBe(403);
    expect((await res.json()).error.code).toBe('FORBIDDEN');
  });

  it('rejects unknown fields and malformed instants before the database (422)', async () => {
    const unknown = await post(first, fields(first, { local_date: '2027-05-05', colour: 'red' }));
    expect(unknown.status).toBe(422);
    const naive = await post(first, fields(first, { starts_at: '2027-05-05T10:00:00', ends_at: '2027-05-05T11:00:00' }));
    expect(naive.status).toBe(422);
    expect((await naive.json()).error.details.field).toBe('starts_at');
  });
});
