// board.ts — the console board for the Fleet page: GET /api/agui/board (the himmel.board/1 JSON from board.mjs --json)
// and GET /api/agui/brief (a leg doc, so a brief link stays inside the UI). Read-only: board.mjs writes only
// into a private temp dir, and a doc is found by NAME under the handover root, never by a path from the request.
//
// ponytail: each console's board is cached BOARD_TTL_MS and one run serves every poller, because board.mjs reads gh,
// Jira and transcripts (seconds); upgrade path: have the console publish the JSON beside its doc and read that.
import { execFile } from "node:child_process";
import { mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { redact } from "../../handover/console-kit/redact.mjs";

export const BOARD_TTL_MS = 30_000;
export const BOARD_TIMEOUT_MS = 90_000;
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$/;
export const validName = (s: string | null): s is string => !!s && NAME.test(s) && !s.includes("..");

// <root>/<user>/<repo bucket>/<name>.md — the handover layout. A name that matches no doc is null.
export async function findDoc(root: string, name: string): Promise<string | null> {
  if (!root || !validName(name)) return null;
  try {
    for (const user of await readdir(root, { withFileTypes: true })) {
      if (!user.isDirectory()) continue;
      for (const bucket of await readdir(join(root, user.name), { withFileTypes: true })) {
        if (!bucket.isDirectory()) continue;
        const p = join(root, user.name, bucket.name, `${name}.md`);
        if ((await stat(p).catch(() => null))?.isFile()) return p;
      }
    }
  } catch { /* no handover root */ }
  return null;
}

// every string in the model passes the console's own redactor (nonces, lock tokens, keys), then the server's.
export const scrub = (v: unknown, extra: (v: unknown) => unknown = (x) => x): unknown =>
  extra(JSON.parse(JSON.stringify(v), (_k, x) => (typeof x === "string" ? redact(x) : x)));

type Entry = { at: number; p: Promise<{ body: unknown } | { error: string }> };
const cache = new Map<string, Entry>();

export function readBoard(o: { script: string; doc: string; checkout: string; env: NodeJS.ProcessEnv; now: number; ttlMs?: number; timeoutMs?: number }): Promise<{ body: unknown } | { error: string }> {
  const hit = cache.get(o.doc);
  if (hit && o.now - hit.at < (o.ttlMs ?? BOARD_TTL_MS)) return hit.p;
  const p = (async () => {
    const dir = await mkdtemp(join(tmpdir(), "agui-board-"));
    try {
      const out = join(dir, "board.json");
      await new Promise<void>((ok, fail) => execFile("node", [o.script, "--doc", o.doc, "--json", out, "--out", join(dir, "board.html"), "--repo", o.checkout],
        { env: o.env, timeout: o.timeoutMs ?? BOARD_TIMEOUT_MS, maxBuffer: 1 << 20 }, (e, _so, se) => (e ? fail(new Error(String(se || e.message).trim().split("\n").pop())) : ok())));
      return { body: JSON.parse(await readFile(out, "utf8")) as unknown };
    } catch (e) {
      cache.delete(o.doc); // a failure is not cached: the next poll retries
      return { error: String((e as Error).message ?? e) };
    } finally { rm(dir, { recursive: true, force: true }).catch(() => undefined); }
  })();
  cache.set(o.doc, { at: o.now, p });
  return p;
}
