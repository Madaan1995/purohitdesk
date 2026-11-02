// Request schemas for /customers (mirror api/openapi.yaml). Unknown fields are rejected.
import { z } from 'zod';
import { normalizeIndianPhone } from '../phone';

const phone = z
  .string()
  .max(32)
  .transform((value, ctx) => {
    const e164 = normalizeIndianPhone(value);
    if (!e164) {
      ctx.addIssue({ code: 'custom', message: 'invalid phone' });
      return z.NEVER;
    }
    return e164;
  });

const address = z.string().max(500).transform((s) => s.trim() || null);

export const CreateCustomerRequest = z.strictObject({
  display_name: z.string().trim().min(1).max(120),
  phone: z.union([z.literal('').transform(() => null), phone]).nullish(),
  address: address.nullish(),
});
export type CreateCustomerRequest = z.infer<typeof CreateCustomerRequest>;

export const UpdateCustomerRequest = z
  .strictObject({
    display_name: z.string().trim().min(1).max(120).optional(),
    phone: z.union([z.literal('').transform(() => null), phone]).nullable().optional(),
    address: address.nullable().optional(),
  })
  .refine((b) => Object.keys(b).length > 0, { message: 'empty body' });
export type UpdateCustomerRequest = z.infer<typeof UpdateCustomerRequest>;

export const ListCustomersQuery = z.strictObject({
  q: z.string().trim().max(60).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
  cursor: z.string().max(1024).optional(),
});
