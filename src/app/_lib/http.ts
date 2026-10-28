import { DomainError } from '@/db';
import { apiError, type ApiError } from '@/domain/errors';
import { z } from 'zod';

const NO_STORE = { 'Cache-Control': 'no-store' };

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return Response.json(body, { status, headers: { ...NO_STORE, ...headers } });
}

function envelope(error: ApiError, requestId: string): Response {
  const { status, ...rest } = error;
  return json({ error: { ...rest, request_id: requestId } }, status);
}

/** The shared error wrapper: every route handler body runs inside it. */
export function route<Args extends unknown[]>(
  handler: (req: Request, ...args: Args) => Promise<Response>,
): (req: Request, ...args: Args) => Promise<Response> {
  return async (req, ...args) => {
    try {
      return await handler(req, ...args);
    } catch (error) {
      return errorResponse(error);
    }
  };
}

export function errorResponse(error: unknown): Response {
  const requestId = crypto.randomUUID();
  if (error instanceof DomainError) {
    if (error.api.status >= 500) logBug(requestId, error.sqlstate ?? error.api.code);
    return envelope(error.api, requestId);
  }
  if (error instanceof z.ZodError) {
    const field = error.issues[0]?.path.join('.') || undefined;
    return envelope(apiError('VALIDATION_FAILED', field ? { details: { field } } : {}), requestId);
  }
  logBug(requestId, error instanceof Error ? error.name : 'unknown');
  return envelope(apiError('INTERNAL'), requestId);
}

// Ids and codes only: never names, phones or messages (spec §10 §3, CLAUDE.md rule 10).
function logBug(requestId: string, code: string): void {
  console.error(JSON.stringify({ level: 'error', request_id: requestId, code }));
}

/** Reads a JSON body and validates it; unknown fields are rejected by strict schemas. */
export async function parseBody<T extends z.ZodType>(req: Request, schema: T): Promise<z.infer<T>> {
  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    throw new DomainError(apiError('VALIDATION_FAILED', { reason: 'INVALID_JSON' }));
  }
  return schema.parse(raw);
}
