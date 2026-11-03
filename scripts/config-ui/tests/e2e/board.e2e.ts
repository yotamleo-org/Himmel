// The Board page, run for real: `himmelctl ui` over a seeded Jira mirror (three versions, one chain, a saved drift run).
// One Board entry in the rail; the old Roadmap and Kanban routes land on it; the version strip, the drift banner, the chain badge,
// the three tabs and the lanes draw from the seeded sources; no console error at 1280 and 390 px, light and dark.
// E2E_SHOTS=<dir> saves the build-side screenshot of each frame, named board-<width>-<scheme>-<tab>.png, to pair with the mockup.
import { test, expect, type Page } from "@playwright/test";
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
  await expect(page.locator(".rm-card", { hasText: "First chain step" })).toBeHidden(); // a Done ticket: the Done column is folded
  await page.locator("#rm-lanes details.rm-done summary").click();
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
  for (const [col, name] of [["rev", "In Review"], ["ci", "IN CI"], ["done", "Done"]]) {
    await page.locator(".rm-card", { hasText: "Second chain step" }).dragTo(page.locator(`[data-rm-drop="${col}"]`));
    await expect(page.locator("#main .alert", { hasText: `${name} is moved by its event` })).toBeVisible(); // the note names this drop's column, so the last drop's note cannot satisfy it
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

test("a ticket with no fixVersion is on its own No version tab, fetched only when the tab opens; no version board has it", async ({ page }) => {
  const errs = consoleErrors(page);
  const reads: string[] = [];
  page.on("request", (r) => { if (r.url().includes("/api/roadmap")) reads.push(r.url()); });
  await open(page);
  await go(page, "#/board");
  await expect(page.locator(".rm-card", { hasText: "Work in flight" })).toBeVisible();
  await expect(page.locator(".rm-card", { hasText: "Standing ticket with no version" })).toHaveCount(0);
  await expect(page.locator("#rm-nv")).toHaveCount(0);
  await expect(page.getByRole("tab", { name: /^No version/ })).toContainText("1");
  expect(reads.every((u) => !u.includes("nv=1"))).toBe(true); // the default read did not ask for them
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
  // the token lives in memory only, so the reloaded page is refused (401) and draws no card; the proof is that route() reaches loadNoVersion() at load without a ReferenceError
  const asked = page.waitForRequest((r) => r.url().includes("/api/roadmap?nv=1"));
  await page.reload();
  await asked;
  await expect(page.locator("#main")).toContainText("roadmap failed (401)");
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
  for (const tab of ["roadmap", "chains", "tidy"]) {
    await go(page, `#/board?tab=${tab}`);
    await expect(page.locator('.rm-bar [data-act="refresh-roadmap"]')).toHaveCount(1);
  }
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

test("the Chains tab draws the link across chains, the change log and the burn-down", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains");
  const links = page.locator("#rm-xlinks");
  await expect(links).toContainText("HIMMEL-6");
  await expect(links).toContainText("HIMMEL-2");
  await expect(links).toContainText("Ops cleanup chain");
  await expect(page.locator(".rm-map .rm-edge.open")).toHaveCount(1);
  const log = page.locator('.rm-log[data-log="ops"]');
  await expect(log.locator("summary")).toContainText("Change log · 2");
  await log.locator("summary").click();
  await expect(log).toContainText("waiting on the freeze");
  const burn = page.locator("#rm-burn");
  await expect(burn.locator(".rm-burn-words")).toContainText("3 open of 4");
  await expect(burn.locator(".rm-burn-words")).toContainText("1 merged since 2026-10-30");
  expect(await burn.locator("circle").count()).toBeGreaterThan(1);
  await expect(burn.locator(".rm-burn-pace")).toHaveCount(0); // the running version has no date
});

test("the Why panel names the blocker of a blocked ticket; Esc closes it, focus returns, and an open change log stays open", async ({ page }) => {
  await open(page);
  await go(page, "#/board?tab=chains");
  await page.locator('.rm-log[data-log="ops"] summary').click();
  const opener = page.locator('tr#cn-HIMMEL-7 [data-why-open="HIMMEL-7.HIMMEL-21"]');
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

test("the ticket drawer keeps its behaviour beside the Why panel: Esc closes it and focus returns to its card", async ({ page }) => {
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
  expect(await page.locator(".rm-edge.open").evaluate((e) => getComputedStyle(e).animationName)).toBe("rm-dash");
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
      await expect(page.locator(".rm-map-note")).toBeVisible({ visible: width > 640 }); // the note speaks of the map: gone with it on a phone
      const keyLines = await page.locator("#cn-HIMMEL-7 td").first().evaluate((e) => { const r = document.createRange(); r.selectNodeContents(e); return r.getClientRects().length; });
      expect(keyLines).toBe(1); // a ticket key never breaks mid-word
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
  await expect(page.locator("#main")).toContainText("drift: not read");
  await expect(page.locator(".rm-link").first()).toContainText("waits for you: not read");
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
  await expect(page.locator(".rm-vstrip .rm-vt", { hasText: "v1.1.3 (SALUS)" })).toHaveCount(1);
  await expect(page.locator(".rm-vstrip .rm-vt", { hasText: "v1.1.3 (HIMMEL)" })).toHaveCount(1);
  await shot(page, "board-1280-two-projects");
  // the Project filter narrows to one
  await page.locator('select[data-rm-filter="project"]').selectOption({ label: "SALUS" });
  await expect(page.locator(".rm-card", { hasText: "Salus intake form" })).toBeVisible();
  await expect(page.locator(".rm-card", { hasText: "Second chain step" })).toHaveCount(0);
  // a drag of the SALUS card posts a body naming project SALUS
  const sent: string[] = [];
  await page.route("**/api/roadmap/write", async (route) => { sent.push(route.request().postData() || ""); await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ ok: true }) }); });
  await page.locator(".rm-card", { hasText: "Salus intake form" }).dragTo(page.locator('[data-rm-drop="prog"]'));
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
