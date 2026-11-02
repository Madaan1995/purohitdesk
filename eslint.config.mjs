import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

// Node modules that perform I/O. src/domain must stay pure (spec §02).
const nodeIoModules = [
  "fs",
  "fs/promises",
  "net",
  "http",
  "https",
  "http2",
  "dns",
  "tls",
  "dgram",
  "child_process",
  "worker_threads",
  "cluster",
];

const domainMessage = "src/domain is pure TypeScript: no framework imports and no I/O.";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  {
    // Only src/db may import the database driver (spec ADR-002).
    files: ["src/**"],
    ignores: ["src/db/**"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: [{ name: "postgres", message: "Import the database only through src/db (withTenantTx)." }],
          patterns: [{ group: ["postgres/*"], message: "Import the database only through src/db (withTenantTx)." }],
        },
      ],
    },
  },
  {
    files: ["src/domain/**"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: [
            "next",
            "react",
            "react-dom",
            "postgres",
            ...nodeIoModules,
            ...nodeIoModules.map((name) => `node:${name}`),
          ].map((name) => ({ name, message: domainMessage })),
          patterns: [
            {
              group: ["next/*", "react/*", "react-dom/*", "postgres/*", "@supabase/*"],
              message: domainMessage,
            },
          ],
        },
      ],
      "no-restricted-globals": [
        "error",
        ...["fetch", "XMLHttpRequest", "WebSocket"].map((name) => ({ name, message: domainMessage })),
      ],
    },
  },
  globalIgnores([".next/**", "out/**", "build/**", "coverage/**", "next-env.d.ts"]),
]);

export default eslintConfig;
