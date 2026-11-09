// The Board page, run for real: `himmelctl ui` over a seeded Jira mirror (three versions, one chain, a saved drift run).
// One Board entry in the rail; the old Roadmap and Kanban routes land on it; the version strip, the drift banner, the chain badge,
// the three tabs and the lanes draw from the seeded sources; no console error at 1280 and 390 px, light and dark.
// E2E_SHOTS=<dir> saves the build-side screenshot of each frame, named board-<width>-<scheme>-<tab>.png, to pair with the mockup.
import { test, expect, chromium, type Page } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { boot, type Harness } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const shot = async (page: Page, name: string) => { const d = process.env.E2E_SHOTS; if (d) { mkdirSync(d, { recursive: true }); await page.screenshot({ path: join(d, `${name}.png`), fullPage: true, animations: "disabled" }); } };
const consoleErrors = (page: Page) => { const errs: string[] = []; page.on("console", (m) => { if (m.type() === "error") errs.push(m.text()); }); page.on("pageerror", (e) => errs.push(String(e))); return errs; };
const go = async (page: Page, hash: string) => { await page.evaluate((x) => { location.hash = x; }, hash); await page.locator("#main h1").filter({ hasText: "Board" }).waitFor(); await page.waitForLoadState("networkidle"); };
async function open(page: Page) {
  process.env.CONFIG_UI_JIRA_CLI = join(__dirname, "..", "stub-jira.js"); // the drawer's stage history is read through the Jira CLI: the stub answers two status moves, never live Jira
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

// fixture, not live: the seeded registry holds nobody waiting on the operator, so the chain read the page asks for is rewritten in flight
// to put the "Second chain step" ticket in "waits on you"; everything else (the server, the page, the render) is real.
test("the Waiting on you section lists a waiting ticket and its key opens that ticket's chain", async ({ page }) => {
  const errs = consoleErrors(page);
  await page.route("**/api/board", async (route) => {
    const res = await route.fetch();
    const j = await res.json();
    for (const c of [j.chains, j.versionChains]) {
      const t = c && c.tickets && c.tickets["HIMMEL-2"];
      if (t) { t.state = "waits on you"; t.title = "Second chain step"; t.chains.forEach((x: { state: string }) => { x.state = "waits on you"; }); }
    }
    await route.fulfill({ response: res, json: j });
  });
  await open(page);
  await go(page, "#/board");
  const sec = page.locator("#rm-waiting");
  await expect(sec).toContainText("Waiting on you");
  await expect(sec.locator("li")).toHaveCount(1);
  await expect(sec.locator("li")).toContainText("HIMMEL-2");
  await expect(sec.locator("li")).toContainText("Second chain step");
  await expect(sec.locator("li")).toContainText("memory 2/2");
  await expect(page.locator(".aside").first()).toContainText("1 ticket waits for you, any version");
  await shot(page, "board-waiting-on-you");
  await sec.locator("li a").click();
  await expect.poll(() => page.evaluate(() => location.hash)).toBe("#/board?tab=chains&at=HIMMEL-2");
  await expect(page.locator("#cn-HIMMEL-2")).toHaveClass(/rm-at/);
  expect(errs).toEqual([]);
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
  const tiles = page.locator(".bh .vchips .vc:not(.all)");
  await expect(tiles).toHaveCount(3);
  await expect(tiles.nth(1)).toHaveAttribute("aria-current", "true");
  await expect(tiles.nth(0)).toHaveAttribute("title", /released 2026-10-19/);
  await expect(tiles.nth(0).locator(".op")).toHaveAttribute("title", /1 still open: HIMMEL-12/);
  await expect(page.locator("#main .alert")).toHaveCount(0);
  await expect(page.getByRole("tab", { name: /^Tidy up/ })).toContainText("! 1 drift row");
  await page.getByRole("tab", { name: /^Tidy up/ }).click();
  await expect(page.locator("#main")).toContainText("transient");
  await go(page, "#/board");
  // the lanes of the running version, with the chain badge on a chain ticket and none on the others
  await expect(page.locator(".rm-card", { hasText: "First chain step" })).toBeHidden(); // a Done ticket: the Done column is folded
  await page.locator("#rm-lanes details.rm-done summary").click();
  await expect(page.locator(".rm-card", { hasText: "First chain step" })).toBeVisible();
  await expect(page.locator(".rm-card", { hasText: "Old shipped work" })).toHaveCount(0);
  await expect(page.locator(".rm-card", { hasText: "Second chain step" }).locator(".rm-chain")).toContainText("memory step 2 of 2 · can launch");
  // 9488: the chain glyph on a card badge is badge-sized and the chain id after it sits inside the badge's box, visible (toContainText also passes on clipped text);
  // the rest of the line is the designed one-line ellipsis, with the whole text in the bubble
  const badge = page.locator(".rm-card", { hasText: "Second chain step" }).locator(".rm-chain");
  const icon = await badge.locator(".ic").boundingBox();
  expect(icon!.width).toBeLessThanOrEqual(16);
  expect(icon!.height).toBeLessThanOrEqual(16);
  const idBox = await badge.locator(".rm-clip").evaluate((el) => {
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); let n: Node | null;
    while ((n = w.nextNode())) { const i = (n.textContent || "").indexOf("memory"); if (i >= 0) { const r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + 6); const x = r.getBoundingClientRect(), c = el.getBoundingClientRect(); return { width: x.width, left: x.left - c.left, right: c.right - x.right }; } }
    return null;
  });
  expect(idBox).not.toBeNull();
  expect(idBox!.width).toBeGreaterThan(20);
  expect(idBox!.left).toBeGreaterThanOrEqual(0);
  expect(idBox!.right).toBeGreaterThanOrEqual(0); // the chain id ends inside the box, not past its clipped edge
  await expect(page.locator(".rm-card", { hasText: "Not in any chain" }).locator(".rm-chain")).toHaveCount(0);
  await expect(page.locator(".rm-card[draggable]").first()).toBeVisible(); // drag and the Sector select are still there
  // no registry-less made-up number: the wait link counts the chain read's own rows
  await expect(page.locator(".aside").first()).toContainText("0 tickets wait for you, any version");
  await expect(page.locator(".aside").first()).not.toContainText("not counted"); // the seeded mirror has a ticket with no version, and the page reads it beside the default read, so nothing is left out
  await expect(page.locator("#rm-waiting")).toHaveCount(0); // nobody waits: no section, the count link above says 0
  // Chains tab
  await page.getByRole("tab", { name: /^Chains/ }).click();
  await expect(page.locator("#rm-chain-memory")).toContainText("1 of 2 tickets done");
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

// 8837: Tidy up's refresh in its three states, the origin column and the checker-bug tag (mockup v4 frames 1, 5, 6)
test("Tidy up: refresh re-runs the check and the next read shows it; a failed run keeps the saved rows and says why", async ({ page }) => {
  const errs = consoleErrors(page);
  await open(page);
  await page.route("**/api/roadmap/history*", (route) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ key: "HIMMEL-12", events: route.request().url().includes("HIMMEL-12")
    ? [{ at: "2026-10-30T10:00:00", who: "Ana Reyes", from: "To Do", to: "Done" }] : [{ at: "2026-10-30T10:00:00", who: "Himmel Bot", from: "To Do", to: "In Progress", himmel: true }] }) }));
  await go(page, "#/board?tab=tidy");
  const drift = page.locator("#rm-status-drift");
  await expect(drift).toContainText("drift: saved run");
  await expect(drift).toContainText("moved in Jira by Ana Reyes");
  await expect(drift).toContainText("himmel's Jira account");
  await expect(drift.locator('a[href="#/config?tile=tracker"]')).toBeVisible();
  await expect(drift).toContainText("team mode is off");
  await shot(page, "tidy-saved");
  // the failed state, answered by the page's route: the saved rows stay
  await page.route("**/api/board/drift-refresh", (route) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ state: "failed", reason: "the check could not read the open PRs or the Jira search in full" }) }));
  await drift.locator('[data-act="drift-refresh"]').click();
  await expect(drift.locator('[role="alert"]')).toContainText("could not read the open PRs");
  await expect(drift).toContainText("VERSION-DRIFT");
  await shot(page, "tidy-refresh-failed");
  await page.unroute("**/api/board/drift-refresh");
  // the real route, over the fixture's stub: running, then the new run
  await drift.locator('[data-act="drift-refresh"]').click();
  await expect(drift).toContainText("re-running the check");
  await expect(drift.locator('[data-act="drift-refresh"]')).toBeDisabled();
  await expect(drift).toContainText("WORKER-COMMENT"); // the saved rows stay until the run ends
  await shot(page, "tidy-refresh-running");
  await expect(drift).toContainText("drift: re-run");
  await expect(drift).toContainText("sdrift=2:newrun");
  await expect(drift.locator("table").first()).toContainText("healed");
  await shot(page, "tidy-refresh-done");
  await page.emulateMedia({ colorScheme: "dark" });
  await shot(page, "tidy-refresh-done-dark");
  await page.emulateMedia({ colorScheme: "light" });
  // the new run's known row tags its card on the lanes, naming the checker
  await go(page, "#/board");
  await expect(page.locator(".rm-card", { hasText: "Second chain step" }).locator(".rm-kb")).toContainText("checker bug HIMMEL-31");
  await shot(page, "lanes-checker-bug");
  expect(errs).toEqual([]);
});

test("dragging a card to another column sends its new status", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  const sent: string[] = [];
  await page.route("**/api/roadmap/write", async (route) => { sent.push(route.request().postData() || ""); await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ ok: true }) }); });
  await page.locator(".rm-card", { hasText: "Second chain step" }).dragTo(page.locator('[data-rm-drop="prog"]'));
  await expect.poll(() => sent.length).toBe(1);
  expect(JSON.parse(sent[0])).toMatchObject({ key: "HIMMEL-2", status: "prog" });
});

// 8832: the ticket drawer (mockup v4 frame 3), a keyboard move, and a drop on a column its event moves
// a click on the card's title text: the middle of a wide card can be its Sector select or chain link, which do their own work and do not open the drawer
const openCard = (page: Page, title: string) => page.locator(".rm-card", { hasText: title }).getByText(title, { exact: true }).click();
const noWrite = async (page: Page) => { // a write that goes out is recorded; none is answered by Jira
  const sent: string[] = [];
  await page.route("**/api/roadmap/write", async (route) => {
    const body = route.request().postData() || "";
    sent.push(body);
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ ok: true, status: JSON.parse(body).status }) }); // answers as the server does: the status the card is now in
  });
  return sent;
};

test("a click on a card opens the drawer with its CLI argv and its stage history, read through the Jira CLI when it opens", async ({ page }) => {
  const errs = consoleErrors(page);
  const reads: string[] = [];
  page.on("request", (r) => { if (r.url().includes("/api/roadmap/history")) reads.push(r.url()); });
  await open(page);
  await go(page, "#/board");
  expect(reads).toEqual([]); // loading the Board reads no history
  await openCard(page, "Second chain step");
  const drawer = page.locator("aside.drawer");
  await expect(drawer).toHaveAttribute("aria-label", "Ticket HIMMEL-2");
  await expect(drawer).toContainText('jira transition HIMMEL-2 "In Progress"'); // the CLI call the move makes
  await expect(drawer.locator(".rm-tl li").first()).toContainText("To Do → In Progress"); // the stub's first status move
  await expect(drawer.locator(".rm-tl")).toContainText("In Progress → In Review");
  await expect(drawer.locator(".rm-tl")).not.toContainText("v1.1.3"); // the Fix Version change is not a stage move
  expect(reads).toHaveLength(1);
  await expect(page.getByRole("button", { name: /^Close ticket/ })).toBeFocused(); // the history redraw did not drop keyboard focus out of the drawer
  await expect(page.locator(".rm-under")).toHaveAttribute("inert", ""); // the board under it takes nothing
  await shot(page, "board-drawer");
  await page.keyboard.press("Escape");
  await expect(drawer).toHaveCount(0);
  await expect(page.locator(".rm-card", { hasText: "Second chain step" })).toBeFocused();
  expect(errs).toEqual([]);
});

test("a history that cannot be read says unavailable, never an empty history", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  await page.route("**/api/roadmap/history*", (route) => route.fulfill({ status: 502, contentType: "application/json", body: JSON.stringify({ error: "history unavailable" }) }));
  await openCard(page, "Second chain step");
  await expect(page.locator("aside.drawer")).toContainText("history unavailable");
  await expect(page.locator("aside.drawer")).not.toContainText("No status moves");
  await page.getByRole("button", { name: /^Close ticket/ }).click();
  await expect(page.locator("aside.drawer")).toHaveCount(0);
});

test("Shift+Right on a focused card moves it to the next column its operator may write and posts the new status", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  const sent = await noWrite(page);
  await page.locator(".rm-card", { hasText: "Second chain step" }).focus();
  await page.keyboard.press("Shift+ArrowRight");
  await expect.poll(() => sent.length).toBe(1);
  expect(JSON.parse(sent[0])).toMatchObject({ key: "HIMMEL-2", status: "prog" });
  await expect(page.locator('[data-rm-col="prog"] .rm-card', { hasText: "Second chain step" })).toBeVisible(); // the write has answered and the board is redrawn: one write at a time
  await expect(page.locator(".rm-card", { hasText: "Second chain step" })).toBeFocused(); // and focus is back on the moved card
  await page.locator(".rm-card", { hasText: "Second chain step" }).focus();
  await page.keyboard.press("Shift+ArrowRight"); // from In progress the next writable column is Won't: In review, CI and Done are skipped
  await expect.poll(() => sent.length).toBe(2);
  expect(JSON.parse(sent[1])).toMatchObject({ key: "HIMMEL-2", status: "wont" });
});

test("a drop on a column its event moves (In review, CI, Done) writes nothing and says so", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  await page.locator("#rm-lanes details.rm-done summary").click();
  const sent = await noWrite(page);
  for (const [col, name] of [["rev", "In Review"], ["done", "Done"]]) { // Review and CI are one column now: a drop on it is a drop on rev
    await page.locator(".rm-card", { hasText: "Second chain step" }).dragTo(page.locator(`[data-rm-drop="${col}"]`));
    await expect(page.locator("#main .alert", { hasText: `${name} is moved by its event` })).toBeVisible(); // the note names this drop's column, so the last drop's note cannot satisfy it
    expect(await page.locator("#main .alert", { hasText: `${name} is moved by its event` }).evaluate((el) => el === el.closest("section.cp")?.firstElementChild), "the note is the first thing inside the panel").toBe(true);
  }
  expect(sent).toEqual([]); // no POST to /api/roadmap/write went out
  await page.locator(".rm-card", { hasText: "Second chain step" }).dragTo(page.locator('[data-rm-drop="prog"]')); // a column the operator owns still writes
  await expect.poll(() => sent.length).toBe(1);
});

// The board under an open drawer is inert, so a person cannot reach it; this drives the events straight at the card, which is what the hold in
// writeRoadmap guards against. Deleting the `|| roadmapUi.drawer` hold makes both attempts post (confirmed RED).
test("with the drawer open a Shift+Arrow key and a drag write nothing", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  const sent = await noWrite(page);
  await openCard(page, "Second chain step");
  await expect(page.locator("aside.drawer")).toBeVisible();
  await page.evaluate(() => {
    const card = document.querySelector('.rm-card[data-rm-open="2"]') as HTMLElement;
    card.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", shiftKey: true, bubbles: true }));
    card.dispatchEvent(new Event("dragstart", { bubbles: true }));
    (document.querySelector('[data-rm-drop="wont"]') as HTMLElement).dispatchEvent(new Event("drop", { bubbles: true, cancelable: true }));
  });
  await page.evaluate(() => new Promise((r) => setTimeout(r, 300))); // a write that was not held would have gone out by now
  expect(sent).toEqual([]);
  await page.keyboard.press("Escape"); // closed, the same card writes again
  await page.locator(".rm-card", { hasText: "Second chain step" }).focus();
  await page.keyboard.press("Shift+ArrowRight");
  await expect.poll(() => sent.length).toBe(1);
});

test("a Done card's drawer closes back onto its card, inside the Done lane that was folded", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  await expect(page.locator(".rm-card", { hasText: "First chain step" })).toBeHidden(); // Done is folded
  await page.locator("#rm-lanes details.rm-done summary").click();
  await openCard(page, "First chain step");
  await expect(page.locator("aside.drawer")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.locator("aside.drawer")).toHaveCount(0);
  await expect(page.locator(".rm-card", { hasText: "First chain step" })).toBeFocused();
});

test("the Chain filter narrows the lanes to that chain's tickets", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  await expect(page.locator(".rm-card", { hasText: "Not in any chain" })).toBeVisible();
  await page.locator("select[data-rm-chain]").selectOption("memory");
  await expect(page.locator(".rm-card", { hasText: "Not in any chain" })).toHaveCount(0);
  await expect(page.locator(".rm-card", { hasText: "Second chain step" })).toBeVisible();
});

test("a ticket with no fixVersion is on its own No version tab, read once beside the default read; no version board has it", async ({ page }) => {
  const errs = consoleErrors(page);
  const reads: string[] = [];
  page.on("request", (r) => { if (r.url().includes("/api/roadmap")) reads.push(r.url()); });
  await open(page);
  await go(page, "#/board");
  await expect(page.locator(".rm-card", { hasText: "Work in flight" })).toBeVisible();
  await expect(page.locator(".rm-card", { hasText: "Standing ticket with no version" })).toHaveCount(0);
  await expect(page.locator("#rm-nv")).toHaveCount(0);
  await expect(page.getByRole("tab", { name: /^No version/ })).toContainText("1");
  await expect.poll(() => reads.filter((u) => u.includes("nv=1")).length).toBe(1); // Waiting on you needs them, so the page asks once beside the default read; the default read itself does not carry them
  await page.getByRole("tab", { name: /^No version/ }).click();
  await expect(page.locator("#rm-nv .rm-card", { hasText: "Standing ticket with no version" })).toBeVisible();
  await expect(page.locator("#rm-nv .rm-card", { hasText: "Work in flight" })).toHaveCount(0);
  expect(reads.filter((u) => u.includes("nv=1"))).toHaveLength(1);
  await shot(page, "board-nv-tab");
  await go(page, "#/board");
  await expect(page.locator(".rm-card", { hasText: "Standing ticket with no version" })).toHaveCount(0);
  expect(errs).toEqual([]);
});

test("reloading on the No version tab starts its read without a page error", async ({ page }) => {
  const errs: string[] = [];
  page.on("pageerror", (e) => errs.push(e.message));
  await open(page);
  await go(page, "#/board?tab=nv");
  await expect(page.locator("#rm-nv .rm-card", { hasText: "Standing ticket with no version" })).toBeVisible();
  const asked = page.waitForRequest((r) => r.url().includes("/api/roadmap?nv=1"));
  await page.reload();
  await asked;
  await expect(page.locator("#rm-nv .rm-card", { hasText: "Standing ticket with no version" })).toBeVisible();
  expect(errs).toEqual([]);
});

test("dragging a card on the No version tab sends its new status", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=nv");
  const sent: string[] = [];
  await page.route("**/api/roadmap/write", async (route) => { sent.push(route.request().postData() || ""); await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ ok: true }) }); });
  await page.locator("#rm-nv .rm-card", { hasText: "Standing ticket with no version" }).dragTo(page.locator('[data-rm-drop="todo"]'));
  await expect.poll(() => sent.length).toBe(1);
  expect(JSON.parse(sent[0])).toMatchObject({ key: "HIMMEL-31", status: "todo" });
});

test("the find box narrows the lanes by title or id on Enter, the columns say how many Jira has, and Done is folded", async ({ page }) => {
  await open(page);
  await go(page, "#/board");
  const todo = page.locator('#rm-lanes [data-rm-col="todo"]');
  await expect(todo.locator(".rm-jira")).toHaveText("Jira 4 matches");
  await expect(page.locator("#rm-lanes details.rm-done")).not.toHaveAttribute("open", "");
  await page.locator("input[data-rm-find]").fill("second chain");
  await page.locator("input[data-rm-find]").press("Enter");
  await expect(page.locator("#rm-lanes .rm-card")).toHaveCount(1);
  await expect(todo.locator(".rm-n")).toHaveText("1");
  await expect(todo.locator(".rm-jira")).toHaveText("Jira 4 · 1 shown");
  await expect(page.locator("input[data-rm-find]")).toHaveValue("second chain");
  await shot(page, "board-find");
});

test("every tab carries the one filter bar and refresh, and Tidy up lists every version by default", async ({ page }) => {
  await open(page);
  for (const tab of ["roadmap", "tidy"]) {
    await go(page, `#/board?tab=${tab}`);
    await expect(page.locator(".rm-bar")).toHaveCount(1);
    await expect(page.locator('[data-act="refresh-roadmap"]')).toHaveCount(1); // the one refresh is the aside's, on every tab
    await expect(page.locator('.aside [data-act="refresh-roadmap"]')).toHaveCount(1);
  }
  await go(page, "#/board?tab=chains"); // the Chains tab has no filter bar; its refresh is the same aside control
  await expect(page.locator(".rm-bar")).toHaveCount(0);
  await expect(page.locator('.aside [data-act="refresh-roadmap"]')).toHaveCount(1);
  await go(page, "#/board?tab=tidy");
  await expect(page.locator("#rm-librarian")).toContainText("HIMMEL-12"); // released-but-open on v1.1.2, not the running version
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

for (const [width, height] of [[1280, 900], [390, 844]]) {
  for (const scheme of ["light", "dark"] as const) {
    test(`the drawer at ${width} px, ${scheme}: it draws over the board, no console error, no sideways scroll`, async ({ page }) => {
      const errs = consoleErrors(page);
      await page.setViewportSize({ width, height });
      await page.emulateMedia({ colorScheme: scheme });
      await open(page);
      await go(page, "#/board");
      await openCard(page, "Second chain step");
      await expect(page.locator("aside.drawer .rm-tl")).toContainText("To Do → In Progress");
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
      const box = await page.locator("aside.drawer").boundingBox();
      expect(box && box.x >= 0 && box.x + box.width <= width + 1).toBe(true);
      await shot(page, `board-${width}-${scheme}-drawer`);
      expect(errs).toEqual([]);
    });
  }
}

// the dense layout, measured in a real browser
const LONG_TITLE = "A very long ticket title ".repeat(9).trim(); // 224 characters
const TWO_LINE_TITLE = "Two line title text Two line title text"; // wraps to two lines in a Board column at 1280 px
async function longTitle(page: Page, titles: Record<string, string> = { "Second chain step": LONG_TITLE }) {
  await page.route("**/api/roadmap", async (route) => {
    const res = await route.fetch();
    const j = await res.json();
    for (const [from, to] of Object.entries(titles)) j.tickets.find((t: { t: string }) => t.t === from).t = to; // cards the Board shows on a fresh browser (the first ticket is a folded Done)
    await route.fulfill({ response: res, json: j });
  });
}

test("the Board at 1280 px is dense: a one-line bar, the first card near the top, four columns and a Won't lane that takes drops", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await open(page);
  await go(page, "#/board");
  const bar = await page.locator(".rm-bar").first().boundingBox();
  expect(bar && bar.height <= 40).toBe(true);
  const card = await page.locator(".rm-card").first().boundingBox();
  expect(card && card.y <= 480).toBe(true); // the sector legend and the drain line add up to about 80 px above the lanes; 350 before them in Noto Sans; DejaVu Sans (CI) is wider, the tab row's aside wraps under the tabs and the card sits near 373
  const tracks = await page.locator(".rm-board").first().evaluate((el) => getComputedStyle(el).gridTemplateColumns.split(" ").length);
  expect(tracks).toBe(5); // four columns and the narrow Won't lane
  await expect(page.locator('[data-rm-drop="wont"]')).toBeVisible();
  await expect(page.locator('[data-rm-drop="ci"]')).toHaveCount(0);
  await shot(page, "board-1280-dense");
});

test("a clamped title shows its full text in a bubble on hover at 1280 px and has none at 390 px", async ({ page }) => {
  await longTitle(page);
  await page.setViewportSize({ width: 1280, height: 900 });
  await open(page);
  await go(page, "#/board");
  const title = page.locator(`.rm-title[data-tip="${LONG_TITLE}"]`).first();
  await title.hover();
  const after = () => title.evaluate((el) => { const s = getComputedStyle(el, "::after"); return { display: s.display, content: s.content }; });
  expect((await after()).display).toBe("block");
  expect((await after()).content).toContain(LONG_TITLE.slice(0, 40));
  await shot(page, "board-1280-bubble");
  await page.setViewportSize({ width: 390, height: 844 });
  await title.hover();
  expect((await after()).display).toBe("none");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
});

// the same ticket, long and not: a 200-character title takes no more room than a two-line one
const tabTo = async (page: Page, sel: string) => { // Tab until the focused element is the one wanted, as a keyboard user would
  for (let i = 0; i < 80; i++) {
    await page.keyboard.press("Tab");
    if (await page.evaluate((q) => !!document.activeElement?.matches(q), sel)) return;
  }
  throw new Error("Tab never reached " + sel);
};
const longCard = '.rm-card:has(.rm-title[data-tip^="A very long ticket title"])';

test("at 1280 px a 200-character card is no taller than a two-line card, Tab shows the bubble and the ticket key is never cut", async ({ page }) => {
  await longTitle(page, { "Work in flight": LONG_TITLE, "Waiting for review": TWO_LINE_TITLE });
  await page.setViewportSize({ width: 1280, height: 900 });
  await open(page);
  await go(page, "#/board");
  const clip = (card: string) => page.locator(`${card} .rm-title .rm-clip`).evaluate((el) => el.clientHeight);
  const long = (await page.locator(longCard).boundingBox())!.height;
  const two = (await page.locator(".rm-card", { hasText: TWO_LINE_TITLE }).boundingBox())!.height;
  expect(await clip(".rm-card:has-text(\"Two line title\")")).toBeGreaterThan(await clip(".rm-card:has-text(\"Not in any chain\")") + 4); // the control: two lines really are taller than one
  expect(Math.abs(long - two)).toBeLessThanOrEqual(2);
  const key = await page.locator(`${longCard} .rm-top b`).evaluate((el) => el.scrollWidth <= el.clientWidth && getComputedStyle(el).textOverflow !== "ellipsis");
  expect(key).toBe(true);
  await tabTo(page, longCard);
  const bubble = await page.locator(`${longCard} .rm-title`).evaluate((el) => { const s = getComputedStyle(el, "::after"); return { display: s.display, content: s.content }; });
  expect(bubble.display).toBe("block");
  expect(bubble.content).toContain(LONG_TITLE.slice(0, 40));
});

test("at 390 px a long title clamps to three lines with no bubble on focus, and a tap opens the drawer with the full title", async ({ page }) => {
  await longTitle(page, { "Work in flight": LONG_TITLE });
  await page.setViewportSize({ width: 390, height: 844 });
  await open(page);
  await go(page, "#/board");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
  const clip = page.locator(`${longCard} .rm-title .rm-clip`);
  const lines = await clip.evaluate((el) => { const s = getComputedStyle(el); return { clamp: s.webkitLineClamp, rows: Math.round(el.clientHeight / parseFloat(s.lineHeight)), cut: el.scrollHeight > el.clientHeight }; });
  expect(lines).toEqual({ clamp: "3", rows: 3, cut: true });
  await tabTo(page, longCard);
  expect(await page.locator(`${longCard} .rm-title`).evaluate((el) => getComputedStyle(el, "::after").display)).toBe("none");
  await page.locator(`${longCard} .rm-title`).click();
  await expect(page.locator("aside.drawer")).toContainText(LONG_TITLE);
});

test("the Chains tab draws the link across chains, the change log and the folded burn-down", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains");
  const links = page.locator(".lmap");
  await expect(links).toContainText("HIMMEL-6");
  await expect(links).toContainText("HIMMEL-2");
  await expect(links).toContainText("Ops cleanup chain");
  await expect(page.locator(".lmap .lk.open")).toHaveCount(1);
  const log = page.locator('.rm-log[data-log="ops"]');
  await expect(log.locator("summary")).toContainText("Change log · 2 rows");
  await log.locator("summary").click();
  await expect(log).toContainText("waiting on the freeze");
  const burn = page.locator("details.burn");
  expect(await burn.evaluate((d) => (d as HTMLDetailsElement).open)).toBe(false); // folded
  await burn.locator("summary").click();
  await expect(burn.locator(".rm-burn-words")).toContainText("3 of 4 tickets open");
  await expect(burn.locator(".rm-burn-words")).toContainText("1 ticket merged since 2026-10-30");
  expect(await burn.locator("circle").count()).toBeGreaterThan(1);
  await expect(burn.locator(".rm-burn-pace")).toHaveCount(0); // the running version has no date
});

test("the Why panel names the blocker of a blocked ticket; Esc closes it, focus returns, and an open change log stays open", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains");
  await page.locator('.rm-log[data-log="ops"] summary').click();
  const opener = page.locator('[data-why-open="HIMMEL-7.HIMMEL-21"]').first();
  await opener.click();
  const panel = page.locator("aside.rm-why");
  await expect(panel).toContainText("Why HIMMEL-7 waits on HIMMEL-21");
  await expect(panel).toContainText("blocked");
  await expect(panel).toContainText("HIMMEL-21 completes");
  await expect(page.locator(".rm-why-close")).toBeFocused();
  await expect(page.locator(".rm-under")).toHaveAttribute("inert", "");
  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await expect(page.locator('[data-why-open="HIMMEL-7.HIMMEL-21"]').first()).toBeFocused();
  expect(await page.locator('.rm-log[data-log="ops"]').evaluate((d) => (d as HTMLDetailsElement).open)).toBe(true);
});

test("a Why link as the first Board visit focuses the panel's close control once the reads arrive", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains&why=HIMMEL-7.HIMMEL-21");
  await expect(page.locator("aside.rm-why")).toBeVisible();
  await expect(page.locator(".rm-why-close")).toBeFocused();
});

test("a version tile picks the version the Chains tab reads, and a link for all versions shows the running one and says so", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains&v=v1.1.4");
  await expect(page.locator("#rm-chains")).toContainText("No chain has a ticket in v1.1.4.");
  await expect(page.locator(".vc.sel")).toHaveCount(1);
  await expect(page.locator(".vc.sel")).toContainText("v1.1.4");
  await expect(page.locator("#rm-chains .foot")).toContainText("have no ticket in v1.1.4");
  await shot(page, "board-1280-light-chains-other-version");
  await go(page, "#/board?tab=chains&v=all");
  await expect(page.locator("#rm-chains")).toContainText("“all versions” shows the running version, v1.1.3.");
  await expect(page.locator(".vc.sel")).toContainText("v1.1.3");
  await expect(page.locator("#rm-chains")).toContainText("2 chains in v1.1.3");
  await expect(page.locator(".tabs .tab.ch .cnt")).toHaveText("2");
});

test("a version tile picked while the first Board read is still out is the version the tab ends on", async ({ page }) => {
  await open(page);
  let release!: () => void;
  const held = new Promise<void>((r) => { release = r; });
  let asked = 0;
  await page.route("**/api/board?*", (route) => route.continue()); // a read with a version is never held
  await page.route(/\/api\/board$/, async (route) => { asked++; await held; await route.continue(); }); // the first, unversioned read waits
  await page.evaluate(() => { location.hash = "#/board?tab=chains"; });
  await expect.poll(() => asked).toBe(1);
  await page.evaluate(() => { location.hash = "#/board?tab=chains&v=v1.1.4"; });
  release();
  await expect(page.locator("#rm-chains")).toContainText("No chain has a ticket in v1.1.4.");
  await expect(page.locator(".vc.sel")).toContainText("v1.1.4");
});

test("after the Why panel closes, the ticket drawer keeps its behaviour on the Board: Esc closes it and focus returns to its card", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains&why=HIMMEL-7.HIMMEL-21");
  await page.keyboard.press("Escape");
  await go(page, "#/board");
  await openCard(page, "Second chain step");
  await expect(page.locator("aside.rm-why")).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(page.locator("aside.drawer")).toHaveCount(0);
  await expect(page.locator(".rm-card", { hasText: "Second chain step" })).toBeFocused();
});

test("motion: an open link moves, and under reduced motion nothing on the tab animates, the Why panel included", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains&why=HIMMEL-7.HIMMEL-21");
  expect(await page.locator(".lk.open").first().evaluate((e) => getComputedStyle(e).animationName)).toBe("rm-ping");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect(page.locator("aside.rm-why")).toHaveCount(1);
  const moving = await page.evaluate(() => [...document.querySelectorAll("*")].filter((e) => getComputedStyle(e).animationName !== "none").map((e) => e.tagName + "." + e.getAttribute("class")));
  expect(moving).toEqual([]);
});

for (const [width, height] of [[1280, 900], [390, 844]]) {
  for (const scheme of ["light", "dark"] as const) {
    test(`the Why panel at ${width} px, ${scheme}: it draws over the tab, no console error, no sideways scroll`, async ({ page }) => {
      const errs = consoleErrors(page);
      await page.setViewportSize({ width, height });
      await page.emulateMedia({ colorScheme: scheme });
      await open(page);
      await go(page, "#/board?tab=chains&why=HIMMEL-7.HIMMEL-21");
      await expect(page.locator("aside.rm-why")).toBeVisible();
      await page.locator("aside.rm-why").evaluate((e) => Promise.all(e.getAnimations().map((a) => a.finished))); // the box below measures the settled panel, not its slide-in
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
      const box = await page.locator("aside.rm-why").boundingBox();
      expect(box && box.x >= 0 && box.x + box.width <= width + 1).toBe(true);
      const chipLines = await page.locator("#cn-HIMMEL-7").first().evaluate((e) => e.getBoundingClientRect().height);
      expect(chipLines).toBeLessThan(26); // a ticket chip is one line: it never breaks
      await shot(page, `board-${width}-${scheme}-why`);
      expect(errs).toEqual([]);
    });
  }
}

test("with no drift file and no chain registry the Board says so in words and shows no count", async ({ page }) => {
  h = await boot({}, { tracker: "jira" });
  await page.goto(h.url);
  await page.locator("nav.pages").waitFor();
  await go(page, "#/board");
  await expect(page.locator("#main")).toContainText("drift not read");
  await page.getByRole("tab", { name: /^Tidy up/ }).click();
  await page.locator('#rm-status-drift [data-act="drift-refresh"]').click(); // nowhere to save the run: refused in words, no count
  await expect(page.locator('#rm-status-drift [role="alert"]')).toContainText("HIMMEL_FOCUS_DRIFT");
  await page.getByRole("tab", { name: /^Roadmap/ }).click();
  await expect(page.locator(".aside").first()).toContainText("waits for you: not read");
  await expect(page.locator(".rm-chain")).toHaveCount(0);
  await page.getByRole("tab", { name: /^Chains/ }).click();
  await expect(page.locator("#rm-chains .nodata")).toContainText("no chain registry");
});

// a second mirror under the mirror root (SALUS) joins the seeded HIMMEL one; its card shares a number with a seeded HIMMEL card.
test("two projects: both projects' cards show with their keys, the Project filter narrows, a SALUS card posts SALUS's own key", async ({ page }) => {
  const errs = consoleErrors(page);
  await page.setViewportSize({ width: 1280, height: 900 });
  await open(page);
  const root = join(h.home, ".himmel", "state", "jira-mirror");
  mkdirSync(join(root, "SALUS"), { recursive: true });
  writeFileSync(join(root, "SALUS", "SALUS-2.md"), '---\nkey: "SALUS-2"\nstatus: "To Do"\nstatusCategory: "To Do"\nlabels: []\nfixVersions: ["v1.1.3"]\nupdated: "2026-10-02T00:00:00.000+0000"\nresolution: null\n---\n\n# SALUS-2: Salus intake form\n');
  writeFileSync(join(root, "SALUS.versions.tsv"), "v1.1.3\tfalse\t\n"); // the same version name as HIMMEL's: two entries, not one
  await go(page, "#/board");
  // both projects' cards, each with its own key; the same number does not merge them
  await expect(page.locator(".rm-card", { hasText: "Salus intake form" }).locator("b")).toHaveText("SALUS-2");
  await expect(page.locator(".rm-card", { hasText: "Second chain step" }).locator("b")).toHaveText("HIMMEL-2");
  await expect(page.locator(".bh .vchips .vc", { hasText: "v1.1.3 (SALUS)" })).toHaveCount(1);
  await expect(page.locator(".bh .vchips .vc", { hasText: "v1.1.3 (HIMMEL)" })).toHaveCount(1);
  await shot(page, "board-1280-two-projects");
  // the Project filter narrows to one
  await page.locator(".rm-more summary").click(); // Project sits under More ▾
  await page.locator('select[data-rm-filter="project"]').selectOption({ label: "SALUS" });
  await expect(page.locator(".rm-card", { hasText: "Salus intake form" })).toBeVisible();
  await expect(page.locator(".rm-card", { hasText: "Second chain step" })).toHaveCount(0);
  // a drag of the SALUS card posts a body naming project SALUS
  const sent: string[] = [];
  await page.route("**/api/roadmap/write", async (route) => { sent.push(route.request().postData() || ""); await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ ok: true }) }); });
  await page.locator(".rm-card", { hasText: "Salus intake form" }).locator(".rm-title").dragTo(page.locator('[data-rm-drop="prog"]')); // grab the title: the card centre is the Sector select
  await expect.poll(() => sent.length).toBe(1);
  expect(JSON.parse(sent[0])).toMatchObject({ key: "SALUS-2", status: "prog" });
  // a keyboard move posts the SALUS key too, not a HIMMEL default
  await page.evaluate(() => new Promise((r) => setTimeout(r, 300))); // the first write's redraw lands first: a key during a write in flight is dropped
  await page.locator(".rm-card", { hasText: "Salus intake form" }).focus();
  await page.keyboard.press("Shift+ArrowRight");
  await expect.poll(() => sent.length).toBe(2);
  expect(JSON.parse(sent[1])).toMatchObject({ key: "SALUS-2", status: "prog" });
  expect(errs).toEqual([]);
});

// The Chains tab, measured. Fixture, not live: the seeded mirror holds two chains over a handful of tickets, so the heights below bound a small
// chains view; the live figures at 1920 and 1280 on the running version are owed from a station and are not claimed here.
const PANEL_MAX = 590, MARGIN = 40, FIRST_CHAIN_MAX = 250;
const chainsMeasure = (page: Page) => page.evaluate(() => {
  const box = (q: string) => document.querySelector(q)!.getBoundingClientRect();
  const small: string[] = [];
  document.querySelectorAll(".bh *, .tr *, .cp *").forEach((el) => {
    if (!el.getClientRects().length) return; // inside a closed fold: nothing drawn
    const own = Array.from(el.childNodes).some((n) => n.nodeType === 3 && (n.textContent || "").trim());
    if (own && parseFloat(getComputedStyle(el).fontSize) < 11) small.push(el.tagName + "." + el.className + " " + getComputedStyle(el).fontSize);
  });
  const text = (document.querySelector(".cp") as HTMLElement).innerText + " " + (document.querySelector(".tabs") as HTMLElement).innerText;
  const css = (q: string, p: string) => getComputedStyle(document.querySelector(q)!).getPropertyValue(p);
  return {
    panel: box(".cp").height, firstChain: document.querySelector(".cp .cc") ? box(".cp .cc").top - box(".tr").top : -1, small, bare: text.match(/\b\d+\/\d+\b|\d+ in chains/g) || [],
    chTab: css(".tabs .tab.ch", "color"), plainTab: css(".tabs .tab:not(.ch)", "color"),
    chTabBorder: css(".tabs .tab.ch", "border-top-color"), panelBorder: css(".cp", "border-top-color"),
  };
});

test("the Chains tab at 1280 px, dark, is short, starts its first chain high, reads no bare n/m and wears its own colour joined to the panel", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.emulateMedia({ colorScheme: "dark" });
  await open(page);
  await go(page, "#/board?tab=chains");
  await expect(page.locator(".cp .cc").first()).toBeVisible();
  const m = await chainsMeasure(page);
  console.log("CHAINS-1280-DARK", JSON.stringify(m));
  expect(m.panel).toBeLessThan(PANEL_MAX + MARGIN);
  expect(m.firstChain).toBeLessThan(FIRST_CHAIN_MAX);
  expect(m.small).toEqual([]);
  expect(m.bare).toEqual([]);
  expect(m.chTab).not.toBe(m.plainTab); // the Chains tab is a different colour from a ticket tab
  expect(m.chTabBorder).toBe(m.panelBorder); // and joins the panel in that colour
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
  await shot(page, "board-1280-dark-chains");
});

test("the Chains tab at 1280 px, dark, with a later version's tile picked, still reads that version alone", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.emulateMedia({ colorScheme: "dark" });
  await open(page);
  await go(page, "#/board?tab=chains");
  await page.locator(".bh .vc", { hasText: "v1.1.4" }).click();
  await expect(page.locator(".vc.sel")).toContainText("v1.1.4");
  await expect(page.locator("#rm-chains")).toContainText("v1.1.4");
  const m = await chainsMeasure(page);
  expect(m.small).toEqual([]);
  expect(m.bare).toEqual([]);
  expect(m.panel).toBeLessThan(PANEL_MAX + MARGIN);
  await shot(page, "board-1280-dark-chains-v1.1.4");
});

test("the Chains tab at 390 px, dark: versions and tabs are one sideways row each, a chain opens to its full titles, the page does not scroll", async ({ page }) => {
  await page.route("**/api/board", async (route) => { // the Chains tab reads its titles from the chain read, so the long title goes there
    const res = await route.fetch();
    const j = await res.json();
    for (const c of [j.chains, j.versionChains]) { const t = c && c.tickets && c.tickets["HIMMEL-2"]; if (t) t.title = LONG_TITLE; }
    await route.fulfill({ response: res, json: j });
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: "dark" });
  await open(page);
  await go(page, "#/board?tab=chains");
  await expect(page.locator(".cp .cc").first()).toBeVisible();
  const rows = await page.evaluate(() => ["#main .vchips", "#main .tabs"].map((q) => { const el = document.querySelector(q)!; const s = getComputedStyle(el); return { wrap: s.flexWrap, ox: s.overflowX, rows: new Set(Array.from(el.children).map((c) => { const r = c.getBoundingClientRect(); return Math.round((r.top + r.bottom) / 2 / 3); })).size }; }));
  expect(rows).toEqual([{ wrap: "nowrap", ox: "auto", rows: 1 }, { wrap: "nowrap", ox: "auto", rows: 1 }]); // every child shares one centre line (to 3 px): no second row
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
  const fold = page.locator(".cp details.fold", { has: page.locator(".tl li", { hasText: LONG_TITLE }) }).first();
  await fold.locator("summary").first().click();
  const title = fold.locator(".tl li", { hasText: LONG_TITLE }).first();
  await expect(title).toBeVisible();
  const cut = await title.evaluate((el) => { const s = getComputedStyle(el); return { ellipsis: s.textOverflow === "ellipsis", sideways: el.scrollWidth > el.clientWidth + 1, wrapped: el.clientHeight > 2 * parseFloat(s.fontSize) }; });
  expect(cut).toEqual({ ellipsis: false, sideways: false, wrapped: true }); // the whole title wraps inside the line: not cut, not scrolled
  const m = await chainsMeasure(page);
  expect(m.small).toEqual([]);
  expect(m.bare).toEqual([]);
  await shot(page, "board-390-dark-chains");
});

test("the outside-ticket name is a hover bubble at 1280 px and plain text on a phone", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains");
  const display = () => page.evaluate(() => { const s = document.createElement("span"); s.className = "outn"; s.textContent = "x"; const w = document.createElement("div"); w.appendChild(s); document.querySelector(".cp")!.appendChild(w); const d = getComputedStyle(s).display; w.remove(); return d; });
  await page.setViewportSize({ width: 1280, height: 900 });
  expect(await display()).toBe("none");
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await display()).toBe("inline");
});

// A Won't ticket and long sector names, added to the roadmap read in flight. The Chains tab must hold at both widths. The Roadmap and
// Tidy up tabs overflow with this fixture on the commit before this change too (their version-window row), so they are not asserted here.
test("with a Won't ticket and long sector names the Chains tab does not scroll sideways at 1280 or 390 px", async ({ page }) => {
  const LONG_SECTOR = "A sector name that is far too long to sit on one line in a card header";
  await page.route("**/api/roadmap", async (route) => {
    const res = await route.fetch();
    const j = await res.json();
    j.themes = j.themes.map((_: string, i: number) => `${LONG_SECTOR} ${i + 1}`);
    const t = j.tickets.find((x: { t: string }) => x.t === "Not in any chain");
    t.b = "wont"; t.s = "Won't Do";
    await route.fulfill({ response: res, json: j });
  });
  await open(page);
  for (const [width, height] of [[1280, 900], [390, 844]]) {
    await page.setViewportSize({ width, height });
    await go(page, "#/board?tab=chains");
    await expect(page.locator(".cp .cc").first()).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
  }
});

const MOCKUP_FIRST_CHAIN_Y = 233, MOCKUP_TAB_H = 590, OPEN_CHAIN_ALLOWANCE = 90, LINK_STRIP_ALLOWANCE = 55;
const FIXTURE_TAB_H_MAX = MOCKUP_TAB_H + 3 * OPEN_CHAIN_ALLOWANCE + LINK_STRIP_ALLOWANCE;
function fiveChains() {
  const lnk = (on: string, status: string, onVersions: string[]) => ({ on, kind: "jira-link", source: "jira", added: null, reason: null, owner: null, until: null, clears: `${on} completes`, status, at: null, onVersions });
  const tk = (key: string, title: string, state: string, chain: string, step: number, steps: number, links: object[] = []) =>
    ({ key, title, state, done: state === "done", chains: [{ id: chain, step, steps, state }], links });
  const ch = (id: string, name: string, keys: string[], done: number, steps: number, next: string | null, across: object[] = []) =>
    ({ id, name, members: keys, total: keys.length, done, steps, next: next ? { step: 2, keys: [next] } : null, across, log: [] });
  return { schema: "himmel.chains/1", now: "2026-11-03T08:00:00.000Z", version: "v1.1.3",
    chains: [
      ch("fx-alpha", "Fixture alpha chain: a station finishes setup without hand editing", ["FIX-1", "FIX-2"], 1, 2, "FIX-2", [{ dir: "holds-up", key: "FIX-5", on: "FIX-2", kind: "jira-link", status: "open", chains: ["fx-gamma"] }]),
      ch("fx-beta", "Fixture beta chain: an outside PR gets a full review at its final head", ["FIX-3", "FIX-4", "FIX-9"], 1, 3, null),
      ch("fx-gamma", "Fixture gamma chain: the report page reads the new state", ["FIX-5", "FIX-6"], 0, 2, null, [{ dir: "waits-on", key: "FIX-5", on: "FIX-2", kind: "jira-link", status: "open", chains: ["fx-alpha"] }]),
      ch("fx-ops", "Fixture ops chain: cleanup after the freeze", ["FIX-7", "FIX-8"], 0, 1, null, [{ dir: "waits-on", key: "FIX-8", on: "FIX-90", kind: "jira-link", status: "open", chains: [] }]),
      ch("fx-delta", "Fixture delta chain: the health page counts every row", ["FIX-10", "FIX-11"], 0, 2, null),
    ],
    tickets: {
      "FIX-1": tk("FIX-1", "Fixture step one, migrate the env file", "done", "fx-alpha", 1, 2),
      "FIX-2": tk("FIX-2", "Fixture step two, secrets to a password vault", "can launch", "fx-alpha", 2, 2),
      "FIX-3": tk("FIX-3", "Fixture review step one", "done", "fx-beta", 1, 3),
      "FIX-4": tk("FIX-4", "Fixture review step two, in flight", "in flight", "fx-beta", 2, 3),
      "FIX-9": tk("FIX-9", "Fixture review step three", "waits on step 2", "fx-beta", 3, 3, [lnk("FIX-4", "open", ["v1.1.3"])]),
      "FIX-5": tk("FIX-5", "Fixture report step one, waits on the alpha chain", "waits on FIX-2", "fx-gamma", 1, 2, [lnk("FIX-2", "open", ["v1.1.3"])]),
      "FIX-6": tk("FIX-6", "Fixture report step two", "waits on step 1", "fx-gamma", 2, 2),
      "FIX-7": tk("FIX-7", "Fixture ops step, waits on the freeze", "waits on FIX-91", "fx-ops", 1, 1, [lnk("FIX-91", "open", ["v1.1.3"])]),
      "FIX-8": tk("FIX-8", "Fixture ops step, blocked on a ticket in the next version", "blocked", "fx-ops", 1, 1, [lnk("FIX-90", "open", ["v1.1.4"])]),
      "FIX-10": tk("FIX-10", "Fixture health step one", "in flight", "fx-delta", 1, 2),
      "FIX-11": tk("FIX-11", "Fixture health step two", "waits on step 1", "fx-delta", 2, 2),
    },
    burn: { total: 11, undated: 0, points: [{ day: "2026-11-01", open: 10, merged: 1 }, { day: "2026-11-02", open: 9, merged: 1 }] } };
}
for (const width of [800, 880, 960, 1280]) {
  test(`${width} px: the tab row keeps the refresh button and both links whole, on every tab`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await page.emulateMedia({ colorScheme: "dark" });
    await open(page);
    for (const tab of ["chains", "roadmap", "tidy", "nv"]) {
      await go(page, `#/board?tab=${tab}`);
      const measure = () => page.evaluate(() => { // one task: a repaint cannot land between two measurements
        const aside = document.querySelector<HTMLElement>(".tr .aside"), btn = aside?.querySelector<HTMLElement>(".btn"), sel = document.querySelector('.tr .tabs [aria-selected="true"]'), panel = document.querySelector("section.cp");
        if (!aside || !btn || !sel || !panel) return null;
        const a = aside.getBoundingClientRect(), r = btn.getBoundingClientRect(), tabs = Array.from(document.querySelectorAll<HTMLElement>(".tr .tabs .tab"));
        return {
          buttonInside: r.left >= a.left - 0.5 && r.right <= a.right + 0.5,
          linksWhole: Array.from(aside.querySelectorAll("a")).every((el) => el.scrollWidth <= el.clientWidth + 1),
          noSideways: document.documentElement.scrollWidth <= window.innerWidth + 1,
          tabLines: new Set(tabs.map((t) => Math.round(t.getBoundingClientRect().top))).size,
          selectedMeetsPanel: Math.abs(sel.getBoundingClientRect().bottom - panel.getBoundingClientRect().top) <= 1,
        };
      });
      await expect.poll(measure, { message: tab }).toEqual({ buttonInside: true, linksWhole: true, noSideways: true, tabLines: 1, selectedMeetsPanel: true });
    }
  });
}
for (const width of [390, 800, 1280]) {
  test(`${width} px, classic scrollbars: none is drawn between a tab and its panel, on every tab`, async () => {
    const browser = await chromium.launch({ ignoreDefaultArgs: ["--hide-scrollbars"] }); // headless hides scrollbars by default, which would hide the thing under test
    try {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      await open(page);
      for (const tab of ["chains", "roadmap", "tidy", "nv"]) {
        await go(page, `#/board?tab=${tab}`);
        const m = await page.locator(".tr .tabs").evaluate((el) => ({ scroll: el.scrollHeight - el.clientHeight, bar: (el as HTMLElement).offsetHeight - el.clientHeight }));
        expect(m, `${tab}: the tab list has no scrollbar`).toEqual({ scroll: 0, bar: 0 });
      }
    } finally { await browser.close(); }
  });
}
test("1280 px, dark: the shared rules draw: a plain panel body, a boxed selected tab, a drift pill, the phone's slim chips", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.emulateMedia({ colorScheme: "dark" });
  await open(page);
  await go(page, "#/board?tab=roadmap");
  const body = await page.locator(".cp.plain > section.box").first().evaluate((el) => { const s = getComputedStyle(el); return { border: s.borderTopWidth, bg: s.backgroundColor, pad: s.paddingTop }; });
  expect(body, "the panel's body adds no box of its own").toEqual({ border: "0px", bg: "rgba(0, 0, 0, 0)", pad: "0px" });
  const tab = await page.locator('.tr .tab[aria-selected="true"]').evaluate((el) => { const s = getComputedStyle(el); return { border: s.borderTopWidth, radius: s.borderTopLeftRadius, line: s.textDecorationLine, bg: s.backgroundColor }; });
  expect(tab, "the selected plain tab is a box with a rounded top, not an underline").toEqual({ border: "1px", radius: "8px", line: "none", bg: await page.locator(".cp.plain").evaluate((el) => getComputedStyle(el).backgroundColor) });
  const pill = await page.locator(".tab .drf").evaluate((el) => { const warn = document.createElement("span"); warn.className = "pill warn"; document.body.append(warn); const bg = getComputedStyle(warn).backgroundColor; warn.remove(); return { display: getComputedStyle(el).display, bg: getComputedStyle(el).backgroundColor, warn: bg }; });
  expect(pill.display, "the drift count sits inline in the tab's text").toBe("inline");
  expect(pill.bg, "the drift count wears the amber of a warn pill").toBe(pill.warn);
  expect(await page.locator(".bh .vc progress").first().evaluate((el) => getComputedStyle(el).display), "a chip carries its progress bar on a wide screen").not.toBe("none");
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.locator(".bh .vc progress").first().evaluate((el) => getComputedStyle(el).display), "and drops it on a phone").toBe("none");
  expect(await page.locator(".bh .vc small").first().evaluate((el) => getComputedStyle(el).display)).toBe("none");
});
// What the sideways rows must keep true after every layout (the chip row and the tab row, both). Each entry is one thing that is wrong; [] is clean.
const auditRows = (page: Page): Promise<string[]> => page.evaluate(() => {
  const TOL = 2, bad: string[] = [];
  const rows = Array.from(document.querySelectorAll<HTMLElement>(".xrow"));
  if (rows.length !== 2) bad.push(`expected the chip row and the tab row, found ${rows.length}`);
  for (const x of rows) {
    const row = x.querySelector<HTMLElement>(".vchips,.tabs")!, L = x.querySelector<HTMLElement>(".edge.l")!, R = x.querySelector<HTMLElement>(".edge.r")!;
    const name = row.classList.contains("tabs") ? "tabs" : "chips";
    const items: Element[][] = [];
    for (const c of Array.from(row.children)) { if (c.matches(".pin") && items.length) items[items.length - 1].push(c); else items.push([c]); }
    const box = (it: Element[]) => ({ l: Math.min(...it.map((e) => e.getBoundingClientRect().left)), r: Math.max(...it.map((e) => e.getBoundingClientRect().right)) });
    const a = row.getBoundingClientRect(), lb = L.hidden ? null : L.getBoundingClientRect(), rb = R.hidden ? null : R.getBoundingClientRect();
    const clearL = lb ? lb.right : a.left, clearR = rb ? rb.left : a.right, mid = (a.left + a.right) / 2;
    const sel = row.querySelector('[aria-selected="true"],[aria-current="true"]');
    if (sel) { const b = sel.getBoundingClientRect(); if (b.left < clearL - TOL || b.right > clearR + TOL) bad.push(`${name}: the selected item is not clear of the labels`); }
    let nl = 0, nr = 0;
    for (const it of items) {
      const b = box(it);
      if (b.l >= clearL - TOL && b.r <= clearR + TOL) continue;
      const left = (b.l + b.r) / 2 < mid;
      if (left) nl++; else nr++;
      const under = left ? !!lb && b.r <= lb.right + TOL : !!rb && b.l >= rb.left - TOL;
      const away = b.r <= a.left + TOL || b.l >= a.right - TOL;
      if (!under && !away) bad.push(`${name}: an item is only partly under a label`);
    }
    for (const [el, n, side] of [[L, nl, "left"], [R, nr, "right"]] as const) {
      if (el.hidden === (n > 0)) bad.push(`${name}: the ${side} label is ${el.hidden ? "hidden" : "shown"} with ${n} items past it`);
      if (!el.hidden && Number(el.dataset.n) !== n) bad.push(`${name}: the ${side} label says ${el.dataset.n}, ${n} items are under it`);
      if (!el.hidden && !/\d/.test(el.textContent || "")) bad.push(`${name}: the ${side} label is a bare arrow`);
    }
  }
  const menu = document.querySelector<HTMLElement>(".bh .vmenu"), chips = document.querySelector<HTMLElement>(".bh .vchips"), head = document.querySelector<HTMLElement>(".rm-head.bh");
  if (!menu || !chips || !head) bad.push("the head has no version menu or chip row");
  else {
    const m = menu.getBoundingClientRect(), c = chips.getBoundingClientRect(), h = head.getBoundingClientRect();
    if (chips.closest(".xrow")!.contains(menu)) bad.push("the version menu sits inside the chip row");
    if (!(m.bottom <= c.top + TOL || m.top >= c.bottom - TOL || m.right <= c.left + TOL || m.left >= c.right - TOL)) bad.push("the version menu overlaps the chip row");
    if (m.left < h.left - TOL || m.right > h.right + TOL || m.top < h.top - TOL || m.bottom > h.bottom + TOL) bad.push("the version menu is outside the head");
  }
  return bad;
});
// Tag the first item the row hides on one side (the one nearest the selected item), so a later check can find it again.
const probeHidden = (page: Page, row: string, side: "l" | "r") => page.evaluate(([q, sd]) => {
  document.querySelectorAll("[data-probe]").forEach((e) => e.removeAttribute("data-probe"));
  const x = document.querySelector<HTMLElement>(q)!, rowEl = x.querySelector<HTMLElement>(".vchips,.tabs")!;
  const L = x.querySelector<HTMLElement>(".edge.l")!, R = x.querySelector<HTMLElement>(".edge.r")!;
  const a = rowEl.getBoundingClientRect(), clearL = L.hidden ? a.left : L.getBoundingClientRect().right, clearR = R.hidden ? a.right : R.getBoundingClientRect().left;
  const kids = Array.from(rowEl.children).filter((c) => !c.matches(".pin"));
  const hid = kids.filter((c) => { const b = c.getBoundingClientRect(); return sd === "l" ? b.left < clearL - 2 : b.right > clearR + 2; });
  const pick = sd === "l" ? hid[hid.length - 1] : hid[0];
  if (!pick) return false;
  pick.setAttribute("data-probe", "1");
  return true;
}, [row, side] as const);
const probeClear = (page: Page, row: string) => page.evaluate((q) => {
  const x = document.querySelector<HTMLElement>(q)!, rowEl = x.querySelector<HTMLElement>(".vchips,.tabs")!, p = rowEl.querySelector("[data-probe]");
  const L = x.querySelector<HTMLElement>(".edge.l")!, R = x.querySelector<HTMLElement>(".edge.r")!;
  const a = rowEl.getBoundingClientRect(), clearL = L.hidden ? a.left : L.getBoundingClientRect().right, clearR = R.hidden ? a.right : R.getBoundingClientRect().left;
  const b = p!.getBoundingClientRect();
  return b.left >= clearL - 2 && b.right <= clearR + 2;
}, row);
const focusedClear = (page: Page) => page.evaluate(() => {
  const f = document.activeElement, x = f && f.closest(".xrow");
  if (!f || !x) return null;
  const rowEl = x.querySelector<HTMLElement>(".vchips,.tabs")!, L = x.querySelector<HTMLElement>(".edge.l")!, R = x.querySelector<HTMLElement>(".edge.r")!;
  const a = rowEl.getBoundingClientRect(), clearL = L.hidden ? a.left : L.getBoundingClientRect().right, clearR = R.hidden ? a.right : R.getBoundingClientRect().left;
  const b = f.getBoundingClientRect();
  return b.left >= clearL - 2 && b.right <= clearR + 2;
});
const PHONE_TABS = ["chains", "roadmap", "tidy", "nv"];
test("390 px: on every tab both sideways rows keep the selected item clear, every item whole or wholly under one label, each label's number true, after the first paint, a refresh, and a resize to 600 px and back", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: "dark" });
  await open(page);
  for (const tab of PHONE_TABS) {
    await go(page, `#/board?tab=${tab}`);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), tab).toBe(true);
    expect(await page.evaluate(() => { const t = document.querySelector(".tr .tabs")!; return t.scrollWidth > t.clientWidth; }), `${tab}: the tab list is wider than the phone`).toBe(true);
    expect(await auditRows(page), `${tab}: first paint`).toEqual([]);
    await Promise.all([page.waitForResponse((r) => r.url().includes("/api/")), page.locator('.aside [data-act="refresh-roadmap"]').click()]);
    await page.waitForLoadState("networkidle");
    await expect.poll(() => auditRows(page), { message: `${tab}: after a refresh` }).toEqual([]);
    for (const w of [600, 390]) {
      await page.setViewportSize({ width: w, height: 844 });
      await expect.poll(() => auditRows(page), { message: `${tab}: at ${w} px` }).toEqual([]);
    }
  }
  await shot(page, "board-tabs-sideways-dark-390");
});
test("390 px: a tap on an edge label leaves the route as it was and brings the next hidden item wholly clear", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: "dark" });
  await open(page);
  await go(page, "#/board?tab=chains");
  const hash = await page.evaluate(() => location.hash);
  let taps = 0;
  for (const [row, label] of [[".tr .xrow", "r"], [".tr .xrow", "l"], [".rm-head.bh .xrow", "r"], [".rm-head.bh .xrow", "l"]] as const) {
    const edge = page.locator(`${row} .edge.${label}`);
    if (!(await edge.isVisible())) continue;
    expect(await edge.evaluate((el) => getComputedStyle(el).position), `${row} ${label}: the label sits over the row`).toBe("absolute");
    expect(await probeHidden(page, row, label), `${row} ${label}: an item is hidden behind the label`).toBe(true);
    await edge.click();
    taps++;
    expect(await page.evaluate(() => location.hash), `${row} ${label}: the route`).toBe(hash);
    await expect.poll(() => probeClear(page, row), { message: `${row} ${label}: the next item is clear` }).toBe(true);
    expect((await auditRows(page)).filter((m) => !m.includes("selected item")), `${row} ${label}`).toEqual([]); // the person moved the row away from the selected item on purpose
  }
  expect(taps, "a label was visible to tap").toBeGreaterThan(0);
});
test("390 px: focus on a hidden tab or chip moves it wholly clear of both labels, tabbing through each row", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: "dark" });
  await open(page);
  await go(page, "#/board?tab=chains");
  const last = page.locator(".tr .tabs .tab").last();
  expect(await last.evaluate((el) => el.getBoundingClientRect().right > el.parentElement!.getBoundingClientRect().right), "the last tab starts off-screen").toBe(true);
  await last.focus();
  expect(await focusedClear(page), "the last tab, focused").toBe(true);
  await page.locator(".bh .vchips .vc").first().focus();
  const seen: (boolean | null)[] = [];
  for (let k = 0; k < 16; k++) { await page.keyboard.press("Tab"); seen.push(await focusedClear(page)); }
  expect(seen.filter((v) => v === true).length, "the key reached the rows' items").toBeGreaterThan(3);
  expect(seen.filter((v) => v === false), "a focused item sat under a label").toEqual([]);
});
test("390 px: a row the person scrolled keeps its place across a refresh, and a tab change starts the row placed afresh", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: "dark" });
  await open(page);
  await go(page, "#/board?tab=chains");
  const tabs = page.locator(".tr .tabs");
  const settle = () => page.evaluate(() => new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(ok))));
  const start = await tabs.evaluate((el) => el.scrollLeft);
  let kept = -1;
  for (const d of [12, 24, 40, 60]) {
    await tabs.evaluate((el, to) => { el.scrollLeft = to; }, start + d);
    await settle();
    const now = await tabs.evaluate((el) => el.scrollLeft);
    if (Math.abs(now - start) > 4 && (await auditRows(page)).length === 0) { kept = now; break; }
  }
  expect(kept, "a hand-scrolled place where the selected tab stays clear").toBeGreaterThanOrEqual(0);
  await Promise.all([page.waitForResponse((r) => r.url().includes("/api/")), page.locator('.aside [data-act="refresh-roadmap"]').click()]);
  await page.waitForLoadState("networkidle");
  await settle();
  expect(Math.abs((await tabs.evaluate((el) => el.scrollLeft)) - kept), "the scroll after a refresh").toBeLessThanOrEqual(2);
  await page.locator(".tr .tabs .tab").first().click(); // another tab: the row is placed for that tab, not left where it was
  await expect(page.locator('.tr .tabs .tab[aria-selected="true"]')).toHaveText(/Roadmap/);
  await page.waitForLoadState("networkidle");
  await settle();
  expect(await tabs.evaluate((el) => el.scrollLeft), "Roadmap is the first tab: nothing to scroll past").toBeLessThanOrEqual(2);
  expect(await auditRows(page)).toEqual([]);
});
for (const [width, height] of [[1280, 900], [390, 844]]) {
  test(`${width} px: five open chains stay compact, each open chain one rail, and the Ops chain's steps and Why links stay on one line`, async ({ page }) => {
    await page.route("**/api/board", async (route) => {
      const res = await route.fetch();
      const j = await res.json();
      j.chains = fiveChains();
      j.versionChains = fiveChains();
      await route.fulfill({ response: res, json: j });
    });
    await page.setViewportSize({ width, height });
    await page.emulateMedia({ colorScheme: "dark" });
    await open(page);
    await go(page, "#/board?tab=chains");
    await expect(page.locator("#rm-chains article.cc")).toHaveCount(5);
    for (const art of await page.locator("#rm-chains article.cc").all()) {
      await expect(art.locator(".rl")).toHaveCount(1);
      expect(await art.locator("details[open]").count()).toBe(0);
    }
    const top = await page.locator("#rm-chains article.cc").first().evaluate((el) => el.getBoundingClientRect().top + window.scrollY);
    const bottom = await page.locator("#rm-chains").evaluate((el) => el.getBoundingClientRect().bottom + window.scrollY);
    const ys = await page.locator("#rm-chain-fx-ops .rl").locator(".tk, .rm-whylink").evaluateAll((els) => els.map((e) => Math.round(e.getBoundingClientRect().top)));
    const twOverflow = await page.locator("#rm-chains .tw").evaluateAll((els) => els.map((e) => getComputedStyle(e).overflowX + "/" + getComputedStyle(e).overflowY));
    expect(twOverflow.length).toBeGreaterThan(0);
    expect(twOverflow.every((o) => o === "visible/visible"), `a chip wrapper must not scroll, it would clip the chip's focus outline: ${[...new Set(twOverflow)].join(",")}`).toBe(true);
    await shot(page, `board-chains-five-fixture-dark-${width}`);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true);
    if (width === 1280) {
      console.log("CHAINS-FIVE-1280", JSON.stringify({ top, bottom }));
      expect(Math.abs(top - MOCKUP_FIRST_CHAIN_Y), `first chain at ${top}px`).toBeLessThanOrEqual(40);
      expect(bottom).toBeLessThanOrEqual(FIXTURE_TAB_H_MAX);
      expect(Math.max(...ys) - Math.min(...ys)).toBeLessThanOrEqual(8);
    }
  });
}
