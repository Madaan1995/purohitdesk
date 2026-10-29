// GET /api/v1/session — authenticated; first login creates the app user (app.ensure_current_user).
import { requireContext } from '@/app/_lib/context';
import { json, readCookie, route } from '@/app/_lib/http';
import { loadSession } from '@/app/_lib/session';

export const GET = route(async (req: Request) => {
  const ctx = await requireContext(req);
  return json(await loadSession(ctx, readCookie(req, 'NEXT_LOCALE')));
});
