// Journeys J5 and J7: the Setup page. A secret typed into it reaches the store and nowhere else, and the commit rules
// change only after a dry-run is confirmed.
import { test, expect, type Page } from "@playwright/test";
import { randomBytes, randomInt } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { boot, type Harness } from "./fixtures";

// a trace records fill() arguments and a screenshot or video records the field: none of them for this page.
test.use({ screenshot: "off", trace: "off", video: "off" });

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

// shaped like the telegram rule asks, built at run time so no token-shaped literal is in the repo.
const canary = () => `${randomInt(100_000_000, 999_999_999)}:${randomBytes(27).toString("base64url").slice(0, 35)}`;
const NAME = "TELEGRAM_BOT_TOKEN";

async function open(page: Page, conf?: string) {
  h = await boot();
  if (conf !== undefined) { mkdirSync(join(h.home, ".himmel"), { recursive: true }); writeFileSync(join(h.home, ".himmel", "himmel.conf"), conf); }
  await page.goto(h.url);
  await page.locator('nav.pages a:has-text("Setup")').click();
  await page.locator("#main h2:has-text('Setup')").waitFor();
}

const store = (): string => join(h.home, ".claude", "channels", "telegram", ".env");
const audit = (): string => { const f = join(h.home, ".himmel", "state", "config-ui", "actions.jsonl"); return existsSync(f) ? readFileSync(f, "utf8") : ""; };

// every place the value could be left: the page markup and fields, the browser's stores, the audit log, the stub's argv.
async function leaks(page: Page, secret: string): Promise<string[]> {
  const found: string[] = [];
  const dom = await page.evaluate(() => ({
    html: document.documentElement.outerHTML,
    fields: [...document.querySelectorAll("input,textarea")].map((i) => (i as HTMLInputElement).value),
    local: JSON.stringify({ ...localStorage }), session: JSON.stringify({ ...sessionStorage }), cookie: document.cookie,
  }));
  if (dom.html.includes(secret)) found.push("markup");
  if (dom.fields.some((v) => v.includes(secret))) found.push("a field");
  if (dom.local.includes(secret)) found.push("localStorage");
  if (dom.session.includes(secret)) found.push("sessionStorage");
  if (dom.cookie.includes(secret)) found.push("cookie");
  if (audit().includes(secret)) found.push("audit log");
  if (h.argv().some((l) => l.includes(secret))) found.push("argv");
  return found;
}

test("J5. Setup sits after Settings in the rail and recommends the terminal", async ({ page }) => {
  await open(page);
  const rail = await page.locator("nav.pages a").allTextContents();
  expect(rail.indexOf("Setup")).toBe(rail.indexOf("Settings") + 1);
  await expect(page.locator("#main")).toContainText("Typing a secret in the terminal");
  const field = page.locator(`input[data-secret="${NAME}"]`);
  await expect(field).toHaveAttribute("type", "password");
  await expect(field).toHaveAttribute("autocomplete", "off");
});

test("J5. a saved secret is set in the store and its value is nowhere else", async ({ page }) => {
  await open(page);
  const secret = canary();
  const row = page.locator(".srow", { has: page.locator(`input[data-secret="${NAME}"]`) });
  await expect(row).toContainText("not set");
  await row.locator("input").fill(secret);
  await row.locator('button[type="submit"]').click();
  await expect(row).toContainText("saved");
  await expect(row.locator(".st")).toHaveText("set");
  await expect(row.locator("input")).toHaveValue("");
  expect(readFileSync(store(), "utf8")).toContain(`${NAME}=${secret}`);
  expect(statSync(store()).mode & 0o777).toBe(0o600);
  expect(await leaks(page, secret)).toEqual([]);
  // a fresh load (the token rides the URL fragment, so a plain reload would lose it) reads presence from the server and still holds no value
  await page.goto(h.url);
  await page.locator('nav.pages a:has-text("Setup")').click();
  await expect(row.locator(".st")).toHaveText("set");
  expect(await leaks(page, secret)).toEqual([]);
});

// the control for the scan above: a value left in any place the scan looks must be named.
test("J5. the leak scan names every place a value is left", async ({ page }) => {
  await open(page);
  const secret = canary();
  await page.evaluate((v) => {
    localStorage.setItem("x", v); sessionStorage.setItem("x", v); document.cookie = `x=${v}`; document.body.append(v);
    (document.querySelector("input") as HTMLInputElement).value = v;
  }, secret);
  const mark = join(h.home, ".himmel", "state", "config-ui");
  mkdirSync(mark, { recursive: true });
  writeFileSync(join(mark, "actions.jsonl"), `${secret}\n`);
  writeFileSync(h.argvFile, `${secret}\n`);
  expect((await leaks(page, secret)).sort()).toEqual(["a field", "argv", "audit log", "cookie", "localStorage", "markup", "sessionStorage"]);
});

// the field is emptied before the request is sent, so a slow or stalled request never leaves the value in the page.
test("J5. the field is empty while the save is still in flight", async ({ page }) => {
  await open(page);
  const secret = canary();
  let release: () => void = () => {};
  const held = new Promise<void>((r) => { release = r; });
  await page.route("**/api/setup/secret", async (route) => { await held; await route.continue(); });
  const row = page.locator(".srow", { has: page.locator(`input[data-secret="${NAME}"]`) });
  await row.locator("input").fill(secret);
  await row.locator('button[type="submit"]').click();
  await expect(row.locator("input")).toHaveValue("");
  expect(await leaks(page, secret)).toEqual([]);
  release();
  await expect(row.locator(".st")).toHaveText("set");
});

// the remove button sits inside the save form: it must remove and nothing else, even with text typed in the field.
test("J5. remove with text in the field removes and does not save", async ({ page }) => {
  await open(page);
  const row = page.locator(".srow", { has: page.locator(`input[data-secret="${NAME}"]`) });
  await row.locator("input").fill(canary());
  await row.locator('button[type="submit"]').click();
  await expect(row.locator(".st")).toHaveText("set");
  await row.locator("input").fill(canary());
  await row.locator('button[data-act="setup-remove"]').click();
  await expect(row).toContainText("removed");
  await expect(row.locator(".st")).toHaveText("not set");
  expect(readFileSync(store(), "utf8")).not.toContain(NAME);
});

test("J5. a refused value shows the reason, writes nothing and is not echoed", async ({ page }) => {
  await open(page);
  const bad = `not-a-bot-token-${randomBytes(6).toString("hex")}`;
  const row = page.locator(".srow", { has: page.locator(`input[data-secret="${NAME}"]`) });
  await row.locator("input").fill(bad);
  await row.locator('button[type="submit"]').click();
  await expect(row).toContainText('value failed rule "telegram-token"');
  await expect(row.locator("input")).toHaveValue("");
  expect(existsSync(store())).toBe(false);
  expect(await leaks(page, bad)).toEqual([]);
});

test("J5. remove drops the secret and the row reads not set", async ({ page }) => {
  await open(page);
  const secret = canary();
  const row = page.locator(".srow", { has: page.locator(`input[data-secret="${NAME}"]`) });
  await row.locator("input").fill(secret);
  await row.locator('button[type="submit"]').click();
  await expect(row.locator(".st")).toHaveText("set");
  await row.locator('button[data-act="setup-remove"]').click();
  await expect(row).toContainText("removed");
  await expect(row.locator(".st")).toHaveText("not set");
  expect(readFileSync(store(), "utf8")).not.toContain(secret);
  expect(await leaks(page, secret)).toEqual([]);
});

test("J7. a commit-rules change shows its dry-run first and only confirm runs it", async ({ page }) => {
  await open(page, "TRACKER=jira\nTICKET_ID_REQUIRED=1\n");
  await page.locator('button[data-act="plan"][data-target="tracker"][data-value="local"]').click();
  const plan = page.locator("#main .plan");
  await expect(plan).toContainText("dry-run · nothing has changed");
  await expect(plan).toContainText("config set commit.tracker local --dry-run");
  expect(h.argv().every((l) => l.endsWith("--dry-run")), h.argv().join("\n")).toBe(true);
  await plan.locator('button[data-act="run"]').click();
  await expect(page.locator("#main .plan")).toContainText("rc=0");
  expect(h.argv().at(-1)).toBe("himmelctl config set commit.tracker local");
});

test("J7. cancel runs nothing, and ticket-ID required is off-limits while the tracker is none", async ({ page }) => {
  await open(page, "TRACKER=none\n");
  await expect(page.locator('button[data-target="ticket-id-required"]').first()).toBeDisabled();
  await page.locator('button[data-act="plan"][data-target="tracker"][data-value="jira"]').click();
  await page.locator('#main .plan button[data-act="close"]').click();
  await expect(page.locator("#main .plan")).toHaveCount(0);
  expect(h.argv().every((l) => l.endsWith("--dry-run")), h.argv().join("\n")).toBe(true);
});
