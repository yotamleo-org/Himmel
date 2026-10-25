// POST /api/setup/account: the first-run Account step creates the UI login once, from a token-bound (not service) server.
// The password is made at run time and must reach no answer, audit line or page markup.
import { test, expect, afterEach } from "bun:test";
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { acquireLock } from "../lock";
import { LOGIN_EXISTS, writeLogin } from "../login";
import { startServer } from "../server";
// @ts-ignore plain browser ES module, no types
import { renderSetup } from "../public/setup.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const canary = () => "pw-canary-" + randomBytes(12).toString("hex");

function boot(extra: { noIdle?: boolean } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "setup-account-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project");
  for (const d of [home, root, project]) mkdirSync(d);
  const s = startServer({
    port: 0, token: TOKEN, root, projectRoot: project, ...extra,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${s.port}`;
  const loginFile = join(home, ".himmel", "state", "ui-login");
  const auditFile = join(home, ".himmel", "state", "config-ui", "actions.jsonl");
  const audit = () => (existsSync(auditFile) ? readFileSync(auditFile, "utf8") : "");
  const post = (path: string, body: unknown, o: { token?: string | null } = {}) => fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json", origin: base, ...(o.token === null ? {} : { "x-himmel-token": o.token ?? TOKEN }) },
    body: JSON.stringify(body),
  });
  const state = async () => (await (await fetch(base + "/api/setup", { headers: { "x-himmel-token": TOKEN } })).json()) as Record<string, any>;
  return { home, loginFile, audit, post, state };
}

// what a refusal must leave as it was: the entry itself (a link is not followed) and what it points at.
const snapshot = (p: string) => {
  const l = lstatSync(p);
  return { link: l.isSymbolicLink() ? readlinkSync(p) : null, mode: l.mode, body: l.isSymbolicLink() ? null : readFileSync(p, "utf8") };
};

test("a fresh install creates the login once: mode 600, no password in the answer or the audit, and it logs in", async () => {
  const b = boot();
  expect((await b.state()).account).toMatchObject({ status: "not-set", user: null, create: "ui" });
  const pw = canary();
  const r = await b.post("/api/setup/account", { user: "op", password: pw });
  const text = await r.text();
  expect(r.status).toBe(200);
  expect(text).not.toContain(pw);
  expect(JSON.parse(text)).toEqual({ status: "set", user: "op" });
  expect(statSync(b.loginFile).mode & 0o777).toBe(0o600);
  expect(readFileSync(b.loginFile, "utf8")).not.toContain(pw);
  expect(b.audit()).not.toContain(pw);
  expect(JSON.parse(b.audit().trim().split("\n").at(-1)!)).toMatchObject({ action: "login.create", target: "ui-login", value: null, rc: 0 });
  expect((await b.state()).account).toMatchObject({ status: "set", user: "op", create: "terminal" });
  expect((await b.post("/api/login", { user: "op", password: pw }, { token: null })).status).toBe(200);
});

test("a login that exists is never replaced from the page", async () => {
  const b = boot();
  expect((await b.post("/api/setup/account", { user: "op", password: canary() })).status).toBe(200);
  const before = readFileSync(b.loginFile, "utf8");
  const pw = canary();
  const r = await b.post("/api/setup/account", { user: "intruder", password: pw });
  expect(r.status).toBe(409);
  expect(await r.text()).not.toContain(pw);
  expect(readFileSync(b.loginFile, "utf8")).toBe(before);
});

test("a login file that cannot be read (a symlink, mode 644, malformed) is refused as it is and never replaced", async () => {
  const valid = JSON.stringify({ user: "op", salt: "ab".repeat(16), hash: "cd".repeat(64) }) + "\n";
  const cases: [string, (p: string, dir: string) => void][] = [
    ["a symlink", (p, dir) => { const t = join(dir, "elsewhere"); writeFileSync(t, valid, { mode: 0o600 }); symlinkSync(t, p); }],
    ["mode 644", (p) => { writeFileSync(p, valid); chmodSync(p, 0o644); }],
    ["malformed", (p) => { writeFileSync(p, "not a login\n", { mode: 0o600 }); }],
  ];
  for (const [label, plant] of cases) {
    const b = boot();
    mkdirSync(dirname(b.loginFile), { recursive: true });
    plant(b.loginFile, b.home);
    const before = snapshot(b.loginFile);
    const target = before.link ? readFileSync(before.link, "utf8") : null;
    expect([label, (await b.state()).account]).toMatchObject([label, { status: "unreadable", create: "terminal" }]);
    const pw = canary();
    const r = await b.post("/api/setup/account", { user: "intruder", password: pw });
    const text = await r.text();
    expect([label, r.status]).toEqual([label, 409]);
    expect([label, JSON.parse(text).error]).toEqual([label, expect.stringContaining("the login file cannot be read")]);
    expect(text).not.toContain(pw);
    expect([label, snapshot(b.loginFile)]).toEqual([label, before]);
    if (before.link) expect(readFileSync(before.link, "utf8")).toBe(target!);
    expect(readdirSync(dirname(b.loginFile)).filter((f) => f.endsWith(".tmp"))).toEqual([]);
  }
});

test("a create-only write never replaces a login that appeared after the check", () => {
  const dir = mkdtempSync(join(tmpdir(), "login-create-only-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const p = join(dir, "ui-login");
  writeLogin(p, "op", canary());
  const before = readFileSync(p, "utf8");
  expect(() => writeLogin(p, "intruder", canary(), { createOnly: true })).toThrow(LOGIN_EXISTS);
  expect(readFileSync(p, "utf8")).toBe(before);
  expect(readdirSync(dir)).toEqual(["ui-login"]);
});

test("a create while another write holds the lock answers busy and writes nothing", async () => {
  const b = boot();
  const held = acquireLock(join(b.home, ".himmel", "state", "config-ui", "write.lock"));
  if ("busy" in held) throw new Error(held.busy);
  try {
    const pw = canary();
    const r = await b.post("/api/setup/account", { user: "op", password: pw });
    const text = await r.text();
    expect(r.status).toBe(409);
    expect(JSON.parse(text).error).toContain("another action is running");
    expect(text).not.toContain(pw);
    expect(existsSync(b.loginFile)).toBe(false);
  } finally { held.release(); }
});

test("a service-mode server refuses, so its long-lived token cannot buy a login", async () => {
  const b = boot({ noIdle: true });
  const acct = (await b.state()).account;
  expect(acct).toMatchObject({ status: "not-set", user: null, create: "terminal" });
  expect(acct.setLogin).toBe(`bun ${join(import.meta.dir, "..", "server.ts")} --set-login <user>`);
  const pw = canary();
  const r = await b.post("/api/setup/account", { user: "op", password: pw });
  expect(r.status).toBe(403);
  expect(await r.text()).not.toContain(pw);
  expect(existsSync(b.loginFile)).toBe(false);
});

test("every refusal answers without the password and writes nothing", async () => {
  const b = boot();
  const pw = canary();
  const cases: [string, unknown, { token?: string | null }, number][] = [
    ["no token", { user: "op", password: pw }, { token: null }, 401],
    ["short password", { user: "op", password: "short" }, {}, 400],
    ["user with a space", { user: "o p", password: pw }, {}, 400],
    ["no user", { password: pw }, {}, 400],
    ["password not a string", { user: "op", password: 12345678 }, {}, 400],
  ];
  for (const [label, body, o, status] of cases) {
    const r = await b.post("/api/setup/account", body, o);
    expect([label, r.status]).toEqual([label, status]);
    expect(await r.text()).not.toContain(pw);
  }
  expect(existsSync(b.loginFile)).toBe(false);
  expect(b.audit()).not.toContain(pw);
});

test("the Setup page puts the Account step first and shows the form only where the page can create the login", () => {
  const base = { secrets: [], commit: { tracker: null, ticketIdRequired: null }, coderabbit: null };
  const fresh = renderSetup({ ...base, account: { status: "not-set", user: null, create: "ui" } }, {}, {});
  expect(fresh.indexOf("Account")).toBeGreaterThan(-1);
  expect(fresh.indexOf("Account")).toBeLessThan(fresh.indexOf("Secrets"));
  expect(fresh).toContain("data-account-form");
  const service = renderSetup({ ...base, account: { status: "not-set", user: null, create: "terminal", setLogin: "bun /abs/server.ts --set-login <user>" } }, {}, {});
  expect(service).not.toContain("data-account-form");
  expect(service).toContain("bun /abs/server.ts --set-login &lt;user&gt;");
  const set = renderSetup({ ...base, account: { status: "set", user: "op", create: "terminal" } }, {}, {});
  expect(set).not.toContain("data-account-form");
  expect(set).toContain("op");
});
