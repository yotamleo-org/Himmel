// Journey J1: the built docs site, served by `astro preview`: the Starlight home, a deep link, the standalone
// HTML pages byte-identical at their docs/ paths, and no broken internal link anywhere in the site.
import { test, expect, type APIRequestContext } from "@playwright/test";
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const DOCS = resolve(__dirname, "../../../docs");
const BASE = "/Himmel/";
// the site ships no favicon yet; scripts/docs-site/test-site-build.sh skips it in its link sweep too.
const NOT_SHIPPED = new Set([`${BASE}favicon.svg`]);

// every standalone page under docs/ (.html at any depth), as a docs-relative path.
function standalonePages(dir = DOCS, rel = ""): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? standalonePages(join(dir, e.name), `${rel}${e.name}/`) : e.name.endsWith(".html") ? [`${rel}${e.name}`] : [],
  );
}

test("J1. the home renders the Starlight page with a title and one h1", async ({ page }) => {
  const res = await page.goto(BASE);
  expect(res?.status()).toBe(200);
  expect((await page.title()).trim().length).toBeGreaterThan(0);
  await expect(page.locator("h1")).toHaveCount(1);
});

test("J1. a deep link renders its page with the sidebar", async ({ page }) => {
  const res = await page.goto(`${BASE}daily-loop/`);
  expect(res?.status()).toBe(200);
  await expect(page.locator("h1")).toHaveCount(1);
  expect((await page.locator("h1").innerText()).trim().length).toBeGreaterThan(0);
  await expect(page.locator("nav.sidebar a").first()).toBeAttached();
});

test("J1. the standalone HTML pages are byte-identical at their docs/ paths", async ({ request }) => {
  const pages = standalonePages();
  expect(pages.length).toBeGreaterThanOrEqual(3);
  for (const rel of pages) {
    const res = await request.get(BASE + rel);
    expect(res.status(), rel).toBe(200);
    expect(Buffer.compare(await res.body(), readFileSync(join(DOCS, rel))), `${rel} differs from docs/${rel}`).toBe(0);
  }
});

// the same-origin paths (fragment dropped) an HTML body links to or loads; a path outside the site base is kept so the crawl reports it.
function localPaths(html: string, from: string): string[] {
  const out = new Set<string>();
  for (const m of html.matchAll(/\b(?:href|src)=(?:"([^"]+)"|'([^']+)')/g)) {
    const raw = m[1] ?? m[2];
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(raw)) continue;
    const u = new URL(raw, `http://site${from}`);
    if (!NOT_SHIPPED.has(u.pathname)) out.add(u.pathname);
  }
  return [...out];
}

async function crawl(request: APIRequestContext): Promise<{ seen: number; broken: string[] }> {
  const queue = [BASE];
  const seen = new Set(queue);
  const broken: string[] = [];
  while (queue.length) {
    const path = queue.shift()!;
    const res = await request.get(path);
    if (res.status() !== 200) {
      broken.push(`${path} -> ${res.status()}`);
      continue;
    }
    if (!(res.headers()["content-type"] ?? "").includes("text/html")) continue;
    for (const p of localPaths(await res.text(), path)) {
      if (!seen.has(p)) {
        seen.add(p);
        queue.push(p);
      }
    }
  }
  return { seen: seen.size, broken };
}

test("J1. no internal link on the site is broken", async ({ request }) => {
  test.setTimeout(300_000);
  const { seen, broken } = await crawl(request);
  expect(seen, "the crawl reached only the home").toBeGreaterThan(20);
  expect(broken, `broken internal links:\n${broken.join("\n")}`).toEqual([]);
});
