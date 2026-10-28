# src/domain

Pure TypeScript: types, errors, permissions, money, share/whatsapp.

- No I/O and no framework imports. ESLint blocks `next`, `react`, `react-dom`, `postgres`, `@supabase/*`, Node I/O modules and the `fetch`, `XMLHttpRequest` and `WebSocket` globals here.
- Money is integer paise; time is timestamptz (UTC) + IANA time zone + local date.
- Everything here is unit-testable without a database or framework.
