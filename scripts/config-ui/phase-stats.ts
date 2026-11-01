// phase-stats.ts — the read-only source behind GET /api/phase-stats: the Eval tab's per-phase numbers for the last 7 full
// UTC days, read from records the fleet already writes. Nothing is written or recomputed in the browser.
//   Build             first LIVE to the first PR opening, per ticket (status-events.jsonl)
//   Review            each branch's highest /pr-check round (<git-common-dir>/cr-review-rounds/<branch>.round)
//   Check and approve first CI run to the merge, per ticket
//   Merge and wrap up the merge to WRAPPED, per ticket
// Start, Plan and design and Assign have no record behind them: "no source yet". The cost per ticket: "no data yet".
// ponytail: a ticket's first event of each kind stands for the whole ticket (a second PR on one ticket is not split, and
// a branch whose ticket merged counts as merged in Review);
// upgrade path: key the spans by PR number once every event row carries one.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
type Ev = { ts: number; event: string; key: string; pr: string };
export type PhaseRow = {
  id: string; name: string; state: "ok" | "nodata" | "nosource"; unit: "min" | "rounds";
  n: number; median: number | null; p80: number | null; perDay: number[]; counts: string;
};
export type Outlier = { pr: string | null; phase: string; value: number; unit: "min" | "rounds"; times: number };
export type PhaseStats = {
  from: string; to: string; days: string[]; phases: PhaseRow[];
  review: { threeUp: { merged: number; notMerged: number }; under: { merged: number; notMerged: number } };
  outliers: Outlier[]; cost: { state: "nodata"; say: string };
};

const DAY = 86_400_000, MIN = 60_000;
export const statusEventsFile = (env: Env) =>
  join(env.TICKET_STATUS_STATE_DIR || join(env.HOME || homedir(), ".himmel", "state"), "status-events.jsonl");

function events(file: string): Ev[] {
  let text: string;
  try { text = readFileSync(file, "utf8"); } catch { return []; }
  const out: Ev[] = [];
  for (const line of text.split("\n")) {
    try {
      const r = JSON.parse(line), ts = Date.parse(r?.ts);
      if (Number.isFinite(ts) && typeof r.event === "string" && typeof r.key === "string") out.push({ ts, event: r.event, key: r.key, pr: typeof r.pr === "string" ? r.pr : "" });
    } catch { /* a torn line */ }
  }
  return out.sort((a, b) => a.ts - b.ts);
}

// every <branch>.round file under the rounds directory, with its highest round and when it was last written
function rounds(dir: string): { branch: string; round: number; at: number }[] {
  const out: { branch: string; round: number; at: number }[] = [];
  const walk = (d: string, prefix: string) => {
    let names: string[];
    try { names = readdirSync(d); } catch { return; }
    for (const name of names) {
      const p = join(d, name);
      let st, round;
      try {
        st = statSync(p);
        if (st.isDirectory()) { walk(p, `${prefix}${name}/`); continue; }
        if (!name.endsWith(".round")) continue;
        round = Number.parseInt(readFileSync(p, "utf8"), 10);
      } catch { continue; }
      if (Number.isInteger(round) && round > 0) out.push({ branch: prefix + name.slice(0, -".round".length), round, at: st.mtimeMs });
    }
  };
  walk(dir, "");
  return out;
}

// the ticket a branch is for: the first <project>-<number> segment after a slash ("feat/abc-12-…" → ABC-12)
const keyOf = (branch: string) => { const m = /(?:^|\/)([a-z][a-z0-9]*)-(\d+)(?=-|$)/i.exec(branch); return m ? `${m[1].toUpperCase()}-${m[2]}` : null; };

function quantile(sorted: number[], q: number): number | null {
  if (!sorted.length) return null;
  const i = (sorted.length - 1) * q, lo = Math.floor(i), hi = Math.ceil(i);
  return Math.round((sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo)) * 10) / 10;
}

export function readPhaseStats(env: Env, roundsDir: string, now: number): PhaseStats {
  const to = Math.floor(now / DAY) * DAY, from = to - 7 * DAY;
  const days = Array.from({ length: 7 }, (_, i) => new Date(from + i * DAY).toISOString().slice(0, 10));
  const inWin = (t: number) => t >= from && t < to;
  const perDay = (ts: number[]) => { const c = Array(7).fill(0); for (const t of ts) if (inWin(t)) c[Math.floor((t - from) / DAY)]++; return c; };

  // the first event of each kind per ticket, and the PR it carried
  const first = new Map<string, Map<string, Ev>>();
  for (const e of events(statusEventsFile(env))) {
    const k = first.get(e.key) ?? new Map<string, Ev>();
    if (!k.has(e.event)) k.set(e.event, e);
    first.set(e.key, k);
  }
  const prOf = (key: string) => { const k = first.get(key); return k?.get("pr-open")?.pr || k?.get("merge")?.pr || k?.get("ci-start")?.pr || null; };

  // one span phase: entered at `a`, left at the first `b` after it; counted when it entered in the window
  const span = (a: string, b: string) => {
    const entered: number[] = [], took: { key: string; v: number }[] = [];
    for (const [key, k] of first) {
      const s = k.get(a), e = k.get(b);
      if (!s || !inWin(s.ts)) continue;
      entered.push(s.ts);
      if (e && e.ts >= s.ts) took.push({ key, v: Math.round(((e.ts - s.ts) / MIN) * 10) / 10 });
    }
    return { entered, took };
  };

  const outliers: Outlier[] = [];
  const row = (id: string, name: string, counts: string, unit: "min" | "rounds", took: { key: string; v: number }[], entered: number[]): PhaseRow => {
    const vs = took.map((t) => t.v).sort((x, y) => x - y);
    const median = quantile(vs, 0.5), p80 = quantile(vs, 0.8);
    if (median !== null && p80 !== null)
      // far outside: past the 8-in-10 line and 3 × the median (2 × for rounds); a median or 8-in-10 line under 1 counts as 1
      for (const t of took) if (t.v > p80 && t.v >= (unit === "rounds" ? 2 : 3) * Math.max(median, 1))
        outliers.push({ pr: prOf(t.key), phase: id, value: t.v, unit, times: Math.round((t.v / Math.max(p80, 1)) * 10) / 10 });
    return { id, name, state: vs.length ? "ok" : "nodata", unit, n: vs.length, median, p80, perDay: perDay(entered), counts };
  };
  const none = (id: string, name: string, counts: string): PhaseRow =>
    ({ id, name, state: "nosource", unit: "min", n: 0, median: null, p80: null, perDay: [], counts });

  const build = span("live", "pr-open"), check = span("ci-start", "merge"), merge = span("merge", "wrapped");
  const merged = (key: string | null) => !!key && !!first.get(key)?.get("merge");
  const branches = rounds(roundsDir).filter((r) => inWin(r.at)).map((r) => ({ ...r, key: keyOf(r.branch) }));
  const review = { threeUp: { merged: 0, notMerged: 0 }, under: { merged: 0, notMerged: 0 } };
  for (const b of branches) review[b.round >= 3 ? "threeUp" : "under"][merged(b.key) ? "merged" : "notMerged"]++;

  const phases = [
    none("start", "Start", "nothing records when an idea arrives"),
    none("plan", "Plan and design", "nothing records an estimate or a design approval"),
    none("assign", "Assign", "nothing records a pick or a refused start"),
    row("build", "Build", "each ticket's time from LIVE to its PR opening", "min", build.took, build.entered),
    row("review", "Review", "each branch's highest review round", "rounds", branches.map((b) => ({ key: b.key ?? "", v: b.round })), branches.map((b) => b.at)),
    row("check", "Check and approve", "each ticket's time from its first CI run to its merge", "min", check.took, check.entered),
    row("merge", "Merge and wrap up", "each ticket's time from its merge to WRAPPED", "min", merge.took, merge.entered),
  ];
  outliers.sort((a, b) => b.times - a.times);
  return {
    from: new Date(from).toISOString(), to: new Date(to).toISOString(), days, phases, review,
    outliers: outliers.slice(0, 10), cost: { state: "nodata", say: "no data yet" },
  };
}
