import { test, expect } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DOCS_PATHS, DOCS_URL, docsHref } from "../public/nav.js";

// The UI links into the docs site, never the reverse. Every docs path the UI links to must be a route of a
// fresh site build (site/dist), so a link to a missing page fails here before it ships.
const DIST = join(import.meta.dir, "../../../site/dist");
const BASE = new URL(DOCS_URL).pathname; // "/Himmel/"

// The routes of a built site: dist/<route>/index.html and dist/<route>.html, as "/<route>" ("/" for the root).
export function routesOf(dist: string): string[] {
  const out: string[] = [];
  for (const f of readdirSync(dist, { recursive: true }).map(String)) {
    if (!f.endsWith(".html")) continue;
    const route = "/" + f.replace(/(^|\/)index\.html$/, "").replace(/\.html$/, "");
    out.push(route.length > 1 ? route.replace(/\/$/, "") : "/");
  }
  return out;
}

// the docs paths (relative to the site base) that are not in the route list.
export function missingRoutes(paths: string[], routes: string[]): string[] {
  const have = new Set(routes.map((r) => (r.length > 1 ? r.replace(/\/$/, "") : r)));
  return paths.filter((p) => !have.has(p.length > 1 ? p.replace(/\/$/, "") : p));
}

test("DOCS_URL is the public site and every docs link is built from it", () => {
  expect(new URL(DOCS_URL).host).toBe("yotamleo-org.github.io");
  expect(DOCS_URL).toBe("https://yotamleo-org.github.io/Himmel/");
  expect(docsHref("/")).toBe(DOCS_URL);
  expect(docsHref("/trail/")).toBe(DOCS_URL + "trail/");
  expect(DOCS_PATHS).toContain("/");
});

test("a planted link to a missing page fails the cross-check; the real links do not", () => {
  const dir = mkdtempSync(join(tmpdir(), "docs-dist-"));
  try {
    mkdirSync(join(dir, "trail"));
    writeFileSync(join(dir, "index.html"), "");
    writeFileSync(join(dir, "trail", "index.html"), "");
    writeFileSync(join(dir, "faq.html"), "");
    const routes = routesOf(dir);
    expect(routes.sort()).toEqual(["/", "/faq", "/trail"]);
    expect(missingRoutes(["/", "/trail/", "/faq"], routes)).toEqual([]);
    expect(missingRoutes(["/", "/no-such-page/"], routes)).toEqual(["/no-such-page/"]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("every docs path the UI links to exists in site/dist", () => {
  if (!existsSync(DIST)) return; // dist is untracked: `cd site && npm ci && npm run build` makes it
  expect(missingRoutes(DOCS_PATHS, routesOf(DIST))).toEqual([]);
});

test("the site base is the repo name, so the root link is the site home", () => {
  expect(BASE).toBe("/Himmel/");
});
