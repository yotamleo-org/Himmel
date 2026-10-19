// the AG-UI page against the real server, driven by a journal that is APPENDED to
// while the page is open (a live stream over the real SSE path). Needs agui-web/dist
// (`cd scripts/config-ui/agui-web && bun install && bun run build`); skipped, loudly, when absent.
import { test, expect } from "@playwright/test";
import { CLOUD, FLEET, PRIOR_CONSOLE } from "../agui-fleet-fixture";
import { aguiBuilt, bootAgui, denseRun, J, play, type AguiHarness } from "./agui-fixtures";
import { shortName } from "../../agui-web/src/fleet-model";
import type { Page } from "@playwright/test";

// a card shows a session's short name (the full one is its title), so rows are found by their id.
const card = (page: Page, name: string) => page.locator(`[id="fleet-${name}"]`);
// A card is one line until its chevron opens the status and lineage detail (the name itself links to the run page).
const expand = (page: Page, name: string) => card(page, name).locator("> .fleet-line .fleet-chev").click();

// a live page keeps tailing after a turn ends, so it reads idle (never "finished") until the stream closes.
const IDLE = /^idle · last event \d+s ago$/;

let h: AguiHarness;
test.skip(!aguiBuilt(), "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build");
test.afterEach(async () => { await h?.stop(); });

test("1. appended journal lines render live: run start, a tool call, text, run end", async ({ page }) => {
  h = await bootAgui();
  await page.goto(h.url);
  await expect(page.getByText("Waiting for the agent's first event.")).toBeVisible();

  h.append(J.prompt("List the files in the repo root."));
  await expect(page.getByRole("status")).toHaveText("live");

  h.append(J.tool("toolu_ls", "Bash", { command: "ls", description: "List files" }));
  const call = page.locator(".call", { hasText: "Bash" });
  await expect(call).toContainText("List files");
  await expect(call).toContainText("running");

  h.append(J.result("toolu_ls", "README.md\nscripts"));
  await expect(call).toContainText("done");
  await call.locator(".call-head").click();
  await expect(call.locator(".call-body")).toContainText("README.md");

  h.append(J.text("Two entries: README.md and scripts."));
  await expect(page.locator(".msg", { hasText: "Two entries" })).toBeVisible();

  h.append(J.end());
  await expect(page.getByRole("status")).toHaveText(IDLE);
  await expect(page.locator(".top .meta")).toContainText(/^started \d\d:\d\d:\d\d.* · 1 turn · \d+ events/);
});

test("2. a wrong token shows the page's error state, not a transcript", async ({ page }) => {
  h = await bootAgui(J.prompt("hi") + J.text("hello") + J.end());
  await page.goto(h.url.replace(/#t=[0-9a-f]{64}/, `#t=${"0".repeat(64)}`));
  await expect(page.getByRole("alert")).toContainText("The run stopped");
  await expect(page.getByRole("status")).toHaveText("stopped");
  await expect(page.locator(".msg")).toHaveCount(0);
});

for (const [name, scheme, size] of [
  ["dark at desktop width", "dark", { width: 1280, height: 800 }],
  ["light at desktop width", "light", { width: 1280, height: 800 }],
  ["dark at phone width", "dark", { width: 375, height: 700 }],
  ["light at phone width", "light", { width: 375, height: 700 }],
] as const) {
  test(`3. renders in ${name} with no horizontal overflow`, async ({ browser }) => {
    h = await bootAgui(J.prompt("go") + J.tool("toolu_a", "Bash", { command: "echo " + "x".repeat(200), description: "long" }) + J.result("toolu_a", "ok") + J.text("done") + J.end());
    const ctx = await browser.newContext({ colorScheme: scheme, viewport: size });
    const page = await ctx.newPage();
    await page.goto(h.url);
    await expect(page.getByRole("status")).toHaveText(IDLE);
    await expect(page.locator(".call")).toBeVisible();
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    await ctx.close();
  });
}

for (const scheme of ["dark", "light"] as const) {
  for (const width of [1280, 390]) {
    test(`dense strip: ten bands in ${scheme} at ${width}px leave the transcript in view`, async ({ page }, info) => {
      await page.setViewportSize({ width, height: 800 });
      await page.emulateMedia({ colorScheme: scheme });
      h = await bootAgui(denseRun());
      await page.goto(h.url);
      await expect(page.locator(".band")).toHaveCount(10);
      await page.screenshot({ path: info.outputPath("dense.png") });
      const strip = page.getByRole("region", { name: "Tool calls over time, by agent" });
      await expect.poll(() => page.locator(".transcript .msg").first().evaluateAll(
        ([el]) => el?.getClientRects()[0]?.bottom ?? Infinity,
      ), { timeout: 15_000 }).toBeLessThan(800);
      const size = await strip.evaluate((el) => ({ height: el.clientHeight, scroll: el.scrollHeight }));
      expect(size.height).toBeLessThanOrEqual(240);
      expect(size.scroll).toBeGreaterThan(size.height);
      await strip.focus();
      await page.keyboard.press("End");
      await expect.poll(() => strip.evaluate((el) => el.scrollTop)).toBeGreaterThan(0);
      const band = page.locator(".band").nth(9);
      const toggle = band.getByRole("button", { name: "10 CV cold review 9 (v7 correctness)", exact: true });
      await expect(toggle).toHaveAttribute("title", "CV cold review 9 (v7 correctness) · subagent");
      await expect(toggle).toHaveAttribute("aria-expanded", "false");
      await expect(band.locator(".bar")).toHaveCount(0);
      await expect(band.locator(".agent-badge")).toHaveText("10");
      await toggle.focus();
      await page.keyboard.press("Enter");
      await expect(toggle).toHaveAttribute("aria-expanded", "true");
      await expect(band.locator(".bar")).toHaveCount(2);
      await band.locator(".bar").first().click();
      await expect(page.locator("#call-read9")).toBeFocused();
      await toggle.click();
      await expect(toggle).toHaveAttribute("aria-expanded", "false");
      await expect(band.locator(".bar")).toHaveCount(0);
      expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(0);
    });
  }
}

// the leg's /pr-check round with a critic subagent (SCENE), its transcript in a separate file.
// Steps are a few ms apart so the server's timestamp merge interleaves the two files as they were written.
const spaced = (h: AguiHarness) => play(h, undefined, () => new Promise((r) => setTimeout(r, 15)));

test("4. each agent is named with its role and model, its work under its name, and a filter shows one agent", async ({ page }) => {
  h = await bootAgui();
  await spaced(h);
  await page.goto(h.url);
  await expect(page.getByRole("status")).toHaveText(IDLE);
  const agents = page.locator(".agents .agent");
  await expect(agents).toHaveCount(2);
  await expect(agents.nth(0)).toContainText("HIMMEL-1957-N1290-check-ci-cap");
  await expect(agents.nth(0)).toContainText("worker session · opus 5.5");
  await expect(agents.nth(1)).toContainText("correctness critic");
  await expect(agents.nth(1)).toContainText("critic · code-reviewer · sonnet 5.5");
  // the critic's Read sits in a block headed by the critic, one step in; the leg's calls do not
  const critic = page.locator(".block.sub", { hasText: "correctness critic" });
  await critic.locator(".fold-head").click();
  await expect(critic.locator(".call", { hasText: "Read" })).toBeVisible();
  await expect(critic.locator(".call", { hasText: "Push the fix" })).toHaveCount(0);
  await expect(page.locator(".band")).toHaveCount(2);

  await agents.nth(1).click();
  await expect(agents.nth(1)).toHaveAttribute("aria-pressed", "true");
  await expect(page.locator(".call", { hasText: "Push the fix" })).toHaveCount(0);
  await expect(page.locator(".call", { hasText: "Grep" })).toBeVisible();
  await page.getByRole("button", { name: "Show every agent" }).click();
  await expect(page.locator(".call", { hasText: "Push the fix" })).toBeVisible();
});

test("5. failures are marked by kind, counted per agent, and the jump control walks them in order", async ({ page }) => {
  h = await bootAgui();
  await spaced(h);
  await page.goto(h.url);
  await expect(page.getByRole("status")).toHaveText(IDLE);
  await expect(page.locator(".fails-count")).toHaveText("4 failures");
  await expect(page.locator(".agents .agent").nth(0)).toContainText("4 failures");
  await expect(page.locator(".call.failed")).toHaveCount(3);
  await expect(page.locator(".call.failed.suite .badge")).toHaveText("suite failed");
  await expect(page.locator(".call.failed.denied .badge")).toHaveText("denied");
  await expect(page.locator(".call.failed.blocked .badge")).toHaveText("blocked");
  await expect(page.locator(".msg.failed.blocked")).toContainText("Holding for the console");
  await expect(page.locator(".bar.failed")).toHaveCount(3);

  // filtered to the critic (no failures), a jump shows everyone again and lands on the first failure
  await page.locator(".agents .agent").nth(1).click();
  await page.getByRole("button", { name: "Next failure" }).click();
  await expect(page.locator(".fails-count")).toHaveText("4 failures · 1 of 4");
  await expect(page.locator("#call-toolu_suite")).toBeFocused();
  await expect(page.locator("#call-toolu_suite")).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator(".call.failed.suite .call-body")).toContainText("not ok 7");
  await page.getByRole("button", { name: "Next failure" }).click();
  await expect(page.locator("#call-toolu_push")).toBeFocused();
  await page.getByRole("button", { name: "Previous failure" }).click();
  await expect(page.locator("#call-toolu_suite")).toBeFocused();
});

test("6. long tool output shows its head with a control for the rest", async ({ page }) => {
  h = await bootAgui();
  await spaced(h);
  await page.goto(h.url);
  await expect(page.getByRole("status")).toHaveText(IDLE);
  await page.locator(".block.sub .fold-head").click(); // the finished subagent's block is folded
  const read = page.locator(".call", { hasText: "Read" });
  await read.locator(".call-head").click();
  await expect(read.locator(".call-body pre").last()).not.toContainText("line 40");
  await read.getByRole("button", { name: "Show all 40 lines" }).click();
  await expect(read.locator(".call-body pre").last()).toContainText("line 40");
});

test("7. the agent view keeps both themes and phone width free of horizontal overflow", async ({ browser }) => {
  h = await bootAgui();
  await spaced(h);
  for (const scheme of ["dark", "light"] as const) {
    const ctx = await browser.newContext({ colorScheme: scheme, viewport: { width: 375, height: 700 } });
    const page = await ctx.newPage();
    await page.goto(h.url);
    await expect(page.getByRole("status")).toHaveText(IDLE);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    await ctx.close();
  }
});

test("8. a running subagent shows running with its current call, then flips to done when its Agent call returns", async ({ page }) => {
  h = await bootAgui();
  await page.goto(h.url);
  const sub = { sub: "b4d2f1", model: "claude-sonnet-5-5" };
  h.append(J.prompt("Check the diff with a critic."));
  h.append(J.tool("toolu_agent", "Agent", { description: "diff critic", subagent_type: "pr-review-toolkit-himmel:code-reviewer", prompt: "Read check-ci.sh" }));
  h.appendSub("b4d2f1", J.prompt("Read check-ci.sh", sub));
  h.appendSub("b4d2f1", J.tool("toolu_r", "Read", { file_path: "scripts/check-ci.sh" }, sub));
  // by its name: the leg's own row also names the critic, in the Agent call it is running
  const critic = page.locator(".agents li", { has: page.locator(".agent-name", { hasText: "diff critic" }) });
  await expect(critic.locator(".agent-state")).toHaveText("running");
  await expect(critic.locator(".agent-now")).toContainText("Read scripts/check-ci.sh");
  await expect(page.locator(".agents-running")).toHaveText("2 running");
  await expect(page.getByRole("status")).toHaveText("live");

  h.appendSub("b4d2f1", J.result("toolu_r", "ok", sub));
  h.appendSub("b4d2f1", J.text("Looks right.", "end_turn", sub));
  await expect(critic.locator(".agent-now")).toContainText("last active"); // between calls: no current call
  await expect(critic.locator(".agent-state")).toHaveText("running"); // its Agent call is still open
  h.append(J.result("toolu_agent", "Looks right.", { use: { status: "completed", agentId: "b4d2f1" } }));
  await expect(critic.locator(".agent-state")).toHaveText("done");
  await expect(page.locator(".agents-running")).toHaveText("1 running");
  h.append(J.end());
  await expect(page.locator(".agents-running")).toHaveText("0 running");
  await expect(page.getByRole("status")).toHaveText(IDLE);
});

test("8b. a running subagent is listed in the Now panel; once finished its block folds and opens on click", async ({ page }) => {
  h = await bootAgui();
  await page.goto(h.url);
  const sub = { sub: "b4d2f1", model: "claude-sonnet-5-5" };
  h.append(J.prompt("Check the diff with a critic."));
  h.append(J.tool("toolu_agent", "Agent", { description: "diff critic", subagent_type: "pr-review-toolkit-himmel:code-reviewer", prompt: "Read check-ci.sh" }));
  h.appendSub("b4d2f1", J.prompt("Read check-ci.sh", sub));
  h.appendSub("b4d2f1", J.tool("toolu_r", "Read", { file_path: "scripts/check-ci.sh" }, sub));
  const row = page.locator(".now li", { has: page.locator(".agent-name", { hasText: "diff critic" }) });
  await expect(row.locator(".agent-now")).toContainText("Read scripts/check-ci.sh");
  await expect(page.locator(".block.sub .msg")).toBeVisible(); // running: open

  h.appendSub("b4d2f1", J.result("toolu_r", "ok", sub));
  h.appendSub("b4d2f1", J.text("Looks right.", "end_turn", sub));
  h.append(J.result("toolu_agent", "Looks right.", { use: { status: "completed", agentId: "b4d2f1" } }));
  await expect(row).toHaveCount(0);
  const fold = page.locator(".block.sub .fold-head");
  await expect(fold).toContainText("from Agent");
  await expect(page.locator(".block.sub .msg")).toHaveCount(0); // finished: folded
  await fold.click();
  await expect(page.locator(".block.sub .msg").last()).toContainText("Looks right.");
  await fold.click(); // the same control folds it again
  await expect(page.locator(".block.sub .msg")).toHaveCount(0);
});

// `himmelctl ui --agui` with no session id opens the fleet landing over the fixture fleet (3 live +
// 1 wrapped); the wrapped leg sits in the closed section, never in the live list; a row opens its run's stream.
test("archived and released consoles show zero live sessions", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const fleet = await response.json();
    const console = fleet.sessions.find((r: any) => r.role === "console");
    fleet.sessions = [
      { ...console, name: "archived-console", console: "archived-console", live: false, state: "unknown" },
      { ...console, name: "released-console", console: "released-console", lock: "released" },
    ];
    await route.fulfill({ response, json: fleet });
  });
  await page.goto(h.url);
  await expect(page.locator(".top .meta")).toContainText("0 running");
  await expect(page.getByText(/^No running sessions\. 2 finished below\.$/)).toBeVisible();
  // both consoles sit in the Finished section, closed by default.
  const finished = page.locator("details.fleet-closed");
  await expect(finished).not.toHaveAttribute("open", "");
  await expect(finished.locator(".fleet-finished .fleet-row")).toHaveCount(2);
});

test("a wrapped session with no console retains a collapsed sidebar drill-in", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const fleet = await response.json();
    const wrapped = fleet.sessions.find((r: any) => r.state === "wrapped");
    fleet.sessions = [{ ...wrapped, console: "gone-console", parent: "gone-console" }];
    await route.fulfill({ response, json: fleet });
  });
  await page.goto(h.url);
  const wrapped = page.locator(".fleet-menu .fleet-menu-wrapped");
  await expect(wrapped).not.toHaveAttribute("open", "");
  await wrapped.locator("summary").click();
  await expect(wrapped.getByRole("link", { name: FLEET.wrapped.name, exact: true })).toHaveAttribute("href", new RegExp(`&run=${FLEET.wrapped.run}$`));
});
test("9. the fleet landing lists 3 live sessions and 1 wrapped one, and a row opens that session's stream", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  expect(h.url).not.toContain("&run=");
  await page.goto(h.url);
  const live = page.locator(".fleet .fleet-row:not(.finished)");
  await expect(live).toHaveCount(3);
  await expect(live.nth(0).locator(".fleet-name")).toHaveText(shortName(FLEET.console.name));
  await expect(live.nth(0).locator(".fleet-name")).toHaveAttribute("title", FLEET.console.name);
  await expect(live.nth(0)).toContainText("console");
  const leg = card(page, FLEET.leg.name);
  await expect(leg.locator(".fleet-chip")).toHaveText("HIMMEL-901");
  // a card is one line; its chevron, not its name, opens the detail, and the detail names the run page.
  await expect(leg.locator(".fleet-detail")).toHaveCount(0);
  await expand(page, FLEET.leg.name);
  await expect(leg.locator(".fleet-chev")).toHaveAttribute("aria-expanded", "true");
  await expect(leg.locator("a.fleet-runlink")).toHaveAttribute("href", new RegExp(`&run=${FLEET.leg.run}$`));
  await expand(page, FLEET.console.name);
  await expand(page, FLEET.idle.name);
  // the status column (activity, then facts) and the lineage column are separate blocks.
  await expect(leg.locator(".fleet-status .fleet-meta")).toContainText("PR 1901 · 1 of 1 subagents running · 1 tool error");
  await expect(leg.locator(".fleet-status .fleet-fails")).toHaveCount(0);
  await expect(leg.locator(".state")).toHaveText("running");
  await expect(card(page, FLEET.idle.name).locator(".state")).toHaveText("idle");
  await expect(live.filter({ has: page.locator(`[title="${FLEET.wrapped.name}"]`) })).toHaveCount(0);
  // the leg sits in its console's subtree; each row says where it hangs and what it has spent.
  await expect(page.getByRole("list", { name: `Under ${FLEET.console.name}` }).locator(".fleet-row")).toHaveText([new RegExp(shortName(FLEET.leg.name))]);
  await expect(leg.locator(".fleet-lineage .fleet-graph")).toHaveText(`operator › ${shortName(FLEET.console.name)} › ${shortName(FLEET.leg.name)}`);
  await expect(live.nth(0).locator(".fleet-graph")).toHaveText(`operator › ${shortName(FLEET.console.name)}`);
  await expect(live.nth(0).locator(".fleet-succession")).toHaveText(`succeeds ${shortName(PRIOR_CONSOLE)} (not live)`);
  await expect(leg.locator(".fleet-context")).toHaveText("context 20% of 200.0k");
  await expect(leg.locator(".fleet-usage")).toHaveText("context 20% of 200.0k (autocompact) · 3 calls · in 30 · out 300 · cache read 120.0k · cache write 0 · cost-eq 13.5k");
  await expect(leg.locator(".fleet-agent")).toHaveCount(1);
  await expect(card(page, FLEET.idle.name).locator(".fleet-usage")).toHaveText(/not measured/);
  await leg.locator(".fleet-rel").click();
  await expect(live.nth(0)).toBeFocused();

  const closed = page.locator("details.fleet-closed");
  await expect(closed.locator("summary")).toHaveText(/^Finished \d+$/);
  await expect(closed).not.toHaveAttribute("open", "");
  await closed.locator("summary").click();
  const wrapped = page.getByRole("list", { name: "Finished sessions" }).locator(`[id="fleet-${FLEET.wrapped.name}"]`);
  await expect(wrapped).toHaveCount(1);
  await expect(wrapped.locator(".fleet-meta")).toHaveText(/^wrapped/);

  await leg.locator("a.fleet-head").click();
  await expect(page).toHaveURL(new RegExp(`&run=${FLEET.leg.run}$`));
  await expect(page.locator(".top .run")).toHaveText(`run ${FLEET.leg.run}`);
  await expect(page.locator(".call", { hasText: "Push" })).toBeVisible();
});

// one app across two documents. The console's rail reaches the fleet, a fleet row reaches its run view,
// the rail there reaches back to Config and Health, and the token never rides a request line.
test("10. console to Fleet to a run view and back: one rail, the token in the fragment only", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  const tok = /#t=([0-9a-f]{64})/.exec(h.url)![1];
  const lines: string[] = [];
  page.on("request", (r) => lines.push(r.url()));
  await page.goto(h.url.replace("/agui/#t=", "/#t="));
  const rail = page.locator("nav.pages a");
  await expect(rail).toHaveText(["Config", "Health", "Tool health", "Fleet", "Roadmap", "Kanban"]);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  expect(await page.evaluate(() => location.hash)).toBe("#/config");
  await expect(rail.filter({ hasText: "Fleet" }).locator(".st-dot")).toHaveClass(/\bok\b/);

  await rail.filter({ hasText: "Fleet" }).click();
  await expect(page).toHaveURL(new RegExp(`/agui/#t=${tok}$`));
  await expect(rail).toHaveText(["Config", "Health", "Tool health", "Fleet", "Roadmap", "Kanban"]);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Fleet");
  const leg = card(page, FLEET.leg.name);
  await expand(page, FLEET.leg.name);
  await expect(leg.locator("a.fleet-link")).toHaveAttribute("href", `/#t=${tok}&page=health`);

  await leg.locator("a.fleet-head").click();
  await expect(page).toHaveURL(new RegExp(`&run=${FLEET.leg.run}$`));
  await expect(rail).toHaveText(["Config", "Health", "Tool health", "Fleet", "Roadmap", "Kanban", "Run"]);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Run");
  await expect(page.locator(".call", { hasText: "Push" })).toBeVisible();

  await rail.filter({ hasText: "Config" }).click();
  await expect(page).toHaveURL(/\/#\/config$/);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  await page.goBack();
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Run");

  await page.goto(h.url);
  // The open card stays open across the reload (kept per viewer).
  await card(page, FLEET.leg.name).locator("a.fleet-link").click();
  await expect(page).toHaveURL(/\/#\/health$/);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Health");

  expect(lines.length).toBeGreaterThan(0);
  for (const u of lines) expect(new URL(u).pathname + new URL(u).search).not.toContain(tok);
});

// a lineage link reveals its target even when the target's console group is collapsed.
test("a succession link opens the collapsed console group it points into", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  const next = "HIMMEL-nextleg-2026-10-07ZZZ-roadmap-console";
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    const console = body.sessions.find((r: any) => r.name === FLEET.console.name);
    body.sessions.push({ ...console, name: next, console: next, run: null, predecessor: FLEET.console.name });
    await route.fulfill({ response, json: body });
  });
  await page.goto(h.url);
  const group = page.locator(`details.fleet-console[aria-label="${next}"]`);
  await group.locator("> summary").click();
  await expect(group).not.toHaveAttribute("open", "");
  await expand(page, FLEET.console.name);
  await card(page, FLEET.console.name).locator(".fleet-succession .fleet-rel").click();
  await expect(group).toHaveAttribute("open", "");
  await expect(card(page, next)).toBeFocused();
});

// orphans have their own section above Running (a session with its reason and action, a stale wrapper
// with its pid, owner and age), and the rail's filters narrow the page and survive a reload.
test("orphans section, and a lane filter that narrows the page and is kept", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    Object.assign(body.sessions.find((r: any) => r.name === FLEET.leg.name), { console: "gone-console", parent: "gone-console" });
    body.processOrphans = [{ pid: 4242, owner: "orphan", ageMin: 95 }];
    await route.fulfill({ response, json: body });
  });
  await page.goto(h.url);
  const orphans = page.locator("#fleet-sec-orphans");
  await expect(orphans.getByRole("list", { name: "Orphan sessions" })).toContainText(`${shortName(FLEET.leg.name)}`);
  await expect(orphans.getByRole("list", { name: "Orphan sessions" })).toContainText("console process gone");
  await expect(orphans.getByRole("list", { name: "Orphan sessions" })).toContainText("adopt via relay / close");
  await expect(orphans.getByRole("table", { name: "Orphan processes" })).toContainText("close: kill 4242");
  await expect(page.locator(".top .meta")).toContainText("2 orphaned");
  await expect(page.locator("#fleet-sec-running")).not.toContainText(shortName(FLEET.leg.name));

  const lane = page.getByRole("group", { name: "Filters" }).getByRole("button", { name: /^claudex/ });
  await lane.click();
  await expect(lane).toHaveAttribute("aria-pressed", "true");
  await expect(page.locator(".top .meta")).toContainText("(filters on)");
  await expect(page.locator(".fleet .fleet-row:not(.finished)")).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("group", { name: "Filters" }).getByRole("button", { name: /^claudex/ })).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("button", { name: "clear filters" }).click();
  await expect(page.locator(".fleet .fleet-row:not(.finished)")).toHaveCount(2);
});

test("12. two-console side menu, deep-linked page, and identical menu/row drill-in", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  const other = "HIMMEL-project-console";
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    const console = body.sessions.find((r: any) => r.name === FLEET.console.name);
    body.sessions.push({ ...console, name: other, console: other, predecessor: null });
    const child = body.sessions.find((r: any) => r.name === FLEET.idle.name);
    Object.assign(child, { role: "leg", parent: other, console: other, lane: "claudex" });
    await route.fulfill({ response, json: body });
  });
  await page.goto(`${h.url}&console=${other}`);
  await expect(page.locator(".top .run")).toHaveText(other);
  await expect(page.locator(".fleet-console h2")).toHaveText(other);
  await expect(page.locator(".fleet")).toContainText(FLEET.idle.name);
  await expect(page.locator(".fleet")).not.toContainText(FLEET.leg.name);
  const menu = page.getByRole("navigation", { name: "Supervisor sessions" });
  await expect(menu.locator("a.console-page")).toHaveCount(2);
  await menu.locator("a.console-page", { hasText: FLEET.console.name }).click();
  await expect(page.locator(".fleet-console h2")).toHaveText(FLEET.console.name);
  const leg = card(page, FLEET.leg.name);
  const rowHref = await leg.locator("a.fleet-head").getAttribute("href");
  const menuLeg = menu.getByRole("link", { name: FLEET.leg.name, exact: true });
  await expect(menuLeg).toHaveAttribute("href", rowHref!);
  await menuLeg.click();
  await expect(page.locator(".top .run")).toHaveText(`run ${FLEET.leg.run}`);
  await expect(page.locator(".call", { hasText: "Push" })).toBeVisible();
  await menu.getByRole("link", { name: FLEET.console.name, exact: true }).last().click();
  await expect(page.locator(".top .run")).toHaveText(`run ${FLEET.console.run}`);
});

// a cloud session is a node under its console with its shepherd leg under it; it links its session,
// says its phase, and says its tokens are not measured (never a zero). A merged one sits with the wrapped.
test("11. cloud sessions: a node under the console, its shepherd under it, tokens not measured", async ({ page }) => {
  h = await bootAgui("", { fleet: true, cloud: true });
  await page.goto(h.url);
  const live = page.locator(".fleet .fleet-row:not(.finished)");
  const done = card(page, "cloud-HIMMEL-905");
  await expect(done.locator(".fleet-chip")).toHaveText("HIMMEL-905");
  // cloud is a lane with its own phases; a shepherded CLOUD-DONE PR is nobody's alarm.
  await expect(done.locator("> .fleet-line .state")).toHaveText("shepherded");
  await expect(card(page, "cloud-HIMMEL-906").locator("> .fleet-line .state")).toHaveText("working");
  await expect(done.locator("> .fleet-line a.fleet-head")).toHaveAttribute("href", CLOUD.url);
  await expand(page, "cloud-HIMMEL-905");
  await expand(page, "cloud-HIMMEL-906");
  await expect(done.locator(".fleet-role")).toHaveText("cloud · cloud usage budget");
  await expect(done.locator(".fleet-cloud-phase")).toHaveText("PR 1905 · CLOUD-DONE, shepherd's turn · cloud session");
  await expect(done.locator("a.fleet-cloud")).toHaveAttribute("href", CLOUD.url);
  await expect(done.locator(".fleet-context")).toHaveText("tokens not measured (cloud)");
  await expect(done.locator(".fleet-usage")).toHaveText("tokens not measured: a cloud session keeps no local journal and no source exposes its usage");
  await expect(done.locator(".fleet-graph")).toHaveText(`operator › ${shortName(FLEET.console.name)} › cloud-HIMMEL-905`);
  await expect(page.getByRole("list", { name: "Under cloud-HIMMEL-905" }).locator(".fleet-row")).toHaveText([new RegExp(shortName(CLOUD.shepherd.name))]);
  await expect(card(page, "cloud-HIMMEL-906").locator(".fleet-cloud-phase")).toHaveText("no CLOUD-DONE yet");
  // a cloud session still working without a shepherd is normal: no attention line, no orphan.
  await expect(page.locator("#fleet-sec-attention")).toHaveCount(0);
  await expect(page.locator("#fleet-sec-orphans")).toHaveCount(0);
  await expect(live.filter({ has: page.locator('[title="cloud-HIMMEL-907"]') })).toHaveCount(0);
  await page.locator("details.fleet-closed > summary").click();
  await expect(page.getByRole("list", { name: "Finished sessions" }).locator('[id="fleet-cloud-HIMMEL-907"] .fleet-meta')).toHaveText("PR merged · PR 1907");
});

// the console board: the leg card's goal cell, the Trends cost chart and the stage-dot drawer, measured in a real render.
for (const [width, tallest] of [[1280, 120], [390, 180]] as const) {
  test(`13. the leg card's goal cell is wide, whole and inside its card at ${width}px`, async ({ page }) => {
    h = await bootAgui("", { fleet: true });
    await page.setViewportSize({ width, height: 800 });
    await page.goto(h.url);
    const row = card(page, FLEET.leg.name);
    await expect(row.locator(".bd-goalcell")).toBeVisible();
    const box = (await row.boundingBox())!, cell = (await row.locator(".bd-goalcell").boundingBox())!;
    expect(cell.width).toBeGreaterThanOrEqual(200);
    expect(box.height).toBeLessThanOrEqual(tallest);
    for (const dot of await row.locator(".bd-dot").all()) {
      const d = (await dot.boundingBox())!;
      expect(d.x).toBeGreaterThanOrEqual(box.x);
      expect(d.x + d.width).toBeLessThanOrEqual(box.x + box.width);
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true);
  });
}

test("14. the Trends cost chart keeps its bars a bar's width, and a stage dot opens the drawer that Esc closes", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  await page.goto(h.url);
  await page.getByRole("navigation", { name: "Fleet views" }).getByRole("button", { name: "Trends" }).click();
  await expect(page.locator(".bd-card")).toHaveCount(4);
  const bars = page.locator("svg.bd-spark rect");
  await expect(bars).toHaveCount(2);
  expect((await bars.first().boundingBox())!.width).toBeLessThanOrEqual(24);
  await page.getByRole("navigation", { name: "Fleet views" }).getByRole("button", { name: "Fleet" }).click();
  await card(page, FLEET.leg.name).locator(".bd-dot").first().click();
  await expect(page.locator(".bd-drawer")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.locator(".bd-drawer")).toHaveCount(0);
});

test("15. a fleet census refresh keeps the live transcript and its one stream; a new run or token still restarts it", async ({ page }) => {
  h = await bootAgui(denseRun());
  const streams: string[] = [];
  page.on("request", (r) => { const m = /\/api\/agui\/(?!fleet|board)([^/?]+)$/.exec(new URL(r.url()).pathname); if (m) streams.push(m[1]); });
  let release!: () => void;
  const held = new Promise<void>((r) => { release = r; });
  await page.route("**/api/agui/fleet", async (route) => { await held; await route.continue(); });
  // the transcript is watched for any moment it is empty after its first message, so a reset and replay cannot slip between polls
  await page.addInitScript(() => {
    (window as any).__emptied = false;
    addEventListener("DOMContentLoaded", () => {
      let seen = false;
      new MutationObserver(() => {
        const n = document.querySelectorAll(".transcript .msg").length;
        if (n) seen = true; else if (seen) (window as any).__emptied = true;
      }).observe(document.body, { childList: true, subtree: true });
    });
  });
  await page.goto(h.url);
  const msgs = page.locator(".transcript .msg");
  await expect(msgs.first()).toBeVisible();
  expect(streams).toHaveLength(1);

  const census = page.waitForResponse((r) => new URL(r.url()).pathname === "/api/agui/fleet");
  release();
  await census;
  await page.waitForTimeout(500); // the root re-renders on the census; give a stray restart time to show
  expect(streams).toHaveLength(1);
  expect(await page.evaluate(() => (window as any).__emptied)).toBe(false);
  await expect(msgs.first()).toBeVisible();

  const t = /#t=([0-9a-f]{64})/.exec(h.url)![1];
  await page.evaluate((hash) => { location.hash = hash; }, `t=${t}&run=other-run`);
  await expect.poll(() => streams.length).toBe(2);
  expect(streams[1]).toBe("other-run");
  await page.evaluate((hash) => { location.hash = hash; }, `t=${"0".repeat(64)}&run=other-run`);
  await expect.poll(() => streams.length).toBe(3);
  await expect(page.getByRole("alert")).toContainText("The run stopped");
});
