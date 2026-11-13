// GET /api/board: the Board page's saved status-drift summary and chain read. Both are read-only chief-kit
// scripts, started only when their input is found: named in the settings (environment, himmel.conf, the checkout's .env)
// or the newest file of that name under the handover root. Everything here lives in a scratch directory, the checkout root included.
import { test, expect, afterEach, mock } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import childProcess from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { DRIFT_BUDGET_S, DRIFT_REFRESH_MS, readBoardExtras, readOwed, refreshDrift, runReader, TIMEOUT_MS } from "../board";
import { renderBoard } from "../public/roadmap.js";

const TOKEN = "a".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const mirrorIssue = (n: number, status: string, cat: string, blockedBy: string[], title: string) =>
  ["---", `key: "HIMMEL-${n}"`, `type: "Task"`, `status: ${JSON.stringify(status)}`, `statusCategory: ${JSON.stringify(cat)}`, `priority: "Medium"`,
    `labels: []`, `fixVersions: ["v1.1.3"]`, `parent: null`, `created: "2026-10-01T00:00:00.000+0000"`, `updated: "2026-10-02T00:00:00.000+0000"`,
    `resolution: null`, "links:", "  blocks: []", `  blocked_by: ${JSON.stringify(blockedBy)}`, "  relates: []", "---", "", `# HIMMEL-${n}: ${title}`, "",
    "## Description", "", "x", "", "## Comments", "", "_(none)_", ""].join("\n");

function scratch() {
  const d = mkdtempSync(join(tmpdir(), "board-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const home = join(d, "home"), mirror = join(d, "state", "jira-mirror", "HIMMEL"), conf = join(d, "conf");
  for (const p of [home, mirror, conf]) mkdirSync(p, { recursive: true });
  writeFileSync(join(mirror, "HIMMEL-1.md"), mirrorIssue(1, "Done", "Done", [], "First step"));
  writeFileSync(join(mirror, "HIMMEL-2.md"), mirrorIssue(2, "To Do", "To Do", ["HIMMEL-1"], "Second step"));
  const registry = join(d, "registry.json");
  writeFileSync(registry, JSON.stringify({ schema: "himmel.chain-registry/1", chains: [{ id: "memory", goal: "Memory guard rework chain", members: ["HIMMEL-1", "HIMMEL-2"] }] }));
  const drift = join(d, "focus-drift.txt");
  writeFileSync(drift, "VERSION-DRIFT HIMMEL-6691 Done in v1.1.4, current v1.1.3 | writer=release-manager | fix=jira release request v1.1.3\nsdrift=1:abc\n");
  const known = join(d, "known.tsv");
  writeFileSync(known, "# checker\tclass\tkey\tedited-at\n");
  return { d, home, mirror, conf, registry, drift, known };
}
const serve = (env: Record<string, string>, s: ReturnType<typeof scratch>) => {
  const srv = startServer({ onIdle: () => {},
    port: 0, token: TOKEN, root: s.d, legsScript: join(s.d, "no-workers.sh"), // root: the checkout's .env is read from the scratch dir, never the real one
    env: { PATH: process.env.PATH, HOME: s.home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000",
      HIMMEL_JIRA_MIRROR: s.mirror, HIMMEL_CONFIG_DIR: s.conf, DRIFT_SUMMARY_KNOWN: s.known, ...env },
  });
  cleanups.push(() => srv.stop());
  return `http://127.0.0.1:${srv.port}/api/board`;
};
const get = async (url: string) => (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
// every file under d with its size and mtime: a read must leave this unchanged
const snapshot = (dir: string): string[] => readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  const p = join(dir, e.name);
  return e.isDirectory() ? snapshot(p) : [`${p} ${statSync(p).size} ${statSync(p).mtimeMs}`];
}).sort();

// POST /api/board/drift-refresh: the one write Tidy up makes. It runs the report-only check and replaces the saved file only on a clean last line.
const refresh = (url: string, token = TOKEN) => fetch(`${url}/drift-refresh`, { method: "POST", headers: { "X-Himmel-Token": token, origin: new URL(url).origin, "content-type": "application/json" }, body: "{}" });
const stubCheck = (s: ReturnType<typeof scratch>, body: string) => {
  const check = join(s.d, "check.sh"), calls = join(s.d, "calls");
  writeFileSync(check, `echo run >> ${JSON.stringify(calls)}\n${body}\n`);
  return { check, runs: () => { try { return readFileSync(calls, "utf8").split("\n").filter(Boolean).length; } catch { return 0; } } };
};
const NEW_RUN = `echo 'UNOWNED HIMMEL-77 no owner | writer=sweep | fix=none'; echo 'sdrift=1:newrun'`;

test("POST drift-refresh: with the token it runs the check once and the next read returns the new run; without it nothing runs", async () => {
  const s = scratch();
  const { check, runs } = stubCheck(s, NEW_RUN);
  const url = serve({ HIMMEL_FOCUS_DRIFT: s.drift, CONFIG_UI_DRIFT_CHECK: check }, s);
  expect((await refresh(url, "b".repeat(64))).status).toBe(401);
  expect(runs()).toBe(0);
  expect((await fetch(`${url}/drift-refresh`, { headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  expect(runs()).toBe(0);
  const r = await refresh(url);
  expect(r.status).toBe(200);
  expect(await r.json()).toEqual({ state: "ok", sdrift: "1:newrun" });
  expect(runs()).toBe(1);
  const after = await get(url);
  expect(after.drift.sdrift).toBe("1:newrun");
  expect(after.drift.real.map((x: { key: string }) => x.key)).toEqual(["HIMMEL-77"]);
  expect(readdirSync(s.d).filter((f) => f.includes(".tmp"))).toEqual([]); // the stage file became the saved file
});

test("GET /api/board leaves the saved drift file and the check's call count unchanged", async () => {
  const s = scratch();
  const { check, runs } = stubCheck(s, NEW_RUN);
  const url = serve({ HIMMEL_FOCUS_DRIFT: s.drift, CONFIG_UI_DRIFT_CHECK: check }, s);
  const before = snapshot(s.d);
  await get(url);
  expect(snapshot(s.d)).toEqual(before);
  expect(runs()).toBe(0);
});

test("POST drift-refresh: a run that does not end clean keeps the saved file byte for byte and says why", async () => {
  for (const [body, why] of [
    ["echo 'UNOWNED HIMMEL-77 half | writer=x | fix=y'; echo 'sdrift=unknown'", "could not read"],
    ["echo 'UNOWNED HIMMEL-77 half | writer=x | fix=y'", "no sdrift line"],
    ["echo 'sdrift=1:newrun'; echo boom >&2; exit 3", "boom"],
  ]) {
    const s = scratch();
    const { check } = stubCheck(s, body);
    const url = serve({ HIMMEL_FOCUS_DRIFT: s.drift, CONFIG_UI_DRIFT_CHECK: check }, s);
    const before = snapshot(s.d).filter((l) => l.includes("focus-drift")), text = readFileSync(s.drift, "utf8");
    const j = await (await refresh(url)).json();
    expect(j.state).toBe("failed");
    expect(j.reason).toContain(why);
    expect(readFileSync(s.drift, "utf8")).toBe(text);
    expect(snapshot(s.d).filter((l) => l.includes("focus-drift"))).toEqual(before);
    expect(readdirSync(s.d).filter((f) => f.includes(".tmp"))).toEqual([]);
  }
});

test("refreshDrift: the check gets a budget that ends before the route's own limit", async () => {
  const s = scratch();
  const { check } = stubCheck(s, `echo "sdrift=0:$TICKET_STATUS_DRIFT_BUDGET"`);
  const r = await refreshDrift({ PATH: process.env.PATH, HOME: s.home, HIMMEL_FOCUS_DRIFT: s.drift, CONFIG_UI_DRIFT_CHECK: check }, s.d);
  expect(r).toEqual({ state: "ok", sdrift: `0:${DRIFT_BUDGET_S}` });
  expect(DRIFT_BUDGET_S * 1000).toBeLessThan(DRIFT_REFRESH_MS);
});

test("refreshDrift: a run past its limit is killed, keeps the saved file and says so", async () => {
  const s = scratch();
  const { check } = stubCheck(s, "sleep 30");
  const text = readFileSync(s.drift, "utf8");
  const r = await refreshDrift({ PATH: process.env.PATH, HOME: s.home, HIMMEL_FOCUS_DRIFT: s.drift, CONFIG_UI_DRIFT_CHECK: check }, s.d, 200);
  expect(r).toMatchObject({ state: "failed" });
  expect((r as { reason: string }).reason).toContain("limit");
  expect(readFileSync(s.drift, "utf8")).toBe(text);
});

test("POST drift-refresh: a second click while a run is in flight joins it, and one audit row names the run", async () => {
  const s = scratch();
  const { check, runs } = stubCheck(s, `sleep 0.3; ${NEW_RUN}`);
  const url = serve({ HIMMEL_FOCUS_DRIFT: s.drift, CONFIG_UI_DRIFT_CHECK: check }, s);
  const [a, b] = await Promise.all([refresh(url), refresh(url)]);
  expect(await a.json()).toEqual(await b.json());
  expect(runs()).toBe(1);
  const rows = readFileSync(join(s.home, ".himmel", "state", "config-ui", "actions.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((l) => l.action === "board.drift-refresh");
  expect(rows).toHaveLength(1);
  expect(rows[0]).toMatchObject({ rc: 0, target: s.drift });
});

test("POST drift-refresh: refused in words, and nothing runs, on another tracker or with nowhere to save the run", async () => {
  const s = scratch();
  const { check, runs } = stubCheck(s, NEW_RUN);
  const local = await refresh(serve({ TRACKER: "local", HIMMEL_FOCUS_DRIFT: s.drift, CONFIG_UI_DRIFT_CHECK: check }, s));
  expect(local.status).toBe(403);
  expect((await local.json()).error).toContain("not Jira");
  const none = await refresh(serve({ CONFIG_UI_DRIFT_CHECK: check }, s));
  expect(await none.json()).toMatchObject({ state: "failed", reason: expect.stringContaining("HIMMEL_FOCUS_DRIFT") });
  expect(runs()).toBe(0);
});

test("GET /api/roadmap/history marks a move by himmel's Jira account and never answers with the address", async () => {
  const s = scratch();
  const cli = join(s.d, "jira-stub.js");
  writeFileSync(cli, `process.stdout.write(JSON.stringify([
    { created: "2026-10-01T10:00:00.000+0000", author: { displayName: "Hima", emailAddress: "Himmel@Example.test" }, items: [{ field: "status", fromString: "To Do", toString: "In Progress" }] },
    { created: "2026-10-02T10:00:00.000+0000", author: { displayName: "Ana", emailAddress: "ana@example.test" }, items: [{ field: "status", fromString: "In Progress", toString: "Done" }] },
    { created: "2026-10-03T10:00:00.000+0000", author: { displayName: "Hidden" }, items: [{ field: "status", fromString: "Done", toString: "To Do" }] },
  ]));`);
  const url = serve({ TRACKER: "jira", JIRA_PROJECT_KEY: "HIMMEL", JIRA_EMAIL: "himmel@example.test", CONFIG_UI_JIRA_CLI: cli }, s);
  const r = await fetch(url.replace("/api/board", "/api/roadmap/history?key=HIMMEL-1"), { headers: { "X-Himmel-Token": TOKEN } });
  const text = await r.text();
  expect(r.status).toBe(200);
  const events = JSON.parse(text).events as { who: string; himmel?: boolean }[];
  expect(events.map((e) => [e.who, e.himmel === true])).toEqual([["Hima", true], ["Ana", false], ["Hidden", false]]);
  expect(text).not.toContain("example.test");
});

test("GET /api/board: token-gated, GET-only; with no input named both reads are absent with the reason and nothing is spawned", async () => {
  const s = scratch();
  const url = serve({}, s);
  expect((await fetch(url)).status).toBe(401);
  expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  const r = await get(url);
  expect(r.drift.state).toBe("absent");
  expect(r.drift.reason).toContain("HIMMEL_FOCUS_DRIFT");
  expect(r.chains.state).toBe("absent");
  expect(r.chains.reason).toContain("HIMMEL_CHAIN_REGISTRY");
  expect(r.drift.counts).toBeUndefined(); // no count is invented
});

// A running version, two linked chains and a blocker outside the version: the read runs with --version and adds the burn-down from the merge rows.
test("GET /api/board: the chain read runs on the running version, so a blocker outside it reads blocked, and carries one burn-down point per day", async () => {
  const s = scratch();
  const put = (n: number, status: string, cat: string, by: string[], title: string, fv = "v1.1.3") => writeFileSync(join(s.mirror, `HIMMEL-${n}.md`), mirrorIssue(n, status, cat, by, title).replace("v1.1.3", fv));
  put(6, "To Do", "To Do", ["HIMMEL-2"], "Linked across chains");
  put(7, "To Do", "To Do", ["HIMMEL-21"], "Blocked from outside");
  put(8, "Done", "Done", [], "Done with no merge row");
  put(21, "To Do", "To Do", [], "Next version work", "v1.1.4");
  writeFileSync(s.mirror + ".versions.tsv", "v1.1.3\tfalse\t\nv1.1.4\tfalse\t\n");
  writeFileSync(s.registry, JSON.stringify({ schema: "himmel.chain-registry/1", chains: [{ id: "memory", goal: "Memory guard rework chain", members: ["HIMMEL-1", "HIMMEL-2", "HIMMEL-8"] }, { id: "ops", goal: "Ops cleanup chain", members: ["HIMMEL-6", "HIMMEL-7"] }] }));
  const st = join(s.d, "chain-state");
  mkdirSync(st);
  writeFileSync(join(st, "status-events.jsonl"), JSON.stringify({ ts: "2026-10-30T10:00:00Z", event: "merge", key: "HIMMEL-1", pr: "7", contract: "yes", result: "moved" }) + "\n");
  writeFileSync(join(st, "chain-log.jsonl"), JSON.stringify({ ts: "2026-10-29T10:00:00Z", change: "hold", key: "HIMMEL-6", kind: "operator", who: "chief", reason: "freeze" }) + "\n" + JSON.stringify({ ts: "2026-10-29T11:00:00Z", change: "release", key: "HIMMEL-6", who: "chief" }) + "\n");
  const r = (await get(serve({ HIMMEL_CHAIN_REGISTRY: s.registry, TICKET_STATUS_STATE_DIR: st }, s))).versionChains;
  expect(r.version).toBe("v1.1.3");
  expect(r.tickets["HIMMEL-7"].state).toBe("blocked");
  expect(r.tickets["HIMMEL-7"].links[0]).toMatchObject({ on: "HIMMEL-21", status: "open" });
  // already passed through on base, pinned here because the page draws them
  expect(r.chains.find((c: { id: string }) => c.id === "ops").across[0]).toMatchObject({ dir: "waits-on", key: "HIMMEL-6", on: "HIMMEL-2", chains: ["memory"] });
  expect(r.chains.find((c: { id: string }) => c.id === "ops").log).toHaveLength(2);
  const days = r.burn.points.map((p: { day: string }) => p.day);
  expect(days[0]).toBe("2026-10-30");
  expect(days.at(-1)).toBe(r.now.slice(0, 10));
  expect(new Set(days).size).toBe(days.length);
  expect(r.burn.points[0]).toEqual({ day: "2026-10-30", open: 3, merged: 1 }); // tickets 2, 6, 7 are open; 8 is done and undated, so it leaves the total
  expect(r.burn).toMatchObject({ total: 4, undated: 1 });
});

test("GET /api/board: with no running version the chain read runs on no version and there is no burn-down point", async () => {
  const s = scratch();
  writeFileSync(join(s.mirror, "HIMMEL-2.md"), mirrorIssue(2, "Done", "Done", [], "Second step"));
  const r = (await get(serve({ HIMMEL_CHAIN_REGISTRY: s.registry, TICKET_STATUS_STATE_DIR: join(s.d, "no-state") }, s))).versionChains;
  expect(r.version).toBeNull();
  expect(r.burn).toEqual({ total: 0, undated: 2, points: [] });
});

// The whole path with nothing set by hand: an operator hold in the chain log and an operator label in the mirror, read by the server's
// two reads and drawn by the page. An unreadable chain log must read "not read" on the page, never as nobody waiting.
test("Board page: a live operator hold and an operator label in the mirror both reach Waiting on you; an unreadable chain log reads as not read", async () => {
  const s = scratch();
  writeFileSync(join(s.mirror, "HIMMEL-9.md"), mirrorIssue(9, "To Do", "To Do", [], "Labelled and in no chain").replace("labels: []", 'labels: ["operator-decision"]'));
  writeFileSync(s.mirror + ".versions.tsv", "v1.1.3\tfalse\t\n");
  const st = join(s.d, "chain-state");
  mkdirSync(st);
  writeFileSync(join(st, "chain-log.jsonl"), JSON.stringify({ ts: "2026-10-29T10:00:00Z", change: "hold", key: "HIMMEL-2", kind: "operator", who: "chief", reason: "decide" }) + "\n");
  const env = { HIMMEL_CHAIN_REGISTRY: s.registry, TICKET_STATUS_STATE_DIR: st };
  const ui = { version: null, theme: null, v: "all" };
  const page = async (base: string) => renderBoard(await get(base.replace("/api/board", "/api/roadmap")), ui, await get(base));
  const html = await page(serve(env, s));
  const sec = html.match(/<section id="rm-waiting"[\s\S]*?<\/section>/)![0];
  expect(sec).toContain("HIMMEL-2");
  expect(sec).toContain("memory 2/2"); // the hold, from chain-log.jsonl through chain-state.mjs
  expect(sec).toContain('href="#/board?tab=chains&amp;v=all&amp;at=HIMMEL-2"');
  expect(sec).toContain("HIMMEL-9"); // the label, from the mirror, in no chain
  expect(sec).toContain("operator-decision");
  expect(sec).not.toContain("at=HIMMEL-9"); // the Chains tab does not hold it, so the key is not a link
  expect(html).toContain("2 tickets wait for you");
  rmSync(join(st, "chain-log.jsonl"));
  mkdirSync(join(st, "chain-log.jsonl")); // there, but not a file: unreadable
  const bad = await page(serve(env, s));
  expect(bad).toContain("chain holds not read");
  const badSec = bad.match(/<section id="rm-waiting"[\s\S]*?<\/section>/)![0];
  expect(badSec).toContain("HIMMEL-9"); // the label still lists
  expect(badSec).not.toContain("HIMMEL-2"); // the hold is not guessed at: nothing of it is listed or linked
  expect(bad).toContain("1 ticket waits for you");
  expect(bad).not.toContain("2 tickets wait for you");
});

test("GET /api/board: the saved drift file and the chain registry named in the environment are read through the chief-kit scripts", async () => {
  const s = scratch();
  const r = await get(serve({ HIMMEL_FOCUS_DRIFT: s.drift, HIMMEL_CHAIN_REGISTRY: s.registry }, s));
  expect(r.drift.counts).toEqual({ real: 1, known: 0, transient: 0, waiting: 0, exempt: 0 });
  expect(r.drift.real[0]).toMatchObject({ class: "VERSION-DRIFT", key: "HIMMEL-6691" });
  expect(r.drift.mode).toBe("single-user");
  expect(r.chains.schema).toBe("himmel.chains/1");
  expect(r.chains.chains.map((c: { id: string }) => c.id)).toEqual(["memory"]);
  expect(r.chains.tickets["HIMMEL-2"].state).toBe("can launch"); // its only blocker is Done
  expect(r.chains.tickets["HIMMEL-1"].chains[0]).toMatchObject({ id: "memory", step: 1, steps: 2 });
});

test("GET /api/board: the drift file also comes from TRACKER_HANDOVERS_DIR/focus-drift.txt", async () => {
  const s = scratch();
  const r = await get(serve({ TRACKER_HANDOVERS_DIR: s.d }, s));
  expect(r.drift.counts.real).toBe(1);
});

test("GET /api/board: with no override the saved drift run and chain registry come from the handover root's own layout", async () => {
  const s = scratch();
  const root = join(s.d, "handovers");
  mkdirSync(join(root, "someone", "himmel"), { recursive: true });
  writeFileSync(join(root, "someone", "himmel", "focus-drift.txt"), readFileSync(s.drift));
  writeFileSync(join(root, "someone", "himmel", "chains.json"), readFileSync(s.registry));
  const r = await get(serve({ HANDOVER_DIR: root }, s));
  expect(r.drift.counts.real).toBe(1);
  expect(r.chains.chains.map((c: { id: string }) => c.id)).toEqual(["memory"]);
  // an empty handover root, or one with no such files, still reads absent
  const empty = join(s.d, "empty-root");
  mkdirSync(join(empty, "someone", "himmel"), { recursive: true });
  const none = await get(serve({ HANDOVER_DIR: empty }, s));
  expect(none.drift.state).toBe("absent");
  expect(none.chains.state).toBe("absent");
});

// a handover root with one slug holding focus-drift.txt with `rows` drift rows (the count tells which slug was read)
function slugWithDrift(root: string, slug: string, rows: number, mtime?: Date) {
  mkdirSync(join(root, slug, "himmel"), { recursive: true });
  const file = join(root, slug, "himmel", "focus-drift.txt");
  writeFileSync(file, Array.from({ length: rows }, (_, i) => `VERSION-DRIFT HIMMEL-${6000 + i} says x | writer=release-manager | fix=jira release request v1.1.3`).join("\n") + "\nsdrift=1:abc\n");
  if (mtime) utimesSync(file, mtime, mtime);
}

test("GET /api/board: with several slugs under the handover root the newest file is read", async () => {
  const s = scratch();
  const root = join(s.d, "handovers");
  slugWithDrift(root, "newer", 2, new Date("2026-11-02T10:00:00Z"));
  slugWithDrift(root, "older", 1, new Date("2026-10-01T10:00:00Z"));
  mkdirSync(join(root, "no-file", "himmel"), { recursive: true }); // a slug without the file is skipped
  expect((await get(serve({ HANDOVER_DIR: root }, s))).drift.counts.real).toBe(2);
});

test("GET /api/board: the newest file wins whichever of two slugs readdir lists first (the mtimes swapped)", async () => {
  const s = scratch();
  const root = join(s.d, "handovers");
  slugWithDrift(root, "older", 1, new Date("2026-11-02T10:00:00Z"));
  slugWithDrift(root, "newer", 2, new Date("2026-10-01T10:00:00Z"));
  expect((await get(serve({ HANDOVER_DIR: root }, s))).drift.counts.real).toBe(1); // "older" is the newer file here
  slugWithDrift(root, "older", 1, new Date("2026-10-01T10:00:00Z"));
  slugWithDrift(root, "newer", 2, new Date("2026-11-02T10:00:00Z"));
  expect((await get(serve({ HANDOVER_DIR: root }, s))).drift.counts.real).toBe(2);
});

test("GET /api/board: an explicit HIMMEL_FOCUS_DRIFT wins over the handover root's file", async () => {
  const s = scratch();
  const root = join(s.d, "handovers");
  slugWithDrift(root, "someone", 2);
  const r = await get(serve({ HANDOVER_DIR: root, HIMMEL_FOCUS_DRIFT: s.drift }, s)); // s.drift holds one row
  expect(r.drift.counts.real).toBe(1);
});

test("GET /api/board: a bare launch finds the handover root in himmel.conf or the checkout's .env, as /api/health does; the process env wins", async () => {
  const s = scratch();
  const viaConf = join(s.d, "conf-root"), viaDotenv = join(s.d, "dotenv-root"), viaEnv = join(s.d, "env-root");
  slugWithDrift(viaConf, "someone", 1);
  slugWithDrift(viaDotenv, "someone", 2);
  slugWithDrift(viaEnv, "someone", 3);
  mkdirSync(join(s.home, ".himmel"), { recursive: true });
  writeFileSync(join(s.home, ".himmel", "himmel.conf"), `HANDOVER_DIR=${viaConf}\n`);
  expect((await get(serve({}, s))).drift.counts.real).toBe(1); // only the conf layer names it
  writeFileSync(join(s.home, ".himmel", "himmel.conf"), "");
  writeFileSync(join(s.d, ".env"), `HANDOVER_DIR=${viaDotenv}\n`);
  expect((await get(serve({}, s))).drift.counts.real).toBe(2); // only the checkout's .env names it
  writeFileSync(join(s.home, ".himmel", "himmel.conf"), `HANDOVER_DIR=${viaConf}\n`);
  expect((await get(serve({ HANDOVER_DIR: viaEnv }, s))).drift.counts.real).toBe(3); // the process env beats both
});

// a Jira mirror whose two cards carry `label` in their titles, at dir
function otherMirror(dir: string, label: string) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "HIMMEL-1.md"), mirrorIssue(1, "To Do", "To Do", [], `First card ${label}`));
  writeFileSync(join(dir, "HIMMEL-2.md"), mirrorIssue(2, "To Do", "To Do", ["HIMMEL-1"], `Second card ${label}`));
}

// the cards (/api/roadmap) and the chains (/api/board) must come from the same mirror when the process env names none
test("GET /api/board and /api/roadmap read the same Jira mirror when it is set only in the checkout's .env", async () => {
  const s = scratch();
  const other = join(s.d, "dotenv-mirror");
  otherMirror(other, "from the .env mirror");
  writeFileSync(join(s.d, ".env"), `HIMMEL_JIRA_MIRROR=${other}\n`);
  const url = serve({ HIMMEL_JIRA_MIRROR: "", HIMMEL_CHAIN_REGISTRY: s.registry }, s);
  expect((await get(url)).chains.tickets["HIMMEL-1"].title).toBe("First card from the .env mirror");
  expect(JSON.stringify(await get(url.replace("/api/board", "/api/roadmap")))).toContain("First card from the .env mirror");
  expect((await get(url.replace("/api/board", "/api/sources"))).sources).toEqual(["jira"]); // the rail stays lit
});

test("GET /api/board: the extras are absent when only the project's .env says the tracker is none", async () => {
  const s = scratch();
  writeFileSync(join(s.d, ".env"), "TRACKER=none\n");
  const r = await get(serve({ HIMMEL_FOCUS_DRIFT: s.drift, HIMMEL_CHAIN_REGISTRY: s.registry }, s));
  expect(r.drift.state).toBe("absent");
  expect(r.drift.reason).toContain("not Jira");
  expect(r.chains.reason).toContain("not Jira");
});

test("a project launched from another checkout: the extras and the cards read the project's mirror, and the handover root still comes from the checkout's settings", async () => {
  const s = scratch();
  const checkout = join(s.d, "checkout"), project = join(s.d, "project"), handovers = join(s.d, "handovers");
  mkdirSync(checkout); mkdirSync(project);
  slugWithDrift(handovers, "someone", 1);
  otherMirror(join(s.d, "checkout-mirror"), "from the checkout mirror");
  otherMirror(join(s.home, ".himmel", "state", "jira-mirror", "HIMMEL"), "from the default mirror"); // what the project, naming none, gets
  writeFileSync(join(checkout, ".env"), `HIMMEL_JIRA_MIRROR=${join(s.d, "checkout-mirror")}\nJIRA_PROJECT_KEY=OTHER\nHANDOVER_DIR=${handovers}\n`);
  const srv = startServer({ onIdle: () => {}, port: 0, token: TOKEN, root: checkout, projectRoot: project, legsScript: join(s.d, "no-workers.sh"),
    env: { PATH: process.env.PATH, HOME: s.home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000",
      HIMMEL_CONFIG_DIR: s.conf, DRIFT_SUMMARY_KNOWN: s.known, HIMMEL_CHAIN_REGISTRY: s.registry } });
  cleanups.push(() => srv.stop());
  const base = `http://127.0.0.1:${srv.port}`;
  const board = await get(`${base}/api/board`);
  const roadmap = JSON.stringify(await get(`${base}/api/roadmap`));
  expect(board.drift.counts.real).toBe(1); // the handover root: the checkout's settings, as /api/health reads them
  expect(board.chains.tickets["HIMMEL-1"].title).toBe("First card from the default mirror");
  expect(roadmap).toContain("First card from the default mirror"); // the cards come from the same mirror
  expect(roadmap).not.toContain("checkout mirror");
});

test("GET /api/roadmap: a non-empty process env mirror beats the checkout's .env", async () => {
  const s = scratch();
  const other = join(s.d, "dotenv-mirror");
  otherMirror(other, "from the .env mirror");
  writeFileSync(join(s.d, ".env"), `HIMMEL_JIRA_MIRROR=${other}\n`);
  const roadmap = JSON.stringify(await get(serve({}, s).replace("/api/board", "/api/roadmap"))); // serve() puts s.mirror in the process env
  expect(roadmap).toContain("First step");
  expect(roadmap).not.toContain("from the .env mirror");
});

test("GET /api/board and /api/roadmap read the same Jira mirror when only himmel.conf sets the project key", async () => {
  const s = scratch();
  otherMirror(join(s.home, ".himmel", "state", "jira-mirror", "CONFKEY"), "from the conf project");
  // the cards enumerate the mirror root by project: this project's own ticket carries its key (the chain read still reads the HIMMEL-keyed fixture above)
  writeFileSync(join(s.home, ".himmel", "state", "jira-mirror", "CONFKEY", "CONFKEY-1.md"), mirrorIssue(1, "To Do", "To Do", [], "First card from the conf project").replaceAll("HIMMEL-1", "CONFKEY-1"));
  writeFileSync(join(s.home, ".himmel", "himmel.conf"), "JIRA_PROJECT_KEY=CONFKEY\n");
  const url = serve({ HIMMEL_JIRA_MIRROR: "", HIMMEL_CHAIN_REGISTRY: s.registry }, s);
  expect((await get(url)).chains.tickets["HIMMEL-1"].title).toBe("First card from the conf project");
  expect(JSON.stringify(await get(url.replace("/api/board", "/api/roadmap")))).toContain("First card from the conf project");
  for (const n of [1, 2]) rmSync(join(s.home, ".himmel", "state", "jira-mirror", "CONFKEY", `HIMMEL-${n}.md`)); // leave only the project's own keyed ticket: the rail must not need a HIMMEL-keyed file
  expect((await get(url.replace("/api/board", "/api/sources"))).sources).toEqual(["jira"]); // the rail stays lit
});

test("runReader: a default call hands execFile a 10 second limit", async () => {
  expect(TIMEOUT_MS).toBe(10_000);
  const s = scratch();
  const ok = join(s.d, "ok.mjs");
  writeFileSync(ok, "console.log(JSON.stringify({ fine: true }));\n");
  const seen: unknown[] = [];
  const realExecFile = childProcess.execFile as (...x: unknown[]) => unknown; // captured before the mock, which Bun may rebind through childProcess
  mock.module("node:child_process", () => ({ ...childProcess, execFile: (...a: unknown[]) => { seen.push((a[2] as { timeout?: number }).timeout); return realExecFile(...a); } }));
  const fresh = await import("../board?default-limit"); // a copy of board.ts bound to the spy
  expect(await fresh.runReader(ok, [], { PATH: process.env.PATH }, "the test reader")).toEqual({ fine: true });
  expect(seen).toEqual([10_000]);
});

test("GET /api/board: an explicit HIMMEL_CHAIN_REGISTRY wins over the handover root's file", async () => {
  const s = scratch();
  const root = join(s.d, "handovers");
  mkdirSync(join(root, "someone", "himmel"), { recursive: true });
  writeFileSync(join(root, "someone", "himmel", "chains.json"), JSON.stringify({ schema: "himmel.chain-registry/1", chains: [{ id: "other", goal: "Other", members: ["HIMMEL-1"] }] }));
  const r = await get(serve({ HANDOVER_DIR: root, HIMMEL_CHAIN_REGISTRY: s.registry }, s));
  expect(r.chains.chains.map((c: { id: string }) => c.id)).toEqual(["memory"]);
});

test("GET /api/board: a missing drift file reports exists=false, and a bad registry is absent with the reason", async () => {
  const s = scratch();
  writeFileSync(join(s.d, "bad.json"), "{}");
  const r = await get(serve({ HIMMEL_FOCUS_DRIFT: join(s.d, "none.txt"), HIMMEL_CHAIN_REGISTRY: join(s.d, "bad.json") }, s));
  expect(r.drift.file.exists).toBe(false);
  expect(r.chains.state).toBe("absent");
  expect(r.chains.reason).toContain("the chain read failed");
});

test("GET /api/board: on a tracker other than Jira the Jira-backed extras are absent even when their inputs are set", async () => {
  for (const tracker of ["none", "local"]) {
    const s = scratch();
    const r = await get(serve({ TRACKER: tracker, TRACKER_STORE: join(s.d, "store"), HIMMEL_FOCUS_DRIFT: s.drift, HIMMEL_CHAIN_REGISTRY: s.registry }, s));
    expect(r.drift.state).toBe("absent");
    expect(r.drift.reason).toContain("not Jira");
    expect(r.chains.state).toBe("absent");
    expect(r.chains.reason).toContain("no chain registry");
  }
});

test("GET /api/board: a secret-bearing value in a drift row never reaches the page", async () => {
  const s = scratch();
  writeFileSync(s.drift, "VERSION-DRIFT HIMMEL-6691 says x | writer=release-manager | fix=PLANTED_SECRET=zz-planted-not-real-0000\nsdrift=1:abc\n"); // gitleaks:allow
  const url = serve({ HIMMEL_FOCUS_DRIFT: s.drift }, s);
  const raw = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).text();
  expect(raw).toContain("redacted");
  expect(raw).not.toContain("zz-planted-not-real-0000");
});

test("runReader: a reader that outlives the limit is absent with the reason, and the child sees only the small environment", async () => {
  const s = scratch();
  const hang = join(s.d, "hang.mjs"), env = join(s.d, "env.mjs");
  writeFileSync(hang, "setInterval(() => {}, 1000);\n");
  writeFileSync(env, "console.log(JSON.stringify({ home: process.env.HOME || null, planted: process.env.PLANTED_NAME || null, keep: process.env.HIMMEL_CONFIG_DIR || null }));\n");
  const slow = await runReader(hang, [], { PATH: process.env.PATH }, "the test reader", 300);
  expect(slow.state).toBe("absent");
  expect(String(slow.reason)).toContain("the test reader failed");
  const seen = await runReader(env, [], { PATH: process.env.PATH, HOME: s.home, HIMMEL_CONFIG_DIR: s.conf, PLANTED_NAME: "leaked" }, "the test reader");
  expect(seen).toEqual({ home: s.home, planted: null, keep: s.conf });
});

test("GET /api/board is read-only: nothing under the scratch tree changes", async () => {
  const s = scratch();
  const url = serve({ HIMMEL_FOCUS_DRIFT: s.drift, HIMMEL_CHAIN_REGISTRY: s.registry }, s);
  const before = snapshot(s.d);
  await get(url);
  await get(url);
  expect(snapshot(s.d)).toEqual(before);
  expect(readFileSync(s.drift, "utf8")).toContain("sdrift=1:abc");
});

// app.js names a card by its number AND project; two projects' same-number cards do not collide, and a drop posts the card's own key.
test("5494: a drop on a SALUS card posts SALUS-1, not HIMMEL-1, though both cards are number 1", async () => {
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8");
  const block = src.slice(src.indexOf("let rmWriting = false;"), src.indexOf('document.addEventListener("dragend"'));
  expect(block).toContain("rmTicket");
  const on: Record<string, (e: unknown) => void> = {};
  const posted: { path: string; body: Record<string, unknown> }[] = [];
  const roadmap = { state: "ok", themes: ["(no sector)"], tickets: [
    { k: 1, project: "HIMMEL", id: "HIMMEL-1", b: "todo", s: "To Do", backend: "jira" }, { k: 1, project: "SALUS", id: "SALUS-1", b: "todo", s: "To Do", backend: "jira" }] };
  const post = async (path: string, body: Record<string, unknown>) => { posted.push({ path, body }); return { ok: true, j: { ok: true, status: "prog", name: "In Progress", mirror: "stale" } }; };
  new Function("roadmap", "roadmapUi", "post", "paint", "loadRoadmap", "document", "readOnly", block)(roadmap, {}, post, () => {}, () => {}, { addEventListener: (n: string, f: (e: unknown) => void) => { on[n] = f; } }, false);
  const target = (data: Record<string, string>) => ({ closest: () => ({ dataset: data }) });
  on.dragstart({ target: target({ rmCard: "1", rmProject: "SALUS" }), dataTransfer: { setData() {} } });
  on.drop({ target: target({ rmDrop: "prog" }), preventDefault() {} });
  await new Promise((r) => setTimeout(r, 0));
  expect(posted).toEqual([{ path: "/api/roadmap/write", body: { key: "SALUS-1", status: "prog" } }]);
  expect(roadmap.tickets.map((t) => t.b)).toEqual(["todo", "prog"]); // only the SALUS card moved
});

// Guard for 5494: the evaluated slice reads app.js's top-level readOnly, so a harness that withholds it must fail loudly, not pass vacuously.
test("5494 guard: the evaluated drop slice throws a ReferenceError when readOnly is not in its scope", () => {
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8");
  const block = src.slice(src.indexOf("let rmWriting = false;"), src.indexOf('document.addEventListener("dragend"'));
  const on: Record<string, (e: unknown) => void> = {};
  new Function("roadmap", "roadmapUi", "post", "paint", "loadRoadmap", "document", block)({}, {}, async () => ({}), () => {}, () => {}, { addEventListener: (n: string, f: (e: unknown) => void) => { on[n] = f; } });
  const target = { closest: () => ({ dataset: { rmCard: "1", rmProject: "SALUS" } }) };
  expect(() => on.dragstart({ target, dataTransfer: { setData() {} }, preventDefault() {} })).toThrow(ReferenceError);
});

// The whole Board reads every version; the Chains tab alone reads the running one, and only that read carries the burn-down.
test("GET /api/board: a member of another version stays in the whole-Board read and leaves the tab's read", async () => {
  const s = scratch();
  writeFileSync(join(s.mirror, "HIMMEL-21.md"), mirrorIssue(21, "To Do", "To Do", [], "Next version work").replace("v1.1.3", "v1.1.4"));
  writeFileSync(s.mirror + ".versions.tsv", "v1.1.3\tfalse\t\nv1.1.4\tfalse\t\n");
  writeFileSync(s.registry, JSON.stringify({ schema: "himmel.chain-registry/1", chains: [{ id: "memory", goal: "Memory guard rework chain", members: ["HIMMEL-1", "HIMMEL-2"] }, { id: "later", goal: "Later version work chain", members: ["HIMMEL-21"] }] }));
  const r = await get(serve({ HIMMEL_CHAIN_REGISTRY: s.registry, TICKET_STATUS_STATE_DIR: join(s.d, "no-state") }, s));
  expect(r.chains).toMatchObject({ version: null });
  expect(Object.keys(r.chains.tickets).sort()).toEqual(["HIMMEL-1", "HIMMEL-2", "HIMMEL-21"]);
  expect(r.chains.chains.map((c: { id: string }) => c.id)).toContain("later");
  expect(r.chains.burn).toBeUndefined();
  expect(r.versionChains.version).toBe("v1.1.3");
  expect(Object.keys(r.versionChains.tickets).sort()).toEqual(["HIMMEL-1", "HIMMEL-2"]);
  expect(r.versionChains.burn.total).toBe(1);
});

// The version tile picked on the Board decides which version the Chains tab reads.
test("GET /api/board?v=: a known version narrows the tab's read to it, an unknown one falls back to the running version and says so, no v is unchanged", async () => {
  const s = scratch();
  writeFileSync(join(s.mirror, "HIMMEL-21.md"), mirrorIssue(21, "To Do", "To Do", [], "Next version work").replace("v1.1.3", "v1.1.4"));
  writeFileSync(s.mirror + ".versions.tsv", "v1.1.3\tfalse\t\nv1.1.4\tfalse\t\n");
  writeFileSync(s.registry, JSON.stringify({ schema: "himmel.chain-registry/1", chains: [{ id: "memory", goal: "Memory guard rework chain", members: ["HIMMEL-1", "HIMMEL-2"] }, { id: "later", goal: "Later version work chain", members: ["HIMMEL-21"] }] }));
  const url = serve({ HIMMEL_CHAIN_REGISTRY: s.registry, TICKET_STATUS_STATE_DIR: join(s.d, "no-state") }, s);
  const picked = await get(`${url}?v=v1.1.4`);
  expect(picked.versionChains.version).toBe("v1.1.4");
  expect(Object.keys(picked.versionChains.tickets)).toEqual(["HIMMEL-21"]);
  expect(picked.versionChains.burn.total).toBe(1);
  expect(picked.versionChains.fellBack).toBeUndefined();
  const unknown = await get(`${url}?v=v9.9.9`);
  expect(unknown.versionChains.version).toBe("v1.1.3");
  expect(unknown.versionChains.fellBack).toEqual({ asked: "v9.9.9", to: "v1.1.3" });
  const none = await get(url);
  expect(none.versionChains.version).toBe("v1.1.3");
  expect(none.versionChains.fellBack).toBeUndefined();
  expect(Object.keys(none.chains.tickets).sort()).toEqual(["HIMMEL-1", "HIMMEL-2", "HIMMEL-21"]);
});

// With two projects on the Board the tiles are named "v1.1.4 (HIMMEL)"; the chain registry is the one project's, so its own suffix is the same version.
test("GET /api/board?v=: a tile named with the chain project's key picks that version, another project's tile falls back and says so", async () => {
  const s = scratch();
  writeFileSync(join(s.mirror, "HIMMEL-21.md"), mirrorIssue(21, "To Do", "To Do", [], "Next version work").replace("v1.1.3", "v1.1.4"));
  writeFileSync(s.mirror + ".versions.tsv", "v1.1.3\tfalse\t\nv1.1.4\tfalse\t\n");
  writeFileSync(s.registry, JSON.stringify({ schema: "himmel.chain-registry/1", chains: [{ id: "memory", goal: "Memory guard rework chain", members: ["HIMMEL-1", "HIMMEL-2"] }, { id: "later", goal: "Later version work chain", members: ["HIMMEL-21"] }] }));
  const url = serve({ HIMMEL_CHAIN_REGISTRY: s.registry, TICKET_STATUS_STATE_DIR: join(s.d, "no-state") }, s);
  const own = await get(`${url}?v=${encodeURIComponent("v1.1.4 (HIMMEL)")}`);
  expect(own.versionChains.version).toBe("v1.1.4");
  expect(own.versionChains.fellBack).toBeUndefined();
  const other = await get(`${url}?v=${encodeURIComponent("v1.1.4 (SALUS)")}`);
  expect(other.versionChains.version).toBe("v1.1.3");
  expect(other.versionChains.fellBack).toEqual({ asked: "v1.1.4 (SALUS)", to: "v1.1.3" });
});

test("GET /api/board: a failed roadmap read is that failure on the tab, never no running version, and the whole-Board read still arrives", async () => {
  const s = scratch();
  const env = { PATH: process.env.PATH, HOME: s.home, HIMMEL_JIRA_MIRROR: s.mirror, HIMMEL_CHAIN_REGISTRY: s.registry, TICKET_STATUS_STATE_DIR: join(s.d, "no-state") };
  const r = await readBoardExtras(env, () => { throw new Error("mirror went away"); });
  expect(r.versionChains).toEqual({ state: "absent", reason: "the running version could not be read: mirror went away" });
  expect((r.chains as { schema: string }).schema).toBe("himmel.chains/1");
});

test("Board: a card shows its open PR and CI as a link from the worker records, flags a started card with no open PR, and flags nothing when the records are not read", async () => {
  const s = scratch();
  writeFileSync(join(s.mirror, "HIMMEL-3.md"), mirrorIssue(3, "In Progress", "In Progress", [], "Has a PR"));
  writeFileSync(join(s.mirror, "HIMMEL-4.md"), mirrorIssue(4, "In Progress", "In Progress", [], "Started, no PR"));
  writeFileSync(join(s.mirror, "HIMMEL-5.md"), mirrorIssue(5, "In Progress", "In Progress", [], "Red latch, plus a closed PR"));
  writeFileSync(s.mirror + ".versions.tsv", "v1.1.3\tfalse\t\n");
  const st = join(s.d, "state");
  mkdirSync(join(st, "workers"), { recursive: true });
  const rec = (key: string, prs: Record<string, unknown>) => writeFileSync(join(st, "workers", `${key}.json`), JSON.stringify({ key, leg: "N1", state: "running", prs }));
  rec("HIMMEL-3", { "4703": { head: "a".repeat(40), ci: "pending", red_latch: false, open: true } });
  rec("HIMMEL-5", { "4704": { head: "b".repeat(40), ci: "green", red_latch: true, open: true }, "4600": { head: "c".repeat(40), ci: "green", red_latch: false, open: false } });
  const env = { HIMMEL_CHAIN_REGISTRY: s.registry, TICKET_STATUS_STATE_DIR: st, GH_REPO: "acme/widgets" };
  const ui = { version: null, theme: null, v: "all" };
  const page = async (base: string) => renderBoard(await get(base.replace("/api/board", "/api/roadmap")), ui, await get(base));
  const base = serve(env, s);
  const api = await get(base);
  expect(api.prs).toEqual({ state: "ok", repo: "acme/widgets", prs: {
    ["HIMMEL-" + 3]: [{ pr: 4703, head: "a".repeat(40), ci: "running" }],
    ["HIMMEL-" + 5]: [{ pr: 4704, head: "b".repeat(40), ci: "red" }] }, seen: {}, unread: [] }); // pending reads running, a red latch reads red, a closed PR is not listed
  const html = await page(base);
  const card = (k: string) => html.match(new RegExp(`<div class="rm-card(?: cc(?: red)?)?"[^>]*aria-label="${k}:[\\s\\S]*?</div></div>`))![0];
  expect(card("HIMMEL-3")).toContain('<a class="pr ci-running" href="https://github.com/acme/widgets/pull/4703"');
  expect(card("HIMMEL-3")).toContain("#4703 · CI running");
  expect(card("HIMMEL-3")).not.toContain("no open PR");
  expect(card("HIMMEL-5")).toContain("#4704 · CI red");
  expect(card("HIMMEL-5")).not.toContain("4600");
  expect(card("HIMMEL-4")).toContain("no open PR"); // started, and no worker record names an open PR
  expect(card("HIMMEL-2")).not.toContain("no open PR"); // not started
  expect(card("HIMMEL-1")).not.toContain("no open PR"); // done
  writeFileSync(join(st, "workers", "HIMMEL-4.json"), "{ not json");
  writeFileSync(join(st, "workers", "HIMMEL-" + 2 + ".json"), "null"); // parses, but holds no record
  expect((await get(serve(env, s))).prs.unread.sort()).toEqual(["HIMMEL-" + 2, "HIMMEL-" + 4]);
  expect((await page(serve(env, s))).match(new RegExp(`<div class="rm-card(?: cc(?: red)?)?"[^>]*aria-label="HIMMEL-${4}:[\\s\\S]*?</div></div>`))![0]).not.toContain("no open PR"); // the record could not be read, so no claim is made
  const none = await page(serve({ ...env, TICKET_STATUS_STATE_DIR: join(s.d, "no-state") }, s));
  expect(none).not.toContain("no open PR"); // the records could not be read: no card is flagged on a guess
  expect(none).not.toContain("CI running");
});

test("the Blocked on you list shows an owed item with no DELIVERED receipt and a worker the tick holds unclosed, and each row leaves when its record lands", () => {
  const s = scratch();
  const doc = join(s.d, "HIMMEL-nextleg-2026-11-10XZ-roadmap-chief.md");
  const stateDir = join(s.d, "tick-state");
  mkdirSync(stateDir, { recursive: true });
  const stateFile = join(stateDir, "tick-unclosed-HIMMEL-nextleg-2026-11-10XZ-roadmap-chief");
  const env = { PATH: process.env.PATH, HOME: s.home, HIMMEL_CHIEF_DOC: doc, HIMMEL_BUCKET_DIR: s.d, TICK_STATE_DIR: stateDir };
  const noRoadmap = (() => { throw new Error("no roadmap in this test"); }) as unknown as typeof import("../roadmap").readRoadmap;
  const write = (bullets: string) => writeFileSync(doc, `# chief\n\n## Live state\n\nworkers: x\n\n## Results\n${bullets}`);
  const held = () => { writeFileSync(stateFile, "N5805 1000 0\nN5806 1000 0\nN5807 1600 0\n"); utimesSync(stateFile, 1600, 1600); };
  const rows = (source: string) => { const o = readOwed(env, noRoadmap); if (o.state !== "ok") throw new Error(o.reason); return o.items.filter((i) => i.source === source); };

  write("- 09:00 OWED sig-9608 sign the spec on Telegram\n- 09:01 OWED sig-9609 pick the version\n- 09:02 DELIVERED sig-9609 msg=42 chat=-100\n");
  held();
  const owed = rows("owed undelivered");
  expect(owed.map((i) => i.title)).toEqual(["sig-9608: sign the spec on Telegram"]);
  expect(owed[0].ctx).toContain("no DELIVERED receipt");
  expect(owed[0].act).toContain("chief-route.ts reply --owed sig-9608");
  const un = rows("unclosed worker");
  expect(un.map((i) => i.title)).toEqual(["N5805 is finished and its window is still open", "N5806 is finished and its window is still open"]);
  expect(un[0].ctx).toContain("no DISPOSITION bullet");
  expect(un[0].act).toContain("DISPOSITION N5805 closed");

  write("- 09:00 OWED sig-9608 sign the spec on Telegram\n- 09:03 DELIVERED sig-9608 msg=43 chat=-100\n- 10:00 DISPOSITION N5806 closed\n- 10:01 DISPOSITION N5805 parked\n");
  expect(rows("owed undelivered")).toEqual([]);
  expect(rows("unclosed worker").map((i) => i.title)).toEqual(["N5805 is finished and its window is still open"]);
  write("- 10:00 DISPOSITION N5806 closed\n- 10:01 DISPOSITION N5805 parked wake=pr-4999-merge\n");
  expect(rows("unclosed worker")).toEqual([]);

  rmSync(stateFile);
  write("- 09:00 OWED sig-9608 sign the spec on Telegram\n");
  expect(rows("unclosed worker")).toEqual([]);
  expect(rows("owed undelivered").length).toBe(1);
});

test("an unclosed worker recorded with a disposition already present stays until a newer one lands, and a parked with nothing after it does not clear it", () => {
  const s = scratch();
  const doc = join(s.d, "HIMMEL-nextleg-2026-11-10XZ-roadmap-chief.md");
  const stateDir = join(s.d, "tick-state");
  mkdirSync(stateDir, { recursive: true });
  const stateFile = join(stateDir, "tick-unclosed-HIMMEL-nextleg-2026-11-10XZ-roadmap-chief");
  const env = { PATH: process.env.PATH, HOME: s.home, HIMMEL_CHIEF_DOC: doc, HIMMEL_BUCKET_DIR: s.d, TICK_STATE_DIR: stateDir };
  const noRoadmap = (() => { throw new Error("no roadmap in this test"); }) as unknown as typeof import("../roadmap").readRoadmap;
  const write = (bullets: string) => writeFileSync(doc, `# chief\n\n## Live state\n\nworkers: x\n\n## Results\n${bullets}`);
  const labels = () => { const o = readOwed(env, noRoadmap); if (o.state !== "ok") throw new Error(o.reason); return o.items.filter((i) => i.source === "unclosed worker").map((i) => { expect(i.since).toBe(1000); return i.label; }); };
  writeFileSync(stateFile, "N5808 1000 1\nN5809 1000 0\n");
  utimesSync(stateFile, 1600, 1600);

  write("- 08:00 DISPOSITION N5808 closed\n- 08:01 DISPOSITION N5809 parked \n- 08:02 note\n");
  expect(labels()).toEqual(["N5808", "N5809"]);
  write("- 08:00 DISPOSITION N5808 closed\n- 09:00 DISPOSITION N5808 closed\n- 08:01 DISPOSITION N5809 parked \n- 08:02 note\n");
  expect(labels()).toEqual(["N5809"]);
});

test("a chief doc with no Live state section is named unread even when it holds an unclosed worker, and the worker still shows", () => {
  const s = scratch();
  const doc = join(s.d, "HIMMEL-nextleg-2026-11-10XZ-roadmap-chief.md");
  const stateDir = join(s.d, "tick-state");
  mkdirSync(stateDir, { recursive: true });
  const stateFile = join(stateDir, "tick-unclosed-HIMMEL-nextleg-2026-11-10XZ-roadmap-chief");
  const env = { PATH: process.env.PATH, HOME: s.home, HIMMEL_CHIEF_DOC: doc, HIMMEL_BUCKET_DIR: s.d, TICK_STATE_DIR: stateDir };
  const noRoadmap = (() => { throw new Error("no roadmap in this test"); }) as unknown as typeof import("../roadmap").readRoadmap;
  writeFileSync(join(s.d, "x-HANDOFF.md"), "# handoff\n\n## Open operator items\n- none\n");
  writeFileSync(doc, "# chief\n\n## Results\n- 08:00 note\n");
  writeFileSync(stateFile, "N5810 1000 0\n");
  utimesSync(stateFile, 1600, 1600);
  const o = readOwed(env, noRoadmap);
  if (o.state !== "ok") throw new Error(o.reason);
  expect(o.unread).toContain("chief doc lines");
  expect(o.items.filter((i) => i.source === "unclosed worker").map((i) => i.label)).toEqual(["N5810"]);
});
