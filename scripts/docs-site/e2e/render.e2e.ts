// Render test: every standalone docs/ page and the site's own routes load headless from `astro preview`
// of a built site/dist. Per page: HTTP 200, every same-origin script/link/img it references resolves to 200,
// its own h1 renders with the text its docs/ source carries, and no uncaught page or console error.
// Run through scripts/docs-site/test-site-build.sh (criterion 4), against the same j1.config.ts server.
import { test, expect } from "@playwright/test";
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const DOCS = resolve(__dirname, "../../../docs");
const BASE = "/Himmel/";
// the site ships no favicon yet; scripts/docs-site/test-site-build.sh skips it in its link sweep too.
const NOT_SHIPPED = /favicon/;

// every standalone page under docs/ (.html at any depth), as a docs-relative path.
function standalonePages(dir = DOCS, rel = ""): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? standalonePages(join(dir, e.name), `${rel}${e.name}/`) : e.name.endsWith(".html") ? [`${rel}${e.name}`] : [],
  );
}

// the h1 text the docs/ source carries, tags stripped: the page's own key element, checked against its source.
function sourceH1(rel: string): string {
  const m = readFileSync(join(DOCS, rel), "utf8").match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
  return (m?.[1] ?? "").replace(/<[^>]+>/g, "").trim();
}

const pages = standalonePages().map((rel) => ({ url: BASE + rel, h1: sourceH1(rel), name: rel }));
const routes = [BASE, `${BASE}daily-loop/`, `${BASE}glossary/`];

test.describe("render: standalone docs pages", () => {
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

test.describe("render: site routes", () => {
  for (const url of routes) {
    test(url, async ({ page }) => {
      const errors: string[] = [];
      page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
      page.on("console", (m) => {
        if (m.type() === "error" && !NOT_SHIPPED.test(m.text())) errors.push(`console: ${m.text()}`);
      });
      const res = await page.goto(url);
      expect(res?.status(), url).toBe(200);
      await expect(page.locator("h1").first()).toBeVisible();
      expect(errors, `errors on ${url}`).toEqual([]);
    });
  }
});
