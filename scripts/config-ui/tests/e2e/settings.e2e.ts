// Journey J3: Config becomes Settings with the frame-10 groups, and Roadmap and Kanban follow the tracker source.
import { test, expect, type Page } from "@playwright/test";
import { boot, type Harness, type TrackerKind } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const GROUPS = ["Plugins", "Review by a second model", "Auto-ship steps", "Scheduled jobs", "Commit rules", "Session switches", "Your install answers"];

async function open(page: Page, tracker: TrackerKind = "jira") {
  h = await boot({}, { tracker });
  await page.goto(h.url);
  await page.locator("#settings").waitFor();
}

test("J3. the page is Settings: its rail entry and title, then the seven groups in order", async ({ page }) => {
  await open(page);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Settings");
  await expect(page.locator("#h-settings")).toHaveText("Settings");
  await expect(page.locator("#settings h3")).toHaveText(GROUPS);
});

test("J3. every row shows its command, when it takes effect and a Learn more link to the docs site", async ({ page }) => {
  await open(page);
  const rows = page.locator("#settings .setrow");
  expect(await rows.count()).toBeGreaterThanOrEqual(10);
  for (const r of await rows.all()) {
    await expect(r.locator("pre code")).not.toBeEmpty();
    await expect(r).toContainText("takes effect: ");
    await expect(r.locator("a.learn")).toHaveAttribute("href", /^https:\/\/yotamleo-org\.github\.io\/Himmel\/[a-z/-]+$/);
    await expect(r.locator("a.learn")).toHaveAttribute("target", "_blank");
  }
});

test("J3. Commit rules point at ~/.himmel/himmel.conf, not the shell profile, and offer no switch", async ({ page }) => {
  await open(page);
  const g = page.locator("#settings .setgroup", { has: page.locator("#sg-commit-rules") });
  await expect(g).toContainText("~/.himmel/himmel.conf");
  await expect(g).not.toContainText(/shell profile/i);
  await expect(g.locator("button")).toHaveCount(0);
});

test("J3. a switch in Settings still previews its dry-run first and runs nothing on cancel", async ({ page }) => {
  await open(page);
  await page.locator('#settings button[data-act="plan"][data-target="pipeline"]').click();
  const plan = page.locator("#settings .plan");
  await expect(plan).toContainText("dry-run · nothing has changed");
  await expect(plan.locator('button[data-act="run"]')).toBeDisabled();
  await plan.locator('button[data-act="close"]').click();
  await expect(page.locator("#settings .plan")).toHaveCount(0);
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
