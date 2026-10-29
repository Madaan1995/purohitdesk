import { ESLint } from "eslint";
import { describe, expect, it } from "vitest";

const eslint = new ESLint({ cwd: process.cwd() });

async function boundaryErrors(code: string, filePath: string): Promise<string[]> {
  const [result] = await eslint.lintText(code, { filePath });
  return result.messages
    .filter((m) => m.ruleId === "no-restricted-imports" || m.ruleId === "no-restricted-globals")
    .map((m) => m.ruleId ?? "");
}

const forbiddenImports = [
  'import { useState } from "react";',
  'import { NextResponse } from "next/server";',
  'import { readFileSync } from "node:fs";',
  'import { readFile } from "fs/promises";',
  'import postgres from "postgres";',
  'import { createClient } from "@supabase/supabase-js";',
];

describe("src/domain boundary rule", () => {
  it.each(forbiddenImports)("flags %s in src/domain", async (code) => {
    expect(await boundaryErrors(`${code}\n`, "src/domain/example.ts")).toEqual(["no-restricted-imports"]);
  });

  it.each(["fetch", "XMLHttpRequest", "WebSocket"])("flags the %s global in src/domain", async (name) => {
    expect(await boundaryErrors(`export const x = ${name};\n`, "src/domain/example.ts")).toEqual([
      "no-restricted-globals",
    ]);
  });

  it.each(forbiddenImports)("allows %s outside src/domain", async (code) => {
    expect(await boundaryErrors(`${code}\n`, "src/app/example.ts")).toEqual([]);
  });

  it("allows pure code in src/domain", async () => {
    expect(await boundaryErrors("export const paise = (rupees: number): number => rupees * 100;\n", "src/domain/example.ts")).toEqual([]);
  });
});
