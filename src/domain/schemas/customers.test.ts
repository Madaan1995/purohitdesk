import { describe, expect, it } from 'vitest';
import { CreateCustomerRequest, ListCustomersQuery, UpdateCustomerRequest } from './customers';

describe('customer request schemas', () => {
  it('normalises the phone and trims the name', () => {
    expect(CreateCustomerRequest.parse({ display_name: ' Ramesh ', phone: '98765 43210', address: ' Sector 70 ' })).toEqual({
      display_name: 'Ramesh',
      phone: '+919876543210',
      address: 'Sector 70',
    });
  });
  it('treats an empty phone or address as none', () => {
    expect(CreateCustomerRequest.parse({ display_name: 'R', phone: '', address: '  ' })).toEqual({
      display_name: 'R',
      phone: null,
      address: null,
    });
  });
  it('rejects unknown fields', () => {
    expect(CreateCustomerRequest.safeParse({ display_name: 'R', acquisition_source: 'IMPORT' }).success).toBe(false);
    expect(UpdateCustomerRequest.safeParse({ notes: 'x' }).success).toBe(false);
    expect(ListCustomersQuery.safeParse({ q: 'x', org: 'y' }).success).toBe(false);
  });
  it('rejects an invalid phone with the field path', () => {
    const result = CreateCustomerRequest.safeParse({ display_name: 'R', phone: '12345' });
    expect(result.success).toBe(false);
    expect(result.error?.issues[0].path).toEqual(['phone']);
  });
  it('update: null clears, absent keeps, empty body rejected', () => {
    expect(UpdateCustomerRequest.parse({ phone: null })).toEqual({ phone: null });
    expect(UpdateCustomerRequest.parse({ display_name: 'X' })).toEqual({ display_name: 'X' });
    expect(UpdateCustomerRequest.safeParse({}).success).toBe(false);
  });
  it('list query: limit defaults to 50 and is capped at 100', () => {
    expect(ListCustomersQuery.parse({}).limit).toBe(50);
    expect(ListCustomersQuery.safeParse({ limit: '101' }).success).toBe(false);
  });
});
