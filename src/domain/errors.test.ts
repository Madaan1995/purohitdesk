import { describe, expect, it } from 'vitest';
import { apiError, mapDatabaseError } from './errors';

describe('mapDatabaseError (spec §11 §3)', () => {
  it.each([
    ['PD401', 401, 'UNAUTHENTICATED'],
    ['PD403', 403, 'FORBIDDEN'],
    ['PD404', 404, 'NOT_FOUND'],
    ['23503', 404, 'NOT_FOUND'],
    ['PD409', 409, 'VERSION_CONFLICT'],
    ['PD410', 409, 'INVALID_TRANSITION'],
    ['PD412', 409, 'IDEMPOTENCY_REUSE'],
    ['23P01', 409, 'BOOKING_CONFLICT'],
    ['PD449', 409, 'BUFFER_CONFLICT'],
    ['23505', 409, 'DUPLICATE'],
    ['PD422', 422, 'VALIDATION_FAILED'],
    ['23514', 422, 'VALIDATION_FAILED'],
    ['22P02', 422, 'VALIDATION_FAILED'],
    ['22007', 422, 'VALIDATION_FAILED'],
    ['22008', 422, 'VALIDATION_FAILED'],
    ['22023', 422, 'VALIDATION_FAILED'],
    ['PD429', 429, 'QUOTA_EXCEEDED'],
    ['PD405', 500, 'INTERNAL'],
    ['PD500', 500, 'INTERNAL'],
    ['42501', 500, 'INTERNAL'],
    ['XX000', 500, 'INTERNAL'],
    [undefined, 500, 'INTERNAL'],
  ])('%s -> %i %s', (sqlstate, status, code) => {
    const mapped = mapDatabaseError({ code: sqlstate, message: 'x', detail: '{"a":1}' });
    expect(mapped.status).toBe(status);
    expect(mapped.code).toBe(code);
  });

  it('passes our JSON detail and reason through for PD-class errors', () => {
    expect(mapDatabaseError({ code: 'PD401', message: 'CONTEXT_MISSING', detail: '{}' })).toEqual({
      status: 401,
      code: 'UNAUTHENTICATED',
      reason: 'CONTEXT_MISSING',
      message: 'Sign-in required.',
    });
    expect(mapDatabaseError({ code: 'PD422', message: 'VALIDATION_FAILED', detail: '{"field":"name"}' })).toEqual({
      status: 422,
      code: 'VALIDATION_FAILED',
      message: 'Some input is not valid.',
      details: { field: 'name' },
    });
    expect(mapDatabaseError({ code: 'PD422', message: 'IDEMPOTENCY_KEY_REQUIRED', detail: '{}' }).reason).toBe(
      'IDEMPOTENCY_KEY_REQUIRED',
    );
    expect(mapDatabaseError({ code: 'PD403', message: 'FORBIDDEN', detail: '{"permission":"CUSTOMER_WRITE"}' }).details)
      .toEqual({ permission: 'CUSTOMER_WRITE' });
  });

  it('drops PostgreSQL DETAIL for constraint errors (it can echo stored values)', () => {
    const mapped = mapDatabaseError({
      code: '23505',
      message: 'duplicate key value violates unique constraint "x"',
      detail: 'Key (phone)=(+919876543210) already exists.',
    });
    expect(mapped).toEqual({ status: 409, code: 'DUPLICATE', message: 'This already exists.' });
    expect(mapDatabaseError({ code: '23503', message: 'm', detail: 'Key (customer_id)=(…) is not present' })).not.toHaveProperty(
      'details',
    );
    expect(mapDatabaseError({ code: '23514', message: 'violates check', detail: '{"leak":true}' })).not.toHaveProperty('details');
  });

  it('never exposes reason or details for bugs', () => {
    expect(mapDatabaseError({ code: 'PD500', message: 'INVARIANT_VIOLATION', detail: '{"booking":"x"}' })).toEqual({
      status: 500,
      code: 'INTERNAL',
      message: 'Something went wrong.',
    });
  });

  it('ignores non-JSON or non-object detail and free-text messages', () => {
    const mapped = mapDatabaseError({ code: 'PD404', message: 'customer Ramesh not found', detail: 'not json' });
    expect(mapped).toEqual({ status: 404, code: 'NOT_FOUND', message: 'Not found.' });
    expect(mapDatabaseError({ code: 'PD404', message: 'NOT_FOUND', detail: '[1,2]' })).not.toHaveProperty('details');
  });
});

describe('apiError', () => {
  it('builds an envelope body with the status for the code', () => {
    expect(apiError('QUOTA_EXCEEDED', { details: { limit: 3 } })).toEqual({
      status: 429,
      code: 'QUOTA_EXCEEDED',
      message: 'Limit reached.',
      details: { limit: 3 },
    });
  });
});
