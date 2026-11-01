// POST /api/v1/bookings/{bookingId}/cancel — BOOKING_CANCEL, or BOOKING_CANCEL_OWN when the actor is the LEAD priest
// (app.cancel_booking). A CONFIRMED booking needs a reason (3–500 characters). If-Match required.
import { bookingNotFound, UUID } from '@/app/_lib/bookings';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, parseIfMatch, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, withTenantTx } from '@/db';
import type { BookingCommandResult } from '@/domain/booking';
import { CancelBookingRequest } from '@/domain/schemas/bookings';

type Params = { params: Promise<{ bookingId: string }> };

export const POST = route(async (req: Request, { params }: Params) => {
  const { bookingId } = await params;
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  if (!UUID.test(bookingId)) throw bookingNotFound();
  const version = parseIfMatch(req);
  const body = await parseBody(req, CancelBookingRequest);
  const hash = requestHash('POST', `/bookings/${bookingId}/cancel`, body);
  const result = await withTenantTx(ctx, (tx) =>
    command<BookingCommandResult>(
      tx`SELECT app.cancel_booking(${bookingId}::uuid, ${version}::int, ${body.reason ?? null},
                                   ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, 200, etag(result.booking.version));
});
