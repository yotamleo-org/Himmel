// Render test: every built page of site/dist (the Starlight pages and the standalone docs/ pages) and every standalone
// docs/ page loads headless from `astro preview` of a built site/dist. Per page: HTTP 200, every same-origin script/link/img
// it references resolves to 200, a visible h1, a non-empty body, and no uncaught page or console error. A standalone docs/
// page's h1 is also checked against its docs/ source. The standalone docs/ pages are listed even when the build drops them,
// so a page missing from HTML_PASSTHROUGH fails here instead of passing silently.
// Run through scripts/docs-site/test-site-build.sh (criterion 4), against the same j1.config.ts server.
import { test, expect } from "@playwright/test";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const DOCS = resolve(__dirname, "../../../docs");
const DIST = resolve(__dirname, "../../../site/dist");
const BASE = "/Himmel/";
// the site ships no favicon yet; scripts/docs-site/test-site-build.sh skips it in its link sweep too.
const NOT_SHIPPED = /favicon/;

// every standalone page under docs/ (.html at any depth), as a docs-relative path.
function standalonePages(dir = DOCS, rel = ""): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? standalonePages(join(dir, e.name), `${rel}${e.name}/`) : e.name.endsWith(".html") ? [`${rel}${e.name}`] : [],
  );
}

// every built page under site/dist as a route: a directory's index.html is that directory, 404.html is not a route.
// A redirect stub (meta refresh to a standalone page) is not a page of its own; its target is in the list.
function builtPages(dir = DIST, rel = ""): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (e.isDirectory()) return builtPages(join(dir, e.name), `${rel}${e.name}/`);
    if (!e.name.endsWith(".html") || (rel === "" && e.name === "404.html")) return [];
    if (readFileSync(join(dir, e.name), "utf8").includes('http-equiv="refresh"')) return [];
    return [e.name === "index.html" ? rel : `${rel}${e.name}`];
  });
}

// the h1 text the docs/ source carries, tags stripped: the page's own key element, checked against its source.
function sourceH1(rel: string): string {
  const m = readFileSync(join(DOCS, rel), "utf8").match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
  return (m?.[1] ?? "").replace(/<[^>]+>/g, "").trim();
}

const standalone = standalonePages();
const pages = [...new Set([...builtPages(), ...standalone])].sort().map((rel) => ({
  url: BASE + rel,
  h1: standalone.includes(rel) ? sourceH1(rel) : "",
  name: rel || "/",
}));

test("render: found the built pages", () => {
  expect(existsSync(DIST), "site/dist is built").toBe(true);
  expect(pages.length, "pages to render").toBeGreaterThan(0);
});

test.describe("render: every built page", () => {
  test.describe.configure({ mode: "parallel" });
  for (const p of pages) {
    test(p.name, async ({ page, request }) => {
      const errors: string[] = [];
      page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
      page.on("console", (m) => {
        if (m.type() === "error" && !NOT_SHIPPED.test(m.text())) errors.push(`console: ${m.text()}`);
      });

      const res = await page.goto(p.url);
      expect(res?.status(), p.url).toBe(200);

      // every same-origin asset the rendered page references must resolve, the way a browser would fetch it
      const assets = await page.$$eval("script[src], link[rel~=stylesheet][href], img[src]", (els) =>
        els.map((el) => el.getAttribute("src") ?? el.getAttribute("href") ?? ""),
      );
      for (const a of new Set(assets)) {
        if (!a || /^(?:[a-z][a-z0-9+.-]*:|\/\/|data:)/i.test(a) || NOT_SHIPPED.test(a)) continue;
        const r = await request.get(new URL(a, page.url()).toString());
        expect(r.status(), `asset ${a} of ${p.url}`).toBe(200);
      }

      await expect(page.locator("h1").first()).toBeVisible();
      if (p.h1) await expect(page.locator("h1").first()).toContainText(p.h1);
      expect((await page.locator("body").innerText()).trim().length, `body of ${p.url}`).toBeGreaterThan(0);
      expect(errors, `errors on ${p.url}`).toEqual([]);
    });
  }
});
