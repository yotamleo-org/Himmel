// Every colour the built pages paint comes from tokens.css. The static drift test
// (design-layer.test.ts) reads the CSS text; this one reads what the browser computed on every element of every
// config-ui page, light and dark, so a colour that slips in by any route (inline style, a page module, a UA default
// left unstyled) fails here. A colour passes when it is a token value, or a mix of two token values (color-mix).
// RED control: E2E_BREAK=colour plants one off-token colour on each page, and the suite must fail.
import { test, expect, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { boot, type Harness } from "./fixtures";

type RGB = [number, number, number];
const TOKENS: RGB[] = [...readFileSync(join(__dirname, "../../public/tokens.css"), "utf8").matchAll(/#([0-9a-f]{6})\b/gi)]
  .map((m) => [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16)) as RGB);
const PAGES = ["shift", "health", "toolhealth", "config", "roadmap", "kanban", "workflow"];
const HEAD = "#main h1, #h-configure"; // every page paints one of these once it has rendered
// the page CSP refuses an injected <style>, so the planted colour goes in through the CSSOM, on <body>: a page
// re-render replaces #main, never the body
const plant = (page: Page) => page.evaluate(() => document.body.style.setProperty("background-color", "#ff00aa"));
// the token rides the first landing only; after it every page is its #/<id> route, as the rail links it
async function show(page: Page, id: string) {
  await page.evaluate((r) => { location.hash = r; }, `#/${id}`);
  await page.locator(`#pages a[aria-current="page"][href$="#/${id}"]`).waitFor();
  await page.locator(HEAD).first().waitFor();
  await page.waitForLoadState("networkidle");
}

const near = (a: number, b: number) => Math.abs(a - b) <= 2;
const isToken = (c: RGB) => TOKENS.some((t) => t.every((v, i) => near(v, c[i])));
// c = t·a + (1-t)·b in sRGB for one t in [0,1], the shape color-mix(in srgb, a p%, b) computes to
function isMix(c: RGB) {
  for (const a of TOKENS) for (const b of TOKENS) {
    const d = a.map((v, i) => v - b[i]), dd = d.reduce((s, v) => s + v * v, 0);
    if (!dd) continue;
    const t = Math.min(1, Math.max(0, d.reduce((s, v, i) => s + v * (c[i] - b[i]), 0) / dd));
    if (c.every((v, i) => near(v, b[i] + t * d[i]))) return true;
  }
  return false;
}

// every painted colour on the page: [where, property, computed value, r, g, b]; transparent ones are skipped
async function paintedColours(page: Page) {
  return page.evaluate(() => {
    const parse = (v: string): number[] | null => {
      let m = /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(v);
      if (m) return m[4] !== undefined && +m[4] === 0 ? null : [+m[1], +m[2], +m[3]];
      m = /^color\(srgb ([\d.]+) ([\d.]+) ([\d.]+)(?: \/ ([\d.]+))?\)$/.exec(v);
      if (m) return m[4] !== undefined && +m[4] === 0 ? null : [+m[1] * 255, +m[2] * 255, +m[3] * 255];
      return v === "none" || v === "transparent" ? null : [-1, -1, -1]; // an unparsed form fails loudly
    };
    const where = (e: Element) => e.tagName.toLowerCase() + (e.id ? `#${e.id}` : "") + (e.classList.length ? `.${[...e.classList].join(".")}` : "");
    const out: [string, string, string, number, number, number][] = [];
    for (const e of document.querySelectorAll("body, body *")) {
      if (!(e as HTMLElement).getClientRects().length) continue; // not rendered
      const s = getComputedStyle(e);
      if (s.visibility === "hidden") continue;
      const props = ["color", "background-color"];
      for (const side of ["top", "right", "bottom", "left"]) if (s.getPropertyValue(`border-${side}-style`) !== "none" && parseFloat(s.getPropertyValue(`border-${side}-width`)) > 0) props.push(`border-${side}-color`);
      if (s.outlineStyle !== "none" && parseFloat(s.outlineWidth) > 0) props.push("outline-color");
      if (e instanceof SVGElement) props.push("fill", "stroke");
      for (const p of props) {
        const v = s.getPropertyValue(p), c = parse(v);
        if (c) out.push([where(e), p, v, c[0], c[1], c[2]]);
      }
    }
    return out;
  });
}

async function offTokens(page: Page) {
  const seen = new Set<string>();
  return (await paintedColours(page)).filter(([w, p, v, r, g, b]) => {
    const key = `${w} ${p} ${v}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return !isToken([r, g, b]) && !isMix([r, g, b]);
  }).map(([w, p, v]) => `${w} ${p}: ${v}`);
}

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

for (const scheme of ["light", "dark"] as const) {
  test(`every config-ui page paints only token colours (${scheme})`, async ({ browser }) => {
    h = await boot();
    const ctx = await browser.newContext({ colorScheme: scheme, viewport: { width: 1280, height: 900 } });
    const page = await ctx.newPage();
    const bad: string[] = [];
    await page.goto(`${h.url}&page=${PAGES[0]}`);
    for (const id of PAGES) {
      await show(page, id);
      if (process.env.E2E_BREAK === "colour") await plant(page);
      for (const o of await offTokens(page)) bad.push(`${id}: ${o}`);
    }
    await ctx.close();
    expect(bad, "colours outside tokens.css").toEqual([]);
  });
}

// the check itself: a planted colour is reported, so a scan that reads nothing cannot pass for a clean page
test("a colour planted outside tokens.css is reported", async ({ page }) => {
  h = await boot();
  await page.goto(`${h.url}&page=health`);
  await show(page, "health");
  await plant(page);
  expect(await offTokens(page)).toContainEqual("body background-color: rgb(255, 0, 170)");
});
