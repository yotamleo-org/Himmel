// The Tool health tiles, names and Tool map columns match approved mockup v9. Reads the real page at 1280 and
// 390 px for the overview, Station, Tool map and guard drill-in views; each pair of shots is attached to the test.
// RED control: the last test removes the phone-card rule's effect (cards hidden at 390) and the check must report it.
import { test, expect, type Page } from "@playwright/test";
import { boot, type Harness } from "./fixtures";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// the real rollup builds the response (an ES module, so a child node runs it)
const ROLLUP = pathToFileURL(join(__dirname, "../../../eval/worker-digest/tool-health.mjs")).href;
const rollupToolHealth = (evals: object[], failures: object[], now: number, opts: object) => JSON.parse(execFileSync(process.execPath, ["--input-type=module", "-e",
  `import { rollupToolHealth } from ${JSON.stringify(ROLLUP)}; const [e, f, n, o] = JSON.parse(process.argv[1]); process.stdout.write(JSON.stringify(rollupToolHealth(e, f, new URLSearchParams(), n, {}, o)));`,
  JSON.stringify([evals, failures, now, opts])], { encoding: "utf8" }));

const NOW = Date.parse("2026-10-28T23:59:00Z");
const AGENT = { id: "main", role: "agent", kind: null, model: "gpt-6.1-sol" };
const SESSION = "48160000-0000-4000-8000-000000000101";
const tool = (name: string, calls: number, classes: Record<string, number> = {}) => {
  const denials = Object.values(classes).reduce((n, v) => n + v, 0);
  return { agent: AGENT, tool: name, calls, failures: denials, errors: 0, denials, classes, day: "2026-10-28" };
};
const digest = rollupToolHealth(
  [{ eval: "leg-trajectory", run_id: SESSION, status: "ok", ts: "2026-10-28T12:00:00Z", lane: "native", model: "gpt-6.1-sol", config: {},
    meta: { leg: true, started_ts: Date.parse("2026-10-28T12:00:00Z"), profile: "worker-impl", tool_health: [
      tool("Bash", 40, { "denied/block-read-secrets": 3, "denied/block-destructive-commands": 1 }), tool("Read", 12, { "denied/block-read-secrets": 2 }),
      tool("Skill:lean-skills:verification-before-completion", 4)] } }],
  [{ session: SESSION, agent: AGENT, class: "denied/block-read-secrets", failure: "denied", count: 5, recovered: null, tool_call_ids: [] },
   { session: SESSION, agent: AGENT, class: "denied/block-destructive-commands", failure: "denied", count: 1, recovered: null, tool_call_ids: [] }],
  NOW, { eligible: { "block-read-secrets": ["Read", "Bash"], "block-destructive-commands": ["Bash"] } });
const INVENTORY = {
  state: "ok", scanned_at: "2026-10-28T23:00:00.000Z",
  sources: [
    { id: "hooks-project", reads: "the project hooks", state: "ok", found: { wirings: 4, scripts: 3 } },
    { id: "plugins", reads: "installed_plugins.json", state: "ok", found: { on: 1, installed: 2 } },
    { id: "plugin-items", reads: "the plugin skills", state: "ok", found: { skills: 2, commands: 0, agents: 0, hook_wirings: 1 } },
    { id: "mcp-runtime", reads: "a live session", state: "absent", reason: "needs a session record", found: null },
  ],
  tools: [
    { kind: "skill", source: "alpha@himmel", name: "alpha:one" },
    { kind: "skill", source: "lean-skills@third", name: "lean-skills:verification-before-completion" },
    { kind: "mcp", source: "mcp-config", name: "qmd", configured_in: ["mcp-profiles"], loads_in_chief: true },
  ],
  hooks: ["block-destructive-commands.sh", "block-read-secrets.sh"].map((name) => ({ kind: "hook", source: "project", name, runs_twice: name.startsWith("block-read"), wired: [["PreToolUse", "Bash"]] })),
  clis: [{ name: "rtk", path: "~/bin/rtk", version: "9.9.9", state: "ok" }, { name: "qmd", path: null, version: null, state: "absent" }],
};

let h: Harness | undefined;
test.afterEach(async () => { await h?.stop(); h = undefined; });

async function open(page: Page, route: string, ready: string) {
  await page.route("**/api/tool-health*", (r) => r.fulfill({ json: digest }));
  await page.route("**/api/tool-inventory*", (r) => r.fulfill({ json: INVENTORY }));
  await page.goto(`${h!.url}&page=toolhealth`);
  await page.evaluate((r) => { location.hash = r; }, route);
  await page.locator(ready).first().waitFor();
  await page.waitForLoadState("networkidle");
}
const sideways = (page: Page) => page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);

for (const width of [1280, 390]) {
  test.describe(`at ${width}px`, () => {
    test.beforeEach(async ({ page }) => { h = await boot(); await page.setViewportSize({ width, height: 900 }); });

    test("overview: four cards; Recovery rides a note", async ({ page }, info) => {
      await open(page, "#/toolhealth", "[data-kpi]");
      expect(await page.locator("[data-kpi]").evaluateAll((els) => els.map((e) => (e as HTMLElement).dataset.kpi))).toEqual(["calls", "failed", "rate", "highest"]);
      await expect(page.locator('[data-note="recovery"]')).toContainText("Recovery");
      expect(await sideways(page)).toBe(false);
      await info.attach(`overview-${width}`, { body: await page.screenshot({ fullPage: true }), contentType: "image/png" });
    });

    test("Station: six tiles and human source names", async ({ page }, info) => {
      await open(page, "#/toolhealth/station", "[data-tile]");
      expect(await page.locator("[data-tile]").evaluateAll((els) => els.map((e) => (e as HTMLElement).dataset.tile))).toEqual(["plugins", "skills", "mcp", "wirings", "twice", "clis"]);
      await expect(page.locator('[data-tile="plugins"] .kv')).toHaveText("1 / 2");
      await expect(page.locator("#th-sources")).toContainText("Hooks · project");
      await expect(page.locator("#th-sources")).toContainText("MCP · runtime");
      await expect(page.locator("#th-sources")).not.toContainText("hooks-project");
      expect(await sideways(page)).toBe(false);
      await info.attach(`station-${width}`, { body: await page.screenshot({ fullPage: true }), contentType: "image/png" });
    });

    test("Tool map: the grid on a desktop, one card per source on a phone; the headers sort", async ({ page }, info) => {
      await open(page, "#/toolhealth/map", ".thmap");
      const grid = page.locator(".thmap"), cards = page.locator(".thcard");
      if (width > 560) {
        await expect(grid).toBeVisible();
        await expect(page.locator(".thcards")).toBeHidden();
        await expect(grid).toContainText("All sources");
        await expect(grid).toContainText("○ ");
        const first = () => page.locator(".thmap .mr button").first().innerText();
        const before = await first();
        await page.locator('.thmap [data-act="th-sort"][data-col="0"]').click();
        await page.locator('.thmap [data-act="th-sort"][data-col="0"]').click();
        expect(await first()).not.toBe(before);
      } else {
        await expect(grid).toBeHidden();
        expect(await cards.count()).toBeGreaterThan(0);
        await expect(cards.first()).toBeVisible();
      }
      expect(await sideways(page)).toBe(false);
      await info.attach(`map-${width}`, { body: await page.screenshot({ fullPage: true }), contentType: "image/png" });
    });

    test("guard drill-in: the This week cards", async ({ page }, info) => {
      await open(page, "#/toolhealth?guard=denied/block-read-secrets", '[data-stat="refused"]');
      await expect(page.locator("h3", { hasText: "This week" })).toBeVisible();
      await expect(page.locator('[data-stat="refused"]')).toHaveText("5");
      for (const id of ["rate", "busiest", "none", "eligible", "bash", "recovery"]) await expect(page.locator(`[data-stat="${id}"]`)).toBeVisible();
      expect(await sideways(page)).toBe(false);
      await info.attach(`guard-${width}`, { body: await page.screenshot({ fullPage: true }), contentType: "image/png" });
    });
  });
}

// the check itself: hiding the phone cards is reported, so a page with no cards cannot pass for a clean one
test("a phone map with its cards hidden is reported", async ({ page }) => {
  h = await boot();
  await page.setViewportSize({ width: 390, height: 900 });
  await open(page, "#/toolhealth/map", ".thcard");
  await page.addStyleTag({ content: ".thcards{display:none !important}" });
  await expect(page.locator(".thcard").first()).toBeHidden();
});
