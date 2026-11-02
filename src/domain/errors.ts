// Error envelope codes and the PostgreSQL error mapping (spec §11 §3).

export const ERROR_CODES = [
  'UNAUTHENTICATED',
  'FORBIDDEN',
  'NOT_FOUND',
  'VERSION_CONFLICT',
  'INVALID_TRANSITION',
  'IDEMPOTENCY_REUSE',
  'BOOKING_CONFLICT',
  'BUFFER_CONFLICT',
  'DUPLICATE',
  'VALIDATION_FAILED',
  'QUOTA_EXCEEDED',
  'INTERNAL',
  'VENDOR_UNAVAILABLE',
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];

export interface ApiError {
  status: number;
  code: ErrorCode;
  reason?: string;
  message: string;
  details?: Record<string, unknown>;
}

const STATUS: Record<ErrorCode, number> = {
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  VERSION_CONFLICT: 409,
  INVALID_TRANSITION: 409,
  IDEMPOTENCY_REUSE: 409,
  BOOKING_CONFLICT: 409,
  BUFFER_CONFLICT: 409,
  DUPLICATE: 409,
  VALIDATION_FAILED: 422,
  QUOTA_EXCEEDED: 429,
  INTERNAL: 500,
  VENDOR_UNAVAILABLE: 503,
};

// English fallback text; the UI shows its own translated message for each code.
const MESSAGES: Record<ErrorCode, string> = {
  UNAUTHENTICATED: 'Sign-in required.',
  FORBIDDEN: 'You do not have permission to do this.',
  NOT_FOUND: 'Not found.',
  VERSION_CONFLICT: 'Someone else changed this first. Reload and try again.',
  INVALID_TRANSITION: 'This change is not allowed in the current state.',
  IDEMPOTENCY_REUSE: 'This request key was already used for a different request.',
  BOOKING_CONFLICT: 'The priest is busy at this time.',
  BUFFER_CONFLICT: 'Travel time overlaps another booking.',
  DUPLICATE: 'This already exists.',
  VALIDATION_FAILED: 'Some input is not valid.',
  QUOTA_EXCEEDED: 'Limit reached.',
  INTERNAL: 'Something went wrong.',
  VENDOR_UNAVAILABLE: 'A service is unavailable. Please try again.',
};

const BY_SQLSTATE: Record<string, ErrorCode> = {
  PD401: 'UNAUTHENTICATED',
  PD403: 'FORBIDDEN',
  PD404: 'NOT_FOUND',
  '23503': 'NOT_FOUND',
  PD409: 'VERSION_CONFLICT',
  PD410: 'INVALID_TRANSITION',
  PD412: 'IDEMPOTENCY_REUSE',
  '23P01': 'BOOKING_CONFLICT',
  PD449: 'BUFFER_CONFLICT',
  '23505': 'DUPLICATE',
  PD422: 'VALIDATION_FAILED',
  '23514': 'VALIDATION_FAILED',
  '22P02': 'VALIDATION_FAILED',
  '22007': 'VALIDATION_FAILED',
  '22008': 'VALIDATION_FAILED',
  '22023': 'VALIDATION_FAILED',
  PD429: 'QUOTA_EXCEEDED',
  PD405: 'INTERNAL',
  PD500: 'INTERNAL',
  '42501': 'INTERNAL',
};

const REASON = /^[A-Z][A-Z0-9_]*$/;

export function apiError(
  code: ErrorCode,
  extra: { reason?: string; details?: Record<string, unknown>; message?: string } = {},
): ApiError {
  return {
    status: STATUS[code],
    code,
    ...(extra.reason ? { reason: extra.reason } : {}),
    message: extra.message ?? MESSAGES[code],
    ...(extra.details ? { details: extra.details } : {}),
  };
}

export interface DatabaseErrorLike {
  code?: string;
  message?: string;
  detail?: string;
}

/**
 * Maps a PostgreSQL error to the API error. Only our own JSON (PD-class SQLSTATEs and 23P01) is passed on as
 * details: PostgreSQL's own DETAIL for 23505/23503/23514/22xxx can echo stored values and is dropped.
 * PD405, PD500 and 42501 mean a bug: they become INTERNAL with no reason or details.
 */
export function mapDatabaseError(error: DatabaseErrorLike): ApiError {
  const sqlstate = error.code ?? '';
  const code = BY_SQLSTATE[sqlstate] ?? 'INTERNAL';
  if (code === 'INTERNAL') return apiError('INTERNAL');

  const ours = sqlstate.startsWith('PD') || sqlstate === '23P01';
  const reason = ours && error.message && REASON.test(error.message) && error.message !== code ? error.message : undefined;
  const details = ours ? parseDetails(error.detail) : undefined;
  return apiError(code, { reason, details });
}

function parseDetails(detail: string | undefined): Record<string, unknown> | undefined {
  if (!detail) return undefined;
  try {
    const parsed: unknown = JSON.parse(detail);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) && Object.keys(parsed).length > 0) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    // Not our JSON: never pass PostgreSQL's own text on.
  }
  return undefined;
}
