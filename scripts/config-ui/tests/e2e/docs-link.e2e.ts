// Journey J2: the UI wears the docs site's tokens and its rail links to the docs.
import { test, expect } from "@playwright/test";
import { boot, type Harness } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

async function open(page: import("@playwright/test").Page, scheme: "light" | "dark") {
  await page.emulateMedia({ colorScheme: scheme });
  h = await boot();
  await page.goto(h.url);
  await page.locator("#inventory .bhead").first().waitFor();
}
const token = (page: import("@playwright/test").Page, name: string) =>
  page.evaluate((n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim(), name);

test("J2. the rail shows Docs linking to the public site, in a new tab, with no session token", async ({ page }) => {
  await open(page, "light");
  const docs = page.locator("#pages a", { hasText: "Docs" });
  await expect(docs).toHaveCount(1);
  await expect(docs).toHaveAttribute("href", "https://yotamleo-org.github.io/Himmel/");
  await expect(docs).toHaveAttribute("target", "_blank");
  await expect(docs).toHaveAttribute("rel", /noopener/);
  expect(await page.locator("#pages a").last().innerText()).toContain("Docs");
});

test("J2. the console reads the shared tokens: light and dark values, system fonts", async ({ page }) => {
  await open(page, "light");
  expect(await token(page, "--bg")).toBe("#F3F6F8");
  expect(await token(page, "--panel")).toBe("#FFFFFF");
  expect(await token(page, "--ok")).toBe("#1B6A3E");
  await page.emulateMedia({ colorScheme: "dark" });
  expect(await token(page, "--bg")).toBe("#0C1319");
  expect(await token(page, "--ok")).toBe("#7FD1A0");
  const fonts = await page.evaluate(() => getComputedStyle(document.querySelector(".rail .brand")!).fontFamily);
  expect(fonts).not.toMatch(/Plex/i);
  expect(await page.locator(".rail .brand").innerText()).toMatch(/^Himmel/);
});
