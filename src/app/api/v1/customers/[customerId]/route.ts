// GET /api/v1/customers/{customerId} — CUSTOMER_READ; PATCH — CUSTOMER_WRITE (app.update_customer), If-Match required.
import { requireContext } from '@/app/_lib/context';
import { getCustomer, type CustomerCommandResult } from '@/app/_lib/customers';
import { etag, json, parseBody, parseIfMatch, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, DomainError, withTenantTx } from '@/db';
import { apiError } from '@/domain/errors';
import { UpdateCustomerRequest } from '@/domain/schemas/customers';

type Params = { params: Promise<{ customerId: string }> };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const notFound = () => new DomainError(apiError('NOT_FOUND', { details: { resource: 'customer' } }));

export const GET = route(async (req: Request, { params }: Params) => {
  const { customerId } = await params;
  const ctx = await requireContext(req, { tenant: true });
  if (!UUID.test(customerId)) throw notFound();
  const customer = await withTenantTx(ctx, (tx) => getCustomer(tx, customerId));
  if (!customer) throw notFound();
  return json(customer, 200, etag(customer.version));
});

export const PATCH = route(async (req: Request, { params }: Params) => {
  const { customerId } = await params;
  const ctx = await requireContext(req, { tenant: true, idempotency: true });
  if (!UUID.test(customerId)) throw notFound();
  const version = parseIfMatch(req);
  const body = await parseBody(req, UpdateCustomerRequest);
  const patch: Record<string, string | null> = {};
  if (body.display_name !== undefined) patch.display_name = body.display_name;
  if (body.phone !== undefined) patch.phone_e164 = body.phone;
  if (body.address !== undefined) patch.address = body.address;
  const hash = requestHash('PATCH', `/customers/${customerId}`, body);
  const result = await withTenantTx(ctx, (tx) =>
    command<CustomerCommandResult>(
      tx`SELECT app.update_customer(${customerId}::uuid, ${version}::int, ${tx.json(patch)}::jsonb,
                                    ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, 200, etag(result.customer.version));
});
