// Journey J3: the Configure page (it replaced Settings and Setup) with its four group tiles, and Roadmap and Kanban follow the tracker source.
import { test, expect, type Page } from "@playwright/test";
import { boot, type Harness, type TrackerKind } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const TILES = ["Secrets", "Review", "Tracker", "Project scope"];
// the Settings groups that sit under the Project scope tile
const SCOPE_GROUPS = ["Plugins", "Auto-ship steps", "Scheduled jobs", "Your install answers"];

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
  await page.locator('button.tile[data-tile="review"]').click();
  await expect(page.locator('button.tile[aria-expanded="true"]')).toHaveCount(0);
});

test("J3. the Check this install strip sits under the tile row", async ({ page }) => {
  await open(page);
  const tiles = await page.locator(".tiles").boundingBox();
  const chk = await page.locator(".chk").boundingBox();
  expect(chk!.y).toBeGreaterThan(tiles!.y);
  await expect(page.locator(".chk")).toContainText("Check this install");
});

test("J3. every Project scope row shows its command, when it takes effect and a Learn more link to the docs site", async ({ page }) => {
  await open(page, "jira", "scope");
  const rows = page.locator("#tile-scope .setrow");
  expect(await rows.count()).toBeGreaterThanOrEqual(5);
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
