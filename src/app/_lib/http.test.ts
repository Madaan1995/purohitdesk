import { DomainError } from '@/db';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { parseBody } from './http';

const Body = z.strictObject({ name: z.string() });

function req(body: string, contentType?: string): Request {
  return new Request('https://pd.example.test/api/v1/x', {
    method: 'POST',
    headers: contentType === undefined ? {} : { 'content-type': contentType },
    body,
  });
}

async function reason(promise: Promise<unknown>): Promise<string | undefined> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(DomainError);
    expect((error as DomainError).api.status).toBe(422);
    return (error as DomainError).api.reason;
  }
  throw new Error('expected a 422');
}

describe('parseBody requires Content-Type: application/json', () => {
  it('accepts application/json, with or without parameters', async () => {
    await expect(parseBody(req('{"name":"a"}', 'application/json'), Body)).resolves.toEqual({ name: 'a' });
    await expect(parseBody(req('{"name":"a"}', 'Application/JSON; charset=utf-8'), Body)).resolves.toEqual({ name: 'a' });
  });

  it('refuses a JSON body sent as a form or plain text, or without a type', async () => {
    // Request() defaults a string body to text/plain; a form can send text/plain without a CORS preflight.
    expect(await reason(parseBody(req('{"name":"a"}'), Body))).toBe('JSON_REQUIRED');
    expect(await reason(parseBody(req('{"name":"a"}', 'text/plain'), Body))).toBe('JSON_REQUIRED');
    expect(await reason(parseBody(req('name=a', 'application/x-www-form-urlencoded'), Body))).toBe('JSON_REQUIRED');
    expect(await reason(parseBody(req('{"name":"a"}', 'application/json-patch+json'), Body))).toBe('JSON_REQUIRED');
  });

  it('still reports invalid JSON', async () => {
    expect(await reason(parseBody(req('{', 'application/json'), Body))).toBe('INVALID_JSON');
  });
});
