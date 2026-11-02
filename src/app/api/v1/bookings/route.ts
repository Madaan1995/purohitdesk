// GET /api/v1/bookings — BOOKING_READ (every role); POST — BOOKING_CREATE (+ BOOKING_CONFIRM[_OWN] with confirm: true)
// through app.create_booking.
import { BadCursorError, listBookings } from '@/app/_lib/bookings';
import { requireContext } from '@/app/_lib/context';
import { etag, json, parseBody, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, DomainError, withTenantTx } from '@/db';
import type { BookingCommandResult } from '@/domain/booking';
import { apiError } from '@/domain/errors';
import { CreateBookingRequest, ListBookingsQuery } from '@/domain/schemas/bookings';

export const GET = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true });
  const query = ListBookingsQuery.parse(Object.fromEntries(new URL(req.url).searchParams));
  const page = await withTenantTx(ctx, async (tx) => {
    try {
      return await listBookings(tx, query);
    } catch (error) {
      if (error instanceof BadCursorError) {
        throw new DomainError(apiError('VALIDATION_FAILED', { details: { field: 'cursor' } }));
      }
      throw error;
    }
  });
  return json(page);
});

export const POST = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  const body = await parseBody(req, CreateBookingRequest);
  const { confirm, ...fields } = body;
  const hash = requestHash('POST', '/bookings', body);
  const result = await withTenantTx(ctx, (tx) =>
    command<BookingCommandResult>(
      tx`SELECT app.create_booking(${tx.json(fields)}::jsonb, ${confirm ?? false}::boolean,
                                   ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, result.idempotent_replay ? 200 : 201, etag(result.booking.version));
});
