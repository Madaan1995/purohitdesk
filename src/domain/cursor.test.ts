import { describe, expect, it } from 'vitest';
import { decodeCursor, encodeCursor } from './cursor';

const ID = '0f8fad5b-d9cb-469f-a165-70867728950e';

describe('keyset cursor', () => {
  it.each(['ramesh sharma', 'शर्मा जी', '', "o'brien \"quoted\""])('round-trips %j', (key) => {
    const cursor = encodeCursor([key, ID]);
    expect(cursor).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(decodeCursor(cursor)).toEqual([key, ID]);
  });

  it('rejects tampered or foreign cursors', () => {
    expect(decodeCursor('not a cursor!')).toBeNull();
    expect(decodeCursor(encodeCursor(['x', ID]).slice(0, -3))).toBeNull();
    expect(decodeCursor(btoa(JSON.stringify(['x', 'not-a-uuid'])).replace(/=+$/, ''))).toBeNull();
    expect(decodeCursor(btoa(JSON.stringify({ a: 1 })).replace(/=+$/, ''))).toBeNull();
    expect(decodeCursor('')).toBeNull();
  });
});
