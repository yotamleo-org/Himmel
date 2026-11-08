export const RAG_EVAL_URL = "/api/rag-eval";
export const NOT_MEASURED = "not measured yet";

export type LedgerRow = { eval: string; ts: string; run_id: string; status: string; n: number; metrics: Record<string, number | null> };
export type Split = { count: number; n: number };
export type Measure = {
  count: number; n: number; rate: number; tokens: number | null; ms: number | null; ts: string; runId: string;
  heldout: Split | null; insample: Split | null;
};
export type Route = { key: string; label: string; finds: Measure | null; findsGap: string; answers: Measure | null; answersGap: string };
export type RagEval = { bottomLine: string; sampleNote: string | null; routes: Route[]; newest: string | null };

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
  const r = newest(rows, "answer-ab", (x) => num(x.metrics[`${arm}.correct`]) !== null && size(x) > 0);
  if (!r) return null;
  const m = r.metrics, count = num(m[`${arm}.correct`])!, n = size(r);
  const mix = ["input", "output", "cache_read", "cache_creation"].map((k) => num(m[`${arm}.${k}`]));
  const tokens = mix.every((t) => t !== null) ? (mix as number[]).reduce((a, b) => a + b, 0) / n : null;
  const part = (s: string) => split(num(m[`${arm}.${s}.correct`]), num(m[`${arm}.${s}.n`]));
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
    parts.push(`on naming a gold file within 3 guesses in a Claude session ${parts.length ? "it" : "combined search"} ${word} vanilla Claude, ${of(a)} against ${of(v)}${word === "ties" ? ", with overlapping 95% ranges" : ""}`);
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
  return { bottomLine: bottomLine(Object.fromEntries(routes.map((r) => [r.key, r]))), sampleNote, routes, newest: stamps.at(-1) ?? null };
}

export const isRagEvalHash = (hash: string) => new URLSearchParams(hash.replace(/^#/, "")).get("page") === "rag-eval";
