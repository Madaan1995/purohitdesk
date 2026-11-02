// POST /api/v1/onboarding/practice — create a practice in one step (app.bootstrap_practice); Idempotency-Key required.
import { requireContext } from '@/app/_lib/context';
import { json, parseBody, route } from '@/app/_lib/http';
import { requestHash } from '@/app/_lib/request-hash';
import { command, withTenantTx } from '@/db';
import { z } from 'zod';

const CreatePractice = z.strictObject({
  name: z.string().trim().min(1).max(120),
  ceremony_type_ids: z.array(z.uuid()).min(1).max(20),
});

export interface OnboardingResult {
  organization: { id: string; name: string; kind: string; timezone: string; status: string; version: number };
  role: 'OWNER';
  organization_priest_id: string;
  offering_count: number;
  idempotent_replay: boolean;
}

export const POST = route(async (req: Request) => {
  const ctx = await requireContext(req, { idempotency: true });
  const body = await parseBody(req, CreatePractice);
  const hash = requestHash('POST', '/onboarding/practice', body);
  const result = await withTenantTx({ actorId: ctx.actorId }, (tx) =>
    command<OnboardingResult>(
      tx`SELECT app.bootstrap_practice(${body.name}, ${tx.array(body.ceremony_type_ids)}::uuid[],
                                       ${ctx.idempotencyKey}, ${hash}) AS result`,
    ),
  );
  return json(result, result.idempotent_replay ? 200 : 201);
});
