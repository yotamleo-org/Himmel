// shift.ts — the shift helper: the one place that decides when a fleet shift opens and closes, writes
// shifts.jsonl, and works out each chief's span and the PRs credited to it. The Shift page and the Morning
// report both read what it writes and never append themselves.
//
// Contract:
//  - opened and closed are ISO-8601 with a zone offset, to the minute; the zone is fixed when the shift opens.
//  - windows are half-open, [opened, closed): a PR merged at the close minute belongs to the next shift. An open shift uses now.
//  - one writer under a lock (lock.ts's link(2) lock beside the file); appends are idempotent on id.
//  - fleet-wide: a queue lock in any bucket (roadmap, voice) keeps the shift open, and a chief in any bucket opens it.
//  - the close time is the last lock release, declared once idleMin minutes pass with nothing held, never idleMin later.
//  - one span function: first LIVE to last WRAPPED/HALTED; a doc with no LIVE starts at its predecessor's end, marked approx.
//
// ponytail: the last lock release is derived from the last poll that saw a lock held and the newest WRAPPED/HALTED stamp (queue-lock.sh keeps no release record, and a stale-dead lock reads as held until swept), upgrade to a release record read from queue-lock.sh, HIMMEL-8391
import { appendFileSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, sep } from "node:path";
import { execFile } from "node:child_process";
import { findDoc, readBoardFile } from "./agui/board";
import { acquireLock } from "./lock";

export type Opts = { idleMin: number; cuts: string[]; minHours: number };
// the three numbers live on Configure (the Morning report build); these are the mockup's defaults
export const DEFAULTS: Opts = { idleMin: 60, cuts: ["08:00", "20:00"], minHours: 4 };

export type Lock = { bucket: string; role: "chief" | "worker"; doc: string; at: number };
export type Obs = { now: number; locks: Lock[]; lastEnd: number | null; chiefLiveAt: number | null };
export type Open = { opened: number; lastHeld: number; buckets: string[]; offsetMin: number };
export type State = { open: Open | null; closedAt: number | null; at?: number }; // at: the time of the poll last applied
export type Span = { name: string; bucket: string; start: number; end: number | null; approx: boolean };
export type Gap = { pr: number; chiefs: [string, string] };
export type Chief = { name: string; bucket: string; span: { start: string; end: string | null; approx: boolean }; prs: number[] };
export type Row = { id: string; name: "day" | "night"; opened: string; closed: string; why: "idle" | "cut"; zone: string; chiefs: Chief[]; buckets: string[]; gap: Gap[]; carried?: Carried[]; shipped?: number };
export type Pr = { number: number; mergedAt: string; [k: string]: unknown };

const MIN = 60_000, DAY = 86_400_000;
const p2 = (n: number) => String(n).padStart(2, "0");

export const zoneOf = (offMin: number) => `${offMin < 0 ? "-" : "+"}${p2(Math.floor(Math.abs(offMin) / 60))}:${p2(Math.abs(offMin) % 60)}`;
// ISO-8601 with offset, to the minute: 2026-10-27T20:00+01:00
export function iso(ms: number, offMin: number): string {
  const d = new Date(Math.floor(ms / MIN) * MIN + offMin * MIN);
  return `${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-${p2(d.getUTCDate())}T${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())}${zoneOf(offMin)}`;
}
const hm = (s: string) => { const [h, m] = s.split(":").map(Number); return h * 60 + m; };
const dayMinute = (ms: number, offMin: number) => (((Math.floor(ms / MIN) + offMin) % 1440) + 1440) % 1440;

// day between the first and second cut time (08:00 to 20:00), otherwise night, whether it opened at a cut or after idle
export function nameOf(opened: number, offMin: number, o: Opts): "day" | "night" {
  const m = dayMinute(opened, offMin);
  return m >= hm(o.cuts[0]) && m < hm(o.cuts[1]) ? "day" : "night";
}

// the first cut time at or after opened + minHours
// ponytail: the zone offset is fixed when a shift opens, so a shift that spans a clock change cuts an hour off local 08:00 or 20:00, upgrade to the offset in force at each cut when a shift is seen to straddle one
export function nextCut(opened: number, offMin: number, o: Opts): number {
  const from = opened + o.minHours * 60 * MIN;
  const dayStart = Math.floor((from + offMin * MIN) / DAY) * DAY - offMin * MIN; // local midnight at or before `from`
  const cuts = o.cuts.map((c) => hm(c) * MIN).sort((a, b) => a - b);
  for (let d = 0; d < 3; d++) for (const c of cuts) if (dayStart + d * DAY + c >= from) return dayStart + d * DAY + c;
  return from;
}

const rowOf = (open: Open, closed: number, why: "idle" | "cut", o: Opts): Row => ({
  id: iso(open.opened, open.offsetMin), name: nameOf(open.opened, open.offsetMin, o), opened: iso(open.opened, open.offsetMin),
  closed: iso(closed, open.offsetMin), why, zone: zoneOf(open.offsetMin), chiefs: [], buckets: [...open.buckets].sort(), gap: [],
});

// One transition of the cut rule. Pure: the caller loops it while it reports a close.
export function step(st: State, obs: Obs, o: Opts, offMin: number): { state: State; closed?: Row } {
  const { now } = obs;
  const held = obs.locks.length > 0;
  const seen = obs.locks.map((l) => l.bucket);
  let open = st.open;
  if (!open) {
    if (obs.chiefLiveAt === null) return { state: st };
    const opened = Math.max(obs.chiefLiveAt, st.closedAt ?? 0);
    open = { opened, lastHeld: held ? now : opened, buckets: [], offsetMin: offMin };
  }
  const buckets = [...new Set([...open.buckets, ...seen])];
  // the last release: now while anything is held, else the newest evidence that something was
  const lastHeld = held ? now : Math.max(open.lastHeld, Math.min(obs.lastEnd ?? 0, now));
  open = { ...open, buckets, lastHeld };
  const idleMs = o.idleMin * MIN;
  const cutAt = nextCut(open.opened, open.offsetMin, o);
  const idleDue = !held && now - lastHeld >= idleMs;
  if (idleDue && (now < cutAt || lastHeld + idleMs <= cutAt)) return { state: { open: null, closedAt: lastHeld }, closed: rowOf(open, lastHeld, "idle", o) };
  // a cut hands over to a successor only when something is held: an idle fleet's last release is before the cut, so a successor would close before it opened
  if (now >= cutAt) return { state: held ? { open: { ...open, opened: cutAt, offsetMin: offMin }, closedAt: st.closedAt } : { open: null, closedAt: cutAt }, closed: rowOf(open, cutAt, "cut", o) };
  return { state: { open, closedAt: st.closedAt } };
}

// the PRs merged in [opened, closed); an open shift (closed null) runs to now
export function mergedIn<T extends Pr>(prs: T[], opened: number, closed: number | null, now: number): T[] {
  return prs.filter((p) => { const t = Date.parse(p.mergedAt); return t >= opened && (closed === null ? t <= now : t < closed); });
}

// ---- the span-and-attribution function ----
type Doc = { name: string; bucket: string; text: string };
const PRED = /successor to `?([^\s`]+?)(?:\.md)?`?[\s(]/;

// Stamps are HH:MM local with no date: the date comes from the doc name and the day rolls over when a stamp is earlier than the one before.
// `held` names the chief docs that hold a queue lock now: a doc outside it that never wrapped ended at its last stamp, never "now".
export function chiefSpans(docs: Doc[], offMin: number, held?: Set<string>): Span[] {
  const stamped = docs.flatMap((d) => {
    const date = /(\d{4})-(\d{2})-(\d{2})/.exec(d.name);
    if (!date) return [];
    const base = Date.UTC(Number(date[1]), Number(date[2]) - 1, Number(date[3])) - offMin * MIN;
    let add = 0, prev = -1;
    const marks: { at: number; mark: string }[] = [];
    for (const m of d.text.matchAll(/^- (\d{2}):(\d{2}) (\S+)/gm)) {
      const mins = Number(m[1]) * 60 + Number(m[2]);
      if (mins < prev) add++;
      prev = mins;
      marks.push({ at: base + add * DAY + mins * MIN, mark: m[3].replace(/[^A-Za-z-]/g, "") });
    }
    return [{ d, marks, pred: PRED.exec(d.text)?.[1] ?? null }];
  });
  const ends = new Map<string, number | null>();
  for (const s of stamped) ends.set(s.d.name, s.marks.filter((m) => m.mark === "WRAPPED" || m.mark === "HALTED").at(-1)?.at ?? (held && !held.has(s.d.name) ? s.marks.at(-1)?.at ?? null : null));
  const out: Span[] = [];
  for (const s of stamped) {
    const live = s.marks.find((m) => m.mark === "LIVE")?.at;
    const predEnd = s.pred ? ends.get(s.pred) ?? null : null;
    const start = live ?? predEnd ?? s.marks[0]?.at;
    if (start === undefined) continue;
    out.push({ name: s.d.name, bucket: s.d.bucket, start, end: ends.get(s.d.name) ?? null, approx: live === undefined });
  }
  return out.sort((a, b) => a.start - b.start);
}

// A PR counts under the chief whose span holds its merge time. A merge in a hand-over gap is named for both chiefs, and counted once in the total.
// A WRAPPED stamp is to the minute, so a span holds the whole minute of its end.
export function attribute(spans: Span[], prs: Pr[], now: number): { perChief: Record<string, number[]>; gap: Gap[]; total: number } {
  const perChief: Record<string, number[]> = Object.fromEntries(spans.map((s) => [s.name, [] as number[]]));
  const gap: Gap[] = [];
  const bucketOf = new Map(spans.map((s) => [s.name, s.bucket]));
  for (const p of prs) {
    const t = Date.parse(p.mergedAt);
    const holders = spans.filter((s) => t >= s.start && t < (s.end ?? now) + MIN);
    if (holders.length) { for (const h of holders) perChief[h.name].push(p.number); continue; }
    // gap: after one chief's end and before the next chief's start in the same bucket
    for (const b of new Set(bucketOf.values())) {
      const inB = spans.filter((s) => s.bucket === b);
      for (let i = 0; i + 1 < inB.length; i++) {
        const [a, c] = [inB[i], inB[i + 1]];
        if (a.end !== null && t >= a.end + MIN && t < c.start) { perChief[a.name].push(p.number); perChief[c.name].push(p.number); gap.push({ pr: p.number, chiefs: [a.name, c.name] }); }
      }
    }
  }
  return { perChief, gap, total: prs.length };
}

// the chiefs of a closed (or running) shift as stored in its row: each span clipped to the shift, with the PRs credited to it
export function chiefsOf(spans: Span[], prs: Pr[], opened: number, closed: number | null, now: number, offMin: number): { chiefs: Chief[]; gap: Gap[]; shipped: number } {
  const end = closed ?? now;
  const inShift = spans.filter((s) => s.start < end && (s.end === null || s.end + MIN > opened));
  const a = attribute(inShift, mergedIn(prs, opened, closed, now), now);
  return {
    chiefs: inShift.map((s) => ({
      name: s.name, bucket: s.bucket, prs: a.perChief[s.name],
      span: { start: iso(Math.max(s.start, opened), offMin), end: s.end === null || (closed !== null && s.end >= closed) ? null : iso(s.end, offMin), approx: s.approx },
    })),
    gap: a.gap,
    shipped: a.total,
  };
}

// ---- locks and chief docs of every bucket ----
// <root>/.locks/queue/<slug>.lock/owner.json, one per held queue. The bucket is the doc's folder under <root>/<user>/.
export function readLocks(root: string): Lock[] {
  const dir = join(root, ".locks", "queue");
  let names: string[];
  try { names = readdirSync(dir).filter((n) => n.endsWith(".lock")); } catch { return []; }
  const out: Lock[] = [];
  for (const n of names) {
    try {
      const o = JSON.parse(readFileSync(join(dir, n, "owner.json"), "utf8"));
      const doc = String(o.handover ?? "");
      const parts = relative(root, doc).split(sep);
      const bucket = parts.length >= 3 && parts[0] !== ".." ? parts[1] : basename(dirname(doc));
      const at = Date.parse(o.heartbeat ?? o.started);
      out.push({ bucket, role: /-chief\.md$/.test(doc) ? "chief" : "worker", doc: basename(doc).replace(/\.md$/, ""), at: Number.isFinite(at) ? at : 0 });
    } catch { /* a lock being acquired or released */ }
  }
  return out;
}

// a chief is live when ITS doc holds a queue lock: a bucket can hold older docs that were never wrapped
export const liveChiefs = (spans: Span[], locks: Lock[]): Span[] => spans.filter((s) => s.end === null && locks.some((l) => l.role === "chief" && l.doc === s.name));

// every chief doc (…-chief.md) of every bucket under <root>/<user>/, newer than `since`
export function readChiefDocs(root: string, since: number): Doc[] {
  const out: Doc[] = [];
  const walk = (dir: string, depth: number) => {
    let ents: import("node:fs").Dirent[];
    try { ents = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = join(dir, e.name);
      if (e.isDirectory()) { if (depth < 2 && !e.name.startsWith(".") && e.name !== "archive") walk(p, depth + 1); continue; }
      if (!/-chief\.md$/.test(e.name)) continue;
      try { if (statSync(p).mtimeMs < since) continue; out.push({ name: e.name.replace(/\.md$/, ""), bucket: basename(dir), text: readFileSync(p, "utf8") }); } catch { /* gone */ }
    }
  };
  walk(root, 0);
  return out;
}

// ---- shifts.jsonl: one writer, under a lock ----
async function withLock<T>(file: string, fn: () => T): Promise<T> {
  const path = `${file}.lock`;
  for (const end = Date.now() + 15_000; ;) {
    const l = acquireLock(path);
    if (!("busy" in l)) { try { return fn(); } finally { l.release(); } }
    if (Date.now() > end) throw new Error(`shifts.jsonl is locked: ${l.busy}`);
    await Bun.sleep(15 + Math.random() * 25);
  }
}

export function readShifts(file: string): Row[] {
  let text: string;
  try { text = readFileSync(file, "utf8"); } catch { return []; }
  const seen = new Map<string, Row>();
  for (const line of text.split("\n")) {
    try { const r = JSON.parse(line); if (r && typeof r.id === "string" && !seen.has(r.id)) seen.set(r.id, r); } catch { /* a torn line */ }
  }
  return [...seen.values()].sort((a, b) => Date.parse(a.opened) - Date.parse(b.opened));
}

const appendRow = (file: string, row: Row): "added" | "exists" => {
  if (readShifts(file).some((r) => r.id === row.id)) return "exists";
  mkdirSync(dirname(file), { recursive: true });
  appendFileSync(file, JSON.stringify(row) + "\n");
  return "added";
};
export const appendShift = (file: string, row: Row) => withLock(file, () => appendRow(file, row));

// ---- the poll: the Shift route and the report generator call this, nothing else writes ----
// merged resolves null when the PR list could not be read: a shift is never closed on a list that may be missing PRs
export type Tick = { root: string; file: string; now: number; opts?: Opts; merged: (fromMs: number, toMs: number) => Promise<Pr[] | null>; boards?: (locks: Lock[], spans: Span[]) => Promise<Board[]> };
export type Snapshot = { state: State; spans: Span[]; locks: Lock[]; offsetMin: number };

const stateFile = (file: string) => `${file}.state.json`;
const readState = (file: string): State => {
  try { const s = JSON.parse(readFileSync(stateFile(file), "utf8")); if (s && typeof s === "object") return { open: s.open ?? null, closedAt: s.closedAt ?? null, at: typeof s.at === "number" ? s.at : undefined }; } catch { /* first run */ }
  return { open: null, closedAt: null };
};

// Reads the fleet, applies the cut rule under the writer lock, writes each closed shift (idempotent on id), and returns where things stand.
export async function tick(t: Tick): Promise<Snapshot & { closed: Row[] }> {
  const o = t.opts ?? DEFAULTS;
  const offsetMin = -new Date(t.now).getTimezoneOffset();
  // the fleet reads and the gh query run before the lock is taken, so the lock is never held across a network call
  const locks = readLocks(t.root);
  const state0 = readState(t.file);
  const spans = chiefSpans(readChiefDocs(t.root, t.now - 3 * DAY), state0.open?.offsetMin ?? offsetMin, new Set(locks.filter((l) => l.role === "chief").map((l) => l.doc)));
  const live = liveChiefs(spans, locks).map((s) => s.start);
  const ends = spans.map((s) => s.end).filter((e): e is number => e !== null);
  const obs: Obs = { now: t.now, locks, lastEnd: ends.length ? Math.max(...ends) : null, chiefLiveAt: live.length ? Math.min(...live) : null };
  const prs = await t.merged(state0.open?.opened ?? t.now - 3 * DAY, t.now + MIN);
  const carried = rowsOf(await (t.boards?.(locks, spans) ?? [])).running.map((r): Carried => ({ ticket: r.ticket, title: r.title, stage: r.stage, pr: r.pr }));
  return withLock(t.file, () => {
    let st = readState(t.file);
    const closed: Row[] = [];
    // this poll read the fleet before it waited for the lock: if a later poll was applied meanwhile, applying this one would move the last release backwards
    if (st.at !== undefined && t.now < st.at) return { state: st, spans, locks, offsetMin, closed };
    for (let i = 0; i < 8; i++) { // a long gap between polls can pass several cuts
      const r = step(st, obs, o, offsetMin);
      if (r.closed && prs === null) return { state: st, spans, locks, offsetMin, closed }; // nothing is written: the next poll closes it with the PRs
      st = r.state;
      if (!r.closed) break;
      const off = (r.closed.zone[0] === "-" ? -1 : 1) * (Number(r.closed.zone.slice(1, 3)) * 60 + Number(r.closed.zone.slice(4, 6)));
      const full = { ...r.closed, carried: r.closed.why === "cut" ? carried : [], ...chiefsOf(spans, prs ?? [], Date.parse(r.closed.opened), Date.parse(r.closed.closed), t.now, off) };
      appendRow(t.file, full);
      closed.push(full);
    }
    mkdirSync(dirname(t.file), { recursive: true });
    const tmp = `${stateFile(t.file)}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify({ ...st, at: t.now }));
    renameSync(tmp, stateFile(t.file));
    return { state: st, spans, locks, offsetMin, closed };
  });
}

export const shiftsFile = (env: Record<string, string | undefined>) => env.SHIFTS_FILE || join(env.HANDOVER_DIR || "", "shifts.jsonl");

// ---- merged PRs: gh by argv, both bounds, the limit above the 60 the board used (49 merged in one real night) ----
export const MERGED_LIMIT = 200;
// The bounds go out in UTC (Z is an offset, and a "+" in a search qualifier would need encoding); the half-open [opened, closed) is applied after.
const utc = (ms: number) => new Date(Math.floor(ms / MIN) * MIN).toISOString().replace(".000Z", "Z");
const readPage = (env: Record<string, string | undefined>, cwd: string, from: number, to: number): Promise<Pr[] | null> => {
  return new Promise((done) => {
    execFile(env.GH_CMD || "gh", ["pr", "list", "--state", "merged", "--search", `merged:${utc(from)}..${utc(to)}`, "--limit", String(MERGED_LIMIT), "--json", "number,title,mergedAt,headRefName"],
      { cwd, env: env as NodeJS.ProcessEnv, timeout: 20_000, maxBuffer: 16 * 1024 * 1024 }, (err, out) => {
        try { const j = err ? null : JSON.parse(String(out)); done(Array.isArray(j) ? j.filter((p) => p && typeof p.number === "number" && typeof p.mergedAt === "string") : null); } catch { done(null); }
      });
  });
};

// A page that came back full may have been cut off: the window is split in two until every half fits, so no PR is dropped.
// A full page inside one two-minute window cannot be split, and that reads as unread rather than short.
export async function readMerged(env: Record<string, string | undefined>, cwd: string, from: number, to: number): Promise<Pr[] | null> {
  const page = await readPage(env, cwd, from, to);
  if (page === null || page.length < MERGED_LIMIT) return page;
  if (to - from <= 2 * MIN) return null;
  const mid = from + Math.floor((to - from) / 2);
  const lo = await readMerged(env, cwd, from, mid), hi = await readMerged(env, cwd, mid, to);
  return lo === null || hi === null ? null : [...new Map([...lo, ...hi].map((p) => [p.number, p])).values()];
}

// ---- what the page reads ----
type Leg = { leg: string; ticket?: string | null; goal?: string | null; description?: string | null; state?: string; stage?: string; stages?: Record<string, string | null>; pr?: { number?: number | null } | null };
type Need = { leg: string; verb?: string; action?: string; detail?: string; since?: string | null };
export type Board = { console?: { name?: string }; legs?: Leg[]; needs_you?: Need[] };
export type Waiting = { kind: string; ticket: string | null; title: string; detail: string; since: string | null; pr: number | null; chief: string };
export type Running = { ticket: string | null; title: string; stage: "building" | "in review"; since: string | null; pr: number | null };
export type Carried = { ticket: string | null; title: string; stage: string; pr: number | null };
export type View = {
  state: "open" | "idle" | "none";
  shift: { id: string; name: string; opened: string; closed: string | null; why: string | null; zone: string; nextCut: string | null; minutes: number } | null;
  chiefs: Chief[]; buckets: string[];
  mergedUnread: boolean; // the merged-PR list could not be read: Shipped is unknown, not empty
  waiting: Waiting[]; running: Running[]; shipped: { number: number; title: string; mergedAt: string; chief: string | null }[]; carried: Carried[]; gap: Gap[];
  pager: { prev: string | null; next: string | null };
  last: { id: string; name: string; opened: string; closed: string; chiefs: number; shipped: number | null } | null;
};

const kindOf = (n: Need, l?: Leg) => (l?.state === "ready-for-go" ? "GO" : n.verb === "unblock" ? "question" : (n.verb ?? "act"));
const prOf = (l?: Leg) => (typeof l?.pr?.number === "number" ? l.pr.number : null);
const titleOf = (l?: Leg) => String(l?.goal || l?.description || "").slice(0, 200);

// The live boards' rows: Waiting = the board's needs_you, Running = live and PR-open workers that are not waiting (a red CI stays Running: it is the worker's to fix).
export function rowsOf(boards: Board[]): { waiting: Waiting[]; running: Running[] } {
  const waiting: Waiting[] = [], running: Running[] = [];
  for (const b of boards) {
    const legs = new Map((b.legs ?? []).map((l) => [l.leg, l]));
    const chief = b.console?.name ?? "";
    const waits = new Set<string>();
    for (const n of b.needs_you ?? []) {
      const l = legs.get(n.leg);
      waits.add(n.leg);
      waiting.push({ kind: kindOf(n, l), ticket: l?.ticket ?? null, title: titleOf(l), detail: String(n.action ?? ""), since: n.since ?? null, pr: prOf(l), chief });
    }
    for (const l of b.legs ?? []) {
      if (waits.has(l.leg) || l.state === "ready-for-go" || l.state === "blocked") continue;
      if (l.stage !== "live" && l.stage !== "pr") continue;
      running.push({ ticket: l.ticket ?? null, title: titleOf(l), stage: l.stage === "pr" ? "in review" : "building", since: l.stages?.live ?? null, pr: prOf(l) });
    }
  }
  const t = (s: string | null) => (s ? Date.parse(s) : Infinity);
  waiting.sort((a, b) => t(a.since) - t(b.since)); // oldest first
  running.sort((a, b) => t(a.since) - t(b.since)); // longest-running first
  return { waiting, running };
}

// The page's whole read. id selects a closed shift (its row), none selects the current one.
export function viewOf(o0: { now: number; rows: Row[]; snap: Snapshot; id: string | null; merged: Pr[] | null; boards: Board[]; opts?: Opts }): View {
  const o = { ...o0, merged: o0.merged ?? [] };
  const opts = o.opts ?? DEFAULTS;
  const empty: View = { state: "none", shift: null, chiefs: [], buckets: [], mergedUnread: o0.merged === null, waiting: [], running: [], shipped: [], carried: [], gap: [], pager: { prev: null, next: null }, last: null };
  const closedRows = o.rows; // oldest first
  const open = o.snap.state.open;
  const pager = (id: string | null) => {
    const i = id === null ? closedRows.length : closedRows.findIndex((r) => r.id === id);
    return { prev: i > 0 ? closedRows[i - 1].id : null, next: id === null ? null : i + 1 < closedRows.length ? closedRows[i + 1].id : open ? "now" : null };
  };
  const titleBy = new Map(o.merged.map((p) => [p.number, String(p.title ?? "")]));
  const shipped = (opened: number, closed: number | null, chiefs: Chief[]) => mergedIn(o.merged, opened, closed, o.now)
    .sort((a, b) => Date.parse(b.mergedAt) - Date.parse(a.mergedAt))
    .map((p) => ({ number: p.number, title: titleBy.get(p.number) ?? "", mergedAt: p.mergedAt, chief: chiefs.find((c) => c.prs.includes(p.number))?.name ?? null }));
  if (o.id !== null) {
    const r = closedRows.find((x) => x.id === o.id);
    if (!r) return empty;
    const sh = shipped(Date.parse(r.opened), Date.parse(r.closed), r.chiefs);
    return { ...empty, state: "none", shift: { id: r.id, name: r.name, opened: r.opened, closed: r.closed, why: r.why, zone: r.zone, nextCut: null, minutes: Math.round((Date.parse(r.closed) - Date.parse(r.opened)) / MIN) },
      chiefs: r.chiefs, buckets: r.buckets, gap: r.gap, shipped: sh, carried: r.carried ?? [], waiting: [], pager: pager(r.id) };
  }
  const lastRow = closedRows.at(-1);
  const last = lastRow ? { id: lastRow.id, name: lastRow.name, opened: lastRow.opened, closed: lastRow.closed, chiefs: lastRow.chiefs.length, shipped: lastRow.shipped ?? (lastRow.chiefs.length ? new Set(lastRow.chiefs.flatMap((c) => c.prs)).size : null) } : null;
  if (!open) return { ...empty, state: "idle", last, pager: pager(null) };
  const off = open.offsetMin;
  const c = chiefsOf(o.snap.spans, o.merged, open.opened, null, o.now, off);
  const { waiting, running } = rowsOf(o.boards);
  return {
    ...empty, state: "open", last, pager: pager(null), chiefs: c.chiefs, gap: c.gap, buckets: open.buckets, waiting, running,
    shipped: shipped(open.opened, null, c.chiefs),
    shift: { id: iso(open.opened, off), name: nameOf(open.opened, off, opts), opened: iso(open.opened, off), closed: null, why: null, zone: zoneOf(off), nextCut: iso(nextCut(open.opened, off, opts), off), minutes: Math.round((o.now - open.opened) / MIN) },
  };
}

// the boards of the chiefs that hold a queue lock now, one per live chief doc, by NAME under the handover root
export async function liveBoards(root: string, locks: Lock[], spans: Span[]): Promise<Board[]> {
  const out: Board[] = [];
  for (const s of liveChiefs(spans, locks)) {
    const doc = await findDoc(root, s.name);
    const b = doc ? await readBoardFile(doc) : null;
    if (b) out.push(b.body as Board);
  }
  return out;
}
