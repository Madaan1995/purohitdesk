// Opaque keyset-pagination cursors: base64url of the JSON array of the last row's sort key and id (spec §11 §1).

function toBase64Url(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(value: string): string {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(base64 + '='.repeat((4 - (base64.length % 4)) % 4));
  return new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(binary, (c) => c.charCodeAt(0)));
}

export function encodeCursor(key: readonly [string, string]): string {
  return toBase64Url(JSON.stringify(key));
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Returns [sortKey, id], or null for anything that is not a cursor we issued. */
export function decodeCursor(cursor: string): [string, string] | null {
  if (!/^[A-Za-z0-9_-]{1,1024}$/.test(cursor)) return null;
  try {
    const parsed: unknown = JSON.parse(fromBase64Url(cursor));
    if (
      Array.isArray(parsed) &&
      parsed.length === 2 &&
      typeof parsed[0] === 'string' &&
      typeof parsed[1] === 'string' &&
      UUID.test(parsed[1])
    ) {
      return [parsed[0], parsed[1]];
    }
  } catch {
    // fall through
  }
  return null;
}
