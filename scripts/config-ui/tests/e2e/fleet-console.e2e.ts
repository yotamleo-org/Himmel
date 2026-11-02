// The Fleet page loads with no console error, at desktop and phone width, in both themes.
// The server sends default-src 'self'; a browser refusal shows up as a console error and as a securitypolicyviolation event.
// Needs agui-web/dist (`cd scripts/config-ui/agui-web && bun install && bun run build`); skipped, loudly, when absent.
import { test, expect } from "@playwright/test";
import { aguiBuilt, bootAgui, type AguiHarness } from "./agui-fixtures";

let h: AguiHarness;
test.skip(!aguiBuilt(), "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build");
test.afterEach(async () => { await h?.stop(); });

for (const scheme of ["dark", "light"] as const) {
  for (const width of [1280, 390]) {
    test(`the Fleet page logs no console error in ${scheme} at ${width}px`, async ({ page }) => {
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
