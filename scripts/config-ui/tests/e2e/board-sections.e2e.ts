// The AG-UI chief-board design's invariant I4: a section the chief writes reaches an OPEN AG-UI board with no page load.
// The real `himmelctl ui --agui` over the fleet fixture, whose chief doc sits in a bucket of its own; the test runs the real
// chief-kit board-section.mjs against that doc and watches the open page: the Chief notes card appears within 7 s of `set`,
// goes within 7 s of `rm`, and the main frame navigated once (the first load). Needs agui-web/dist
// (`cd scripts/config-ui/agui-web && bun install && bun run build`); a missing bundle FAILS here, never skips.
// E2E_SHOTS=<dir> saves board-sections-after-set.png and board-sections-after-rm.png.
import { test, expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FLEET } from "../agui-fleet-fixture";
import { aguiBuilt, bootAgui, type AguiHarness } from "./agui-fixtures";

const WRITER = join(__dirname, "../../../handover/chief-kit/board-section.mjs");
const POLL_BUDGET = 7_000; // the page polls every 5 s

let h: AguiHarness;
let root: string; // the shared fixture root: bootAgui's temp dir is made under it, so the test can find the chief doc
let tmpWas: string | undefined;
test.beforeEach(() => {
  tmpWas = process.env.TMPDIR;
  root = mkdtempSync(join(tmpdir(), "board-sections-"));
  process.env.TMPDIR = root;
});
test.afterEach(async () => {
  await h?.stop();
  if (tmpWas === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = tmpWas;
  rmSync(root, { recursive: true, force: true });
});

const chiefDoc = () => join(root, readdirSync(root).find((d) => d.startsWith("agui-e2e-"))!, "handover", "yotam", "himmel", `${FLEET.console.name}.md`);
const board = (...args: string[]) => execFileSync("node", [WRITER, "--doc", chiefDoc(), ...args], { encoding: "utf8" });

test("a section the chief writes shows on the open board within 7 s with no page load, and rm takes it off", async ({ page }) => {
  expect(aguiBuilt(), "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build").toBe(true);
  h = await bootAgui("", { fleet: true });
  let navigations = 0;
  page.on("framenavigated", (f) => { if (f === page.mainFrame()) navigations++; });
  await page.goto(h.url);
  await expect(page.locator(".bd-goalcell").first()).toBeVisible(); // the chief's board has loaded
  await expect(page.locator(".bd-notes")).toHaveCount(0); // no sections yet: the strip draws nothing
  const shot = async (name: string) => { const d = process.env.E2E_SHOTS; if (d) { mkdirSync(d, { recursive: true }); await page.screenshot({ path: join(d, `${name}.png`), fullPage: true, animations: "disabled" }); } };

  expect(board("set", "e2e-note", "--title", "E2E live note", "--tone", "warn", "--body", "written by the chief-kit command")).toContain("redacted: 0");
  const card = page.locator(".bd-note", { hasText: "E2E live note" });
  await expect(card).toBeVisible({ timeout: POLL_BUDGET });
  await expect(card.locator(".bd-note-body")).toHaveText("written by the chief-kit command");
  await expect(page.locator(".bd-notes summary")).toHaveText("Chief notes (1)");
  await shot("board-sections-after-set");

  board("rm", "e2e-note");
  await expect(card).toHaveCount(0, { timeout: POLL_BUDGET });
  await expect(page.locator(".bd-notes")).toHaveCount(0);
  await shot("board-sections-after-rm");

  console.log(`framenavigated count: ${navigations}`);
  expect(navigations).toBe(1); // the first load only: no reload carried either edit
});
