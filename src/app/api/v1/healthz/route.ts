// GET /api/v1/healthz — unauthenticated, never cached (spec §11).
export const dynamic = "force-dynamic";

export function GET(): Response {
  // Set by Vercel on every deployment; absent on local runs.
  const commit = process.env.VERCEL_GIT_COMMIT_SHA || "unknown";
  return Response.json(
    { status: "ok", commit },
    { status: 200, headers: { "Cache-Control": "no-store" } },
  );
}
