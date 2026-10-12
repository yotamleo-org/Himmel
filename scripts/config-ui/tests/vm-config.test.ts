// HIMMEL-4620: GET/POST /api/vm — the config UI edits vm.mode and vm.remote through luna-config.js
// (validateVm before write, atomic save). Every test points the config path and HOME at a temp dir.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
// @ts-expect-error CommonJS module without types
import { defaultConfig, configPath } from "../../himmelctl/lib/luna-config.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const SAVED = ["HOME", "HIMMEL_LUNA_CONFIG_PATH", "HIMMEL_PROVENANCE_DIR"] as const;
let saved: Record<string, string | undefined> = {};
let dir = "";
let cfg = "";
let stop: (() => void) | null = null;

beforeEach(() => {
  saved = Object.fromEntries(SAVED.map((k) => [k, process.env[k]]));
  dir = mkdtempSync(join(tmpdir(), "vm-config-"));
  const home = join(dir, "home");
  mkdirSync(home);
  cfg = join(dir, "config.json");
  process.env.HOME = home;
  process.env.HIMMEL_LUNA_CONFIG_PATH = cfg;
  process.env.HIMMEL_PROVENANCE_DIR = join(dir, "prov");
});
afterEach(() => {
  stop?.(); stop = null;
  for (const k of SAVED) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  rmSync(dir, { recursive: true, force: true });
});

function boot() {
  // never let a test reach the live config
  expect(configPath().startsWith(tmpdir())).toBe(true);
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, HOME: process.env.HOME, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000" } });
  stop = () => s.stop();
  return s.port;
}
const seed = (extra: Record<string, unknown> = {}) => {
  const doc = { ...defaultConfig(), ...extra };
  doc.luna.vaultPath = "/seeded/vault";
  doc.bridge.enabled = true;
  writeFileSync(cfg, JSON.stringify(doc, null, 2) + "\n");
  return doc;
};
const read = () => JSON.parse(readFileSync(cfg, "utf8"));
const get = (port: number, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }) => fetch(`http://127.0.0.1:${port}/api/vm`, { headers });
const post = (port: number, body: unknown, headers: Record<string, string> = {}) => fetch(`http://127.0.0.1:${port}/api/vm`, {
  method: "POST",
  headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json", Origin: `http://127.0.0.1:${port}`, ...headers },
  body: JSON.stringify(body),
});
const withoutVm = (d: Record<string, unknown>) => { const { vm, ...o } = d; void vm; return o; };

test("GET with no vm section answers the resolver default, local", async () => {
  seed();
  const port = boot();
  const r = await get(port);
  expect(r.status).toBe(200);
  expect(await r.json()).toEqual({ mode: "local", remote: null });
});

test("GET with no config file at all answers local and writes nothing", async () => {
  const port = boot();
  const r = await get(port);
  expect(r.status).toBe(200);
  expect((await r.json()).mode).toBe("local");
  expect(() => readFileSync(cfg)).toThrow();
});

test("POST local saves vm.mode=local and leaves every other section as it was", async () => {
  const before = seed();
  const port = boot();
  const r = await post(port, { mode: "local" });
  expect(r.status).toBe(200);
  const after = read();
  expect(after.vm).toEqual({ mode: "local" });
  expect(withoutVm(after)).toEqual(withoutVm(before));
});

test("POST remote saves ssh, numeric port and identity", async () => {
  const before = seed();
  const port = boot();
  const r = await post(port, { mode: "remote", remote: { ssh: "ops@vm.example", port: "2200", identity: "~/.ssh/id_test" } });
  expect(r.status).toBe(200);
  const after = read();
  expect(after.vm).toEqual({ mode: "remote", remote: { ssh: "ops@vm.example", port: 2200, identity: "~/.ssh/id_test" } });
  expect(withoutVm(after)).toEqual(withoutVm(before));
  expect(await (await get(port)).json()).toEqual({ mode: "remote", remote: { ssh: "ops@vm.example", port: 2200, identity: "~/.ssh/id_test" } });
});

test("POST remote with only ssh leaves port and identity to the resolver defaults", async () => {
  seed();
  const port = boot();
  expect((await post(port, { mode: "remote", remote: { ssh: "ops@vm.example", port: "", identity: "" } })).status).toBe(200);
  expect(read().vm).toEqual({ mode: "remote", remote: { ssh: "ops@vm.example" } });
});

test("POST none saves vm.mode=none and drops a previous remote", async () => {
  seed({ vm: { mode: "remote", remote: { ssh: "ops@vm.example" } } });
  const port = boot();
  expect((await post(port, { mode: "none" })).status).toBe(200);
  expect(read().vm).toEqual({ mode: "none" });
});

test("invalid input is refused with the validator message and writes nothing", async () => {
  seed();
  const port = boot();
  const bytes = readFileSync(cfg, "utf8");
  const cases: [unknown, RegExp][] = [
    [{ mode: "Local" }, /vm\.mode/],
    [{ mode: "sometimes" }, /vm\.mode/],
    [{ mode: "remote", remote: {} }, /vm\.remote\.ssh/],
    [{ mode: "remote", remote: { ssh: "-oProxyCommand=x" } }, /vm\.remote\.ssh/],
    [{ mode: "remote", remote: { ssh: "ops@vm.example", port: "70000" } }, /vm\.remote\.port/],
    [{ mode: "remote", remote: { ssh: "ops@vm.example", identity: "a b" } }, /vm\.remote\.identity/],
  ];
  for (const [body, msg] of cases) {
    const r = await post(port, body);
    expect(r.status).toBe(400);
    expect((await r.json()).error).toMatch(msg);
    expect(readFileSync(cfg, "utf8")).toBe(bytes);
  }
});

test("a malformed config file is never rewritten", async () => {
  writeFileSync(cfg, "{ not json");
  const port = boot();
  const r = await post(port, { mode: "none" });
  expect(r.status).toBe(422);
  expect(readFileSync(cfg, "utf8")).toBe("{ not json");
});

test("the write needs the token, the same origin and a JSON body", async () => {
  seed();
  const port = boot();
  expect((await post(port, { mode: "none" }, { "X-Himmel-Token": "x".repeat(64) })).status).toBe(401);
  expect((await post(port, { mode: "none" }, { Origin: "http://evil.test" })).status).toBe(403);
  expect((await post(port, { mode: "none" }, { "Content-Type": "text/plain" })).status).toBe(415);
  expect((await get(port, {})).status).toBe(401);
  expect(read().vm).toBeUndefined();
});
