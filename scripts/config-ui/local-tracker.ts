// local-tracker.ts — Roadmap and Kanban on the local tracker backend (TRACKER=local, no Jira). Every read and write goes through
// the tracker seam (scripts/lib/tracker.sh) as an argv child, never a shell string: the seam owns the store, its lock, the
// id check and the status ladder, and tracker.mjs owns the item parser. The route in server.ts adds the token gate, the write
// lock and the audit, as it does for a Jira card.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runChild, type ChildResult } from "./lock";
import { SECTOR_RE, STATUS_NAMES, type WriteResult } from "./jira-write";
// @ts-ignore -- plain ESM twin of the seam's normalisation, no type declarations
import { parseLocalItem } from "../lib/tracker.mjs";

type Env = Record<string, string | undefined>;
export type LocalItem = { id: string; title: string; status: string; type: string; fix_version: string; epic: string; sector: string };
export type LocalWriteReq =
  | { action: "tracker-transition"; key: string; status: string; value: string }
  | { action: "tracker-sector"; key: string; sector: string; value: string };

const TRACKER_SH = join(import.meta.dir, "..", "lib", "tracker.sh");
const READ_MS = 15_000, WRITE_MS = 30_000;
const MAX_SECTOR = 60;
// a local id is the store prefix (git config himmel.trackerPrefix, LOCAL by default) and a number; the seam checks it again
const ID_RE = /^[A-Z][A-Z0-9]*-\d+$/;

// run one seam verb (or a short sequence of them) with the local backend forced, so the resolver never picks Jira here.
const seamArgv = (script: string, args: string[]) => ["bash", "-c", `. "$1"; shift; ${script}`, "_", TRACKER_SH, ...args];
function seam(script: string, args: string[], env: Env, root: string, timeoutMs: number, onSpawn?: (pgid: number) => void): Promise<ChildResult> {
  return runChild(seamArgv(script, args), { cwd: root, env: { ...env, TRACKER: "local" }, timeoutMs, onSpawn });
}

// every item in the store, in the seam's id order; [] for an empty or absent store, null when the seam fails.
export async function readLocalItems(env: Env, root: string): Promise<LocalItem[] | null> {
  const r = await seam('_tracker_local_store && tracker_query', [], env, root, READ_MS);
  if (r.rc !== 0) return null;
  const [store, ...rows] = r.stdout.split("\n");
  const out: LocalItem[] = [];
  for (const row of rows) {
    const id = row.split("\t")[0];
    if (!ID_RE.test(id)) continue;
    try { out.push(parseLocalItem(readFileSync(join(store, `${id}.md`), "utf8")) as LocalItem); } catch { /* removed since the query */ }
  }
  return out;
}

export function parseLocalWrite(b: Record<string, unknown>): LocalWriteReq | { error: string } {
  const key = b.key;
  if (typeof key !== "string" || !ID_RE.test(key)) return { error: "key must be a local tracker id (LOCAL-<n>)" };
  const hasStatus = "status" in b, hasSector = "sector" in b;
  if (hasStatus === hasSector) return { error: "send exactly one of status or sector" };
  if (hasStatus) {
    const s = b.status;
    if (typeof s !== "string" || !Object.prototype.hasOwnProperty.call(STATUS_NAMES, s)) return { error: "unknown status column" };
    return { action: "tracker-transition", key, status: s, value: s };
  }
  const s = b.sector;
  if (typeof s !== "string" || s.length > MAX_SECTOR || !SECTOR_RE.test(s)) return { error: "sector must be a Sector name" };
  return { action: "tracker-sector", key, sector: s, value: s };
}

const fail = (status: number, error: string, argv: string[], rc: number | null, before: WriteResult["before"], output = ""): WriteResult =>
  ({ status, body: { error, output }, argv, rc, before, after: null, outcome: rc === null ? "error" : undefined });
// the seam's codes: 2 a refused name or status, 3 no such item, anything else a failure
const seamFail = (r: ChildResult, argv: string[], before: WriteResult["before"]): WriteResult =>
  r.rc === 2 ? fail(400, "the tracker refused the write", argv, r.rc, before, r.stderr)
    : r.rc === 3 ? fail(404, "no such local item", argv, r.rc, before, r.stderr)
      : fail(502, r.timedOut ? "tracker write timed out" : "tracker write failed", argv, r.rc, before, r.stdout + r.stderr);

async function getItem(key: string, env: Env, root: string, onSpawn?: (pgid: number) => void): Promise<{ r: ChildResult; item: LocalItem | null }> {
  const r = await seam('tracker_get "$@"', [key], env, root, READ_MS, onSpawn);
  let item: LocalItem | null = null;
  if (r.rc === 0) { try { item = JSON.parse(r.stdout); } catch { /* reported as a failure below */ } }
  return { r, item };
}

// A drop moves the item with --allow-back (a board drop may go left); the seam never moves an item out of Done or off the
// ladder, so the item read after the move decides: a status that stayed is a 409, not a silent success.
export async function applyLocalWrite(req: LocalWriteReq, d: { env: Env; root: string; onSpawn?: (pgid: number) => void }): Promise<WriteResult> {
  const transition = req.action === "tracker-transition";
  const verb = transition ? ["tracker_transition", req.key, STATUS_NAMES[req.status], "--allow-back"] : ["tracker_sector", req.key, req.sector];
  const argv = seamArgv('"$@"', verb);
  const was = await getItem(req.key, d.env, d.root, d.onSpawn);
  if (!was.item) return was.r.rc === 0 ? fail(502, "tracker get answered no item", argv, was.r.rc, null) : seamFail(was.r, argv, null);
  const before = transition ? { status: was.item.status } : { sector: was.item.sector };
  const r = await seam('"$@"', verb, d.env, d.root, WRITE_MS, d.onSpawn);
  if (r.rc !== 0) return seamFail(r, argv, before);
  const now = (await getItem(req.key, d.env, d.root, d.onSpawn)).item;
  const after = now ? (transition ? { status: now.status } : { sector: now.sector }) : null;
  if (transition && now?.status !== STATUS_NAMES[req.status]) {
    return { status: 409, body: { error: `the tracker kept ${req.key} at ${now?.status ?? "an unknown status"}`, output: "" }, argv, rc: r.rc, before, after };
  }
  const extra = transition ? { status: req.status, name: STATUS_NAMES[req.status] } : { sector: req.sector };
  return { status: 200, body: { ok: true, key: req.key, ...extra, backend: "local" }, argv, rc: r.rc, before, after };
}
