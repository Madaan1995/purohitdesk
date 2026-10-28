PurohitDesk
Priest-services app. Full spec: docs/spec.md. Build plan: docs/plan.md.
Read both before planning any work.
Stack
Next.js (App Router), TypeScript strict, Supabase (Postgres, Auth, RLS), Vercel.
Commands
npm run dev
npm run lint
npm run typecheck   (tsc --noEmit)
npm test
Rules
Do not invent tables, columns, env vars, roles or features. If the spec doesn't cover it, stop and ask me.
Never connect to any database or use DB credentials. Write migrations as new SQL files in supabase/migrations/ only; I review and apply them. Never edit a migration that has been applied.
Every new table has RLS enabled with explicit policies in the same migration.
Secrets never go in code. List every new env variable (no values) in .env.example.
Work only on the current milestone. No drive-by refactors.
Before calling anything done: run lint, typecheck and tests, and show me the real output.
Commit in small steps with clear messages, on a feature branch. Never push to or merge into main.
