// M7 integration: travel-buffer acknowledgement and reschedule over HTTP against the throwaway database.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { RESCHEDULE_REASON_CODES } from '@/domain/booking';
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
const reschedule = await import('@/app/api/v1/bookings/[bookingId]/reschedule/route');
const { closeSql } = await import('@/db');

describe.skipIf(!enabled)('M7 reschedule and travel buffers against a throwaway database', () => {
  const admin = enabled ? adminSql() : (null as never);
  let token: string;
  let org: string;
  let base: Record<string, unknown>;
  let key = 0;
  const nextKey = () => `m7-int-${String(++key).padStart(5, '0')}`;
  const params = (bookingId: string) => ({ params: Promise.resolve({ bookingId }) });
  const create = (body: Record<string, unknown>, k = nextKey()) =>
    bookings.POST(request('/bookings', { method: 'POST', token, tenant: org, key: k, body: { ...base, ...body } }));
  const move = (id: string, version: number, body: Record<string, unknown>, k = nextKey()) =>
    reschedule.POST(
      request(`/bookings/${id}/reschedule`, { method: 'POST', token, tenant: org, key: k, body, headers: { 'if-match': `"${version}"` } }),
      params(id),
    );
  const get = async (id: string) =>
    (await booking.GET(request(`/bookings/${id}`, { token, tenant: org }), params(id))).json();

  beforeAll(async () => {
    holder.config = await makeAuthConfig();
    const owner = await createAuthUser(admin, 'Owner Seven');
    token = await tokenFor(owner);
    await getSession(request('/session', { token }));
    const [havan] = await admin`SELECT id FROM app.ceremony_types WHERE slug = 'havan'`;
    const created = await (
      await postPractice(
        request('/onboarding/practice', { method: 'POST', token, key: nextKey(), body: { name: 'Travel Practice', ceremony_type_ids: [havan.id] } }),
      )
    ).json();
    org = created.organization.id;
    const c = await (
      await customers.POST(request('/customers', { method: 'POST', token, tenant: org, key: nextKey(), body: { display_name: 'Yajman Seven' } }))
    ).json();
    const list = await (await offerings.GET(request('/offerings', { token, tenant: org }))).json();
    base = { customer_id: c.customer.id, offering_id: list.data[0].id, priest_ids: [created.organization_priest_id] };
  });

  afterAll(async () => {
    await closeSql();
    await admin.end();
  });

  it('15 minutes between two bookings with 30-minute buffers asks for an acknowledgement; continuing records it', async () => {
    expect((await create({ starts_at: '2027-08-01T04:30:00Z', ends_at: '2027-08-01T05:30:00Z', confirm: true })).status).toBe(201);
    const second = { starts_at: '2027-08-01T05:45:00Z', ends_at: '2027-08-01T06:45:00Z', confirm: true };
    const refused = await create(second);
    expect(refused.status).toBe(409);
    const { error } = await refused.json();
    expect(error.code).toBe('BUFFER_CONFLICT');
    expect(error.details.conflicts[0]).toMatchObject({ starts_at: '2027-08-01T04:30:00+00:00', ends_at: '2027-08-01T05:30:00+00:00', same_org: true });

    const accepted = await create({ ...second, ack_buffer_overlap: true });
    expect(accepted.status).toBe(201);
    const b = (await accepted.json()).booking;
    expect(b).toMatchObject({ status: 'CONFIRMED', buffer_overlap_ack: true });
    const [{ events }] = await admin`SELECT string_agg(event, ',' ORDER BY id) AS events FROM app.booking_events WHERE booking_id = ${b.id}`;
    expect(events).toBe('CREATED,CONFIRMED,BUFFER_OVERLAP_ACKNOWLEDGED');
  });

  it('the confirm endpoint takes the acknowledgement too', async () => {
    const draft = (await (await create({ starts_at: '2027-08-01T06:55:00Z', ends_at: '2027-08-01T07:30:00Z' })).json()).booking;
    const send = (ack?: boolean) =>
      confirm.POST(
        request(`/bookings/${draft.id}/confirm`, {
          method: 'POST', token, tenant: org, key: nextKey(), body: ack ? { ack_buffer_overlap: true } : {}, headers: { 'if-match': '"1"' },
        }),
        params(draft.id),
      );
    expect((await send()).status).toBe(409);
    const ok = await send(true);
    expect(ok.status).toBe(200);
    expect((await ok.json()).booking.buffer_overlap_ack).toBe(true);
  });

  it('a reschedule into a ceremony conflict is refused and the original time is unchanged', async () => {
    const a = (await (await create({ starts_at: '2027-08-02T04:30:00Z', ends_at: '2027-08-02T05:30:00Z', confirm: true })).json()).booking;
    await create({ starts_at: '2027-08-02T09:00:00Z', ends_at: '2027-08-02T10:00:00Z', confirm: true });
    const res = await move(a.id, a.version, { starts_at: '2027-08-02T09:30:00Z', ends_at: '2027-08-02T10:30:00Z', reason_code: 'CUSTOMER_REQUEST' });
    expect(res.status).toBe(409);
    expect((await res.json()).error.code).toBe('BOOKING_CONFLICT');
    expect(await get(a.id)).toMatchObject({ starts_at: '2027-08-02T04:30:00+00:00', version: a.version });
  });

  it('a reschedule to a free slot frees the old slot for another booking', async () => {
    const a = (await (await create({ starts_at: '2027-08-03T04:30:00Z', ends_at: '2027-08-03T05:30:00Z', confirm: true })).json()).booking;
    const res = await move(a.id, a.version, { starts_at: '2027-08-03T11:00:00Z', ends_at: '2027-08-03T12:00:00Z', reason_code: 'MUHURAT_FIXED' });
    expect(res.status).toBe(200);
    expect(res.headers.get('etag')).toBe(`"${(await res.clone().json()).booking.version}"`);
    const taken = await create({ starts_at: '2027-08-03T04:30:00Z', ends_at: '2027-08-03T05:30:00Z', confirm: true });
    expect(taken.status).toBe(201);
  });

  it('accepts every reason code and refuses free text', async () => {
    let b = (await (await create({ starts_at: '2027-08-10T04:30:00Z', ends_at: '2027-08-10T05:00:00Z', confirm: true })).json()).booking;
    for (const [i, code] of RESCHEDULE_REASON_CODES.entries()) {
      const day = `2027-08-${String(11 + i).padStart(2, '0')}`;
      const res = await move(b.id, b.version, { starts_at: `${day}T04:30:00Z`, ends_at: `${day}T05:00:00Z`, reason_code: code });
      expect(res.status, code).toBe(200);
      b = (await res.json()).booking;
    }
    const text = await move(b.id, b.version, { starts_at: '2027-08-20T04:30:00Z', ends_at: '2027-08-20T05:00:00Z', reason_code: 'OTHER', reason: 'family wedding' });
    expect(text.status).toBe(422);
    const noCode = await move(b.id, b.version, { starts_at: '2027-08-20T04:30:00Z', ends_at: '2027-08-20T05:00:00Z' });
    expect(noCode.status).toBe(422);
    expect((await noCode.json()).error.details.field).toBe('reason_code');
  });

  it('replays a retried reschedule; a stale If-Match is a version conflict', async () => {
    const a = (await (await create({ starts_at: '2027-08-25T04:30:00Z', ends_at: '2027-08-25T05:30:00Z', confirm: true })).json()).booking;
    const body = { starts_at: '2027-08-26T04:30:00Z', ends_at: '2027-08-26T05:30:00Z', reason_code: 'PRIEST_REQUEST' };
    const first = await move(a.id, a.version, body, 'm7-int-replay-1');
    const again = await move(a.id, a.version, body, 'm7-int-replay-1');
    expect([first.status, again.status]).toEqual([200, 200]);
    expect((await again.json()).idempotent_replay).toBe(true);
    const stale = await move(a.id, a.version, { ...body, starts_at: '2027-08-27T04:30:00Z', ends_at: '2027-08-27T05:30:00Z' });
    expect(stale.status).toBe(409);
    expect((await stale.json()).error.code).toBe('VERSION_CONFLICT');
  });
});
