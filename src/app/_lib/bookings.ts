// Booking reads (SELECT under RLS as app_runtime, and app.get_booking), shared by the API routes and the pages.
import { DomainError, type Tx } from '@/db';
import type { Booking, BookingStatus } from '@/domain/booking';
import { decodeCursor, encodeCursor } from '@/domain/cursor';
import { apiError } from '@/domain/errors';
import type { ListBookingsQuery } from '@/domain/schemas/bookings';

export interface BookingSummary {
  id: string;
  booking_number: string;
  status: BookingStatus;
  customer: { id: string; display_name: string };
  offering: { id: string; name_hi: string; name_en: string };
  title: string | null;
  local_date: string;
  starts_at: string | null;
  ends_at: string | null;
  timezone: string;
  is_time_tentative: boolean;
  version: number;
}

export class BadCursorError extends Error {}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const bookingNotFound = () => new DomainError(apiError('NOT_FOUND', { details: { resource: 'booking' } }));

/** Keyset page of the current tenant's bookings, sorted by (local_date, seq_no). */
export async function listBookings(
  tx: Tx,
  q: Pick<ListBookingsQuery, 'status' | 'customer_id' | 'from' | 'to' | 'limit' | 'cursor'>,
): Promise<{ data: BookingSummary[]; next_cursor: string | null }> {
  const after = q.cursor ? decodeCursor(q.cursor) : null;
  if (q.cursor && !after) throw new BadCursorError();
  const [afterDate, afterSeq] = after ? after[0].split('/') : [null, null];
  if (after && (!/^\d{4}-\d{2}-\d{2}$/.test(afterDate ?? '') || !/^\d{1,18}$/.test(afterSeq ?? ''))) {
    throw new BadCursorError();
  }

  const rows = await tx<(BookingSummary & { seq_no: string })[]>`
    SELECT b.id, b.booking_number, b.status, b.title, to_char(b.local_date, 'YYYY-MM-DD') AS local_date,
           b.starts_at, b.ends_at, b.timezone, b.is_time_tentative, b.version, b.seq_no::text AS seq_no,
           jsonb_build_object('id', c.id, 'display_name', c.display_name) AS customer,
           jsonb_build_object('id', o.id, 'name_hi', o.name_hi, 'name_en', o.name_en) AS offering
    FROM app.bookings b
    JOIN app.customers c ON c.id = b.customer_id AND c.org_id = b.org_id
    JOIN app.offerings o ON o.id = b.offering_id AND o.org_id = b.org_id
    WHERE b.org_id = app.current_tenant_id()
      AND (${q.status ?? null}::text IS NULL OR b.status = ${q.status ?? null})
      AND (${q.customer_id ?? null}::uuid IS NULL OR b.customer_id = ${q.customer_id ?? null})
      AND (${q.from ?? null}::date IS NULL OR b.local_date >= ${q.from ?? null}::date)
      AND (${q.to ?? null}::date IS NULL OR b.local_date <= ${q.to ?? null}::date)
      AND (${afterDate}::date IS NULL OR (b.local_date, b.seq_no) > (${afterDate}::date, ${afterSeq}::bigint))
    ORDER BY b.local_date, b.seq_no
    LIMIT ${q.limit + 1}`;

  const page = rows.slice(0, q.limit);
  const last = page[page.length - 1];
  return {
    data: page.map((r) => ({
      id: r.id,
      booking_number: r.booking_number,
      status: r.status,
      customer: r.customer,
      offering: r.offering,
      title: r.title,
      local_date: r.local_date,
      starts_at: r.starts_at ? new Date(r.starts_at).toISOString() : null,
      ends_at: r.ends_at ? new Date(r.ends_at).toISOString() : null,
      timezone: r.timezone,
      is_time_tentative: r.is_time_tentative,
      version: r.version,
    })),
    next_cursor: rows.length > q.limit && last ? encodeCursor([`${last.local_date}/${last.seq_no}`, last.id]) : null,
  };
}

export async function getBooking(tx: Tx, id: string): Promise<Booking | null> {
  const [row] = await tx<{ result: Booking | null }[]>`SELECT app.get_booking(${id}::uuid) AS result`;
  return row?.result ?? null;
}

/** The practice's priest links (for the booking form). */
export async function listPriests(tx: Tx): Promise<{ id: string; display_name: string; priest_profile_id: string }[]> {
  return [
    ...(await tx<{ id: string; display_name: string; priest_profile_id: string }[]>`
      SELECT op.id, p.display_name, op.priest_profile_id FROM app.organization_priests op
      JOIN app.priest_profiles p ON p.id = op.priest_profile_id
      WHERE op.org_id = app.current_tenant_id()
      ORDER BY op.created_at, op.id`),
  ];
}
