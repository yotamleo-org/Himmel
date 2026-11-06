// Every UI page keeps one side menu and one identity header, and a Fleet chief page links back to Fleet.
// The real `himmelctl ui --agui` over the fleet fixture (both documents on one server: the config chief at / and the AG-UI
// app at /agui/). The test walks Shift, Morning report, Fleet, a Fleet chief page and Health through the rail and asserts
// the same rail entries and position, and the version line, Build details and scope line, on each; then the back control.
// Needs agui-web/dist (`cd scripts/config-ui/agui-web && bun install && bun run build`); a missing bundle FAILS here.
// E2E_SHOTS=<dir> saves shell-<page>.png for each page.
import { test, expect, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { aguiBuilt, bootAgui, type AguiHarness } from "./agui-fixtures";
import { buildFeed, HIMMEL_ID } from "./fixtures";

let h: AguiHarness;
let root: string;
let tmpWas: string | undefined;
test.beforeEach(() => {
  tmpWas = process.env.TMPDIR;
  root = mkdtempSync(join(tmpdir(), "shell-consistency-"));
  process.env.TMPDIR = root; // bootAgui's temp dir is made under it, so the test can hand the stub its feed
});
test.afterEach(async () => {
  await h?.stop();
  if (tmpWas === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = tmpWas;
  delete process.env.E2E_FEED_DELAY_MS;
  rmSync(root, { recursive: true, force: true });
});

type Shell = { pages: { page: string | null; text: string; external: boolean }[]; current: string | null; rail: Box; pagesBox: Box };
type Box = { x: number; y: number; width: number; height: number };

// The rail as the reader sees it, minus what legitimately differs between pages: the current mark, the status dots and the Shift badge.
const readShell = (page: Page): Promise<Shell> => page.evaluate(() => {
  const box = (el: Element | null): Box => { const r = el!.getBoundingClientRect(); return { x: r.x, y: r.y + scrollY, width: r.width, height: r.height }; };
  const links = [...document.querySelectorAll("aside.rail nav.pages a")];
  return {
    pages: links.map((a) => ({ page: a.getAttribute("data-page"), text: [...a.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join("").trim(), external: a.getAttribute("target") === "_blank" })),
    current: links.find((a) => a.getAttribute("aria-current") === "page")?.getAttribute("data-page") ?? null,
    rail: box(document.querySelector("aside.rail")), pagesBox: box(document.querySelector("aside.rail nav.pages")),
  };
});

test("Shift, Morning report, Fleet, a chief page and Health draw one rail and one identity header, and the chief page links back", async ({ page }) => {
  expect(aguiBuilt(), "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build").toBe(true);
  h = await bootAgui("", { fleet: true });
  const dir = join(root, readdirSync(root).find((d) => d.startsWith("agui-e2e-"))!);
  writeFileSync(join(dir, "feed.json"), JSON.stringify(buildFeed()));
  const { origin, hash } = new URL(h.url);
  const token = new URLSearchParams(hash.slice(1)).get("t")!;
  const shot = async (name: string) => { const d = process.env.E2E_SHOTS; if (d) { mkdirSync(d, { recursive: true }); await page.screenshot({ path: join(d, `shell-${name}.png`), fullPage: true, animations: "disabled" }); } };

  const seen: Record<string, Shell> = {};
  // the identity header: the version line, the Build details fold and the host · scope line
  const identity = async (name: string, current: string) => {
    await expect(page.locator("aside.rail nav.pages a[aria-current=page]"), `${name}: the rail marks ${current}`).toHaveAttribute("data-page", current);
    await expect(page.locator("aside.rail #top .ver"), `${name}: the version line`).toHaveText(`himmel ${HIMMEL_ID.version} · ${HIMMEL_ID.describe}`);
    await expect(page.locator("aside.rail #top summary"), `${name}: Build details`).toHaveText("Build details");
    await expect(page.locator("aside.rail #where"), `${name}: the scope line`).toHaveText(`${new URL(origin).host} · user scope`);
    seen[name] = await readShell(page);
    await shot(name);
  };

  await page.goto(`${origin}/#t=${token}&page=shift`);
  await identity("shift", "shift");
  await page.locator("aside.rail nav.pages a[data-page=report]").click();
  await identity("report", "report");
  await page.locator("aside.rail nav.pages a[data-page=fleet]").click(); // the AG-UI app: a different document
  await expect(page.locator("main.fleet")).toBeVisible();
  await identity("fleet", "fleet");
  await page.locator("a.chief-page").first().click();
  await expect(page).toHaveURL(/console=/);
  const back = page.getByRole("link", { name: /back to fleet/i });
  await expect(back, "a chief page has a back control").toBeVisible();
  await identity("chief", "fleet");
  await back.click();
  await expect(page).not.toHaveURL(/console=/);
  await expect(page.locator("main.fleet")).toBeVisible();
  await page.goBack(); // the browser's Back from the Fleet main view returns to the chief page the click left, and Forward again does the reverse
  await expect(page).toHaveURL(/console=/);
  await page.goBack();
  await expect(page).not.toHaveURL(/console=/);
  await page.goForward();
  await expect(page).toHaveURL(/console=/);

  await page.locator("aside.rail nav.pages a[data-page=health]").click();
  await identity("health", "health");

  const first = seen.shift;
  for (const name of ["report", "fleet", "chief", "health"]) {
    const s = seen[name];
    expect(s.pages, `${name}: the rail entries`).toEqual(first.pages);
    expect(s.rail, `${name}: the rail box`).toEqual(first.rail);
    expect(s.pagesBox, `${name}: the page list position`).toEqual(first.pagesBox);
  }
});

// The AG-UI page reads the shared report cache (GET /api/feed): it never draws a rail-less or header-less page when that read fails or has no identity.
const aguiOnly = async (feed: object | null) => {
  h = await bootAgui("", { fleet: true });
  const dir = join(root, readdirSync(root).find((d) => d.startsWith("agui-e2e-"))!);
  if (feed) writeFileSync(join(dir, "feed.json"), JSON.stringify(feed));
  else rmSync(join(dir, "feed.json")); // none: the stub's report fails, the feed answers 502
  return h.url;
};
const RAIL = ["shift", "report", "fleet", "health", "docs"];

test("a failed report still draws the AG-UI rail and an identity header with no data", async ({ page }) => {
  expect(aguiBuilt(), "agui-web/dist is not built").toBe(true);
  process.env.E2E_FEED_DELAY_MS = "1500"; // the boot-time report reads its file at the end of the delay: after aguiOnly removed it
  let feedAsks = 0;
  page.on("request", (r) => { if (new URL(r.url()).pathname === "/api/feed") feedAsks++; });
  await page.goto(await aguiOnly(null));
  await expect(page.locator("aside.rail #top .ver")).toHaveText("version unknown (feed has no himmel identity)", { timeout: 20_000 });
  await expect(page.locator("aside.rail #where")).toHaveText(`${new URL(h.url).host} · ? scope`);
  expect((await readShell(page)).pages.map((p) => p.page)).toEqual(expect.arrayContaining(RAIL));
  const asks = feedAsks;
  await page.waitForTimeout(3_000);
  expect(feedAsks, "the page stops asking once the report failed").toBe(asks);
});

test("a report with no himmel identity still draws the AG-UI rail, the unknown-version header and the scope line", async ({ page }) => {
  expect(aguiBuilt(), "agui-web/dist is not built").toBe(true);
  await page.goto(await aguiOnly(buildFeed({ noIdentity: true })));
  await expect(page.locator("aside.rail #top .ver")).toHaveText("version unknown (feed has no himmel identity)");
  await expect(page.locator("aside.rail #where")).toHaveText(`${new URL(h.url).host} · user scope`);
  expect((await readShell(page)).pages.map((p) => p.page)).toEqual(expect.arrayContaining(RAIL));
});

// ps lines of a running stub report: one per probe in flight.
const probes = () => execFileSync("ps", ["-eo", "args"], { encoding: "utf8" }).split("\n").filter((l) => /^node\b.*e2e-stub\.js report\b/.test(l)).length;

test("the config chief and the AG-UI page opened together share one report probe, and a reload inside the cache starts none", async ({ page, context }) => {
  expect(aguiBuilt(), "agui-web/dist is not built").toBe(true);
  process.env.E2E_FEED_DELAY_MS = "3000"; // a held report, so overlapping probes would be seen
  const agui = await aguiOnly(buildFeed());
  const { origin, hash } = new URL(agui);
  const token = new URLSearchParams(hash.slice(1)).get("t")!;
  const ver = `himmel ${HIMMEL_ID.version} · ${HIMMEL_ID.describe}`;
  let peak = 0;
  const sampler = setInterval(() => { peak = Math.max(peak, probes()); }, 100);
  try {
    const other = await context.newPage();
    await Promise.all([page.goto(`${origin}/#t=${token}&page=shift`), other.goto(agui)]);
    await expect(other.locator("aside.rail #top .ver")).toHaveText(ver, { timeout: 20_000 });
    await expect(page.locator("aside.rail #top .ver")).toHaveText(ver, { timeout: 20_000 });
    expect(peak, "the held report was seen running, once").toBe(1);
    peak = 0;
    await other.reload(); // the report is cached for 30 s: no new probe
    await expect(other.locator("aside.rail #top .ver")).toHaveText(ver);
    await other.waitForTimeout(1_500);
    expect(peak, "a reload inside the cache starts no probe").toBe(0);
  } finally { clearInterval(sampler); }
});
