import { test, expect } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// The docs site and the config console share one token file. The site holds the canonical
// site/src/styles/tokens.css; the console serves only public/, so it carries a byte-identical copy. These pin the
// copy, the sync and the rule that theme.css reads its colours and fonts from the shared tokens.
const PUBLIC = join(import.meta.dir, "../public");
const TWIN = join(import.meta.dir, "../../../site/src/styles/tokens.css");
const COPY = join(PUBLIC, "tokens.css");
const read = (f: string) => readFileSync(f, "utf8");

// null when the two files are byte-identical, else why not.
export function syncFault(canon: string, copy: string): string | null {
  if (!existsSync(canon)) return `missing ${canon}`;
  if (!existsSync(copy)) return `missing ${copy}`;
  const a = readFileSync(canon);
  const b = readFileSync(copy);
  return a.equals(b) ? null : `${copy} differs from ${canon} (${a.length} vs ${b.length} bytes)`;
}

test("the copy exists and names the site file it twins", () => {
  expect(existsSync(COPY)).toBe(true);
  expect(read(COPY)).toContain("site/src/styles/tokens.css");
});

test("the copy is byte-identical to the site's token file once the site has one", () => {
  if (!existsSync(TWIN)) return; // HIMMEL-6287 lands site/src/styles/tokens.css; until then the copy is the source
  expect(syncFault(TWIN, COPY)).toBeNull();
});

test("a one-byte edit to the copy is a sync fault; identical files are not", () => {
  const dir = mkdtempSync(join(tmpdir(), "tokens-sync-"));
  try {
    mkdirSync(join(dir, "site"));
    const canon = join(dir, "site", "tokens.css");
    const copy = join(dir, "tokens.css");
    const body = read(COPY);
    writeFileSync(canon, body);
    writeFileSync(copy, body);
    expect(syncFault(canon, copy)).toBeNull();
    writeFileSync(copy, body.replace("--radius:6px", "--radius:7px"));
    expect(syncFault(canon, copy)).toMatch(/differs from/);
    rmSync(copy);
    expect(syncFault(canon, copy)).toMatch(/^missing /);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("the tokens define light and dark values for the ten colours the console reads", () => {
  const css = read(COPY);
  for (const v of ["--bg", "--surface", "--rule", "--rule-strong", "--ink", "--muted", "--accent", "--ship", "--beta", "--crit"]) {
    expect(css, v).toContain(`${v}:`);
  }
  expect(css).toContain("prefers-color-scheme: dark");
  expect(css).toContain(':root[data-theme="dark"]');
  expect(css).toContain("--font-ui:");
  expect(css).toContain("--font-mono:");
});

test("theme.css imports the shared tokens and points its ten names at them; no IBM Plex", () => {
  const theme = read(join(PUBLIC, "theme.css"));
  expect(theme).toMatch(/@import\s+(url\()?["']?\.\/tokens\.css/);
  const maps: Record<string, string> = {
    "--panel": "var(--surface)", "--line": "var(--rule)", "--fg": "var(--ink)", "--dim": "var(--muted)",
    "--ok": "var(--ship)", "--warn": "var(--beta)", "--fail": "var(--crit)", "--off": "var(--rule-strong)",
    "--mono": "var(--font-mono)", "--sans": "var(--font-ui)",
  };
  for (const [name, to] of Object.entries(maps)) expect(theme, name).toContain(`${name}:${to}`);
  for (const f of ["theme.css", "app.css"]) expect(read(join(PUBLIC, f)), f).not.toMatch(/IBM Plex/i);
});
