// Request schemas for /availability and /blocks (mirror api/openapi.yaml). Unknown fields are rejected.
import { z } from 'zod';
import { daysBetween } from '../agenda';

/** Local dates, inclusive; at most 62 days of data (spec §11 §2). */
export const AvailabilityQuery = z
  .strictObject({ priest_id: z.uuid(), from: z.iso.date(), to: z.iso.date() })
  .refine((q) => q.from <= q.to && daysBetween(q.from, q.to) <= 61, { message: 'from..to is 1-62 days', path: ['to'] });

export const CreateBlockRequest = z.strictObject({
  priest_id: z.uuid(),
  starts_at: z.iso.datetime({ offset: true }),
  ends_at: z.iso.datetime({ offset: true }),
  note: z.string().max(500).nullable().optional(),
});
export type CreateBlockRequest = z.infer<typeof CreateBlockRequest>;
