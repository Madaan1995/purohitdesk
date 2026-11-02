// Customer reads (SELECT under RLS as app_runtime), shared by the API routes and the pages.
import type { Tx } from '@/db';
import { decodeCursor, encodeCursor } from '@/domain/cursor';
import { normalizeIndianPhone, phoneDigits } from '@/domain/phone';

export interface Customer {
  id: string;
  display_name: string;
  phone_e164: string | null;
  address: string | null;
  acquisition_source: 'PRIEST_DIRECT' | 'IMPORT';
  version: number;
  created_at: string;
  updated_at: string;
}

export interface CustomerCommandResult {
  customer: Customer;
  possible_duplicates: { id: string; display_name: string }[];
  idempotent_replay: boolean;
}

export class BadCursorError extends Error {}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (c) => `\\${c}`);
}

/**
 * Keyset page of the current tenant's customers, sorted by lower(name), id.
 * q: an Indian phone → exact match; ≥ 4 digits only → phone contains; otherwise any word of the name starts with q.
 */
export async function listCustomers(
  tx: Tx,
  params: { q?: string; limit: number; cursor?: string },
): Promise<{ data: Customer[]; next_cursor: string | null }> {
  const after = params.cursor ? decodeCursor(params.cursor) : null;
  if (params.cursor && !after) throw new BadCursorError();

  const q = params.q?.trim() || '';
  const phone = q ? normalizeIndianPhone(q) : null;
  const digits = /^[\d\s+\-()]+$/.test(q) ? phoneDigits(q) : '';
  const mode = !q ? 'all' : phone ? 'phone' : digits.length >= 4 ? 'digits' : 'name';
  const prefix = `${escapeLike(q.toLowerCase())}%`;

  const rows = await tx<(Customer & { sort_key: string })[]>`
    SELECT id, display_name, phone_e164, address, acquisition_source, version, created_at, updated_at,
           lower(display_name) AS sort_key
    FROM app.customers
    WHERE org_id = app.current_tenant_id() AND erased_at IS NULL
      AND (${mode} = 'all'
           OR (${mode} = 'phone' AND phone_e164 = ${phone})
           OR (${mode} = 'digits' AND phone_e164 LIKE '%' || ${digits} || '%')
           OR (${mode} = 'name' AND (lower(display_name) LIKE ${prefix} ESCAPE '\\'
                                     OR lower(display_name) LIKE '% ' || ${prefix} ESCAPE '\\')))
      AND (${after?.[0] ?? null}::text IS NULL
           OR (lower(display_name), id) > (${after?.[0] ?? null}::text, ${after?.[1] ?? null}::uuid))
    ORDER BY lower(display_name), id
    LIMIT ${params.limit + 1}`;

  const page = rows.slice(0, params.limit);
  const last = page[page.length - 1];
  return {
    data: page.map((r) => ({
      id: r.id,
      display_name: r.display_name,
      phone_e164: r.phone_e164,
      address: r.address,
      acquisition_source: r.acquisition_source,
      version: r.version,
      created_at: r.created_at,
      updated_at: r.updated_at,
    })),
    next_cursor: rows.length > params.limit && last ? encodeCursor([last.sort_key, last.id]) : null,
  };
}

export async function getCustomer(tx: Tx, id: string): Promise<Customer | null> {
  const [row] = await tx<Customer[]>`
    SELECT id, display_name, phone_e164, address, acquisition_source, version, created_at, updated_at
    FROM app.customers
    WHERE id = ${id} AND org_id = app.current_tenant_id() AND erased_at IS NULL`;
  return row ?? null;
}

/** Other customers of the practice with the same phone (shown as a warning; both records are kept). */
export async function samePhoneCustomers(tx: Tx, customer: Customer): Promise<{ id: string; display_name: string }[]> {
  if (!customer.phone_e164) return [];
  return [
    ...(await tx<{ id: string; display_name: string }[]>`
      SELECT id, display_name FROM app.customers
      WHERE org_id = app.current_tenant_id() AND phone_e164 = ${customer.phone_e164}
        AND id <> ${customer.id} AND erased_at IS NULL
      ORDER BY created_at, id`),
  ];
}
