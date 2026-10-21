// trackerSources() per source: the rail offers Roadmap and Kanban only when the UI can read a tracker.
// Jira only, local only, GitHub only, none; a direct #/kanban with no tracker says so in plain words.
import { test, expect, type Page } from "@playwright/test";
import { boot, type Harness, type TrackerKind } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const RAIL = (tracker: TrackerKind) => tracker === "local" || tracker === "none"
  ? ["Config", "Health", "Tool health", "Fleet", "Docs"]
  : ["Config", "Health", "Tool health", "Fleet", "Roadmap", "Kanban", "Docs"];

// landing: a console page id opened straight from the landing fragment (#t=<token>&page=<id>), as a bookmark would.
async function open(page: Page, tracker: TrackerKind, landing = "") {
  h = await boot({}, { tracker });
  await page.goto(landing ? `${h.url}&page=${landing}` : h.url);
  await page.locator("nav.pages").waitFor();
}

for (const tracker of ["jira", "local", "github", "none"] as TrackerKind[]) {
  test(`rail with the ${tracker} tracker: ${RAIL(tracker).join(", ")}`, async ({ page }) => {
    await open(page, tracker);
    await expect.poll(() => page.locator("nav.pages a").allTextContents()).toEqual(RAIL(tracker));
  });
}

test("no tracker: a direct landing on Kanban shows the plain-words empty state, not an empty board", async ({ page }) => {
  await open(page, "none", "kanban");
  await expect(page.locator(".nodata")).toContainText("No tracker the UI can read is configured");
  await expect(page.locator(".rm-board")).toHaveCount(0);
});

test("github tracker: Kanban shows the issue cards read-only", async ({ page }) => {
  await open(page, "github", "kanban");
  await expect(page.locator(".rm-card", { hasText: "#21" })).toBeVisible();
  await expect(page.locator("#rm-kanban")).toContainText("read-only");
  await expect(page.locator(".rm-card[draggable]")).toHaveCount(0);
});
