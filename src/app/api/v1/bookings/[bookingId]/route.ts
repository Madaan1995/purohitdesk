// GET /api/v1/bookings/{bookingId} — BOOKING_READ (app.get_booking); PATCH — BOOKING_EDIT (app.update_booking),
// If-Match required.
import { bookingNotFound, getBooking, UUID } from '@/app/_lib/bookings';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, parseIfMatch, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, withTenantTx } from '@/db';
import type { BookingCommandResult } from '@/domain/booking';
import { UpdateBookingRequest } from '@/domain/schemas/bookings';

type Params = { params: Promise<{ bookingId: string }> };

export const GET = route(async (req: Request, { params }: Params) => {
  const { bookingId } = await params;
  const ctx = await requireContext(req, { tenant: true });
  if (!UUID.test(bookingId)) throw bookingNotFound();
  const booking = await withTenantTx(ctx, (tx) => getBooking(tx, bookingId));
  if (!booking) throw bookingNotFound();
  return json(booking, 200, etag(booking.version));
});

export const PATCH = route(async (req: Request, { params }: Params) => {
  const { bookingId } = await params;
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  if (!UUID.test(bookingId)) throw bookingNotFound();
  const version = parseIfMatch(req);
  const body = await parseBody(req, UpdateBookingRequest);
  const hash = requestHash('PATCH', `/bookings/${bookingId}`, body);
  const result = await withTenantTx(ctx, (tx) =>
    command<BookingCommandResult>(
      tx`SELECT app.update_booking(${bookingId}::uuid, ${version}::int, ${tx.json(body)}::jsonb,
                                   ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, 200, etag(result.booking.version));
});
