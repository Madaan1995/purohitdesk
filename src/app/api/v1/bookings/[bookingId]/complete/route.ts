// POST /api/v1/bookings/{bookingId}/complete — BOOKING_COMPLETE, or BOOKING_COMPLETE_OWN when the actor is the LEAD
// priest (app.complete_booking). Only after the ceremony has started. If-Match required.
import { bookingNotFound, UUID } from '@/app/_lib/bookings';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, parseIfMatch, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, withTenantTx } from '@/db';
import type { BookingCommandResult } from '@/domain/booking';
import { CompleteBookingRequest } from '@/domain/schemas/bookings';

type Params = { params: Promise<{ bookingId: string }> };

export const POST = route(async (req: Request, { params }: Params) => {
  const { bookingId } = await params;
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  if (!UUID.test(bookingId)) throw bookingNotFound();
  const version = parseIfMatch(req);
  const body = await parseBody(req, CompleteBookingRequest);
  const hash = requestHash('POST', `/bookings/${bookingId}/complete`, body);
  const result = await withTenantTx(ctx, (tx) =>
    command<BookingCommandResult>(
      tx`SELECT app.complete_booking(${bookingId}::uuid, ${version}::int, ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, 200, etag(result.booking.version));
});
