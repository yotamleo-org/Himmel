import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import { FLEET } from "../agui-fleet-fixture";
import { aguiBuilt, bootAgui, type AguiHarness } from "./agui-fixtures";

let h: AguiHarness;
test.skip(!aguiBuilt(), "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build");
test.afterEach(async () => { await h?.stop(); });

const at = (min: number) => new Date(Date.UTC(2026, 10, 8, 9, 0) + min * 60000).toISOString();
const merged = (n: number) => Array.from({ length: n }, (_, i) => {
  const span = 60 + i * 10;
  return { worker: `N${9100 + i}`, live_at: at(i * 10), merged_at: at(i * 10 + span), live_to_merged_min: span, to_pr_min: 20, ready_to_merged_min: 5 };
});
const color = (c: string, label: string) => ({ color: c, label });
const board = (over: Record<string, unknown> = {}, today = merged(5)) => ({
  schema: "himmel.board/1", generated_at: "2026-11-08T22:27:00+01:00", console: { name: "e2e-chief" }, sections: [],
  headline: { live: 1, cap: 15, merged_today: 69, needs_you: 0, blocked: 0 },
  bank: { week_pct: 46, five_hour_pct: 2 }, ci: { open: 13, green: 6, pending: 5, no_checks: 0, red: 2 },
  milestones: [], needs_you: [], workers: Array.from({ length: 20 }, (_, i) => ({ worker: `N${9100 + i}`, ticket: `HIMMEL-${910 + i}` })),
  trends: {
    worker_time: { unit: "min", today }, cost: null, console_cost: null,
    exploration: { window_h: 24, flag_tokens: 100000, sessions: 116, median_tokens: 122000, over_flag: 74 },
    failures: { since: "2026-11-08T22:07:00+01:00", classes: [
      { class: "error/Bash", sessions: 2, events: 11, route: "signal" },
      { class: "denied/guard-pr-check-literal", sessions: 2, events: 4, route: "signal" },
      { class: "mystery/odd", sessions: 1, events: 1, route: "signal" },
      { class: "suite/red", sessions: 1, events: 1, route: "signal" },
    ] },
    tools: [],
  },
  legend: {
    state: {}, stage: { live: color("acc", "LIVE"), pr: color("vio", "PR"), ready: color("ok", "READY") },
    ci: { green: color("ok", "green"), pending: color("warn", "pending"), red: color("bad", "red"), no_checks: color("mut", "no checks yet") },
    failure: { denial: color("warn", "guard denial"), error: color("bad", "tool error"), other: color("mut", "something else") },
  },
  cards: {}, ...over,
});
const card = (id: string, title: string, metric: string, unit: string, values: number[], week: object | null, version: object | null, running: object | null) => ({
  id, title, metric, unit, state: "ok", spark: values.map((value, i) => ({ key: `2026-W${40 + i}`, value })), week, version, running, sentence: "",
});
const cmp = (key: string, value: number, delta: number | null, prev_key: string | null) => ({ key, value, delta, prev_key, partial: false });
const rollup = (many = true) => ({ state: "ok", cards: [
  card("velocity", "Velocity", "merges per week", "merges", many ? [421, 550, 681, 774, 516] : [38], cmp("2026-W44", many ? 516 : 38, many ? -258 : null, many ? "2026-W43" : null), cmp("v1.1.2", 86, -142, "v1.1.1"), { key: "2026-W45", value: 402 }),
  card("cost", "Cost", "cost per ticket (Opus-eq)", "eq", many ? [2430000, 2400000, 1720000, 1840000, 2640000] : [2600000], cmp("2026-W44", 2600000, many ? 791000 : null, many ? "2026-W43" : null), null, null),
  card("health", "Health", "red-main incidents", "red main", many ? [4, 6, 2, 17, 3] : [3], cmp("2026-W44", 3, many ? -14 : null, many ? "2026-W43" : null), null, { key: "2026-W45", value: 5 }),
] });

async function open(page: Page, b: object, r: object, chief = true) {
  await page.route("**/api/agui/board**", (route) => route.fulfill({ json: b }));
  await page.route("**/api/rollup", (route) => route.fulfill({ json: r }));
  if (!chief) await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch().catch(() => null);
    if (!response) return route.abort();
    const fleet = await response.json();
    fleet.sessions = fleet.sessions.filter((s: { role: string }) => s.role !== "console");
    await route.fulfill({ response, json: fleet });
  });
  h = await bootAgui("", { fleet: true });
  await page.goto(h.url);
  await page.getByRole("navigation", { name: "Fleet views" }).getByRole("button", { name: "Trends" }).click();
}

test("1. twenty merged workers draw the 8 longest and a link for the other 12", async ({ page }) => {
  await open(page, board({}, merged(20)), rollup());
  await expect(page.locator(".bd-gt .bd-track")).toHaveCount(8);
  const drawn = await page.locator(".bd-gt .bd-w").evaluateAll((els) => els.map((e) => e.firstChild?.textContent ?? ""));
  expect([...drawn].sort()).toEqual(Array.from({ length: 8 }, (_, i) => `N${9112 + i}`));
  await expect(page.getByRole("button", { name: /^and 12 more, each shorter than 3h 0m/ })).toBeVisible();
  await page.getByRole("button", { name: /^and 12 more/ }).click();
  await expect(page.locator(".bd-drawer .bd-table tr")).toHaveCount(20);
  const total = async (worker: string) => {
    const text = await page.locator(".bd-drawer .bd-table tr", { has: page.locator("th", { hasText: new RegExp(`^${worker}$`) }) }).locator("td").innerText();
    return Number(/total (\d+)m/.exec(text)?.[1]);
  };
  for (let i = 0; i < 12; i++) expect(await total(`N${9100 + i}`), `N${9100 + i} is one of the 12 shorter workers`).toBeLessThan(180);
});

test("1b. with no live chief the tab says so, still draws the weekly band, and draws no Today or stuck section", async ({ page }) => {
  await open(page, board({}, merged(20)), rollup(), false);
  await expect(page.locator(".bd-nod", { hasText: "read a live chief's board" })).toContainText("No chief is live: start one, or read the weekly band above.");
  await expect(page.locator(".bd-nod b", { hasText: "Today" })).toBeVisible();
  await expect(page.locator(".bd-nod b", { hasText: "Where workers got stuck" })).toBeVisible();
  await expect(page.locator(".bd-gh", { hasText: "By week" })).toBeVisible();
  await expect(page.locator(".bd-wk svg.bd-wline")).toHaveCount(3);
  await expect(page.locator(".bd-gh", { hasText: "Today" })).toHaveCount(0);
  await expect(page.locator(".bd-gh", { hasText: "Where workers got stuck" })).toHaveCount(0);
  await expect(page.locator(".bd-gt")).toHaveCount(0);
  await expect(page.locator(".bd-aside")).toHaveCount(0);
});

test("2. a one-week roll-up draws its dot and says the line starts with the second", async ({ page }) => {
  await open(page, board(), rollup(false));
  await expect(page.locator(".bd-wk svg.bd-wline")).toHaveCount(0);
  await expect(page.locator(".bd-spark1")).toHaveCount(3);
  await expect(page.locator(".bd-spark1").first()).toContainText("one week so far: the line starts with the second");
  await expect(page.locator(".bd-spark1 circle").first()).toBeVisible();
  await expect(page.getByText("No earlier week to compare with yet").first()).toBeVisible();
});

test("2b. a roll-up with only a running week labels its value as the running week", async ({ page }) => {
  const r = rollup(false) as { cards: { week: { partial: boolean } }[] };
  r.cards.forEach((c) => { c.week.partial = true; });
  await open(page, board(), r);
  await expect(page.locator(".bd-v small").first()).toHaveText("2026-W44, running week");
});

test("3. a null CI or merged-today count says it could not be read, never 0", async ({ page }) => {
  await open(page, board({ ci: null, headline: { live: 1, cap: 15, merged_today: null, needs_you: 0, blocked: 0 } }), rollup());
  await expect(page.locator(".bd-nod", { hasText: "Merged today" })).toContainText("could not be read");
  await expect(page.locator(".bd-nod", { hasText: "Open PRs by CI" })).toContainText("could not be read");
  await expect(page.locator(".bd-big", { hasText: "merged today" })).toHaveCount(0);
  await expect(page.locator(".bd-big", { hasText: "open PR" })).toHaveCount(0);
});

test("4. a version delta names both versions, and the merged count says it is today's", async ({ page }) => {
  await open(page, board(), rollup());
  await expect(page.getByText("v1.1.2: 86, -142 vs v1.1.1")).toBeVisible();
  await expect(page.getByText("-258 vs W43")).toBeVisible();
  await expect(page.getByText("W45 so far: 402 merges, 5 red main")).toBeVisible();
  await expect(page.locator(".bd-big", { hasText: "69 PRs merged today" })).toContainText("calendar day");
  await expect(page.locator(".bd-td")).not.toContainText("24 h");
  await expect(page.getByText("vs last version")).toHaveCount(0);
});

test("5. the failure chip kind comes from the legend, and an unknown class reads as other", async ({ page }) => {
  await open(page, board(), rollup());
  const chips = page.locator(".bd-fl .bd-kd");
  await expect(chips).toHaveCount(3);
  await expect(chips.nth(0)).toHaveText("tool error");
  await expect(chips.nth(1)).toHaveText("guard denial");
  await expect(chips.nth(2)).toHaveText("something else");
  await expect(page.getByRole("button", { name: "1 more, with each one's route →" })).toBeVisible();
});

test("6. the tab row names the chief it reads, and at 390 px the ticket id drops and nothing scrolls sideways", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 900 });
  await open(page, board(), rollup());
  await expect(page.locator(".bd-aside")).toContainText(FLEET.console.name);
  expect(await page.locator(".bd-w small").count()).toBeGreaterThan(0);
  await expect(page.locator(".bd-w small").first()).toBeHidden();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true);
});
