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
function boot(o: { password?: string | null; noIdle?: boolean; readOnly?: boolean; legacy?: boolean; locked?: boolean; envLogin?: string; extra?: Record<string, string> } = {}) {
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
  const s =startServer({ port: 0, token: TOKEN, root, projectRoot: project, noIdle: o.noIdle, readOnly: o.readOnly, onIdle: () => {}, now: () => t, env });
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

test("setting the login says so when the old login file cannot be removed, since it would serve the old password again", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-stuck-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir), f = join(dir, "ui-login");
  mkdirSync(f);
  expect(() => writeLogin(f, USER, secret(), { env: k.env })).toThrow(/could not be removed/);
});

test("a secret-tool that exits 1 with nothing printed on an empty search still means no login", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-rc1-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const k = stubKeyring(dir), env = { ...k.env, KSTUB_LOOKUP_FAIL: "1", KSTUB_SEARCH_RC1: "1" };
  expect(readLogin(join(dir, "ui-login"), env)).toBeNull();
  k.put(KEY, loginLine(USER, secret()));
  expect(() => readLogin(join(dir, "ui-login"), env)).toThrow(/keyring/i);
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

// ---- the page side: app.js and login.js run against a real service-mode server through a cookie jar ----
// A refused secret save offers Log in, login returns to Configure, the header shows the login state, and the typed value
// reaches nothing but the one save request. The page runs against stubs of the DOM; the server, the session and the keyring are real.
const PUBLIC = join(import.meta.dir, "../public");
const settle = () => new Promise((r) => setTimeout(r, 120));
const NAME = "JIRA_API_TOKEN";

type Spy = { urls: string[]; bodies: { url: string; body: string }[]; store: string[]; logs: string[]; cookies: string[]; replaced: string[]; history: string[] };

// What a browser keeps for one site: one cookie, and a record of everything the page sent, stored, logged or wrote to the address bar.
function browser(base: string) {
  let jar = "";
  const spy: Spy = { urls: [], bodies: [], store: [], logs: [], cookies: [], replaced: [], history: [] };
  const real = globalThis.fetch;
  const answered = new Set(["/api/mode", "/api/setup/secret", "/api/login", "/api/logout"]);
  const fetchStub = async (url: string, init: { headers?: Record<string, string>; body?: unknown } = {}) => {
    const path = String(url).split("?")[0];
    spy.urls.push(String(url));
    if (init.body !== undefined) spy.bodies.push({ url: path, body: String(init.body) });
    if (!answered.has(path)) return new Promise<Response>(() => {}); // every other read stays quiet
    const r = await real(base + url, { ...init, headers: { ...init.headers, origin: base, ...(jar ? { cookie: jar } : {}) } });
    const set = r.headers.get("set-cookie");
    if (set) jar = /Max-Age=0/.test(set) ? "" : set.split(";")[0];
    return r;
  };
  return { spy, fetchStub, hasSession: () => jar !== "" };
}

const GLOBALS = ["document", "location", "history", "fetch", "addEventListener", "localStorage", "sessionStorage", "console", "FormData"] as const;
async function withGlobals(over: Record<string, unknown>, run: () => Promise<void>) {
  const g = globalThis as Record<string, unknown>;
  const names = [...GLOBALS, ...Object.keys(over)];
  const saved = Object.fromEntries(names.map((n) => [n, g[n]]));
  Object.assign(g, over);
  try { await run(); } finally { for (const n of names) { if (saved[n] === undefined) delete g[n]; else g[n] = saved[n]; } }
}
const recorder = (spy: Spy) => ({
  localStorage: { setItem: (k: string, v: string) => spy.store.push(`${k}=${v}`) },
  sessionStorage: { setItem: (k: string, v: string) => spy.store.push(`${k}=${v}`) },
  console: { log: (...a: unknown[]) => spy.logs.push(a.join(" ")), warn: (...a: unknown[]) => spy.logs.push(a.join(" ")), error: (...a: unknown[]) => spy.logs.push(a.join(" ")), info: (...a: unknown[]) => spy.logs.push(a.join(" ")), debug: (...a: unknown[]) => spy.logs.push(a.join(" ")) },
});

// the names app.js imports are no-ops, but for the few whose result is read as data
const DATA_STUBS: Record<string, unknown> = {
  reviewGateDraft: () => [], verdict: () => ({ cls: "off", word: "No data" }), parseView: () => ({ mode: "project", project: null, tab: "broken", row: null }),
  projectVerdict: () => ({ word: "All clear" }), chiefLiveFor: () => undefined, toolHealthLoader: () => ({}), driftSince: () => null, pinsFromSearch: () => [],
  togglePin: () => ({ pins: [], msg: "" }), parseWorkflowRoute: () => null, apiRolesDraft: () => null, fleetDot: () => ({ cls: "off", title: "" }),
  healthDot: () => ({ cls: "off", title: "" }), navLinks: () => [], parseLanding: () => null,
};
const escHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

// Load the page at `hash` the way the browser does, hand the test a way to fire events, and read what was painted.
async function onPage(b: ReturnType<typeof browser>, hash: string, run: (p: { main: () => string; top: () => string; fire: (type: string, target: unknown) => void }) => Promise<void>) {
  const full = readFileSync(join(PUBLIC, "app.js"), "utf8");
  const importLine = /^import\s*\{([^}]*)\}\s*from\s*["'][^"']+["'];?\s*$/gm;
  const src = full.replace(importLine, "");
  const names = [...full.matchAll(importLine)].flatMap((m) => m[1].split(",").map((s) => s.trim().split(/\s+as\s+/).pop()!).filter(Boolean));
  const stubs: Record<string, unknown> = Object.fromEntries(names.map((n) => [n, () => ""]));
  Object.assign(stubs, DATA_STUBS);
  // Configure paints each message the way setup.js does: <span class="ro" role="status">message</span>
  stubs.render = (_f: unknown, c: { msgs: Record<string, string> }) => Object.values(c.msgs).map((m) => `<span class="ro" role="status">${escHtml(m)}</span>`).join("");
  const els: Record<string, Record<string, unknown>> = {};
  const el = (k: string) => (els[k] ??= { textContent: "", innerHTML: "", hidden: false, dataset: {}, focus() {}, setSelectionRange() {}, setAttribute() {}, classList: { toggle() {}, add() {}, remove() {} } });
  const known = new Set(["#main", "#top", "#nav", "#where", "#pages", "#status", "#toast", "#read-only-banner"]);
  const handlers: Record<string, ((e: unknown) => void)[]> = {};
  const doc = {
    querySelector: (s: string) => (known.has(s) ? el(s) : null), querySelectorAll: () => [], getElementById: (s: string) => el("#" + s), activeElement: null, body: { dataset: {} },
    addEventListener: (t: string, f: (e: unknown) => void) => void (handlers[t] ??= []).push(f),
    set cookie(v: string) { b.spy.cookies.push(v); }, get cookie() { return ""; },
  };
  // the address bar: the launch URL's #t=<token>&page=<id> lands on /#/<id>, as parseLanding and app.js do in the browser
  const loc = { hash, pathname: "/", search: "", host: "x" };
  stubs.parseLanding = (h: string) => { const m = /^#t=([^&]+)&page=(\w+)/.exec(h); return m ? { token: m[1], page: m[2] } : null; };
  const over = {
    ...stubs, ...recorder(b.spy), MutationObserver: class { observe() {} }, document: doc, fetch: b.fetchStub, addEventListener() {}, location: loc,
    history: { replaceState: (_a: unknown, _b: unknown, u: string) => { b.spy.history.push(u); loc.hash = u.includes("#") ? u.slice(u.indexOf("#")) : ""; } },
  };
  await withGlobals(over, async () => {
    new Function(src)();
    await settle();
    await run({
      main: () => String(el("#main").innerHTML), top: () => String(el("#top").innerHTML),
      fire: (type, target) => { for (const h of handlers[type] ?? []) h({ target, preventDefault() {}, stopPropagation() {} }); },
    });
  });
}

// the Save click on a secret row: a form holding one input
const saveEvent = (value: string) => {
  const input = { value };
  const form = { dataset: { name: NAME }, querySelector: () => input };
  return { input, target: { closest: (s: string) => (s === "[data-setup-form]" ? form : null) } };
};
const clickEvent = (act: string) => { const btn = { dataset: { act }, getAttribute: () => null, closest: () => null }; return { closest: (s: string) => (s === "[data-act],[data-f]" ? btn : null) }; };

// login.js against the same browser: submit the form with a user, a password and the page's own ?next=
async function logIn(b: ReturnType<typeof browser>, search: string, user: string, password: string) {
  let submit: (e: unknown) => Promise<void> = async () => {};
  const form = { elements: { password: { value: password } }, addEventListener: (_t: string, f: (e: unknown) => Promise<void>) => void (submit = f) };
  const status = { textContent: "" };
  class Form { get(k: string) { return k === "user" ? user : password; } }
  const over = { ...recorder(b.spy), FormData: Form, fetch: b.fetchStub, document: { getElementById: (id: string) => (id === "login" ? form : status) }, location: { search, origin: "http://127.0.0.1", replace: (u: string) => b.spy.replaced.push(u) } };
  await withGlobals(over, async () => {
    new Function(readFileSync(join(PUBLIC, "login.js"), "utf8"))();
    await submit({ preventDefault() {} });
  });
  return status.textContent;
}

// One operator walking the whole way: refused save, Log in, back on Configure, a save that works. Shared by the rows below.
let walked: Promise<{ spy: Spy; refused: string; refusedTop: string; href: string; replaced: string[]; backTop: string; backMain: string; stored: string; typed: string; password: string; cleared: boolean }> | null = null;
function walk() {
  return (walked ??= (async () => {
    const s = boot({ noIdle: true });
    const b = browser(s.base);
    const typed = "e2e-canary-" + randomBytes(12).toString("hex");
    let refused = "", refusedTop = "", cleared = false;
    await onPage(b, `#t=${TOKEN}&page=config`, async (p) => {
      const ev = saveEvent(typed);
      p.fire("submit", ev.target);
      await settle();
      refused = p.main(); refusedTop = p.top(); cleared = ev.input.value === "";
    });
    const href = /href="(\/login[^"]*)"/.exec(refused)?.[1] ?? "";
    await logIn(b, href.includes("?") ? "?" + href.split("?")[1] : "", USER, s.password);
    let backTop = "", backMain = "";
    await onPage(b, "#/config", async (p) => {
      backTop = p.top();
      p.fire("submit", saveEvent(typed).target);
      await settle();
      backMain = p.main();
    });
    const envFile = join(dirname(s.home), "root", ".env");
    const stored = (existsSync(envFile) ? readFileSync(envFile, "utf8") : "") + (s.k.get(NAME) ?? "");
    return { spy: b.spy, refused, refusedTop, href, replaced: b.spy.replaced, backTop, backMain, stored, typed, password: s.password, cleared };
  })());
}

test("a refused save offers a Log in button that leads back to Configure, and a save there then succeeds against the stub keyring", async () => {
  const w = await walk();
  expect(w.refused).toContain("log in to save a secret");
  expect(w.refused).toMatch(/<a class="btn primary" href="\/login\?next=%2F%23%2Fconfig">Log in<\/a>/);
  expect(w.replaced).toEqual(["/#/config"]);
  expect(w.backMain).toContain("saved");
  expect(w.stored).toContain(w.typed);
});

test("the return path is limited to a path on this site: absolute, protocol-relative, backslash and scheme forms land on /", async () => {
  const s = boot({ noIdle: true });
  const off = ["https://evil.example/", "http://127.0.0.1.evil.example/", "//evil.example/x", "/\\evil.example", "\\\\evil.example", "\\/evil.example", "javascript:alert(1)", "/\t/evil.example", "/\n/evil.example", "evil.example", ""];
  for (const next of off) {
    const b = browser(s.base);
    await logIn(b, "?next=" + encodeURIComponent(next), USER, s.password);
    expect(b.spy.replaced, JSON.stringify(next)).toEqual(["/"]);
  }
  for (const next of ["/", "/#/config", "/#/config?tile=secrets"]) {
    const b = browser(s.base);
    await logIn(b, "?next=" + encodeURIComponent(next), USER, s.password);
    expect(b.spy.replaced, next).toEqual([next]);
  }
  const none = browser(s.base);
  await logIn(none, "", USER, s.password);
  expect(none.spy.replaced).toEqual(["/"]);
});

test("a typed secret value reaches no URL, storage, log, cookie or address bar, only the save request body", async () => {
  const w = await walk();
  const v = w.typed;
  expect(w.cleared).toBe(true);
  expect(w.spy.bodies.filter((x) => x.body.includes(v)).map((x) => x.url)).toEqual(["/api/setup/secret", "/api/setup/secret"]);
  for (const [what, seen] of Object.entries({ urls: w.spy.urls, store: w.spy.store, logs: w.spy.logs, cookies: w.spy.cookies, history: w.spy.history, replaced: w.spy.replaced, links: [w.href, w.refused, w.refusedTop, w.backTop, w.backMain] })) {
    expect(seen.join("\n"), what).not.toContain(v);
  }
  expect(w.spy.bodies.map((x) => x.body).filter((x) => x.includes(w.password)).length).toBe(1); // the password is in the login request only
  expect(w.spy.urls.join("\n")).not.toContain(w.password);
});

test("a read-only UI refuses every write, login and logout included, so its header offers neither", async () => {
  const s = boot({ noIdle: true, readOnly: true });
  const b = browser(s.base);
  await onPage(b, `#t=${TOKEN}&page=config`, async (p) => {
    await settle();
    expect(p.top()).not.toContain("login");
    expect(p.top()).not.toContain('data-act="logout"');
    expect(p.top()).not.toContain("/login");
  });
});

test("the header shows the login state: Log in while out, Log out while in, and Log out ends the session", async () => {
  const w = await walk();
  expect(w.refusedTop).toContain("not logged in");
  expect(w.refusedTop).toContain('href="/login?next=%2F%23%2Fconfig"');
  expect(w.backTop).toContain("logged in");
  expect(w.backTop).not.toContain("not logged in");
  expect(w.backTop).toContain('data-act="logout"');
  const s = boot({ noIdle: true });
  const b = browser(s.base);
  await logIn(b, "", USER, s.password);
  await onPage(b, "#/config", async (p) => {
    expect(p.top()).toContain('data-act="logout"');
    p.fire("click", clickEvent("logout"));
    await settle();
    expect(b.hasSession()).toBe(false);
    expect(p.top()).toContain("not logged in");
    expect(p.top()).not.toContain('data-act="logout"');
  });
});
