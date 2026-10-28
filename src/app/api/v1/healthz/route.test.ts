import { afterEach, describe, expect, it, vi } from "vitest";
import { GET } from "./route";

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("GET /api/v1/healthz", () => {
  it("returns 200 with exactly {status, commit} and Cache-Control: no-store", async () => {
    vi.stubEnv("VERCEL_GIT_COMMIT_SHA", "abc1234");
    const res = GET();
    expect(res.status).toBe(200);
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(res.headers.get("Content-Type")).toContain("application/json");
    expect(await res.json()).toStrictEqual({ status: "ok", commit: "abc1234" });
  });

  it('falls back to "unknown" when VERCEL_GIT_COMMIT_SHA is unset', async () => {
    vi.stubEnv("VERCEL_GIT_COMMIT_SHA", undefined);
    expect(await GET().json()).toStrictEqual({ status: "ok", commit: "unknown" });
  });

  it('falls back to "unknown" when VERCEL_GIT_COMMIT_SHA is empty', async () => {
    vi.stubEnv("VERCEL_GIT_COMMIT_SHA", "");
    expect(await GET().json()).toStrictEqual({ status: "ok", commit: "unknown" });
  });
});
