// The chief board on the Fleet page: himmel.board/1 (board.mjs --json, served by /api/agui/board) joined to the
// fleet rows by worker label, the drawer's keyboard reducer and the deep-link fragment. Dependency-free, like fleet-model.
import { fleetSections, type Filters, type Row } from "./fleet-model";

export const STAGES = ["dispatch", "live", "pr", "ready", "go", "merged"] as const;
export type Stage = (typeof STAGES)[number];
export const BOARD_URL = (console: string) => `/api/agui/board?console=${encodeURIComponent(console)}`;
export const BRIEF_URL = (worker: string) => `/api/agui/brief?leg=${encodeURIComponent(worker)}`;

export type Legend = Record<string, Record<string, { color: string; label: string }>>;
export type TimelineBullet = { at: string | null; stage: string; marker: string; text: string };
export type BoardWorker = {
  worker: string; ticket: string; goal: string; state: string; stage: Stage; stages: Record<Stage, string | null>;
  pr: { number: number; url: string | null } | null; links: { ticket: string | null; brief: string | null }; timeline: TimelineBullet[];
};
export type Need = { worker: string; verb: string; action: string; detail: string; command: string | null; since: string | null };
export type Succession = {
  tool: string; from: string; to: string; started: string | null; live_at: string | null; wall_min: number | null; turns: number; eq: number;
  legs_quoted: number; legs_silent: number; target: { eq: number; turns: number }; pass: boolean; recommendation: string;
};
export type Board = {
  schema: "himmel.board/1"; generated_at: string; console: { name: string };
  headline: { live: number; cap: number | null; merged_today: number; needs_you: number; blocked: number };
  bank: { week_pct: number | null; five_hour_pct: number | null };
  ci: { open: number; green: number; pending: number; no_checks: number; red: number };
  milestones: { version: string; unavailable?: boolean; done?: number; total?: number; open_blockers?: string[] }[];
  needs_you: Need[]; workers: BoardWorker[];
  trends: {
    worker_time: { unit: string; today: { worker: string; live_at: string | null; merged_at: string | null; live_to_merged_min: number | null; to_pr_min: number | null; ready_to_merged_min: number | null }[] };
    cost: { total: number; [k: string]: unknown } | null;
    console_cost: { unit: string; since: string; messages: number; eq: number; per_hour: number; hourly: { hour: string; eq: number }[]; fleet_eq: number | null } | null;
    exploration: { over_flag?: number; [k: string]: unknown } | null;
    failures: { classes: { class: string; sessions: number; route: string }[]; [k: string]: unknown } | null;
    tools: Succession[];
  };
  legend: Legend; cards: Record<"velocity" | "health" | "tools" | "roadmap", { recommendation: string }>;
};

// The one reader of board.mjs's old wire keys, which it emits until its writer flips. The browser has no
// HIMMEL_LEGACY_NAMES switch, so the fallback is always on. The removal of the legacy names deletes the marked lines.
export function normalizeBoard(raw: any): Board {
  const { legs: oldWorkers, ...rest } = raw; // legacy wire fallback
  const workerOf = ({ leg: oldName, ...r }: any) => ({ ...r, worker: r.worker ?? oldName }); // legacy wire fallback
  const { leg_time: oldTime, ...trends } = raw.trends; // legacy wire fallback
  const time = trends.worker_time ?? oldTime;
  return {
    ...rest,
    workers: (rest.workers ?? oldWorkers).map(workerOf),
    needs_you: raw.needs_you.map(workerOf),
    trends: { ...trends, worker_time: { ...time, today: time.today.map(workerOf) } },
  };
}

export type Joined ={ worker: BoardWorker; row: Row | null; need: Need | null };
// A board card per board worker: its fleet row (null when the census has no live session for it) and what it needs.
export function joinBoard(rows: Row[], board: Board): Joined[] {
  // the board labels a worker by its number (N2339); a fleet row is its doc stem, whose -N2339[b]- names the same worker.
  const label = (name: string) => /-(N\d+)[a-z]?-/.exec(name)?.[1] ?? name;
  const byLabel = new Map<string, Row>();
  // a live hop beats a finished one; of several live hops the newest start wins, whatever the input order.
  const start = (r: Row) => r.runtime?.startedAt ?? 0;
  for (const r of rows) {
    const cur = byLabel.get(label(r.name));
    if (!cur || (r.live !== false && (cur.live === false || start(r) >= start(cur)))) byLabel.set(label(r.name), r);
  }
  const need = new Map(board.needs_you.map((n) => [n.worker, n]));
  return board.workers.map((worker) => ({ worker, row: byLabel.get(worker.worker) ?? null, need: need.get(worker.worker) ?? null }));
}

// The needs-you cards the rail's filters leave: a worker shows when its fleet row is on the page (a worker with no row
// hides once any filter is on, as it cannot match one).
export function needsShown(joined: Joined[], rows: Row[], filters: Filters): Joined[] {
  const needing = joined.filter((j) => j.need);
  if (!filters.lanes.length && !filters.states.length && !filters.text.trim()) return needing;
  const s = fleetSections(rows, null, filters);
  const on = new Set([...s.running.flatMap((g) => [...(g.showConsole && g.console ? [g.console] : []), ...g.rows]), ...[...s.attention.operator, ...s.attention.chief].map((a) => a.row), ...s.orphans.map((a) => a.row)].map((r) => r.name));
  return needing.filter((j) => j.row && on.has(j.row.name));
}

// The Brief panel's text and error: a new request starts from neither, so a changed token or row never shows the last one's.
export type BriefState = { text: string | null; err: string | null };
export const BRIEF_IDLE: BriefState = { text: null, err: null };
export function briefNext(s: BriefState, a: { kind: "start" } | { kind: "text"; text: string } | { kind: "error"; err: string }): BriefState {
  return a.kind === "start" ? BRIEF_IDLE : a.kind === "text" ? { ...s, text: a.text } : { ...s, err: a.err };
}

const ms = (iso: string | null) => (iso ? Date.parse(iso) : NaN);
// one band per stage reached, each ending where the next reached stage starts; the last runs to `now` (or its merge).
export function stageSegments(l: BoardWorker, now: number): { stage: Stage; from: number; to: number }[] {
  const reached = STAGES.filter((s) => Number.isFinite(ms(l.stages[s]))).map((s) => ({ stage: s, from: ms(l.stages[s]) }));
  return reached.map((r, i) => ({ ...r, to: i + 1 < reached.length ? reached[i + 1].from : r.stage === "merged" ? r.from : Math.max(r.from, now) }));
}

// The drawer: where it is, and the places it left (its own history, so Back stays inside the panel).
export type Drawer = { worker: string; stage: Stage; back: { worker: string; stage: Stage }[] };
export const openAt = (from: Drawer | null, worker: string, stage: Stage): Drawer =>
  from && (from.worker !== worker || from.stage !== stage) ? { worker, stage, back: [...from.back, { worker: from.worker, stage: from.stage }].slice(-20) } : from ?? { worker, stage, back: [] };

// left/right move between stages, up/down between workers (the order the page lists them), Esc closes (null), Backspace goes back.
export function applyKey(d: Drawer, key: string, workers: string[]): Drawer | null {
  if (key === "Escape") return null;
  if (key === "Backspace") {
    const p = d.back[d.back.length - 1];
    return p ? { worker: p.worker, stage: p.stage, back: d.back.slice(0, -1) } : d;
  }
  const si = STAGES.indexOf(d.stage), li = workers.indexOf(d.worker);
  const to = key === "ArrowRight" ? { worker: d.worker, stage: STAGES[Math.min(STAGES.length - 1, si + 1)] }
    : key === "ArrowLeft" ? { worker: d.worker, stage: STAGES[Math.max(0, si - 1)] }
      : key === "ArrowDown" && li >= 0 ? { worker: workers[Math.min(workers.length - 1, li + 1)], stage: d.stage }
        : key === "ArrowUp" && li >= 0 ? { worker: workers[Math.max(0, li - 1)], stage: d.stage } : null;
  return to ? openAt(d, to.worker, to.stage) : d;
}

// #t=<token>&console=<doc>&tab=trends&k=s.<worker>.<stage>; a worker label holds no dot, so the stage is after the last one.
export function viewHash(token: string, console: string | null, tab: "fleet" | "trends", k: { worker: string; stage: Stage } | null): string {
  const p = new URLSearchParams({ t: token });
  if (console) p.set("console", console);
  if (tab === "trends") p.set("tab", "trends");
  if (k) p.set("k", `s.${k.worker}.${k.stage}`);
  return `#${p}`;
}
export function parseView(hash: string): { tab: "fleet" | "trends"; k: { worker: string; stage: Stage } | null } {
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  const m = /^s\.(.+)\.([a-z]+)$/.exec(p.get("k") ?? "");
  const stage = m && (STAGES as readonly string[]).includes(m[2]) ? (m[2] as Stage) : null;
  return { tab: p.get("tab") === "trends" ? "trends" : "fleet", k: m && stage ? { worker: m[1], stage } : null };
}

// GET /api/rollup: the weekly roll-up as three cards (scripts/config-ui/rollup.ts); deltas and sentence are the server's.
export const ROLLUP_URL = "/api/rollup";
export type RollupCompared = { key: string; value: number; delta: number | null; partial: boolean };
export type RollupCard = {
  id: "velocity" | "cost" | "health"; title: string; metric: string; unit: string; state: "ok" | "nodata";
  spark: { key: string; value: number }[]; week: RollupCompared | null; version: RollupCompared | null; sentence: string;
};
export type Rollup = { state: "ok"; cards: RollupCard[] } | { state: "absent"; reason: string };
