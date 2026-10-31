// the Kanban's write path. A drop moves a ticket to another status column and a sector select sets its Sector,
// both through the Jira CLI (never the REST API, never credentials in this process). The CLI resolves the name against the
// live option list and refuses an unknown one, so no list is kept here. Validation is here and runs before any child; the
// route in server.ts adds the token gate, the write lock and the audit.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { ChildResult } from "./lock";

export const KEY_RE = /^HIMMEL-\d+$/;
// a Sector option name: printable, and no leading "-" so the CLI never reads it as an option
export const SECTOR_RE = /^[^\s\-\x00-\x1f\x7f][^\x00-\x1f\x7f]*$/;
const MAX_SECTOR = 60;
// The board's bucket ids (roadmap.ts BUCKETS) to the workflow status names the Jira CLI's `transition` matches.
export const STATUS_NAMES: Record<string, string> = { todo: "To Do", prog: "In Progress", rev: "In Review", ci: "IN CI", done: "Done", wont: "wont do" };
const WRITE_MS = 30_000, MIRROR_MS = 60_000;

export type WriteReq =
  | { action: "jira-transition"; key: string; status: string; value: string }
  | { action: "jira-sector"; key: string; sector: string; value: string };

export function parseWrite(b: Record<string, unknown>): WriteReq | { error: string } {
  const key = b.key;
  if (typeof key !== "string" || !KEY_RE.test(key)) return { error: "key must match HIMMEL-<n>" };
  const hasStatus = "status" in b, hasSector = "sector" in b;
  if (hasStatus === hasSector) return { error: "send exactly one of status or sector" };
  if (hasStatus) {
    const s = b.status;
    if (typeof s !== "string" || !Object.prototype.hasOwnProperty.call(STATUS_NAMES, s)) return { error: "unknown status column" };
    return { action: "jira-transition", key, status: s, value: s };
  }
  const s = b.sector;
  // the Jira CLI has no way to clear a Sector, so a null or empty one is refused here rather than half-applied
  if (typeof s !== "string" || s.length > MAX_SECTOR || !SECTOR_RE.test(s)) return { error: "sector must be a Sector name" };
  return { action: "jira-sector", key, sector: s, value: s };
}

// A mirror file's current status name and Sector, or null when the ticket is not mirrored.
export function mirrorState(dir: string, key: string): { status: string; sector: string } | null {
  let txt: string;
  try { txt = readFileSync(join(dir, `${key}.md`), "utf8"); } catch { return null; }
  const fm = txt.split("---")[1] ?? "";
  const field = (name: string) => new RegExp(`^${name}:\\s*(.*)$`, "m").exec(fm)?.[1].trim();
  const parse = <T>(s: string | undefined, d: T): T => { try { return s === undefined ? d : JSON.parse(s); } catch { return d; } };
  const status = parse<unknown>(field("status"), "");
  const sector = parse<unknown>(field("sector"), "");
  return { status: typeof status === "string" ? status : "", sector: typeof sector === "string" ? sector : "" };
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
    argv = jira(d, "edit", req.key, "--sector", req.sector);
    before = { sector: was?.sector ?? "" };
    extra = { sector: req.sector };
  }
  const r = await d.run(argv, WRITE_MS);
  if (r.rc !== 0) return fail(502, r.timedOut ? "jira write timed out" : "jira refused the write", argv, r.rc, before, r.stdout + r.stderr);
  // The mirror is incremental and read-only against Jira; it brings the ticket's file up to what Jira now says.
  const m = await d.run(jira(d, "mirror", "--root", d.mirrorDir), MIRROR_MS);
  const now = mirrorState(d.mirrorDir, req.key);
  const after = now ? (req.action === "jira-transition" ? { status: now.status } : { sector: now.sector }) : null;
  return { status: 200, body: { ok: true, key: req.key, ...extra, mirror: m.rc === 0 ? "refreshed" : "stale" }, argv, rc: r.rc, before, after };
}
