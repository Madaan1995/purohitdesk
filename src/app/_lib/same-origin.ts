/**
 * CSRF guard for cookie-authenticated writes. The session cookie is SameSite=Lax, which leaves same-site requests and
 * browser defaults in charge; this checks the request itself. Accepted only when the browser says
 * `Sec-Fetch-Site: same-origin`, or, for a browser that sends no Fetch Metadata, when `Origin` equals the origin of
 * this request. Anything else (cross-site, same-site, `none`, a missing or `null` Origin) is refused.
 */
export function isSameOriginRequest(req: Request): boolean {
  const site = req.headers.get('sec-fetch-site');
  if (site !== null) return site === 'same-origin';
  const origin = req.headers.get('origin');
  return origin !== null && origin === new URL(req.url).origin;
}

/** GET and HEAD never change anything, so only other methods are checked. */
export function isUnsafeMethod(req: Request): boolean {
  return req.method !== 'GET' && req.method !== 'HEAD';
}
