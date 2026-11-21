import { spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const KEY = /[A-Z][A-Z0-9]{1,9}-[0-9]+/g;
const REF = /(?:[A-Za-z0-9_.-]+\/)?[A-Za-z0-9_.-]+#[0-9]+/g;
const WORKER = /N[0-9]+[a-z]*/g;
const SUMMARY_MAX = 80;
const TRACKER_TIMEOUT_MS = 5000;
const TRACKER_BUDGET_MS = 8000;

export type Range = [number, number];

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

export function findDo(text: string): number {
  const prot = protectedRanges(text);
  for (let i = text.length - 4; i >= 1; i--) {
    if (text.startsWith("Do: ", i) && (text[i - 1] === " " || text[i - 1] === "\n") && !hits(prot, i - 1, i + 4)) return i - 1;
  }
  return -1;
}

function standalone(text: string, a: number, b: number): boolean {
  const before = a === 0 ? "" : text[a - 1];
  const after = b >= text.length ? "" : text[b];
  return (before === "" || before === " " || before === "\n" || before === "(") && (after === "" || /[ \n.,;:)]/.test(after));
}

const clip = (s: string) => (s.length > SUMMARY_MAX ? `${s.slice(0, SUMMARY_MAX - 1)}…` : s);

function trackerTitle(key: string, deadline: number): string | null {
  const left = deadline - Date.now();
  const cli = process.env.HIMMEL_JIRA_CLI || join(import.meta.dir, "..", "jira", "dist", "index.js");
  if (left <= 0 || (process.env.HIMMEL_TEST_FIXTURE === "1" && !process.env.HIMMEL_JIRA_CLI) || !existsSync(cli)) return null;
  const r = spawnSync("node", [cli, "get", key], {
    encoding: "utf8", timeout: Math.min(TRACKER_TIMEOUT_MS, left), maxBuffer: 1 << 20, stdio: ["ignore", "pipe", "ignore"],
    env: { ...process.env, JIRA_PROJECT_KEY: key.slice(0, key.lastIndexOf("-")) },
  });
  if (r.status !== 0) return null;
  return /^[^\t\n]+\t[^\t\n]*\t[^\t\n]*\t([^\n]+)/.exec(r.stdout)?.[1].trim() || null;
}

function summaryOf(mirrorRoot: string, key: string, deadline: number): string | null {
  const project = key.slice(0, key.lastIndexOf("-"));
  const file = join(mirrorRoot, project, `${key}.md`);
  if (existsSync(file)) {
    const h1 = readFileSync(file, "utf8").split("\n").find((l) => l.startsWith(`# ${key}: `));
    const s = h1?.slice(`# ${key}: `.length).trim();
    if (s) return clip(s);
  }
  const t = trackerTitle(key, deadline);
  return t ? clip(t) : null;
}

const knownProject = (mirrorRoot: string, project: string) => project === process.env.JIRA_PROJECT_KEY || existsSync(join(mirrorRoot, project));

export function briefText(text: string, mirrorRoot: string, refWord: string): string {
  return briefTextCounted(text, mirrorRoot, refWord).text;
}

export function briefTextCounted(text: string, mirrorRoot: string, refWord: string, trackerBudgetMs = TRACKER_BUDGET_MS): { text: string; keys: number; unresolved: string[] } {
  const doAt = findDo(text);
  const body = doAt < 0 ? text : text.slice(0, doAt);
  const doStep = doAt < 0 ? "" : text.slice(doAt + 1);
  const prot = protectedRanges(text);
  const edits: { at: number; end: number; with: string }[] = [];
  const trailers: string[] = [];
  const seen = new Set<string>();
  const unresolved: string[] = [];
  const deadline = Date.now() + trackerBudgetMs;

  for (const m of text.matchAll(KEY)) {
    const key = m[0];
    if (seen.has(key)) continue;
    if (!knownProject(mirrorRoot, key.slice(0, key.lastIndexOf("-")))) continue;
    seen.add(key);
    const summary = summaryOf(mirrorRoot, key, deadline);
    if (summary === null) { unresolved.push(key); continue; }
    const spot = [...body.matchAll(new RegExp(key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"))].find((k) => {
      const a = k.index!; const b = a + key.length;
      return !hits(prot, a, b) && standalone(body, a, b) && !/(--key |=|\/)$/.test(body.slice(0, a));
    });
    if (spot) {
      const b = spot.index! + key.length;
      const has = [...Array(4).keys()].some((n) => body.slice(b + n, b + n + 12) === summary.slice(0, 12));
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
  if (!trailers.length) return { text: doAt < 0 ? out : `${out}${text[doAt]}${doStep}`, keys, unresolved };
  return { text: doAt < 0 ? `${out}\n${trailers.join("\n")}` : `${out}\n${trailers.join("\n")}\n${doStep}`, keys, unresolved };
}
