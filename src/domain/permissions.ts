// Roles and permissions: the same names as app.role_permissions (spec §08 §2).

export const ROLES = ['OWNER', 'ADMIN', 'PRIEST', 'STAFF', 'READ_ONLY'] as const;
export type Role = (typeof ROLES)[number];

export const PERMISSIONS = [
  'ORG_READ',
  'ORG_SETTINGS',
  'MEMBER_MANAGE',
  'AUDIT_READ',
  'EXPORT_DATA',
  'CUSTOMER_READ',
  'CUSTOMER_WRITE',
  'CUSTOMER_ERASE',
  'CATALOG_WRITE',
  'BOOKING_READ',
  'BOOKING_CREATE',
  'BOOKING_EDIT',
  'BOOKING_CONFIRM',
  'BOOKING_CONFIRM_OWN',
  'BOOKING_CANCEL',
  'BOOKING_CANCEL_OWN',
  'BOOKING_COMPLETE',
  'BOOKING_COMPLETE_OWN',
  'BLOCK_MANAGE',
  'BLOCK_MANAGE_OWN',
  'PAYMENT_RECORD',
  'PAYMENT_REVERSE',
  'SHARE_MESSAGE',
  'VOICE_USE',
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export function isRole(value: unknown): value is Role {
  return typeof value === 'string' && (ROLES as readonly string[]).includes(value);
}

export function isPermission(value: unknown): value is Permission {
  return typeof value === 'string' && (PERMISSIONS as readonly string[]).includes(value);
}
