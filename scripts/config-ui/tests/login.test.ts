// The UI login: POST /api/login checks the operator's password against the scrypt hash in the OS keyring (key HIMMEL_UI_LOGIN,
// through scripts/lib/himmel-secrets; a stub secret-tool here, never the real keyring) and answers with an HttpOnly,
// SameSite=Strict session cookie; /api/* takes that cookie or the launch token. A pre-keyring ~/.himmel/state/ui-login is a
// one-shot fallback that moves into the keyring. The password is made at run time and must never reach a response, the audit
// line, the keyring item or a file.
import { test, expect, afterEach } from "bun:test";
import { randomBytes, scryptSync } from "node:crypto";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { startServer } from "../server";
import { readLogin, writeLogin } from "../login";
import { stubKeyring } from "./keyring-stub";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const USER = "operator";
const KEY = "HIMMEL_UI_LOGIN";
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const secret = () => "pw-" + randomBytes(12).toString("hex");

// what the keyring item and a pre-keyring file hold: one JSON line, a scrypt hash and never the password.
function loginLine(user: string, password: string): string {
  const salt = randomBytes(16).toString("hex");
  return JSON.stringify({ user, salt, hash: scryptSync(password, salt, 64).toString("hex") });
}
function writeLegacy(path: string, line: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, line + "\n", { mode: 0o600 });
  chmodSync(path, 0o600);
}

// legacy: the login sits in the pre-keyring file instead of the keyring; locked: the stub keyring is locked;
// envLogin: the process env carries its own HIMMEL_UI_LOGIN; extra: more stub knobs (KSTUB_*) for the server's env.
function boot(o: { password?: string | null; noIdle?: boolean; legacy?: boolean; locked?: boolean; envLogin?: string; extra?: Record<string, string> } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project");
  for (const d of [home, root, project]) mkdirSync(d);
  const password = o.password === undefined ? secret() : o.password;
  const loginFile = join(home, ".himmel", "state", "ui-login");
  const k = stubKeyring(dir);
  if (password !== null) { if (o.legacy) writeLegacy(loginFile, loginLine(USER, password)); else k.put(KEY, loginLine(USER, password)); }
  let t = 1_000_000;
  const env: Record<string, string | undefined> = { ...k.env, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home };
  if (o.locked) env.KSTUB_LOCKED = "true";
  if (o.envLogin !== undefined) env[KEY] = o.envLogin;
  Object.assign(env, o.extra);
  const s =startServer({ port: 0, token: TOKEN, root, projectRoot: project, noIdle: o.noIdle, now: () => t, env });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${s.port}`;
  const post = (path: string, body: unknown, headers: Record<string, string> = {}) => fetch(base + path, {
    method: "POST", headers: { "content-type": "application/json", origin: base, ...headers }, body: JSON.stringify(body),
  });
  const login = (user: string, pw: string) => post("/api/login", { user, password: pw });
  const feed = (headers: Record<string, string> = {}) => fetch(base + "/api/feed", { headers });
  const audit = () => { const f = join(home, ".himmel", "state", "config-ui", "actions.jsonl"); return existsSync(f) ? readFileSync(f, "utf8") : ""; };
  return { s, base, home, project, loginFile, k, env, password: password ?? "", post, login, feed, audit, advance: (ms: number) => { t += ms; } };
}

const cookieOf = (r: Response) => (r.headers.get("set-cookie") ?? "").split(";")[0];

test("without a session or the token /api/ is 401, and a made-up cookie does not count", async () => {
  const b = boot();
  expect((await b.feed()).status).toBe(401);
  expect((await b.feed({ cookie: "himmel_session=" + "a".repeat(64) })).status).toBe(401);
});

test("the right password answers with an HttpOnly, SameSite=Strict, short-lived cookie that opens /api/", async () => {
  const b = boot();
  const r = await b.login(USER, b.password);
  expect(r.status).toBe(200);
  const set = r.headers.get("set-cookie") ?? "";
  expect(set).toMatch(/^himmel_session=[0-9a-f]{64};/);
  expect(set).toContain("HttpOnly");
  expect(set).toContain("SameSite=Strict");
  expect(set).toContain("Path=/");
  const age = Number(/Max-Age=(\d+)/.exec(set)?.[1]);
  expect(age).toBeGreaterThan(0);
  expect(age).toBeLessThanOrEqual(3600);
  expect(await r.text()).not.toContain(b.password);
  expect((await b.feed({ cookie: cookieOf(r) })).status).toBe(200);
});

test("the launch token still opens /api/ next to the login", async () => {
  const b = boot();
  expect((await b.feed({ "x-himmel-token": TOKEN })).status).toBe(200);
});

test("a wrong password or user is 401 and sets no cookie", async () => {
  const b = boot();
  for (const [u, p] of [[USER, secret()], ["someone", b.password], ["", ""]]) {
    const r = await b.login(u, p);
    expect(r.status).toBe(401);
    expect(r.headers.get("set-cookie")).toBeNull();
  }
});

test("after five failures the login is rate-limited with Retry-After, even for the right password, until the window passes", async () => {
  const b = boot();
  for (let i = 0; i < 5; i++) expect((await b.login(USER, secret())).status).toBe(401);
  const r = await b.login(USER, b.password);
  expect(r.status).toBe(429);
  expect(Number(r.headers.get("retry-after"))).toBeGreaterThan(0);
  expect(r.headers.get("set-cookie")).toBeNull();
  b.advance(15 * 60 * 1000 + 1);
  expect((await b.login(USER, b.password)).status).toBe(200);
});

test("logout ends the session and clears the cookie", async () => {
  const b = boot();
  const c = cookieOf(await b.login(USER, b.password));
  const out = await b.post("/api/logout", {}, { cookie: c });
  expect(out.status).toBe(200);
  expect(out.headers.get("set-cookie") ?? "").toContain("Max-Age=0");
  expect((await b.feed({ cookie: c })).status).toBe(401);
});

test("a logout that is not JSON is 415 and leaves the session alive", async () => {
  const b = boot();
  const c = cookieOf(await b.login(USER, b.password));
  const out = await b.post("/api/logout", {}, { cookie: c, "content-type": "text/plain" });
  expect(out.status).toBe(415);
  expect(out.headers.get("set-cookie")).toBeNull();
  expect((await b.feed({ cookie: c })).status).toBe(200);
});

test("a session expires after its TTL", async () => {
  const b = boot();
  const c = cookieOf(await b.login(USER, b.password));
  b.advance(60 * 60 * 1000 + 1);
  expect((await b.feed({ cookie: c })).status).toBe(401);
});

test("setting the login again ends the sessions opened under the old one", async () => {
  const b = boot();
  const c = cookieOf(await b.login(USER, b.password));
  writeLogin(b.loginFile, USER, secret(), { env: b.env });
  expect((await b.feed({ cookie: c })).status).toBe(401);
});

test("a login from a foreign origin is refused before the password is checked", async () => {
  const b = boot();
  expect((await b.post("/api/login", { user: USER, password: b.password }, { origin: "http://evil.test" })).status).toBe(403);
});

test("with no login set the login answers 404 and says how to set one", async () => {
  const b = boot({ password: null });
  const r = await b.login(USER, "anything");
  expect(r.status).toBe(404);
  expect(await r.text()).toContain(`bun ${join(import.meta.dir, "..", "server.ts")} --set-login`);
});

test("in service mode a logged-in session may save a secret, the launch token alone may not", async () => {
  const b = boot({ noIdle: true });
  const value = "e2e-canary-" + randomBytes(12).toString("hex");
  const body = { name: "JIRA_API_TOKEN", value, op: "set" };
  const byToken = await b.post("/api/setup/secret", body, { "x-himmel-token": TOKEN });
  expect(byToken.status).toBe(403);
  const c = cookieOf(await b.login(USER, b.password));
  const bySession = await b.post("/api/setup/secret", body, { cookie: c });
  expect(bySession.status).toBe(200);
  expect(await bySession.text()).not.toContain(value);
  expect(b.audit()).not.toContain(value);
  expect(b.audit()).not.toContain(b.password);
});

test("the login hash is stored in the keyring, never the password, and no login file is written", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-vault-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir), f = join(dir, "state", "ui-login"), pw = secret();
  writeLogin(f, USER, pw, { env: k.env });
  const item = k.get(KEY);
  expect(item).not.toBeNull();
  expect(item).not.toContain(pw);
  expect(JSON.parse(item!)).toMatchObject({ user: USER, salt: expect.stringMatching(/^[0-9a-f]+$/), hash: expect.stringMatching(/^[0-9a-f]{128}$/) });
  expect(existsSync(f)).toBe(false);
  expect(readLogin(f, k.env)?.user).toBe(USER);
});

test("with the hash only in the keyring, no session is 401, a wrong password is 401 and then rate-limited, the right one logs in", async () => {
  const b = boot();
  expect(existsSync(b.loginFile)).toBe(false);
  expect((await b.feed()).status).toBe(401);
  for (let i = 0; i < 5; i++) expect((await b.login(USER, secret())).status).toBe(401);
  expect((await b.login(USER, b.password)).status).toBe(429);
  b.advance(15 * 60 * 1000 + 1);
  const r = await b.login(USER, b.password);
  expect(r.status).toBe(200);
  expect((await b.feed({ cookie: cookieOf(r) })).status).toBe(200);
});

test("a pre-keyring login file is read once with a deprecation notice, moved into the keyring and removed", async () => {
  const seen: string[] = [];
  const orig = console.error;
  console.error = (...a: unknown[]) => { seen.push(a.join(" ")); };
  cleanups.push(() => { console.error = orig; });
  const b = boot({ legacy: true });
  const line = readFileSync(b.loginFile, "utf8").trim();
  expect(b.k.get(KEY)).toBeNull();
  const r = await b.login(USER, b.password);
  expect(r.status).toBe(200);
  expect(b.k.get(KEY)).toBe(line);
  expect(existsSync(b.loginFile)).toBe(false);
  const notice = seen.filter((m) => /deprecated/i.test(m));
  expect(notice.length).toBe(1);
  expect(notice[0]).toContain(b.loginFile);
  expect(notice[0]).not.toContain(JSON.parse(line).hash);
  expect((await b.login(USER, b.password)).status).toBe(200);
  expect(seen.filter((m) => /deprecated/i.test(m)).length).toBe(1);
});

test("a pre-keyring login file still logs in when the keyring is locked, and stays where it is", async () => {
  const b = boot({ legacy: true, locked: true });
  expect((await b.login(USER, b.password)).status).toBe(200);
  expect(existsSync(b.loginFile)).toBe(true);
  expect(b.k.get(KEY)).toBeNull();
});

test("a locked keyring with no login file is a 500 that says so, never a 404 that invites setting a login", async () => {
  const b = boot({ password: null, locked: true });
  const r = await b.login(USER, "anything");
  expect(r.status).toBe(500);
  expect(await r.text()).toMatch(/keyring/i);
});

test("the process env never overrides the keyring item, and never stands in for a missing one", async () => {
  const b = boot({ envLogin: loginLine(USER, "env-" + secret()) });
  expect((await b.login(USER, b.password)).status).toBe(200);
  const none = boot({ password: null, envLogin: loginLine(USER, "env-" + secret()) });
  expect((await none.login(USER, "anything")).status).toBe(404);
});

test("a pre-keyring login file that is a symlink or readable by others is refused", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-file-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir);
  const real = join(dir, "real"), link = join(dir, "link");
  writeLegacy(real, loginLine(USER, secret()));
  symlinkSync(real, link);
  expect(() => readLogin(link, k.env)).toThrow(/symlink/);
  chmodSync(real, 0o644);
  expect(() => readLogin(real, k.env)).toThrow(/mode 600/);
});

test("a keyring lookup that errors while the login exists is a 500, never a 404 that invites setting a login", async () => {
  const b = boot({ password: null, extra: { KSTUB_LOOKUP_FAIL: "1" } });
  b.k.put(KEY, loginLine(USER, "stored-" + secret()));
  const r = await b.login(USER, "anything");
  expect(r.status).toBe(500);
  expect(await r.text()).toMatch(/keyring/i);
});

test("a keyring that cannot even be searched is an error, not an empty answer", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-search-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir);
  expect(() => readLogin(join(dir, "ui-login"), { ...k.env, KSTUB_LOOKUP_FAIL: "1", KSTUB_SEARCH_FAIL: "1" })).toThrow(/keyring/i);
});

test("a lookup error with no item stored is still just no login: a clean search is the proof of empty", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-empty-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir);
  expect(readLogin(join(dir, "ui-login"), { ...k.env, KSTUB_LOOKUP_FAIL: "1" })).toBeNull();
});

test("create-only refuses, and leaves the item, when the keyring lookup errors", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-create-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir), line = loginLine(USER, secret());
  k.put(KEY, line);
  expect(() => writeLogin(join(dir, "ui-login"), USER, secret(), { createOnly: true, env: { ...k.env, KSTUB_LOOKUP_FAIL: "1" } })).toThrow();
  expect(k.get(KEY)).toBe(line);
});

test("a pre-keyring file stays when the keyring does not hold the login after the move", async () => {
  const b = boot({ legacy: true, extra: { KSTUB_STORE_NOOP: "1" } });
  const line = readFileSync(b.loginFile, "utf8").trim();
  expect((await b.login(USER, b.password)).status).toBe(200);
  expect(b.k.get(KEY)).toBeNull();
  expect(readFileSync(b.loginFile, "utf8").trim()).toBe(line);
});

test("setting the login keeps a pre-keyring file when the keyring does not hold the new login afterwards", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-set-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir), f = join(dir, "ui-login"), line = loginLine(USER, secret());
  writeLegacy(f, line);
  expect(() => writeLogin(f, USER, secret(), { env: { ...k.env, KSTUB_STORE_NOOP: "1" } })).toThrow(/did not return/);
  expect(readFileSync(f, "utf8").trim()).toBe(line);
});

test("a project-scoped item of the checkout the server runs in never shadows the user-scope login", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-cwd-"));
  const cwd = process.cwd();
  cleanups.push(() => { process.chdir(cwd); rmSync(dir, { recursive: true, force: true }); });
  const repo = join(dir, "repo");
  mkdirSync(repo);
  expect(spawnSync("git", ["init", "-q", repo]).status).toBe(0);
  const k = stubKeyring(dir);
  k.put(KEY, loginLine(USER, secret()));
  k.putProject(KEY, loginLine("shadow", secret()), realpathSync(repo));
  process.chdir(repo);
  expect(readLogin(join(dir, "ui-login"), k.env)?.user).toBe(USER);
});

test("a credentials directory never serves the login either", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-creds-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir), creds = join(dir, "creds");
  mkdirSync(creds);
  writeFileSync(join(creds, KEY), loginLine("credsuser", secret()));
  expect(readLogin(join(dir, "ui-login"), { ...k.env, CREDENTIALS_DIRECTORY: creds })).toBeNull();
  k.put(KEY, loginLine(USER, secret()));
  expect(readLogin(join(dir, "ui-login"), { ...k.env, CREDENTIALS_DIRECTORY: creds })?.user).toBe(USER);
});
