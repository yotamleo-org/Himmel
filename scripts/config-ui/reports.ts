// reports.ts — the read side of the Morning report page: the dated morning-report-YYYY-MM-DD.md files that
// scripts/handover/generate-morning-briefing.sh writes under the handover root, parsed into blocks the page renders,
// plus the "so far" view (today's closed shifts, read live from shifts.jsonl; never a report and never saved).
// Read only: the generator is the one writer of the files, shift.ts of shifts.jsonl.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { readShifts, type Row } from "./shift";

export type Block = { t: "p"; text: string } | { t: "ul"; items: string[] } | { t: "table"; head: string[]; rows: string[][] } | { t: "code"; text: string };
export type Section = { title: string; blocks: Block[] };
export type ReportView =
  | { state: "ok"; day: string; bar: string[]; notes: string[]; sections: Section[] }
  | { state: "none"; day: string };
export type ReportList = { days: string[]; newest: string | null; ageHours: number | null; today: string };
export type SoFar = { day: string; shifts: { id: string; name: string; opened: string; closed: string; why: string; chiefs: number; prs: number }[] };

export const DAY = /^\d{4}-\d{2}-\d{2}$/;
const FILE = /^morning-report-(\d{4}-\d{2}-\d{2})\.md$/;

const cells = (line: string) => line.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());

// The generator's markdown is a small, fixed dialect: headings, bullets, one-line paragraphs, pipe tables, fenced code.
export function parseReport(md: string, day: string): ReportView {
  const bar: string[] = [], notes: string[] = [], sections: Section[] = [];
  let cur: Section | null = null;
  let fence: string[] | null = null;
  const lines = md.split(/\r?\n/);
  const push = (b: Block) => { if (cur) cur.blocks.push(b); };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (fence) { if (/^```/.test(line)) { push({ t: "code", text: fence.join("\n") }); fence = null; } else fence.push(line); continue; }
    if (/^```/.test(line)) { fence = []; continue; }
    const h = /^(#{2,3}) (.*)$/.exec(line);
    if (h) { cur = { title: h[2].trim(), blocks: [] }; sections.push(cur); continue; }
    if (/^# /.test(line)) continue; // the page has its own title
    if (!cur) { // the header block: the quoted lines before the first section
      const q = /^> ?(.*)$/.exec(line);
      if (!q) continue;
      const t = q[1].trim();
      if (!t) continue;
      if (t.startsWith("⚠")) notes.push(t.replace(/^⚠️?\s*/, ""));
      else if (/^(The tiles|Day starts)/.test(t)) bar.push(t);
      continue;
    }
    if (/^\|/.test(line) && i + 1 < lines.length && /^\|[\s:|-]+\|?$/.test(lines[i + 1])) {
      const head = cells(line); const rows: string[][] = []; i += 2;
      while (i < lines.length && /^\|/.test(lines[i])) rows.push(cells(lines[i++]));
      i--; push({ t: "table", head, rows }); continue;
    }
    const bullet = /^(\s*)- (.*)$/.exec(line);
    if (bullet) {
      const last = cur.blocks.at(-1);
      if (last && last.t === "ul") last.items.push(bullet[2]); else push({ t: "ul", items: [bullet[2]] });
      continue;
    }
    if (line.trim() && !/^>/.test(line)) push({ t: "p", text: line.trim() });
  }
  return { state: "ok", day, bar, notes, sections };
}

export function listReports(dir: string, now: number, today: string): ReportList {
  let days: string[] = [];
  try { days = readdirSync(dir).map((f) => FILE.exec(f)?.[1]).filter((d): d is string => !!d).sort().reverse(); } catch { /* no root */ }
  const newest = days[0] ?? null;
  let ageHours: number | null = null;
  if (newest) { try { ageHours = Math.round((now - statSync(join(dir, `morning-report-${newest}.md`)).mtimeMs) / 3_600_000); } catch { /* raced a delete */ } }
  return { days, newest, ageHours, today };
}

// The day is validated as a date and joined to a fixed name: no path ever comes from the request.
export function readReport(dir: string, day: string): ReportView {
  if (!DAY.test(day)) return { state: "none", day };
  const file = join(dir, `morning-report-${day}.md`);
  if (!existsSync(file)) return { state: "none", day };
  try { return parseReport(readFileSync(file, "utf8"), day); } catch { return { state: "none", day }; }
}

// "So far": the closed shifts whose close falls on `day`, straight from the record.
export function soFar(shiftsFile: string, day: string): SoFar {
  let rows: Row[] = [];
  try { rows = readShifts(shiftsFile); } catch { /* no record yet */ }
  return { day, shifts: rows.filter((r) => r.closed.slice(0, 10) === day).map((r) => ({ id: r.id, name: r.name, opened: r.opened, closed: r.closed, why: r.why, chiefs: r.chiefs.length, prs: new Set(r.chiefs.flatMap((c) => c.prs)).size })) };
}
