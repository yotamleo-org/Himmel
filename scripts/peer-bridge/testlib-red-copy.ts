// Test helper for the mutation controls: copies the repo layout a peer-bridge
// suite needs into a temp dir so a test can break one guard in the copy and
// expect its own row to turn red. Production code carries no flag for this.
import { cpSync, mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const REPO = join(import.meta.dir, "..", "..");

// The root bunfig and the three files its preloads load (the setup file imports
// ./live/project-guard), so a nested `bun test` there behaves like the repo's.
const BASE = ["scripts/peer-bridge", "bunfig.toml", "scripts/jira/vitest.setup.ts", "scripts/jira/bun-test-preload.ts", "scripts/jira/live/project-guard.ts"];

export function makeRedCopy(extra: string[] = []): string {
  const root = mkdtempSync(join(tmpdir(), "peer-red-"));
  for (const rel of [...BASE, ...extra]) {
    mkdirSync(dirname(join(root, rel)), { recursive: true });
    cpSync(join(REPO, rel), join(root, rel), { recursive: true });
  }
  return root;
}

// The test names a nested run reported as failed.
export function failedTests(output: string): string[] {
  return output.split("\n").filter(l => l.startsWith("(fail) ")).map(l => l.slice(7).replace(/ \[[0-9.]+m?s\]$/, ""));
}
