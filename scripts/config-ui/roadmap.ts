// roadmap.ts — the read-side behind GET /api/roadmap. The Jira mirror (or the GitHub issues, or the local tracker store's
// items, read by the caller), the plan dir, the drift log and the workers are read LIVE on every request; nothing here
// writes or executes anything. Semantics are a port of
// scripts/handover/chief-kit/tracker.py (read_mirror, read_versions, bucket, jira_view, drift_log), which stays the
// CLI/offline renderer and the drift log's only writer. legSync only PLANS Jira CLI argv: the chief kit is the one writer.
import { closeSync, fstatSync, openSync, readdirSync, readFileSync, readSync } from "node:fs";
import { basename, join } from "node:path";
import type { Section } from "./health-sources";
import type { GhIssue } from "./tracker-sources";
import type { LocalItem } from "./local-tracker";

export const SYNC_LABEL = "worker-blocked";
// read-only: tickets flagged and noted under the old names still count; writers emit only the new names
const OLD_SYNC_LABEL = "leg-blocked";
const OLD_SYNC_TAG = "[leg-sync]";
const TRAIN_RE = /^v1\.\d+\.\d+[a-z]?$/;
const TAIL_BYTES = 64 * 1024;
const TREND_ROWS = 30;
const NO_SECTOR = "(no sector)";
const NO_THEME = "(no theme)";
const THEME_PREFIX = "theme-"; // the retired Jira label `theme-<slug>`: the fallback for a ticket with no Sector, read before the plan overlay
const slugOf = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
const STUCK = new Set(["BLOCKED", "FINDING", "HALTED", "PARKED-BANK", "PARKED-USAGE"]);
const CLEARING = new Set(["LIVE", "RESUMED", "RESOLVED", "READY", "WRAPPED"]);
const NOTED = new Set(["READY", "WRAPPED"]);
// tracker.py BUCKETS: the status NAME decides, the category only a name not listed.
const BUCKETS: Record<string, string> = { "to do": "todo", backlog: "todo", "in progress": "prog", "in review": "rev", ci: "ci", "in ci": "ci",
  done: "done", closed: "wont", "in public": "done", "wont do": "wont", "wont fix": "wont" };
const SHIPPED = new Set(["", "done", "fixed"]); // a Done ticket resolved any other way (Won't Do, Duplicate, ...) shipped nothing

export type Bucket = "todo" | "prog" | "rev" | "ci" | "done" | "wont";
export type Worker = { label: string; marker: string; reason: string };
export type Ticket = {
  k: number; id?: string; project?: string; t: string; s: string; b: Bucket; v: number; theme: number; pt: number; pv: string | null; drift: 0 | 1 | 2; // id: the shown id (a Jira ticket's <PROJECT>-<k>, a GitHub issue's #<k>, a local item's LOCAL-<n>); project: the Jira project key; pt: the index into planThemes
  after?: { id: string; b: Bucket | "unknown" }[]; // an open ticket's blockers from the mirror's links, each with its state; a key in no mirror is unknown
  noVersion?: true; // a Jira ticket with no fixVersion: v is -1, no version counts it; only the No version read (Opts.noVersion) carries it
  labels: string[]; worker: Worker | null; noted?: string; // noted: the mirror body, for the sync dedupe; non-enumerable, never shipped
  backend: Source; epic?: string; // backend: where a write for this card goes; epic: a local item's parent id
};
type Source = "jira" | "github" | "local";
// project: the Jira project the version belongs to; with several projects on the Board n is `<name> (<PROJECT>)`, so a same-named version of two projects is two entries.
export type Version = { n: string; project?: string; run?: "running" | "next"; rel: boolean; date: string; counts: Record<Bucket, number>; open: number[] };
export type Proposal = { k: number; id?: string; title: string; proposal: string; needsApproval: true };
export type DupProposal = { keys: number[]; ids?: string[]; title: string; proposal: string; needsApproval: true };
export type SyncOp = { k: number; id?: string; marker: string; argv: string[]; why: string };
export type Roadmap = {
  state: "ok" | "absent"; reason?: string; source: Source | "none";
  mirror: { dir: string; count: number; newest: string };
  projects: string[]; // the Jira projects whose tickets are on the Board; empty for GitHub and the local store
  projectThemes?: Record<string, number[]>; // with several projects: the indexes into themes each project's tickets use
  releaseUnknown: boolean; versions: Version[]; tickets: Ticket[]; themes: string[]; // themes: the Sector groups (wire key kept), "(no sector)" for none
  planThemes: string[]; // the plan's theme (or the retired theme- label), apart from the Sector; "(no theme)" for none
  plan: { state: "ok" | "absent"; reason?: string; dir?: string };
  cur: number; next: number;
  noVersionCount: number; // the Jira tickets with no fixVersion: the default read leaves them out, so this is all it says of them
  drift: { now: { drift: number; unplanned: number; unthemed: number }; trend: [string, number, number, number][] };
  librarian: { staleInProgress: Proposal[]; drift: Proposal[]; unthemed: Proposal[]; releasedOpen: Proposal[]; duplicates: DupProposal[] };
};
// local: the local tracker store's items (TRACKER=local); none: TRACKER=none, no tracker at all
// projects: the Jira mirrors to read, one per project (<root>/<KEY>, its versions in <root>/<KEY>.versions.tsv); without it mirrorDir is the one HIMMEL mirror
type Opts = { mirrorDir: string; versionsFile?: string; projects?: { key: string; dir: string }[]; planDir?: string; driftLog?: string; workers: Section; github?: GhIssue[]; local?: LocalItem[]; none?: boolean;
  noVersion?: boolean }; // noVersion: carry the tickets with no fixVersion and nothing else; without it they are left out (the Board's No version tab asks)
type M = { k: number; p: string; sn: string; cat: string; res: string; fv: string[]; labels: string[]; sector: string; upd: string; title: string; body: string; id?: string; epic?: string; blockedBy?: string[] };

const text = (f: string) => { try { return readFileSync(f, "utf8"); } catch { return ""; } };
const json = <T>(s: string | undefined, d: T): T => { try { return s === undefined ? d : JSON.parse(s); } catch { return d; } };
const unq = (s: string | undefined) => (s ?? "").trim().replace(/^"|"$/g, "");
const clip = (s: string, n: number) => { s = s.split(/\s+/).filter(Boolean).join(" "); return s.length <= n ? s : s.slice(0, n - 1) + "…"; };
const rows = (f: string) => text(f).split(/\r?\n/).filter(Boolean).map((l) => l.split("\t"));
const KEY_ID = /^([A-Z][A-Z0-9]*)-(\d+)$/;
const keyNum = (k: string | undefined) => { const m = KEY_ID.exec((k ?? "").trim()); return m ? { p: m[1], n: Number(m[2]) } : null; };
const planKey = (m: M) => (m.p ? `${m.p}-${m.k}` : `HIMMEL-${m.k}`); // the plan tables and the worker docs name a ticket by its full key

// tracker.py ver_key: v1.0.n[a-z] by n, v1.1.N after v1.0.2, later milestone minors numerically, anything else last.
function verKey(v: string): [number, number, string] {
  let m = /^v1\.0\.(\d+)([a-z]?)$/.exec(v);
  if (m) return [0, Number(m[1]), m[2]];
  m = /^v1\.1\.(\d+)$/.exec(v);
  if (m) return [0, 2, String.fromCharCode(98 + Number(m[1]))];
  m = /^v1\.([2-9]|\d{2,})\.(\d+)([a-z]?)$/.exec(v);
  return m ? [0, 1000 + Number(m[1]), String(m[2]).padStart(12, "0") + m[3]] : [1, 0, ""];
}
const verCmp = (a: string, b: string) => { const x = verKey(a), y = verKey(b); return x[0] - y[0] || x[1] - y[1] || (x[2] < y[2] ? -1 : x[2] > y[2] ? 1 : 0); };

function readMirror(dir: string, project: string): M[] {
  let names: string[];
  try { names = readdirSync(dir).filter((f) => f.endsWith(".md") && keyNum(f.slice(0, -3))?.p === project); } catch { return []; }
  const out: M[] = [];
  for (const f of names) {
    const parts = text(join(dir, f)).split("---");
    if (parts.length < 3) continue;
    const fm: Record<string, string> = {};
    for (const l of parts[1].split("\n")) { const i = l.indexOf(":"); if (i > 0 && !l.startsWith(" ")) fm[l.slice(0, i).trim()] = l.slice(i + 1).trim(); }
    const key = keyNum(unq(fm.key));
    if (key === null || key.p !== project) continue;
    const k = key.n;
    const body = parts.slice(2).join("---");
    const sn = json<unknown>(fm.status, "");
    const res = json<unknown>(fm.resolution, "");
    const sector = json<unknown>(fm.sector, ""); // `sector: "Visibility"` or null; the line is absent when sectors are off
    const blockedBy = json<unknown>(/^\s+blocked_by:\s*(\[.*\])\s*$/m.exec(parts[1])?.[1], []); // the `links:` block's nested line, which the flat frontmatter read above skips
    out.push({ k, p: project, blockedBy: Array.isArray(blockedBy) ? blockedBy.map(String) : [], sn: typeof sn === "string" ? sn : "", cat: unq(fm.statusCategory), res: typeof res === "string" ? res : "", fv: json<string[]>(fm.fixVersions, []).map(String), labels: json<string[]>(fm.labels, []).map(String),
      sector: typeof sector === "string" ? sector.trim() : "", upd: unq(fm.updated), title: /^# [A-Z][A-Z0-9]*-\d+:\s*(.*)$/m.exec(body)?.[1] ?? "", body });
  }
  return out;
}

// GitHub issues as mirror rows: an open issue's status comes from an in-progress / in-review / ci label, a closed one from its
// state reason; the milestone is the version and a `theme-<slug>` label the theme, as for Jira.
const NO_MILESTONE = "(no milestone)";
const GH_STATUS: Record<string, string> = { "in-progress": "In Progress", "in-review": "In Review", ci: "IN CI", "in-ci": "IN CI" };
function fromIssues(issues: GhIssue[]): M[] {
  return issues.map((i) => {
    const labels = (i.labels ?? []).map((l) => l.name);
    const open = i.state.toUpperCase() === "OPEN";
    const live = labels.map((l) => { const s = slugOf(l).replace(/^status-/, ""); return Object.hasOwn(GH_STATUS, s) ? GH_STATUS[s] : undefined; }).find(Boolean);
    const sn = open ? live ?? "To Do" : i.stateReason?.toUpperCase() === "NOT_PLANNED" ? "Closed" : "Done";
    return { k: i.number, p: "", sn, cat: "", res: "", fv: [i.milestone?.title ?? NO_MILESTONE], labels, sector: "", upd: i.updatedAt ?? "", title: i.title, body: "" };
  });
}
function ghVersions(issues: GhIssue[]): { n: string; rel: boolean; date: string }[] {
  const ms = new Map<string, number>();
  for (const i of issues) if (i.milestone) ms.set(i.milestone.title, i.milestone.number);
  const names = [...ms].sort((a, b) => a[1] - b[1]).map(([n]) => n);
  if (issues.some((i) => !i.milestone)) names.push(NO_MILESTONE);
  return names.map((n) => ({ n, rel: false, date: "" }));
}

// Local store items as mirror rows: the generated id is kept as shown, its number orders the cards; the seam's ladder names
// are the bucket names already; the fix_version is the version and the item's sector the theme.
const NO_VERSION = "(no version)";
function fromLocal(items: LocalItem[]): M[] {
  return items.flatMap((i) => {
    const m = /^[A-Z][A-Z0-9]*-(\d+)$/.exec(i.id);
    return m ? [{ k: Number(m[1]), p: "", id: i.id, epic: i.epic, sn: i.status, cat: "", res: "", fv: [i.fix_version || NO_VERSION], labels: [], sector: i.sector.trim(), upd: "", title: i.title, body: "" }] : [];
  });
}
function localVersions(items: LocalItem[]): { n: string; rel: boolean; date: string }[] {
  const names = [...new Set(items.map((i) => i.fix_version).filter(Boolean))].sort((a, b) => verCmp(a, b) || a.localeCompare(b, undefined, { numeric: true }));
  if (items.some((i) => !i.fix_version)) names.push(NO_VERSION);
  return names.map((n) => ({ n, rel: false, date: "" }));
}

const bucketOf = (m: M): Bucket => {
  const b = BUCKETS[m.sn.trim().toLowerCase()] ?? ({ Done: "done", "In Progress": "prog" } as Record<string, string>)[m.cat] ?? "todo";
  return (b === "done" && !SHIPPED.has(m.res.trim().toLowerCase()) ? "wont" : b) as Bucket;
};
const isOpen = (b: Bucket) => b !== "done" && b !== "wont";

function readVersions(file: string, mir: M[]): { list: { n: string; rel: boolean; date: string }[]; unknown: boolean } {
  const ok = (f: string[]) => f.length >= 2 && TRAIN_RE.test(f[0]) && f[0] !== "v1.0.0";
  const lines = rows(file).filter(ok);
  if (!lines.length) {
    const names = [...new Set(mir.flatMap((m) => m.fv).filter((v) => TRAIN_RE.test(v) && v !== "v1.0.0"))].sort(verCmp);
    return { list: names.map((n) => ({ n, rel: false, date: "" })), unknown: true };
  }
  return { list: lines.map((f) => ({ n: f[0], rel: f[1] === "true", date: f[2] ?? "" })), unknown: false };
}

// Plan tables are TSVs with a header row; a column is found by its name.
function table(f: string): Record<string, string>[] {
  const [head, ...body] = rows(f);
  return head ? body.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ""]))) : [];
}

function readTheme(planDir: string): Map<string, string> {
  const out = new Map<string, string>();
  const stage1 = join(planDir, "stage1");
  let files: string[] = [];
  try { files = readdirSync(stage1).filter((f) => /^C\d\d\.tsv$/.test(f)).sort(); } catch { /* no stage1 */ }
  for (const f of files) for (const r of table(join(stage1, f))) { const k = (r.key ?? "").trim(); if (keyNum(k) && r.theme) out.set(k, r.theme); }
  for (const r of table(join(stage1, "themes-overlay.tsv"))) { const k = (r.key ?? "").trim(); if (keyNum(k) && r.theme && !out.has(k)) out.set(k, r.theme); } // overlay fills only the missing
  return out;
}

// The last 64 KiB of a file; "" when unreadable.
function tail(f: string): string {
  try {
    const fd = openSync(f, "r");
    try {
      const size = fstatSync(fd).size, start = Math.max(0, size - TAIL_BYTES), buf = Buffer.alloc(size - start);
      readSync(fd, buf, 0, buf.length, start);
      return buf.toString("utf8");
    } finally { closeSync(fd); }
  } catch { return ""; }
}

// The text after the marker on the doc's newest `- ` bullet that starts with it ("- 04:32 BLOCKED — why").
function legReason(doc: string, marker: string): string {
  const re = new RegExp(`^-\\s+(?:\\d{1,2}:\\d{2}\\s+)?(?:\\*\\*)?${marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:\\*\\*)?[\\s:—–-]*(.*)$`);
  const lines = tail(doc).split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) { const m = re.exec(lines[i]); if (m) return m[1].replace(/\*\*$/, "").trim(); }
  return "";
}

function readTrend(f: string): [string, number, number, number][] {
  return rows(f).slice(1).filter((r) => r.length === 4 && r.slice(1).every((x) => /^\d+$/.test(x)))
    .map((r) => [r[0], Number(r[1]), Number(r[2]), Number(r[3])] as [string, number, number, number]).slice(-TREND_ROWS);
}

const normTitle = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

export function readRoadmap(o: Opts): Roadmap {
  const gh = o.github, local = o.local;
  const source: Source = gh ? "github" : local ? "local" : "jira";
  // Jira: one group per project (its mirror, its versions snapshot); GitHub and the local store are one group with no project.
  type VL = { n: string; raw: string; p: string; rel: boolean; date: string };
  const jiraGroups = o.none || gh || local ? [] : (o.projects ?? [{ key: "HIMMEL", dir: o.mirrorDir }]).map((pr) => {
    const rows = readMirror(pr.dir, pr.key);
    const v = readVersions(o.projects ? pr.dir + ".versions.tsv" : o.versionsFile ?? pr.dir + ".versions.tsv", rows);
    return { p: pr.key, mir: rows, ...v };
  }).filter((g) => g.mir.length);
  const multi = jiraGroups.length > 1;
  const mir: M[] = o.none ? [] : gh ? fromIssues(gh) : local ? fromLocal(local) : jiraGroups.flatMap((g) => g.mir);
  const empty: Roadmap = { state: "absent", source: o.none ? "none" : source, mirror: { dir: o.mirrorDir, count: 0, newest: "" }, projects: [], releaseUnknown: false, versions: [], tickets: [], themes: [NO_SECTOR], planThemes: [NO_THEME], noVersionCount: 0,
    plan: { state: "absent" }, cur: -1, next: -1, drift: { now: { drift: 0, unplanned: 0, unthemed: 0 }, trend: [] },
    librarian: { staleInProgress: [], drift: [], unthemed: [], releasedOpen: [], duplicates: [] } };
  if (o.none) return { ...empty, reason: "no tracker is configured (TRACKER=none)" };
  if (!mir.length) {
    return { ...empty, reason: gh ? "no issues in this GitHub repository" : local ? "no items in the local tracker store"
      : `no Jira mirror at ${o.mirrorDir}; build one with: node scripts/jira/dist/index.js mirror` };
  }

  // The version list is every project's own, side by side: a name two projects share is two entries, told apart by the project in n.
  const plain = (l: { n: string; rel: boolean; date: string }[], p: string): VL[] => l.map((v) => ({ n: v.n, raw: v.n, p, rel: v.rel, date: v.date }));
  const list: VL[] = gh ? plain(ghVersions(gh), "") : local ? plain(localVersions(local), "")
    : jiraGroups.flatMap((g) => plain(g.list, g.p).map((v) => (multi ? { ...v, n: `${v.raw} (${g.p})` } : v)));
  const unknown = !gh && !local && jiraGroups.some((g) => g.unknown);
  const vi = new Map(list.map((v, i) => [`${v.p}\u0000${v.raw}`, i]));
  const vix = (m: M, name: string) => vi.get(`${m.p}\u0000${name}`);

  // Plan: placement.tsv (version per ticket) and the themes; absent plan = every drift 0. Rows name a ticket by its full key.
  let place: Map<string, string> | null = null, planReason = "no plan dir";
  if (o.planDir) {
    const p = table(join(o.planDir, "stage3", "placement.tsv"));
    if (p.length) place = new Map(p.flatMap((r) => { const k = (r.key ?? "").trim(); return keyNum(k) === null ? [] : [[k, r.version] as [string, string]]; }));
    else planReason = `no stage3/placement.tsv in ${o.planDir}`;
  }
  const themeOf = o.planDir ? readTheme(o.planDir) : new Map<string, string>();
  // a ticket's Sector wins; else its retired Jira theme label (a slug that matches a plan theme shows that theme's name); else the plan.
  const planNames = new Map([...themeOf.values()].map((n) => [slugOf(n), n] as [string, string]));
  const planOf = new Map(themeOf); // the Theme filter: the retired label, else the plan, whatever the Sector says
  for (const m of mir) {
    const lab = m.labels.find((l) => l.startsWith(THEME_PREFIX) && l.length > THEME_PREFIX.length), pk = planKey(m);
    if (lab) planOf.set(pk, planNames.get(lab.slice(THEME_PREFIX.length)) ?? lab.slice(THEME_PREFIX.length));
    if (m.sector) themeOf.set(pk, m.sector);
    else if (lab) themeOf.set(pk, planOf.get(pk)!);
  }
  const themes = [...new Set([NO_SECTOR, ...themeOf.values()])].sort();
  const planThemes = [...new Set([NO_THEME, ...planOf.values()])].sort();

  // Workers: ticket number -> the last worker listed for it.
  const workers = new Map<string, Worker>();
  // worker docs are named by Jira key, so only a Jira roadmap matches them
  if (source === "jira" && o.workers.state === "ok" && Array.isArray(o.workers.workers)) {
    for (const l of o.workers.workers as { doc: string; status: string }[]) {
      const m = /^([A-Z][A-Z0-9]*-\d+)-(N\d+[a-z]?)-.*\.md$/.exec(basename(String(l.doc)));
      if (m) workers.set(m[1], { label: m[2], marker: String(l.status), reason: legReason(String(l.doc), String(l.status)) });
    }
  }

  const all: Ticket[] = [];
  const byKey = new Map(mir.map((x) => [planKey(x), x]));
  for (const m of mir) {
    const hit = m.fv.filter((v) => vix(m, v) !== undefined);
    const nv = !m.fv.length; // no fixVersion at all: read, but kept out of the default read. A fixVersion outside the train is still dropped.
    if (!hit.length && !nv) continue;
    const un = hit.filter((v) => !list[vix(m, v)!].rel);
    const v = nv ? "" : un.length ? un.reduce((a, b) => (vix(m, b)! < vix(m, a)! ? b : a)) : hit.reduce((a, b) => (vix(m, b)! > vix(m, a)! ? b : a));
    const pk = planKey(m), b = bucketOf(m), pv = place?.get(pk) ?? null;
    const drift = nv || !place ? 0 : pv !== null ? (pv !== v ? 1 : 0) : isOpen(b) ? 2 : 0;
    const t: Ticket = { k: m.k, ...(gh ? { id: `#${m.k}` } : m.id ? { id: m.id } : m.p ? { id: pk, project: m.p } : {}), t: clip(m.title, 90), s: m.sn || m.cat, b, v: nv ? -1 : vix(m, v)!, theme: themes.indexOf(themeOf.get(pk) ?? NO_SECTOR),
      pt: planThemes.indexOf(planOf.get(pk) ?? NO_THEME), pv, drift: drift as 0 | 1 | 2,
      labels: m.labels, worker: isOpen(b) ? workers.get(pk) ?? null : null, backend: source,
      ...(isOpen(b) && m.blockedBy?.length ? { after: m.blockedBy.map((id) => ({ id, b: byKey.has(id) ? bucketOf(byKey.get(id)!) : ("unknown" as const) })) } : {}), ...(nv ? { noVersion: true as const } : {}), ...(m.epic ? { epic: m.epic } : {}) };
    Object.defineProperty(t, "noted", { value: m.body, enumerable: false });
    all.push(t);
  }
  all.sort((a, b) => (a.project ?? "").localeCompare(b.project ?? "") || a.k - b.k);
  const noVersionCount = all.filter((t) => t.noVersion).length;
  const projects = jiraGroups.map((g) => g.p);
  // the Sectors each project's tickets use, over every ticket (with and without a version): the page offers a card only its own project's
  const projectThemes = multi ? { projectThemes: Object.fromEntries(projects.map((p) => [p, [...new Set(all.filter((t) => t.project === p).map((t) => t.theme))]])) } : {};
  if (o.noVersion) {
    return { ...empty, state: "ok", source, mirror: { dir: o.mirrorDir, count: mir.length, newest: mir.reduce((a, m) => (m.upd > a ? m.upd : a), "") },
      projects, ...projectThemes, releaseUnknown: unknown, tickets: all.filter((t) => t.noVersion), themes, planThemes, noVersionCount,
      plan: place ? { state: "ok", dir: o.planDir } : { state: "absent", reason: planReason } };
  }
  const tickets = all.filter((t) => !t.noVersion);

  const versions: Version[] = list.map((v, i) => {
    const counts = { todo: 0, prog: 0, rev: 0, ci: 0, done: 0, wont: 0 };
    const mine = tickets.filter((t) => t.v === i);
    for (const t of mine) counts[t.b]++;
    return { n: v.n, ...(v.p ? { project: v.p } : {}), rel: v.rel, date: v.date, counts, open: v.rel ? mine.filter((t) => isOpen(t.b)).map((t) => t.k) : [] };
  });
  const cur = versions.findIndex((v, i) => !v.rel && tickets.some((t) => t.v === i && isOpen(t.b)));
  const next = versions.findIndex((v, i) => i > cur && !v.rel && tickets.some((t) => t.v === i));
  // Each project runs its own version: the running and the next one are found among that project's versions alone. With several
  // projects the version carries it (run), and the librarian points a released-but-open ticket at its own project's running version.
  const own = new Map<string, { cur: number; next: number }>();
  for (const p of new Set(list.map((v) => v.p))) {
    const at = versions.map((_, i) => i).filter((i) => list[i].p === p);
    const c = at.find((i) => !versions[i].rel && tickets.some((t) => t.v === i && isOpen(t.b))) ?? -1;
    own.set(p, { cur: c, next: at.find((i) => i > c && !versions[i].rel && tickets.some((t) => t.v === i)) ?? -1 });
  }
  if (multi) versions.forEach((v, i) => { const r = own.get(list[i].p); if (r?.cur === i) v.run = "running"; else if (r?.next === i) v.run = "next"; });

  const open = tickets.filter((t) => isOpen(t.b));
  const unthemed = open.filter((t) => themes[t.theme] === NO_SECTOR);
  const now = { drift: tickets.filter((t) => t.drift === 1).length, unplanned: open.filter((t) => t.drift === 2).length, unthemed: unthemed.length };

  const prop = (t: Ticket, proposal: string): Proposal => ({ k: t.k, ...(t.id ? { id: t.id } : {}), title: t.t, proposal, needsApproval: true });
  const runOf = (t: Ticket) => versions[own.get(t.project ?? "")?.cur ?? -1]?.n;
  // ponytail: duplicates are an exact match on the normalized title only (within one project), upgrade path: token-similarity when the librarian lane runs.
  const byTitle = new Map<string, Ticket[]>();
  for (const t of open) { const n = normTitle(t.t); if (n) byTitle.set(`${t.project ?? ""}\u0000${n}`, [...(byTitle.get(`${t.project ?? ""}\u0000${n}`) ?? []), t]); }
  const librarian = {
    staleInProgress: tickets.filter((t) => ["prog", "rev", "ci"].includes(t.b) && (!t.worker || t.worker.marker === "WRAPPED" || t.worker.marker === "HALTED"))
      .map((t) => prop(t, t.worker ? `${t.s} but its worker is ${t.worker.marker}: confirm the state, then move it back to To Do or close it` : `${t.s} with no worker: confirm someone is on it, else move it back to To Do`)),
    drift: tickets.filter((t) => t.drift === 1).map((t) => prop(t, `Jira says ${versions[t.v].n}, the plan says ${t.pv}: move fixVersion to ${t.pv} or re-plan`)),
    unthemed: unthemed.map((t) => prop(t, source === "github"
      ? "assign a theme in the plan (stage1 overlay)"
      : source === "local" ? "assign a Sector with the card's Sector select on the Board"
        : `assign a Sector: jira edit ${t.id ?? `HIMMEL-${t.k}`} --sector "<sector>"`)),
    releasedOpen: open.filter((t) => t.v >= 0 && versions[t.v].rel).map((t) => prop(t, `${versions[t.v].n} is released but this is still open: move to ${runOf(t) ?? "the running version"}`)),
    duplicates: [...byTitle.values()].filter((g) => g.length > 1).map((g) => ({ keys: g.map((t) => t.k).sort((a, b) => a - b), ...(g[0].id ? { ids: g.slice().sort((a, b) => a.k - b.k).map((t) => t.id!) } : {}), title: g[0].t,
      proposal: "same title: close all but one, linking the rest to it", needsApproval: true as const })).sort((a, b) => a.keys[0] - b.keys[0]),
  };

  return {
    state: "ok", source, mirror: { dir: o.mirrorDir, count: mir.length, newest: mir.reduce((a, m) => (m.upd > a ? m.upd : a), "") },
    projects, ...projectThemes, releaseUnknown: unknown, versions, tickets, themes, planThemes, noVersionCount,
    plan: place ? { state: "ok", dir: o.planDir } : { state: "absent", reason: planReason },
    cur, next, drift: { now, trend: o.driftLog ? readTrend(o.driftLog) : [] }, librarian,
  };
}

// The Jira CLI argv that mirrors each worker's marker onto its ticket. Planned only: the chief kit is the one writer,
// workers never write Jira, and this page never does. The flag is dropped with `--remove-labels` (a `--labels` full replace
// cannot leave a ticket with no label); a status is never moved.
export function legSync(tickets: Ticket[]): SyncOp[] {
  const ops: SyncOp[] = [];
  for (const t of tickets) {
    if (!t.worker) continue;
    const { label, marker, reason } = t.worker, key = t.id ?? `HIMMEL-${t.k}`;
    const text = `${label} ${marker}${reason ? `: ${reason}` : ""}`;
    const line = `[worker-sync] ${text}`;
    const noted = (t.noted ?? "").includes(line) || (t.noted ?? "").includes(`${OLD_SYNC_TAG} ${text}`);
    const has = t.labels.includes(SYNC_LABEL) || t.labels.includes(OLD_SYNC_LABEL);
    if (STUCK.has(marker)) {
      if (!has) ops.push({ k: t.k, id: key, marker, argv: ["edit", key, "--add-labels", SYNC_LABEL], why: `worker ${label} is ${marker}: flag the ticket` });
      if (!noted) ops.push({ k: t.k, id: key, marker, argv: ["comment", key, line], why: `record why worker ${label} is ${marker}` });
    } else if (CLEARING.has(marker)) {
      if (has) ops.push({ k: t.k, id: key, marker, argv: ["edit", key, "--remove-labels", `${SYNC_LABEL},${OLD_SYNC_LABEL}`], why: `worker ${label} is ${marker}: clear the flag` });
      if (NOTED.has(marker) && !noted) ops.push({ k: t.k, id: key, marker, argv: ["comment", key, line], why: `note once that worker ${label} is ${marker}` });
    }
  }
  return ops;
}
