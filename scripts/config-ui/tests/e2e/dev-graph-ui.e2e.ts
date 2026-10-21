// Journey J-DG2: the console's Workflow page draws the development graph from the same graph.json the docs page uses,
// served read-only by the config server under its own CSP (default-src 'self').
import { test, expect, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import { request } from "node:http";
import { join, resolve } from "node:path";
import { boot, type Harness } from "./fixtures";

const GRAPH = JSON.parse(readFileSync(resolve(__dirname, "../../../../docs/guide/dev-graph/graph.json"), "utf8"));
const w1 = GRAPH.walkthroughs.find((x: { id: string }) => x.id === "w1");

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const origin = () => new URL(h.url).origin;
const stepOf = async (page: Page) => Number(await page.getByRole("slider").inputValue());
const violations = (page: Page) => page.evaluate(() => (window as unknown as { __csp: string[] }).__csp);

async function open(page: Page, hash = "") {
  await page.addInitScript(() => {
    const seen: string[] = [];
    (window as unknown as { __csp: string[] }).__csp = seen;
    document.addEventListener("securitypolicyviolation", (e) => seen.push(`${e.violatedDirective} ${e.blockedURI}`));
  });
  h = await boot();
  await page.goto(h.url);
  await page.locator("#pages a", { hasText: "Workflow" }).click();
  if (hash) await page.evaluate((x) => { location.hash = x; }, hash);
  await page.locator(".dg-wide .dg-node").first().waitFor({ state: "attached" });
}

// A raw request keeps the path as written; fetch and page.request normalise "..".
function rawGet(path: string): Promise<{ status: number; type: string; body: string }> {
  const u = new URL(origin());
  return new Promise((ok, fail) => {
    const r = request({ host: u.hostname, port: u.port, path, method: "GET" }, (res) => {
      let body = "";
      res.on("data", (d) => (body += d));
      res.on("end", () => ok({ status: res.statusCode ?? 0, type: String(res.headers["content-type"] ?? ""), body }));
    });
    r.on("error", fail);
    r.end();
  });
}

test("J-DG2. the rail shows Workflow, and the page draws every node of graph.json from /dev-graph/graph.json", async ({ page }) => {
  h = await boot();
  const loaded = page.waitForResponse((r) => new URL(r.url()).pathname === "/dev-graph/graph.json");
  await page.goto(h.url);
  await page.locator("#pages a", { hasText: "Workflow" }).click();
  expect((await loaded).status()).toBe(200);
  await expect(page.locator(".dg-wide .dg-node")).toHaveCount(GRAPH.nodes.length);
  await expect(page.locator("#pages a[aria-current=page]")).toHaveText("Workflow");
});

test("J-DG2. the page runs under the server's CSP with zero violations", async ({ page }) => {
  await open(page, "#/workflow&w=w1&s=1");
  await page.getByRole("button", { name: "Next" }).click();
  await expect(page.locator(".dg-caption")).toContainText("Step 2 of");
  expect(await violations(page)).toEqual([]);
});

test("J-DG2. the CSP violation detector fires on a planted inline style", async ({ page }) => {
  await open(page, "#/workflow&w=w1&s=1");
  await page.evaluate(() => document.body.setAttribute("style", "color: red"));
  await expect.poll(() => violations(page)).not.toEqual([]);
});

test("J-DG2. W1 steps to its last step, and the walkthrough keys ride the fragment", async ({ page }) => {
  await open(page, "#/workflow&w=w1&s=1");
  for (let i = 1; i < w1.steps.length; i++) await page.getByRole("button", { name: "Next" }).click();
  expect(await stepOf(page)).toBe(w1.steps.length - 1);
  await expect(page.locator(".dg-caption")).toContainText(`Step ${w1.steps.length} of ${w1.steps.length}`);
  await expect(page).toHaveURL(new RegExp(`#/workflow&w=w1&s=${w1.steps.length}$`));
  await page.reload();
  await page.locator(".dg-wide .dg-node").first().waitFor({ state: "attached" });
  expect(await stepOf(page)).toBe(w1.steps.length - 1);
});

test("J-DG2. a deep link to another walkthrough step restores it", async ({ page }) => {
  await open(page, "#/workflow&w=w2&s=7");
  await expect(page.getByLabel("Walkthrough")).toHaveValue("w2");
  expect(await stepOf(page)).toBe(6);
});

test("J-DG2. leaving the page and coming back does not stack a second graph", async ({ page }) => {
  await open(page, "#/workflow&w=w1&s=1");
  await page.locator('#pages a[href="#/config"]').click();
  await expect(page.locator(".dg")).toHaveCount(0);  await page.locator("#pages a", { hasText: "Workflow" }).click();
  await page.locator(".dg-wide .dg-node").first().waitFor({ state: "attached" });
  await expect(page.locator(".dg")).toHaveCount(1);
});

test("J-DG2. /dev-graph/ serves its four files read-only and nothing outside the directory", async () => {
  h = await boot();
  for (const [file, type] of [["graph.json", "application/json"], ["dev-graph.js", "javascript"], ["dev-graph.css", "text/css"]]) {
    const r = await rawGet(`/dev-graph/${file}`);
    expect(r.status, file).toBe(200);
    expect(r.type, file).toContain(type);
    expect(r.body, file).toBe(readFileSync(join(__dirname, "../../../../docs/guide/dev-graph", file), "utf8"));
  }
  // the encoded ones reach the handler as written: a .js file that exists outside the directory is stopped by the realpath guard alone.
  const out = "..%2f..%2f..%2fscripts%2fconfig-ui";
  for (const path of ["/dev-graph/../server.ts", `/dev-graph/${out}%2fserver.ts`, `/dev-graph/${out}%2fpublic%2fnav.js`, `/dev-graph/%2e%2e%2f..%2f..%2fCLAUDE.md`, "/dev-graph/", "/dev-graph/nope.json"]) {
    expect((await rawGet(path)).status, path).toBe(404);
  }
  const post = await new Promise<number>((ok, fail) => {
    const u = new URL(origin());
    const r = request({ host: u.hostname, port: u.port, path: "/dev-graph/graph.json", method: "POST" }, (res) => { res.resume(); ok(res.statusCode ?? 0); });
    r.on("error", fail);
    r.end();
  });
  expect(post).toBeGreaterThanOrEqual(400);
});

test.describe("phone", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("J-DG2. no horizontal scroll at 390 px, the phone layout is shown", async ({ page }) => {
    await open(page, "#/workflow&w=w1&s=1");
    await expect(page.locator(".dg-narrow")).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
});
