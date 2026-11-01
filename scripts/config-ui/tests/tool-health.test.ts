// three seeded digests exercise the real ledger writer and server rate math.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import * as sources from "../health-sources";
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
      tool_health: [{ agent, lane: s.lane, tool: "Bash", calls: s.bash, failures: s.errors + s.denied, errors: s.errors, denials: s.denied }, { agent, lane: s.lane, tool: "Read", calls: s.read, failures: 0, errors: 0, denials: 0 }],
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
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: null, failures: 8, rate: null });
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

test("a mixed legacy population poisons incomplete denominators, not failure counts", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  delete rows[0].meta.tool_health;
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env);
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: null, failures: 8, rate: null });
  expect(data.daily.find((r: any) => r.tool === "Bash" && r.lane === "native").rate).toBeNull();
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
  expect(skill("chief").listing_tokens).toBeLessThan(skill("worker-impl").listing_tokens);
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

test("Bash rolls up by command head and cause; rtk joins by call id and a missing history stays unread", async () => {
  const env = seedSplit();
  const byId = new Map([["toolu_a", { path: "rtk", deny: false }], ["toolu_c", { path: "bash", deny: true }], ["toolu_d", { path: "bash", deny: false }]]);
  const data = readRtk(env, () => ({ state: "ok", byId, duplicates: 1 }));
  expect(data.bash.commands).toEqual([
    { head: "git", calls: 2, failures: 1, cause: { command: 1, rtk_hook: 0, guard: 0, classifier: 0, other: 0 }, rtk: 1 },
    { head: "cat", calls: 1, failures: 1, cause: { command: 0, rtk_hook: 1, guard: 0, classifier: 0, other: 0 }, rtk: 0 },
    { head: "gh", calls: 1, failures: 1, cause: { command: 0, rtk_hook: 0, guard: 0, classifier: 1, other: 0 }, rtk: 0 },
    { head: "other", calls: 1, failures: 1, cause: { command: 0, rtk_hook: 0, guard: 0, classifier: 0, other: 1 }, rtk: 0 },
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
const cells = (html: string, attr: string) => [...html.matchAll(new RegExp(`<tr ${attr}="([^"]*)"[^>]*>([\\s\\S]*?)</tr>`, "g"))].map((m) => [m[1], [...m[2].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((c) => c[1].replace(/<[^>]*>/g, ""))]);

test("overview-call-total-is-the-tool-attempt-sum", async () => {
  const data = readP(seedP());
  expect(data.totalCalls).toBe(70);
  expect(data.tools.reduce((n: number, t: any) => n + t.calls, 0)).toBe(70);
  expect(kpi(await page(data), "calls")).toBe("70");
  const u = readP(seedP((rows) => { delete rows[0].meta.tool_health; }));
  expect(u.totalCalls).toBeNull();
  expect(kpi(await page(u), "calls")).toBe("—");
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
  expect(kpi(await page(data), "denied")).toBe("5");
  data.tools.find((t: any) => t.tool === "Bash").denials = 60;
  const bad = await page(data);
  expect(bad).toContain("Count check failed");
  expect(kpi(bad, "rate")).toBe("—");
  expect(cells(bad, "data-tool-row").find(([k]) => k === "Bash")?.[1]).not.toContain("16.0%");
});

test("overview-recovery-keeps-unknown-class-outcomes-out", async () => {
  const data = readP(seedP());
  const html = await page(data);
  expect(kpi(html, "recovery")).toBe("25.0%");
  expect(kpiSub(html, "recovery")).toContain("1 of 4 known · 4 unclassified");
  for (const t of data.tools) { t.known = 0; t.recovered = 0; }
  expect(kpi(await page(data), "recovery")).toBe("—");
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
