// PATCH /api/v1/me — own name and language (app.update_my_profile); also syncs the language cookie.
import { requireContext } from '@/app/_lib/context';
import { json, parseBody, route } from '@/app/_lib/http';
import type { SessionUser } from '@/app/_lib/session';
import { command, withTenantTx } from '@/db';
import { LOCALES } from '@/domain/locale';
import { z } from 'zod';

const UpdateMe = z
  .strictObject({
    display_name: z.string().trim().min(1).max(120).optional(),
    preferred_locale: z.enum(LOCALES).optional(),
  })
  .refine((b) => b.display_name !== undefined || b.preferred_locale !== undefined, { message: 'empty body' });

export const PATCH = route(async (req: Request) => {
  const ctx = await requireContext(req);
  const body = await parseBody(req, UpdateMe);
  const user = await withTenantTx({ actorId: ctx.actorId }, (tx) =>
    command<SessionUser>(
      tx`SELECT app.update_my_profile(${body.display_name ?? null}, ${body.preferred_locale ?? null}) AS result`,
    ),
  );
  return json(user, 200, {
    'Set-Cookie': `NEXT_LOCALE=${user.preferred_locale}; Path=/; Max-Age=31536000; SameSite=Lax`,
  });
});
