// GET /api/v1/customers — CUSTOMER_READ (every role); POST — CUSTOMER_WRITE (app.create_customer).
import { requireContext } from '@/app/_lib/context';
import { BadCursorError, listCustomers, type CustomerCommandResult } from '@/app/_lib/customers';
import { etag, json, parseBody, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, DomainError, withTenantTx } from '@/db';
import { apiError } from '@/domain/errors';
import { CreateCustomerRequest, ListCustomersQuery } from '@/domain/schemas/customers';

export const GET = route(async (req: Request) => {
  const ctx = await requireContext(req, { tenant: true });
  const query = ListCustomersQuery.parse(Object.fromEntries(new URL(req.url).searchParams));
  const page = await withTenantTx(ctx, async (tx) => {
    try {
      return await listCustomers(tx, query);
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
  const body = await parseBody(req, CreateCustomerRequest);
  const hash = requestHash('POST', '/customers', body);
  const result = await withTenantTx(ctx, (tx) =>
    command<CustomerCommandResult>(
      tx`SELECT app.create_customer(${body.display_name}, ${body.phone ?? null}, ${body.address ?? null},
                                    ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, result.idempotent_replay ? 200 : 201, etag(result.customer.version));
});
