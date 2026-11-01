// The daily tool-health record (spec section 7): one UTC day's counts as an eval-run body, and the pooled rate over several days.
// Hand-built ledger rows only; nothing here reads or writes a real HOME, ledger or log.
import { test, expect } from "bun:test";
import { buildRecord, poolRate, poolRecords, recordRollup } from "../../eval/worker-digest/tool-health-record.mjs";

const agent = { id: "main", role: "agent", kind: null, model: "gpt-6.1-sol" };
const DAY = "2026-10-28";
const sid = (n: number) => "48160000-0000-4000-8000-0000000002" + String(n).padStart(2, "0");
const evalOn = (day: string, n: number, health: any[]) => ({ eval: "leg-trajectory", run_id: sid(n), status: "ok", ts: `${day}T12:00:00Z`, lane: "native", model: "gpt-6.1-sol", config: {},
  meta: { leg: true, started_ts: Date.parse(`${day}T12:00:00Z`), profile: "worker-impl", tool_health: health } });
const tool = (day: string, name: string, calls: number, classes: Record<string, number> = {}) => {
  const denials = Object.values(classes).reduce((n, v) => n + v, 0);
  return { agent, tool: name, calls, failures: denials, errors: 0, denials, classes, day };
};
const fail = (n: number, cls: string, count: number, ids: string[] = [], at = `${DAY}T10:30:00Z`) => ({ session: sid(n), agent, class: cls, failure: cls.split("/")[0], count, recovered: null,
  tool_call_ids: ids, first_ts: Date.parse(at), last_ts: Date.parse(at) });
const WIRED = { "block-read-secrets": ["Bash", "PowerShell", "Read", "Grep"], "read-clamp": ["Bash", "Read", "Grep"] };
const CLEAN = { skip: { state: "ok", rows: [] }, run: { state: "ok", rows: [] } };
const SECRETS = "denied/block-read-secrets";
// Fixture Q: Bash 4, Read 3, Grep 2, PowerShell 1 calls (10); three secrets refusals, one read-clamp.
const qEvals = (day = DAY) => [evalOn(day, 1, [tool(day, "Bash", 4, { [SECRETS]: 1 }), tool(day, "Read", 3, { [SECRETS]: 1, "denied/read-clamp": 1 }), tool(day, "Grep", 2), tool(day, "PowerShell", 1, { [SECRETS]: 1 })])];
const qFails = () => [fail(1, SECRETS, 3), fail(1, "denied/read-clamp", 1)];
const day = (rollup: any, d = DAY) => buildRecord(rollup, { day: d });
const roll = (evals: any[], fails: any[], opts: any = {}, d = DAY) => recordRollup(evals, fails, d, { eligible: WIRED, chain: CLEAN, ...opts });

test("daily-record-shares-counts-and-suppresses-partial-learning", () => {
  const rec = day(roll(qEvals(), qFails()));
  expect(rec).toMatchObject({ status: "ok", n: 10 });
  expect(rec.metrics["guard.block-read-secrets.eligible_calls"]).toBe(10);
  expect(rec.metrics["guard.block-read-secrets.deny_rate"]).toBe(0.3);
  expect(rec.metrics["tool.Bash.calls"]).toBe(4);
  expect(rec.cases["guard:block-read-secrets"]).toMatchObject({ denials: 3, eligible_calls: 10, reason_rule: 0, reason_before_logging: 0, reason_not_established: 3 });
  expect(rec.cases["tool:Read"]).toMatchObject({ calls: 3, failures: 2, denials: 2 });
  // Cases and metrics hold numbers, booleans or null only, never text.
  for (const v of Object.values(rec.cases).flatMap((c: any) => Object.values(c))) expect(["number", "boolean", "object"]).toContain(typeof v);
  for (const v of Object.values(rec.metrics)) expect(v === null || typeof v === "number").toBe(true);
  // The day lives in meta; the config holds neither the date nor a count, so two days share one series.
  expect(rec.meta.day).toBe(DAY);
  expect(JSON.stringify(rec.config)).not.toContain("2026-");
  const other = day(roll(qEvals("2026-10-27"), [fail(1, SECRETS, 3, [], "2026-10-27T10:30:00Z"), fail(1, "denied/read-clamp", 1, [], "2026-10-27T10:30:00Z")], {}, "2026-10-27"), "2026-10-27");
  expect(other.config).toEqual(rec.config);
});

test("a record with a missing source or denominator is partial and its unknowns are null, never zero", () => {
  const noWiring = day(roll(qEvals(), qFails(), { eligible: null }));
  expect(noWiring.status).toBe("partial");
  expect(noWiring.metrics["guard.block-read-secrets.eligible_calls"]).toBeNull();
  expect(noWiring.metrics["guard.block-read-secrets.deny_rate"]).toBeNull();
  expect(noWiring.meta.audit.missing_sources).toContain("wiring");
  const noChain = day(roll(qEvals(), qFails(), { chain: { skip: { state: "absent" }, run: { state: "absent" } } }));
  expect(noChain.status).toBe("partial");
  expect(noChain.cases["guard:block-read-secrets"].reason_rule).toBeNull();
  expect(noChain.meta.audit.missing_sources).toContain("hook-chain log");
  // A chain row whose provenance cannot be shown is unverified, which also makes the record partial.
  const legacy = { skip: { state: "ok", rows: [{ ts: `${DAY}T10:00:00.000Z`, action: "deny", member: "x.sh", reason: "ETIMEDOUT", sessionId: "s", callId: "toolu_1", invocation: "000000000001", occurrence: 0 }] }, run: { state: "ok", rows: [] } };
  expect(day(roll(qEvals(), qFails(), { chain: legacy })).status).toBe("partial");
});

test("a permission prompt is not a guard and gets no guard case or metric", () => {
  const evals = [evalOn(DAY, 1, [tool(DAY, "Bash", 4, { [SECRETS]: 1, "denied/permission-prompt": 2 }), tool(DAY, "Read", 3, { [SECRETS]: 1 }), tool(DAY, "Grep", 2), tool(DAY, "PowerShell", 1, { [SECRETS]: 1 })])];
  const rec = day(roll(evals, [fail(1, SECRETS, 3), fail(1, "denied/permission-prompt", 2)]));
  expect(Object.keys(rec.cases).filter((k) => k.includes("permission-prompt"))).toEqual([]);
  expect(Object.keys(rec.metrics).filter((k) => k.includes("permission-prompt"))).toEqual([]);
  expect(rec.cases["guard:block-read-secrets"]).toBeDefined();
});

test("a complete day with no calls is inconclusive and every rate is null", () => {
  const rec = day(roll([evalOn(DAY, 1, [])], []));
  expect(rec.status).toBe("inconclusive");
  expect(rec.n).toBe(0);
  expect(rec.metrics.calls).toBe(0);
  expect(rec.metrics["guard.block-read-secrets.deny_rate"] ?? null).toBeNull();
});

test("a day nobody ran has no record", () => {
  expect(day(roll([], []))).toBeNull();
});

test("the reason split is carried, and rows plus residuals equal refused", () => {
  const hit = { ts: `${DAY}T10:00:00.000Z`, v: 1, origin: "production", event: "PreToolUse", session: "s", callId: "toolu_a", tool: "Read", invocation: "00000000000a", exit: 2, elapsed: 5,
    members: [{ member: "block-read-secrets.sh", occurrence: 0, outcome: "deny", reason: "RULE", elapsed: 4, denyLine: "no" }] };
  const rec = day(roll(qEvals(), [fail(1, SECRETS, 3, ["toolu_a", "toolu_b"]), fail(1, "denied/read-clamp", 1)], { chain: { skip: { state: "ok", rows: [] }, run: { state: "ok", rows: [hit] } } }));
  const g = rec.cases["guard:block-read-secrets"];
  expect(g).toMatchObject({ denials: 3, reason_rule: 1, reason_not_established: 2, reason_before_logging: 0 });
  expect(g.reason_rule + g.reason_timeout + g.reason_deadline + g.reason_buffer + g.reason_other + g.reason_before_logging + g.reason_not_established).toBe(g.denials);
  expect(rec.status).toBe("ok");
});

test("a pooled rate sums the counts before dividing: 1/10 and 9/30 pool to 10/40 = 25%, not the 20% mean of the daily rates", () => {
  expect(poolRate([[1, 10], [9, 30]])).toBe(0.25);
  expect(poolRate([[1, 10], [9, 30]])).not.toBe((1 / 10 + 9 / 30) / 2);
  // Denominator 0 or unknown gives null, and one unknown day makes the whole pool unknown.
  expect(poolRate([[0, 0]])).toBeNull();
  expect(poolRate([[1, 10], [2, null]])).toBeNull();
  expect(poolRate([])).toBeNull();
  // The same sum over two daily records of one series.
  const d1 = day(roll([evalOn("2026-10-27", 1, [tool("2026-10-27", "Read", 10, { "denied/read-clamp": 1 })])], [fail(1, "denied/read-clamp", 1, [], "2026-10-27T10:30:00Z")], {}, "2026-10-27"), "2026-10-27");
  const d2 = day(roll([evalOn(DAY, 2, [tool(DAY, "Read", 30, { "denied/read-clamp": 9 })])], [fail(2, "denied/read-clamp", 9)]));
  expect(poolRecords([d1, d2], "guard:read-clamp", "denials", "eligible_calls")).toBe(0.25);
  expect(poolRecords([d1, { ...d2, status: "partial" }], "guard:read-clamp", "denials", "eligible_calls")).toBe(0.1); // a partial day does not enter the pool
});

// ---- the command: temp HOME, temp ledgers, temp chain logs; the real station is never read or written.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const CLI = resolve(import.meta.dir, "../tool-health-record.ts");
function cliEnv() {
  const dir = mkdtempSync(join(tmpdir(), "th-record-"));
  mkdirSync(join(dir, "repo"), { recursive: true });
  writeFileSync(join(dir, "eval.jsonl"), qEvals().map((r) => JSON.stringify(r)).join("\n") + "\n");
  writeFileSync(join(dir, "fail.jsonl"), qFails().map((r) => JSON.stringify(r)).join("\n") + "\n");
  const env = { PATH: process.env.PATH!, HOME: dir, HIMMEL_REPO: join(dir, "repo"), HIMMEL_EVAL_RUNS_LEDGER: join(dir, "eval.jsonl"), HIMMEL_WORKER_SESSION_FAILURES_LEDGER: join(dir, "fail.jsonl"),
    RUN_HOOK_CHAIN_SKIP_LOG: join(dir, "none-skips.jsonl"), RUN_HOOK_CHAIN_RUN_LOG: join(dir, "none-runs.jsonl") };
  return { dir, env };
}
const cli = (env: any, ...args: string[]) => spawnSync("bun", [CLI, ...args], { env, encoding: "utf8", timeout: 60000 });

test("the command prints a day's record without writing, refuses a day that has not finished, and writes once", () => {
  const { dir, env } = cliEnv();
  try {
    const dry = cli(env, "--day", DAY, "--dry-run");
    expect(dry.status).toBe(0);
    const body = JSON.parse(dry.stdout);
    expect(body).toMatchObject({ day: DAY, status: "partial", n: 10 });
    expect(body.meta.audit.missing_sources).toContain("wiring");
    expect(existsSync(join(dir, "out.jsonl"))).toBe(false);
    const today = cli(env, "--day", new Date().toISOString().slice(0, 10), "--dry-run");
    expect(today.status).toBe(2);
    expect(today.stderr).toContain("has not finished");
    // A day that does not exist is refused, not read as another day.
    const fake = cli(env, "--day", "2026-02-30", "--dry-run");
    expect(fake.status).toBe(2);
    expect(fake.stderr).toContain("real YYYY-MM-DD date");
    const ledger = join(dir, "out.jsonl");
    expect(cli(env, "--day", DAY, "--ledger", ledger).status).toBe(0);
    const again = cli(env, "--day", DAY, "--ledger", ledger);
    expect(again.stdout).toContain("exists");
    expect(readFileSync(ledger, "utf8").trim().split("\n").length).toBe(1);
    expect(JSON.parse(readFileSync(ledger, "utf8")).eval).toBe("tool-health");
    expect(cli(env, "--day", "2026-01-01", "--dry-run").stdout).toContain("nothing recorded");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
