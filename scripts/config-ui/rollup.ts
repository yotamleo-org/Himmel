// rollup.ts — the read-only source behind GET /api/rollup: the weekly roll-up (scripts/eval/weekly-rollup.py,
// ~/.himmel/state/rollup/weekly.jsonl) as three trend cards. The deltas are the ones the writer stored; nothing is
// recomputed here or in the browser. A missing file is state absent, never an error.
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
type Row = { kind: string; key: string; partial?: boolean; since?: string; delta?: Record<string, number | null>; [k: string]: unknown };
export type Point = { key: string; value: number };
export type Compared = { key: string; value: number; delta: number | null; prev_key: string | null; partial: boolean };
export type Card = {
  id: "velocity" | "cost" | "health"; title: string; metric: string; unit: string; state: "ok" | "nodata";
  spark: Point[]; week: Compared | null; version: Compared | null; running: Point | null; sentence: string;
};
export type Rollup = { state: "ok"; cards: Card[] } | { state: "absent"; reason: string };

const SPARK_WEEKS = 12;
// series = the roll-up column the card plots; better = which direction of change is good; words = [better, worse, same].
const CARDS = [
  { id: "velocity", title: "Velocity", metric: "merges per week", unit: "merges", series: "merges", better: 1, words: ["faster", "slower", "as fast"] },
  { id: "cost", title: "Cost", metric: "cost per ticket (Opus-eq)", unit: "eq", series: "cost_eq_per_ticket", better: -1, words: ["cheaper", "costlier", "as costly"] },
  { id: "health", title: "Health", metric: "red-main incidents", unit: "red main", series: "red_main", better: -1, words: ["healthier", "less healthy", "as healthy"] },
] as const;

export const rollupFile = (env: Env) => env.WEEKLY_ROLLUP_FILE || join(env.HOME || homedir(), ".himmel", "state", "rollup", "weekly.jsonl");

function rows(file: string): Row[] | null {
  let text: string;
  try { text = readFileSync(file, "utf8"); } catch { return null; }
  const out: Row[] = [];
  for (const line of text.split("\n")) {
    try { const r = JSON.parse(line); if (r && typeof r === "object" && typeof r.kind === "string" && typeof r.key === "string") out.push(r); } catch { /* a torn or foreign line */ }
  }
  return out;
}

const isNum = (x: unknown): x is number => typeof x === "number" && Number.isFinite(x);
const byKey = (a: Row, b: Row) => (a.since ?? a.key) < (b.since ?? b.key) ? -1 : 1;

// the newest row of a kind that carries the series (a running week is not compared: it would read as a drop)
function newest(rs: Row[], kind: string, series: string, finished: boolean): Compared | null {
  const have = rs.filter((r) => r.kind === kind && isNum(r[series])).sort(byKey);
  const row = (finished ? have.filter((r) => !r.partial) : have).at(-1) ?? have.at(-1);
  if (!row) return null;
  const d = row.delta?.[series];
  const compared = isNum(d) && !row.partial;
  const before = rs.filter((r) => r.kind === kind).sort(byKey);
  const prev = before[before.findIndex((r) => r.key === row.key) - 1];
  return { key: row.key, value: row[series] as number, delta: compared ? d : null, prev_key: compared && prev ? prev.key : null, partial: !!row.partial };
}

function sentence(c: (typeof CARDS)[number], week: Compared | null, version: Compared | null): string {
  const say = (d: number | null, than: string) => d === null ? null : d === 0 ? `${c.words[2]} as ${than}` : `${(d * c.better > 0 ? c.words[0] : c.words[1])} than ${than}`;
  const parts = [say(week?.delta ?? null, "last week"), say(version?.delta ?? null, "last version")].filter((x): x is string => !!x);
  if (!parts.length) return "No earlier week or version to compare with yet";
  const s = parts.join(" and ");
  return s[0].toUpperCase() + s.slice(1);
}

export type Job = "on" | "off" | "unknown";
const JOB_TIMEOUT_MS = 15_000;
const JOB_TTL_MS = 30_000;
const jobs = new Map<string, { at: number; job: Promise<Job> }>();

type ProbeError = { code?: unknown; killed?: boolean; signal?: unknown };
const isBrokenProbe = (err: ProbeError | null, out: string): boolean =>
  !!err && (typeof err.code !== "number" || !!err.killed || !!err.signal || (err.code !== 0 && !/^not armed\b/m.test(out)));

export function rollupJob(script: string, timeoutMs = JOB_TIMEOUT_MS, now = Date.now()): Promise<Job> {
  const hit = jobs.get(script);
  if (hit && now - hit.at < JOB_TTL_MS) return hit.job;
  const job = new Promise<Job>((resolve) => {
    execFile("bash", [script, "status"], { encoding: "utf8", timeout: timeoutMs }, (err, stdout) => {
      const out = String(stdout || "");
      resolve(isBrokenProbe(err, out) ? "unknown" : /^ARMED\b/m.test(out) ? "on" : "off");
    });
  });
  jobs.set(script, { at: now, job });
  return job;
}

const NO_ROLLUP = "no weekly roll-up yet.";
const REASON: Record<Job, string> = {
  off: `${NO_ROLLUP} The weekly roll-up job is off; switch it on in Configure.`,
  on: `${NO_ROLLUP} The weekly roll-up job is on and has not run yet.`,
  unknown: `${NO_ROLLUP} How to fill it: bash scripts/eval/rollup-cadence.sh arm (see docs/cadences.md).`,
};

export async function readRollupWithJob(env: Env, script: string): Promise<Rollup & { job: Job }> {
  const [r, job] = [readRollup(env), await rollupJob(script)];
  return r.state === "absent" ? { ...r, reason: REASON[job], job } : { ...r, job };
}

export function readRollup(env: Env): Rollup {
  const rs = rows(rollupFile(env));
  if (!rs) return { state: "absent", reason: "no weekly roll-up yet (run scripts/eval/weekly-rollup.py write)" };
  const cards = CARDS.map((c): Card => {
    const weeks = rs.filter((r) => r.kind === "week" && isNum(r[c.series])).sort(byKey);
    const spark = (weeks.some((r) => !r.partial) ? weeks.filter((r) => !r.partial) : weeks).slice(-SPARK_WEEKS).map((r) => ({ key: r.key, value: r[c.series] as number }));
    const week = newest(rs, "week", c.series, true), version = newest(rs, "version", c.series, true);
    const live = weeks.filter((r) => r.partial).at(-1);
    const running = live ? { key: live.key, value: live[c.series] as number } : null;
    const { better: _b, words: _w, series: _s, ...shown } = c;
    return week || version
      ? { ...shown, state: "ok", spark, week, version, running, sentence: sentence(c, week, version) }
      : { ...shown, state: "nodata", spark: [], week: null, version: null, running: null, sentence: "no data yet" };
  });
  return { state: "ok", cards };
}
