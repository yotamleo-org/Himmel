// The Morning report page and the four Reports and shifts settings, against the real `himmelctl ui` over a
// two-day fixture (reports for 27 and 28 October, shifts.jsonl with one shift per day). E2E_SHOTS=<dir> also saves a
// screenshot of each frame there, for the side-by-side with the approved mockup.
import { test, expect, type Page } from "@playwright/test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { boot, type Harness } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const root = () => join(h.legDoc, "..", "..");
const shot = async (page: Page, name: string) => { const d = process.env.E2E_SHOTS; if (d) { mkdirSync(d, { recursive: true }); await page.screenshot({ path: join(d, `${name}.png`), fullPage: true }); } };
const report = (n: number, bar: string) => [
  "# 🌅 Morning Report", "", `> The tiles, Completed and Chiefs cover ${bar}. Spend per shift covers each shift over its own [opened, closed).`, "> Day starts: local midnight on the station · change on Configure.", "",
  "## ✅ What shipped", "", `**${n}** PRs merged to main · **5** commits · **2** Done (cross-ref'd). Detail: Completed, below.`, "",
  "## ⏳ What waits on you", "", "- **2** open PR(s) to review/merge", "- **1** worker(s) awaiting your GO", "- **0** worker question(s)", "",
  "## 💸 What it spent", "", "- Claude usage of the shift (last 24h): weekly bank **+4.5** points", "",
  "## ▶️ What runs next", "", "- **2** In-Progress ticket(s) in flight.", "",
  "## 👥 Chiefs", "", "| Chief | Span | PRs merged | Shift |", "|---|---|---|---|", "| IH | 01:00 to 07:00 | 2 | night 20:00 to 08:00 |", "",
  "## 💸 Spend per shift", "", "| Shift | Span | PRs merged | Chiefs | Claude bank | Codex tokens | Codex bank | API $ | OpenRouter $ |", "|---|---|---|---|---|---|---|---|---|",
  "| night | 20:00 to 08:00 | 2 | 1 | 41% (cadence log) | 3400 tokens (codex rollouts) | not available | $2.50 (local-priced) | not available |", "",
].join("\n");

function seed() {
  writeFileSync(join(root(), "morning-report-2026-10-27.md"), report(3, "Tue 27 Oct 00:00 to Wed 28 Oct 00:00"));
  writeFileSync(join(root(), "morning-report-2026-10-28.md"), report(7, "Wed 28 Oct 00:00 to Thu 29 Oct 00:00"));
}

test("the Morning report page: day selector, five tiles, per-shift spend, an empty state for a missing day", async ({ page }) => {
  h = await boot();
  seed();
  await page.goto(`${h.url}&page=report`);
  await page.locator("h1", { hasText: "Morning report" }).waitFor();
  await expect(page.locator("nav.pages a", { hasText: "Morning report" })).toHaveAttribute("aria-current", "page");
  const chips = page.locator(".rp-days .chip");
  await expect(chips.filter({ hasText: "Wed 28 Oct" })).toHaveAttribute("aria-pressed", "true");
  await expect(page.locator(".tiles .tile")).toHaveCount(5);
  await expect(page.locator(".tile", { hasText: "What shipped" }).locator(".num")).toHaveText("7");
  await expect(page.locator(".tile", { hasText: "Open PRs" }).locator(".num")).toHaveText("2");
  await expect(page.locator(".rp-bar")).toContainText("Day starts: local midnight on the station");
  await expect(page.locator("table.data").last()).toContainText("41% (cadence log)");
  await expect(page.locator("table.data").last()).toContainText("not available");
  await shot(page, "report-newest");
  await chips.filter({ hasText: "Tue 27 Oct" }).click();
  await expect(page.locator(".tile", { hasText: "What shipped" }).locator(".num")).toHaveText("3");
  await shot(page, "report-earlier-day");
  await page.evaluate(() => { location.hash = "#/report?day=2026-10-25"; });
  await expect(page.locator("#no-report")).toContainText("No report was made for Sunday 25 October");
  await shot(page, "report-no-report");
});

test("the four settings show on Configure, save, and land in the himmel config", async ({ page }) => {
  h = await boot();
  await page.goto(h.url);
  await page.locator("#h-configure").waitFor();
  await page.locator('button.tile[data-tile="scope"]').click();
  await expect(page.locator("#reports")).toBeVisible();
  await expect(page.locator('input[data-rs="report_day"][value="local"]')).toBeChecked();
  await expect(page.locator('[data-rs="idle"]')).toHaveValue("60");
  await expect(page.locator('[data-rs="cut1"]')).toHaveValue("08:00");
  await expect(page.locator('[data-rs="cut2"]')).toHaveValue("20:00");
  await expect(page.locator('[data-rs="minrun"]')).toHaveValue("4");
  await shot(page, "configure-reports-defaults");
  await page.locator('input[data-rs="report_day"][value="utc"]').check();
  await page.locator('[data-rs="idle"]').fill("90");
  await page.locator('[data-rs="cut1"]').fill("07:30");
  await page.locator('[data-rs="cut2"]').fill("19:30");
  await page.locator('[data-rs="minrun"]').fill("3");
  await page.locator('[data-act="reports-save"]').click();
  await expect(page.locator("#reports")).toContainText("saved");
  await shot(page, "configure-reports-saved");
  const cfg = JSON.parse(readFileSync(join(h.home, ".himmel", "config.json"), "utf8"));
  expect(cfg.reports).toEqual({ report_day: "utc", shift_idle_min: 90, shift_cuts: ["07:30", "19:30"], shift_min_run_h: 3 });
});
