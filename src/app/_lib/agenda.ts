// Agenda reads (spec §01 §3): the practice's bookings with a time, its own blocks (with notes, under RLS), other
// practices' busy time through app.priest_busy (anonymous), and date-only drafts still to be timed.
import type { Tx } from '@/db';
import type { BookingStatus } from '@/domain/booking';
import { listPriests } from './bookings';

export interface Block {
  id: string;
  organization_priest_id: string;
  starts_at: string;
  ends_at: string;
  note: string | null;
  status: 'ACTIVE' | 'RELEASED';
  created_at: string;
  released_at: string | null;
}

export interface BusySpan {
  kind: 'BOOKING' | 'BLOCK' | 'BUSY';
  starts_at: string;
  ends_at: string;
  same_org: boolean;
  booking_id: string | null;
  reservation_id: string | null;
}

export interface AgendaBooking {
  id: string;
  booking_number: string;
  status: BookingStatus;
  starts_at: string;
  ends_at: string;
  timezone: string;
  is_time_tentative: boolean;
  customer_name: string;
  offering_hi: string;
  offering_en: string;
}

export interface AgendaBlock {
  id: string;
  organization_priest_id: string;
  priest_name: string;
  starts_at: string;
  ends_at: string;
  note: string | null;
}

export interface AgendaBusy {
  organization_priest_id: string;
  priest_name: string;
  starts_at: string;
  ends_at: string;
}

const iso = (v: string | Date) => new Date(v).toISOString();

export async function priestBusy(tx: Tx, priestId: string, from: Date, to: Date): Promise<BusySpan[]> {
  const rows = await tx<BusySpan[]>`
    SELECT reservation_id, kind, starts_at, ends_at, same_org, booking_id
    FROM app.priest_busy(${priestId}::uuid, ${from.toISOString()}::timestamptz, ${to.toISOString()}::timestamptz)`;
  return rows.map((r) => ({ ...r, starts_at: iso(r.starts_at), ends_at: iso(r.ends_at) }));
}

export async function loadAgenda(tx: Tx, from: Date, to: Date, todayLocal: string) {
  const bookings = (
    await tx<AgendaBooking[]>`
      SELECT b.id, b.booking_number, b.status, b.starts_at, b.ends_at, b.timezone, b.is_time_tentative,
             c.display_name AS customer_name, o.name_hi AS offering_hi, o.name_en AS offering_en
      FROM app.bookings b
      JOIN app.customers c ON c.id = b.customer_id AND c.org_id = b.org_id
      JOIN app.offerings o ON o.id = b.offering_id AND o.org_id = b.org_id
      WHERE b.org_id = app.current_tenant_id() AND b.status <> 'CANCELLED' AND b.starts_at IS NOT NULL
        AND b.starts_at < ${to.toISOString()}::timestamptz AND b.ends_at > ${from.toISOString()}::timestamptz
      ORDER BY b.starts_at, b.seq_no`
  ).map((b) => ({ ...b, starts_at: iso(b.starts_at), ends_at: iso(b.ends_at) }));

  const priests = await listPriests(tx);
  const blocks: AgendaBlock[] = [];
  const busy: AgendaBusy[] = [];
  for (const p of priests) {
    const spans = await priestBusy(tx, p.id, from, to);
    for (const s of spans.filter((x) => !x.same_org)) {
      busy.push({ organization_priest_id: p.id, priest_name: p.display_name, starts_at: s.starts_at, ends_at: s.ends_at });
    }
    const blockIds = spans.filter((x) => x.kind === 'BLOCK' && x.reservation_id).map((x) => x.reservation_id as string);
    if (blockIds.length > 0) {
      const rows = await tx<{ id: string; note: string | null; starts_at: string; ends_at: string }[]>`
        SELECT id, note, lower(span) AS starts_at, upper(span) AS ends_at FROM app.calendar_reservations
        WHERE id = ANY (${blockIds}::uuid[]) AND org_id = app.current_tenant_id()`;
      for (const r of rows) {
        blocks.push({
          id: r.id, organization_priest_id: p.id, priest_name: p.display_name, note: r.note,
          starts_at: iso(r.starts_at), ends_at: iso(r.ends_at),
        });
      }
    }
  }

  const toFix = (
    await tx<{ id: string; booking_number: string; local_date: string; customer_name: string; offering_hi: string; offering_en: string }[]>`
      SELECT b.id, b.booking_number, to_char(b.local_date, 'YYYY-MM-DD') AS local_date, c.display_name AS customer_name,
             o.name_hi AS offering_hi, o.name_en AS offering_en
      FROM app.bookings b
      JOIN app.customers c ON c.id = b.customer_id AND c.org_id = b.org_id
      JOIN app.offerings o ON o.id = b.offering_id AND o.org_id = b.org_id
      WHERE b.org_id = app.current_tenant_id() AND b.status = 'DRAFT' AND b.starts_at IS NULL
        AND b.local_date >= ${todayLocal}::date
      ORDER BY b.local_date, b.seq_no
      LIMIT 50`
  ).map((r) => ({ ...r }));

  return { bookings, blocks, busy, toFix, priests };
}
