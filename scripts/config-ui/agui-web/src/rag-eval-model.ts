export const RAG_EVAL_URL = "/api/rag-eval";
export const NOT_MEASURED = "not measured yet";

export type LedgerRow = {
  eval: string; ts: string; run_id: string; status: string; n: number; metrics: Record<string, number | null>;
  protocol?: string; pilot?: PilotRow | null;
};
export type Split = { count: number; n: number };
export type Measure = {
  count: number; n: number; rate: number; tokens: number | null; ms: number | null; ts: string; runId: string;
  heldout: Split | null; insample: Split | null;
};
export type Route = { key: string; label: string; finds: Measure | null; findsGap: string; answers: Measure | null; answersGap: string };
export type RagEval = { bottomLine: string; sampleNote: string | null; routes: Route[]; newest: string | null; pilot: Pilot | null };

const ROUTES: { key: string; label: string; finds: string | null; answers: string | null; findsGap?: string }[] = [
  { key: "combined", label: "Combined: grep + qmd + graphify", finds: "combined", answers: "fused-cached" },
  { key: "qmd-hybrid", label: "qmd · hybrid + rerank", finds: "qmd-hybrid", answers: null },
  { key: "qmd-vec", label: "qmd · vector + rerank", finds: null, answers: "vec-rerank" },
  { key: "qmd-lex", label: "qmd · keyword + rerank", finds: null, answers: "bm25-rerank" },
  { key: "graphify", label: "graphify · query", finds: "graphify", answers: null },
  { key: "grep", label: "Plain grep", finds: "grep", answers: null },
  { key: "vanilla", label: "Vanilla Claude (no route tool)", finds: null, answers: "vanilla", findsGap: "no ranked list to score" },
];

const HIT_AT_5_LEGACY_NAME = "recall@5";
const FILE_HIT_LEGACY_NAME = "correct";
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const newest = (rows: LedgerRow[], name: string, has: (r: LedgerRow) => boolean) =>
  rows.filter((r) => r.eval === name && r.status === "ok" && r.metrics && has(r)).sort((a, b) => (a.ts < b.ts ? 1 : -1))[0];

const split = (count: number | null, n: number | null): Split | null => (count !== null && n !== null && n > 0 ? { count, n } : null);

function finds(rows: LedgerRow[], arm: string): Measure | null {
  const hit = (m: LedgerRow["metrics"], key: string) => num(m[`${key}.hit@5`]) ?? num(m[`${key}.${HIT_AT_5_LEGACY_NAME}`]);
  const r = newest(rows, "retrieval-eval", (x) => hit(x.metrics, arm) !== null && (num(x.n) ?? 0) > 0);
  if (!r) return null;
  const m = r.metrics, rate = hit(m, arm)!;
  const part = (s: string) => {
    const n = num(m[`${arm}.${s}.n`]), rate = hit(m, `${arm}.${s}`);
    return split(rate !== null && n !== null ? Math.round(rate * n) : null, n);
  };
  return {
    count: Math.round(rate * r.n), n: r.n, rate, tokens: num(m[`${arm}.tokens_mean`]), ms: num(m[`${arm}.ms_median`]), ts: r.ts, runId: r.run_id,
    heldout: part("heldout"), insample: part("insample"),
  };
}

function answers(rows: LedgerRow[], arm: string): Measure | null {
  const size = (x: LedgerRow) => num(x.metrics[`${arm}.n`]) ?? num(x.n) ?? 0;
  const hits = (m: LedgerRow["metrics"], key: string) => num(m[`${key}.file_hit`]) ?? num(m[`${key}.${FILE_HIT_LEGACY_NAME}`]);
  const r = newest(rows, "answer-ab", (x) => hits(x.metrics, arm) !== null && size(x) > 0);
  if (!r) return null;
  const m = r.metrics, count = hits(m, arm)!, n = size(r);
  const mix = ["input", "output", "cache_read", "cache_creation"].map((k) => num(m[`${arm}.${k}`]));
  const tokens = mix.every((t) => t !== null) ? (mix as number[]).reduce((a, b) => a + b, 0) / n : null;
  const part = (s: string) => split(hits(m, `${arm}.${s}`), num(m[`${arm}.${s}.n`]));
  return { count, n, rate: count / n, tokens, ms: num(m[`${arm}.ms_median`]), ts: r.ts, runId: r.run_id, heldout: part("heldout"), insample: part("insample") };
}

export function wilson(k: number, n: number, z = 1.96): [number, number] {
  const p = k / n, d = 1 + (z * z) / n, c = p + (z * z) / (2 * n), h = z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n));
  return [(c - h) / d, (c + h) / d];
}

const pct = (m: Measure) => `${Math.round(m.rate * 100)}%`;
const of = (m: Measure) => `${m.count} of ${m.n}`;
function bottomLine(by: Record<string, Route>): string {
  const parts: string[] = [];
  const c = by.combined.finds, g = by.grep.finds;
  if (c && g && c.runId === g.runId) parts.push(`Combined search finds the right file on ${pct(c)} of agent questions (${of(c)}), plain grep on ${pct(g)} (${of(g)})`);
  const a = by.combined.answers, v = by.vanilla.answers;
  if (a && v && a.runId === v.runId) {
    const [al, ah] = wilson(a.count, a.n), [vl, vh] = wilson(v.count, v.n);
    const word = al > vh ? "beats" : ah < vl ? "trails" : "ties";
    parts.push(`on naming a gold file among up to 3 guesses in a Claude session, which does not check the answer, ${parts.length ? "it" : "combined search"} ${word} vanilla Claude, ${of(a)} against ${of(v)}${word === "ties" ? ", with overlapping 95% ranges" : ""}`);
  }
  if (!parts.length) return Object.values(by).some((r) => r.finds || r.answers) ? "Not enough has been measured yet to compare combined search with grep or vanilla Claude." : "Nothing has been measured yet, so no route can be compared.";
  const line = parts.join("; ") + ".";
  return line[0].toUpperCase() + line.slice(1);
}

export function ragEvalModel(rows: LedgerRow[]): RagEval {
  const routes = ROUTES.map((d) => ({
    key: d.key, label: d.label,
    finds: d.finds ? finds(rows, d.finds) : null, findsGap: d.findsGap ?? NOT_MEASURED,
    answers: d.answers ? answers(rows, d.answers) : null, answersGap: NOT_MEASURED,
  }));
  const stamps = routes.flatMap((r) => [r.finds?.ts, r.answers?.ts]).filter((t): t is string => !!t).sort();
  const sampled = routes.map((r) => r.finds).find((f) => f?.insample);
  const sampleNote = sampled ? `${sampled.insample!.n} of the ${sampled.n} questions are in-sample: the routes were tuned on them, so the held-out questions are the fairer test.` : null;
  return { bottomLine: bottomLine(Object.fromEntries(routes.map((r) => [r.key, r]))), sampleNote, routes, newest: stamps.at(-1) ?? null,
    pilot: pilotModel(rows) };
}

// ---------------------------------------------------------------------------------------------
// The three-answer pilot: V (plain Claude Code), S (station search), Q (local search) on one
// common task set. Its rows are their own protocol group and never share an axis with the old
// file-hit runs above.
export const PILOT_PROTOCOL = "rag-pilot-r18";
export const ARM_NAMES: Record<"V" | "S" | "Q", string> = { V: "Plain Claude Code (V)", S: "Station search (S)", Q: "Local search (Q)" };
type Nums = (number | null)[] | null;
type ArmRow = {
  supported?: number | null; cost_usd?: number | null; cost_mean_usd?: number | null; cash_usd?: number | null;
  route?: { offered: number | null; called: number | null; returned: number | null; read: number | null; cited: number | null } | null;
  qmd_only?: number | null; graph_only?: number | null; both?: number | null; skips?: number | null; errors?: number | null;
  timeouts?: number | null; unjudged?: number | null; paraphrase_candidates?: number | null; latency_ms_median?: number | null; tokens_mean?: number | null;
};
type CompRow = {
  contrast: string | null; confirmatory: boolean | null; family: string | null; discordant: Nums; p_raw: number | null;
  p_adjusted: number | null; gain_pp: number | null; interval_pp: Nums; interval_label: string | null; real_half_gain_pp: number | null; label: string | null;
};
type Cells = Record<string, { V: Nums; S: Nums; Q: Nums }> | null;
export type PilotRow = {
  stop_kind: string | null; reason: string | null; finalization_status: string | null; void: boolean | null;
  counts: { attempted: number | null; completed: number | null; common_scored: number | null } | null; common_cohort_hash: string | null;
  judge: { completed_rounds: number | null; discarded_verdicts: number | null; unjudged: Record<string, number | null> | null; ended: string | null } | null;
  supported: Record<string, number | null> | null; per_arm: Record<string, ArmRow | null> | null; comparisons: CompRow[] | null;
  cost_intervals: Record<string, Nums> | null; kinds: Cells; halves: Cells; strata: Cells;
  lists: { complete: boolean | null; S: { fact_file_at5: Nums; by_stratum: Record<string, Nums> | null } | null; Q: { fact_file_at5: Nums; by_stratum: Record<string, Nums> | null } | null } | null;
  exposure: string | null; coupling: string | null; spend: { subscription_equivalent_usd: number | null; cash_usd: number | null; total_usd: number | null } | null;
};
export type PilotComparison = {
  contrast: "S-V" | "Q-V" | "S-Q"; confirmatory: boolean; label: string | null; gainPp: number; pRaw: number; pAdjusted: number | null;
  interval: [number, number]; intervalLabel: string; realHalfGainPp: number | null; discordant: [number, number];
};
// One answer clause and one cost clause per retrieval arm, drawn with the SAME class: a cost
// line may never shrink beside the answer line it qualifies.
export type PilotClause = { arm: "S" | "Q"; answer: string; cost: string; answerClass: string; costClass: string; loss: boolean; comparison: PilotComparison };
export type PilotArm = { arm: "V" | "S" | "Q"; name: string; supported: number | null; costUsd: number | null; cashUsd: number | null;
  route: string | null; use: string | null; skips: number | null; errors: number | null; unjudged: number | null; paraphrases: number | null };
export type Pilot = {
  runId: string; ts: string; status: "full" | "short" | "void"; headline: string; stopNote: string; n: number;
  counts: string; judge: string; arms: PilotArm[]; clauses: PilotClause[] | null; exploratory: PilotComparison | null; noComparison: string | null;
  cells: { title: string; rows: { name: string; V: string; S: string; Q: string }[] }[]; lists: string[]; spend: string; disclosures: string[];
};

const CLAUSE = "rag-clause";
const usd = (x: number | null | undefined) => (typeof x === "number" ? `$${x.toFixed(2)}` : "unavailable");
const p3 = (x: number | null | undefined) => (typeof x === "number" ? (x < 0.001 ? "<0.001" : x.toFixed(3)) : "n/a");
const pts = (x: number) => `${x > 0 ? "+" : ""}${x.toFixed(1)} points`;
const kn = (v: Nums | undefined) => (Array.isArray(v) && typeof v[0] === "number" && typeof v[1] === "number" ? `${v[0]} of ${v[1]}` : "unavailable");

function comparison(c: CompRow | undefined, contrast: "S-V" | "Q-V" | "S-Q"): PilotComparison | null {
  if (!c || typeof c.gain_pp !== "number" || typeof c.p_raw !== "number" || !Array.isArray(c.interval_pp)) return null;
  const [lo, hi] = c.interval_pp;
  if (typeof lo !== "number" || typeof hi !== "number") return null;
  const d = Array.isArray(c.discordant) ? c.discordant : [null, null];
  return {
    contrast, confirmatory: contrast !== "S-Q" && c.confirmatory === true, label: contrast === "S-Q" ? null : c.label,
    gainPp: c.gain_pp, pRaw: c.p_raw, pAdjusted: contrast === "S-Q" ? null : c.p_adjusted, interval: [lo, hi],
    intervalLabel: c.interval_label || "pointwise 95% interval, not simultaneous", realHalfGainPp: c.real_half_gain_pp,
    discordant: [typeof d[0] === "number" ? d[0] : 0, typeof d[1] === "number" ? d[1] : 0],
  };
}

function pilotArm(p: PilotRow, a: "V" | "S" | "Q"): PilotArm {
  const r = (p.per_arm && p.per_arm[a]) || {};
  const rt = r.route;
  return {
    arm: a, name: ARM_NAMES[a], supported: p.supported?.[a] ?? null, costUsd: r.cost_usd ?? null, cashUsd: r.cash_usd ?? null,
    route: a === "V" ? null : rt ? `offered ${rt.offered ?? "?"}, called ${rt.called ?? "?"}, returned ${rt.returned ?? "?"}, read ${rt.read ?? "?"}, cited ${rt.cited ?? "?"}` : "unavailable",
    use: a === "V" ? null : `qmd only ${r.qmd_only ?? "?"}, graph only ${r.graph_only ?? "?"}, both ${r.both ?? "?"}`,
    skips: r.skips ?? null, errors: r.errors ?? null, unjudged: r.unjudged ?? null, paraphrases: r.paraphrase_candidates ?? null,
  };
}

function cellTable(title: string, cells: Cells) {
  if (!cells) return { title, rows: [] };
  return { title, rows: Object.entries(cells).map(([name, v]) => ({ name, V: kn(v.V), S: kn(v.S), Q: kn(v.Q) })) };
}

export function pilotModel(rows: LedgerRow[]): Pilot | null {
  const r = rows.filter((x) => x.protocol === PILOT_PROTOCOL && x.eval === "answer-ab" && x.pilot).sort((a, b) => (a.ts < b.ts ? 1 : -1))[0];
  if (!r || !r.pilot) return null;
  const p = r.pilot;
  const n = p.counts?.common_scored ?? 0;
  const isVoid = p.void === true || p.stop_kind === "HARD_STOP" || n < 36;
  const status: Pilot["status"] = isVoid ? "void" : n < 40 || p.finalization_status === "short" ? "short" : "full";
  const arms = (["V", "S", "Q"] as const).map((a) => pilotArm(p, a));
  const comps = Object.fromEntries((p.comparisons || []).map((c) => [c.contrast, c]));
  const sv = comparison(comps["S-V"], "S-V"), qv = comparison(comps["Q-V"], "Q-V");
  let clauses: PilotClause[] | null = null, noComparison: string | null = null;
  if (isVoid) noComparison = `No answer comparison: the run ${p.stop_kind === "HARD_STOP" ? "hard-stopped" : "ended"} (${p.reason || "no reason recorded"}) with ${n} common tasks. Only spend and service state are shown.`;
  else if (!sv || !qv || !p.common_cohort_hash) noComparison = "No answer comparison: the row lacks the S and Q results against V on one common task set.";
  else {
    const vArm = arms[0];
    const ci = p.cost_intervals || {};
    clauses = ([["S", sv], ["Q", qv]] as const).map(([a, c]) => {
      const me = arms.find((x) => x.arm === a)!;
      const interval = ci[c.contrast];
      return {
        arm: a, comparison: c, loss: c.gainPp < 0, answerClass: CLAUSE, costClass: CLAUSE,
        answer: `${ARM_NAMES[a]}: ${c.label} ${me.supported ?? "?"} of ${n} supported answers against ${vArm.supported ?? "?"} of ${n} for plain Claude Code; ${pts(c.gainPp)}, raw p ${p3(c.pRaw)}, Holm-adjusted p ${p3(c.pAdjusted)}; ${c.intervalLabel} ${c.interval[0].toFixed(1)} to ${c.interval[1].toFixed(1)} points.`
          + (c.realHalfGainPp !== null ? ` Real questions alone: ${pts(c.realHalfGainPp)}.` : ""),
        cost: `${ARM_NAMES[a]} cost: ${usd(me.costUsd)} for the run against ${usd(vArm.costUsd)} for plain Claude Code`
          + (Array.isArray(interval) && typeof interval[0] === "number" && typeof interval[1] === "number" && typeof interval[2] === "number"
            ? `; per task ${interval[0] >= 0 ? "+" : ""}$${interval[0].toFixed(3)} (pointwise 95% $${interval[1].toFixed(3)} to $${interval[2].toFixed(3)})` : "")
          + `; search cash ${usd(me.cashUsd)}.`,
      };
    });
  }
  const xq = clauses ? comparison(comps["S-Q"], "S-Q") : null;
  const headline = clauses ? clauses.map((c) => `${ARM_NAMES[c.arm]}: ${c.comparison.label}`).join(" ")
    : "The pilot gives no answer comparison.";
  const j = p.judge || { completed_rounds: null, discarded_verdicts: null, unjudged: null, ended: null };
  const lists: string[] = [];
  if (!p.lists) lists.push("Retrieval lists: not run.");
  else {
    if (!p.lists.complete) lists.push("Retrieval lists are incomplete: no full 40-task list comparison.");
    for (const a of ["S", "Q"] as const) {
      const l = p.lists[a];
      lists.push(`${ARM_NAMES[a]} fixed lists: a file holding a required fact in the top five on ${kn(l?.fact_file_at5)} answerable tasks`
        + (l?.by_stratum ? ` (${Object.entries(l.by_stratum).map(([k, v]) => `${k} ${kn(v)}`).join(", ")})` : "") + ".");
    }
  }
  const sp = p.spend || { subscription_equivalent_usd: null, cash_usd: null, total_usd: null };
  return {
    runId: r.run_id, ts: r.ts, status, headline, n,
    stopNote: status === "void" ? "Void" : status === "short" ? `Short pilot: ${n} of 40 tasks scored in all three setups` : "Full pilot: all 40 tasks scored in all three setups",
    counts: `${p.counts?.attempted ?? "?"} tasks attempted, ${p.counts?.completed ?? "?"} completed, ${n} scored in all three setups.`,
    judge: `Judge: ${j.completed_rounds ?? 0} complete rounds applied, ${j.discarded_verdicts ?? 0} partial-round verdicts discarded; unjudged V ${j.unjudged?.V ?? 0}, S ${j.unjudged?.S ?? 0}, Q ${j.unjudged?.Q ?? 0} (unjudged counts as not supported)${j.ended ? `; judging ended: ${j.ended}` : ""}.`,
    arms, clauses, exploratory: xq, noComparison,
    cells: [cellTable("By kind", p.kinds), cellTable("Real and harder halves", p.halves), cellTable("Doc, code and mixed sources", p.strata)],
    lists, spend: `Spend on every attempted task: ${usd(sp.total_usd)} (subscription equivalent ${usd(sp.subscription_equivalent_usd)}, search cash ${usd(sp.cash_usd)}).`,
    disclosures: [p.exposure, p.coupling].filter((x): x is string => !!x),
  };
}

export const isRagEvalHash = (hash: string) => new URLSearchParams(hash.replace(/^#/, "")).get("page") === "rag-eval";
