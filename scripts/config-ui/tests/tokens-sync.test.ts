import { test, expect } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// The docs site and the config chief share one token file. The site holds the canonical
// site/src/styles/tokens.css; the chief serves only public/, so it carries a byte-identical copy. These pin the
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

test("the copy is byte-identical to the site's token file", () => {
  expect(existsSync(TWIN), `${TWIN} must exist`).toBe(true);
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

test("the docs site applies the tokens and the Starlight variable map through customCss", () => {
  const site = join(import.meta.dir, "../../../site");
  const cfg = read(join(site, "astro.config.mjs"));
  const m = cfg.match(/customCss:\s*\[([^\]]*)\]/);
  expect(m, "astro.config.mjs must set customCss").not.toBeNull();
  const listed = [...m![1].matchAll(/['"]([^'"]+)['"]/g)].map((x) => x[1]);
  expect(listed).toEqual(["./src/styles/tokens.css", "./src/styles/starlight-map.css"]);
  for (const f of listed) expect(existsSync(join(site, f)), `${f} must exist`).toBe(true);
  const map = read(join(site, "src/styles/starlight-map.css")).replace(/\s+/g, "");
  for (const [sl, token] of [["--sl-color-accent", "--accent"], ["--sl-color-bg", "--bg"], ["--sl-color-text", "--ink"], ["--sl-color-hairline", "--rule"]]) {
    expect(map, sl).toContain(`${sl}:var(${token})`);
  }
});

test("the tokens define light and dark values for the ten colours the console reads", () => {
  const css = read(COPY);
  for (const v of ["--bg", "--surface", "--rule", "--rule-strong", "--ink", "--muted", "--accent", "--ship", "--beta", "--crit"]) {
    expect(css, v).toContain(`${v}:`);
  }
  expect(css).toContain(':root[data-theme="light"]');
  expect(css).toContain("--font-ui:");
  expect(css).toContain("--font-mono:");
});

// with no saved choice the page is dark whatever the system prefers; only a saved light choice
// ([data-theme="light"]) turns it light. A prefers-color-scheme query would let a light system preference win.
const lum = (hex: string) => {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const contrast = (a: string, b: string) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
// the colour a token resolves to in the rule that begins with `selector`, following var(--x) references through :root
function resolve(css: string, selector: string, token: string): string {
  const body = (sel: string) => new RegExp(`${sel.replace(/[[\]().]/g, "\\$&")}\\s*\\{([^}]*)\\}`).exec(css)?.[1] ?? "";
  const raw = (name: string, ...sels: string[]) => {
    for (const s of sels) { const m = new RegExp(`${name}\\s*:\\s*([^;]+);`).exec(body(s)); if (m) return m[1].trim(); }
    return "";
  };
  let v = raw(token, selector, ":root");
  for (let i = 0; i < 4 && v.startsWith("var("); i++) v = raw(v.slice(4, -1), ":root");
  return v;
}

test("no saved choice is dark with readable text, whatever the system prefers", () => {
  const css = read(COPY);
  expect(css).not.toContain("prefers-color-scheme");
  expect(/:root\s*\{[^}]*color-scheme:\s*dark/.test(css)).toBe(true);
  const bg = resolve(css, ":root", "--bg");
  expect(lum(bg)).toBeLessThan(0.1);
  for (const t of ["--ink", "--muted", "--accent", "--ship", "--beta", "--crit"]) {
    expect(contrast(resolve(css, ":root", t), bg), t).toBeGreaterThanOrEqual(4.5);
  }
});

test("a saved light choice still wins and is readable", () => {
  const css = read(COPY);
  expect(css).toMatch(/:root\[data-theme="light"\]\s*\{[^}]*color-scheme:\s*light/);
  const bg = resolve(css, ':root[data-theme="light"]', "--bg");
  expect(lum(bg)).toBeGreaterThan(0.5);
  for (const t of ["--ink", "--muted"]) expect(contrast(resolve(css, ':root[data-theme="light"]', t), bg), t).toBeGreaterThanOrEqual(4.5);
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
