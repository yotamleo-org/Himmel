// Journey J-DG1: the docs page walks the development graph. ES modules do not load over file://,
// so the spec serves docs/guide over http itself.
import { test, expect, type Page } from "@playwright/test";
import { createServer, type Server } from "node:http";
import { readFileSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const GUIDE = resolve(__dirname, "../../../../docs/guide");
const GRAPH = JSON.parse(readFileSync(join(GUIDE, "dev-graph/graph.json"), "utf8"));
const TYPES: Record<string, string> = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };

let server: Server;
let base = "";

test.beforeAll(async () => {
  server = createServer((req, res) => {
    const rel = normalize(decodeURIComponent((req.url ?? "/").split(/[?#]/)[0])).replace(/^(\.\.[/\\])+/, "");
    try {
      const body = readFileSync(join(GUIDE, rel === "/" ? "dev-graph.html" : rel));
      res.writeHead(200, { "content-type": TYPES[extname(rel)] ?? "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}/dev-graph.html`;
});
test.afterAll(() => { server.close(); });

const stepOf = async (page: Page) => Number(await page.getByRole("slider").inputValue());
const nodeState = (page: Page, id: string) => page.locator(`.dg-wide [data-id="${id}"]`);
const w = (id: string) => GRAPH.walkthroughs.find((x: { id: string }) => x.id === id);
const edgeById = (id: string) => GRAPH.edges.find((e: { id: string }) => e.id === id);

async function open(page: Page, hash = "") {
  await page.goto(base + hash);
  await page.locator(".dg-node").first().waitFor({ state: "attached" });
}

test("J-DG1. the page draws every node of graph.json", async ({ page }) => {
  await open(page);
  await expect(page.locator(".dg-wide .dg-node")).toHaveCount(GRAPH.nodes.length);
});

test("J-DG1. W2 stepped with Next shows the NO-GO as refused, with its condition and source", async ({ page }) => {
  await open(page, "#w=w2&s=1");
  const steps = w("w2").steps;
  const at = steps.findIndex((s: { at: string }) => s.at === "j.verdict");
  await page.getByLabel("Walkthrough").selectOption("w2");
  for (let i = 0; i < at; i++) await page.getByRole("button", { name: "Next" }).click();
  await expect(nodeState(page, "j.verdict")).toHaveAttribute("data-state", "refused");
  const cap = page.locator(".dg-caption");
  await expect(cap).toContainText(edgeById("e.verdict.nogo").condition);
  await expect(cap).toContainText("write-verdict.sh");
  await expect(cap).toContainText("Refused");
  await page.getByRole("button", { name: "Next" }).click();
  await expect(nodeState(page, "j.verdict")).toHaveAttribute("data-state", "refused");
});

test("J-DG1. a deep link restores the walkthrough and step, and stepping rewrites it", async ({ page }) => {
  await open(page, "#w=w2&s=7");
  await expect(page.getByLabel("Walkthrough")).toHaveValue("w2");
  await expect(page.locator(".dg-caption")).toContainText(`Step 7 of ${w("w2").steps.length}`);
  await expect(nodeState(page, w("w2").steps[6].at)).toHaveAttribute("data-state", "active");
  await page.getByRole("button", { name: "Next" }).click();
  await expect(page).toHaveURL(/#w=w2&s=8$/);
});

test("J-DG1. a hash that carries other keys keeps them", async ({ page }) => {
  await open(page, "#t=abc&w=w1&s=2");
  await page.getByRole("button", { name: "Next" }).click();
  await expect(page).toHaveURL(/#t=abc&.*s=3$/);
});

test("J-DG1. a hash change that is not a walkthrough one leaves the step alone", async ({ page }) => {
  await open(page, "#w=w2&s=7");
  await page.evaluate(() => { location.hash = "#conditions"; });
  await page.waitForTimeout(300);
  expect(await stepOf(page)).toBe(6);
  await expect(page.getByLabel("Walkthrough")).toHaveValue("w2");
});

test("J-DG1. Play advances at least two steps in six seconds", async ({ page }) => {
  await open(page, "#w=w1&s=1");
  await page.getByRole("button", { name: "Play" }).click();
  await expect.poll(() => stepOf(page), { timeout: 6000 }).toBeGreaterThanOrEqual(2);
});

test.describe("reduced motion", () => {
  test.use({ reducedMotion: "reduce" });

  test("J-DG1. autoplay does not start, and a step makes no animation", async ({ page }) => {
    await page.addInitScript(() => {
      const calls: number[] = [];
      (window as unknown as { __animateCalls: number[] }).__animateCalls = calls;
      const real = Element.prototype.animate;
      Element.prototype.animate = function (...a: Parameters<typeof real>) { calls.push(1); return real.apply(this, a); };
    });
    await open(page);
    await page.waitForTimeout(3000);
    expect(await stepOf(page)).toBe(0);
    await page.getByRole("button", { name: "Next" }).click();
    expect(await stepOf(page)).toBe(1);
    expect(await page.evaluate(() => document.getAnimations().length)).toBe(0);
    expect(await page.evaluate(() => (window as unknown as { __animateCalls: number[] }).__animateCalls.length)).toBe(0);
  });
});

test("J-DG1. outside reduced motion a step does animate the edge it takes", async ({ page }) => {
  await page.addInitScript(() => {
    const calls: number[] = [];
    (window as unknown as { __animateCalls: number[] }).__animateCalls = calls;
    const real = Element.prototype.animate;
    Element.prototype.animate = function (...a: Parameters<typeof real>) { calls.push(1); return real.apply(this, a); };
  });
  await open(page, "#w=w1&s=1");
  await page.getByRole("button", { name: "Next" }).click();
  expect(await page.evaluate(() => (window as unknown as { __animateCalls: number[] }).__animateCalls.length)).toBeGreaterThan(0);
});

test.describe("phone", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("J-DG1. no horizontal scroll at 390 px, and the phone layout is the one shown", async ({ page }) => {
    await open(page, "#w=w1&s=1");
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await expect(page.locator(".dg-narrow")).toBeVisible();
    await page.getByRole("button", { name: "Next" }).click();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
});

test.describe("dark", () => {
  test.use({ colorScheme: "dark" });

  test("J-DG1. dark mode resolves --bg to the dark token", async ({ page }) => {
    await open(page);
    expect(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--bg").trim())).toBe("#0C1319");
  });
});

async function serveBroken(page: Page, edit: (g: typeof GRAPH) => void) {
  await page.route("**/dev-graph/graph.json", async (route) => {
    const g = JSON.parse(JSON.stringify(GRAPH));
    edit(g);
    await route.fulfill({ contentType: "application/json", body: JSON.stringify(g) });
  });
}

test("J-DG1. a walkthrough step naming an unknown id shows the error banner", async ({ page }) => {
  await serveBroken(page, (g) => { g.walkthroughs[0].steps[1].at = "x.nope"; });
  await page.goto(base);
  const banner = page.locator(".dg-banner");
  await expect(banner).toBeVisible();
  await expect(banner).toContainText("x.nope");
});

test("J-DG1. steps with no edge between them show the error banner", async ({ page }) => {
  await serveBroken(page, (g) => { const s = g.walkthroughs[0].steps; [s[1], s[5]] = [s[5], s[1]]; });
  await page.goto(base);
  await expect(page.locator(".dg-banner")).toContainText("no edge");
});
