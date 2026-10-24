// The UI login: POST /api/login checks the operator's password against the scrypt hash in ~/.himmel/state/ui-login
// and answers with an HttpOnly, SameSite=Strict session cookie; /api/* takes that cookie or the launch token.
// The password is made at run time and must never reach a response, the audit line or the login file.
import { test, expect, afterEach } from "bun:test";
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { readLogin, writeLogin } from "../login";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const USER = "operator";
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const secret = () => "pw-" + randomBytes(12).toString("hex");

function boot(o: { password?: string | null; noIdle?: boolean } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project");
  for (const d of [home, root, project]) mkdirSync(d);
  const password = o.password === undefined ? secret() : o.password;
  const loginFile = join(home, ".himmel", "state", "ui-login");
  if (password !== null) writeLogin(loginFile, USER, password);
  let t = 1_000_000;
  const s = startServer({
    port: 0, token: TOKEN, root, projectRoot: project, noIdle: o.noIdle, now: () => t,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${s.port}`;
  const post = (path: string, body: unknown, headers: Record<string, string> = {}) => fetch(base + path, {
    method: "POST", headers: { "content-type": "application/json", origin: base, ...headers }, body: JSON.stringify(body),
  });
  const login = (user: string, pw: string) => post("/api/login", { user, password: pw });
  const feed = (headers: Record<string, string> = {}) => fetch(base + "/api/feed", { headers });
  const audit = () => { const f = join(home, ".himmel", "state", "config-ui", "actions.jsonl"); return existsSync(f) ? readFileSync(f, "utf8") : ""; };
  return { s, base, home, project, loginFile, password: password ?? "", post, login, feed, audit, advance: (ms: number) => { t += ms; } };
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

test("a session expires after its TTL", async () => {
  const b = boot();
  const c = cookieOf(await b.login(USER, b.password));
  b.advance(60 * 60 * 1000 + 1);
  expect((await b.feed({ cookie: c })).status).toBe(401);
});

test("setting the login again ends the sessions opened under the old one", async () => {
  const b = boot();
  const c = cookieOf(await b.login(USER, b.password));
  writeLogin(b.loginFile, USER, secret());
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

test("the login file is mode 600, holds a scrypt hash and never the password", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-file-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const f = join(dir, "state", "ui-login"), pw = secret();
  writeLogin(f, USER, pw);
  expect(statSync(f).mode & 0o777).toBe(0o600);
  expect(readFileSync(f, "utf8")).not.toContain(pw);
  expect(readLogin(f)?.user).toBe(USER);
});

test("a login file that is a symlink or readable by others is refused", () => {
  const dir = mkdtempSync(join(tmpdir(), "ui-login-file-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const real = join(dir, "real"), link = join(dir, "link");
  writeLogin(real, USER, secret());
  symlinkSync(real, link);
  expect(() => readLogin(link)).toThrow(/symlink/);
  chmodSync(real, 0o644);
  expect(() => readLogin(real)).toThrow(/mode 600/);
});
