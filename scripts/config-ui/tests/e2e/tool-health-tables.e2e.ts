// The Tool health tables stay readable at desktop and phone width. The page never overflows sideways, so the
// overflow check stays green while a squeezed column breaks "project" into "pro / jec / t". This reads the real page at
// 1280 and 390 px for the five tables (Hook wiring, overview Tools, overview Guards, Station sources, guard drill-in
// Refused by tool) and fails when a header or a short value breaks inside a word, or when a table wider than its panel
// is not reachable by scrolling inside its own box.
// RED control: the last test squeezes one cell with a planted width and the check must report it.
import { test, expect, type Page } from "@playwright/test";
import { boot, type Harness } from "./fixtures";
import { execFileSync } from "node:child_process";
import { join } from "node:path";

// the real rollup builds the response, so the fixture has the shape the server sends; it is an ES module and the
// Playwright runner loads specs as CommonJS, so a child node runs it
const ROLLUP = join(__dirname, "../../../eval/worker-digest/tool-health.mjs");
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
      tool("mcp__plugin_example_example__searchWorkspaceItemsUsingAQuery", 6), tool("Skill:lean-skills:verification-before-completion", 4)] } }],
  [{ session: SESSION, agent: AGENT, class: "denied/block-read-secrets", failure: "denied", count: 5, recovered: null, tool_call_ids: [] },
   { session: SESSION, agent: AGENT, class: "denied/block-destructive-commands", failure: "denied", count: 1, recovered: null, tool_call_ids: [] }],
  NOW, { eligible: { "block-read-secrets": ["Read", "Bash"], "block-destructive-commands": ["Bash"] } });
const INVENTORY = {
  state: "ok", scanned_at: "2026-10-28T23:00:00.000Z",
  sources: [{ id: "plugins", reads: "~/.claude/plugins/installed_plugins.json", state: "ok", found: { on: 1, installed: 2 } },
    { id: "hooks-project", reads: "the project's .claude/settings.json hooks block, read at runtime from the checkout the session started in", state: "absent", reason: "needs a session record from a session started in this checkout", found: null }],
  tools: [{ kind: "skill", source: "alpha@himmel", name: "alpha:one" },
    { kind: "mcp", source: "mcp-config", name: "qmd", configured_in: ["mcp-profiles", "the project .mcp.json", "the user settings file"], loads_in_chief: true }],
  // the wiring text of one hook is long, as on the real station: it takes the width the short columns need
  hooks: ["block-destructive-commands.sh", "block-read-secrets.sh", "auto-approve-safe-bash.sh"].map((name) => ({ kind: "hook", source: "project", name, runs_twice: false,
    wired: [["PreToolUse", "Bash"], ["PreToolUse", "PowerShell"], ["PreToolUse", "Edit|Write|MultiEdit|NotebookEdit"], ["PreToolUse", "mcp__plugin_example_example__.*|mcp__claude_ai_Example_MCP__.*"]] })),
  clis: [{ name: "rtk", path: "~/bin/rtk", version: "9.9.9", state: "ok" }, { name: "qmd", path: null, version: null, state: "absent" }],
};

let h: Harness | undefined;
test.afterEach(async () => { await h?.stop(); h = undefined; });

async function open(page: Page, route: string, section: string) {
  await page.route("**/api/tool-health*", (r) => r.fulfill({ json: digest }));
  await page.route("**/api/tool-inventory*", (r) => r.fulfill({ json: INVENTORY }));
  await page.goto(`${h!.url}&page=toolhealth`);
  await page.evaluate((r) => { location.hash = r; }, route);
  await page.locator(`${section} table.data`).first().waitFor();
  await page.waitForLoadState("networkidle");
}

// every problem in the data tables of the given sections (the five tables of the ticket): [where, what]
async function problems(page: Page, sections: string[]) {
  return page.evaluate((sel) => {
    const out: string[] = [];
    // a word is a run of characters between spaces and hyphens (a hyphen is a place a line may end); it breaks when its box spans two lines
    const broken = (el: Element) => {
      const out: string[] = [];
      const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        for (const m of (n.textContent || "").matchAll(/[^\s-]+/g)) {
          const r = document.createRange();
          r.setStart(n, m.index!);
          r.setEnd(n, m.index! + m[0].length);
          if (new Set([...r.getClientRects()].filter((q) => q.width > 0).map((q) => Math.round(q.top))).size > 1) out.push(m[0]);
        }
      }
      return out;
    };
    for (const t of document.querySelectorAll(sel.map((s) => `${s} table.data`).join(", "))) {
      if (!t.getClientRects().length) continue; // inside a closed details
      const where = t.closest("section")?.id || "table";
      // a column that holds free text (td.wrap) may break anywhere; every other header and value keeps each word whole
      for (const c of t.querySelectorAll("th, td:not(.wrap)")) for (const w of broken(c)) out.push(`${where}: ${c.tagName === "TH" ? "header" : "value"} word "${w}" breaks`);
      const scroll = t.closest(".scroll")!;
      const wide = t.getBoundingClientRect().width > scroll.clientWidth + 1;
      if (wide && !/^(auto|scroll)$/.test(getComputedStyle(scroll).overflowX)) out.push(`${where}: wider than its box and not scrollable`);
      if (scroll.getBoundingClientRect().right > window.innerWidth + 1) out.push(`${where}: its box runs past the viewport`);
    }
    if (document.documentElement.scrollWidth > window.innerWidth + 1) out.push("the page scrolls sideways");
    return out;
  }, sections);
}

const VIEWS: [string, string, string[]][] = [
  ["Hook wiring", "#/toolhealth/hooks", ["#th-hooks"]],
  ["Station sources", "#/toolhealth/station", ["#th-sources", "#th-mcp", "#th-clis"]],
  ["overview Tools and guards", "#/toolhealth", ["#th-tools", "#th-guards"]],
  ["guard drill-in, Refused by tool", "#/toolhealth?guard=denied/block-read-secrets", ["#th-guard-tools"]],
];
for (const width of [1280, 390]) {
  for (const [name, route, sections] of VIEWS) {
    test(`${name} keeps every word whole at ${width}px`, async ({ page }) => {
      h = await boot();
      await page.setViewportSize({ width, height: 900 });
      await open(page, route, sections[0]);
      for (const s of sections) expect(await page.locator(`${s} table.data`).count(), `${s} renders a table`).toBeGreaterThan(0);
      expect(await problems(page, sections)).toEqual([]);
    });
  }
}

// the check itself: a squeezed cell is reported, so a scan that finds nothing cannot pass for a clean page
test("a squeezed cell is reported", async ({ page }) => {
  h = await boot();
  await page.setViewportSize({ width: 1280, height: 900 });
  await open(page, "#/toolhealth/hooks", "#th-hooks");
  await page.evaluate(() => {
    for (const c of document.querySelectorAll<HTMLElement>("#th-hooks table.data :is(th, td):nth-child(2)")) {
      c.style.whiteSpace = "normal";
      c.style.overflowWrap = "anywhere";
      c.style.width = "1ch";
      c.style.maxWidth = "1ch";
    }
  });
  expect((await problems(page, ["#th-hooks"])).some((p) => /value word "project" breaks/.test(p))).toBe(true);
});
