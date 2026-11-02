// The Board page, run for real: `himmelctl ui` over a seeded Jira mirror (three versions, one chain, a saved drift run).
// One Board entry in the rail; the old Roadmap and Kanban routes land on it; the version strip, the drift banner, the chain badge,
// the three tabs and the lanes draw from the seeded sources; no console error at 1280 and 390 px, light and dark.
// E2E_SHOTS=<dir> saves the build-side screenshot of each frame, named board-<width>-<scheme>-<tab>.png, to pair with the mockup.
import { test, expect, type Page } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { boot, type Harness } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const shot = async (page: Page, name: string) => { const d = process.env.E2E_SHOTS; if (d) { mkdirSync(d, { recursive: true }); await page.screenshot({ path: join(d, `${name}.png`), fullPage: true }); } };
const consoleErrors = (page: Page) => { const errs: string[] = []; page.on("console", (m) => { if (m.type() === "error") errs.push(m.text()); }); page.on("pageerror", (e) => errs.push(String(e))); return errs; };
const go = async (page: Page, hash: string) => { await page.evaluate((x) => { location.hash = x; }, hash); await page.locator("#main h1").filter({ hasText: "Board" }).waitFor(); await page.waitForLoadState("networkidle"); };
async function open(page: Page) {
  h = await boot({}, { tracker: "jira", board: true });
  await page.goto(h.url);
  await page.locator("nav.pages").waitFor();
}

test("the rail has one Board entry, no Roadmap and no Kanban", async ({ page }) => {
  await open(page);
  const labels = await page.locator("nav.pages a").allTextContents();
  expect(labels.filter((l) => l.startsWith("Board"))).toHaveLength(1);
  expect(labels.some((l) => /^(Roadmap|Kanban)/.test(l))).toBe(false);
});

test("the old Roadmap and Kanban routes land on the Board page", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  for (const [from, to] of [["#/roadmap", "#/board"], ["#/roadmap/v1.1.4", "#/board?v=v1.1.4"], ["#/kanban", "#/board?v=all"]]) {
    await page.evaluate((x) => { location.hash = x; }, from);
    await expect.poll(() => page.evaluate(() => location.hash)).toBe(to);
    await expect(page.locator('#pages a[aria-current="page"]')).toHaveText(/^Board/);
    await expect(page.locator("#main h1")).toHaveText("Board");
  }
  // a bookmark of the old landing fragment resolves the same way
  await page.goto("about:blank"); // a fragment-only change would not reload the page, and the landing is read at load
  await page.goto(`${h.url}&page=kanban`);
  await expect(page.locator("#main h1")).toHaveText("Board");
  expect(await page.evaluate(() => location.hash)).toBe("#/board?v=all");
});

test("the Board draws the seeded mirror: strip, drift banner, chain badge, lanes, and the three tabs", async ({ page }) => {
  const errs = consoleErrors(page);
  await open(page);
  await go(page, "#/board");
  // the version strip: one tile per version, the running one selected
  const tiles = page.locator(".rm-vstrip .rm-vt");
  await expect(tiles).toHaveCount(3);
  await expect(tiles.nth(1)).toHaveAttribute("aria-current", "true");
  await expect(tiles.nth(0)).toContainText("released 2026-10-19");
  await expect(tiles.nth(0)).toContainText("1 still open: HIMMEL-12");
  // the drift banner counts the real row; the transient row is named, not counted
  await expect(page.locator("#main .alert").first()).toContainText("1 drift row");
  await expect(page.locator("#main .alert").first()).toContainText("1 transient");
  // the lanes of the running version, with the chain badge on a chain ticket and none on the others
  await expect(page.locator(".rm-card", { hasText: "First chain step" })).toBeVisible();
  await expect(page.locator(".rm-card", { hasText: "Old shipped work" })).toHaveCount(0);
  await expect(page.locator(".rm-card", { hasText: "Second chain step" }).locator(".rm-chain")).toContainText("memory 2/2 · can launch");
  await expect(page.locator(".rm-card", { hasText: "Not in any chain" }).locator(".rm-chain")).toHaveCount(0);
  await expect(page.locator(".rm-card[draggable]").first()).toBeVisible(); // drag and the Sector select are still there
  // no registry-less made-up number: the wait link counts the chain read's own rows
  await expect(page.locator(".rm-link").first()).toContainText("0 wait for you");
  // Chains tab
  await page.getByRole("tab", { name: /^Chains/ }).click();
  await expect(page.locator("#rm-chain-memory")).toContainText("1/2 done");
  await expect(page.locator("#cn-HIMMEL-2")).toContainText("can launch");
  // the badge opens the Chains tab at the ticket
  await go(page, "#/board");
  await page.locator(".rm-card", { hasText: "Second chain step" }).locator(".rm-chain").click();
  await expect.poll(() => page.evaluate(() => location.hash)).toBe("#/board?tab=chains&at=HIMMEL-2");
  await expect(page.locator("#cn-HIMMEL-2")).toHaveClass(/rm-at/);
  // Tidy up: the status-drift rows, then the sections the Roadmap page held
  await page.getByRole("tab", { name: /^Tidy up/ }).click();
  await expect(page.locator("#rm-status-drift")).toContainText("VERSION-DRIFT");
  await expect(page.locator("#rm-status-drift")).toContainText("jira release request v1.1.3");
  for (const id of ["rm-drift", "rm-sync", "rm-librarian"]) await expect(page.locator(`#${id}`)).toBeVisible();
  expect(errs).toEqual([]);
});

for (const [width, height] of [[1280, 900], [390, 844]]) {
  for (const scheme of ["light", "dark"] as const) {
    test(`the Board at ${width} px, ${scheme}: every tab draws, no console error, no sideways scroll`, async ({ page }) => {
      const errs = consoleErrors(page);
      await page.setViewportSize({ width, height });
      await page.emulateMedia({ colorScheme: scheme });
      await open(page);
      for (const tab of ["roadmap", "chains", "tidy"]) {
        await go(page, `#/board?tab=${tab}`);
        await expect(page.locator(`.tabs a[aria-selected="true"]`)).toHaveAttribute("href", new RegExp(`tab=${tab}`));
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
        await shot(page, `board-${width}-${scheme}-${tab}`);
      }
      expect(errs).toEqual([]);
    });
  }
}

test("with no drift file and no chain registry the Board says so in words and shows no count", async ({ page }) => {
  h = await boot({}, { tracker: "jira" });
  await page.goto(h.url);
  await page.locator("nav.pages").waitFor();
  await go(page, "#/board");
  await expect(page.locator("#main")).toContainText("drift: not read");
  await expect(page.locator(".rm-link").first()).toContainText("waits for you: not read");
  await expect(page.locator(".rm-chain")).toHaveCount(0);
  await page.getByRole("tab", { name: /^Chains/ }).click();
  await expect(page.locator("#main .nodata")).toContainText("no chain registry");
});
