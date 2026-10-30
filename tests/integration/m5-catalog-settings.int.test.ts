// M5 integration: offerings, samagri templates, organization and priest settings against the throwaway database.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { adminSql, createAuthUser, enabled, makeAuthConfig, request, tokenFor } from './helpers';

const holder = vi.hoisted(() => ({ config: null as unknown }));
vi.mock('@/app/_lib/auth-config', () => ({ authConfig: () => holder.config }));

const { GET: getSession } = await import('@/app/api/v1/session/route');
const { POST: postPractice } = await import('@/app/api/v1/onboarding/practice/route');
const offerings = await import('@/app/api/v1/offerings/route');
const offering = await import('@/app/api/v1/offerings/[offeringId]/route');
const templates = await import('@/app/api/v1/samagri-templates/route');
const template = await import('@/app/api/v1/samagri-templates/[templateId]/route');
const organization = await import('@/app/api/v1/organization/route');
const priests = await import('@/app/api/v1/priests/[organizationPriestId]/route');
const { closeSql } = await import('@/db');

describe.skipIf(!enabled)('M5 catalog and settings API against a throwaway database', () => {
  const admin = enabled ? adminSql() : (null as never);
  let token: string;
  let readOnlyToken: string;
  let org: string;
  let priestLink: string;
  let key = 0;
  const nextKey = () => `m5-int-${String(++key).padStart(4, '0')}`;
  const write = (path: string, method: string, body: unknown, t = token, headers: Record<string, string> = {}) =>
    request(path, { method, token: t, tenant: org, key: nextKey(), body, headers });

  beforeAll(async () => {
    holder.config = await makeAuthConfig();
    const owner = await createAuthUser(admin, 'Owner Five');
    token = await tokenFor(owner);
    await getSession(request('/session', { token }));
    const [havan] = await admin`SELECT id FROM app.ceremony_types WHERE slug = 'havan'`;
    const res = await postPractice(
      request('/onboarding/practice', { method: 'POST', token, key: nextKey(), body: { name: 'Catalog Practice', ceremony_type_ids: [havan.id] } }),
    );
    const created = await res.json();
    org = created.organization.id;
    priestLink = created.organization_priest_id;
    const reader = await createAuthUser(admin, 'Reader Five');
    readOnlyToken = await tokenFor(reader);
    await getSession(request('/session', { token: readOnlyToken }));
    await admin`INSERT INTO app.org_members (org_id, user_id, role) VALUES (${org}, ${reader}, 'READ_ONLY')`;
  });

  afterAll(async () => {
    await closeSql();
    await admin.end();
  });

  it('adds an offering from the catalog, then changes its duration and dakshina', async () => {
    const [ct] = await admin`SELECT id FROM app.ceremony_types WHERE slug = 'satyanarayan-katha'`;
    const created = await offerings.POST(write('/offerings', 'POST', { ceremony_type_id: ct.id }));
    expect(created.status).toBe(201);
    const o = await created.json();
    expect(o).toMatchObject({ name_en: 'Satyanarayan Katha', name_hi: 'सत्यनारायण कथा', duration_min: 120, version: 1 });

    const patched = await offering.PATCH(
      write(`/offerings/${o.id}`, 'PATCH', { duration_min: 150, suggested_dakshina_paise: 510000 }, token, { 'if-match': '"1"' }),
      { params: Promise.resolve({ offeringId: o.id }) },
    );
    expect(patched.status).toBe(200);
    expect(patched.headers.get('etag')).toBe('"2"');

    const list = await (await offerings.GET(request('/offerings', { token, tenant: org }))).json();
    const saved = list.data.find((x: { id: string }) => x.id === o.id);
    expect(saved).toMatchObject({ duration_min: 150, suggested_dakshina_paise: 510000 });
    expect(typeof saved.suggested_dakshina_paise).toBe('number');
  });

  it('builds a samagri template, reorders it, and keeps the order', async () => {
    const list = await (await offerings.GET(request('/offerings', { token, tenant: org }))).json();
    const havan = list.data.find((x: { name_en: string }) => x.name_en === 'Havan');
    const items = [
      { name: 'Ghee', quantity: '1 kg', provided_by: 'FAMILY' },
      { name: 'Havan kund', provided_by: 'PRIEST' },
      { name: 'Samidha', quantity: '', provided_by: 'FAMILY' },
    ];
    const created = await templates.POST(write('/samagri-templates', 'POST', { offering_id: havan.id, items }));
    expect(created.status).toBe(201);
    const t = await created.json();

    const reordered = [items[2], items[0], items[1]];
    const put = await template.PUT(write(`/samagri-templates/${t.id}`, 'PUT', { items: reordered }, token, { 'if-match': '"1"' }), {
      params: Promise.resolve({ templateId: t.id }),
    });
    expect(put.status).toBe(200);

    const { data } = await (await templates.GET(request('/samagri-templates', { token, tenant: org }))).json();
    expect(data[0].items.map((i: { name: string }) => i.name)).toEqual(['Samidha', 'Ghee', 'Havan kund']);
    expect(data[0].items.map((i: { provided_by: string }) => i.provided_by)).toEqual(['FAMILY', 'FAMILY', 'PRIEST']);
    expect(data[0].items[0].quantity).toBeNull();

    const stale = await template.PUT(write(`/samagri-templates/${t.id}`, 'PUT', { items }, token, { 'if-match': '"1"' }), {
      params: Promise.resolve({ templateId: t.id }),
    });
    expect(stale.status).toBe(409);
  });

  it('renames the practice with If-Match; a stale version is a conflict; IST is refused', async () => {
    const ok = await organization.PATCH(write('/organization', 'PATCH', { name: 'Renamed Practice' }, token, { 'if-match': '"1"' }));
    expect(ok.status).toBe(200);
    expect((await ok.json()).name).toBe('Renamed Practice');
    const stale = await organization.PATCH(write('/organization', 'PATCH', { name: 'Again' }, token, { 'if-match': '"1"' }));
    expect(stale.status).toBe(409);
    const ist = await organization.PATCH(write('/organization', 'PATCH', { timezone: 'IST' }, token, { 'if-match': '"2"' }));
    expect(ist.status).toBe(422);
    expect((await ist.json()).error.details).toEqual({ field: 'timezone' });
  });

  it('changes the default buffers to 45/30', async () => {
    const res = await priests.PATCH(write(`/priests/${priestLink}`, 'PATCH', { default_buffer_before_min: 45, default_buffer_after_min: 30 }), {
      params: Promise.resolve({ organizationPriestId: priestLink }),
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ default_buffer_before_min: 45, default_buffer_after_min: 30 });
  });

  it('READ_ONLY can read but every edit is refused with 403', async () => {
    expect((await offerings.GET(request('/offerings', { token: readOnlyToken, tenant: org }))).status).toBe(200);
    const list = await (await offerings.GET(request('/offerings', { token: readOnlyToken, tenant: org }))).json();
    const o = list.data[0];
    const tries = [
      offerings.POST(write('/offerings', 'POST', { name_hi: 'x', name_en: 'x', duration_min: 60 }, readOnlyToken)),
      offering.PATCH(write(`/offerings/${o.id}`, 'PATCH', { duration_min: 60 }, readOnlyToken, { 'if-match': `"${o.version}"` }), {
        params: Promise.resolve({ offeringId: o.id }),
      }),
      templates.POST(write('/samagri-templates', 'POST', { offering_id: o.id, items: [] }, readOnlyToken)),
      organization.PATCH(write('/organization', 'PATCH', { name: 'x' }, readOnlyToken, { 'if-match': '"2"' })),
      priests.PATCH(write(`/priests/${priestLink}`, 'PATCH', { default_buffer_before_min: 0 }, readOnlyToken), {
        params: Promise.resolve({ organizationPriestId: priestLink }),
      }),
    ];
    for (const res of await Promise.all(tries)) {
      expect(res.status).toBe(403);
      expect((await res.json()).error.code).toBe('FORBIDDEN');
    }
  });
});
