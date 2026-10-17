// The console board on the Fleet page: himmel.board/1 (board.mjs --json, served by /api/agui/board) joined to the
// fleet rows by leg label, the drawer's keyboard reducer and the deep-link fragment. Dependency-free, like fleet-model.
import { fleetSections, type Filters, type Row } from "./fleet-model";

export const STAGES = ["dispatch", "live", "pr", "ready", "go", "merged"] as const;
export type Stage = (typeof STAGES)[number];
export const BOARD_URL = (console: string) => `/api/agui/board?console=${encodeURIComponent(console)}`;
export const BRIEF_URL = (leg: string) => `/api/agui/brief?leg=${encodeURIComponent(leg)}`;

export type Legend = Record<string, Record<string, { color: string; label: string }>>;
export type TimelineBullet = { at: string | null; stage: string; marker: string; text: string };
export type BoardLeg = {
  leg: string; ticket: string; goal: string; state: string; stage: Stage; stages: Record<Stage, string | null>;
  pr: { number: number; url: string | null } | null; links: { ticket: string | null; brief: string | null }; timeline: TimelineBullet[];
};
export type Need = { leg: string; verb: string; action: string; detail: string; command: string | null; since: string | null };
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
  needs_you: Need[]; legs: BoardLeg[];
  trends: {
    leg_time: { unit: string; today: { leg: string; live_at: string | null; merged_at: string | null; live_to_merged_min: number | null; to_pr_min: number | null; ready_to_merged_min: number | null }[] };
    cost: { total: number; [k: string]: unknown } | null;
    console_cost: { unit: string; since: string; messages: number; eq: number; per_hour: number; hourly: { hour: string; eq: number }[]; fleet_eq: number | null } | null;
    exploration: { over_flag?: number; [k: string]: unknown } | null;
    failures: { classes: { class: string; sessions: number; route: string }[]; [k: string]: unknown } | null;
    tools: Succession[];
  };
  legend: Legend; cards: Record<"velocity" | "health" | "tools" | "roadmap", { recommendation: string }>;
};

export type Joined = { leg: BoardLeg; row: Row | null; need: Need | null };
// A board card per board leg: its fleet row (null when the census has no live session for it) and what it needs.
export function joinBoard(rows: Row[], board: Board): Joined[] {
  // the board labels a leg by its number (N2339); a fleet row is its doc stem, whose -N2339[b]- names the same leg.
  const label = (name: string) => /-(N\d+)[a-z]?-/.exec(name)?.[1] ?? name;
  const byLabel = new Map<string, Row>();
  // a live hop beats a finished one; of several live hops the newest start wins, whatever the input order.
  const start = (r: Row) => r.runtime?.startedAt ?? 0;
  for (const r of rows) {
    const cur = byLabel.get(label(r.name));
    if (!cur || (r.live !== false && (cur.live === false || start(r) >= start(cur)))) byLabel.set(label(r.name), r);
  }
  const need = new Map(board.needs_you.map((n) => [n.leg, n]));
  return board.legs.map((leg) => ({ leg, row: byLabel.get(leg.leg) ?? null, need: need.get(leg.leg) ?? null }));
}

// The needs-you cards the rail's filters leave: a leg shows when its fleet row is on the page (a leg with no row
// hides once any filter is on, as it cannot match one).
export function needsShown(joined: Joined[], rows: Row[], filters: Filters): Joined[] {
  const needing = joined.filter((j) => j.need);
  if (!filters.lanes.length && !filters.states.length && !filters.text.trim()) return needing;
  const s = fleetSections(rows, null, filters);
  const on = new Set([...s.running.flatMap((g) => [...(g.showConsole && g.console ? [g.console] : []), ...g.rows]), ...s.attention.map((a) => a.row), ...s.orphans.map((a) => a.row)].map((r) => r.name));
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
export function stageSegments(l: BoardLeg, now: number): { stage: Stage; from: number; to: number }[] {
  const reached = STAGES.filter((s) => Number.isFinite(ms(l.stages[s]))).map((s) => ({ stage: s, from: ms(l.stages[s]) }));
  return reached.map((r, i) => ({ ...r, to: i + 1 < reached.length ? reached[i + 1].from : r.stage === "merged" ? r.from : Math.max(r.from, now) }));
}

// The drawer: where it is, and the places it left (its own history, so Back stays inside the panel).
export type Drawer = { leg: string; stage: Stage; back: { leg: string; stage: Stage }[] };
export const openAt = (from: Drawer | null, leg: string, stage: Stage): Drawer =>
  from && (from.leg !== leg || from.stage !== stage) ? { leg, stage, back: [...from.back, { leg: from.leg, stage: from.stage }].slice(-20) } : from ?? { leg, stage, back: [] };

// left/right move between stages, up/down between legs (the order the page lists them), Esc closes (null), Backspace goes back.
export function applyKey(d: Drawer, key: string, legs: string[]): Drawer | null {
  if (key === "Escape") return null;
  if (key === "Backspace") {
    const p = d.back[d.back.length - 1];
    return p ? { leg: p.leg, stage: p.stage, back: d.back.slice(0, -1) } : d;
  }
  const si = STAGES.indexOf(d.stage), li = legs.indexOf(d.leg);
  const to = key === "ArrowRight" ? { leg: d.leg, stage: STAGES[Math.min(STAGES.length - 1, si + 1)] }
    : key === "ArrowLeft" ? { leg: d.leg, stage: STAGES[Math.max(0, si - 1)] }
      : key === "ArrowDown" && li >= 0 ? { leg: legs[Math.min(legs.length - 1, li + 1)], stage: d.stage }
        : key === "ArrowUp" && li >= 0 ? { leg: legs[Math.max(0, li - 1)], stage: d.stage } : null;
  return to ? openAt(d, to.leg, to.stage) : d;
}

// #t=<token>&console=<doc>&tab=trends&k=s.<leg>.<stage>; a leg label holds no dot, so the stage is after the last one.
export function viewHash(token: string, console: string | null, tab: "fleet" | "trends", k: { leg: string; stage: Stage } | null): string {
  const p = new URLSearchParams({ t: token });
  if (console) p.set("console", console);
  if (tab === "trends") p.set("tab", "trends");
  if (k) p.set("k", `s.${k.leg}.${k.stage}`);
  return `#${p}`;
}
export function parseView(hash: string): { tab: "fleet" | "trends"; k: { leg: string; stage: Stage } | null } {
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  const m = /^s\.(.+)\.([a-z]+)$/.exec(p.get("k") ?? "");
  const stage = m && (STAGES as readonly string[]).includes(m[2]) ? (m[2] as Stage) : null;
  return { tab: p.get("tab") === "trends" ? "trends" : "fleet", k: m && stage ? { leg: m[1], stage } : null };
}
