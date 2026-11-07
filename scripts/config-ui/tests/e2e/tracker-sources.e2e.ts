// trackerSources() per source: the rail offers the Board (it replaced Roadmap and Kanban) only when the UI can read a tracker.
// Jira only, local only (an empty store: nothing to read), GitHub only, none (listed, so both pages can say no tracker is
// configured); a direct landing on the old Kanban route (it lands on the Board) with TRACKER=none says so in plain words.
import { test, expect, type Page } from "@playwright/test";
import { boot, type Harness, type TrackerKind } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

const RAIL = (tracker: TrackerKind) => tracker === "local"
  ? ["Shift", "Morning report", "Fleet", "Health", "Tool health", "Configure", "Workflow", "Cost", "Docs"]
  : ["Shift", "Morning report", "Fleet", "Health", "Tool health", "Configure", "Board", "Workflow", "Cost", "Docs"];

// landing: a chief page id opened straight from the landing fragment (#t=<token>&page=<id>), as a bookmark would.
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

test("TRACKER=none: a direct landing on Kanban shows the plain-words no-tracker state, not an empty board", async ({ page }) => {
  await open(page, "none", "kanban");
  await expect(page.locator(".nodata")).toContainText("No tracker is configured (TRACKER=none)");
  await expect(page.locator(".rm-board")).toHaveCount(0);
});

test("github tracker: Kanban shows the issue cards read-only", async ({ page }) => {
  await open(page, "github", "kanban");
  await expect(page.locator(".rm-card", { hasText: "#21" })).toBeVisible();
  await expect(page.locator("#rm-lanes")).toContainText("read-only"); // the Board's lanes section (was #rm-kanban)
  await expect(page.locator(".rm-card[draggable]")).toHaveCount(0);
});
