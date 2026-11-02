import { describe, expect, it } from 'vitest';
import { isSameOriginRequest, isUnsafeMethod } from './same-origin';

const URL_ = 'https://pd.example.test/api/v1/me';

function req(headers: Record<string, string>, method = 'POST'): Request {
  return new Request(URL_, { method, headers });
}

describe('isSameOriginRequest (CSRF guard)', () => {
  it('accepts Sec-Fetch-Site: same-origin', () => {
    expect(isSameOriginRequest(req({ 'sec-fetch-site': 'same-origin' }))).toBe(true);
  });

  it('refuses cross-site, same-site and none, even with a matching Origin', () => {
    for (const site of ['cross-site', 'same-site', 'none']) {
      expect(isSameOriginRequest(req({ 'sec-fetch-site': site, origin: 'https://pd.example.test' }))).toBe(false);
    }
  });

  it('without Fetch Metadata, accepts only an Origin equal to the request origin', () => {
    expect(isSameOriginRequest(req({ origin: 'https://pd.example.test' }))).toBe(true);
    expect(isSameOriginRequest(req({ origin: 'https://evil.example.test' }))).toBe(false);
    expect(isSameOriginRequest(req({ origin: 'http://pd.example.test' }))).toBe(false);
    expect(isSameOriginRequest(req({ origin: 'null' }))).toBe(false);
  });

  it('refuses a request with neither header', () => {
    expect(isSameOriginRequest(req({}))).toBe(false);
  });

  it('treats only GET and HEAD as safe', () => {
    expect(isUnsafeMethod(req({}, 'GET'))).toBe(false);
    expect(isUnsafeMethod(req({}, 'HEAD'))).toBe(false);
    for (const m of ['POST', 'PUT', 'PATCH', 'DELETE']) expect(isUnsafeMethod(req({}, m))).toBe(true);
  });
});
