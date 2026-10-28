// M4 integration: customer routes against the throwaway database as app_runtime.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { adminSql, createAuthUser, enabled, makeAuthConfig, request, tokenFor } from './helpers';

const holder = vi.hoisted(() => ({ config: null as unknown }));
vi.mock('@/app/_lib/auth-config', () => ({ authConfig: () => holder.config }));

const { GET: getSession } = await import('@/app/api/v1/session/route');
const { POST: postPractice } = await import('@/app/api/v1/onboarding/practice/route');
const customers = await import('@/app/api/v1/customers/route');
const customer = await import('@/app/api/v1/customers/[customerId]/route');
const { closeSql } = await import('@/db');

const params = (customerId: string) => ({ params: Promise.resolve({ customerId }) });

describe.skipIf(!enabled)('M4 customers API against a throwaway database', () => {
  const admin = enabled ? adminSql() : (null as never);
  let owner: string;
  let token: string;
  let org: string;
  let otherToken: string;
  let otherOrg: string;
  let readOnlyToken: string;
  let key = 0;
  const nextKey = () => `cust-int-${String(++key).padStart(4, '0')}`;

  async function practice(name: string, t: string): Promise<string> {
    await getSession(request('/session', { token: t }));
    const [ceremony] = await admin`SELECT id FROM app.ceremony_types WHERE slug = 'havan'`;
    const res = await postPractice(
      request('/onboarding/practice', { method: 'POST', token: t, key: nextKey(), body: { name, ceremony_type_ids: [ceremony.id] } }),
    );
    return (await res.json()).organization.id;
  }

  async function create(body: unknown, t = token, tenant = org) {
    return customers.POST(request('/customers', { method: 'POST', token: t, tenant, key: nextKey(), body }));
  }

  beforeAll(async () => {
    holder.config = await makeAuthConfig();
    owner = await createAuthUser(admin, 'Owner Four');
    token = await tokenFor(owner);
    org = await practice('Customers Practice', token);
    const other = await createAuthUser(admin, 'Other Four');
    otherToken = await tokenFor(other);
    otherOrg = await practice('Other Practice', otherToken);
    const readOnly = await createAuthUser(admin, 'Reader Four');
    readOnlyToken = await tokenFor(readOnly);
    await getSession(request('/session', { token: readOnlyToken }));
    await admin`INSERT INTO app.org_members (org_id, user_id, role) VALUES (${org}, ${readOnly}, 'READ_ONLY')`;
  });

  afterAll(async () => {
    await closeSql();
    await admin.end();
  });

  it('POST creates a customer without a phone: 201 + ETag', async () => {
    const res = await create({ display_name: 'Ramesh Sharma' });
    expect(res.status).toBe(201);
    expect(res.headers.get('etag')).toBe('"1"');
    const body = await res.json();
    expect(body.customer).toMatchObject({ display_name: 'Ramesh Sharma', phone_e164: null, version: 1 });
    expect(body.possible_duplicates).toEqual([]);
  });

  it('two customers with the same phone are both saved, with a duplicate warning', async () => {
    const first = await (await create({ display_name: 'Suresh Verma', phone: '98765 43210' })).json();
    expect(first.customer.phone_e164).toBe('+919876543210');
    const second = await (await create({ display_name: 'Sunita Verma', phone: '+91 98765-43210' })).json();
    expect(second.possible_duplicates).toEqual([{ id: first.customer.id, display_name: 'Suresh Verma' }]);
  });

  it('an invalid phone is a 422 on the phone field', async () => {
    const res = await create({ display_name: 'X', phone: '12345' });
    expect(res.status).toBe(422);
    expect((await res.json()).error.details).toEqual({ field: 'phone' });
  });

  it('search: "Sha" finds "Ramesh Sharma" (word prefix), phone finds by number or digits', async () => {
    const byName = await (await customers.GET(request('/customers?q=Sha', { token, tenant: org }))).json();
    expect(byName.data.map((c: { display_name: string }) => c.display_name)).toEqual(['Ramesh Sharma']);
    const byPhone = await (await customers.GET(request('/customers?q=09876543210', { token, tenant: org }))).json();
    expect(byPhone.data).toHaveLength(2);
    const byDigits = await (await customers.GET(request('/customers?q=4321', { token, tenant: org }))).json();
    expect(byDigits.data).toHaveLength(2);
    const literal = await (await customers.GET(request('/customers?q=%25', { token, tenant: org }))).json();
    expect(literal.data).toHaveLength(0);
  });

  it('keyset pagination walks every customer exactly once', async () => {
    for (const name of ['Amit', 'Bharat', 'Chetan', 'Deepak', 'शर्मा जी']) await create({ display_name: name });
    const seen: string[] = [];
    let cursor: string | null = null;
    let pages = 0;
    do {
      const url: string = `/customers?limit=3${cursor ? `&cursor=${cursor}` : ''}`;
      const page = await (await customers.GET(request(url, { token, tenant: org }))).json();
      seen.push(...page.data.map((c: { id: string }) => c.id));
      cursor = page.next_cursor;
      pages += 1;
    } while (cursor && pages < 10);
    expect(pages).toBe(3);
    expect(new Set(seen).size).toBe(8);
    expect(seen).toHaveLength(8);
    const bad = await customers.GET(request('/customers?cursor=garbage!', { token, tenant: org }));
    expect(bad.status).toBe(422);
  });

  it('GET by id returns the customer with an ETag; PATCH needs If-Match and detects stale versions', async () => {
    const { customer: c } = await (await create({ display_name: 'Edit Me' })).json();
    const got = await customer.GET(request(`/customers/${c.id}`, { token, tenant: org }), params(c.id));
    expect(got.status).toBe(200);
    expect(got.headers.get('etag')).toBe('"1"');

    const noIfMatch = await customer.PATCH(
      request(`/customers/${c.id}`, { method: 'PATCH', token, tenant: org, key: nextKey(), body: { address: 'Sector 70' } }),
      params(c.id),
    );
    expect(noIfMatch.status).toBe(422);
    expect((await noIfMatch.json()).error.reason).toBe('IF_MATCH_REQUIRED');

    const tabA = await customer.PATCH(
      request(`/customers/${c.id}`, {
        method: 'PATCH', token, tenant: org, key: nextKey(), body: { address: 'Sector 70' }, headers: { 'if-match': '"1"' },
      }),
      params(c.id),
    );
    expect(tabA.status).toBe(200);
    expect(tabA.headers.get('etag')).toBe('"2"');

    const tabB = await customer.PATCH(
      request(`/customers/${c.id}`, {
        method: 'PATCH', token, tenant: org, key: nextKey(), body: { address: 'Zirakpur' }, headers: { 'if-match': '"1"' },
      }),
      params(c.id),
    );
    expect(tabB.status).toBe(409);
    expect((await tabB.json()).error).toMatchObject({ code: 'VERSION_CONFLICT', details: { current_version: 2 } });
  });

  it('READ_ONLY can list but not create (403)', async () => {
    expect((await customers.GET(request('/customers', { token: readOnlyToken, tenant: org }))).status).toBe(200);
    expect((await create({ display_name: 'Nope' }, readOnlyToken)).status).toBe(403);
  });

  it("another practice cannot see or touch this practice's customers", async () => {
    const list = await (await customers.GET(request('/customers', { token: otherToken, tenant: otherOrg }))).json();
    expect(list.data).toEqual([]);
    const forged = await customers.GET(request('/customers', { token: otherToken, tenant: org }));
    expect(forged.status).toBe(404);
    const { data } = await (await customers.GET(request('/customers?limit=1', { token, tenant: org }))).json();
    const cross = await customer.GET(request(`/customers/${data[0].id}`, { token: otherToken, tenant: otherOrg }), params(data[0].id));
    expect(cross.status).toBe(404);
  });
});
