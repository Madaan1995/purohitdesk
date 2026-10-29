// M2 integration: route handlers -> withTenantTx -> postgres.js -> app_runtime login -> RLS + commands.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { adminSql, createAuthUser, enabled, makeAuthConfig, request, tokenFor } from './helpers';

const holder = vi.hoisted(() => ({ config: null as unknown }));
vi.mock('@/app/_lib/auth-config', () => ({ authConfig: () => holder.config }));

const { GET: getSession } = await import('@/app/api/v1/session/route');
const { PATCH: patchMe } = await import('@/app/api/v1/me/route');
const { POST: postPractice } = await import('@/app/api/v1/onboarding/practice/route');
const { GET: getCeremonyTypes } = await import('@/app/api/v1/ceremony-types/route');
const { GET: getOrganization } = await import('@/app/api/v1/organization/route');
const { closeSql } = await import('@/db');

describe.skipIf(!enabled)('M2 API against a throwaway database', () => {
  const admin = enabled ? adminSql() : (null as never);
  let owner: string;
  let ownerToken: string;
  let other: string;
  let otherToken: string;
  let orgId: string;
  let ceremonyIds: string[];

  beforeAll(async () => {
    holder.config = await makeAuthConfig();
    owner = await createAuthUser(admin, 'Ramesh Sharma');
    other = await createAuthUser(admin, 'Second Pandit');
    ownerToken = await tokenFor(owner, 'Ramesh Sharma');
    otherToken = await tokenFor(other, 'Second Pandit');
    ceremonyIds = (await admin`SELECT id FROM app.ceremony_types WHERE slug IN ('havan', 'vivah') ORDER BY slug`).map(
      (r) => r.id as string,
    );
  });

  afterAll(async () => {
    await closeSql();
    await admin.end();
  });

  it('401 without a token, with an error envelope and request id', async () => {
    const res = await getSession(request('/session'));
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.error).toMatchObject({ code: 'UNAUTHENTICATED', reason: 'TOKEN_MISSING' });
    expect(body.error.request_id).toMatch(/^[0-9a-f-]{36}$/);
  });

  it('401 with a modified token', async () => {
    const [h, p, s] = ownerToken.split('.');
    const tampered = `${h}.${p.slice(0, -2)}AA.${s}`;
    expect((await getSession(request('/session', { token: tampered }))).status).toBe(401);
  });

  it('first GET /session creates the user with the cookie language and no memberships', async () => {
    const res = await getSession(request('/session', { token: ownerToken, headers: { cookie: 'NEXT_LOCALE=en' } }));
    expect(res.status).toBe(200);
    expect(res.headers.get('cache-control')).toBe('no-store');
    expect(await res.json()).toEqual({
      user: { id: owner, display_name: 'Ramesh Sharma', preferred_locale: 'en' },
      memberships: [],
    });
  });

  it('onboarding requires an Idempotency-Key', async () => {
    const res = await postPractice(
      request('/onboarding/practice', { method: 'POST', token: ownerToken, body: { name: 'X', ceremony_type_ids: ceremonyIds } }),
    );
    expect(res.status).toBe(422);
    expect((await res.json()).error).toMatchObject({ code: 'VALIDATION_FAILED', reason: 'IDEMPOTENCY_KEY_REQUIRED' });
  });

  it('onboarding rejects unknown fields', async () => {
    const res = await postPractice(
      request('/onboarding/practice', {
        method: 'POST',
        token: ownerToken,
        key: 'unknown-field-1',
        body: { name: 'X', ceremony_type_ids: ceremonyIds, slug: 'mine' },
      }),
    );
    expect(res.status).toBe(422);
  });

  it('onboarding creates a practice; a retry with the same key returns the same practice', async () => {
    const body = { name: 'Sharma Ji Pooja', ceremony_type_ids: ceremonyIds };
    const first = await postPractice(request('/onboarding/practice', { method: 'POST', token: ownerToken, key: 'onboard-int-0001', body }));
    expect(first.status).toBe(201);
    const created = await first.json();
    expect(created).toMatchObject({ role: 'OWNER', offering_count: 2, idempotent_replay: false });
    orgId = created.organization.id;

    const reordered = { ceremony_type_ids: ceremonyIds, name: 'Sharma Ji Pooja' };
    const retry = await postPractice(
      request('/onboarding/practice', { method: 'POST', token: ownerToken, key: 'onboard-int-0001', body: reordered }),
    );
    expect(retry.status).toBe(200);
    const replayed = await retry.json();
    expect(replayed.organization.id).toBe(orgId);
    expect(replayed.idempotent_replay).toBe(true);

    const changed = await postPractice(
      request('/onboarding/practice', { method: 'POST', token: ownerToken, key: 'onboard-int-0001', body: { ...body, name: 'Other' } }),
    );
    expect(changed.status).toBe(409);
    expect((await changed.json()).error.code).toBe('IDEMPOTENCY_REUSE');
  });

  it('GET /session lists the practice with role OWNER and its permissions', async () => {
    const res = await getSession(request('/session', { token: ownerToken }));
    const session = await res.json();
    expect(session.memberships).toHaveLength(1);
    expect(session.memberships[0]).toMatchObject({
      organization: { id: orgId, name: 'Sharma Ji Pooja', kind: 'SOLO', timezone: 'Asia/Kolkata' },
      role: 'OWNER',
    });
    expect(session.memberships[0].permissions).toHaveLength(20);
    expect(session.memberships[0].permissions).toContain('MEMBER_MANAGE');
  });

  it('GET /organization returns the tenant with an ETag', async () => {
    const res = await getOrganization(request('/organization', { token: ownerToken, tenant: orgId }));
    expect(res.status).toBe(200);
    expect(res.headers.get('etag')).toBe('"1"');
    expect(await res.json()).toMatchObject({ id: orgId, plan: 'PILOT', status: 'ACTIVE', version: 1 });
  });

  it('GET /organization without X-Tenant-ID is a validation error', async () => {
    const res = await getOrganization(request('/organization', { token: ownerToken }));
    expect(res.status).toBe(422);
    expect((await res.json()).error.reason).toBe('TENANT_REQUIRED');
  });

  it("a non-member asking for another practice's id gets 404, not 403", async () => {
    await getSession(request('/session', { token: otherToken }));
    const res = await getOrganization(request('/organization', { token: otherToken, tenant: orgId }));
    expect(res.status).toBe(404);
    expect((await res.json()).error.code).toBe('NOT_FOUND');
  });

  it('a revoked member is denied on the very next request (API-SEC-3)', async () => {
    await admin`INSERT INTO app.org_members (org_id, user_id, role) VALUES (${orgId}, ${other}, 'STAFF')`;
    const before = await getOrganization(request('/organization', { token: otherToken, tenant: orgId }));
    expect(before.status).toBe(200);
    const staff = await (await getSession(request('/session', { token: otherToken }))).json();
    expect(staff.memberships[0].role).toBe('STAFF');
    expect(staff.memberships[0].permissions).not.toContain('BOOKING_CONFIRM');

    await admin`UPDATE app.org_members SET status = 'REVOKED' WHERE org_id = ${orgId} AND user_id = ${other}`;
    const after = await getOrganization(request('/organization', { token: otherToken, tenant: orgId }));
    expect(after.status).toBe(404);
  });

  it('GET /ceremony-types returns the 20 seeded ceremonies with both names', async () => {
    const res = await getCeremonyTypes(request('/ceremony-types', { token: ownerToken }));
    const { data } = await res.json();
    expect(data).toHaveLength(20);
    expect(data.find((c: { slug: string }) => c.slug === 'havan')).toMatchObject({ name_hi: 'हवन', default_duration_min: 90 });
  });

  it('PATCH /me saves the language and sets the language cookie', async () => {
    const res = await patchMe(request('/me', { method: 'PATCH', token: ownerToken, body: { preferred_locale: 'hi' } }));
    expect(res.status).toBe(200);
    expect((await res.json()).preferred_locale).toBe('hi');
    expect(res.headers.get('set-cookie')).toContain('NEXT_LOCALE=hi');
    const bad = await patchMe(request('/me', { method: 'PATCH', token: ownerToken, body: { preferred_locale: 'pa' } }));
    expect(bad.status).toBe(422);
  });

  it('pooled connections never leak a tenant: 60 interleaved requests from two practices', async () => {
    const third = await createAuthUser(admin, 'Third Pandit');
    const thirdToken = await tokenFor(third);
    await getSession(request('/session', { token: thirdToken }));
    const res = await postPractice(
      request('/onboarding/practice', {
        method: 'POST',
        token: thirdToken,
        key: 'onboard-int-0003',
        body: { name: 'Third', ceremony_type_ids: ceremonyIds },
      }),
    );
    const thirdOrg = (await res.json()).organization.id;

    const calls = Array.from({ length: 60 }, (_, i) =>
      i % 2 === 0
        ? getOrganization(request('/organization', { token: ownerToken, tenant: orgId })).then(async (r) => [orgId, (await r.json()).id])
        : getOrganization(request('/organization', { token: thirdToken, tenant: thirdOrg })).then(async (r) => [thirdOrg, (await r.json()).id]),
    );
    for (const [expected, got] of await Promise.all(calls)) expect(got).toBe(expected);
  });
});
