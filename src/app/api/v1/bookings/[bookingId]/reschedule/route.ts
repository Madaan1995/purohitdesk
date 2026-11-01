// POST /api/v1/bookings/{bookingId}/reschedule — BOOKING_CONFIRM, or BOOKING_CONFIRM_OWN when the actor is the LEAD
// priest before and after any priest_ids change (app.reschedule_booking). If-Match required; reason_code required.
import { bookingNotFound, UUID } from '@/app/_lib/bookings';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, parseIfMatch, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, withTenantTx } from '@/db';
import type { BookingCommandResult } from '@/domain/booking';
import { RescheduleBookingRequest } from '@/domain/schemas/bookings';

type Params = { params: Promise<{ bookingId: string }> };

export const POST = route(async (req: Request, { params }: Params) => {
  const { bookingId } = await params;
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  if (!UUID.test(bookingId)) throw bookingNotFound();
  const version = parseIfMatch(req);
  const body = await parseBody(req, RescheduleBookingRequest);
  const { reason_code: reasonCode, ack_buffer_overlap: ack, ...changes } = body;
  const hash = requestHash('POST', `/bookings/${bookingId}/reschedule`, body);
  const result = await withTenantTx(ctx, (tx) =>
    command<BookingCommandResult>(
      tx`SELECT app.reschedule_booking(${bookingId}::uuid, ${version}::int, ${tx.json(changes)}::jsonb, ${reasonCode},
                                       ${ack ?? false}::boolean, ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, 200, etag(result.booking.version));
});
