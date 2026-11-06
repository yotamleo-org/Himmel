// board.ts — the chief board for the Fleet page: GET /api/agui/board (the himmel.board/1 JSON from board.mjs --json)
// and GET /api/agui/brief (a worker doc, so a brief link stays inside the UI). Read-only: this module only reads
// files, and a doc is found by NAME under the handover root, never by a path from the request.
//
// The chief writes the board JSON beside its doc (board.mjs, <doc>.board.json); readBoardFile serves that file, re-read
// whenever its mtime moves, so a change reaches the next poll. A chief with no such file has no board: the routes say so
// and run nothing (the board reads gh, Jira and transcripts: only the chief's own render pays for that).
import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { join, sep } from "node:path";
import { readSections } from "../../handover/chief-kit/board-section.mjs";
import { redact } from "../../handover/chief-kit/redact.mjs";

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

// <doc>.md → <doc>.board.json. null when the chief has not written one (or it does not parse): the caller reports no board.
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

// The chief's sections: a thin wrapper over board-section.mjs's readSections, which owns the sidecar path, the mtime+size cache and the
// 64 KB / parse bounds, so this file never opens or names the sidecar (I9). `error` is set for an oversize or unparseable file.
export type Section = { id: string; title: string; body: string; tone: "info" | "warn" | "ok"; order: number };
export const readSectionsFile = (doc: string): Promise<{ sections: Section[]; error?: string }> => readSections(doc);

// every string in the model passes the chief's own redactor (nonces, lock tokens, keys), then the server's.
export const scrub = (v: unknown, extra: (v: unknown) => unknown = (x) => x): unknown =>
  extra(JSON.parse(JSON.stringify(v), (_k, x) => (typeof x === "string" ? redact(x) : x)));
