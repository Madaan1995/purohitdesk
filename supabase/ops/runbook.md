# PurohitDesk operator runbook (staging)

Everything here is done by the founder. Never paste a password or key into the repository, a PR or a chat.
Supabase and Google change their dashboards often: if a menu name below has moved, look for the same setting
nearby, and tell me what you saw so I can fix this file.

## 1. First-time database setup (M1 + M2)

1. Supabase dashboard → your staging project (region `ap-south-1`, Mumbai) → **SQL Editor**.
2. Run each file in `supabase/migrations/` **in filename order**, one file per run, the whole file at once, and
   only the ones not applied yet: M1 `20261028200000_m1_foundation.sql`, `20261028200100_m1_identity_tenancy.sql`;
   M2 `20261028210000_m2_auth_onboarding.sql`; M4 `20261028220000_m4_customers.sql`;
   M5 `20261028230000_m5_catalog_settings.sql`. If any statement fails (most likely a `CREATE ROLE`, `GRANT <role> TO
   CURRENT_USER`, `ALTER FUNCTION … OWNER TO` or `REVOKE <role> FROM CURRENT_USER` — spec risk U1), stop and send me
   the exact error. Do not work around it with BYPASSRLS or the service-role key.
   - Each migration makes `postgres` a member of the roles it hands functions to and removes that membership again
     before it ends; `postgres` is never left a member of an application role. A migration also stops with an error
     (and applies nothing) if a `GRANT` silently granted nothing: the SQL editor would otherwise only show a
     `WARNING: no privileges were granted`. Send me that error too.
   - No application role reads `auth.users`; nothing is granted on schema `auth`.
3. Run `supabase/seed/ceremony_types.sql`.
4. Run every `supabase/checks/m<N>_checks.sql` for the milestones applied so far. Every row must say `PASS`.

## 2. Give `app_runtime` a login (M2)

1. Generate a long random password on your own machine, e.g. `openssl rand -base64 32 | tr -d '/+='`.
2. SQL Editor (replace the placeholder, run once, then clear the editor):
   ```sql
   ALTER ROLE app_runtime WITH LOGIN PASSWORD '<the generated password>';
   ```
3. Check it (no password shown):
   ```sql
   SELECT rolname, rolcanlogin, rolbypassrls, rolsuper FROM pg_roles WHERE rolname = 'app_runtime';
   -- expect: app_runtime | t | f | f
   ```
4. Build `DATABASE_URL` for the **transaction pooler** (port 6543): dashboard → **Connect** → *Transaction pooler*.
   Take the shown URI and change the user part from `postgres.<project-ref>` to `app_runtime.<project-ref>` and the
   password to the generated one:
   `postgres://app_runtime.<project-ref>:<password>@aws-0-ap-south-1.pooler.supabase.com:6543/postgres`
   (the host in your dashboard may differ slightly; keep the one it shows).
5. If the app cannot connect through port 6543 (spec risk U2), tell me; the spec's fallback is the session pooler
   (port 5432, same user format).

Rotation (quarterly, or at once if leaked): repeat steps 1–2 with a new password, update `DATABASE_URL` in Vercel,
redeploy.

## 3. Keep the Data API away from schema `app`

Dashboard → **Project Settings → Data API** (sometimes under **API**) → *Exposed schemas*: `app` must **not** be in
the list (the defaults are `public` and `graphql_public`). Check from your machine:

```bash
curl "https://<project-ref>.supabase.co/rest/v1/organizations" \
  -H "apikey: <publishable key>" -H "Accept-Profile: app"
# expect an error saying the schema must be one of the exposed schemas
```

## 4. Auth: asymmetric JWT signing keys (M2)

The API verifies tokens against the project's public keys (JWKS), so the project must sign with an asymmetric key.

1. Dashboard → **Project Settings → JWT Keys** (in some versions: **Authentication → JWT Keys** / *Signing keys*).
2. If the *current* key is the legacy HS256 secret: create a standby key of type **ECC (P-256)** (or RSA), then
   **Rotate** so it becomes the current key.
3. Check from your machine: `curl https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json` returns a `keys`
   array with a key whose `kty` is `EC` (or `RSA`). An empty list means the project still signs with HS256 and every
   API call will answer 401.

## 5. Google sign-in (M2)

Google Cloud Console (<https://console.cloud.google.com>), a project of your own:

1. **APIs & Services → OAuth consent screen**: user type *External*; app name "PurohitDesk"; your support e-mail;
   scopes `openid`, `email`, `profile` only. While in *Testing* mode, add the Google accounts you will test with
   under *Test users*.
2. **APIs & Services → Credentials → Create credentials → OAuth client ID** → *Web application*:
   - *Authorized redirect URIs*: `https://<project-ref>.supabase.co/auth/v1/callback`
   - Copy the **Client ID** and **Client secret**.
3. Supabase dashboard → **Authentication → Sign In / Providers → Google**: enable, paste the Client ID and secret,
   save.

## 6. Redirect URLs (M2)

Supabase dashboard → **Authentication → URL Configuration**:

- *Site URL*: your main Vercel URL for now (e.g. `https://purohitdesk.vercel.app`).
- *Redirect URLs*, add:
  - `https://*-<your-vercel-team-or-account-slug>.vercel.app/**` (all preview deployments)
  - `https://purohitdesk.vercel.app/**` (or your project's production URL)
  - `http://localhost:3000/**` (local development)

The app sends Google back to `<deployment URL>/auth/callback`, so that URL must match one of these patterns.

## 7. Vercel environment variables (M2)

Vercel → project → **Settings → Environment Variables** → environment **Preview** (Production later, in M13):

| Name | Value | Where to find it |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | `https://<project-ref>.supabase.co` | Supabase → Project Settings → API / Data API |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_…` | Supabase → Project Settings → API Keys |
| `DATABASE_URL` | the URI from §2 step 4 | — (mark it *Sensitive*) |

Redeploy the preview after adding them.

## 8. Members with other roles (staging only; P0 has no member-management UI)

The person must have signed in to PurohitDesk once. Each script is one call to an operator command
(`app.ops_add_member` / `app.ops_revoke_member`, owned by the NOLOGIN role `app_operator`). Only `postgres` may run
them; the API's `app_runtime` cannot. They never touch the practice's OWNER and never change row-level security.

- Add or change a member: open `supabase/ops/add_member.sql`, edit the four values (owner e-mail, practice name
  exactly as on the home page, member e-mail, role `ADMIN`/`STAFF`/`READ_ONLY`), run the whole file.
- Revoke: `supabase/ops/revoke_member.sql`, three values, run the whole file. The member loses access on their very
  next request.
- The result is one row like `{"org_id": "…", "user_id": "…", "role": "STAFF", "status": "ACTIVE"}`: ids, role and
  status only, never names or e-mails. Clear the e-mails from the editor afterwards.
- If it fails, the error names the reason and nothing changes:

  | Error | Meaning |
  | --- | --- |
  | `PRACTICE_NOT_FOUND` | No ACTIVE practice with that exact name whose OWNER has that e-mail. |
  | `PRACTICE_NAME_AMBIGUOUS` | That owner has two ACTIVE practices with this name; rename one in the app first. |
  | `MEMBER_NOT_SIGNED_IN` | No PurohitDesk user for that e-mail: they must sign in once (or the account was deleted). |
  | `ROLE_NOT_ALLOWED` | The role is not `ADMIN`, `STAFF` or `READ_ONLY` (OWNER is never given; PRIEST needs a priest link). |
  | `OWNER_UNTOUCHABLE` | That person is the practice's OWNER; the scripts never change or revoke the owner. |
  | `NOT_AN_ACTIVE_MEMBER` | (revoke) That person has no ACTIVE membership in this practice. |
