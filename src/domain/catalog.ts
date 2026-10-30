// Catalog and settings limits, shared by the API schemas and the forms (the database enforces the same values).

export const DURATION_MIN = 15;
export const DURATION_MAX = 1440;
export const BUFFER_MAX = 240;
export const MAX_SAMAGRI_ITEMS = 100;
export const PROVIDED_BY = ['FAMILY', 'PRIEST'] as const;
export type ProvidedBy = (typeof PROVIDED_BY)[number];

export function isValidDuration(minutes: unknown): minutes is number {
  return typeof minutes === 'number' && Number.isInteger(minutes) && minutes >= DURATION_MIN && minutes <= DURATION_MAX;
}

export function isValidBuffer(minutes: unknown): minutes is number {
  return typeof minutes === 'number' && Number.isInteger(minutes) && minutes >= 0 && minutes <= BUFFER_MAX;
}
