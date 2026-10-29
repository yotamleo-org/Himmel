// Journey J3: the Configure page (it replaced Settings and Setup) with its four group tiles, and Roadmap and Kanban follow the tracker source.
import { test, expect, type Page } from "@playwright/test";
import { boot, type Harness, type TrackerKind } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const TILES = ["Secrets", "Review", "Tracker", "Project scope"];
// the Settings groups that sit under the Project scope tile
const SCOPE_GROUPS = ["Auto-ship steps", "Plugins", "Scheduled jobs", "Your install answers"];

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
  await expect(page.locator(".chk")).toBeVisible();
  const tiles = await page.locator(".tiles").boundingBox();
  const chk = await page.locator(".chk").boundingBox();
  expect(chk!.y).toBeGreaterThan(tiles!.y);
  await expect(page.locator(".chk")).toContainText("Check this install");
});

test("J3. every Project scope row shows its command, when it takes effect and a Learn more link to the docs site", async ({ page }) => {
  await open(page, "jira", "scope");
  const rows = page.locator('#tile-scope .setgroup:has(h3[id^="sg-"]) .setrow'); // the Fleet cap and VM rows are machine settings, with no command or Learn more link
  await expect.poll(() => rows.count()).toBeGreaterThanOrEqual(5);
  for (const r of await rows.all()) {
    await expect(r.locator("pre code")).not.toBeEmpty();
    await expect(r).toContainText("takes effect: ");
    await expect(r.locator("a.learn")).toHaveAttribute("href", /^https:\/\/yotamleo-org\.github\.io\/Himmel\/[a-z/-]+$/);
    await expect(r.locator("a.learn")).toHaveAttribute("target", "_blank");
  }
  await expect(page.locator("#tile-scope .setgroup h3").filter({ hasText: /^(Plugins|Auto-ship steps|Scheduled jobs|Your install answers)$/ })).toHaveText(SCOPE_GROUPS);
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

for (const [tracker, shown] of [["none", false], ["local", false], ["jira", true]] as [TrackerKind, boolean][]) {
  test(`J3. with the ${tracker} tracker the rail ${shown ? "shows" : "hides"} Roadmap and Kanban`, async ({ page }) => {
    await open(page, tracker);
    const rail = page.locator("nav.pages a");
    await expect.poll(async () => (await rail.allTextContents()).includes("Roadmap")).toBe(shown);
    expect((await rail.allTextContents()).includes("Kanban")).toBe(shown);
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
    await expect(page.locator(`#tile-${t}`)).toBeVisible();
    const box = await page.locator(`#tile-${t}`).boundingBox();
    expect(box!.width, `${t} panel`).toBeLessThanOrEqual(3840 * 0.45);
  }
  await page.locator('button.tile[data-tile="secrets"]').click();
  await expect(page.locator("#tile-secrets form[data-setup-form] input")).toHaveCount(3);
  const edges = await page.locator("#tile-secrets form[data-setup-form] input").evaluateAll((els) => els.map((e) => Math.round(e.getBoundingClientRect().right)));
  expect(edges.length).toBeGreaterThan(1);
  expect(new Set(edges).size, `input right edges ${edges}`).toBe(1);
});
