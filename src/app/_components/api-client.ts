// Browser-side calls to /api/v1 (the httpOnly session cookie authenticates them). Never throws: returns the error code.

export type WriteResult<T> = { ok: true; data: T } | { ok: false; code: string; field?: string };

export async function apiWrite<T>(
  path: string,
  init: { method: 'POST' | 'PATCH' | 'PUT'; tenantId: string; idempotencyKey: string; body: unknown; ifMatch?: number },
): Promise<WriteResult<T>> {
  try {
    const res = await fetch(`/api/v1${path}`, {
      method: init.method,
      headers: {
        'content-type': 'application/json',
        'x-tenant-id': init.tenantId,
        'idempotency-key': init.idempotencyKey,
        ...(init.ifMatch !== undefined ? { 'if-match': `"${init.ifMatch}"` } : {}),
      },
      body: JSON.stringify(init.body),
    });
    const json = await res.json();
    if (res.ok) return { ok: true, data: json as T };
    return { ok: false, code: json?.error?.code ?? 'INTERNAL', field: json?.error?.details?.field };
  } catch {
    return { ok: false, code: 'NETWORK' };
  }
}
