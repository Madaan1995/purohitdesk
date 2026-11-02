// Bookings (spec ADR-007, §05): the four stored states and their transitions, mirrored from the database guard
// app.tg_booking_guard; booking numbers PD-YY-NNNN (spec revision 2.1 #16).

export const BOOKING_STATUSES = ['DRAFT', 'CONFIRMED', 'COMPLETED', 'CANCELLED'] as const;
export type BookingStatus = (typeof BOOKING_STATUSES)[number];

/** Allowed status changes. A CONFIRMED booking may also stay CONFIRMED while it is rescheduled (M7). */
export const BOOKING_TRANSITIONS: Readonly<Record<BookingStatus, readonly BookingStatus[]>> = {
  DRAFT: ['CONFIRMED', 'CANCELLED'],
  CONFIRMED: ['COMPLETED', 'CANCELLED'],
  COMPLETED: [],
  CANCELLED: [],
};

export function canTransition(from: BookingStatus, to: BookingStatus): boolean {
  return BOOKING_TRANSITIONS[from].includes(to);
}

export function isTerminal(status: BookingStatus): boolean {
  return BOOKING_TRANSITIONS[status].length === 0;
}

/** booking_events.event (CHECK in the M6 migration). */
export const BOOKING_EVENTS = [
  'CREATED',
  'EDITED',
  'CONFIRMED',
  'RESCHEDULED',
  'CANCELLED',
  'COMPLETED',
  'BUFFER_OVERLAP_ACKNOWLEDGED',
  'SAMAGRI_ATTACHED',
  'SHARE_PREPARED',
  'PAYMENT_RECORDED',
  'PAYMENT_REVERSED',
  'PII_ERASED',
] as const;
export type BookingEvent = (typeof BOOKING_EVENTS)[number];

export const MAX_BOOKING_DAYS = 7;
export const MAX_PRIESTS = 11;
export const BOOKING_BUFFER_MAX = 360;
export const CANCEL_REASON_MIN = 3;
export const CANCEL_REASON_MAX = 500;

/** PD-YY-NNNN: YY = the two-digit year the booking was created; NNNN zero-padded, longer after 9999. */
export function formatBookingNumber(year: number, seq: number): string {
  if (!Number.isSafeInteger(seq) || seq < 1) throw new RangeError('seq must be a positive integer');
  return `PD-${String(year % 100).padStart(2, '0')}-${String(seq).padStart(4, '0')}`;
}

export interface BookingPriest {
  organization_priest_id: string;
  priest_profile_id: string;
  display_name: string;
  role: 'LEAD' | 'ASSISTANT';
}

/** The booking read model (app._booking_out; OpenAPI components.schemas.Booking). */
export interface Booking {
  id: string;
  booking_number: string;
  status: BookingStatus;
  customer: { id: string; display_name: string };
  offering: { id: string; name_hi: string; name_en: string; duration_min: number };
  title: string | null;
  location: string | null;
  notes: string | null;
  agreed_dakshina_paise: number | null;
  timezone: string;
  local_date: string;
  starts_at: string | null;
  ends_at: string | null;
  is_time_tentative: boolean;
  buffer_before_min: number | null;
  buffer_after_min: number | null;
  buffer_overlap_ack: boolean;
  source: 'PRIEST_DIRECT';
  created_via: 'MANUAL';
  cancel_reason: string | null;
  priests: BookingPriest[];
  confirmed_at: string | null;
  completed_at: string | null;
  cancelled_at: string | null;
  created_at: string;
  updated_at: string;
  version: number;
}

export interface BookingCommandResult {
  booking: Booking;
  idempotent_replay: boolean;
}

/** One busy span in a BOOKING_CONFLICT error (details.conflicts[]); booking_id only for the same practice. */
export interface BookingConflict {
  organization_priest_id: string;
  starts_at: string;
  ends_at: string;
  same_org: boolean;
  booking_id?: string;
}

/** reschedule_booking reason codes (the SQL list in the M7 migration; no free text in history, spec defect 10). */
export const RESCHEDULE_REASON_CODES = [
  'CUSTOMER_REQUEST',
  'PRIEST_REQUEST',
  'MUHURAT_FIXED',
  'PRIEST_CHANGED',
  'CORRECTION',
  'OTHER',
] as const;
export type RescheduleReasonCode = (typeof RESCHEDULE_REASON_CODES)[number];

/**
 * The shortest travel time, in whole minutes, between a ceremony [startsAt, endsAt) and the busy spans of a
 * BUFFER_CONFLICT ("only 15 minutes to travel"). 0 when a span touches the ceremony; null without spans.
 */
export function travelGapMinutes(
  conflicts: readonly { starts_at: string; ends_at: string }[],
  startsAt: string,
  endsAt: string,
): number | null {
  const start = Date.parse(startsAt);
  const end = Date.parse(endsAt);
  let best: number | null = null;
  for (const c of conflicts) {
    const cs = Date.parse(c.starts_at);
    const ce = Date.parse(c.ends_at);
    const gap = ce <= start ? start - ce : cs >= end ? cs - end : 0;
    const minutes = Math.floor(gap / 60_000);
    if (best === null || minutes < best) best = minutes;
  }
  return best;
}
