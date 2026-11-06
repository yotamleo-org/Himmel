// The Fleet page loads with no console error, at desktop and phone width, in both themes.
// The server sends default-src 'self'; a browser refusal shows up as a console error and as a securitypolicyviolation event.
// Needs agui-web/dist (`cd scripts/config-ui/agui-web && bun install && bun run build`); skipped, loudly, when absent.
import { test, expect } from "@playwright/test";
import { aguiBuilt, bootAgui, type AguiHarness } from "./agui-fixtures";

let h: AguiHarness;
const noDist = !aguiBuilt(); // the Fleet tests need the bundle; the Health page bar test is the console's and does not
const NO_DIST = "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build";
test.afterEach(async () => { await h?.stop(); });

for (const scheme of ["dark", "light"] as const) {
  for (const width of [1280, 390]) {
    test(`the Fleet page logs no console error in ${scheme} at ${width}px`, async ({ page }) => {
      test.skip(noDist, NO_DIST);
      const logged: string[] = [];
      page.on("console", (m) => { if (m.type() === "error") logged.push(`${m.text()} @ ${m.location().url}:${m.location().lineNumber}`); });
      page.on("pageerror", (e) => logged.push(`pageerror: ${e.message}`));
      await page.addInitScript(() => {
        const w = window as unknown as { __csp: string[] };
        w.__csp = [];
        document.addEventListener("securitypolicyviolation", (e) => w.__csp.push(`${e.violatedDirective} ${e.blockedURI} ${e.sourceFile}:${e.lineNumber} ${e.sample}`));
      });
      await page.setViewportSize({ width, height: 800 });
      await page.emulateMedia({ colorScheme: scheme });
      h = await bootAgui("", { fleet: true });
      await page.goto(h.url);
      await expect(page.locator(".fleet-row").first()).toBeVisible();
      await page.waitForTimeout(1000); // the first poll and its render have landed
      expect(await page.evaluate(() => (window as unknown as { __csp: string[] }).__csp)).toEqual([]);
      expect(logged).toEqual([]);
    });
  }
}

// The AG-UI rail is the console rail (links only); the filters are a bar in the page and the chiefs are group headers.
const RAIL_STRAYS = "input, [role=group][aria-label=Filters], nav[aria-label='Supervisor sessions'], details:not(#top *)"; // the identity header's Build details fold is the one details the rail has
test("the AG-UI rail holds no filter input and no session tree; the page holds the filter bar and no supervisor sessions nav", async ({ page }) => {
  test.skip(noDist, NO_DIST);
  h = await bootAgui("", { fleet: true });
  await page.goto(h.url);
  await expect(page.locator(".fleet-row").first()).toBeVisible();
  const rail = page.locator("aside.rail");
  await expect(rail.locator("nav.pages a")).not.toHaveCount(0);
  await expect(rail.locator(RAIL_STRAYS)).toHaveCount(0);
  await expect(page.getByRole("navigation", { name: "Supervisor sessions" })).toHaveCount(0);
  await expect(page.locator("main.fleet").getByRole("group", { name: "Filters" }).locator("input[type=search]")).toBeVisible();
});

// The check above still bites: a details fold in the rail body is caught; the identity header's own fold is not.
test("a stray details element in the rail body fails the rail check, the header's Build details fold does not", async ({ page }) => {
  test.skip(noDist, NO_DIST);
  h = await bootAgui("", { fleet: true });
  await page.goto(h.url);
  const rail = page.locator("aside.rail");
  await expect(rail.locator("#top details")).toHaveCount(1);
  await expect(rail.locator(RAIL_STRAYS)).toHaveCount(0);
  await page.evaluate(() => document.querySelector("aside.rail nav.pages")!.insertAdjacentHTML("afterend", "<details><summary>stray</summary></details>"));
  await expect(rail.locator(RAIL_STRAYS)).toHaveCount(1);
});

test("a live chief's group header counts its running and waiting-for-GO sessions and links its page; Other sessions shows none", async ({ page }) => {
  test.skip(noDist, NO_DIST);
  h = await bootAgui("", { fleet: true });
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    for (const r of body.sessions) if (r.role === "worker" && r.live !== false && r.state !== "wrapped") r.state = "waiting for GO";
    await route.fulfill({ response, json: body });
  });
  await page.goto(h.url);
  const group = page.locator(".fleet-chief:not([aria-label='Other sessions'])").first();
  await expect(group.locator(".fleet-chief-counts")).toHaveText(/\b1 running\b.*\b1 waiting for GO\b/);
  const link = group.locator("a.chief-page");
  await expect(link).toHaveCount(1);
  await expect(link).not.toHaveAttribute("aria-current", "page");
  await expect(group).toHaveJSProperty("open", true);
  const other = page.locator(".fleet-chief[aria-label='Other sessions']");
  await expect(other).toHaveCount(1);
  await expect(other.locator(".fleet-chief-counts, a.chief-page")).toHaveCount(0);
  await link.click();
  await expect(group.locator("a.chief-page")).toHaveAttribute("aria-current", "page");
  await expect(group).toHaveJSProperty("open", true); // the link follows; it never toggles the group
});

// One rail, two documents: the AG-UI Fleet page and the console's Board page list the same page ids.
test("the AG-UI Fleet rail lists the same page ids as the console rail on Board", async ({ page }) => {
  test.skip(noDist, NO_DIST);
  h = await bootAgui("", { fleet: true });
  const { origin, hash } = new URL(h.url);
  const ids = (p: typeof page) => p.locator("nav.pages a[data-page]").evaluateAll((as) => as.map((a) => a.getAttribute("data-page")).join());
  const fleetPage = await page.context().newPage();
  const settled = Promise.all([page.waitForResponse("**/api/sources"), fleetPage.waitForResponse("**/api/sources")]);
  await page.goto(`${origin}/${hash}&page=board`);
  await fleetPage.goto(h.url);
  await settled;
  await expect(page.locator("nav.pages a[data-page]").first()).toBeVisible();
  await expect(fleetPage.locator("nav.pages a[data-page]").first()).toBeVisible();
  const consoleIds = await ids(page);
  expect(consoleIds).toContain("fleet");
  await expect.poll(() => ids(fleetPage)).toBe(consoleIds);
});

// The console's Health page keeps its project picker in the page bar, never the rail; at 760 px the bar folds to "Filters (n on)".
test("the Health page bar folds to Filters (n on) at 760px and the rail holds no picker", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  const { origin, hash } = new URL(h.url); // /agui/#t=<token>: the console is the same server's /, the token in the same fragment
  await page.setViewportSize({ width: 760, height: 800 });
  await page.goto(`${origin}/${hash}&page=health`);
  const fold = page.locator("#pagebar .pb-fold");
  await expect(fold).toHaveText(/^Filters \(\d+ on\)$/);
  await expect(page.locator("#proj")).toBeHidden();
  await fold.click();
  await expect(page.locator("#proj")).toBeVisible();
  await expect(page.locator("nav.pages #proj")).toHaveCount(0);
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(fold).toBeHidden();
  await expect(page.locator("#proj")).toBeVisible();
});
