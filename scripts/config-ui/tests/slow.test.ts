// Bun.serve cuts any request slower than 10 s by default, and every
// other config-ui test answers instantly. These rows use a stub that is slower.
import { test, expect, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const TOKEN = "t".repeat(64);
const H = { "X-Himmel-Token": TOKEN };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const dirs: string[] = [];
const stops: (() => void)[] = [];
afterEach(() => { while (restores.length) restores.pop()!(); while (stops.length) stops.pop()!(); while (dirs.length) rmSync(dirs.pop()!, { recursive: true, force: true }); });

// The page rows below run app.js against global stubs. Bun abandons a timed-out test body, so a finally block in it never
// runs and the stubs would stay set for every later row and file in the process: stubGlobals records what it replaced, and
// afterEach (which does run after a timeout) puts it back.
const touched = new Map<string, { had: boolean; value: unknown }>(); // every name a row stubbed, as it was before the first stub
const restores: (() => void)[] = [];
function stubGlobals(stubs: Record<string, unknown>, alsoSet: string[] = []) {
  const g = globalThis as Record<string, unknown>;
  const names = [...Object.keys(stubs), ...alsoSet];
  const before = names.map((n) => [n, n in g, g[n]] as const);
  for (const [n, had, value] of before) if (!touched.has(n)) touched.set(n, { had, value });
  restores.push(() => { for (const [n, had, value] of before) { if (had) g[n] = value; else delete g[n]; } });
  Object.assign(g, stubs);
}
const FORCE_TIMEOUT = process.env.SLOW_FORCE_TIMEOUT === "1"; // set by the child run below, never by hand

// One no-op for every name app.js imports (its local binding: `renderConfigure as render` is `render`). The import lines are
// stripped before app.js runs, so a name missing here is a free global, and the first route that calls it throws or hangs
// the row. app-import-stubs.test.ts reads this block and fails, naming the import, when one is missing.
const APP_IMPORT_STUBS: Record<string, unknown> = {
  renderInventory: () => "", renderTriage: () => "", renderHeader: () => "", renderProbe: () => "", reviewGateDraft: () => [],
  renderHealth: () => "", verdict: () => ({ cls: "off", word: "No data" }), parseView: () => ({ mode: "project", project: null, tab: "broken", row: null }), projectVerdict: () => ({ word: "All clear" }), chiefLiveFor: () => undefined,
  renderToolHealth: () => "", toolHealthLoader: () => ({}), toolHealthHref: () => "",
  boardRefreshDue: () => false, driftSince: () => null, renderBoard: () => "", pinsFromSearch: () => [], searchWithPins: () => "", togglePin: () => ({ pins: [], msg: "" }),
  renderWorkflow: () => "", parseWorkflowRoute: () => null, renderCost: () => "",
  apiRolesDraft: () => null, render: () => "",
  renderShift: () => "",
  renderReport: () => "", reportBar: () => "",
  fleetDot: () => ({ cls: "off", title: "" }), healthDot: () => ({ cls: "off", title: "" }), navLinks: () => [], parseLanding: () => null, railMarkup: () => "",
};

function boot(env: Record<string, string>, x: Record<string, unknown> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-slow-"));
  dirs.push(dir);
  mkdirSync(join(dir, "home"), { recursive: true });
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, env: { PATH: process.env.PATH, HOME: join(dir, "home"), CONFIG_UI_IDLE_MS: "60000", ...env }, ...x } as never);
  stops.push(() => s.stop());
  return { port: s.port, dir };
}
const feed = (port: number) => fetch(`http://127.0.0.1:${port}/api/feed`, { headers: H });
const STUB = join(import.meta.dir, "stub-himmelctl.js");

// Poll like the page does: 202 means "still probing", keep asking.
async function untilFeed(port: number) {
  const seen: number[] = [];
  for (;;) {
    const r = await feed(port);
    seen.push(r.status);
    if (r.status !== 202) return { r, seen };
  }
}

test("a feed slower than Bun's 10 s default still arrives: 202 while probing, then the 200 feed", async () => {
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_SLEEP: "11500" }, { feedWaitMs: 3000 });
  const { r, seen } = await untilFeed(port);
  expect(seen[0]).toBe(202);
  expect(r.status).toBe(200);
  expect((await r.json()).schema).toBe("himmel-config-feed/1");
}, 30_000);

test("concurrent feed requests share one report run, and the result is cached", async () => {
  const count = join(mkdtempSync(join(tmpdir(), "cfgui-cnt-")), "n");
  dirs.push(join(count, ".."));
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_SLEEP: "600", STUB_FEED_COUNT: count });
  const rs = await Promise.all([feed(port), feed(port), feed(port)]);
  expect(rs.map((r) => r.status)).toEqual([200, 200, 200]);
  expect((await feed(port)).status).toBe(200); // cached
  expect(readFileSync(count, "utf8").split("\n").filter(Boolean).length).toBe(1);
});

test("a failed report is a terminal error, is not cached, and the next request retries it", async () => {
  const count = join(mkdtempSync(join(tmpdir(), "cfgui-cnt-")), "n");
  dirs.push(join(count, ".."));
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_SLEEP: "5000", STUB_FEED_COUNT: count }, { feedTimeoutMs: 300 });
  const r = await feed(port);
  expect(r.status).toBe(502);
  expect((await r.json()).state).toBe("error");
  expect((await feed(port)).status).toBe(502);
  expect(readFileSync(count, "utf8").split("\n").filter(Boolean).length).toBe(2); // a fresh run each time, no cached failure
});

test("a slow /api/run (over 10 s) still returns its result to the client", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-run-"));
  dirs.push(dir);
  const [home, cad, state] = ["home", "cad", "state"].map((d) => { mkdirSync(join(dir, d), { recursive: true }); return join(dir, d); });
  const rel = "scripts/luna/graphmap-cadence.sh";
  mkdirSync(join(cad, "scripts/luna"), { recursive: true });
  copyFileSync(join(import.meta.dir, "stub-cadence.sh"), join(cad, rel));
  const repo = join(dir, "repo");
  mkdirSync(repo);
  const argv = join(dir, "argv");
  writeFileSync(argv, "");
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, root: repo, env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_IDLE_MS: "60000",
    CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-recorder.js"), HIMMEL_REPORT_CADENCE_ROOT: cad, STUB_ARGV: argv, STUB_STATE: state, STUB_RUN_SLEEP: "11" } } as never);
  stops.push(() => s.stop());
  const post = (path: string, body: unknown) => fetch(`http://127.0.0.1:${s.port}${path}`, { method: "POST", body: JSON.stringify(body),
    headers: { ...H, Origin: `http://127.0.0.1:${s.port}`, "Content-Type": "application/json" } });
  const ARM = { action: "cadence.arm", target: "graphmap" };
  expect((await feed(s.port)).status).toBe(200);
  const pv = await (await post("/api/preview", ARM)).json();
  const r = await post("/api/run", { previewId: pv.previewId, ...ARM, consent: "graphmap" });
  expect(r.status).toBe(200);
  expect((await r.json()).rc).toBe(0);
  // The action changed the station: the next feed re-probes instead of serving the 30 s cache.
  expect((await feed(s.port)).status).toBe(200);
  const feedRuns = readFileSync(argv, "utf8").split("\n").filter((l) => /^himmelctl report\b/.test(l) && !l.includes("--items"));
  expect(feedRuns.length).toBe(2);
}, 40_000);

test("a /api/run rejected before it starts leaves the shared feed run alone", async () => {
  const count = join(mkdtempSync(join(tmpdir(), "cfgui-cnt-")), "n");
  dirs.push(join(count, ".."));
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_SLEEP: "300", STUB_FEED_COUNT: count });
  expect((await feed(port)).status).toBe(200);
  const r = await fetch(`http://127.0.0.1:${port}/api/run`, { method: "POST", body: JSON.stringify({ previewId: "nope", action: "cadence.arm", target: "graphmap" }),
    headers: { ...H, Origin: `http://127.0.0.1:${port}`, "Content-Type": "application/json" } });
  expect(r.status).toBe(409);
  expect((await feed(port)).status).toBe(200); // still the cached run
  expect(readFileSync(count, "utf8").split("\n").filter(Boolean).length).toBe(1);
});

// app.js is a browser module; run it against stubs and drive loadFeed directly.
test("page: a slower, older feed load never repaints over a newer one", async () => {
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8")
    .replace(/^import .*$/gm, "").concat("\nglobalThis.__loadFeed = loadFeed;\n");
  const painted: string[] = [];
  const el = () => ({ textContent: "", innerHTML: "", hidden: false, focus() {}, setSelectionRange() {} });
  const waiting: ((b: string) => void)[] = [];
  let first = true;
  stubGlobals({
    ...APP_IMPORT_STUBS,
    render: (f: { id?: string } | null) => { if (f) painted.push(f.id ?? "?"); return ""; }, renderNav: () => "",
    document: { querySelector: el, querySelectorAll: () => [], getElementById: el, activeElement: null, addEventListener() {} },
    location: { hash: "", pathname: "/", search: "" }, history: { replaceState() {} },
    // the rail (nav.js) and its fleet read are not under test here, nor is the read-only mode probe or the vm form's or the report settings' or the review gate's or the fleet cap's or the setup read (Configure's onVisit) or the tracker sources' read: none may take the feed's fetch slot.
    fetch: (url: string) => url === "/api/agui/fleet" || url === "/api/mode" || url === "/api/vm" || url === "/api/review-gate" || url === "/api/fleet-cap" || url === "/api/report-settings" || url === "/api/setup" || url === "/api/sources" || url === "/api/api-roles" ? Promise.resolve({ status: 401, ok: false, json: async () => ({ error: "stub" }) }) : new Promise((res) => {
      const ok = (b: string) => res({ status: 200, ok: true, json: async () => ({ id: b }) });
      if (first) { first = false; ok("initial"); } else waiting.push(ok);
    }),
  }, ["__loadFeed"]);
  new Function(src)();
  await sleep(20);
  const load = (globalThis as Record<string, unknown>).__loadFeed as () => Promise<void>;
  const a = load(), b = load(); // two actions each start a re-probe
  await sleep(20);
  waiting[1]("newer"); await b;
  waiting[0]("older"); await a; // the older report lands last
  expect(painted).toEqual(["initial", "newer"]);
});

test("page: a repaint after a review gate control changes puts the focus back on that control", async () => {
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8")
    .replace(/^import .*$/gm, "").concat("\nglobalThis.__paint = paint;\n");
  const focused: string[] = [];
  const ctl = (rg: string, slug: string) => ({ dataset: { rg, slug }, matches: (q: string) => q === "[data-rg]", focus() { focused.push(`${rg}:${slug}`); } });
  const rendered = [ctl("mode", "codex"), ctl("required", "claude"), ctl("enabled", "claude")];
  const el = () => ({ textContent: "", innerHTML: "", hidden: false, focus() {}, setSelectionRange() {} });
  stubGlobals({
    ...APP_IMPORT_STUBS, renderNav: () => "",
    document: { querySelector: el, querySelectorAll: (q: string) => (q === "[data-rg]" ? rendered : []), getElementById: el, activeElement: rendered[1], addEventListener() {} },
    location: { hash: "", pathname: "/", search: "" }, history: { replaceState() {} },
    fetch: () => new Promise(() => {}),
  }, ["__paint"]);
  new Function(src)();
  focused.length = 0;
  ((globalThis as Record<string, unknown>).__paint as () => void)();
  expect(focused).toEqual(["required:claude"]);
});

// before: the path field as the page holds it; after: the same field as the repaint renders it from the fresh read
for (const [name, before, after, want] of [
  ["a path field the operator emptied stays empty through a repaint", { value: "", defaultValue: "/saved/path" }, "/saved/path", ""],
  ["a path field the operator left untouched takes the path a fresh read brings", { value: "", defaultValue: "" }, "/set/elsewhere", "/set/elsewhere"],
] as [string, { value: string; defaultValue: string }, string, string][]) test(`page: ${name}`, async () => {
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8")
    .replace(/^import .*$/gm, "").concat("\nglobalThis.__paint = paint;\n");
  const emptied = { dataset: { path: "handover-root" }, ...before, selectionStart: 0, selectionEnd: 0 };
  const repainted = { value: after, focus() {}, setSelectionRange() {} };
  const el = () => ({ textContent: "", innerHTML: "", hidden: false, focus() {}, setSelectionRange() {} });
  stubGlobals({
    ...APP_IMPORT_STUBS, renderNav: () => "",
    document: { querySelector: (q: string) => (q === 'input[data-path="handover-root"]' ? repainted : el()), querySelectorAll: (q: string) => (q.startsWith("input[data-secret]") ? [emptied] : []), getElementById: el, activeElement: null, addEventListener() {} },
    location: { hash: "", pathname: "/", search: "" }, history: { replaceState() {} },
    fetch: () => new Promise(() => {}),
  }, ["__paint"]);
  new Function(src)();
  ((globalThis as Record<string, unknown>).__paint as () => void)();
  expect(repainted.value).toBe(want);
});

test("page: a failed setup refresh keeps the last good setup and says so, instead of replacing the forms with an error", async () => {
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8")
    .replace(/^import .*$/gm, "").concat("\nglobalThis.__loadSetup = loadSetup;\nglobalThis.__setup = () => setup;\n");
  const toastEl = { textContent: "", hidden: true };
  const el = () => ({ textContent: "", innerHTML: "", hidden: false, focus() {}, setSelectionRange() {} });
  let failing = false;
  stubGlobals({
    ...APP_IMPORT_STUBS, renderNav: () => "",
    document: { querySelector: (q: string) => (q === "#toast" ? toastEl : el()), querySelectorAll: () => [], getElementById: el, activeElement: null, addEventListener() {} },
    location: { hash: "", pathname: "/", search: "" }, history: { replaceState() {} },
    fetch: (url: string) => (url === "/api/setup"
      ? Promise.resolve(failing ? { ok: false, status: 500, json: async () => ({}) } : { ok: true, status: 200, json: async () => ({ secrets: [] }) })
      : new Promise(() => {})),
  }, ["__loadSetup", "__setup"]);
  const g = globalThis as Record<string, unknown>;
  new Function(src)();
  await sleep(20);
  await (g.__loadSetup as () => Promise<void>)();
  failing = true;
  await (g.__loadSetup as () => Promise<void>)();
  const kept = (g.__setup as () => unknown)();
  expect(kept).toEqual({ secrets: [] });
  expect(toastEl.textContent).toContain("setup failed (500)");
});

test("the server refuses to start when a route budget would outlast idleTimeout", () => {
  const env = { PATH: process.env.PATH, HOME: tmpdir() };
  expect(() => startServer({ onIdle: () => {}, port: 0, token: TOKEN, env, reprobeBudgetMs: 120_000 } as never)).toThrow(/idleTimeout/);
  const ok = startServer({ onIdle: () => {}, port: 0, token: TOKEN, env });
  stops.push(() => ok.stop());
});

test("a server idle after a feed still exits on time (an in-flight report does not leak the idle guard)", async () => {
  let idled = false;
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "800", STUB_FEED_SLEEP: "300" }, { onIdle: () => { idled = true; } });
  expect((await feed(port)).status).toBe(200);
  await sleep(2000);
  expect(idled).toBe(true);
});

// the Health picker lives in the page bar (the top of #main) only on the Health page, and a refreshed feed re-reads it (no route change).
type PickerHarness = { main: () => string; refresh: () => Promise<void>; seed: (f: object) => void; go: (hash: string) => void; setFail: (n: number) => void };
async function pickerHarness(hash: string, run: (h: PickerHarness) => Promise<void>) {
  const { parseView, projectVerdict, chiefLiveFor } = await import("../public/health.js");
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8")
    .replace(/^import .*$/gm, "").concat("\nglobalThis.__refresh = refreshFeed;\nglobalThis.__seed = (f) => { feed = f; };\nglobalThis.__route = route;\n");
  let fail = 0, main = "";
  const el = () => ({ textContent: "", innerHTML: "", hidden: false, focus() {}, setSelectionRange() {} });
  const mainEl = { textContent: "", hidden: false, focus() {}, setSelectionRange() {}, set innerHTML(v: string) { main = v; }, get innerHTML() { return main; } };
  const loc = { hash, pathname: "/", search: "" };
  const g = globalThis as Record<string, unknown>;
  const json = (b: object) => Promise.resolve({ status: 200, ok: true, json: async () => b });
  stubGlobals({
    ...APP_IMPORT_STUBS, renderNav: () => "", parseView, projectVerdict, chiefLiveFor,
    document: { querySelector: (q: string) => (q === "#main" ? mainEl : el()), querySelectorAll: () => [], getElementById: el, activeElement: null, addEventListener() {} },
    location: loc, history: { replaceState() {} }, addEventListener() {},
    fetch: (url: string) => url === "/api/projects" ? json({ current: "himmel", projects: [{ name: "himmel", checkedAt: "2026-10-31T00:00:00Z", counts: { project: { fail, warn: 0 } } }] })
      : url === "/api/feed" ? json({ generatedAt: "2" }) : new Promise(() => {}),
  }, ["__refresh", "__seed", "__route"]);
  new Function(src)();
  await sleep(20);
  await run({ main: () => main, refresh: g.__refresh as () => Promise<void>, seed: g.__seed as (f: object) => void,
    go: (h) => { loc.hash = h; (g.__route as () => void)(); }, setFail: (n) => { fail = n; } });
}

test("page: a refreshed feed changes the picker's verdict word with no route change", async () => {
  await pickerHarness("#/health", async (h) => {
    expect(h.main()).toContain("himmel · All clear");
    h.seed({ generatedAt: "1" });
    h.setFail(1);
    await h.refresh();
    await sleep(20);
    expect(h.main()).toContain("himmel · Act now");
    expect(h.main()).not.toContain("All clear");
  });
});

test("page: the picker is gone from the rail once the reader leaves Health", async () => {
  await pickerHarness("#/health", async (h) => {
    expect(h.main()).toContain('id="proj"');
    h.go("#/config");
    expect(h.main()).not.toContain('id="proj"');
  });
});

// A row that times out must leave no global stub behind. The forced row exists only in the child run below; the guard
// after it fails when the timed-out row's stubs are still set (every ordinary run holds the guard to the rows above too).
if (FORCE_TIMEOUT) test("FORCED-TIMEOUT page row stubs globals, then never resolves", async () => {
  stubGlobals({ fetch: () => new Promise(() => {}), render: () => "", document: { querySelector: () => null } });
  await new Promise(() => {});
}, 200);

test("STUB-LEAK-GUARD no harness global stub is left set by an earlier row", () => {
  const g = globalThis as Record<string, unknown>;
  const leaked = [...touched].filter(([n, o]) => (o.had ? g[n] !== o.value : n in g)).map(([n]) => n);
  expect(leaked).toEqual([]);
});

test.skipIf(FORCE_TIMEOUT)("a row that times out leaves no harness stub set (child bun run with a forced timeout)", () => {
  const r = spawnSync(process.execPath, ["test", import.meta.path, "-t", "FORCED-TIMEOUT|STUB-LEAK-GUARD"], {
    env: { ...process.env, SLOW_FORCE_TIMEOUT: "1" }, encoding: "utf8", timeout: 60_000,
  });
  const out = String(r.stdout) + String(r.stderr);
  expect(out).toMatch(/\(fail\) FORCED-TIMEOUT/); // the row did time out
  expect(out).not.toMatch(/\(fail\) STUB-LEAK-GUARD/); // and left nothing behind
  expect(out).toMatch(/\b1 pass\b/); // the guard ran (bun prints no line for a passing row)
}, 70_000);
