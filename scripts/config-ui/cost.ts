// cost.ts — the Cost page's data: the phase-cost rows usage-compute.sh keeps (docs/internals/usage-records.md), read through
// usage-read.sh --phase-cost, turned into one model: the day's dollars, and each phase of the work with the parts it is made of.
// Nothing is computed in the browser and nothing is written. Every figure carries how it was got: counted (a ledger or the
// session's own usage), derived (a counted total split by the last-tool rule), unpriced (a call's model has no price row).
// A part no record splits is "nocount": it has no number of its own, or it holds the whole phase as the one figure the records keep.
// ponytail: a synchronous spawn of usage-read.sh per read, one day at a time, no week window; behind GET /api/cost a read that waits
// on the usage store lock (usage-read.sh waits up to 60 s) holds the whole server for that long;
// upgrade path: an async read behind the route, and a week table once the records carry parts per phase for it.
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
export type PhaseCostRow = {
  kind: "phase-cost"; day: string; session: string; parent: string | null; lane: string; class: string; model: string;
  phase: string; phase_rule: string; calls: number; in: number; out: number; cache_read: number; cc_5m: number; cc_1h: number;
  usd: number | null; mark: string;
};
export type Mark = "counted" | "derived" | "unpriced" | "nocount";
export type CostPart = { id: string; name: string; note: string; usd: number | null; share: number | null; mark: Mark };
export type CostPhase = { id: string; name: string; usd: number | null; share: number | null; mark: Mark; made: string; parts: CostPart[] };
export type CostModel = {
  state: "ok" | "nodata" | "nostore"; day: string | null; days: string[]; usd: number | null; mark: Mark; calls: number;
  models: { model: string; usd: number | null }[]; phases: CostPhase[];
};

const READ = join(import.meta.dir, "..", "usage", "usage-read.sh");
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

// a ticket key (and what trails it in the same word) never reaches the page; "claude-opus-5-5" is not one
const KEY_RE = /\[?\b[A-Z][A-Z0-9]*-\d+\b[^\s,\]]*\]?/g;
const plain = (s: string) => s.replace(KEY_RE, "").replace(/\s+/g, " ").trim();
const modelLabel = (m: string) => m.split(",").map(plain).filter(Boolean).join(", ") || "unknown model";

// The latest row per (day, session, phase), as usage-read.sh keeps them, less a row the writer closed with zero calls.
export function readPhaseCostRows(env: Env, day?: string): PhaseCostRow[] {
  let out: string;
  try {
    out = execFileSync("bash", [READ, "--phase-cost", ...(day ? ["--day", day] : [])], {
      env: { PATH: env.PATH, HOME: env.HOME, HIMMEL_USAGE_STORE: env.HIMMEL_USAGE_STORE },
      encoding: "utf8", timeout: 65_000, maxBuffer: 256 * 1024 * 1024, stdio: ["ignore", "pipe", "ignore"],
    });
  } catch { return []; } // no store yet, or a store held past the reader's own wait: the page says "no data yet"
  const rows: PhaseCostRow[] = [];
  for (const line of out.split("\n")) {
    let r;
    try { r = JSON.parse(line); } catch { continue; }
    if (r?.kind === "phase-cost" && typeof r.day === "string" && DAY_RE.test(r.day) && typeof r.phase === "string" && Number.isFinite(r.calls) && r.calls > 0)
      rows.push(r as PhaseCostRow);
  }
  return rows;
}

type PartDef = { id: string; name: string; note: string; of?: (r: PhaseCostRow) => boolean; whole?: boolean };
type GroupDef = { id: string; name: string; phases: string[]; says: string; parts: PartDef[] };
const phaseIs = (p: string) => (r: PhaseCostRow) => r.phase === p;
// A part with `of` is counted from the rows; one without says "not countable yet" (`whole`: it holds the phase's one figure).
const GROUPS: GroupDef[] = [
  { id: "build", name: "PR build", phases: ["build", "agent", "compaction", "retrieval", "boot"], says: "reading, editing and everything between", parts: [
    { id: "build-edit", name: "reading and editing", note: "Read, Edit, Write and every other command", of: phaseIs("build") },
    { id: "build-agent", name: "worker subagents", note: "subagents a worker spawns, with their own calls", of: phaseIs("agent") },
    { id: "build-compaction", name: "compaction", note: "calls after a compaction, up to the next tool", of: phaseIs("compaction") },
    { id: "build-retrieval", name: "retrieval", note: "notes search and the code graph", of: phaseIs("retrieval") },
    { id: "build-boot", name: "boot", note: "calls before the first tool", of: phaseIs("boot") }] },
  { id: "chief", name: "Chief turns", phases: ["chief-turns"], says: "chief sessions and the helpers they spawn", parts: [
    { id: "chief-sessions", name: "chief sessions", note: "a chief's own turns", of: (r) => r.class === "chief" },
    { id: "brief-drafting", name: "brief drafting", note: "brief-drafter subagents", of: (r) => r.class === "brief-drafter" },
    { id: "chief-helpers", name: "chief helpers", note: "other subagents a chief spawns", of: (r) => r.class !== "chief" && r.class !== "brief-drafter" },
    { id: "chief-steps", name: "chief sessions by step", note: "a chief session is one phase in the records; none splits it by step" }] },
  { id: "judge", name: "Judges", phases: ["judge"], says: "judge runs", parts: [
    { id: "judge-pr", name: "per PR", note: "judge runs do not record their PR", whole: true }] },
  { id: "review", name: "Review steps", phases: ["review"], says: "pr-check, verdicts, ready-check, thread resolve", parts: [
    { id: "review-step", name: "per step: pr-check, verdicts, ready-check, thread resolve", note: "one figure for all review steps; none is recorded apiece", whole: true }] },
  { id: "tests", name: "Tests", phases: ["tests"], says: "impacted suites, quiet-run", parts: [
    { id: "tests-run", name: "per suite run", note: "suite runs log seconds by head, not dollars", whole: true }] },
  { id: "relmgr", name: "Release manager", phases: ["release-mgr"], says: "headless release manager runs", parts: [
    { id: "relmgr-run", name: "release judges and the manager's own turns", note: "release judge launches and the runs are not reconciled", whole: true }] },
  { id: "comms", name: "Comms and handover", phases: ["comms"], says: "results bullets, messages, locks", parts: [
    { id: "comms-step", name: "per step: results bullets, messages, locks", note: "one figure for all comms steps", whole: true }] },
  { id: "critic", name: "Critic", phases: ["critic"], says: "critic runs", parts: [
    { id: "critic-pr", name: "per PR", note: "critic runs do not record their PR", whole: true }] },
  { id: "ship", name: "Ship", phases: ["ship"], says: "commit, push, PR open, merge", parts: [
    { id: "ship-step", name: "per step: commit, push, PR open, merge", note: "one figure for all ship steps", whole: true }] },
  { id: "tickets", name: "Tickets", phases: ["ticket-filing", "ticket-read"], says: "filing and reading tickets", parts: [
    { id: "tickets-filing", name: "filing", note: "workers and others; the chief's own are in Chief turns", of: phaseIs("ticket-filing") },
    { id: "tickets-reads", name: "reads", note: "workers and others; the chief's own are in Chief turns", of: phaseIs("ticket-read") }] },
  { id: "ci", name: "CI", phases: ["ci"], says: "check-ci waits and triage", parts: [
    { id: "ci-step", name: "waits and triage apart", note: "one figure for check-ci waits and triage", whole: true }] },
  { id: "skills", name: "Skill and tool calls", phases: ["tool-load", "skill"], says: "tool search and skills", parts: [
    { id: "skills-tool", name: "tool search", note: "calls after a tool search", of: phaseIs("tool-load") },
    { id: "skills-skill", name: "skills", note: "calls after a skill runs", of: phaseIs("skill") }] },
  { id: "vm", name: "VM", phases: ["vm"], says: "test VM steps", parts: [
    { id: "vm-run", name: "per VM run", note: "no record splits it by VM run", whole: true }] },
  { id: "other", name: "Other", phases: [], says: "phases the page does not know", parts: [
    { id: "other-phases", name: "other phases", note: "a phase this page has no row for", of: () => true },
    { id: "other-probes", name: "graph probes and bots", note: "their sessions are not told apart from other sessions yet" }] },
];

const round = (n: number, dp: number) => Math.round(n * 10 ** dp) / 10 ** dp;
const sum = (rows: PhaseCostRow[]) => (rows.every((r) => r.usd == null) ? null : round(rows.reduce((a, r) => a + (r.usd ?? 0), 0), 4));
const pct = (part: number | null, whole: number | null) => (part == null || !whole ? null : round((part / whole) * 100, 1));
// unpriced wins over derived, derived over counted: a figure is only as sure as its least sure row
const markOf = (rows: PhaseCostRow[]): Mark => (rows.some((r) => r.mark === "unpriced") ? "unpriced" : rows.some((r) => r.mark === "derived") ? "derived" : "counted");
const money = (n: number) => n.toFixed(1);

export function buildCostModel(all: PhaseCostRow[], day?: string): CostModel {
  const days = [...new Set(all.filter((r) => DAY_RE.test(r.day)).map((r) => r.day))].sort().reverse();
  // a day asked for that has no rows is that day with no data, never another day's costs
  if (day && !days.includes(day)) return { state: "nodata", day, days, usd: null, mark: "nocount", calls: 0, models: [], phases: [] };
  const picked = day ?? days[0];
  if (!picked) return { state: "nodata", day: null, days: [], usd: null, mark: "nocount", calls: 0, models: [], phases: [] };
  const rows = all.filter((r) => r.day === picked && r.calls > 0);

  const known = new Set(GROUPS.flatMap((g) => g.phases));
  const inGroup = (g: GroupDef, r: PhaseCostRow) => (g.id === "other" ? !known.has(r.phase) : g.phases.includes(r.phase));
  const total = sum(rows);

  const phases = GROUPS.flatMap((g, order) => {
    const mine = rows.filter((r) => inGroup(g, r));
    if (!mine.length) return [];
    const usd = sum(mine);
    const parts: CostPart[] = g.parts.flatMap((d): CostPart[] => {
      if (!d.of) return [{ id: d.id, name: d.name, note: d.note, usd: d.whole ? usd : null, share: d.whole ? pct(usd, usd) : null, mark: "nocount" }];
      const own = mine.filter(d.of);
      if (!own.length) return [];
      const u = sum(own);
      return [{ id: d.id, name: d.name, note: d.note, usd: u, share: pct(u, usd), mark: markOf(own) }];
    });
    // biggest first; a part with no number of its own goes last
    parts.sort((a, b) => (b.usd ?? -1) - (a.usd ?? -1));
    const made = parts.filter((p) => p.mark !== "nocount" && p.usd).map((p) => `${p.name} ${money(p.usd!)}`).join(" · ") || g.says;
    return [{ order, phase: { id: g.id, name: g.name, usd, share: pct(usd, total), mark: markOf(mine), made, parts } as CostPhase }];
  }).sort((a, b) => (b.phase.usd ?? -1) - (a.phase.usd ?? -1) || a.order - b.order).map((x) => x.phase);

  const byModel = new Map<string, PhaseCostRow[]>();
  for (const r of rows) { const k = modelLabel(r.model); byModel.set(k, [...(byModel.get(k) ?? []), r]); }
  const models = [...byModel].map(([model, rs]) => ({ model, usd: sum(rs) })).sort((a, b) => (b.usd ?? -1) - (a.usd ?? -1));
  // the total is counted from the calls' own usage, so it is counted unless some call has no price (then it covers only the priced ones)
  return { state: "ok", day: picked, days, usd: total, mark: rows.some((r) => r.mark === "unpriced") ? "unpriced" : "counted", calls: rows.reduce((a, r) => a + r.calls, 0), models, phases };
}

const storeFile = (env: Env) => join(env.HIMMEL_USAGE_STORE || join(env.HOME ?? "", ".himmel", "state", "usage"), "records.jsonl");

export const readCost = (env: Env, day?: string): CostModel =>
  existsSync(storeFile(env))
    ? buildCostModel(readPhaseCostRows(env), day)
    : { state: "nostore", day: day ?? null, days: [], usd: null, mark: "nocount", calls: 0, models: [], phases: [] };
