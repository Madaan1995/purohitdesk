// M8 integration: availability (free/busy across practices), calendar blocks, against the throwaway database.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import en from '../../messages/en.json';
import hi from '../../messages/hi.json';
import { isBlockedTimeConflict } from '@/domain/booking';
import { adminSql, createAuthUser, enabled, makeAuthConfig, request, tokenFor } from './helpers';

const holder = vi.hoisted(() => ({ config: null as unknown }));
vi.mock('@/app/_lib/auth-config', () => ({ authConfig: () => holder.config }));

const { GET: getSession } = await import('@/app/api/v1/session/route');
const { POST: postPractice } = await import('@/app/api/v1/onboarding/practice/route');
const customers = await import('@/app/api/v1/customers/route');
const offerings = await import('@/app/api/v1/offerings/route');
const bookings = await import('@/app/api/v1/bookings/route');
const confirm = await import('@/app/api/v1/bookings/[bookingId]/confirm/route');
const availability = await import('@/app/api/v1/availability/route');
const blocks = await import('@/app/api/v1/blocks/route');
const block = await import('@/app/api/v1/blocks/[blockId]/route');
const { closeSql } = await import('@/db');

interface Practice {
  org: string;
  link: string;
  base: Record<string, unknown>;
}

describe.skipIf(!enabled)('M8 agenda, availability and blocks against a throwaway database', () => {
  const admin = enabled ? adminSql() : (null as never);
  let token: string;
  let readOnlyToken: string;
  let first: Practice;
  let second: Practice;
  let key = 0;
  const nextKey = () => `m8-int-${String(++key).padStart(5, '0')}`;
  const book = (p: Practice, body: Record<string, unknown>) =>
    bookings.POST(request('/bookings', { method: 'POST', token, tenant: p.org, key: nextKey(), body: { ...p.base, ...body } }));
  const avail = (p: Practice, q: string, t = token) => availability.GET(request(`/availability?${q}`, { token: t, tenant: p.org }));
  const addBlock = (p: Practice, body: Record<string, unknown>, t = token) =>
    blocks.POST(request('/blocks', { method: 'POST', token: t, tenant: p.org, key: nextKey(), body }));
  const release = (p: Practice, id: string, k = nextKey()) =>
    block.DELETE(request(`/blocks/${id}`, { method: 'DELETE', token, tenant: p.org, key: k }), { params: Promise.resolve({ blockId: id }) });

  async function practice(name: string): Promise<Practice> {
    const [havan] = await admin`SELECT id FROM app.ceremony_types WHERE slug = 'havan'`;
    const created = await (
      await postPractice(request('/onboarding/practice', { method: 'POST', token, key: nextKey(), body: { name, ceremony_type_ids: [havan.id] } }))
    ).json();
    const org = created.organization.id;
    const c = await (
      await customers.POST(request('/customers', { method: 'POST', token, tenant: org, key: nextKey(), body: { display_name: `Customer of ${name}` } }))
    ).json();
    const list = await (await offerings.GET(request('/offerings', { token, tenant: org }))).json();
    return {
      org,
      link: created.organization_priest_id,
      base: { customer_id: c.customer.id, offering_id: list.data[0].id, priest_ids: [created.organization_priest_id], buffer_before_min: 0, buffer_after_min: 0 },
    };
  }

  beforeAll(async () => {
    holder.config = await makeAuthConfig();
    const owner = await createAuthUser(admin, 'Owner Eight');
    token = await tokenFor(owner);
    await getSession(request('/session', { token }));
    first = await practice('Agenda Practice One');
    second = await practice('Agenda Practice Two');
    const reader = await createAuthUser(admin, 'Reader Eight');
    readOnlyToken = await tokenFor(reader);
    await getSession(request('/session', { token: readOnlyToken }));
    await admin`INSERT INTO app.org_members (org_id, user_id, role) VALUES (${first.org}, ${reader}, 'READ_ONLY')`;
  });

  afterAll(async () => {
    await closeSql();
    await admin.end();
  });

  it('shows the other practice\'s booking as BUSY without any details', async () => {
    const other = await book(second, { starts_at: '2027-10-05T04:30:00Z', ends_at: '2027-10-05T05:30:00Z', title: 'Secret title', confirm: true });
    expect(other.status).toBe(201);
    const otherId = (await other.json()).booking.id;
    await book(first, { starts_at: '2027-10-05T08:30:00Z', ends_at: '2027-10-05T09:30:00Z', confirm: true });

    const res = await avail(first, `priest_id=${first.link}&from=2027-10-05&to=2027-10-05`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).not.toContain(otherId);
    expect(text).not.toContain('Secret');
    const body = JSON.parse(text);
    expect(body).toMatchObject({ priest_id: first.link, timezone: 'Asia/Kolkata', from: '2027-10-05', to: '2027-10-05' });
    expect(body.busy).toEqual([
      { kind: 'BUSY', starts_at: '2027-10-05T04:30:00.000Z', ends_at: '2027-10-05T05:30:00.000Z', same_org: false },
      expect.objectContaining({ kind: 'BOOKING', starts_at: '2027-10-05T08:30:00.000Z', same_org: true, booking_id: expect.any(String) }),
    ]);
  });

  it('limits availability to 62 days and to this practice\'s priests', async () => {
    expect((await avail(first, `priest_id=${first.link}&from=2027-10-01&to=2027-12-01`)).status).toBe(200);
    const long = await avail(first, `priest_id=${first.link}&from=2027-10-01&to=2027-12-02`);
    expect(long.status).toBe(422);
    const foreign = await avail(first, `priest_id=${second.link}&from=2027-10-01&to=2027-10-02`);
    expect(foreign.status).toBe(404);
    expect((await avail(first, `priest_id=${first.link}&from=2027-10-01&to=2027-10-02`, readOnlyToken)).status).toBe(200);
  });

  it('block 2-4 pm: a booking in that window is refused; release the block; the booking confirms', async () => {
    const created = await addBlock(first, { priest_id: first.link, starts_at: '2027-10-06T08:30:00Z', ends_at: '2027-10-06T10:30:00Z', note: 'Family function' });
    expect(created.status).toBe(201);
    const { block: b } = await created.json();
    expect(b).toMatchObject({ status: 'ACTIVE', note: 'Family function', starts_at: '2027-10-06T08:30:00+00:00' });

    const draft = (await (await book(first, { starts_at: '2027-10-06T09:00:00Z', ends_at: '2027-10-06T10:00:00Z' })).json()).booking;
    const send = () =>
      confirm.POST(
        request(`/bookings/${draft.id}/confirm`, { method: 'POST', token, tenant: first.org, key: nextKey(), body: {}, headers: { 'if-match': '"1"' } }),
        { params: Promise.resolve({ bookingId: draft.id }) },
      );
    const refused = await send();
    expect(refused.status).toBe(409);
    expect((await refused.json()).error.details.conflicts).toEqual([
      expect.objectContaining({ starts_at: '2027-10-06T08:30:00+00:00', same_org: true, block: true }),
    ]);

    const released = await release(first, b.id);
    expect(released.status).toBe(200);
    const releasedBlock = (await released.json()).block;
    expect(releasedBlock).toMatchObject({ status: 'RELEASED', released_by: expect.any(String), released_at: expect.any(String) });
    const [audit] = await admin`SELECT actor_user_id, data FROM app.audit_log WHERE action = 'BLOCK_RELEASED' AND target_id = ${b.id}`;
    expect(audit.actor_user_id).toBe(releasedBlock.released_by);
    expect(audit.data).toEqual({ organization_priest_id: first.link, starts_at: '2027-10-06T08:30:00+00:00', ends_at: '2027-10-06T10:30:00+00:00' });
    expect(JSON.stringify(audit.data)).not.toContain('Family');
    expect((await release(first, b.id)).status).toBe(409);
    expect((await send()).status).toBe(200);
  });

  it('a block over a block is a 409 BOOKING_CONFLICT listing the existing block ("time is blocked")', async () => {
    const existing = await addBlock(first, { priest_id: first.link, starts_at: '2027-10-10T04:30:00Z', ends_at: '2027-10-10T06:30:00Z', note: 'Yatra' });
    expect(existing.status).toBe(201);
    const over = await addBlock(first, { priest_id: first.link, starts_at: '2027-10-10T05:00:00Z', ends_at: '2027-10-10T07:00:00Z' });
    expect(over.status).toBe(409);
    const { error } = await over.json();
    expect(error.code).toBe('BOOKING_CONFLICT');
    expect(error.details.conflicts).toEqual([
      { organization_priest_id: first.link, starts_at: '2027-10-10T04:30:00+00:00', ends_at: '2027-10-10T06:30:00+00:00', same_org: true, block: true },
    ]);
    // The form shows bookings.blockedTime for exactly this response.
    expect(isBlockedTimeConflict(error.details.conflicts)).toBe(true);
    expect(hi.bookings.blockedTime).toBe('इस समय पंडित जी ने समय रोका हुआ है।');
    expect(en.bookings.blockedTime).toBe('The priest has blocked this time.');

    // The same human's block in the other practice: busy time only, no block flag, no ids, no note.
    const foreign = await addBlock(second, { priest_id: second.link, starts_at: '2027-10-10T06:00:00Z', ends_at: '2027-10-10T06:15:00Z' });
    expect(foreign.status).toBe(409);
    const text = await foreign.text();
    expect(text).not.toContain('Yatra');
    expect(JSON.parse(text).error.details.conflicts).toEqual([
      { organization_priest_id: second.link, starts_at: '2027-10-10T04:30:00+00:00', ends_at: '2027-10-10T06:30:00+00:00', same_org: false },
    ]);
    expect(isBlockedTimeConflict(JSON.parse(text).error.details.conflicts)).toBe(false);
  });

  it('a block in one practice keeps the same priest out in the other, anonymously', async () => {
    await addBlock(second, { priest_id: second.link, starts_at: '2027-10-07T04:30:00Z', ends_at: '2027-10-07T06:30:00Z', note: 'Private' });
    const res = await book(first, { starts_at: '2027-10-07T05:00:00Z', ends_at: '2027-10-07T06:00:00Z', confirm: true });
    expect(res.status).toBe(409);
    const { error } = await res.json();
    expect(error.details.conflicts).toEqual([
      { organization_priest_id: first.link, starts_at: '2027-10-07T04:30:00+00:00', ends_at: '2027-10-07T06:30:00+00:00', same_org: false },
    ]);
  });

  it('READ_ONLY cannot block; a replayed block returns the first; a DELETE replays too', async () => {
    const ro = await addBlock(first, { priest_id: first.link, starts_at: '2027-10-08T04:30:00Z', ends_at: '2027-10-08T05:30:00Z' }, readOnlyToken);
    expect(ro.status).toBe(403);
    const body = { priest_id: first.link, starts_at: '2027-10-09T04:30:00Z', ends_at: '2027-10-09T05:30:00Z' };
    const a = await blocks.POST(request('/blocks', { method: 'POST', token, tenant: first.org, key: 'm8-int-replay-1', body }));
    const b = await blocks.POST(request('/blocks', { method: 'POST', token, tenant: first.org, key: 'm8-int-replay-1', body }));
    expect([a.status, b.status]).toEqual([201, 200]);
    const id = (await a.json()).block.id;
    expect((await b.json()).block.id).toBe(id);
    const d1 = await release(first, id, 'm8-int-replay-2');
    const d2 = await release(first, id, 'm8-int-replay-2');
    expect([d1.status, d2.status]).toEqual([200, 200]);
    expect((await d2.json()).idempotent_replay).toBe(true);
  });
});
