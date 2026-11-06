// three seeded digests exercise the real ledger writer and server rate math.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import * as sources from "../health-sources";
import { rollupToolHealth } from "../../eval/worker-digest/tool-health.mjs";
import { startServer } from "../server";
import { navLinks, parseLanding } from "../public/nav.js";

const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });
const agent = { id: "main", role: "agent", kind: null, model: "gpt-6.1-sol" };
function seed() {
  const dir = mkdtempSync(join(tmpdir(), "tool-health-")); dirs.push(dir);
  const evals = join(dir, "eval.jsonl"), failures = join(dir, "fail.jsonl");
  const samples = [
    { lane: "native", bash: 10, read: 10, errors: 2, denied: 1, recovered: true },
    { lane: "claudex", bash: 30, read: 10, errors: 1, denied: 3, recovered: false },
    { lane: "native", bash: 10, read: 0, errors: 0, denied: 1, recovered: null },
  ];
  for (const [i, s] of samples.entries()) {
    const session = `48160000-0000-4000-8000-00000000000${i}`;
    const row = (cls: string, count: number, recovered: boolean | null) => ({ session, agent, class: cls, failure: cls.split("/")[0], count, recovered, identical_retry: null, first_ts: Date.parse("2026-10-07T12:00:00Z"), last_ts: Date.parse("2026-10-07T12:00:01Z"), tool_call_ids: [`toolu_${i}`] });
    const digest = { digest_v: 2, mapper_v: 1, trajectory_v: 1, session, status: "ok", model: agent.model,
      lane: s.lane, started_ts: Date.parse("2026-10-07T12:00:00Z"), agents: [agent],
      metrics: { tool_calls: s.bash + s.read, turns: 1, tool_calls_by_tool: { Bash: s.bash, Read: s.read }, tool_failures_by_tool: { Bash: s.errors + s.denied } },
      tool_health: [{ agent, lane: s.lane, tool: "Bash", calls: s.bash, failures: s.errors + s.denied, errors: s.errors, denials: s.denied, classes: { ...(s.denied ? { "denied/read-clamp": s.denied } : {}), ...(s.errors ? { "error/Bash": s.errors } : {}) } }, { agent, lane: s.lane, tool: "Read", calls: s.read, failures: 0, errors: 0, denials: 0, classes: {} }],
      failures: [row("denied/read-clamp", s.denied, s.recovered), ...(s.errors ? [row("error/Bash", s.errors, null)] : [])] };
    const file = join(dir, `digest${i}.json`); writeFileSync(file, JSON.stringify(digest));
    const r = Bun.spawnSync(["python3", resolve(import.meta.dir, "../../eval/worker-digest/worker_ledger.py"), "record", "--digest", file, "--lane", s.lane, "--worker", `N${i + 1}`, "--failures-ledger", failures, "--eval-ledger", evals, "--state-dir", join(dir, "state")]);
    expect(r.exitCode).toBe(0);
  }
  const config = join(dir, "claude-config"); mkdirSync(config);
  return { HOME: dir, HIMMEL_EVAL_RUNS_LEDGER: evals, HIMMEL_WORKER_SESSION_FAILURES_LEDGER: failures, CLAUDE_CONFIG_DIR: config };
}
const read = (env: object, query = new URLSearchParams()) => (sources as any).readToolHealth(env, query, Date.parse("2026-10-07T23:59:00Z"));

test("three digests use weighted calls, not the mean of session percentages", () => {
  expect(typeof (sources as any).readToolHealth).toBe("function");
  const data = read(seed());
  expect(data.state).toBe("ok");
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 50, failures: 8, rate: 0.16, error_rate: 0.06, recovery_rate: 0.25 });
  expect(data.hooks.find((r: any) => r.class === "denied/read-clamp")).toMatchObject({ calls: 50, failures: 5, rate: 0.1 });
  expect(data.daily.find((r: any) => r.lane === "native" && r.tool === "Bash")).toMatchObject({ day: "2026-10-07", calls: 20, failures: 4, rate: 0.2 });
  expect(data.tools.find((r: any) => r.tool === "Bash").trend).toHaveLength(7);
});

test("lane filters and comparisons use per-lane call totals; recovery excludes unknown rows", () => {
  const env = seed(), data = read(env, new URLSearchParams({ lane: "native", days: "30" }));
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 20, failures: 4, rate: 0.2, recovery_rate: 1 });
  expect(data.tools.find((r: any) => r.tool === "Bash").trend).toHaveLength(30);
  const comparison = read(env).comparison.find((r: any) => r.metric === "calls_per_100" && r.key === "Bash");
  expect(comparison.values.native).toBeCloseTo(200 / 3);
  expect(comparison.values.claudex).toBe(75);
  expect(comparison.delta.claudex).toBeCloseTo(25 / 3);
  expect(read(env, new URLSearchParams({ model: "absent" })).tools).toEqual([]);
  expect(read(env, new URLSearchParams({ role: "console" })).tools).toEqual([]);
});

test("legacy digests keep failures visible without inventing a zero rate", () => {
  const env = seed();
  const lines = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  for (const r of lines) { delete r.meta.tool_health; r.config.digest_v = 1; }
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, lines.map(JSON.stringify).join("\n") + "\n");
  const data = read(env);
  // The 3 errors are Bash's; the 5 denials name no tool, so they sit in the explicit legacy-unknown bucket.
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: null, failures: 3, rate: null });
  expect(data.tools.find((r: any) => r.tool === "(unknown)")).toMatchObject({ calls: null, failures: 5, denials: 5, rate: null });
  expect(data.hooks[0].rate).toBeNull();
});

test("recorded worker-doc lane overrides extractor provenance and stamps every persisted tool row", () => {
  const env = seed(), dir = dirs[dirs.length - 1];
  const doc = join(dir, "worker.md"), file = join(dir, "digest0.json"), evals = join(dir, "doc-eval.jsonl"), state = join(dir, "doc-state");
  writeFileSync(doc, "> Sibling N2 uses native lane.\n# N1 (gpt-6.1-sol, cloud lane, headed)\n");
  const r = Bun.spawnSync(["python3", resolve(import.meta.dir, "../../eval/worker-digest/worker_ledger.py"), "record", "--digest", file, "--doc", doc, "--worker", "N1", "--failures-ledger", join(dir, "doc-fail.jsonl"), "--eval-ledger", evals, "--state-dir", state]);
  expect(r.exitCode).toBe(0);
  const row = JSON.parse(readFileSync(evals, "utf8"));
  expect(row.lane).toBe("cloud");
  expect(row.meta.tool_health.every((h: any) => h.lane === "cloud")).toBe(true);
  const saved = JSON.parse(readFileSync(join(state, "48160000-0000-4000-8000-000000000000.json"), "utf8"));
  expect(saved.lane).toBe("cloud");
  expect(saved.tool_health.every((h: any) => h.lane === "cloud")).toBe(true);
  expect(read({ ...env, HIMMEL_EVAL_RUNS_LEDGER: evals }).daily[0].lane).toBe("cloud");
});

test("a session with no tool_health is left out of the denominators and counted, so the window keeps its numbers", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  delete rows[0].meta.tool_health;
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env, new URLSearchParams({ days: "30" }));
  // Two sessions are counted (claudex 30 + native 10 Bash calls, 1 + 3 + 1 denials/errors), the third is named in the count.
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 40, failures: 5, rate: 0.125 });
  expect(data.hooks.find((r: any) => r.class === "denied/read-clamp")).toMatchObject({ calls: 40, failures: 4, rate: 0.1 });
  expect(data.totalCalls).toBe(50);
  expect(data.coverage).toMatchObject({ sessions: 2, without_tool_health: 1 });
  expect(read(seed(), new URLSearchParams({ days: "30" })).coverage).toMatchObject({ sessions: 3, without_tool_health: 0 });
});

test("Bash command failures split by the exit code the digest kept", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  for (const h of rows[0].meta.tool_health) if (h.tool === "Bash") h.bash_calls = [["toolu_a", "git", "command", 1], ["toolu_b", "git", "command", 2], ["toolu_c", "git", "command", 1], ["toolu_d", "cat", "guard"], ["toolu_e", "git", null]];
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env, new URLSearchParams({ days: "30" }));
  expect(data.bash.exit_codes).toEqual([{ code: 1, count: 2 }, { code: 2, count: 1 }]);
  expect(data.bash.commands.find((c: any) => c.head === "git")).toMatchObject({ calls: 4, failures: 3, exit: { "1": 2, "2": 1 } });
  expect(data.bash.commands.find((c: any) => c.head === "cat")).toMatchObject({ failures: 1, exit: {} });
});

test("coverage names the rtk sessions and Bash calls that no digest accounts for", () => {
  const env = seed();
  const digested = ["48160000-0000-4000-8000-000000000000", "48160000-0000-4000-8000-000000000001"];
  const sessions = new Map([[digested[0], 10], [digested[1], 30], ["99990000-0000-4000-8000-000000000009", 7], ["99990000-0000-4000-8000-00000000000a", 5]]);
  const rtk: any = () => ({ state: "absent" });
  rtk.coverage = (first: string, last: string) => ({ state: "ok", first, last, sessions });
  const data = (sources as any).readToolHealth(env, new URLSearchParams({ days: "30" }), Date.parse("2026-10-07T23:59:00Z"), { rtk });
  expect(data.coverage.rtk).toEqual({ state: "ok", undigested_sessions: 2, undigested_calls: 12 });
  expect(data.coverage.rtk.first).toBeUndefined();
  const plain = (sources as any).readToolHealth(env, new URLSearchParams(), Date.parse("2026-10-07T23:59:00Z"), { rtk: () => ({ state: "absent" }) });
  expect(plain.coverage.rtk).toEqual({ state: "not-read", undigested_sessions: null, undigested_calls: null });
});

test("a mixed legacy population leaves the legacy session out of every denominator and failure count", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  delete rows[0].meta.tool_health;
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env);
  // The legacy session is counted apart (coverage), so what is left is a clean rate over the sessions that have data.
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 40, failures: 5, rate: 0.125 });
  expect(data.tools.find((r: any) => r.tool === "(unknown)")).toBeUndefined();
  expect(data.tools.reduce((n: number, t: any) => n + t.failures, 0)).toBe(5);
  expect(data.daily.find((r: any) => r.tool === "Bash" && r.lane === "native")).toMatchObject({ calls: 10, rate: 0.1 });
  expect(read(env, new URLSearchParams({ lane: "claudex" })).tools.find((r: any) => r.tool === "Bash").calls).toBe(30);
});

test("a session spanning midnight assigns each call cohort to its actual UTC day", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  for (const h of rows[0].meta.tool_health) h.day = "2026-10-06";
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env);
  expect(data.daily.find((r: any) => r.day === "2026-10-06" && r.tool === "Bash")).toMatchObject({ calls: 10, failures: 3 });
  expect(data.daily.find((r: any) => r.day === "2026-10-07" && r.lane === "native" && r.tool === "Bash")).toMatchObject({ calls: 10, failures: 1 });
});

test("since retains current-day tool cohorts from sessions started before the cutoff", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows[0].meta.started_ts = Date.parse("2026-10-06T23:00:00Z");
  for (const h of rows[0].meta.tool_health) h.day = "2026-10-07";
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env, new URLSearchParams({ since: "2026-10-07T00:00:00Z" }));
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 50, failures: 8 });
});

test("intraday since never presents whole-day calls as an exact shift denominator", () => {
  const data = read(seed(), new URLSearchParams({ since: "2026-10-07T13:00:00Z" }));
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: null, failures: 8, rate: null });
  expect(data.hooks[0]).toMatchObject({ calls: null, rate: null });
  expect(data.daily.find((r: any) => r.tool === "Bash").calls).toBeNull();
  expect(data.daily_hooks[0].calls).toBeNull();
});

test("a very old since keeps the trend to a year and the window honest", () => {
  const data = read(seed(), new URLSearchParams({ since: "1970-01-01T00:00:00Z" }));
  const trend = data.tools.find((r: any) => r.tool === "Bash").trend;
  expect(trend.length).toBe(366);
  expect(trend[365].day).toBe("2026-10-07");
  expect(data.window_days).toBeGreaterThan(20000);
});

test("the trend heading names the since window, not the days switch", async () => {
  const { renderToolHealth } = await import("../public/tool-health.js");
  const html = renderToolHealth({ data: read(seed(), new URLSearchParams({ since: "2026-09-27T00:00:00Z" })) }, "t", { tool: "Bash" });
  expect(html).toContain("11-day trend");
  expect(html).not.toContain("7-day trend");
});

test("v2 text-only subagent failures do not poison complete tool denominators", () => {
  const env = seed();
  const textFailure = { session: "48160000-0000-4000-8000-000000000000", agent: { ...agent, id: "child" }, class: "blocked/report", failure: "blocked", count: 1, recovered: null };
  writeFileSync(env.HIMMEL_WORKER_SESSION_FAILURES_LEDGER, readFileSync(env.HIMMEL_WORKER_SESSION_FAILURES_LEDGER, "utf8") + JSON.stringify(textFailure) + "\n");
  const data = read(env);
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 50, rate: 0.16 });
  expect(data.hooks[0]).toMatchObject({ calls: 50, rate: 0.1 });
});

test("daily hook rates include successful sessions in the same lane population", () => {
  const data = read(seed());
  expect(data.daily_hooks.find((r: any) => r.lane === "native")).toMatchObject({ day: "2026-10-07", calls: 20, failures: 2, rate: 0.1 });
});

test("partial digests preserve observations without claiming complete denominators", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows[0].status = "partial";
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env);
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: null, failures: 8, rate: null });
  expect(data.hooks[0].calls).toBeNull();
});

test("out-of-range numeric timestamps skip malformed rows instead of throwing", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows[0].meta.started_ts = 1e30;
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  expect(read(env).tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 40, failures: 5 });
});

test("missing ledgers degrade to no data", () => {
  expect(read({ HIMMEL_EVAL_RUNS_LEDGER: "/no/evals", HIMMEL_WORKER_SESSION_FAILURES_LEDGER: "/no/failures" })).toMatchObject({ state: "absent", tools: [] });
});

test("authenticated read-only route renders the seeded rates and session drilldown", async () => {
  const token = "a".repeat(64), env = seed();
  const s = startServer({ port: 0, token, now: () => Date.parse("2026-10-07T23:59:00Z"), env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), ...env } });
  try {
    const url = `http://127.0.0.1:${s.port}/api/tool-health`;
    const res = await fetch(url, { headers: { "X-Himmel-Token": token } });
    expect(res.status).toBe(200);
    expect((await fetch(url)).status).toBe(401);
    expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": token } })).status).toBe(405);
    const { renderToolHealth } = await import("../public/tool-health.js");
    const data = await res.json();
    const html = renderToolHealth({ data }, token);
    expect(html).toContain("16.0%");
    expect(html).toContain("10.0%");
    expect(renderToolHealth({ data }, token, { tool: "Bash" })).toContain("48160000-0000-4000-8000-000000000000");
    expect(renderToolHealth(null, token)).toContain("No recorded tool observations in this window");
    expect(renderToolHealth({ data: { state: "absent", selected: { days: 7 } } }, token)).toContain('value="30"');
    data.tools[0].tool = '<img src=x onerror=alert(1)>';
    const escaped = renderToolHealth({ data }, token);
    expect(escaped).not.toContain('<img');
    expect(escaped).toContain('&lt;img');
  } finally { s.stop(); }
});

function seedProfiles() {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows.forEach((r: any, i: number) => { if (i < 2) for (const h of r.meta.tool_health) h.profile = i === 0 ? "leg-impl" : "judge"; });
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const listing = join(dirs[dirs.length - 1], "listing.json");
  writeFileSync(listing, JSON.stringify({ "worker-impl": { Bash: 0, mcp__qmd__query: 900 }, judge: { Read: 0 } }));
  return { ...env, HIMMEL_PROFILE_LISTING: listing };
}

test("the payload carries a per-profile table, listing cost and drop candidates; unlabelled sessions stay unknown", () => {
  const data = read(seedProfiles());
  expect(data.profiles.map((p: any) => p.profile)).toEqual(["judge", "unknown", "worker-impl"]);
  expect(data.profiles.find((p: any) => p.profile === "worker-impl").tools.find((t: any) => t.tool === "Bash")).toMatchObject({ calls: 10, listing_tokens: 0, verdict: "keep" });
  expect(data.drop_candidates).toEqual([expect.objectContaining({ profile: "worker-impl", tool: "mcp__qmd__query", listing_tokens: 900, calls: 0, window_days: 7 })]);
  expect(read(seed()).drop_candidates).toEqual([]);
});

test("a profile whose other sessions have no tool_health never reads a listed tool as unused", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  const [withData, bare] = rows;
  withData.meta.profile = "worker-impl"; for (const h of withData.meta.tool_health) h.profile = "worker-impl";
  bare.meta.profile = "worker-impl"; delete bare.meta.tool_health;
  const nine = Array.from({ length: 9 }, (_, i) => ({ ...structuredClone(bare), run_id: `48160000-0000-4000-8000-00000000010${i}` }));
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, [withData, ...nine].map((r) => JSON.stringify(r)).join("\n") + "\n");
  const listing = join(dirs[dirs.length - 1], "listing.json");
  writeFileSync(listing, JSON.stringify({ "worker-impl": { Bash: 0, mcp__qmd__query: 900 } }));
  const data = read({ ...env, HIMMEL_PROFILE_LISTING: listing }, new URLSearchParams({ days: "30" }));
  const profile = data.profiles.find((p: any) => p.profile === "worker-impl");
  expect(data.coverage).toMatchObject({ sessions: 1, without_tool_health: 9 });
  expect(profile.tools.find((t: any) => t.tool === "mcp__qmd__query")).toMatchObject({ calls: null, verdict: "keep" });
  expect(data.drop_candidates).toEqual([]);
});

test("the default path prices the Skill listing of the real worker-impl, console-judge and chief profiles without a file or a claude run", async () => {
  const { loadRegistry, resolveProfile } = await import("../../lanes/plugin-profiles.mjs");
  const registry = loadRegistry(), profiles = ["worker-impl", "console-judge", "chief"];
  const env: any = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows.forEach((r: any, i: number) => { for (const h of r.meta.tool_health) h.profile = profiles[i]; });
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const ids = new Set<string>();
  for (const p of profiles) for (const [id, on] of Object.entries(resolveProfile(registry, p).enabledPlugins)) if (on) ids.add(id);
  for (const id of ids) {
    const dir = join(env.CLAUDE_CONFIG_DIR, "plugins", "cache", id.split("@")[1], id.split("@")[0], "1.0.0", "skills", "one");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "SKILL.md"), `---\nname: one\ndescription: ${"x".repeat(400)}\n---\nbody\n`);
  }
  expect(env.HIMMEL_PROFILE_LISTING).toBeUndefined();
  const data = read(env);
  const skill = (p: string) => data.profiles.find((x: any) => x.profile === p).tools.find((t: any) => t.tool === "Skill");
  for (const p of profiles) expect(skill(p).listing_tokens).toBeGreaterThan(0);
  expect(skill("chief").listing_tokens).toBeLessThanOrEqual(skill("worker-impl").listing_tokens);
  expect(data.drop_candidates.map((d: any) => d.profile).sort()).toEqual([...profiles].sort());
});

test("a same-named plugin from another marketplace does not inflate the profile's Skill listing", async () => {
  const { loadRegistry, resolveProfile } = await import("../../lanes/plugin-profiles.mjs");
  const enabled = Object.entries(resolveProfile(loadRegistry(), "worker-impl").enabledPlugins).filter(([, on]) => on).map(([id]) => id);
  const skillTokens = (decoy: boolean) => {
    const env: any = seed();
    const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
    rows.forEach((r: any) => { for (const h of r.meta.tool_health) h.profile = "worker-impl"; });
    writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
    const put = (marketplace: string, plugin: string, chars: number) => {
      const dir = join(env.CLAUDE_CONFIG_DIR, "plugins", "cache", marketplace, plugin, "1.0.0", "skills", "one");
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "SKILL.md"), `---\nname: one\ndescription: ${"x".repeat(chars)}\n---\nbody\n`);
    };
    for (const id of enabled) put(id.split("@")[1], id.split("@")[0], 400);
    if (decoy) put("not-enabled-marketplace", enabled[0].split("@")[0], 4000);
    return read(env).profiles.find((p: any) => p.profile === "worker-impl").tools.find((t: any) => t.tool === "Skill").listing_tokens;
  };
  expect(skillTokens(true)).toBe(skillTokens(false));
});

test("the page shows the per-profile table in plain words and labels the unknown bucket", async () => {
  const { renderToolHealth } = await import("../public/tool-health.js");
  const html = renderToolHealth({ data: read(seedProfiles()) }, "t");
  expect(html).toContain("Tools by launch profile");
  expect(html).toContain("worker-impl");
  expect(html).toContain("judge");
  expect(html).toContain("unknown (launch profile not recorded)");
  expect(html).toContain("mcp__qmd__query");
  expect(html).toContain("Move to on-demand (drop from default)");
  expect(html).toContain("Keep");
  const noCost = renderToolHealth({ data: read(seed()) }, "t");
  expect(noCost).toContain("not measured");
  expect(noCost).not.toContain("Move to on-demand");
  const empty = renderToolHealth({ data: { ...read(seed()), profiles: [] } }, "t");
  expect(empty).toContain("No per-profile data");
  const evil = read(seedProfiles());
  evil.profiles[0].profile = "<b>x</b>";
  expect(renderToolHealth({ data: evil }, "t")).not.toContain("<b>x</b>");
});

test("the page renders the role x lane x profile cross-tab and names the unknown remainder", async () => {
  const { renderToolHealth } = await import("../public/tool-health.js");
  const env = seedSplit();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows[2].lane = "unknown"; rows[2].meta.launch_gap = "release-manager";
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map((r: any) => JSON.stringify(r)).join("\n") + "\n");
  const html = renderToolHealth({ data: read(env) }, "t");
  expect(html).toContain("Role, lane and profile");
  expect(html).toContain('data-cross-tab="worker native worker-impl"');
  expect(html).toContain('data-cross-tab="judge claudex console-judge"');
  expect(html).toContain('data-cross-tab="other unknown unknown"');
  expect(html).toContain("Lane unknown: 14.3% of calls (1 of 3 sessions)");
  expect(html).toContain("release-manager (1 sessions, 10 calls)");
});

test("Tool health navigation carries tokens only in fragments", () => {
  const token = "a".repeat(64);
  const link = navLinks({ here: "agui", token, current: "fleet" }).find((r: any) => r.id === "toolhealth");
  expect(link?.href).toBe(`/#t=${token}&page=toolhealth`);
  expect(parseLanding(`#t=${token}&page=toolhealth`)?.page).toBe("toolhealth");
});

// Spec 0.4 a/d: profile to role, and Bash by command and cause joined to rtk history.
function seedSplit() {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  const profiles = ["worker-impl", "console-judge", undefined];
  const calls = [[["toolu_a", "git", null], ["toolu_b", "git", "command"], ["toolu_c", "cat", "guard"]], [["toolu_d", "gh", "classifier"]], [["toolu_e", "other", "other"]]];
  rows.forEach((r: any, i: number) => { for (const h of r.meta.tool_health) { if (profiles[i]) h.profile = profiles[i]; if (h.tool === "Bash") h.bash_calls = calls[i]; } });
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  return env;
}
const readRtk = (env: object, rtk: any, query = new URLSearchParams()) => (sources as any).readToolHealth(env, query, Date.parse("2026-10-07T23:59:00Z"), { rtk });

test("roles map from the launch profile, sum to the fleet, and an unmapped profile is other", async () => {
  const { teamOf } = await import("../../eval/worker-digest/tool-health.mjs");
  expect([teamOf("worker-impl"), teamOf("design-ui"), teamOf("console-judge"), teamOf("unknown"), teamOf("made-up")]).toEqual(["worker", "worker", "judge", "other", "other"]);
  const data = read(seedSplit());
  expect(data.teams).toEqual([
    { team: "worker", sessions: 1, calls: 20, failures: 3 },
    { team: "judge", sessions: 1, calls: 40, failures: 4 },
    { team: "other", sessions: 1, calls: 10, failures: 1 },
  ]);
  expect(data.teams.reduce((n: number, t: any) => n + t.calls, 0)).toBe(data.totalCalls);
  const one = read(seedSplit(), new URLSearchParams({ team: "judge" }));
  expect(one.tools.find((r: any) => r.tool === "Bash").calls).toBe(30);
  expect(one.teams).toHaveLength(3);
  expect(read(seedSplit(), new URLSearchParams({ team: "nonsense" })).selected.team).toBe("");
});

test("the role x lane x profile cross-tab sums to the fleet and the unknown share is named, not inferred", async () => {
  const { teamOf } = await import("../../eval/worker-digest/tool-health.mjs");
  expect([teamOf("console"), teamOf("console-relay"), teamOf("leg-impl"), teamOf("worker-docs"), teamOf("worker-eval")]).toEqual(["chief", "chief-relay", "worker", "worker", "worker"]);
  const data = read(seedSplit());
  expect(data.cross_tab).toEqual([
    { team: "judge", lane: "claudex", profile: "console-judge", sessions: 1, calls: 40, failures: 4, denials: 3 },
    { team: "other", lane: "native", profile: "unknown", sessions: 1, calls: 10, failures: 1, denials: 1 },
    { team: "worker", lane: "native", profile: "worker-impl", sessions: 1, calls: 20, failures: 3, denials: 1 },
  ]);
  expect(data.cross_tab.reduce((n: number, c: any) => n + c.calls, 0)).toBe(data.totalCalls);
  expect(data.attribution).toMatchObject({ calls: 70, lane_unknown_calls: 0, lane_unknown_share: 0, profile_unknown_calls: 10, remainder: [] });
  expect(data.attribution.profile_unknown_share).toBeCloseTo(10 / 70);
  // a session no launch record names stays unknown, and the remainder says what kind of session it was
  const env = seedSplit();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows[2].lane = "unknown"; rows[2].meta.launch_gap = "release-manager";
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map((r: any) => JSON.stringify(r)).join("\n") + "\n");
  const gap = read(env).attribution;
  expect(gap.remainder).toEqual([{ kind: "release-manager", sessions: 1, calls: 10 }]);
  expect(gap).toMatchObject({ lane_unknown_calls: 10, lane_unknown_sessions: 1, sessions: 3 });
  // a row written before the kind was kept is named for what it is
  delete rows[2].meta.launch_gap;
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map((r: any) => JSON.stringify(r)).join("\n") + "\n");
  expect(read(env).attribution.remainder).toEqual([{ kind: "not-restamped", sessions: 1, calls: 10 }]);
});

test("a PreToolUse deny on an mcp tool rolls up as a denial of that tool, not an error", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows[0].meta.tool_health.push({ agent, lane: "native", tool: "mcp__himmel-bus__read", calls: 2, failures: 2, errors: 1, denials: 1, classes: { "denied/guard-leg-context-handoff": 1, "error/mcp": 1 } });
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map((r: any) => JSON.stringify(r)).join("\n") + "\n");
  const mcp = read(env).tools.find((t: any) => t.tool === "mcp__himmel-bus__read");
  expect(mcp).toMatchObject({ calls: 2, failures: 2, errors: 1, denials: 1 });
});

test("Bash rolls up by command head and cause; rtk joins by call id and a missing history stays unread", async () => {
  const env = seedSplit();
  const byId = new Map([["toolu_a", { path: "rtk", deny: false }], ["toolu_c", { path: "bash", deny: true }], ["toolu_d", { path: "bash", deny: false }]]);
  const data = readRtk(env, () => ({ state: "ok", byId, duplicates: 1 }));
  expect(data.bash.commands).toEqual([
    { head: "git", calls: 2, failures: 1, cause: { command: 1, rtk_hook: 0, guard: 0, classifier: 0, other: 0 }, exit: {}, rtk: 1, bash: 0 },
    { head: "cat", calls: 1, failures: 1, cause: { command: 0, rtk_hook: 1, guard: 0, classifier: 0, other: 0 }, exit: {}, rtk: 0, bash: 1 },
    { head: "gh", calls: 1, failures: 1, cause: { command: 0, rtk_hook: 0, guard: 0, classifier: 1, other: 0 }, exit: {}, rtk: 0, bash: 1 },
    { head: "other", calls: 1, failures: 1, cause: { command: 0, rtk_hook: 0, guard: 0, classifier: 0, other: 1 }, exit: {}, rtk: 0, bash: 0 },
  ]);
  expect(data.bash).toMatchObject({ recorded: 5, unrecorded: 45, rtk: { state: "ok", matched: 3, unmatched: 2, duplicates: 1 },
    fleet: { rtk: { calls: 1, failures: 0 }, bash: { calls: 2, failures: 2 }, unmatched: { calls: 2, failures: 2 } } });
  const native = readRtk(env, () => ({ state: "ok", byId, duplicates: 0 }), new URLSearchParams({ lane: "native" }));
  expect(native.bash.commands.map((c: any) => c.head)).toEqual(["git", "cat", "other"]);
  expect(native.bash.fleet.bash.calls).toBe(2);
  expect(read(env).bash.rtk.state).toBe("absent"); // the page's default join, over a HOME with no history.db
  const { readToolHealth: rollupOnly } = await import("../../eval/worker-digest/tool-health.mjs");
  const unread = rollupOnly(env, new URLSearchParams(), Date.parse("2026-10-07T23:59:00Z"));
  expect(unread.bash.rtk).toEqual({ state: "not-read", matched: null, unmatched: null, duplicates: null });
  expect(unread.bash.fleet).toBeNull();
  expect(unread.bash.commands[0].rtk).toBeNull();
  expect(unread.bash.commands[0].bash).toBeNull();
  expect(readRtk(env, () => ({ state: "absent" })).bash.rtk.state).toBe("absent");
  expect(readRtk(env, () => { throw new Error("locked"); }).bash.rtk.state).toBe("error");
});

// Build spec section 4 fixture P (P1-P3 on 26-28 Oct) and the v9 page proofs P-A1 to P-A19.
const P_NOW = Date.parse("2026-10-28T23:59:00Z");
function seedP(drop?: (rows: any[]) => void) {
  const env = seed();
  const days = ["2026-10-26", "2026-10-27", "2026-10-28"], profiles = ["worker-impl", "judge", "worker-impl"];
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows.forEach((r: any, i: number) => { r.meta.started_ts = Date.parse(`${days[i]}T12:00:00Z`); for (const h of r.meta.tool_health) { h.day = days[i]; h.profile = profiles[i]; } });
  drop?.(rows);
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const listing = join(dirs[dirs.length - 1], "listing.json");
  writeFileSync(listing, JSON.stringify({ "worker-impl": { mcp__qmd__query: 900 }, judge: { Read: 0 } }));
  return { ...env, HIMMEL_PROFILE_LISTING: listing };
}
const readP = (env: object, query = new URLSearchParams()) => (sources as any).readToolHealth(env, query, P_NOW, { rtk: () => ({ state: "absent" }) });
const LOADED = Date.parse("2026-10-28T23:59:30Z");
async function page(data: any, ui: any = {}, extra: any = {}) {
  const { renderToolHealth } = await import("../public/tool-health.js");
  return renderToolHealth({ data, loadedAt: LOADED, ...extra }, "t", ui) as string;
}
const kpi = (html: string, id: string) => (new RegExp(`data-kpi="${id}"[^>]*>[\\s\\S]*?<b class="kv">([^<]*)</b>`).exec(html) || [])[1];
const kpiSub = (html: string, id: string) => (new RegExp(`data-kpi="${id}"[^>]*>[\\s\\S]*?<span class="ks">([^<]*)</span>`).exec(html) || [])[1];
const recoveryNote = (html: string) => (/<p class="sub" data-note="recovery">([^<]*)</.exec(html) || [])[1] || "";
const cells = (html: string, attr: string) => [...html.matchAll(new RegExp(`<tr ${attr}="([^"]*)"[^>]*>([\\s\\S]*?)</tr>`, "g"))].map((m) => [m[1], [...m[2].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((c) => c[1].replace(/<[^>]*>/g, ""))]);

test("overview-call-total-is-the-tool-attempt-sum", async () => {
  const data = readP(seedP());
  expect(data.totalCalls).toBe(70);
  expect(data.tools.reduce((n: number, t: any) => n + t.calls, 0)).toBe(70);
  expect(kpi(await page(data), "calls")).toBe("70");
  const u = readP(seedP((rows) => { delete rows[0].meta.tool_health; }));
  expect(u.totalCalls).toBe(50);
  expect(u.coverage.without_tool_health).toBe(1);
});

test("overview-failure-rate-is-weighted", async () => {
  const html = await page(readP(seedP()));
  expect(kpi(html, "failed")).toBe("8");
  expect(kpiSub(html, "failed")).toContain("3 errors · 5 denied");
  expect(kpi(html, "rate")).toBe("11.4%");
  expect(kpiSub(html, "rate")).toContain("8 of 70 calls");
});

test("denied-attempts-are-not-hooks-plus-tools", async () => {
  const data = readP(seedP());
  expect(kpiSub(await page(data), "failed")).toContain("5 denied");
  data.tools.find((t: any) => t.tool === "Bash").denials = 60;
  const bad = await page(data);
  expect(bad).toContain("Count check failed");
  expect(kpi(bad, "rate")).toBe("—");
  expect(cells(bad, "data-tool-row").find(([k]) => k === "Bash")?.[1]).not.toContain("16.0%");
});

test("overview-recovery-keeps-unknown-class-outcomes-out", async () => {
  const data = readP(seedP());
  const html = await page(data);
  expect(recoveryNote(html)).toContain("25.0% (1 of 4 known · 4 unclassified)");
  for (const t of data.tools) { t.known = 0; t.recovered = 0; }
  expect(recoveryNote(await page(data))).toContain("Recovery —");
});

test("overview-daily-failures-reconcile", async () => {
  const rows = cells(await page(readP(seedP())), "data-day");
  expect(rows.map(([d]) => d)).toEqual(["2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27", "2026-10-28"]);
  for (const [, c] of rows.slice(0, 4)) expect(c.slice(1)).toEqual(["—", "—", "—"]);
  expect(rows.slice(4).map(([, c]) => c[2])).toEqual(["3", "4", "1"]);
});

test("daily-rate-sums-cohorts-before-dividing", async () => {
  const rows = cells(await page(readP(seedP())), "data-day").slice(4);
  expect(rows.map(([, c]) => c[3])).toEqual(["15.0%", "10.0%", "10.0%"]);
  expect(rows[1][1].join(" ")).not.toContain("6.7%");
});

test("tool-ranking-counts-not-percentages", async () => {
  const data = readP(seedP());
  const extra = (tool: string) => ({ ...data.tools.find((t: any) => t.tool === "Read"), tool, calls: 1, failures: 0 });
  data.tools.push(extra("<b>z</b>"), extra("a&b"));
  const html = await page(data);
  expect(cells(html, "data-tool-row").map(([k]) => k)).toEqual(["Bash", "&lt;b&gt;z&lt;/b&gt;", "Read", "a&amp;b"]);
  expect(html).not.toContain("<b>z</b>");
  expect(cells(html, "data-tool-row")[0][1]).toEqual(expect.arrayContaining(["50", "8", "3", "5", "16.0%"]));
});

test("tool-drill-retains-population-and-counts", async () => {
  const env = seedP();
  const stats = (html: string) => ["calls", "failed", "errors", "denied"].map((k) => (new RegExp(`data-stat="${k}"[^>]*>([^<]*)<`).exec(html) || [])[1]);
  expect(stats(await page(readP(env), { tool: "Bash" }))).toEqual(["50", "8", "3", "5"]);
  const native = await page(readP(env, new URLSearchParams({ lane: "native" })), { tool: "Read", filters: { days: "7", lane: "native" } });
  expect(stats(native)).toEqual(["10", "0", "0", "0"]);
  expect(stats(await page(readP(env, new URLSearchParams({ lane: "native" })), { tool: "Bash" }))).toEqual(["20", "4", "2", "2"]);
  const none = await page(readP(env), { tool: "Nope", filters: { days: "7", lane: "native" } });
  expect(none).toContain("No matching tool");
  expect(none).toMatch(/href="#\/toolhealth\?[^"]*lane=native[^"]*"[^>]*>Back to overview/);
});

test("full-trend-uses-rate-not-spark-height", async () => {
  const rows = cells(await page(readP(seedP()), { tool: "Bash" }), "data-trend-day").slice(4);
  expect(rows.map(([, c]) => c[3])).toEqual(["30.0%", "13.3%", "10.0%"]);
});

test("tool-class-rate-uses-own-denominator", async () => {
  const rows = Object.fromEntries(cells(await page(readP(seedP()), { tool: "Bash" }), "data-class").map(([k, c]) => [k, c.slice(1)]));
  expect(rows["denied/read-clamp"]).toEqual(["5", "10.0%"]);
  expect(rows["error/Bash"]).toEqual(["3", "6.0%"]);
});

test("evidence-is-sampled-and-session-ids-are-validated", async () => {
  const data = readP(seedP());
  data.tools.find((t: any) => t.tool === "Bash").sessions.push("not-a-uuid", data.tools[0].sessions[0]);
  const html = await page(data, { tool: "Bash" });
  expect(html.match(/href="\/agui\/#t=t&amp;run=48160000-[^"]*"/g)).toHaveLength(3);
  expect(html).not.toContain("run=not-a-uuid");
  expect(html).toContain("not-a-uuid");
  expect(html).not.toMatch(/\?t=/);
  expect(html).toContain("Sampled call ids");
  expect(html).toContain("3 sessions with observations");
});

test("every-guard-rate-names-the-legacy-denominator", async () => {
  const data = readP(seedP());
  data.hooks.push({ ...data.hooks[0], class: "denied/classifier:shell", failures: 1, rate: 0.02 });
  const html = await page(data);
  const guards = cells(html, "data-guard-row");
  expect(guards.map(([k]) => k)).toEqual(["denied/read-clamp"]);
  expect(guards[0][1]).toEqual(expect.arrayContaining(["5", "10.0%", "÷50 Bash calls (legacy)"]));
  const cls = cells(html, "data-classifier-row");
  expect(cls.map(([k]) => k)).toEqual(["denied/classifier:shell"]);
  expect(cls[0][1].join(" ")).toContain("category");
  expect(html).toContain("reason unverified");
});

test("guard-daily-chart-reconciles-with-guard-total", async () => {
  const html = await page(readP(seedP()), { guard: "denied/read-clamp" });
  const rows = cells(html, "data-guard-day").filter(([, c]) => c[1] !== "—");
  expect(rows.map(([, c]) => c[1])).toEqual(["1", "3", "1"]);
  expect(html).toMatch(/data-stat="refused"[^>]*>5</);
  expect(await page(readP(seedP()), { guard: "denied/nope" })).toContain("No matching guard");
});

test("lane-deltas-have-explicit-units", async () => {
  const rows = Object.fromEntries(cells(await page(readP(seedP())), "data-lane-metric").map(([k, c]) => [k, c]));
  expect(rows.calls_per_100).toEqual(expect.arrayContaining(["66.7", "75.0", "+8.3 calls/100"]));
  expect(rows.error_rate).toEqual(expect.arrayContaining(["10.0%", "3.3%", "−6.7 pp"]));
});

test("profile-drill-sessions-are-distinct", async () => {
  const data = readP(seedP());
  data.profiles.push({ profile: "unknown", sessions: 1, tools: [] });
  const html = await page(data);
  const rows = cells(html, "data-profile-tool").map(([k, c]) => [k, c.slice(1, 3)]);
  expect(rows).toEqual(expect.arrayContaining([["worker-impl Bash", ["2", "20"]], ["worker-impl Read", ["2", "10"]], ["judge Bash", ["1", "30"]], ["judge Read", ["1", "10"]]]));
  expect(html).toContain("unknown (launch profile not recorded)");
});

test("candidate-cost-is-per-listing-not-savings", async () => {
  const html = await page(readP(seedP()));
  const rows = cells(html, "data-candidate");
  expect(rows).toEqual([["worker-impl mcp__qmd__query", ["worker-impl", "mcp__qmd__query", "0 calls", "900 tokens per listing"]]]);
  expect(html).not.toMatch(/sav(e|ing)/i);
});

test("filters-use-api-enums-and-calendar-window", async () => {
  const data = readP(seedP());
  expect(data.window_days).toBe(7);
  const html = await page(data);
  expect(html).toContain("22–28 Oct 2026");
  expect(html).toContain('<option value="7" selected>7 UTC days</option>');
  const opts = (name: string) => [...((new RegExp(`data-tool-filter="${name}"[^>]*>([\\s\\S]*?)</select>`).exec(html) || [])[1] || "").matchAll(/value="([^"]*)"[^>]*>([^<]*)</g)].map((m) => `${m[1]}=${m[2]}`);
  expect(opts("team")).toEqual(["=All", "worker=workers", "other=other"]);
  expect(opts("profile")).toEqual(["=All", "judge=judge", "worker-impl=worker-impl"]);
  expect(opts("lane")[0]).toBe("=All");
});

test("latest-fetch-wins-with-stale-response-label", async () => {
  const { toolHealthLoader } = await import("../public/tool-health.js");
  const data = readP(seedP());
  const later: Record<string, (v: any) => void> = {};
  let clock = Date.parse("2026-10-28T09:12:00Z"), paints = 0;
  const loader = toolHealthLoader({ get: (q: string) => new Promise((ok, no) => { later[q] = (v) => v instanceof Error ? no(v) : ok(v); }), now: () => clock, onChange: () => { paints++; } });
  const a = loader.load("A"), b = loader.load("B");
  expect(loader.state.loading).toBe(true);
  later.B({ ...data, tag: "B" }); await b;
  later.A({ ...data, tag: "A" }); await a;
  expect(loader.state.data.tag).toBe("B");
  expect(loader.state.loadedAt).toBe(Date.parse("2026-10-28T09:12:00Z"));
  clock += 3600_000;
  const c = loader.load("C"); later.C(new Error("down")); await c;
  expect(loader.state.data.tag).toBe("B");
  const { renderToolHealth } = await import("../public/tool-health.js");
  const html = renderToolHealth(loader.state, "t", {});
  expect(html).toContain("Tool health could not load. Retry.");
  expect(html).toContain("stale since 09:12 UTC");
  expect(html).toContain("Loaded at 2026-10-28 09:12 UTC");
  expect(html).not.toMatch(/as of/i);
  expect(paints).toBeGreaterThan(0);
  expect(renderToolHealth({ loading: true }, "t", {})).toContain("Loading recorded observations…");
  expect(renderToolHealth({ data, loading: true, loadedAt: LOADED }, "t", {})).toContain("Refreshing; showing previous response");
});

const INVENTORY = {
  state: "ok", scanned_at: "2026-10-28T23:00:00.000Z",
  sources: [{ id: "plugins", reads: "~/.claude/plugins/installed_plugins.json", state: "ok", found: { on: 1, installed: 2 } }, { id: "core", reads: "a recorded session", state: "absent", reason: "needs a session record", found: null }],
  tools: [{ kind: "skill", source: "alpha@himmel", name: "alpha:one" }, { kind: "agent", source: "project", name: "judge" }, { kind: "mcp", source: "mcp-config", name: "qmd", configured_in: ["mcp-profiles"], loads_in_chief: true }],
  hooks: [{ kind: "hook", source: "project", name: "read-clamp.sh", wired: [["PreToolUse", "Bash"]], runs_twice: false }],
  clis: [{ name: "rtk", path: "~/bin/rtk", version: "9.9.9", state: "ok" }, { name: "qmd", path: null, version: null, state: "absent" }],
};

test("every tool row and map tile's tool opens a drill-in; none is a dead click", async () => {
  const data = readP(seedP());
  const overview = await page(data, { all: true }, { inventory: INVENTORY });
  const rows = cells(overview, "data-tool-row");
  expect(rows.map(([k]) => k).sort()).toEqual(["Agent:judge", "Bash", "Read", "Skill:alpha:one", "mcp__qmd"].sort());
  for (const [key] of rows) {
    const link = new RegExp(`<a [^>]*data-tool="${key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"[^>]*href="#/toolhealth\\?[^"]*tool=`);
    expect(overview).toMatch(link);
    const drill = await page(data, { tool: key.replace(/&amp;/g, "&") }, { inventory: INVENTORY });
    expect(drill).not.toContain("No matching tool");
    expect(drill).toContain("Back to overview");
  }
  expect(await page(data, { tool: "Skill:alpha:one" }, { inventory: INVENTORY })).toContain("No recorded calls in this window");
  const map = await page(data, { tab: "map" }, { inventory: INVENTORY });
  const tiles = [...map.matchAll(/data-act="th-pick" data-src="([^"]*)" data-kind="([^"]*)"/g)].map((m) => [m[1], m[2]]);
  expect(tiles.length).toBeGreaterThan(0);
  for (const [src, kind] of tiles) {
    const picked = await page(data, { tab: "map", src, kind }, { inventory: INVENTORY });
    const listed = cells(picked, "data-tool-row");
    expect(listed.length).toBeGreaterThan(0);
    for (const [key] of listed) expect(picked).toContain(`data-tool="${key}"`);
  }
});

test("the page paints under the server CSP: widths ride data attributes, never an inline style", async () => {
  const data = readP(seedP());
  const html = (await page(data, {}, { inventory: INVENTORY })) + (await page(data, { tab: "map" }, { inventory: INVENTORY }));
  expect(html).not.toMatch(/\sstyle=/);
  expect(html).toMatch(/class="thbar" data-w="[0-9.]+"/);
  expect(html).toMatch(/class="thmap" data-cols="[0-9]+"/);
  const app = readFileSync(resolve(import.meta.dir, "../public/app.js"), "utf8");
  expect(app).toContain('setProperty("--w"');
  expect(app).toContain('setProperty("--cols"');
});

test("a failed rescan or reviewers refresh keeps the last answer and says it is stale", async () => {
  const data = readP(seedP());
  expect(await page(data, { tab: "station" }, { inventory: { ...INVENTORY, stale: "down" } })).toContain("Rescan failed (down); showing the scan from");
  const text = "# Reviewers\n\nCaught 8 of 10.\n";
  expect(await page(data, { tab: "reviewers" }, { reviewers: { state: "ok", writtenAt: "2026-10-26T03:00:00Z", text, stale: "down" } })).toContain("Refresh failed (down); showing the page read earlier");
  expect(await page(data, { tab: "reviewers" }, { reviewers: { state: "ok", writtenAt: "2026-10-26T03:00:00Z", text } })).not.toContain("Refresh failed");
  const app = readFileSync(resolve(import.meta.dir, "../public/app.js"), "utf8");
  expect(app).toContain("stale: inv.error");
  expect(app).toContain("stale: rv.error");
});

test("Reset filters clears the page-memory filters and repaints, also when its link is the current hash", () => {
  const app = readFileSync(resolve(import.meta.dir, "../public/app.js"), "utf8");
  const src = app.match(/function toolHealthClick\(b\) \{[\s\S]*?\n\}/)![0];
  const thUi: any = { kind: "mcp", src: "project", q: "git", group: "g", all: true, before: true, sorts: {} };
  let painted = 0;
  const click = new Function("thUi", "paint", "thLoaders", `${src}; return toolHealthClick;`)(thUi, () => { painted++; }, () => ({}));
  click({ dataset: { act: "th-reset" } });
  expect(thUi).toMatchObject({ kind: null, src: null, q: "", group: null, all: false, before: false });
  expect(painted).toBe(1);
});

test("a hook on a non-tool event has no derived runs, and a command's bash count leaves out unmatched calls", async () => {
  const data = readP(seedP());
  const bashCalls = data.tools.find((t: any) => t.tool === "Bash").calls;
  const inventory = { ...INVENTORY, hooks: [...INVENTORY.hooks, { kind: "hook", source: "alpha@himmel", name: "start.sh", wired: [["SessionStart", "*"]], runs_twice: false }] };
  const hooks = Object.fromEntries(cells(await page(data, { kind: "hook" }, { inventory }), "data-tool-row"));
  expect(hooks["hook:alpha@himmel:start.sh"][2]).toBe("— runs derived");
  expect(hooks["hook:project:read-clamp.sh"][2]).toBe(`${bashCalls} runs derived`);
  const bash = { ...data.bash, rtk: { state: "ok", matched: 2, unmatched: 1, duplicates: 0 }, commands: [{ head: "git", calls: 3, failures: 0, cause: {}, rtk: 1, bash: 1 }] };
  const cmds = Object.fromEntries(cells(await page({ ...data, bash }, { tool: "Bash" }), "data-command"));
  expect(cmds.git).toEqual(["git", "3", "1", "1", "0"]);
});

// ---- refused-tool attribution and the option-B guard rate. Hand-built ledger rows, no writer, no HOME.
const B_NOW = Date.parse("2026-10-28T23:59:00Z");
const bSession = (n: number) => "48160000-0000-4000-8000-0000000001" + String(n).padStart(2, "0");
const bEval = (n: number, health?: any[], over: any = {}) => ({ eval: "leg-trajectory", run_id: bSession(n), status: "ok", ts: "2026-10-28T12:00:00Z", lane: "native", model: "gpt-6.1-sol", config: {},
  meta: { leg: true, started_ts: Date.parse("2026-10-28T12:00:00Z"), profile: "worker-impl", ...(health ? { tool_health: health } : {}) }, ...over });
const bTool = (tool: string, calls: number, classes: Record<string, number> = {}) => {
  const denials = Object.values(classes).reduce((n, v) => n + v, 0);
  return { agent, tool, calls, failures: denials, errors: 0, denials, classes, day: "2026-10-28" };
};
const bFail = (n: number, cls: string, count: number, ids: string[] = [], span: [string, string] | null = null) => ({ session: bSession(n), agent, class: cls, failure: cls.split("/")[0], count, recovered: null, tool_call_ids: ids,
  ...(span ? { first_ts: Date.parse(span[0]), last_ts: Date.parse(span[1]) } : {}) });
const roll = (evals: any[], failures: any[], opts: any = {}) => rollupToolHealth(evals, failures, new URLSearchParams(), B_NOW, {}, opts);
const guardOf = (d: any, cls: string) => d.hooks.find((h: any) => h.class === cls);
const readPE = (env: object, eligible: any) => (sources as any).readToolHealth(env, new URLSearchParams(), P_NOW, { rtk: () => ({ state: "absent" }), eligible });
const SECRETS = ["Bash", "PowerShell", "Read", "Grep"], CLAMP = ["Bash", "Read", "Grep"];
const WIRED = { "block-read-secrets": SECRETS, "read-clamp": CLAMP, "block-write-into-main-checkout": ["Bash"] };
// Fixture Q: Bash 4, Read 3, Grep 2, PowerShell 1 calls; three secrets refusals, one read-clamp, one write-into-main.
const qEvals = () => [bEval(1, [bTool("Bash", 4, { "denied/block-read-secrets": 1, "denied/block-write-into-main-checkout": 1 }),
  bTool("Read", 3, { "denied/block-read-secrets": 1, "denied/read-clamp": 1 }), bTool("Grep", 2), bTool("PowerShell", 1, { "denied/block-read-secrets": 1 })])];
const qFails = () => [bFail(1, "denied/block-read-secrets", 3), bFail(1, "denied/read-clamp", 1), bFail(1, "denied/block-write-into-main-checkout", 1)];

test("eligible-tools-follow-effective-matchers", () => {
  const d = roll(qEvals(), qFails(), { eligible: WIRED });
  expect(guardOf(d, "denied/block-read-secrets")).toMatchObject({ failures: 3, eligible_calls: 10, eligible_rate: 0.3, eligible_by_tool: { Bash: 4, PowerShell: 1, Read: 3, Grep: 2 } });
  expect(guardOf(d, "denied/read-clamp")).toMatchObject({ eligible_calls: 9, eligible_rate: 1 / 9 });
  expect(guardOf(d, "denied/block-write-into-main-checkout")).toMatchObject({ eligible_calls: 4, eligible_rate: 0.25 });
  expect(d.totalCalls).toBe(10); // the three eligible sums overlap; none of them is the fleet total
  // A changed wiring changes the series fingerprint; an unchanged one keeps it. A wired tool nobody called reads 0 calls.
  const wider = roll(qEvals(), qFails(), { eligible: { ...WIRED, "block-write-into-main-checkout": ["Bash", "Edit"] } });
  expect(guardOf(wider, "denied/block-write-into-main-checkout")).toMatchObject({ eligible_calls: 4, eligible_by_tool: { Bash: 4, Edit: 0 } });
  expect(wider.eligible_fingerprint).not.toBe(d.eligible_fingerprint);
  expect(roll(qEvals(), qFails(), { eligible: { ...WIRED } }).eligible_fingerprint).toBe(d.eligible_fingerprint);
  // A matcher is a pattern over tool names: mcp__.* takes every recorded MCP tool, once.
  const mcp = roll([bEval(1, [bTool("Bash", 4), bTool("mcp__qmd__query", 6, { "denied/block-mcp": 2 })])], [bFail(1, "denied/block-mcp", 2)], { eligible: { "block-mcp": ["mcp__.*"] } });
  expect(guardOf(mcp, "denied/block-mcp")).toMatchObject({ eligible_calls: 6, eligible_rate: 2 / 6 });
});

test("a guard wired to Agent or Skill counts the split Agent:<type> and Skill:<plugin>:<skill> calls", () => {
  const split = roll([bEval(1, [bTool("Bash", 4), bTool("Agent:judge", 3, { "denied/guard-subagent-model": 1 }), bTool("Agent:explore", 2),
    bTool("Skill:alpha:one", 2, { "denied/skill-guard": 1 })])], [bFail(1, "denied/guard-subagent-model", 1), bFail(1, "denied/skill-guard", 1)],
  { eligible: { "guard-subagent-model": ["Agent"], "skill-guard": ["Skill"] } });
  expect(guardOf(split, "denied/guard-subagent-model")).toMatchObject({ eligible_calls: 5, eligible_rate: 1 / 5, outside_eligible: 0, eligible_by_tool: { Agent: 5 } });
  expect(guardOf(split, "denied/skill-guard")).toMatchObject({ eligible_calls: 2, eligible_rate: 1 / 2, outside_eligible: 0, eligible_by_tool: { Skill: 2 } });
});

test("an unknown matcher or an incomplete cohort gives no eligible denominator, never a Bash fallback", () => {
  const none = roll(qEvals(), qFails(), { eligible: { "read-clamp": CLAMP } });
  expect(guardOf(none, "denied/block-read-secrets")).toMatchObject({ failures: 3, eligible_calls: null, eligible_rate: null, eligible_by_tool: null });
  const off = roll(qEvals(), qFails(), { eligible: null });
  expect(guardOf(off, "denied/read-clamp")).toMatchObject({ eligible_calls: null, eligible_rate: null });
  expect(off.eligible_fingerprint).toBeNull();
  expect(roll(qEvals(), qFails()).eligible_fingerprint).toBeNull(); // the chief board passes no map
  const partial = roll([bEval(1, (qEvals()[0].meta as any).tool_health, { status: "partial" })], qFails(), { eligible: WIRED });
  expect(guardOf(partial, "denied/block-read-secrets")).toMatchObject({ failures: 3, eligible_calls: null, eligible_rate: null });
  // A refusal on a tool outside the wired set is a count check failure: no rate, the surplus shown.
  const stray = roll([bEval(1, [bTool("Bash", 4), bTool("Edit", 2, { "denied/read-clamp": 1 })])], [bFail(1, "denied/read-clamp", 1)], { eligible: { "read-clamp": CLAMP } });
  expect(guardOf(stray, "denied/read-clamp")).toMatchObject({ eligible_calls: 4, eligible_rate: null, outside_eligible: 1 });
});

test("denial-attribution-preserves-actual-tool-and-legacy-unknown", () => {
  // L: a legacy session, no tool cohorts, one denial that names no tool.
  const legacy = roll([bEval(1)], [bFail(1, "denied/read-clamp", 1)]);
  expect(legacy.tools.find((t: any) => t.tool === "Bash")).toBeUndefined();
  expect(legacy.tools.find((t: any) => t.tool === "(unknown)")).toMatchObject({ failures: 1, denials: 1, calls: null });
  expect(guardOf(legacy, "denied/read-clamp")).toMatchObject({ failures: 1, by_tool: { "(unknown)": 1 }, unattributed: 0, rate: null });
  // An error class still names its tool, so only denials lose the Bash guess.
  const mixed = roll([bEval(1)], [bFail(1, "denied/read-clamp", 1), bFail(1, "error/Bash", 2)]);
  expect(mixed.tools.find((t: any) => t.tool === "Bash")).toMatchObject({ failures: 2, denials: 0 });
  // An explicit Read denial with Read calls lands on Read, not Bash.
  const modern = roll([bEval(1, [bTool("Bash", 10), bTool("Read", 5, { "denied/read-clamp": 1 })])], [bFail(1, "denied/read-clamp", 1)]);
  expect(modern.tools.find((t: any) => t.tool === "Read")).toMatchObject({ calls: 5, denials: 1 });
  expect(modern.tools.find((t: any) => t.tool === "Bash")).toMatchObject({ calls: 10, denials: 0 });
  expect(guardOf(modern, "denied/read-clamp")).toMatchObject({ failures: 1, by_tool: { Read: 1 }, unattributed: 0 });
  // A legacy session beside a modern one is left out and counted (coverage), so the split adds up over the sessions that have data.
  const both = roll([bEval(1), bEval(2, [bTool("Bash", 10), bTool("Read", 5, { "denied/read-clamp": 2 })])], [bFail(1, "denied/read-clamp", 1), bFail(2, "denied/read-clamp", 2)]);
  const g = guardOf(both, "denied/read-clamp");
  expect(g.failures).toBe(2);
  expect(g.by_tool).toEqual({ Read: 2 });
  expect(both.coverage).toMatchObject({ sessions: 1, without_tool_health: 1 });
});

test("a guard table row shows the option-B rate beside the legacy rate", async () => {
  const row = (cells(await page(readPE(seedP(), { "read-clamp": CLAMP })), "data-guard-row")[0] as any)[1];
  expect(row).toEqual(expect.arrayContaining(["5", "7.14%", "÷70 eligible call attempts", "10.0%", "÷50 Bash calls (legacy)"]));
  const none = (cells(await page(readPE(seedP(), null)), "data-guard-row")[0] as any)[1];
  expect(none).toEqual(expect.arrayContaining(["5", "—", "eligible tools unknown", "10.0%", "÷50 Bash calls (legacy)"]));
});

test("the guard drill-in splits the refusals by tool and names the legacy-unknown bucket", async () => {
  const modern = roll([bEval(2, [bTool("Bash", 10), bTool("Read", 5, { "denied/read-clamp": 2 })])], [bFail(2, "denied/read-clamp", 2)], { eligible: { "read-clamp": CLAMP } });
  expect(Object.fromEntries(cells(await page(modern, { guard: "denied/read-clamp" }), "data-guard-tool").map(([k, c]: any) => [k, c.slice(1, 3)])).Read[0]).toBe("2");
  const data = roll([bEval(1)], [bFail(1, "denied/read-clamp", 1)], { eligible: { "read-clamp": CLAMP } });
  const rows = Object.fromEntries(cells(await page(data, { guard: "denied/read-clamp" }), "data-guard-tool").map(([k, c]: any) => [k, c.slice(1, 3)]));
  expect(rows["(unknown)"]).toEqual(["1", "tool not recorded (legacy)"]);
});

test("the guard drill-in calls a refused Agent:<type> row a wired tool for a guard wired to Agent", async () => {
  const data = roll([bEval(1, [bTool("Agent:judge", 3, { "denied/guard-subagent-model": 1 }), bTool("Edit", 2, { "denied/guard-subagent-model": 1 })])], [bFail(1, "denied/guard-subagent-model", 2)], { eligible: { "guard-subagent-model": ["Agent"] } });
  const rows = Object.fromEntries(cells(await page(data, { guard: "denied/guard-subagent-model" }), "data-guard-tool").map(([k, c]: any) => [k, c.slice(1, 3)]));
  expect(rows["Agent:judge"]).toEqual(["1", "a tool this guard is wired to check"]);
  expect(rows.Edit).toEqual(["1", "not a tool this guard is wired to check"]);
});

// ---- hook-chain incidents: the exact call, the reason a guard refused, the recorded timing. Hand-built log rows, temp files only.
const INV = (n: number) => n.toString(16).padStart(12, "0");
const C_DAY = "2026-10-28";
const skipRow = (n: number, over: any = {}) => ({ ts: `${C_DAY}T10:00:${String(n % 60).padStart(2, "0")}.000Z`, action: "deny", member: "block-read-secrets.sh", budget: 15000, elapsed: 15072, reason: "ETIMEDOUT",
  sessionId: "sess-chain", toolCall: "Read /x", callId: `toolu_C${n}`, tool: "Read", event: "PreToolUse", invocation: INV(n), occurrence: 0, origin: "production", ...over });
const runMember = (over: any = {}) => ({ member: "block-read-secrets.sh", occurrence: 0, outcome: "deny", reason: "RULE", elapsed: 41, ...over });
const runRow = (n: number, members: any[], over: any = {}) => ({ ts: `${C_DAY}T10:00:${String(n % 60).padStart(2, "0")}.000Z`, v: 1, origin: "production", event: "PreToolUse", session: "sess-chain",
  callId: `toolu_C${n}`, tool: "Read", invocation: INV(n), exit: 2, elapsed: 20, members, ...over });
const WINDOW_LINE = "must-run guard did not evaluate this call within its 15000ms window; failing closed";
// Fixture T: three secrets-guard refusals (a rule denial, an ETIMEDOUT deny, an entry-deadline deny) and one advisory ENOBUFS skip.
function chainT() {
  return {
    skip: { state: "ok", rows: [
      skipRow(2, { denyLine: WINDOW_LINE }),
      skipRow(3, { reason: "ENTRY_DEADLINE", elapsed: 0, budget: 0, starved: true, denyLine: "must-run guard was left no safe window before the entry deadline; failing closed" }),
      skipRow(4, { action: "skip", member: "read-clamp.sh", reason: "ENOBUFS", elapsed: 321, budget: 8000 }),
    ] },
    run: { state: "ok", rows: [
      runRow(1, [runMember({ denyLine: "blocked: a secret-shaped path" })]),
      runRow(2, [runMember({ reason: "ETIMEDOUT", elapsed: 15072, budget: 15000, denyLine: WINDOW_LINE })]),
      runRow(3, [runMember({ reason: "ENTRY_DEADLINE", elapsed: 0, budget: 0, denyLine: "must-run guard was left no safe window before the entry deadline; failing closed" })]),
      runRow(4, [runMember({ member: "read-clamp.sh", outcome: "skip", reason: "ENOBUFS", elapsed: 321, budget: 8000 })], { exit: 0 }),
    ] },
  };
}
const rollChain = (chain: any) => rollupToolHealth([], [], new URLSearchParams(), B_NOW, {}, { chain }).chain;
const callEvent = (c: any, id: string) => c.events.find((e: any) => e.call_id === id);

test("chain-reasons-and-actions-are-not-all-timeouts", () => {
  const c = rollChain(chainT());
  expect(c.state).toBe("ok");
  expect(c.by_reason).toEqual({ rule: 1, timeout: 1, deadline: 1, buffer: 1, other: 0 });
  expect(c.by_action).toEqual({ deny: 3, skip: 1 });
  expect([c.infra, c.denials, c.events_total]).toEqual([3, 3, 4]);
  // The guard that never started (the entry-deadline deny) is a refusal but not a run.
  expect(c.members["block-read-secrets.sh"]).toMatchObject({ denials: 3, skips: 0, runs: 2, by_reason: { rule: 1, timeout: 1, deadline: 1, buffer: 0, other: 0 } });
  expect(c.members["read-clamp.sh"]).toMatchObject({ denials: 0, skips: 1, by_reason: { buffer: 1 } });
  // One call is in both logs and counts once; the three refusals are three distinct calls.
  expect(c.joined).toBe(3);
  expect(new Set(c.events.filter((e: any) => e.outcome === "deny").map((e: any) => e.call_id)).size).toBe(3);
  // A skip is not a success: the event makes no claim about what the tool did afterwards.
  expect(callEvent(c, "toolu_C4")).toMatchObject({ outcome: "skip", reason: "ENOBUFS", member: "read-clamp.sh", session: "sess-chain" });
  expect(callEvent(c, "toolu_C4")).not.toHaveProperty("recovered");
});

test("incident-timing-uses-recorded-budget", () => {
  const c = rollChain(chainT());
  expect(callEvent(c, "toolu_C2")).toMatchObject({ elapsed_ms: 15072, budget_ms: 15000, not_started: false, ratio: 15072 / 15000 });
  expect(callEvent(c, "toolu_C3")).toMatchObject({ elapsed_ms: 0, not_started: true, ratio: null });
  // Budget 0 gives no ratio, and another budget is used as recorded, never a fixed 15 s.
  const v = rollChain({ skip: { state: "ok", rows: [skipRow(5, { elapsed: 90, budget: 0 }), skipRow(6, { elapsed: 8100, budget: 8000, member: "other-guard.sh" })] }, run: { state: "ok", rows: [] } });
  expect(callEvent(v, "toolu_C5")).toMatchObject({ budget_ms: 0, ratio: null, not_started: false });
  expect(callEvent(v, "toolu_C6")).toMatchObject({ budget_ms: 8000, ratio: 8100 / 8000 });
  const missing = rollChain({ skip: { state: "ok", rows: [skipRow(7, { budget: undefined, elapsed: -3 })] }, run: { state: "ok", rows: [] } });
  expect(callEvent(missing, "toolu_C7")).toMatchObject({ budget_ms: null, elapsed_ms: null, ratio: null });
});

const unprintable = (s: string) => [...s].some((ch) => { const n = ch.codePointAt(0)!; return n < 0x20 || (n >= 0x7f && n <= 0x9f) || n === 0x2028 || n === 0x2029; });

test("deny-line-is-redacted-before-first-line-and-clip", () => {
  const sep = String.fromCharCode(0x2028), bell = String.fromCharCode(7), esc = String.fromCharCode(27);
  const lines = { long: "x".repeat(300), astral: "\u{1F600}".repeat(300), ctrl: `a${bell}b${esc}[31mred${sep}next`, markup: "<img src=x onerror=alert(1)> & \"q\"", notText: 42 };
  const rows = Object.entries(lines).map(([k, denyLine], i) => skipRow(20 + i, { denyLine, member: `m${k}.sh` }));
  const c = rollChain({ skip: { state: "ok", rows }, run: { state: "ok", rows: [] } });
  const line = (k: string) => callEvent(c, `toolu_C${20 + Object.keys(lines).indexOf(k)}`).deny_line;
  expect(Array.from(line("long")).length).toBe(240);
  expect(Array.from(line("astral")).length).toBe(240);
  expect(unprintable(line("ctrl"))).toBe(false);
  expect(line("markup")).toBe(lines.markup); // kept as text: the renderer escapes it
  expect(line("notText")).toBeNull();
  // Different tools and messages stay distinct events, never merged into one group.
  expect(new Set(c.events.map((e: any) => e.deny_line)).size).toBe(c.events.length);
  // A skip is not a refusal and carries no line.
  const skip = rollChain({ skip: { state: "ok", rows: [skipRow(30, { action: "skip", denyLine: "should not show" })] }, run: { state: "ok", rows: [] } });
  expect(callEvent(skip, "toolu_C30").deny_line).toBeNull();
});

const auditSum = (a: any) => a.accepted + a.excluded_fixture + a.unverified + a.non_tool + a.malformed + a.duplicates + a.outside_window;
// Fixture F: 657 incident inputs, exactly 270 marked test-origin (hang, hog, flood and a real guard name), 387 verified production.
function chainF() {
  const names = ["hang.sh", "hog.sh", "flood.sh", "block-read-secrets.sh"], rows: any[] = [];
  for (let i = 0; i < 270; i++) rows.push(skipRow(1000 + i, { origin: "test", member: names[i % 4] }));
  for (let i = 0; i < 387; i++) rows.push(skipRow(2000 + i, { ts: `${C_DAY}T11:${String(Math.floor(i / 60)).padStart(2, "0")}:${String(i % 60).padStart(2, "0")}.000Z` }));
  return rows;
}
const skipOnly = (rows: any[]) => rollChain({ skip: { state: "ok", rows }, run: { state: "ok", rows: [] } });

test("fixture-provenance-is-not-production-health", () => {
  const rows = chainF();
  let c = skipOnly(rows);
  expect(c.audit).toMatchObject({ total: 657, accepted: 387, excluded_fixture: 270, unverified: 0, duplicates: 0 });
  expect(c.state).toBe("ok");
  expect(c.events_total).toBe(387);
  expect(auditSum(c.audit)).toBe(c.audit.total);
  // One row whose provenance cannot be shown is unverified: not an incident, not a fixture, and the roll-up is partial.
  const legacy: any = skipRow(9000); delete legacy.origin;
  c = skipOnly([...rows, legacy]);
  expect(c.audit).toMatchObject({ total: 658, accepted: 387, excluded_fixture: 270, unverified: 1 });
  expect([c.state, c.events_total]).toEqual(["partial", 387]);
  // Replaying a duplicate incident changes neither the accepted count nor the event count.
  c = skipOnly([...rows, rows[300]]);
  expect(c.audit).toMatchObject({ total: 658, accepted: 387, duplicates: 1 });
  expect(c.events_total).toBe(387);
  expect(auditSum(c.audit)).toBe(c.audit.total);
  // Every other input lands in exactly one named bucket too.
  const odd = [skipRow(9001, { ts: "2026-09-01T00:00:00.000Z" }), skipRow(9002, { event: "SessionStart", callId: null }), skipRow(9003, { ts: "not a time" }), skipRow(9004, { callId: null }), skipRow(9005, { invocation: "short" })];
  c = skipOnly(odd);
  expect(c.audit).toMatchObject({ total: 5, accepted: 0, outside_window: 1, non_tool: 1, malformed: 1, unverified: 2 });
  expect(auditSum(c.audit)).toBe(5);
  expect(c.events_total).toBe(0);
});

test("a missing chain source reads unknown, never zero", () => {
  const none = rollChain({ skip: { state: "absent" }, run: { state: "absent" } });
  expect(none).toMatchObject({ state: "absent", infra: null, denials: null, invocations: null, by_reason: { rule: null, timeout: null, deadline: null, buffer: null }, by_action: { deny: null, skip: null } });
  // Only the skip log: timeouts are known, rule denials are not derived from anything else.
  const only = rollChain({ skip: { state: "ok", rows: [skipRow(2)] }, run: { state: "absent" } });
  expect(only.state).toBe("partial");
  expect(only.by_reason).toMatchObject({ rule: null, timeout: 1 });
  expect([only.denials, only.invocations]).toEqual([null, null]);
  expect(only.members["block-read-secrets.sh"]).toMatchObject({ runs: null, run_ms: null });
  expect(rollupToolHealth([], [], new URLSearchParams(), B_NOW, {}, {}).chain).toEqual({ state: "not-read" }); // the chief board passes no chain
  expect(rollChain({ skip: { state: "error" }, run: { state: "absent" } }).state).toBe("error");
});

test("chain logs are read from the override files or from the checkout and each worktree, and a damaged line makes the roll-up partial", () => {
  const env: any = seed(), repo = join(env.HOME, "repo");
  const put = (dir: string, name: string, rows: any[]) => { mkdirSync(dir, { recursive: true }); writeFileSync(join(dir, name), rows.map((r) => (typeof r === "string" ? r : JSON.stringify(r))).join("\n") + "\n"); };
  const main = join(repo, ".claude", "logs"), wt = join(repo, ".claude", "worktrees", "feat+x", ".claude", "logs");
  put(main, "hook-chain-skips.jsonl", [skipRow(2)]);
  put(wt, "hook-chain-skips.jsonl", [skipRow(3, { reason: "ENTRY_DEADLINE", elapsed: 0, budget: 0 })]);
  put(wt, "hook-runs.jsonl", [runRow(1, [runMember()])]);
  const run = (e: object, opts: object = {}) => (sources as any).readToolHealth(e, new URLSearchParams(), B_NOW, { rtk: () => ({ state: "absent" }), ...opts }).chain;
  const both = run(env, { repoRoot: repo });
  expect(both).toMatchObject({ state: "ok", events_total: 3, by_reason: { rule: 1, timeout: 1, deadline: 1 }, sources: { skip: { files: 2 }, run: { files: 1 } } });
  // An override names exactly one file and nothing else is read.
  const one = run({ ...env, RUN_HOOK_CHAIN_SKIP_LOG: join(main, "hook-chain-skips.jsonl"), RUN_HOOK_CHAIN_RUN_LOG: join(wt, "hook-runs.jsonl") }, { repoRoot: repo });
  expect(one).toMatchObject({ events_total: 2, sources: { skip: { files: 1 }, run: { files: 1 } } });
  // No checkout given and no override: nothing is read, which is absent, not zero.
  expect(run(env)).toMatchObject({ state: "absent", infra: null });
  put(main, "hook-chain-skips.jsonl", [skipRow(2), "{not json"]);
  const damaged = run(env, { repoRoot: repo });
  expect(damaged.state).toBe("partial");
  expect(damaged.audit).toMatchObject({ malformed: 1 });
});

// ---- the pages that show the chain incidents.
const chainPage = (chain: any, ui: any, extra: any = {}) => page(roll([bEval(1, [bTool("Read", 5, { "denied/block-read-secrets": 3 })])], [bFail(1, "denied/block-read-secrets", 3, ["toolu_C1", "toolu_C2", "toolu_C3"], ["2026-10-28T10:00:00Z", "2026-10-28T10:00:09Z"])], { eligible: { "block-read-secrets": ["Read"] }, chain }), ui, extra);
const GUARD = { guard: "denied/block-read-secrets" };
const evCells = (html: string) => Object.fromEntries(cells(html, "data-chain-event").map(([k, c]: any) => [k, c]));
const stat = (html: string, id: string) => (new RegExp(`data-stat="${id}">([^<]*)<`).exec(html) || [])[1];

test("the guard drill-in says why it refused: a rule, a timeout and a guard that never started are separate rows", async () => {
  const html = await chainPage(chainT(), GUARD);
  const why = Object.fromEntries(cells(html, "data-chain-reason").map(([k, c]: any) => [k, c[1]]));
  expect(why).toEqual({ rule: "1", timeout: "1", deadline: "1", buffer: "0", other: "0", before_logged: "0", not_established: "0" });
  const ev = evCells(html);
  expect(Object.keys(ev).sort()).toEqual(["toolu_C1", "toolu_C2", "toolu_C3"]);
  // [When, Outcome, Reason, Guard, Tool, Time used, Refusal line, Call]
  expect(ev.toolu_C2.slice(1, 6)).toEqual(["Refused the call", "Timeout", "block-read-secrets.sh", "Read", "15072 ms of 15000 ms (100.5%)"]);
  expect(ev.toolu_C2[6]).toBe(WINDOW_LINE);
  expect(ev.toolu_C3[2]).toBe("Never started");
  expect(ev.toolu_C3[5]).toBe("not started");
  expect(ev.toolu_C1[2]).toBe("Rule");
  expect(ev.toolu_C2[0]).toBe("2026-10-28 10:00:02 UTC");
  expect(html).not.toContain("toolu_C4"); // another guard's skipped check is not this guard's incident
  expect(html).toContain("model, lane, role and profile filters do not apply");
});

// Fixture G: six counted refusals of one guard. Two are older than the first run-log row, two have a chain row (a rule and a
// timeout), one names a call the chain never saw, one carries no call id. The chain also holds a refusal that no counted refusal names.
const G = "denied/block-read-secrets";
const gapData = (chain: any = chainT()) => roll([1, 2, 3, 4].map((n, i) => bEval(n, [bTool("Read", 5, { [G]: [2, 2, 1, 1][i] })]))
  , [bFail(1, G, 2, ["toolu_old1", "toolu_old2"], ["2026-10-28T08:00:00Z", "2026-10-28T08:05:00Z"]),
    bFail(2, G, 2, ["toolu_C1", "toolu_C2"], ["2026-10-28T10:30:00Z", "2026-10-28T10:31:00Z"]),
    bFail(3, G, 1, ["toolu_nochain"], ["2026-10-28T10:40:00Z", "2026-10-28T10:40:00Z"]),
    bFail(4, G, 1, [], ["2026-10-28T10:50:00Z", "2026-10-28T10:50:00Z"])], { eligible: { "block-read-secrets": ["Read"] }, chain });

test("guard-reason-rows-plus-no-reason-counts-equal-refused", async () => {
  const gap = guardOf(gapData(), G).reason_gap;
  expect(gap).toMatchObject({ refused: 6, with_reason: 2, before_reasons_logged: 2, not_established: 2, unmatched_chain: 1, run_log_start: "2026-10-28T10:00:01.000Z" });
  expect(gap.by_reason).toEqual({ rule: 1, timeout: 1, deadline: 0, buffer: 0, other: 0 });
  expect(Object.values(gap.by_reason).reduce((n: number, v: any) => n + v, 0) + gap.before_reasons_logged + gap.not_established).toBe(gap.refused);
  // The page shows the same rows and the two labelled residuals, and they add up to the Refused card.
  const html = await page(gapData(), GUARD);
  const why = Object.fromEntries(cells(html, "data-chain-reason").map(([k, c]: any) => [k, c[1]]));
  expect(why).toEqual({ rule: "1", timeout: "1", deadline: "0", buffer: "0", other: "0", before_logged: "2", not_established: "2" });
  expect(Object.values(why).reduce((n: number, v: any) => n + Number(v), 0)).toBe(6);
  expect(html).toContain("Recorded before reasons were logged");
  expect(html).toContain("No reason row, cause not established");
  expect(html).toContain("1 chain row names a refusal this window does not count");
});

test("the reason split is unknown, never zero, when the run log cannot be read", async () => {
  const skipOnlyChain = { skip: { state: "ok", rows: [skipRow(2)] }, run: { state: "absent" } };
  expect(guardOf(gapData(skipOnlyChain), G).reason_gap).toBeNull();
  expect(guardOf(gapData({ skip: { state: "absent" }, run: { state: "absent" } }), G).reason_gap).toBeNull();
  expect(guardOf(gapData(null), G).reason_gap).toBeNull();
  // Run log present but empty: nothing is known to have started, so no refusal is called "before reasons were logged".
  const empty = guardOf(gapData({ skip: { state: "ok", rows: [] }, run: { state: "ok", rows: [] } }), G).reason_gap;
  expect(empty).toMatchObject({ refused: 6, with_reason: 0, before_reasons_logged: 0, not_established: 6, run_log_start: null });
});

test("the recent-events table keeps a word whole in its narrow columns and lets the refusal line and call id take the wrapping", async () => {
  const html = await chainPage(chainT(), GUARD);
  expect(html).toContain('<table class="data events">');
  const row = /<tr data-chain-event="toolu_C2">([\s\S]*?)<\/tr>/.exec(html)![1];
  const cellsOf = [...row.matchAll(/<td( class="wrap")?>/g)].map((m) => !!m[1]);
  // [When, Outcome, Reason, Guard, Tool, Time used, Refusal line, Call]: only the refusal line and the call id wrap anywhere.
  expect(cellsOf).toEqual([false, false, false, false, false, false, true, true]);
  const css = readFileSync(resolve(import.meta.dir, "../public/app.css"), "utf8");
  expect(css).toMatch(/\.data\.events th,\s*\.data\.events td\{overflow-wrap:normal\}/);
  expect(css).toMatch(/\.data\.events td\.wrap\{overflow-wrap:anywhere\}/);
});

test("the five Tool health tables keep a header and a short value whole and give the wrapping to their free-text columns", async () => {
  const data = readP(seedP());
  const wrapFlags = (html: string, row: RegExp) => [...row.exec(html)![1].matchAll(/<td( class="wrap")?>/g)].map((m) => !!m[1]);
  const tab = (html: string) => (html.match(/<table class="data thtab">/g) || []).length;
  // Hook wiring: [Hook, Source, Wired on, Wirings, Runs twice, Runs, Refused]; the hook name and the wiring text wrap.
  const hooks = await page(data, { tab: "hooks" }, { inventory: INVENTORY });
  expect(tab(hooks)).toBe(1);
  expect(wrapFlags(hooks, /<tr>(<td[\s\S]*?)<\/tr>/)).toEqual([true, false, true, false, false, false, false]);
  // Station sources: [Source, Reads at runtime, Found, Note]; MCP servers and CLIs share the sortable table.
  const station = await page(data, { tab: "station" }, { inventory: INVENTORY });
  expect(tab(station)).toBe(3);
  expect(wrapFlags(station, /<tr>(<td[\s\S]*?)<\/tr>/)).toEqual([false, true, true, true]);
  // Overview: the Tools table and the guards table.
  const overview = await page(data, {}, { inventory: INVENTORY });
  expect(tab(overview)).toBe(2);
  expect(wrapFlags(overview, /<tr data-tool-row="[^"]*">([\s\S]*?)<\/tr>/)).toEqual([true, false, false, false, false, false, false, false]);
  expect(wrapFlags(overview, /<tr data-guard-row="[^"]*">([\s\S]*?)<\/tr>/)).toEqual([true, false, false, true, false, true]);
  // Guard drill-in, Refused by tool: [Tool, Refused, Note, Eligible call attempts].
  const drill = await chainPage(chainT(), GUARD);
  expect(tab(drill)).toBe(1);
  expect(wrapFlags(drill, /<tr data-guard-tool="[^"]*">([\s\S]*?)<\/tr>/)).toEqual([true, false, true, false]);
  const css = readFileSync(resolve(import.meta.dir, "../public/app.css"), "utf8");
  expect(css).toMatch(/\.data\.thtab th,\s*\.data\.thtab td\{overflow-wrap:normal\}/);
  expect(css).toMatch(/\.data\.thtab th\{white-space:nowrap\}/);
  expect(css).toMatch(/\.data\.thtab td\.wrap\{overflow-wrap:anywhere;min-width:16ch\}/);
});

// ---- time to result per tool (RESULT time minus START time). Hand-built digest rows, no journal.
const timed = (tool: string, calls: number, timing: any) => ({ ...bTool(tool, calls), timing });
const timingOf = (d: any, tool: string) => d.tools.find((t: any) => t.tool === tool).timing;

test("time-to-result-headline-comes-from-single-calls-only", () => {
  const d = roll([bEval(1, [timed("Read", 6, { single: [300, 400, 500], batched: [490, 9000], missing: 1 })])], []);
  expect(timingOf(d, "Read")).toEqual({ n: 3, p50_ms: 400, p95_ms: 500, batched_n: 2, batched_p50_ms: 490, missing: 1, unknown_calls: 0, capped: false });
  expect(d.tools.find((t: any) => t.tool === "Read")).not.toHaveProperty("timing_raw");
  // A digest written before timing was kept leaves its calls unknown, never fast.
  const mixed = roll([bEval(1, [timed("Read", 1, { single: [100], batched: [], missing: 0 })]), bEval(2, [bTool("Read", 4)])], []);
  expect(timingOf(mixed, "Read")).toMatchObject({ n: 1, p50_ms: 100, unknown_calls: 4 });
  expect(timingOf(roll([bEval(1, [bTool("Read", 2)])], []), "Read")).toMatchObject({ n: 0, p50_ms: null, p95_ms: null, batched_p50_ms: null, unknown_calls: 2 });
  // A call with no result is missing, not a zero that would pull the median down.
  expect(timingOf(roll([bEval(1, [timed("Grep", 1, { single: [], batched: [], missing: 1 })])], []), "Grep")).toMatchObject({ n: 0, p50_ms: null, missing: 1 });
});

test("the hook chain time per tool comes from the run log, and is unknown without it", () => {
  const rows = [20, 40, 60].map((ms, i) => runRow(60 + i, [], { elapsed: ms }));
  const c = rollChain({ skip: { state: "ok", rows: [] }, run: { state: "ok", rows } });
  expect(c.hook_ms_by_tool.Read).toEqual({ n: 3, p50_ms: 40, p95_ms: 60 });
  expect(rollChain({ skip: { state: "ok", rows: [] }, run: { state: "absent" } }).hook_ms_by_tool).toBeNull();
});

const ttr = (html: string, id: string) => (new RegExp(`data-stat="${id}">([^<]*)<`).exec(html) || [])[1];

test("the tool drill-in shows time to result for a single, a batched and a missing call, labelled as including waiting and hooks", async () => {
  const run = [20, 40, 60].map((ms, i) => runRow(60 + i, [], { elapsed: ms }));
  const chain = { skip: { state: "ok", rows: [] }, run: { state: "ok", rows: run } };
  const data = roll([bEval(1, [timed("Read", 3, { single: [400], batched: [490], missing: 1 }), timed("Grep", 1, { single: [], batched: [], missing: 1 })])], [], { chain });
  const html = await page(data, { tool: "Read" });
  expect(html).toContain("time to result (includes waiting and hooks)");
  expect(html).not.toMatch(/run time/i);
  expect(ttr(html, "ttr-p50")).toBe("400 ms");
  expect(ttr(html, "ttr-p95")).toBe("400 ms");
  expect(ttr(html, "ttr-n")).toBe("1");
  expect(ttr(html, "ttr-batched")).toBe("490 ms (1 batched call, kept out of the headline)");
  expect(ttr(html, "ttr-missing")).toBe("1");
  expect(ttr(html, "ttr-hook")).toBe("40 ms median over 3 runs of the hook chain");
  // The hook chain figure covers every session on the station, whatever the filters say, and the box says so.
  expect(html).toContain("Hook chain time covers every session on this station and ignores the filters.");
  // A tool whose only call has no result shows a dash, never 0 ms.
  const none = await page(data, { tool: "Grep" });
  expect(ttr(none, "ttr-p50")).toBe("—");
  expect(ttr(none, "ttr-p95")).toBe("—");
  expect(ttr(none, "ttr-n")).toBe("0");
  expect(ttr(none, "ttr-hook")).toBe("—");
  expect(none).not.toContain("0 ms");
});

test("a digest written before timing was kept says so, and a tool with no timing reads a dash", async () => {
  const html = await page(roll([bEval(1, [bTool("Read", 3)])], []), { tool: "Read" });
  expect(ttr(html, "ttr-p50")).toBe("—");
  expect(html).toContain("3 calls were recorded before time to result was kept");
});

test("a call drawer carries the exact call id, the session and what is not recorded", async () => {
  const sid = "48160000-0000-4000-8000-000000000199";
  const chain = { skip: { state: "ok", rows: [skipRow(2, { sessionId: sid, denyLine: WINDOW_LINE })] }, run: { state: "ok", rows: [] } };
  const html = await chainPage(chain, GUARD);
  const drawer = /<tr data-chain-event="toolu_C2"[\s\S]*?<details>([\s\S]*?)<\/details>/.exec(html)![1];
  expect(drawer).toContain("toolu_C2");
  expect(drawer).toContain(INV(2));
  expect(drawer).toContain(`href="/agui/#t=t&amp;run=${sid}"`);
  expect(drawer).toContain("Recovery");
  expect(drawer).toMatch(/Recovery<\/dt><dd>[^<]*not recorded/);
  const odd = await chainPage({ skip: { state: "ok", rows: [skipRow(2, { sessionId: "sess-chain" })] }, run: { state: "ok", rows: [] } }, GUARD);
  expect(odd).toContain("<code>sess-chain</code>");
});

test("a timing with no budget shows no percentage, and one that never started says so", async () => {
  const chain = { skip: { state: "ok", rows: [skipRow(5, { elapsed: 90, budget: 0 }), skipRow(6, { elapsed: undefined, budget: undefined })] }, run: { state: "ok", rows: [] } };
  const ev = evCells(await chainPage(chain, GUARD));
  expect(ev.toolu_C5[5]).toBe("90 ms · no budget recorded");
  expect(ev.toolu_C6[5]).toBe("not recorded");
});

test("a refusal line is escaped on the page", async () => {
  const hostile = "<img src=x onerror=alert(1)> & \"q\" <script>alert(2)</script>";
  const html = await chainPage({ skip: { state: "ok", rows: [skipRow(2, { denyLine: hostile })] }, run: { state: "ok", rows: [] } }, GUARD);
  expect(html).not.toContain("<img src=x");
  expect(html).not.toContain("<script>alert(2)");
  expect(html).toContain("&lt;img src=x onerror=alert(1)&gt; &amp; &quot;q&quot; &lt;script&gt;alert(2)&lt;/script&gt;");
});

test("without chain logs the reason rows read — and unverified, never 0", async () => {
  for (const chain of [undefined, { skip: { state: "absent" }, run: { state: "absent" } }]) {
    const html = await chainPage(chain, GUARD);
    const why = Object.fromEntries(cells(html, "data-chain-reason").map(([k, c]: any) => [k, c[1]]));
    expect(why).toEqual({ rule: "—", timeout: "—", deadline: "—", buffer: "—", other: "—" });
    expect(html).toContain("unverified");
    expect(cells(html, "data-chain-event")).toEqual([]);
  }
  // Only the skip log: a timeout count is known, a rule denial count is not.
  const half = Object.fromEntries(cells(await chainPage({ skip: { state: "ok", rows: [skipRow(2)] }, run: { state: "absent" } }, GUARD), "data-chain-reason").map(([k, c]: any) => [k, c[1]]));
  expect(half).toEqual({ rule: "—", timeout: "1", deadline: "0", buffer: "0", other: "—" });
});

test("the audit line counts the rows that were left out and why", async () => {
  const chain = { skip: { state: "ok", rows: [skipRow(2), skipRow(3, { origin: "test" }), skipRow(4, { origin: undefined })] }, run: { state: "ok", rows: [] } };
  const html = await chainPage(chain, GUARD);
  const audit = /data-chain-audit>([^<]*)</.exec(html)![1];
  expect(audit).toContain("accepted 1");
  expect(audit).toContain("test fixtures excluded 1");
  expect(audit).toContain("unverified 1");
  expect(html).toMatch(/Partial:/);
  expect(cells(html, "data-chain-event").map(([k]: any) => k)).toEqual(["toolu_C2"]);
});

test("a tool drill-in shows its timeouts and its recent events from the chain logs", async () => {
  const html = await chainPage(chainT(), { tool: "Read" });
  expect(stat(html, "timeouts")).toBe("1");
  expect(Object.keys(evCells(html)).sort()).toEqual(["toolu_C1", "toolu_C2", "toolu_C3", "toolu_C4"]);
  expect(html).not.toContain("needs new data (later build)");
});

test("a tool drill-in reads — for timeouts when the chain logs are missing, and for a skill or subagent row", async () => {
  expect(stat(await chainPage(undefined, { tool: "Read" }), "timeouts")).toBe("—");
  expect(stat(await chainPage({ skip: { state: "absent" }, run: { state: "absent" } }, { tool: "Read" }), "timeouts")).toBe("—");
  const data = roll([bEval(1, [bTool("Skill:alpha:one", 2)])], [], { chain: chainT() });
  const skill = await page(data, { tool: "Skill:alpha:one" }, { inventory: INVENTORY });
  // No exact incident ids name a skill or subagent, so its timeout count is "needs new data" with the blocker named, never 0.
  expect(stat(skill, "timeouts")).toBe("needs new data");
  expect(skill).toContain("name the tool, not the skill or subagent");
  expect(skill).toContain("record which skill or subagent a call named");
  // A tool with no incident in complete logs is a real zero.
  const none = roll([bEval(1, [bTool("Grep", 2)])], [], { chain: chainT() });
  expect(stat(await page(none, { tool: "Grep" }), "timeouts")).toBe("0");
});

test("the hook list shows measured runs where the chain logs them and derived runs elsewhere", async () => {
  const data = roll([bEval(1, [bTool("Bash", 4), bTool("Read", 3)])], [], { chain: chainT() });
  const inventory = { ...INVENTORY, hooks: [...INVENTORY.hooks, { kind: "hook", source: "project", name: "block-read-secrets.sh", wired: [["PreToolUse", "Read"]], runs_twice: false }, { kind: "hook", source: "project", name: "notchained.sh", wired: [["PreToolUse", "Bash"]], runs_twice: false }] };
  const hooks = Object.fromEntries(cells(await page(data, { kind: "hook" }, { inventory }), "data-tool-row"));
  expect(hooks["hook:project:read-clamp.sh"][2]).toBe("1 runs measured");
  expect(hooks["hook:project:block-read-secrets.sh"][2]).toBe("2 runs measured");
  expect(hooks["hook:project:notchained.sh"][2]).toBe("4 runs derived");
  const tab = await page(data, { tab: "hooks" }, { inventory });
  expect(tab).not.toContain("Runs derived");
  const unmeasured = await page(roll([bEval(1, [bTool("Bash", 4), bTool("Read", 3)])], [], { chain: { skip: { state: "absent" }, run: { state: "absent" } } }), { kind: "hook" }, { inventory });
  expect(Object.fromEntries(cells(unmeasured, "data-tool-row"))["hook:project:read-clamp.sh"][2]).toBe("4 runs derived");
});

test("a map tile that adds measured and derived hook runs says it mixes them", async () => {
  const data = roll([bEval(1, [bTool("Bash", 4), bTool("Read", 3)])], [], { chain: chainT() });
  const inventory = { ...INVENTORY, hooks: [...INVENTORY.hooks, { kind: "hook", source: "project", name: "notchained.sh", wired: [["PreToolUse", "Bash"]], runs_twice: false }] };
  const lines = [...(await page(data, { tab: "map" }, { inventory })).matchAll(/data-kind="hook" aria-pressed="[a-z]+"><b>[^<]*<\/b><span>([^<]*)<\/span>/g)].map((m) => m[1]);
  expect(lines.some((l) => /^5 runs measured and derived · /.test(l))).toBe(true);
  expect(lines.some((l) => /^\S+ runs derived · /.test(l))).toBe(false);
});

test("a guard that never started is a refusal or a skip but not a measured run", () => {
  const member = (over: any) => runMember({ member: "g.sh", ...over });
  const run = [
    runRow(60, [member({ outcome: "allow", reason: undefined, elapsed: 5 })]),
    runRow(61, [member({ outcome: "skip", reason: "INTEGRITY", elapsed: 0 })], { exit: 0 }),
    runRow(62, [member({ reason: "ENTRY_DEADLINE", elapsed: 0, budget: 0 })]),
    runRow(63, [member({ reason: "SPAWN", elapsed: 3 })]),
    runRow(64, [member({ reason: "ETIMEDOUT", elapsed: 15072, budget: 15000 })]),
  ];
  const c = rollChain({ skip: { state: "ok", rows: [] }, run: { state: "ok", rows: run } });
  // Only the allow and the timeout ran the guard; the integrity skip, the deadline deny and the spawn failure never did.
  expect(c.members["g.sh"]).toMatchObject({ runs: 2, denials: 3, skips: 1, run_ms: 15077, max_ms: 15072 });
  expect(c.invocations).toBe(5);
  // The same three reasons read "not started" on the incident, never an elapsed time that looks like a fast run.
  expect([61, 62, 63, 64].map((n) => callEvent(c, `toolu_C${n}`).not_started)).toEqual([true, true, true, false]);
  expect(callEvent(c, "toolu_C61").ratio).toBeNull();
});

test("a count that only the run log can show reads unknown when the run log is missing", () => {
  const timeout = (n: number) => skipRow(n);
  const skipOnly = rollChain({ skip: { state: "ok", rows: [timeout(2)] }, run: { state: "absent" } });
  // Rule denials, integrity skips, spawn failures and crashes are written to the run log only.
  expect(skipOnly).toMatchObject({ infra: null, denials: null, by_action: { deny: null, skip: null }, by_reason: { rule: null, timeout: 1, deadline: 0, buffer: 0, other: null } });
  expect(skipOnly.members["block-read-secrets.sh"].by_reason).toMatchObject({ rule: null, timeout: 1, other: null });
  // The run log alone carries every kind, the skip-log kinds included.
  const runOnly = rollChain({ skip: { state: "absent" }, run: { state: "ok", rows: [runRow(2, [runMember({ reason: "ETIMEDOUT", elapsed: 15072, budget: 15000 })])] } });
  expect(runOnly).toMatchObject({ infra: 1, denials: 1, by_action: { deny: 1, skip: 0 }, by_reason: { rule: 0, timeout: 1, deadline: 0, buffer: 0, other: 0 } });
});

test("measured hook runs say they cover every session and ignore the filters", async () => {
  const note = "Measured hook runs cover every session on this station and ignore the filters";
  const inventory = { ...INVENTORY, hooks: [...INVENTORY.hooks, { kind: "hook", source: "project", name: "block-read-secrets.sh", wired: [["PreToolUse", "Read"]], runs_twice: false }] };
  const data = roll([bEval(1, [bTool("Read", 3)])], [], { chain: chainT() });
  expect(await page(data, { kind: "hook" }, { inventory })).toContain(note);
  expect(await page(data, { tab: "hooks" }, { inventory })).toContain(note);
  const unmeasured = roll([bEval(1, [bTool("Read", 3)])], [], { chain: { skip: { state: "absent" }, run: { state: "absent" } } });
  expect(await page(unmeasured, { kind: "hook" }, { inventory })).not.toContain(note);
  expect(await page(unmeasured, { tab: "hooks" }, { inventory })).not.toContain(note);
});

test("a worktree folder that cannot be listed makes the roll-up partial and the page says so", async () => {
  const chain = { ...chainT(), worktreesUnreadable: true };
  expect(rollChain(chain)).toMatchObject({ state: "partial", worktrees_unreadable: true, events_total: 4 });
  expect(rollChain(chainT())).toMatchObject({ state: "ok", worktrees_unreadable: false });
  expect(await chainPage(chain, GUARD)).toMatch(/Partial:[^<]*worktree/);
});

test("a tool whose events fall outside the newest ones does not read as having none", async () => {
  const rows = Array.from({ length: 301 }, (_, i) => skipRow(100 + i, { tool: "Edit", callId: `toolu_E${i}`, invocation: INV(100 + i) }));
  const html = await chainPage({ skip: { state: "ok", rows }, run: { state: "ok", rows: [] } }, { tool: "Read" });
  expect(html).not.toContain("No guard refused or skipped a call to this tool");
  expect(html).toContain("newest 300");
  expect(stat(html, "timeouts")).toBe("at least 0");
  // A tool with more events than the page shows, in a capped list, says the total is a floor.
  const reads = Array.from({ length: 301 }, (_, i) => skipRow(100 + i, { callId: `toolu_R${i}`, invocation: INV(100 + i) }));
  const some = await chainPage({ skip: { state: "ok", rows: reads }, run: { state: "ok", rows: [] } }, { tool: "Read" });
  expect(some).toContain("Showing the newest 20 of at least 300.");
});

(process.getuid?.() === 0 ? test.skip : test)("a worktree folder that cannot be inspected makes the roll-up partial", () => {
  const env: any = seed(), repo = join(env.HOME, "repo"), worktrees = join(repo, ".claude", "worktrees");
  mkdirSync(join(worktrees, "feat+x", ".claude", "logs"), { recursive: true });
  writeFileSync(join(worktrees, "feat+x", ".claude", "logs", "hook-chain-skips.jsonl"), JSON.stringify(skipRow(2)) + "\n");
  mkdirSync(join(repo, ".claude", "logs"), { recursive: true });
  writeFileSync(join(repo, ".claude", "logs", "hook-chain-skips.jsonl"), JSON.stringify(skipRow(3)) + "\n");
  writeFileSync(join(repo, ".claude", "logs", "hook-runs.jsonl"), JSON.stringify(runRow(1, [runMember()])) + "\n");
  const run = () => (sources as any).readToolHealth(env, new URLSearchParams(), B_NOW, { rtk: () => ({ state: "absent" }), repoRoot: repo }).chain;
  expect(run()).toMatchObject({ state: "ok", worktrees_unreadable: false, events_total: 3 });
  chmodSync(worktrees, 0o444); // listable, but its entries cannot be inspected
  try { expect(run()).toMatchObject({ state: "partial", worktrees_unreadable: true }); } finally { chmodSync(worktrees, 0o755); }
});

const svgs = (html: string) => [...html.matchAll(/<svg class="thchart"[\s\S]*?<\/svg>/g)].map((m) => m[0]);
const count = (s: string, re: RegExp) => (s.match(re) || []).length;
const chartCases: [string, any, string, number][] = [
  ["overview", {}, "data-day", 2],
  ["bash", { tool: "Bash" }, "data-trend-day", 1],
  ["guard", { guard: "denied/read-clamp" }, "data-guard-day", 1],
];
for (const [name, ui, attr, n] of chartCases) {
  test(`chart-${name}-has-scale-and-one-day-label-per-day`, async () => {
    const html = await page(readP(seedP()), ui);
    const charts = svgs(html);
    expect(charts.length).toBeGreaterThanOrEqual(n);
    const days = count(html, new RegExp(`<tr ${attr}=`, "g"));
    expect(days).toBeGreaterThan(0);
    for (const c of charts.slice(0, n)) {
      expect(count(c, /<text class="ax"/g)).toBe(3);
      expect(count(c, /<text class="dl"/g)).toBe(days);
    }
  });
  test(`chart-${name}-markers-are-not-stretched`, async () => {
    for (const c of svgs(await page(readP(seedP()), ui))) expect(c).not.toContain('preserveAspectRatio="none"');
  });
}
const rateTicks = async (calls: number, failures: number) => {
  const data = readP(seedP());
  data.daily = [{ day: "2026-10-28", calls, failures }];
  const rate = svgs(await page(data))[1];
  return [...rate.matchAll(/<text class="ax" x="([^"]*)"[^>]*>([^<]*)<\/text>/g)].map((m) => ({ x: Number(m[1]), text: m[2] }));
};
test("chart-rate-ticks-stay-distinct-for-a-tiny-rate", async () => {
  const ticks = (await rateTicks(5000, 1)).map((t) => t.text);
  expect(ticks).toHaveLength(3);
  expect(new Set(ticks).size).toBe(3);
});
test("chart-rate-ticks-fit-the-left-margin-at-one-hundred-percent", async () => {
  const ticks = await rateTicks(1, 1);
  expect(ticks.map((t) => t.text)).toContain("100.0%");
  for (const t of ticks) expect(t.x - t.text.length * 6.7).toBeGreaterThanOrEqual(0);
});
test("chart-bars-have-no-line-or-stray-gap-mark", async () => {
  for (const ui of [{}, { guard: "denied/read-clamp" }]) {
    const html = await page(readP(seedP()), ui);
    expect(html).toMatch(/<rect[^>]*class="fb"/);
    const bar = svgs(html)[0];
    expect(bar).not.toContain('class="line"');
    expect(bar).not.toContain('class="gap"');
  }
});
test("chart-bars-use-the-failure-colour-token", () => {
  const css = readFileSync(resolve(import.meta.dir, "../public/app.css"), "utf8");
  expect(css).toMatch(/\.thchart \.fb\{[^}]*fill:var\(--crit\)/);
  expect(css).toMatch(/\.thchart\{[^}]*height:auto/);
  expect(css).toMatch(/\.thchart\{[^}]*max-width:480px/);
});

// The tiles, names and Tool map columns match mockup v9 (the facts stay the same).
const SHAPE_INV = {
  ...INVENTORY,
  sources: [
    { id: "hooks-project", reads: "the project hooks", state: "ok", found: { wirings: 4, scripts: 3 } },
    { id: "hooks-user", reads: "the user hooks", state: "ok", found: { wirings: 2, scripts: 2 } },
    { id: "plugins", reads: "installed_plugins.json", state: "ok", found: { on: 2, installed: 9 } },
    { id: "plugin-items", reads: "<installPath>/skills", state: "ok", found: { skills: 1, commands: 0, agents: 0, hook_wirings: 3 } },
    { id: "mcp-user", reads: "~/.claude.json", state: "ok", found: { servers: 1, off_here: 0 } },
    { id: "mcp-runtime", reads: "a live session", state: "absent", reason: "source unknown", found: null },
    { id: "core", reads: "a recorded session", state: "absent", reason: "needs a session record", found: null },
    { id: "rtk-history", reads: "history.db", state: "ok", found: { bytes: 5 } },
  ],
  hooks: [...INVENTORY.hooks, { kind: "hook", source: "user", name: "read-clamp.sh", wired: [["PreToolUse", "Bash"]], runs_twice: true }, { kind: "hook", source: "project", name: "other.sh", wired: [["Stop", "*"]], runs_twice: false }],
};
const tile = (html: string, id: string) => ({ value: (new RegExp(`data-tile="${id}"[^>]*>[\\s\\S]*?<b class="kv">([^<]*)</b>`).exec(html) || [])[1], sub: (new RegExp(`data-tile="${id}"[^>]*>[\\s\\S]*?<span class="ks">([^<]*)</span>`).exec(html) || [])[1] });
const mapLabels = (html: string) => [...html.matchAll(/<span class="mr">(?:<button[^>]*>)?([^<]*)</g)].map((m) => m[1]);

test("the tab row is the mockup's plain text row with the active tab bold and underlined", () => {
  const css = readFileSync(resolve(import.meta.dir, "../public/app.css"), "utf8");
  const block = css.slice(css.indexOf("/* Tool health shape (mockup v9)"));
  expect(block).toMatch(/\.tabs \.tab\{[^}]*font-size:\.85rem/);
  expect(block).toMatch(/\.tabs \.tab\[aria-selected="true"\]\{[^}]*font-weight:700[^}]*text-decoration:underline/);
});

test("the overview shows the mockup's four cards: Calls, Failed, Failure rate, Highest rate", async () => {
  const html = await page(readP(seedP()));
  expect([...html.matchAll(/data-kpi="([a-z]+)"/g)].map((m) => m[1])).toEqual(["calls", "failed", "rate", "highest"]);
  expect(kpi(html, "highest")).toBe("16.0%");
  expect(kpiSub(html, "highest")).toContain("Bash");
  expect(kpiSub(html, "highest")).toContain("8 of 50 calls");
  const few = readP(seedP());
  few.tools = few.tools.filter((t: any) => t.tool !== "Bash");
  expect(kpi(await page(few), "highest")).toBe("—");
});

test("the Station tiles are Plugins, Skills, MCP servers, Hook wirings, Runs twice and CLIs", async () => {
  const html = await page(readP(seedP()), { tab: "station" }, { inventory: SHAPE_INV });
  expect([...html.matchAll(/data-tile="([a-z]+)"/g)].map((m) => m[1])).toEqual(["plugins", "skills", "mcp", "wirings", "twice", "clis"]);
  expect(tile(html, "plugins")).toMatchObject({ value: "2 / 9", sub: "on / installed" });
  expect(tile(html, "skills").value).toBe("1");
  expect(tile(html, "mcp").value).toBe("1");
  expect(tile(html, "wirings")).toMatchObject({ value: "9", sub: "2 scripts" });
  expect(tile(html, "twice").value).toBe("1");
  expect(tile(html, "clis")).toMatchObject({ value: "1 / 2", sub: "on PATH" });
  const absent = await page(readP(seedP()), { tab: "station" }, { inventory: { ...SHAPE_INV, sources: SHAPE_INV.sources.map((s) => (s.id === "plugins" || s.id.startsWith("hooks-") ? { ...s, state: "absent", found: null } : s)) } });
  expect(tile(absent, "plugins").value).toBe("—");
  expect(tile(absent, "wirings").value).toBe("—");
  expect(tile(absent, "twice").value).toBe("—");
});

test("the Station sources read with the mockup's human names, not the machine ids", async () => {
  const html = await page(readP(seedP()), { tab: "station" }, { inventory: SHAPE_INV });
  for (const name of ["Hooks · project", "Hooks · user", "Plugins", "Plugin items", "MCP · user config", "MCP · runtime", "Core tools", "rtk history"]) expect(html).toContain(`<td>${name}</td>`);
  expect(html).not.toContain("<td>hooks-project</td>");
  expect(html).not.toContain("<td>mcp-runtime</td>");
});

test("the Tool map has every kind as a column, an All column and row, sort headers, a loaded-never-used mark and phone source cards", async () => {
  const data = readP(seedP());
  const html = await page(data, { tab: "map" }, { inventory: SHAPE_INV });
  expect(html).toMatch(/class="thmap" data-cols="10"/);
  const heads = [...html.matchAll(/data-act="th-sort" data-table="map" data-col="(\d+)"[^>]*>([^<▴▾]*)/g)].map((m) => [m[1], m[2].trim()]);
  expect(heads).toEqual([["0", "Source"], ["1", "built-in"], ["2", "MCP"], ["3", "MCP resource"], ["4", "skill"], ["5", "command"], ["6", "subagent"], ["7", "workflow"], ["8", "hook"], ["9", "CLI"], ["10", "All"]]);
  expect(html).not.toMatch(/data-kind="res"/);
  expect(html).toContain("All sources");
  expect(html).toMatch(/data-act="th-pick" data-src="himmel" data-kind=""/);
  expect(html).toMatch(/data-src="himmel" data-kind="skill"[^>]*><b>1 skill<\/b>[\s\S]*?○ 1/);
  expect(html).toContain("loaded, never used");
  expect((html.match(/class="thcard"/g) || []).length).toBe(mapLabels(html).length);
  const labels = mapLabels(html);
  const desc = mapLabels(await page(data, { tab: "map", sorts: { map: { col: 0, desc: true } } }, { inventory: SHAPE_INV }));
  expect(desc).toEqual([...labels].sort((a, b) => b.localeCompare(a)));
  const css = readFileSync(resolve(import.meta.dir, "../public/app.css"), "utf8");
  expect(css.slice(css.indexOf("/* Tool health shape (mockup v9)"))).toMatch(/\.thcards\{display:none\}/);
});

test("the guard drill-in shows the This week cards: Refused, rate over eligible attempts, Busiest day, Days with none", async () => {
  const html = await page(readP(seedP()), { guard: "denied/read-clamp" });
  expect(html).toContain("<h3>This week</h3>");
  expect(stat(html, "refused")).toBe("5");
  expect(stat(html, "busiest")).toBe("27 Oct · 3");
  expect(stat(html, "none")).toBe("0");
  expect(html).toContain("Rate ÷ eligible call attempts");
  for (const id of ["rate", "eligible", "legacy-rate", "bash", "recovery"]) expect(html).toContain(`data-stat="${id}"`);
});

// the Bash cause view, the guard This week row and the Tool map tiles follow mockup v9.
test("the Bash drill-in draws Failures by cause as a stacked bar over five cause cards, not a table", async () => {
  const data = readRtk(seedSplit(), () => ({ state: "absent" }), new URLSearchParams({ days: "30" }));
  const html = await page(data, { tool: "Bash" });
  const box = /<section class="box" id="th-bash-cause">([\s\S]*?)<\/section>/.exec(html)![1];
  expect(box).not.toContain("<table");
  expect([...box.matchAll(/data-cause-card="([a-z-]+)"/g)].map((m) => m[1])).toEqual(["command", "rtk-filter", "rtk-hook", "guard", "classifier"]);
  const seg = [...box.matchAll(/<rect [^>]*data-cause-seg="([a-z_]+)" [^>]*width="([0-9.]+)"/g)];
  expect(seg.map((m) => m[1])).toEqual(["command", "guard", "classifier", "other"]); // the empty rtk hook cause draws no segment
  expect(seg.every((m) => Math.abs(Number(m[2]) - 25) < 0.01)).toBe(true); // 1 of 4 failures each, in percent of the bar
  // rtk history is absent here, so the rtk hook card is a dash with its reason, never a healthy 0
  expect(causeCards(box)).toEqual({ command: "1", "rtk-filter": "—", "rtk-hook": "—", guard: "1", classifier: "1" });
  expect(box).toMatch(/data-cause-card="rtk-hook"[\s\S]*?<b class="kv" title="rtk history could not be read/);
  // the mockup's colours: command red, rtk hook amber, himmel guard purple, classifier teal
  const fill = (k: string) => new RegExp(`data-cause-seg="${k}"[^>]*fill="([^"]+)"`).exec(box)![1];
  expect([fill("command"), fill("guard"), fill("classifier")]).toEqual(["var(--crit)", "var(--road)", "var(--alpha)"]);
  expect(box).toContain("1 other");
  expect(box).toContain("Auto-mode classifier");
  expect(html).not.toMatch(/\sstyle=/);
});

// one value per cause card, read card by card so a wrong number in any card fails
const causeCards = (box: string) => Object.fromEntries([...box.matchAll(/data-cause-card="([a-z-]+)"><span class="k">[\s\S]*?<\/span><b class="kv"[^>]*>([^<]*)<\/b>/g)].map((m) => [m[1], m[2]]));
const causeBox = (html: string) => /<section class="box" id="th-bash-cause">([\s\S]*?)<\/section>/.exec(html)![1];

test("with rtk history read, the rtk hook card counts the refusals history.db says were rtk's", async () => {
  const byId = new Map([["toolu_a", { path: "rtk", deny: false }], ["toolu_c", { path: "bash", deny: true }], ["toolu_d", { path: "bash", deny: false }]]);
  const html = await page(readRtk(seedSplit(), () => ({ state: "ok", byId, duplicates: 0 }), new URLSearchParams({ days: "30" })), { tool: "Bash" });
  const box = causeBox(html);
  expect(causeCards(box)).toEqual({ command: "1", "rtk-filter": "—", "rtk-hook": "1", guard: "0", classifier: "1" });
  expect([...box.matchAll(/<rect [^>]*data-cause-seg="([a-z_]+)"/g)].map((m) => m[1])).toEqual(["command", "rtk_hook", "classifier", "other"]);
  expect(box).not.toContain("rtk history could not be read");
});

test("the cause view says when no cause was recorded, and how much of the window the causes cover", async () => {
  const none = await page(readRtk(seed(), () => ({ state: "absent" }), new URLSearchParams({ days: "30" })), { tool: "Bash" });
  expect(none).toMatch(/id="th-bash-cause">[\s\S]*?<p class="nodata">No failure cause recorded/);
  expect(causeBox(none)).not.toContain("data-cause-card");
  expect(causeBox(none)).not.toContain("thcausebar");
  const data = readRtk(seedSplit(), () => ({ state: "absent" }), new URLSearchParams({ days: "30" }));
  expect(data.bash).toMatchObject({ recorded: 5, unrecorded: 45 });
  expect(causeBox(await page(data, { tool: "Bash" }))).toContain("Failure causes cover 5 of 50 calls");
  expect(causeBox(await page({ ...data, bash: { ...data.bash, unrecorded: null } }, { tool: "Bash" }))).toContain("causes cover 5 of an unknown number of calls");
  expect(causeBox(await page({ ...data, bash: { ...data.bash, unrecorded: 0 } }, { tool: "Bash" }))).not.toContain("causes cover");
});

test("the guard drill-in puts Refusals per day beside a four-card This week; the other facts sit below", async () => {
  const html = await page(readP(seedP()), { guard: "denied/read-clamp" });
  const row = /<div class="th-charts">([\s\S]*?)<\/figure><\/div>/.exec(html)![1];
  expect(row.indexOf("Refusals per day")).toBeGreaterThan(-1);
  expect(row.indexOf("<h3>This week</h3>")).toBeGreaterThan(row.indexOf("Refusals per day"));
  const week = row.slice(row.indexOf("<h3>This week</h3>"));
  expect([...week.matchAll(/data-stat="([a-z-]+)"/g)].map((m) => m[1])).toEqual(["refused", "rate", "busiest", "none"]);
  expect((week.match(/class="kpi"/g) || []).length).toBe(4); // four boxed cards, as in the mockup
  expect(week).toContain('<div class="kpis th-cols">'); // two columns, so the four cards read 2x2 as in the mockup
  for (const id of ["eligible", "legacy-rate", "bash", "recovery"]) { expect(html).toContain(`data-stat="${id}"`); expect(week).not.toContain(`data-stat="${id}"`); }
  expect(html.indexOf('id="th-guard-why"')).toBeGreaterThan(html.indexOf("<h3>This week</h3>"));
});

test("a phone Tool map tile carries its calls line and the failure-rate colour, as the desktop tile does", async () => {
  const html = await page(readP(seedP()), { tab: "map" }, { inventory: SHAPE_INV });
  const cards = html.slice(html.indexOf('<div class="thcards">'));
  expect(cards).toMatch(/<button class="mln mc (?:bad-t|warn-t|ok-t|zero)[^"]*" data-act="th-pick" data-src="core" data-kind="builtin"[^>]*>[\s\S]*?\d+ calls · \d+ failed/);
  expect(cards).toMatch(/class="thcard"[\s\S]*?<p class="sub">\d+ tools? · \d+ calls/);
  expect(cards).toMatch(/○ \d/);
  // exact values, not just a shape: Bash 50 calls / 8 failed and Read 20 calls / 0 failed make one built-in tile of 70 calls, 8 failed (11.4 %, the bad tint)
  expect(cards).toMatch(/<button class="mln mc bad-t" data-act="th-pick" data-src="core" data-kind="builtin"[^>]*><span class="kl">built-in<\/span><b>2<\/b><span>70 calls · 8 failed<\/span>/);
});

test("a Tool map whose digest could not be read shows dashes, never zero calls or zero failed, on tiles and source cards", async () => {
  const html = await page(null, { tab: "map" }, { inventory: SHAPE_INV });
  const tiles = [...html.matchAll(/<button class="(?:mln )?mc[^"]*" data-act="th-pick"[^>]*>([\s\S]*?)<\/button>/g)].map((m) => m[1]);
  expect(tiles.length).toBeGreaterThan(0);
  for (const t of tiles) expect(t).not.toMatch(/\b0 (?:calls|failed|refused)\b/);
  expect(html).toMatch(/— calls · — failed/);
  expect(html).toMatch(/<p class="sub">\d+ tools? · — calls<\/p>/);
  expect(html).not.toMatch(/<p class="sub">\d+ tools? · 0 calls/);
});

test("a recorded window with no failures reads 0 failed and the quiet tint, not a dash", async () => {
  const data = readP(seedP());
  const quiet = { ...data, tools: data.tools.map((t: any) => ({ ...t, failures: 0, errors: 0, denials: 0, rate: 0 })) };
  const cards = (await page(quiet, { tab: "map" }, { inventory: SHAPE_INV })).split('<div class="thcards">')[1];
  expect(cards).toMatch(/<button class="mln mc ok-t" data-act="th-pick" data-src="core" data-kind="builtin"[^>]*><span class="kl">built-in<\/span><b>2<\/b><span>70 calls · 0 failed<\/span>/);
});
