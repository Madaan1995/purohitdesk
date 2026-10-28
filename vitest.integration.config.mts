import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// Route handlers against a THROWAWAY database (after supabase/tests/run.sh), as a real app_runtime login.
export default defineConfig({
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  test: {
    environment: "node",
    include: ["tests/integration/**/*.int.test.ts"],
    fileParallelism: false,
    testTimeout: 20000,
  },
});
