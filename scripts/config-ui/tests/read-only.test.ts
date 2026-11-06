// The config UI's read-only mode. With readOnly set at start (himmelctl ui --read-only) the server answers every
// request whose method is not GET or HEAD with 403 before any route runs. Scratch HOME and config only, never the station's.
import { test, expect, afterEach } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const BIN = join(import.meta.dir, "../../himmelctl/bin.js");
const TOKEN = "t".repeat(64);
const BASE = { panel: [{ slug: "codex", model: "gpt-6.1-sol", provider: "openai-codex", tier: "paid", mode: "hard", required: true }] };
let dir = "";
let stop: (() => void) | null = null;
afterEach(() => { stop?.(); stop = null; if (dir) rmSync(dir, { recursive: true, force: true }); dir = ""; });

function boot(readOnly: boolean) {
  dir = mkdtempSync(join(tmpdir(), "read-only-"));
  mkdirSync(join(dir, "home", ".himmel"), { recursive: true });
  mkdirSync(join(dir, "station"));
  mkdirSync(join(dir, "handover"));
  writeFileSync(join(dir, "critics.json"), JSON.stringify(BASE, null, 2) + "\n");
  const s = startServer({ onIdle: () => {},
    port: 0, token: TOKEN, ...(readOnly ? { readOnly: true } : {}),
    env: { PATH: process.env.PATH, HOME: join(dir, "home"), HIMMEL_POLICY_FOLLOWS_HOME: "1", CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HANDOVER_DIR: join(dir, "handover"),
      HIMMELCTL_REPO_ROOT: join(dir, "station"), CRITICS_BASE_JSON: join(dir, "critics.json"), CRITICS_LOCAL_JSON: join(dir, "critics.local.json") },
  });
  stop = () => s.stop();
  return s.port;
}
// every file under the scratch dir with its content hash: a refused write leaves this identical
function tree(d: string, out: Record<string, string> = {}): Record<string, string> {
  for (const n of readdirSync(d)) {
    if (n === ".bun") continue; // bun's own package cache, filled by a child process a route starts; not config or state
    const p = join(d, n);
    const st = statSync(p);
    if (st.isDirectory()) tree(p, out); else out[p] = `${createHash("sha256").update(readFileSync(p)).digest("hex")}:${st.mtimeMs}`;
  }
  return out;
}
const post = (port: number, p: string, body: unknown = {}, method = "POST") => fetch(`http://127.0.0.1:${port}${p}`, {
  method, headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json", Origin: `http://127.0.0.1:${port}` }, body: JSON.stringify(body),
});
const get = (port: number, p: string, method = "GET") => fetch(`http://127.0.0.1:${port}${p}`, { method, headers: { "X-Himmel-Token": TOKEN } });

// every route the server accepts a POST on
const WRITE_ROUTES: [string, unknown][] = [
  ["/api/login", { user: "u", password: "p" }],
  ["/api/logout", {}],
  ["/api/preview", { action: "x", target: "y" }],
  ["/api/run", { action: "x", target: "y" }],
  ["/api/board/drift-refresh", {}],
  ["/api/vm", { vm: {} }],
  ["/api/report-settings", {}],
  ["/api/review-gate", { reviewers: [{ slug: "codex", mode: "hard", required: true, enabled: true, model: "gpt-6.2-test" }] }],
  ["/api/fleet-cap", { cap: 9 }],
  ["/api/roadmap/write", {}],
  ["/api/setup/secret", { name: "X", value: "v" }],
  ["/api/setup/account", { user: "u", password: "p" }],
  ["/api/setup/verify", {}],
];

for (const [route, body] of WRITE_ROUTES) {
  test(`--read-only: POST ${route} is 403 and the scratch config is unchanged`, async () => {
    const port = boot(true);
    const before = tree(dir);
    const r = await post(port, route, body);
    expect(r.status).toBe(403);
    expect(await r.text()).toContain("read-only");
    expect(tree(dir)).toEqual(before);
  });
}

test("--read-only: PUT, PATCH and DELETE are 403 on a path no route knows, so a route added later is covered", async () => {
  const port = boot(true);
  for (const m of ["PUT", "PATCH", "DELETE", "POST"]) expect((await post(port, "/api/not-a-route-yet", {}, m)).status).toBe(403);
});

test("--read-only: a POST without the token or origin is 403 too, before auth", async () => {
  const port = boot(true);
  expect((await fetch(`http://127.0.0.1:${port}/api/review-gate`, { method: "POST", body: "{}" })).status).toBe(403);
});

test("--read-only: GET and HEAD still work and GET /api/mode says readOnly", async () => {
  const port = boot(true);
  expect(await (await get(port, "/api/mode")).json()).toEqual({ readOnly: true });
  expect((await get(port, "/api/fleet-cap")).status).toBe(200);
  expect((await get(port, "/api/fleet-cap", "HEAD")).status).not.toBe(403); // HEAD passes the gate (the routes themselves serve GET only)
});

// every GET route that reads the config or the fleet; a poll that records state (the shift poll, the cached feed) is among them
const GET_ROUTES = ["/api/feed", "/api/projects", "/api/bank", "/api/board", "/api/fleet-cap", "/api/health", "/api/mode", "/api/phase-stats", "/api/report",
  "/api/reports", "/api/report-settings", "/api/reviewers", "/api/review-gate", "/api/roadmap", "/api/rollup", "/api/setup", "/api/shift", "/api/sources",
  "/api/tool-health", "/api/tool-inventory", "/api/vm"];

test("--read-only: a GET on every route writes nothing, file bytes and mtimes in the scratch tree are unchanged", async () => {
  const port = boot(true);
  const before = tree(dir);
  for (const r of GET_ROUTES) await get(port, r);
  await new Promise((res) => setTimeout(res, 300)); // the feed saves after its run ends
  expect(tree(dir)).toEqual(before);
});

test("RED control, no flag: the same GET sweep records the shift state, so the read-only sweep above is not vacuous", async () => {
  const port = boot(false);
  await get(port, "/api/shift");
  expect(existsSync(join(dir, "handover", "shifts.jsonl.state.json"))).toBe(true);
});

test("RED control, no flag: the same review-gate POST writes the overlay, and /api/mode says readOnly false", async () => {
  const port = boot(false);
  expect(await (await get(port, "/api/mode")).json()).toEqual({ readOnly: false });
  const r = await post(port, "/api/review-gate", WRITE_ROUTES.find(([p]) => p === "/api/review-gate")![1]);
  expect(r.status).toBe(200);
  expect(existsSync(join(dir, "critics.local.json"))).toBe(true);
});

// no DOM harness here: the banner and the disabled controls are checked in a browser against a scratch server (the PR body says how)
test("the page carries a hidden read-only banner that app.js shows from GET /api/mode, disables write controls and stops posting", () => {
  const pub = join(import.meta.dir, "../public");
  expect(readFileSync(join(pub, "index.html"), "utf8")).toMatch(/<div id="read-only-banner" role="status" hidden>/);
  const app = readFileSync(join(pub, "app.js"), "utf8");
  expect(app).toContain('fetch("/api/mode"');
  expect(app).toContain('$("#read-only-banner").hidden = false');
  expect(app).toMatch(/async function post\(path, body\) \{\n  if \(readOnly\) return \{ ok: false, status: 403/);
  // every control that sends one of the page's writes is on the disabled list
  for (const sel of ['data-act="plan"', 'data-act="run"', 'data-act="vm-save"', 'data-act="reports-save"', 'data-act="review-gate-save"', 'data-act="setup-remove"', 'data-act="setup-verify"', 'data-act="drift-refresh"', "[data-vm]", "[data-rs]", "[data-fc]", "[data-rg]", "select.rm-theme", "form[data-setup-form]", "form[data-account-form]", "form[data-path-form]"]) {
    expect(app.slice(app.indexOf("const WRITE_CONTROLS"), app.indexOf("function lockWrites"))).toContain(sel);
  }
  expect(app).toContain('document.querySelectorAll("[data-rm-card]")'); // the Roadmap cards stop being draggable
});

// --allow-agent-session: the suite may itself run inside a Claude session, and that refusal also exits 2
// a scratch HOME: were a flag ever accepted, the command would touch the scratch home, never the station's
const ctl = (...args: string[]) => {
  const home = mkdtempSync(join(tmpdir(), "read-only-ctl-"));
  try { return spawnSync("node", [BIN, ...args], { encoding: "utf8", env: { ...process.env, HOME: home } }); } finally { rmSync(home, { recursive: true, force: true }); }
};

test("himmelctl ui --service refuses --read-only: the installed unit would start the server without it", () => {
  const r = ctl("ui", "--allow-agent-session", "--service", "status", "--read-only");
  expect(r.status).toBe(2);
  expect(r.stderr).toContain("--read-only does not apply to --service");
});

test("himmelctl rejects --read-only on a command that is not ui, so ensure --yes --read-only changes nothing", () => {
  const r = ctl("ensure", "--yes", "--read-only", "--dry-run");
  expect(r.status).toBe(2);
  expect(r.stderr).toContain("--read-only is not valid with 'ensure'");
});

test("himmelctl ui help says the default mode can write and describes --read-only", () => {
  const help = execFileSync("node", [BIN, "--help"], { encoding: "utf8" });
  const ui = help.slice(help.indexOf("  ui [--port N]"), help.indexOf("  gaps "));
  expect(ui).toContain("--read-only");
  expect(ui).toContain("CAN WRITE");
  expect(ui).not.toContain("  ui [--port N]           read-only config UI");
});
