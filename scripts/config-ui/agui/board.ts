// board.ts — the console board for the Fleet page: GET /api/agui/board (the himmel.board/1 JSON from board.mjs --json)
// and GET /api/agui/brief (a leg doc, so a brief link stays inside the UI). Read-only: board.mjs writes only
// into a private temp dir, and a doc is found by NAME under the handover root, never by a path from the request.
//
// The console writes the board JSON beside its doc (board.mjs, <doc>.board.json); readBoardFile serves that file, re-read
// whenever its mtime moves, so a change reaches the next poll with no rebuild.
// ponytail: with no such file the board is built by running board.mjs, cached BOARD_TTL_MS and shared by every poller
// (it reads gh, Jira and transcripts: seconds); retire this fallback once every console has written the file.
import { execFile } from "node:child_process";
import { mkdtemp, readdir, readFile, realpath, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { redact } from "../../handover/console-kit/redact.mjs";

export const BOARD_TTL_MS = 30_000;
export const BOARD_TIMEOUT_MS = 90_000;
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$/;
export const validName = (s: string | null): s is string => !!s && NAME.test(s) && !s.includes("..");

// <root>/<user>/<repo bucket>/<name>.md — the handover layout. A name that matches no doc is null,
// and so is a doc whose symlink resolves outside the root.
export async function findDoc(root: string, name: string): Promise<string | null> {
  if (!root || !validName(name)) return null;
  try {
    const real = await realpath(root);
    for (const user of await readdir(root, { withFileTypes: true })) {
      if (!user.isDirectory()) continue;
      for (const bucket of await readdir(join(root, user.name), { withFileTypes: true })) {
        if (!bucket.isDirectory()) continue;
        const p = join(root, user.name, bucket.name, `${name}.md`);
        if (!(await stat(p).catch(() => null))?.isFile()) continue;
        const canon = await realpath(p);
        if (canon.startsWith(real + sep)) return canon;
      }
    }
  } catch { /* no handover root */ }
  return null;
}

// <doc>.md → <doc>.board.json. null when the console has not written one (or it does not parse): the caller builds instead.
const fileCache = new Map<string, { mtimeMs: number; size: number; body: unknown }>();
export async function readBoardFile(doc: string): Promise<{ body: unknown } | null> {
  const p = doc.replace(/\.md$/, "") + ".board.json";
  try {
    const st = await stat(p);
    if (!st.isFile()) return null;
    const hit = fileCache.get(p);
    if (hit && hit.mtimeMs === st.mtimeMs && hit.size === st.size) return { body: hit.body };
    const body = JSON.parse(await readFile(p, "utf8")) as unknown;
    fileCache.set(p, { mtimeMs: st.mtimeMs, size: st.size, body });
    return { body };
  } catch { return null; }
}

// every string in the model passes the console's own redactor (nonces, lock tokens, keys), then the server's.
export const scrub = (v: unknown, extra: (v: unknown) => unknown = (x) => x): unknown =>
  extra(JSON.parse(JSON.stringify(v), (_k, x) => (typeof x === "string" ? redact(x) : x)));

// `at` is null while the build is pending (every poll shares it), then the time it finished.
type Entry = { at: number | null; p: Promise<{ body: unknown } | { error: string }> };
const cache = new Map<string, Entry>();

export function readBoard(o: { script: string; doc: string; checkout: string; env: NodeJS.ProcessEnv; now: number; ttlMs?: number; timeoutMs?: number }): Promise<{ body: unknown } | { error: string }> {
  const hit = cache.get(o.doc);
  if (hit && (hit.at === null || o.now - hit.at < (o.ttlMs ?? BOARD_TTL_MS))) return hit.p;
  const started = Date.now();
  const p = (async () => {
    let dir = "";
    try {
      dir = await mkdtemp(join(tmpdir(), "agui-board-"));
      const out = join(dir, "board.json");
      await new Promise<void>((ok, fail) => execFile("node", [o.script, "--doc", o.doc, "--json", out, "--out", join(dir, "board.html"), "--repo", o.checkout],
        { env: o.env, timeout: o.timeoutMs ?? BOARD_TIMEOUT_MS, maxBuffer: 1 << 20 }, (e, _so, se) => (e ? fail(new Error(String(se || e.message).trim().split("\n").pop())) : ok())));
      const body = JSON.parse(await readFile(out, "utf8")) as unknown;
      const e = cache.get(o.doc);
      if (e) e.at = o.now + (Date.now() - started); // the TTL runs from when the build finished
      return { body };
    } catch (e) {
      cache.delete(o.doc); // a failure is not cached: the next poll retries
      return { error: String((e as Error).message ?? e) };
    } finally { if (dir) rm(dir, { recursive: true, force: true }).catch(() => undefined); }
  })();
  cache.set(o.doc, { at: null, p });
  return p;
}
