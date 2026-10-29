// Journeys J5, J7 and J8: the Setup page. A secret typed into it reaches the store and nowhere else, and the commit
// rules and setup paths change only after a dry-run is confirmed.
import { test, expect, type Page } from "@playwright/test";
import { randomBytes, randomInt } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { boot, type Harness } from "./fixtures";
import { stubKeyring } from "../keyring-stub";

// a trace records fill() arguments and a screenshot or video records the field: none of them for this page.
test.use({ screenshot: "off", trace: "off", video: "off" });

// The UI login lives in the OS keyring. boot() hands this worker's env to the real server, so a stub secret-tool goes on this
// env first: the page creates its login in the stub, never in the operator's keyring.
let h: Harness;
let k: ReturnType<typeof stubKeyring>;
let kdir = "";
const savedEnv: Record<string, string | undefined> = {};
test.afterEach(async () => {
  await h?.stop();
  for (const [n, v] of Object.entries(savedEnv)) { if (v === undefined) delete process.env[n]; else process.env[n] = v; }
  if (kdir) rmSync(kdir, { recursive: true, force: true });
});

// shaped like the telegram rule asks, built at run time so no token-shaped literal is in the repo.
const canary = () => `${randomInt(100_000_000, 999_999_999)}:${randomBytes(27).toString("base64url").slice(0, 35)}`;
const NAME = "TELEGRAM_BOT_TOKEN";

async function open(page: Page, conf?: string, tile = "secrets") {
  kdir = mkdtempSync(join(tmpdir(), "setup-e2e-keyring-"));
  k = stubKeyring(kdir);
  for (const [n, v] of Object.entries(k.env)) { savedEnv[n] = process.env[n]; process.env[n] = v; }
  h = await boot();
  if (conf !== undefined) { mkdirSync(join(h.home, ".himmel"), { recursive: true }); writeFileSync(join(h.home, ".himmel", "himmel.conf"), conf); }
  await page.goto(`${h.url}&page=setup`); // the himmelctl install hand-off link: lands on Configure with the Secrets tile open
  await page.locator("#h-configure").waitFor();
  if (tile !== "secrets") await page.locator(`button.tile[data-tile="${tile}"]`).click();
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

test("J5. the page=setup hand-off lands on Configure with the Secrets tile open, and recommends the terminal", async ({ page }) => {
  await open(page);
  const rail = await page.locator("nav.pages a").allTextContents();
  expect(rail).toContain("Configure");
  expect(rail).not.toContain("Setup");
  await expect(page.locator('button.tile[data-tile="secrets"]')).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator("#tile-secrets")).not.toContainText("0600");
  await expect(page.locator("#main")).toContainText("A secret you save here goes to this machine over a loopback connection");
  const field = page.locator(`input[data-secret="${NAME}"]`);
  await expect(field).toHaveAttribute("type", "password");
  await expect(field).toHaveAttribute("autocomplete", "new-password");
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
  await page.goto("about:blank"); // a hash-only goto from the loaded page is a same-document move that skips the landing
  await page.goto(`${h.url}&page=setup`);
  await page.locator("#h-configure").waitFor();
  await expect(row.locator(".st")).toHaveText("set");
  expect(await leaks(page, secret)).toEqual([]);
});

// the control for the scan above: a value left in any place the scan looks must be named.
test("J5. the leak scan names every place a value is left", async ({ page }) => {
  await open(page);
  await page.locator(`input[data-secret="${NAME}"]`).waitFor();
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

const loginFile = (): string => join(h.home, ".himmel", "state", "ui-login");

// the fields are emptied before the request is sent, and the password is in no place the scan looks, during or after.
test("J5. a created login empties the password fields and leaves the password nowhere", async ({ page }) => {
  await open(page);
  const pw = `pw-${randomBytes(12).toString("hex")}`;
  let release: () => void = () => {};
  const held = new Promise<void>((r) => { release = r; });
  await page.route("**/api/setup/account", async (route) => { await held; await route.continue(); });
  const form = page.locator("form[data-account-form]");
  await form.locator('[data-account="user"]').fill("op");
  await form.locator('[data-account="password"]').fill(pw);
  await form.locator('[data-account="confirm"]').fill(pw);
  await form.locator('button[type="submit"]').click();
  await expect(form.locator('[data-account="password"]')).toHaveValue("");
  await expect(form.locator('[data-account="confirm"]')).toHaveValue("");
  expect(await leaks(page, pw)).toEqual([]);
  release();
  await expect(page.locator("#main")).toContainText("The UI login is set for op");
  await expect(page.locator("form[data-account-form]")).toHaveCount(0);
  expect(existsSync(loginFile())).toBe(false);
  expect(k.get("HIMMEL_UI_LOGIN")).not.toBeNull();
  expect(k.get("HIMMEL_UI_LOGIN")).not.toContain(pw);
  expect(await leaks(page, pw)).toEqual([]);
});

test("J5. two different passwords send nothing and leave neither in the page", async ({ page }) => {
  await open(page);
  const a = `pw-${randomBytes(12).toString("hex")}`, b = `pw-${randomBytes(12).toString("hex")}`;
  let sent = 0;
  await page.route("**/api/setup/account", async (route) => { sent++; await route.continue(); });
  const form = page.locator("form[data-account-form]");
  await form.locator('[data-account="user"]').fill("op");
  await form.locator('[data-account="password"]').fill(a);
  await form.locator('[data-account="confirm"]').fill(b);
  await form.locator('button[type="submit"]').click();
  await expect(page.locator("#main")).toContainText("the two passwords differ");
  await expect(page.locator('[data-account="password"]')).toHaveValue("");
  await expect(page.locator('[data-account="confirm"]')).toHaveValue("");
  expect(sent).toBe(0);
  expect(existsSync(loginFile())).toBe(false);
  expect(k.get("HIMMEL_UI_LOGIN")).toBeNull();
  expect(await leaks(page, a)).toEqual([]);
  expect(await leaks(page, b)).toEqual([]);
});

test("J7. a commit-rules change shows its dry-run first and only confirm runs it", async ({ page }) => {
  await open(page, "TRACKER=jira\nTICKET_ID_REQUIRED=1\n", "tracker");
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
  await open(page, "TRACKER=none\n", "tracker");
  await expect(page.locator('button[data-target="ticket-id-required"]').first()).toBeDisabled();
  // the rule reads off while the tracker is none, so "off" is the pressed choice
  await expect(page.locator('button[data-target="ticket-id-required"][data-value="off"]')).toHaveAttribute("aria-pressed", "true");
  await expect(page.locator('button[data-target="ticket-id-required"][data-value="on"]')).toHaveAttribute("aria-pressed", "false");
  await page.locator('button[data-act="plan"][data-target="tracker"][data-value="jira"]').click();
  await page.locator('#main .plan button[data-act="close"]').click();
  await expect(page.locator("#main .plan")).toHaveCount(0);
  expect(h.argv().every((l) => l.endsWith("--dry-run")), h.argv().join("\n")).toBe(true);
});

test("J8. a handover-root change shows its dry-run first and only confirm runs it", async ({ page }) => {
  await open(page, undefined, "scope");
  await page.locator('input[data-path="handover-root"]').fill("/srv/state/handovers");
  await page.locator('[data-path-form][data-target="handover-root"] button[type="submit"]').click();
  const plan = page.locator("#main .plan");
  await expect(plan).toContainText("config set handover.root /srv/state/handovers --dry-run");
  expect(h.argv().every((l) => l.endsWith("--dry-run")), h.argv().join("\n")).toBe(true);
  await plan.locator('button[data-act="run"]').click();
  await expect(page.locator("#main .plan")).toContainText("rc=0");
  expect(h.argv().at(-1)).toBe("himmelctl config set handover.root /srv/state/handovers");
});

test("J8. a refused path shows the reason and runs nothing", async ({ page }) => {
  await open(page, undefined, "scope");
  await page.locator('input[data-path="luna-vault"]').fill("../vault");
  await page.locator('[data-path-form][data-target="luna-vault"] button[type="submit"]').click();
  await expect(page.locator("#main .plan")).toContainText("absolute path");
  expect(h.argv()).toEqual([]);
});
