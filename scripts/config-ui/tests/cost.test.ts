// The Cost page's data module (cost.ts) and browser half (public/cost.js): phase-cost rows in, one page model out, each
// phase row opening to the parts it is made of. A part no record splits says "not countable yet"; it never gets a number.
import { test, expect, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { buildCostModel, readCost, readPhaseCostRows, type PhaseCostRow } from "../cost";
import { mountCost, renderCost } from "../public/cost.js";

const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const DAY = "2026-11-04";
const READER = join(import.meta.dir, "..", "..", "usage", "usage-read.sh");
const row = (o: Partial<PhaseCostRow> & { phase: string; usd: number | null }): PhaseCostRow => ({
  kind: "phase-cost", day: DAY, session: "s", parent: null, lane: "claude", class: "worker", model: "claude-sonnet-5-5",
  phase_rule: "v1", calls: 1, in: 100, out: 10, cache_read: 1000, cc_5m: 0, cc_1h: 0, mark: "derived", ...o,
});
// a worker (build, a subagent, boot), a chief with a brief-drafter and a helper, a judge, a review step whose model text carries a
// ticket key, a tests row with no price, and a row from the day before
const ROWS: PhaseCostRow[] = [
  row({ session: "w1", phase: "build", usd: 10 }), row({ session: "w1", phase: "agent", class: "subagent", usd: 4 }),
  row({ session: "w1", phase: "boot", usd: 1, model: "claude-opus-5-5" }),
  row({ session: "c1", phase: "chief-turns", class: "chief", usd: 20, mark: "counted" }),
  row({ session: "b1", phase: "chief-turns", class: "brief-drafter", usd: 5, mark: "counted" }),
  row({ session: "h1", phase: "chief-turns", class: "subagent", parent: "c1", usd: 3, mark: "counted" }),
  row({ session: "j1", phase: "judge", class: "judge", usd: 6, mark: "counted" }),
  row({ session: "w1", phase: "review", usd: 4, model: "claude-opus-5-5,HIMMEL-9260-x" }),
  row({ session: "w1", phase: "tests", usd: null, mark: "unpriced", model: "gpt-9-unknown" }),
  row({ session: "w0", phase: "build", usd: 99, day: "2026-11-03" }),
];

test("cost: phases come out biggest first with their share of the day, and the day's total is counted", () => {
  const m = buildCostModel(ROWS, DAY);
  expect(m.state).toBe("ok");
  expect(m.day).toBe(DAY);
  expect(m.days).toEqual(["2026-11-04", "2026-11-03"]);
  expect(m.usd).toBe(53);
  expect(m.phases.map((p) => [p.id, p.usd, p.share, p.mark])).toEqual([
    ["chief", 28, 52.8, "counted"], ["build", 15, 28.3, "derived"], ["judge", 6, 11.3, "counted"], ["review", 4, 7.5, "derived"], ["tests", null, null, "unpriced"],
  ]);
});

test("cost: a phase row opens to its parts; a part no record splits is 'not countable yet' with no number", () => {
  const m = buildCostModel(ROWS, DAY);
  const chief = m.phases.find((p) => p.id === "chief")!;
  expect(chief.parts.map((p) => [p.id, p.usd, p.share, p.mark])).toEqual([
    ["chief-sessions", 20, 71.4, "counted"], ["brief-drafting", 5, 17.9, "counted"], ["chief-helpers", 3, 10.7, "counted"], ["chief-steps", null, null, "nocount"],
  ]);
  expect(chief.made).toBe("chief sessions 20.0 · brief drafting 5.0 · chief helpers 3.0");
  expect(buildCostModel(ROWS, DAY).phases.find((p) => p.id === "build")!.parts.map((p) => [p.id, p.usd])).toEqual([["build-edit", 10], ["build-agent", 4], ["build-boot", 1]]);
  // a phase the records keep as one figure opens to one not-countable-yet row holding the whole phase
  const judge = m.phases.find((p) => p.id === "judge")!;
  expect(judge.parts).toMatchObject([{ id: "judge-pr", usd: 6, share: 100, mark: "nocount" }]);
});

test("cost: a row with no price keeps its phase and says so; no dollar is invented for it", () => {
  const tests = buildCostModel(ROWS, DAY).phases.find((p) => p.id === "tests")!;
  expect(tests).toMatchObject({ usd: null, share: null, mark: "unpriced" });
  expect(tests.parts.every((p) => p.usd === null || p.mark === "nocount")).toBe(true);
});

test("cost: the day's total is counted only when every call is priced; a day with no priced call has no total, not $0", () => {
  expect(buildCostModel(ROWS, DAY)).toMatchObject({ usd: 53, mark: "unpriced" });
  expect(renderCost(buildCostModel(ROWS, DAY), { open: [] })).toContain("no price yet");
  const priced = buildCostModel(ROWS.filter((r) => r.phase !== "tests"), DAY);
  expect(priced).toMatchObject({ usd: 53, mark: "counted" });
  const none = buildCostModel([row({ phase: "build", usd: null, mark: "unpriced" })], DAY);
  expect(none).toMatchObject({ state: "ok", usd: null, mark: "unpriced" });
  expect(renderCost(none, { open: [] })).toContain("<span class=\"big\">— ");
});

test("cost: a day asked for that has no rows is that day with no data, never another day's costs", () => {
  const m = buildCostModel(ROWS, "2026-10-01");
  expect(m).toMatchObject({ state: "nodata", day: "2026-10-01", usd: null, phases: [] });
  expect(m.days).toEqual(["2026-11-04", "2026-11-03"]);
});

test("cost: no ticket key reaches the page model or the rendered page", () => {
  const m = buildCostModel(ROWS, DAY);
  expect(JSON.stringify(m)).not.toMatch(/[A-Z][A-Z0-9]*-\d+/);
  expect(m.models.map((x) => x.model)).toContain("claude-opus-5-5");
  const html = renderCost(m, { open: ["chief", "review"] });
  expect(html).not.toMatch(/[A-Z][A-Z0-9]*-\d+/);
  expect(html).not.toMatch(/mockup/i);
});

test("cost: the rendered table has every phase closed, and an open phase shows its parts", () => {
  const m = buildCostModel(ROWS, DAY);
  const closed = renderCost(m, { open: [] });
  expect(closed.match(/aria-expanded="false"/g)).toHaveLength(5);
  expect(closed).not.toContain("brief-drafter subagents");
  const open = renderCost(m, { open: ["chief"] });
  expect(open.match(/aria-expanded="true"/g)).toHaveLength(1);
  expect(open).toContain("brief-drafter subagents");
  expect(open).toContain("not countable yet");
});

test("cost: a click on a phase row opens it, a second click closes it", () => {
  const m = buildCostModel(ROWS, DAY);
  let click: (e: unknown) => void = () => {};
  const root = { innerHTML: "", addEventListener: (_t: string, f: (e: unknown) => void) => { click = f; } };
  mountCost(root, m);
  const on = (id: string) => click({ target: { closest: () => ({ getAttribute: () => id }) } });
  expect(root.innerHTML).not.toContain("brief-drafter subagents");
  on("chief");
  expect(root.innerHTML).toContain("brief-drafter subagents");
  on("chief");
  expect(root.innerHTML).not.toContain("brief-drafter subagents");
});

test("cost: a row with a script tag in its model is shown as text", () => {
  const m = buildCostModel([row({ phase: "build", usd: 1, model: "<script>alert(1)</script>" })], DAY);
  expect(renderCost(m, { open: [] })).not.toContain("<script>");
});

test("cost: no rows is no data yet, never zeros", () => {
  const m = buildCostModel([], undefined);
  expect(m).toMatchObject({ state: "nodata", day: null, days: [], phases: [] });
  expect(renderCost(m, { open: [] })).toContain("no data yet");
});

test("cost: usage-read hands over the latest row per day, session and phase, and drops a closed (zero-call) one", () => {
  const dir = mkdtempSync(join(tmpdir(), "cost-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const store = join(dir, "usage");
  mkdirSync(store);
  const lines = [
    row({ session: "w1", phase: "build", usd: 1, calls: 1 }), row({ session: "w1", phase: "build", usd: 3, calls: 2 }),
    row({ session: "w1", phase: "boot", usd: 0, calls: 0 }), row({ session: "w2", phase: "build", usd: 5 }),
  ].map((r) => JSON.stringify(r));
  lines.splice(1, 0, JSON.stringify({ schema: 1, ticket: "HIMMEL-1", totals: {} })); // a ticket record in the same store
  writeFileSync(join(store, "records.jsonl"), lines.join("\n") + "\n");
  const rows = readPhaseCostRows({ HIMMEL_USAGE_STORE: store, PATH: process.env.PATH });
  expect(rows.map((r) => [r.session, r.phase, r.usd])).toEqual([["w1", "build", 3], ["w2", "build", 5]]);
  expect(readPhaseCostRows({ HIMMEL_USAGE_STORE: join(dir, "absent"), PATH: process.env.PATH })).toEqual([]);
});

test("cost: no store says the usage store has not been built yet and names the command, never 'no data yet'", () => {
  const dir = mkdtempSync(join(tmpdir(), "cost-nostore-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const m = readCost({ HIMMEL_USAGE_STORE: join(dir, "absent"), PATH: process.env.PATH });
  expect(m).toMatchObject({ state: "nostore", usd: null, phases: [] });
  const html = renderCost(m, { open: [] });
  expect(html).toContain("the usage store has not been built yet");
  expect(html).toContain("scripts/usage/usage-compute.sh");
  expect(html).not.toContain("no data yet");
  expect(readCost({ HOME: join(dir, "home"), PATH: process.env.PATH }).state).toBe("nostore");
});

test("cost: a store with phase-cost rows gives the table", () => {
  const dir = mkdtempSync(join(tmpdir(), "cost-store-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const store = join(dir, "usage");
  mkdirSync(store);
  writeFileSync(join(store, "records.jsonl"), ROWS.map((r) => JSON.stringify(r)).join("\n") + "\n");
  const m = readCost({ HIMMEL_USAGE_STORE: store, PATH: process.env.PATH }, DAY);
  expect(m).toMatchObject({ state: "ok", day: DAY, usd: 53 });
  const html = renderCost(m, { open: [] });
  expect(html).toContain("Cost by phase");
  expect(html).toContain("<table");
  expect(html).not.toContain("not been built");
});

test("cost: usage-read --phase-cost keeps one day with --day, every version with --all, and refuses --day alone or with --ticket", () => {
  const dir = mkdtempSync(join(tmpdir(), "cost-flags-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const store = join(dir, "usage");
  mkdirSync(store);
  const lines = [row({ phase: "build", usd: 1 }), row({ phase: "build", usd: 3, calls: 2 }), row({ phase: "build", usd: 7, day: "2026-11-03" })];
  writeFileSync(join(store, "records.jsonl"), lines.map((r) => JSON.stringify(r)).join("\n") + "\n");
  const read = (...args: string[]) => spawnSync("bash", [READER, "--store", store, ...args], { encoding: "utf8" });
  const usds = (args: string[]) => read(...args).stdout.trim().split("\n").map((l) => JSON.parse(l).usd);
  expect(usds(["--phase-cost", "--day", "2026-11-03"])).toEqual([7]);
  expect(usds(["--phase-cost", "--all"])).toEqual([1, 3, 7]);
  expect(usds(["--phase-cost"])).toEqual([7, 3]);
  expect(read("--day", DAY)).toMatchObject({ status: 1, stderr: expect.stringContaining("--day needs --phase-cost") });
  expect(read("--phase-cost", "--ticket", "HIMMEL-1")).toMatchObject({ status: 1, stderr: expect.stringContaining("does not combine") });
});

const BASIS = "Claude transcript usage at list prices; not invoices. Native Codex and other provider stores are not included.";
const UNKNOWN = "Collection freshness and completeness unknown";

test("cost: basis is explicit in every state", () => {
  const dir = mkdtempSync(join(tmpdir(), "cost-basis-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const ok = buildCostModel(ROWS, DAY);
  const nodata = buildCostModel(ROWS, "2026-10-01");
  const empty = buildCostModel([], undefined);
  const nostore = readCost({ HIMMEL_USAGE_STORE: join(dir, "absent"), PATH: process.env.PATH });
  const other = { ...nodata, state: "error" } as unknown as typeof nodata;
  for (const m of [ok, nodata, empty, nostore, other]) {
    expect(m.basis).toBe(BASIS);
    expect(m.coverageNote).toBe(UNKNOWN);
    const html = renderCost(m, { open: [] });
    expect(html).toContain(BASIS);
    expect(html).toContain(UNKNOWN);
    expect(html).not.toMatch(/all[- ]provider|every provider|invoice(?:d| total)/i);
  }
});

test("cost: agent parts partition class and conserve total", () => {
  const sample = [
    row({ session: "w1", phase: "agent", class: "subagent", usd: 4, calls: 2 }), row({ session: "w1", phase: "agent", class: "worker", usd: 1, calls: 3 }),
    row({ session: "w2", phase: "agent", class: "other", usd: 2, calls: 5 }), row({ session: "w1", phase: "compaction", usd: 3, calls: 7 }),
  ];
  const m = buildCostModel(sample, DAY);
  const build = m.phases.find((p) => p.id === "build")!;
  expect(m).toMatchObject({ usd: 10, calls: 17 });
  expect(build).toMatchObject({ usd: 10 });
  expect(build.parts.map((p) => [p.id, p.usd]).sort()).toEqual([["build-agent", 4], ["build-agent-followup", 3], ["build-compaction", 3]]);
  expect(build.parts.reduce((a, p) => a + (p.usd ?? 0), 0)).toBe(build.usd);
});

test("cost: after-compaction label describes follow-up, and the build captions name child sessions apart from parent follow-ups", () => {
  const sample = [
    row({ phase: "agent", class: "subagent", usd: 4 }), row({ phase: "agent", class: "worker", usd: 1 }), row({ phase: "compaction", usd: 3 }),
  ];
  const html = renderCost(buildCostModel(sample, DAY), { open: ["build"] });
  expect(html).toContain("Build and other work");
  expect(html).toContain("Child sessions");
  expect(html).toContain("Parent follow-ups after delegation");
  expect(html).toContain("After compaction");
  expect(html).not.toContain("PR build");
  expect(html).not.toContain("worker subagents");
});

test("cost: before the first read lands the page says loading, and after a failed read it adds no 'no data yet' beside the failure note", () => {
  expect(renderCost(null, { open: [] })).toContain("loading");
  expect(renderCost(null, { open: [] })).not.toContain("no data yet");
  expect(renderCost(null, { open: [], err: true })).toBe("");
});

const T3_DAY = "2026-11-24";
type T3Turn = { thread: string; driver: string; model?: string; session?: string; at: string; usage?: Record<string, unknown>; live?: Record<string, unknown> };
function makeT3Home(turns: T3Turn[], titles: Record<string, string>): { home: string; env: Record<string, string | undefined> } {
  const dir = mkdtempSync(join(tmpdir(), "cost-t3-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, "t3", "userdata"), { recursive: true });
  const db = new Database(join(dir, "t3", "userdata", "statev2.sqlite"));
  db.exec(`CREATE TABLE orchestration_v2_projection_provider_turns (provider_turn_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, provider_thread_id TEXT NOT NULL,
      node_id TEXT NOT NULL, run_attempt_id TEXT, ordinal INTEGER NOT NULL, status TEXT NOT NULL, started_at TEXT, completed_at TEXT, payload_json TEXT NOT NULL);
    CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL, default_provider TEXT NOT NULL,
      runtime_mode TEXT NOT NULL, interaction_mode TEXT NOT NULL, active_provider_thread_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL);
    CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, owner_node_id TEXT, provider TEXT NOT NULL,
      provider_session_id TEXT, status TEXT NOT NULL, first_run_ordinal INTEGER, last_run_ordinal INTEGER, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
    CREATE TABLE orchestration_v2_projection_provider_sessions (provider_session_id TEXT PRIMARY KEY, thread_id TEXT, provider TEXT NOT NULL, status TEXT NOT NULL,
      model TEXT, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);`);
  for (const [id, title] of Object.entries(titles))
    db.run("INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [id, "p", title, "x", "r", "i", null, "t", "t", null, null, "{}"]);
  turns.forEach((t, i) => {
    const pt = `pt-${i}`, sess = `ps-${i}`;
    db.run("INSERT INTO orchestration_v2_projection_provider_sessions VALUES (?,?,?,?,?,?,?)", [sess, t.thread, t.driver, "ok", t.session ?? null, "t", "{}"]);
    db.run("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?,?,?,?,?,?)", [pt, t.thread, null, t.driver, sess, "ok", 1, 1, "t", "{}"]);
    const payload = { id: `turn-${i}`, nativeTurnRef: { driver: t.driver }, ...(t.model ? { model: t.model } : {}), ...(t.usage ? { turnTokenUsage: t.usage } : {}), ...(t.live ? { tokenUsage: t.live } : {}) };
    db.run("INSERT INTO orchestration_v2_projection_provider_turns VALUES (?,?,?,?,?,?,?,?,?,?)", [`turn-${i}`, t.thread, pt, "n", null, i, "completed", t.at, t.at, JSON.stringify(payload)]);
  });
  db.close();
  const usage = join(dir, "usage");
  mkdirSync(usage);
  const phased = [T3_DAY, "2026-11-23"].map((day) => JSON.stringify(row({ session: "p1", phase: "build", usd: 1, day, mark: "counted" }))).join("\n");
  writeFileSync(join(usage, "records.jsonl"), phased + "\n");
  return { home: join(dir, "t3"), env: { HIMMEL_USAGE_STORE: usage, T3CODE_HOME: join(dir, "t3"), HOME: join(dir, "nohome"), PATH: process.env.PATH } };
}
const use = (inputTokens: number, cachedInputTokens: number, cacheCreationTokens: number, outputTokens: number) =>
  ({ usageScope: "main_agent", usageStatus: "complete", inputTokens, cachedInputTokens, cacheCreationTokens, outputTokens, reasoningTokens: 0, hasSubagents: false });
const UNAVAILABLE = { usageScope: "main_agent", usageStatus: "unavailable", hasSubagents: false };
const T3_TURNS: T3Turn[] = [
  { thread: "th-claude", driver: "claudeAgent", model: "claude-opus-5-5", at: `${T3_DAY}T10:00:00.000Z`, usage: use(1_000_000, 800_000, 100_000, 10_000), live: { promptCacheTtlMs: 3_600_000 } },
  { thread: "th-claude", driver: "claudeAgent", model: "claude-opus-5-5", at: `${T3_DAY}T11:00:00.000Z`, usage: use(200_000, 100_000, 50_000, 5_000) },
  { thread: "th-codex", driver: "codex", session: "gpt-6.1-sol", at: `${T3_DAY}T12:00:00.000Z`, usage: use(500_000, 400_000, 0, 20_000) },
  { thread: "th-agy", driver: "antigravity", at: `${T3_DAY}T13:00:00.000Z`, usage: use(1_000_000, 900_000, 0, 10_000) },
  { thread: "th-cursor", driver: "cursor", at: `${T3_DAY}T14:00:00.000Z`, usage: use(200_000, 100_000, 0, 2_000) },
  { thread: "th-grok", driver: "grok", at: `${T3_DAY}T15:00:00.000Z`, usage: UNAVAILABLE },
  { thread: "th-acp", driver: "acpRegistry", at: `${T3_DAY}T16:00:00.000Z`, usage: UNAVAILABLE },
  { thread: "th-claude", driver: "claudeAgent", model: "claude-opus-5-5", at: "2026-11-23T10:00:00.000Z", usage: use(100_000, 0, 0, 1_000) },
];
const T3_TITLES = { "th-claude": "Build HIMMEL-123 the thing", "th-codex": "Codex thread", "th-agy": "Antigravity thread", "th-cursor": "Cursor thread", "th-grok": "Grok thread", "th-acp": "ACP thread" };

test("cost: T3 Code rows list usage, tokens and cost per provider for the day, from T3's own store, and name every provider T3 reports", () => {
  const { env } = makeT3Home(T3_TURNS, T3_TITLES);
  const m = readCost(env);
  const t3 = m.t3!;
  expect(t3).toMatchObject({ state: "ok", day: T3_DAY, days: [T3_DAY, "2026-11-23"] });
  expect(t3.providers.map((p) => [p.id, p.turns, p.usd, p.mark])).toEqual([
    ["codex", 1, 0.44, "counted"], ["antigravity", 1, null, "unpriced"], ["claudeAgent", 2, null, "inphase"],
    ["cursor", 1, null, "unpriced"], ["acpRegistry", 1, null, "nocount"], ["grok", 1, null, "nocount"],
  ]);
  expect(t3.providers[2]).toMatchObject({ in: 150_000, out: 15_000, cache_read: 900_000, cache_write: 150_000 });
  expect(t3.providers[0]).toMatchObject({ in: 100_000, out: 20_000, cache_read: 400_000, cache_write: 0 });
  expect(t3.usd).toBe(0.44);
  expect(t3.mark).toBe("unpriced");
  expect(t3.providers.find((p) => p.id === "grok")!.note).toContain("1 of 1 turns carry no usage");
});

test("cost: T3 Code rows list the day's threads biggest first, with the thread's title and no ticket key", () => {
  const { env } = makeT3Home(T3_TURNS, T3_TITLES);
  const t3 = readCost(env).t3!;
  expect(t3.threads.map((t) => [t.name, t.usd, t.turns])).toEqual([
    ["Codex thread", 0.44, 1], ["Antigravity thread", null, 1], ["Build the thing", null, 2], ["Cursor thread", null, 1], ["ACP thread", null, 1], ["Grok thread", null, 1],
  ]);
  expect(JSON.stringify(t3)).not.toMatch(/[A-Z][A-Z0-9]*-\d+/);
});

test("cost: a day asked for picks that day's T3 rows, and a day T3 has no turns for is no data, not another day", () => {
  const { env } = makeT3Home(T3_TURNS, T3_TITLES);
  expect(readCost(env, "2026-11-23").t3).toMatchObject({ state: "ok", day: "2026-11-23", usd: null, mark: "inphase" });
  expect(readCost(env, "2026-10-01").t3).toMatchObject({ state: "nodata", day: "2026-10-01", usd: null, providers: [], threads: [] });
});

test("cost: no T3 Code store is no T3 rows, and the phase table still reads as before", () => {
  const dir = mkdtempSync(join(tmpdir(), "cost-not3-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const m = readCost({ HIMMEL_USAGE_STORE: join(dir, "absent"), T3CODE_HOME: join(dir, "no-t3"), HOME: join(dir, "h"), PATH: process.env.PATH });
  expect(m).toMatchObject({ state: "nostore", t3: { state: "nostore", providers: [], threads: [], usd: null } });
  expect(renderCost(m, { open: [] })).not.toContain("T3 Code");
});

test("cost: a T3 store that cannot be read is no T3 rows, never a thrown page", () => {
  const { home, env } = makeT3Home(T3_TURNS, T3_TITLES);
  writeFileSync(join(home, "userdata", "statev2.sqlite"), "not a database");
  expect(readCost(env).t3).toMatchObject({ state: "nostore", providers: [] });
});

test("cost: the page renders the T3 Code card per provider and per thread, as text, beside the phase table", () => {
  const { env } = makeT3Home(T3_TURNS, { ...T3_TITLES, "th-codex": "<script>alert(1)</script>" });
  const html = renderCost(readCost(env), { open: [] });
  expect(html).toContain("T3 Code");
  expect(html).toContain("By provider");
  expect(html).toContain("By thread");
  for (const name of ["Claude", "Codex", "Antigravity", "Cursor", "Grok", "ACP registry"]) expect(html).toContain(name);
  expect(html).toContain("Build the thing");
  expect(html).toContain("$0.4");
  expect(html).not.toContain("<script>");
  expect(html).not.toMatch(/[A-Z][A-Z0-9]*-\d+/);
});

test("cost: a provider that reports no usage shows no token numbers, not measured zeros", () => {
  const { env } = makeT3Home(T3_TURNS, T3_TITLES);
  const html = renderCost(readCost(env), { open: [] });
  const grok = html.match(/<tr><td>Grok<\/td>.*?<\/tr>/)![0];
  expect(grok).toContain("not countable yet");
  expect(grok).not.toContain('<td class="n">0</td>');
  expect(grok.match(/<td class="n">—<\/td>/g)!.length).toBeGreaterThanOrEqual(6);
});

test("cost: a Claude session in both the phase table and T3's store has its dollars in the phase table only, and T3 shows its tokens", () => {
  const { env } = makeT3Home(T3_TURNS, T3_TITLES);
  const store = env.HIMMEL_USAGE_STORE!;
  writeFileSync(join(store, "records.jsonl"), JSON.stringify(row({ session: "1eecca75", phase: "build", usd: 5.5, day: T3_DAY, mark: "counted" })) + "\n");
  const m = readCost(env, T3_DAY);
  const claude = m.t3!.providers.find((p) => p.id === "claudeAgent")!;
  expect(m.usd).toBe(5.5);
  expect(claude).toMatchObject({ usd: null, mark: "inphase", in: 150_000, out: 15_000 });
  expect(claude.note).toContain("phase table");
  expect(m.t3!.usd).toBe(0.44);
  const html = renderCost(m, { open: [] });
  expect(html.match(/<tr><td>Claude<\/td>.*?<\/tr>/)![0]).toContain("in the phase table");
  expect(html).toContain("$5.5");
});

test("cost: with no phase table behind it, T3's Claude turns are priced on the T3 card, never dropped from both", () => {
  const { env } = makeT3Home(T3_TURNS, T3_TITLES);
  const m = readCost({ ...env, HIMMEL_USAGE_STORE: join(env.T3CODE_HOME!, "absent") });
  expect(m.state).toBe("nostore");
  expect(m.t3!.providers.find((p) => p.id === "claudeAgent")).toMatchObject({ usd: 2.13, mark: "counted" });
  expect(m.t3!.usd).toBe(2.57);
});
