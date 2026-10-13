// HIMMEL-5491: the Kanban's write path. A drop moves a ticket to another status column and a theme select sets its
// single `theme-<slug>` label, both through the Jira CLI (never the REST API, never credentials in this process).
// Validation is here and runs before any child; the route in server.ts adds the token gate, the write lock and the audit.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { ChildResult } from "./lock";

export const KEY_RE = /^HIMMEL-\d+$/;
export const THEME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
export const THEME_PREFIX = "theme-";
const MAX_THEME = 40;
// The board's bucket ids (roadmap.ts BUCKETS) to the workflow status names the Jira CLI's `transition` matches.
export const STATUS_NAMES: Record<string, string> = { todo: "To Do", prog: "In Progress", rev: "In Review", ci: "IN CI", done: "Done", wont: "wont do" };
const LABEL_RE = /^[^\s,]+$/;
const WRITE_MS = 30_000, MIRROR_MS = 60_000;

export type WriteReq =
  | { action: "jira-transition"; key: string; status: string; value: string }
  | { action: "jira-theme"; key: string; theme: string | null; value: string | null };

export function parseWrite(b: Record<string, unknown>): WriteReq | { error: string } {
  const key = b.key;
  if (typeof key !== "string" || !KEY_RE.test(key)) return { error: "key must match HIMMEL-<n>" };
  const hasStatus = "status" in b, hasTheme = "theme" in b;
  if (hasStatus === hasTheme) return { error: "send exactly one of status or theme" };
  if (hasStatus) {
    const s = b.status;
    if (typeof s !== "string" || !Object.prototype.hasOwnProperty.call(STATUS_NAMES, s)) return { error: "unknown status column" };
    return { action: "jira-transition", key, status: s, value: s };
  }
  const t = b.theme;
  if (t === null) return { action: "jira-theme", key, theme: null, value: null };
  if (typeof t !== "string" || t.length > MAX_THEME || !THEME_RE.test(t)) return { error: "theme must be a lowercase slug" };
  return { action: "jira-theme", key, theme: t, value: t };
}

// A mirror file's current status name and labels, or null when the ticket is not mirrored.
export function mirrorState(dir: string, key: string): { status: string; labels: string[] } | null {
  let txt: string;
  try { txt = readFileSync(join(dir, `${key}.md`), "utf8"); } catch { return null; }
  const fm = txt.split("---")[1] ?? "";
  const field = (name: string) => new RegExp(`^${name}:\\s*(.*)$`, "m").exec(fm)?.[1].trim();
  const parse = <T>(s: string | undefined, d: T): T => { try { return s === undefined ? d : JSON.parse(s); } catch { return d; } };
  const status = parse<unknown>(field("status"), "");
  const labels = parse<unknown>(field("labels"), []);
  return { status: typeof status === "string" ? status : "", labels: Array.isArray(labels) ? labels.map(String) : [] };
}

export type WriteDeps = { run: (argv: string[], timeoutMs: number) => Promise<ChildResult>; bin: string; mirrorDir: string };
export type WriteResult = {
  status: number; body: Record<string, unknown>; argv: string[]; rc: number | null;
  before: Record<string, string> | null; after: Record<string, string> | null; outcome?: "error";
};

const jira = (d: WriteDeps, ...a: string[]) => ["node", d.bin, ...a];
const fail = (status: number, error: string, argv: string[], rc: number | null, before: WriteResult["before"], output = ""): WriteResult =>
  ({ status, body: { error, output }, argv, rc, before, after: null, outcome: rc === null ? "error" : undefined });

export async function applyWrite(req: WriteReq, d: WriteDeps): Promise<WriteResult> {
  const was = mirrorState(d.mirrorDir, req.key);
  let argv: string[], before: WriteResult["before"], extra: Record<string, unknown>;
  if (req.action === "jira-transition") {
    argv = jira(d, "transition", req.key, STATUS_NAMES[req.status]);
    before = { status: was?.status ?? "" };
    extra = { status: req.status, name: STATUS_NAMES[req.status] };
  } else {
    // --labels is a full replace in the CLI, so the set is read live from Jira, not from the (possibly stale) mirror.
    // The labels come from `get --json` (fields.labels), never the human output: there the Labels line follows the
    // description body, so a description line starting `Labels:` would read as the ticket's labels and the edit would wipe them.
    const getArgv = jira(d, "get", req.key, "--json");
    const got = await d.run(getArgv, WRITE_MS);
    if (got.rc !== 0) return fail(502, "could not read the ticket's labels", getArgv, got.rc, null, got.stdout + got.stderr);
    let issue: { key?: unknown; fields?: { labels?: unknown } } | null = null;
    try { issue = JSON.parse(got.stdout); } catch { /* answered below */ }
    const raw = issue?.fields?.labels;
    if (!issue || issue.key !== req.key || !Array.isArray(raw)) return fail(502, "unexpected ticket output", getArgv, got.rc, null, got.stdout);
    const labels = raw.filter((l): l is string => typeof l === "string");
    if (labels.length !== raw.length || !labels.every((l) => LABEL_RE.test(l))) return fail(502, "unreadable labels", getArgv, got.rc, null);
    const next = [...labels.filter((l) => !l.startsWith(THEME_PREFIX)), ...(req.theme ? [THEME_PREFIX + req.theme] : [])];
    // The CLI's --labels refuses an empty set and it has no remove or clear option, so the last label cannot go.
    if (next.length === 0) return fail(422, "the Jira CLI cannot remove a ticket's last label, so its theme cannot be cleared here", jira(d, "edit", req.key, "--labels", ""), null, null);
    argv = jira(d, "edit", req.key, "--labels", next.join(","));
    before = { labels: labels.filter((l) => l.startsWith(THEME_PREFIX)).join(",") };
    extra = { theme: req.theme, labels: next };
  }
  const r = await d.run(argv, WRITE_MS);
  if (r.rc !== 0) return fail(502, r.timedOut ? "jira write timed out" : "jira refused the write", argv, r.rc, before, r.stdout + r.stderr);
  // The mirror is incremental and read-only against Jira; it brings the ticket's file up to what Jira now says.
  const m = await d.run(jira(d, "mirror", "--root", d.mirrorDir), MIRROR_MS);
  const now = mirrorState(d.mirrorDir, req.key);
  const after = now ? (req.action === "jira-transition" ? { status: now.status } : { labels: now.labels.filter((l) => l.startsWith(THEME_PREFIX)).join(",") }) : null;
  return { status: 200, body: { ok: true, key: req.key, ...extra, mirror: m.rc === 0 ? "refreshed" : "stale" }, argv, rc: r.rc, before, after };
}
