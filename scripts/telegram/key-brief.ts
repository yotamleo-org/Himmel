// The plain-words rule for Telegram texts: a ticket key gets its summary from the
// Jira mirror, a PR number and a worker label get words, and a paste-ready command is never touched.
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

export const NOT_READABLE = "summary not readable on the station";
const KEY = /[A-Z][A-Z0-9]{1,9}-[0-9]+/g;
const REF = /(?:[A-Za-z0-9_.-]+\/)?[A-Za-z0-9_.-]+#[0-9]+/g;
const WORKER = /N[0-9]+[a-z]*/g;
const SUMMARY_MAX = 80;

export type Range = [number, number];

// Backtick spans and every line that starts with `!` or `$ `, as [start, end) offsets into `text`.
export function protectedRanges(text: string): Range[] {
  const out: Range[] = [];
  for (const m of text.matchAll(/`[^`]*`/g)) out.push([m.index!, m.index! + m[0].length]);
  let at = 0;
  for (const line of text.split("\n")) {
    if (line.startsWith("!") || line.startsWith("$ ")) out.push([at, at + line.length]);
    at += line.length + 1;
  }
  return out;
}

const hits = (r: Range[], a: number, b: number) => r.some(([s, e]) => a < e && b > s);

// The offset of the space or newline that starts the Do: step: the last `Do: ` after a space or a newline that lies outside
// every backtick span and `!` / `$ ` line. -1 when there is none. The cap and the plain-words rule both split here.
export function findDo(text: string): number {
  const prot = protectedRanges(text);
  for (let i = text.length - 4; i >= 1; i--) {
    if (text.startsWith("Do: ", i) && (text[i - 1] === " " || text[i - 1] === "\n") && !hits(prot, i - 1, i + 4)) return i - 1;
  }
  return -1;
}

// Standalone: after the start, a space or `(`; before the end, a space or one of `.,;:)`.
function standalone(text: string, a: number, b: number): boolean {
  const before = a === 0 ? "" : text[a - 1];
  const after = b >= text.length ? "" : text[b];
  return (before === "" || before === " " || before === "\n" || before === "(") && (after === "" || /[ \n.,;:)]/.test(after));
}

function summaryOf(mirrorRoot: string, key: string): string {
  const project = key.slice(0, key.lastIndexOf("-"));
  const file = join(mirrorRoot, project, `${key}.md`);
  if (!existsSync(file)) return NOT_READABLE;
  // A file that exists and cannot be read throws on purpose: the router's guard then sends the raw text.
  const h1 = readFileSync(file, "utf8").split("\n").find((l) => l.startsWith(`# ${key}: `));
  const s = h1?.slice(`# ${key}: `.length).trim();
  if (!s) return NOT_READABLE;
  return s.length > SUMMARY_MAX ? `${s.slice(0, SUMMARY_MAX - 1)}…` : s;
}

const knownProject = (mirrorRoot: string, project: string) => project === process.env.JIRA_PROJECT_KEY || existsSync(join(mirrorRoot, project));

// briefText(text, mirrorRoot, refWord): the text in plain words. Never changes the Do: segment, a
// backtick span or a `!` / `$ ` line. A key with no standalone place outside them gets a trailer line.
export function briefText(text: string, mirrorRoot: string, refWord: string): string {
  return briefTextCounted(text, mirrorRoot, refWord).text;
}

// Same, and how many distinct keys the text names with a summary (inline, already there, or trailer), for the route log.
export function briefTextCounted(text: string, mirrorRoot: string, refWord: string): { text: string; keys: number } {
  const doAt = findDo(text);
  const body = doAt < 0 ? text : text.slice(0, doAt);
  const doSeg = doAt < 0 ? "" : text.slice(doAt + 1);   // "Do: ..." without the separator before it
  const prot = protectedRanges(text);
  const edits: { at: number; end: number; with: string }[] = [];
  const trailers: string[] = [];
  const seen = new Set<string>();

  for (const m of text.matchAll(KEY)) {
    const key = m[0];
    if (seen.has(key)) continue;
    if (!knownProject(mirrorRoot, key.slice(0, key.lastIndexOf("-")))) continue;
    seen.add(key);
    const summary = summaryOf(mirrorRoot, key);
    const spot = [...body.matchAll(new RegExp(key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"))].find((k) => {
      const a = k.index!; const b = a + key.length;
      return !hits(prot, a, b) && standalone(body, a, b) && !/(--key |=|\/)$/.test(body.slice(0, a));
    });
    if (spot) {
      const b = spot.index! + key.length;
      const has = [...Array(4).keys()].some((n) => body.slice(b + n, b + n + 12) === summary.slice(0, 12) && summary !== NOT_READABLE);
      if (!has) edits.push({ at: b, end: b, with: ` (${summary})` });
    } else {
      trailers.push(`${key}: ${summary}`);
    }
  }

  for (const m of body.matchAll(REF)) {
    const a = m.index!; const b = a + m[0].length;
    if (hits(prot, a, b) || !standalone(body, a, b)) continue;
    const [repo, num] = m[0].split("#");
    edits.push({ at: a, end: b, with: `${refWord} ${num} in ${repo}` });
  }
  for (const m of body.matchAll(WORKER)) {
    const a = m.index!; const b = a + m[0].length;
    if (hits(prot, a, b) || !standalone(body, a, b) || /worker $/i.test(body.slice(0, a))) continue;
    edits.push({ at: a, end: b, with: `worker ${m[0]}` });
  }

  let out = body;
  for (const e of edits.sort((x, y) => y.at - x.at)) out = out.slice(0, e.at) + e.with + out.slice(e.end);
  const keys = seen.size;
  if (!trailers.length) return { text: doAt < 0 ? out : `${out}${text[doAt]}${doSeg}`, keys };
  return { text: doAt < 0 ? `${out}\n${trailers.join("\n")}` : `${out}\n${trailers.join("\n")}\n${doSeg}`, keys };
}
