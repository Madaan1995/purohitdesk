// Request schemas for /bookings (mirror api/openapi.yaml). Unknown fields are rejected; the database re-validates
// everything (app._booking_apply) and is the authority.
import { z } from 'zod';
import { BOOKING_BUFFER_MAX, BOOKING_STATUSES, CANCEL_REASON_MAX, MAX_PRIESTS, RESCHEDULE_REASON_CODES } from '../booking';
import { MAX_PAISE } from '../money';

const text = (max: number) => z.string().max(max).nullable();
const instant = z.iso.datetime({ offset: true });
const localDate = z.iso.date();
const buffer = z.number().int().min(0).max(BOOKING_BUFFER_MAX).nullable();
const priestIds = z.array(z.uuid()).max(MAX_PRIESTS);

const editable = {
  customer_id: z.uuid(),
  offering_id: z.uuid(),
  title: text(120),
  location: text(500),
  notes: text(2000),
  agreed_dakshina_paise: z.number().int().min(0).max(MAX_PAISE).nullable(),
  timezone: z.string().min(1).max(64),
  local_date: localDate.nullable(),
  starts_at: instant.nullable(),
  ends_at: instant.nullable(),
  is_time_tentative: z.boolean(),
  buffer_before_min: buffer,
  buffer_after_min: buffer,
  priest_ids: priestIds,
};

export const CreateBookingRequest = z.strictObject({
  ...editable,
  title: editable.title.optional(),
  location: editable.location.optional(),
  notes: editable.notes.optional(),
  agreed_dakshina_paise: editable.agreed_dakshina_paise.optional(),
  timezone: editable.timezone.optional(),
  local_date: editable.local_date.optional(),
  starts_at: editable.starts_at.optional(),
  ends_at: editable.ends_at.optional(),
  is_time_tentative: editable.is_time_tentative.optional(),
  buffer_before_min: editable.buffer_before_min.optional(),
  buffer_after_min: editable.buffer_after_min.optional(),
  priest_ids: editable.priest_ids.optional(),
  confirm: z.boolean().optional(),
  ack_buffer_overlap: z.boolean().optional(),
});
export type CreateBookingRequest = z.infer<typeof CreateBookingRequest>;

export const UpdateBookingRequest = z
  .strictObject(Object.fromEntries(Object.entries(editable).map(([k, v]) => [k, v.optional()])) as {
    [K in keyof typeof editable]: z.ZodOptional<(typeof editable)[K]>;
  })
  .refine((b) => Object.keys(b).length > 0, { message: 'empty body' });
export type UpdateBookingRequest = z.infer<typeof UpdateBookingRequest>;

export const ConfirmBookingRequest = z.strictObject({
  priest_ids: priestIds.min(1).optional(),
  ack_buffer_overlap: z.boolean().optional(),
});

/** Moves a CONFIRMED booking; a reason code is required and free text is not accepted (spec defect 10). */
export const RescheduleBookingRequest = z.strictObject({
  starts_at: instant.optional(),
  ends_at: instant.optional(),
  timezone: editable.timezone.optional(),
  is_time_tentative: z.boolean().optional(),
  buffer_before_min: z.number().int().min(0).max(BOOKING_BUFFER_MAX).optional(),
  buffer_after_min: z.number().int().min(0).max(BOOKING_BUFFER_MAX).optional(),
  priest_ids: priestIds.min(1).optional(),
  reason_code: z.enum(RESCHEDULE_REASON_CODES),
  ack_buffer_overlap: z.boolean().optional(),
});
export type RescheduleBookingRequest = z.infer<typeof RescheduleBookingRequest>;
export const CancelBookingRequest = z.strictObject({ reason: z.string().max(CANCEL_REASON_MAX).nullable().optional() });
export const CompleteBookingRequest = z.strictObject({});

export const ListBookingsQuery = z
  .strictObject({
    status: z.enum(BOOKING_STATUSES).optional(),
    customer_id: z.uuid().optional(),
    from: localDate.optional(),
    to: localDate.optional(),
    limit: z.coerce.number().int().min(1).max(100).default(50),
    cursor: z.string().max(1024).optional(),
  })
  .refine((q) => !q.from || !q.to || q.from <= q.to, { message: 'from after to', path: ['to'] })
  .refine(
    (q) => !q.from || !q.to || Date.parse(q.to) - Date.parse(q.from) <= 366 * 86_400_000,
    { message: 'range longer than 366 days', path: ['to'] },
  );
export type ListBookingsQuery = z.infer<typeof ListBookingsQuery>;
