import { mapDatabaseError, type ApiError } from '@/domain/errors';
import postgres from 'postgres';

/** An error that is safe to turn into the API error envelope. */
export class DomainError extends Error {
  readonly api: ApiError;
  /** SQLSTATE when the error came from PostgreSQL (for logs; never shown to users). */
  readonly sqlstate?: string;

  constructor(api: ApiError, sqlstate?: string) {
    super(api.code);
    this.name = 'DomainError';
    this.api = api;
    this.sqlstate = sqlstate;
  }
}

/** Database errors become DomainError through mapDatabaseError; anything else is rethrown unchanged. */
export function toDomainError(error: unknown): unknown {
  if (error instanceof DomainError) return error;
  if (error instanceof postgres.PostgresError) {
    return new DomainError(
      mapDatabaseError({ code: error.code, message: error.message, detail: error.detail }),
      error.code,
    );
  }
  return error;
}
