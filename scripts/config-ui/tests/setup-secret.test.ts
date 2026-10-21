// POST /api/setup/secret — the Setup page's write path for one secret. The canary is made at run time and
// must reach exactly one file, the store; never the response, the audit line or the server's output.
import { test, expect, afterEach } from "bun:test";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const canary = () => "e2e-canary-" + randomBytes(12).toString("hex");

function boot(extra: { noIdle?: boolean } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "setup-secret-"));
  const home = join(dir, "home"), root = join(dir, "root"), project = join(dir, "project");
  for (const d of [home, root, project]) mkdirSync(d);
  const s = startServer({
    port: 0, token: TOKEN, root, projectRoot: project, ...extra,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const auditFile = join(home, ".himmel", "state", "config-ui", "actions.jsonl");
  const audit = () => (existsSync(auditFile) ? readFileSync(auditFile, "utf8") : "");
  const url = `http://127.0.0.1:${s.port}/api/setup/secret`;
  const post = (body: unknown, o: { token?: string | null; origin?: string } = {}) => fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", origin: o.origin ?? `http://127.0.0.1:${s.port}`, ...(o.token === null ? {} : { "x-himmel-token": o.token ?? TOKEN }) },
    body: JSON.stringify(body),
  });
  return { s, url, root, project, audit, post };
}

test("set writes the store at 0600 and answers with the name and status only", async () => {
  const b = boot();
  const v = canary();
  const r = await b.post({ name: "JIRA_API_TOKEN", value: v, op: "set" });
  expect(r.status).toBe(200);
  expect(r.headers.get("cache-control")).toBe("no-store");
  const text = await r.text();
  expect(JSON.parse(text)).toEqual({ name: "JIRA_API_TOKEN", status: "set" });
  expect(text).not.toContain(v);
  const store = join(b.root, ".env");
  expect(readFileSync(store, "utf8")).toContain(`JIRA_API_TOKEN=${v}`);
  expect(statSync(store).mode & 0o777).toBe(0o600);
  expect(b.audit()).not.toContain(v);
  expect(JSON.parse(b.audit().trim().split("\n").at(-1)!)).toMatchObject({ action: "secret.set", target: "JIRA_API_TOKEN", value: null, rc: 0 });
});

test("a project-scoped secret goes to the project store, not the himmel one", async () => {
  const b = boot();
  const r = await b.post({ name: "JIRA_PROJECT_KEY", value: "ABC", op: "set" });
  expect(r.status).toBe(200);
  expect(readFileSync(join(b.project, ".env"), "utf8")).toContain("JIRA_PROJECT_KEY=ABC");
  expect(existsSync(join(b.root, ".env"))).toBe(false);
});

test("remove drops the key, keeps the other lines, and reports not-set", async () => {
  const b = boot();
  writeFileSync(join(b.root, ".env"), "KEEP=1\nJIRA_API_TOKEN=" + canary() + "\nALSO=2\n", { mode: 0o600 });
  const r = await b.post({ name: "JIRA_API_TOKEN", op: "remove" });
  expect(r.status).toBe(200);
  expect(await r.json()).toEqual({ name: "JIRA_API_TOKEN", status: "not-set" });
  expect(readFileSync(join(b.root, ".env"), "utf8")).toBe("KEEP=1\nALSO=2\n");
  expect(JSON.parse(b.audit().trim().split("\n").at(-1)!)).toMatchObject({ action: "secret.remove", target: "JIRA_API_TOKEN", value: null });
});

test("every refusal answers without the value and writes nothing", async () => {
  const b = boot();
  const v = canary();
  const cases: [string, Parameters<typeof b.post>[0], Parameters<typeof b.post>[1], number][] = [
    ["no token", { name: "JIRA_API_TOKEN", value: v, op: "set" }, { token: null }, 401],
    ["wrong token", { name: "JIRA_API_TOKEN", value: v, op: "set" }, { token: "x".repeat(64) }, 401],
    ["wrong origin", { name: "JIRA_API_TOKEN", value: v, op: "set" }, { origin: "http://evil.example" }, 403],
    ["unknown name", { name: "NOT_A_SECRET", value: v, op: "set" }, {}, 400],
    ["card key", { name: "FIRECRAWL_API_KEY", value: v, op: "set" }, {}, 400],
    ["bad op", { name: "JIRA_API_TOKEN", value: v, op: "dump" }, {}, 400],
    ["no value on set", { name: "JIRA_API_TOKEN", op: "set" }, {}, 400],
    ["value breaks its rule", { name: "JIRA_BASE_URL", value: "http://" + v, op: "set" }, {}, 400],
    ["value with a newline", { name: "JIRA_API_TOKEN", value: v + "\nX=1", op: "set" }, {}, 400],
    ["value on remove", { name: "JIRA_API_TOKEN", value: v, op: "remove" }, {}, 400],
  ];
  for (const [label, body, o, status] of cases) {
    const r = await b.post(body, o);
    expect([label, r.status]).toEqual([label, status]);
    expect(await r.text()).not.toContain(v);
  }
  expect(existsSync(join(b.root, ".env"))).toBe(false);
  expect(b.audit()).not.toContain(v);
});

test("a GET, even with the value in the query string, is refused with 405", async () => {
  const b = boot();
  const v = canary();
  const r = await fetch(`${b.url}?name=JIRA_API_TOKEN&value=${v}&op=set`, { headers: { "x-himmel-token": TOKEN } });
  expect(r.status).toBe(405);
  expect(existsSync(join(b.root, ".env"))).toBe(false);
});

test("a server in service mode refuses set but still allows remove", async () => {
  const b = boot({ noIdle: true });
  const v = canary();
  const set = await b.post({ name: "JIRA_API_TOKEN", value: v, op: "set" });
  expect(set.status).toBe(403);
  expect(await set.text()).not.toContain(v);
  expect(existsSync(join(b.root, ".env"))).toBe(false);
  writeFileSync(join(b.root, ".env"), "JIRA_API_TOKEN=" + canary() + "\n", { mode: 0o600 });
  expect((await b.post({ name: "JIRA_API_TOKEN", op: "remove" })).status).toBe(200);
});

test("a store that git does not ignore inside a work tree is refused and the value is not echoed", async () => {
  const b = boot();
  mkdirSync(join(b.project, ".git"));
  const v = canary();
  const r = await b.post({ name: "JIRA_PROJECT_KEY", value: "ABC", op: "set" });
  expect(r.status).toBe(409);
  expect(await r.text()).not.toContain(v);
  expect(existsSync(join(b.project, ".env"))).toBe(false);
});
