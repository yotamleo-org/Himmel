// Journey J3: the Configure page (it replaced Settings and Setup) with its four group tiles, and the Board follows the tracker source.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test, expect, type Page } from "@playwright/test";
import { boot, type Harness, type TrackerKind } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const TILES = ["Secrets", "Review", "Tracker", "Project scope"];
// the Settings groups that sit under the Project scope tile
const SCOPE_GROUPS = ["Auto-ship steps", "Plugins", "Scheduled jobs", "Your install answers"];
// the setup read can take longer than a poll's default 5 s (the CodeRabbit probe alone allows 5 s)
const SETUP_WAIT = { timeout: 20_000 };

async function open(page: Page, tracker: TrackerKind = "jira", tile?: string) {
  h = await boot({}, { tracker });
  await page.goto(h.url);
  await page.locator("#h-configure").waitFor();
  if (tile) await page.locator(`button.tile[data-tile="${tile}"]`).click();
}

test("J3. the page is Configure: its rail entry and title, then the four tiles in order, one open at a time", async ({ page }) => {
  await open(page);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Configure");
  await expect(page.locator("#h-configure")).toHaveText("Configure");
  await expect(page.locator(".tiles .tile .tname")).toHaveText(TILES);
  await page.locator('button.tile[data-tile="review"]').click();
  await expect(page.locator('button.tile[aria-expanded="true"]')).toHaveCount(1);
  await expect(page.locator('button.tile[data-tile="review"]')).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator('button.tile[data-tile="review"]')).toBeFocused(); // the repaint keeps a keyboard user on the tile
  await page.locator('button.tile[data-tile="review"]').click();
  await expect(page.locator('button.tile[aria-expanded="true"]')).toHaveCount(0);
});

test("J3. the Check this install strip sits under the tile row", async ({ page }) => {
  await open(page);
  // a repaint when the setup read lands replaces both nodes, so read the two boxes together and retry
  await expect.poll(async () => {
    const tiles = await page.locator(".tiles").boundingBox();
    const chk = await page.locator(".chk").boundingBox();
    return tiles && chk ? chk.y - tiles.y : -1;
  }, SETUP_WAIT).toBeGreaterThan(0);
  await expect(page.locator(".chk")).toContainText("Check this install");
});

test("J3. every Project scope row shows its command, when it takes effect and a Learn more link to the docs site", async ({ page }) => {
  await open(page, "jira", "scope");
  const rows = page.locator('#tile-scope .setgroup:has(h3[id^="sg-"]) .setrow'); // the Fleet cap and VM rows are machine settings, with no command or Learn more link
  await expect.poll(() => rows.count(), SETUP_WAIT).toBeGreaterThanOrEqual(5);
  for (const r of await rows.all()) {
    // Machine settings has no command to copy: its only content was the config file path, which decision 578 hides
    if ((await r.locator(".id").first().textContent())?.trim() !== "Machine settings") await expect(r.locator('button[data-act="copy"], code').first()).not.toBeEmpty();
    await expect(r.locator("pre code")).toHaveCount(0);
    for (const copy of await r.locator('button[data-act="copy"]').all()) {
      // decision 578: the tooltip is plain text, never the command with its key names and paths
      const tip = await copy.getAttribute("title");
      expect(tip).toBeTruthy();
      expect(tip).not.toBe(await copy.getAttribute("data-cmd"));
      expect(tip).not.toMatch(/[A-Z_]{4,}|\.json|\.conf|\.env|config set|~\//);
    }
    await expect(r).toContainText("takes effect: ");
    await expect(r.locator("a.learn")).toHaveAttribute("href", /^https:\/\/yotamleo-org\.github\.io\/Himmel\/[a-z/-]+$/);
    await expect(r.locator("a.learn")).toHaveAttribute("target", "_blank");
  }
  await expect(page.locator("#tile-scope .setgroup h3").filter({ hasText: /^(Plugins|Auto-ship steps|Scheduled jobs|Your install answers)$/ })).toHaveText(SCOPE_GROUPS);
});

// Proof shots: the Project scope categories at 1280 and 390 wide, light and dark, all folded and the first expanded.
// Writes nothing unless E2E_SHOTS names a folder, so it never leaves files in the tree.
test("J3. the Project scope categories fold, and expand on a click (proof shots with E2E_SHOTS)", async ({ page }) => {
  const shots = process.env.E2E_SHOTS;
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: width === 1280 ? 900 : 800 });
    await open(page, "jira", "scope");
    const cats = page.locator("#tile-scope details.cat");
    await expect(cats).toHaveCount(5, SETUP_WAIT);
    await expect(cats.first()).toHaveAttribute("open", "");
    await expect(page.locator("#tile-scope details.cat[open]")).toHaveCount(1);
    for (const scheme of ["light", "dark"] as const) {
      await page.emulateMedia({ colorScheme: scheme });
      await cats.first().locator("> summary").click();
      await expect(page.locator("#tile-scope details.cat[open]")).toHaveCount(0);
      if (shots) await page.locator("#tile-scope").screenshot({ path: `${shots}/configure-scope-${width}-${scheme}-collapsed.png` });
      await cats.first().locator("> summary").click();
      await expect(page.locator("#tile-scope details.cat[open]")).toHaveCount(1);
      if (shots) await page.locator("#tile-scope").screenshot({ path: `${shots}/configure-scope-${width}-${scheme}-expanded.png` });
    }
  }
});

test("J3. the Tracker tile's Team mode switch shows off when unset, previews a dry run, and writes tracker.teamMode", async ({ page }) => {
  await open(page, "jira", "tracker");
  const on = page.locator('button[data-action="config.tracker"][data-value="on"]');
  await expect(page.locator("#tile-tracker")).toContainText("Board · who edits this Jira project", SETUP_WAIT);
  await expect(page.locator('button[data-action="config.tracker"][data-value="off"]')).toHaveAttribute("aria-pressed", "true");
  const shots = process.env.E2E_SHOTS;
  await on.click();
  const box = page.locator("#tile-tracker .dryrun");
  await expect(box).toContainText("HIMMEL_TRACKER_TEAM_MODE=on");
  if (shots) for (const scheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme: scheme });
    await page.screenshot({ path: `${shots}/configure-tracker-team-mode-${scheme}.png`, fullPage: true });
  }
  await box.locator('[data-act="run"]').click();
  await expect.poll(() => h.argv(), SETUP_WAIT).toContain("himmelctl config set tracker.teamMode on");
  await expect.poll(() => readFileSync(join(h.home, ".himmel", "himmel.conf"), "utf8"), SETUP_WAIT).toContain("HIMMEL_TRACKER_TEAM_MODE=on\n");
  // a full page load, as a new tab gets it: the token is kept in memory only, so a bare page.reload() answers 401
  await page.goto("about:blank");
  await page.goto(h.url);
  await page.locator('button.tile[data-tile="tracker"]').click();
  await expect(on).toHaveAttribute("aria-pressed", "true", SETUP_WAIT);
  await expect(page.locator('button[data-action="config.tracker"][data-value="off"]')).toHaveAttribute("aria-pressed", "false");
});

test("J3. the Tracker tile points commit rules at ~/.himmel/himmel.conf, not the shell profile", async ({ page }) => {
  await open(page, "jira", "tracker");
  const t = page.locator("#tile-tracker");
  await expect(t).toContainText("~/.himmel/himmel.conf");
  await expect(t).not.toContainText(/shell profile/i);
  await expect(t.locator(".cols .col")).toHaveCount(2); // the shared dry-run box appears only once a change is previewed
});

test("J3. a switch on Configure still previews its dry-run first and runs nothing on cancel", async ({ page }) => {
  await open(page, "jira", "scope");
  await page.locator('#tile-scope button[data-act="plan"][data-target="pipeline"]').click();
  const plan = page.locator("#tile-scope .plan");
  await expect(plan).toContainText("dry-run · nothing has changed");
  await expect(plan.locator('button[data-act="run"]')).toBeDisabled();
  await plan.locator('button[data-act="close"]').click();
  await expect(page.locator("#tile-scope .plan")).toHaveCount(0);
  expect(h.argv().every((l) => l.endsWith("--dry-run")), h.argv().join("\n")).toBe(true);
});

for (const [tracker, shown] of [["none", true], ["local", false], ["jira", true]] as [TrackerKind, boolean][]) {
  test(`J3. with the ${tracker} tracker the rail ${shown ? "shows" : "hides"} Board`, async ({ page }) => {
    await open(page, tracker);
    const rail = page.locator("nav.pages a");
    await expect.poll(async () => (await rail.allTextContents()).includes("Board")).toBe(shown);
    // the two pages the Board replaced are gone from the rail whatever the tracker
    const labels = await rail.allTextContents();
    expect(labels.includes("Roadmap") || labels.includes("Kanban")).toBe(false);
  });
}

test("J3. at 390 px no tile makes the page scroll sideways", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await open(page);
  for (const t of ["secrets", "review", "tracker", "scope"]) {
    await page.locator(`button.tile[data-tile="${t}"]`).click();
    await expect(page.locator(`#tile-${t}`)).toBeVisible();
    const w = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
    expect(w.scroll, `${t}: page ${w.scroll}px in a ${w.client}px window`).toBeLessThanOrEqual(w.client);
  }
});

test("J4. on a 3840 px screen the panel stays a readable width and every secret input ends on one edge", async ({ page }) => {
  await page.setViewportSize({ width: 3840, height: 2160 });
  await open(page);
  for (const t of ["secrets", "review", "tracker", "scope"]) {
    await page.locator(`button.tile[data-tile="${t}"]`).click();
    // a repaint when the setup read lands replaces the panel, so measure inside a retry
    await expect.poll(async () => {
      const w = (await page.locator(`#tile-${t}`).boundingBox())?.width ?? 0;
      return w > 0 && w <= 3840 * 0.45 ? "readable" : `${t} panel ${w}px`;
    }, SETUP_WAIT).toBe("readable");
  }
  await page.locator('button.tile[data-tile="secrets"]').click();
  await expect.poll(async () => {
    const edges = await page.locator("#tile-secrets form[data-setup-form] input").evaluateAll((els) => els.map((e) => Math.round(e.getBoundingClientRect().right)));
    return edges.length > 1 && new Set(edges).size === 1 ? "one edge" : `input right edges ${edges}`;
  }, SETUP_WAIT).toBe("one edge");
});
