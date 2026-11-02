// rtk-history.ts — rtk's ~/.local/share/rtk/history.db, opened read-only, joined to Bash call ids
// (build spec 0.4 d). hook_decisions.tool_use_id is the join key; parse_failures has no call id,
// so rtk filter failures stay out (slice B). A call took the rtk path when the hook rewrote it or the
// command itself starts with "rtk ", but "rtk proxy" runs the raw command, so it is the bash path. Only the path and a deny flag leave here, never a command.
import { Database } from "bun:sqlite";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
export type RtkJoin = { state: "ok" | "absent" | "error"; byId: Map<string, { path: "rtk" | "bash"; deny: boolean }>; duplicates: number };

export type RtkCoverage = { state: "ok" | "absent" | "error"; sessions: Map<string, number> };

const CHUNK = 500; // under SQLite's bound-variable limit

export function rtkHistory(env: Env) {
  const file = join(env.HOME || homedir(), ".local", "share", "rtk", "history.db");
  const join_ = (ids: string[]): RtkJoin => {
    const byId: RtkJoin["byId"] = new Map();
    if (!existsSync(file)) return { state: "absent", byId, duplicates: 0 };
    let db: Database | undefined;
    try {
      db = new Database(file, { readonly: true });
      const rows = new Map<string, number>();
      for (let i = 0; i < ids.length; i += CHUNK) {
        const chunk = ids.slice(i, i + CHUNK);
        const q = db.query(`SELECT tool_use_id AS id, decision, (rewritten_cmd IS NOT NULL AND rewritten_cmd NOT LIKE 'rtk proxy %') OR (raw_cmd LIKE 'rtk %' AND raw_cmd NOT LIKE 'rtk proxy %') AS rtk FROM hook_decisions WHERE tool_use_id IN (${chunk.map(() => "?").join(",")})`);
        for (const r of q.all(...chunk) as { id: string; decision: string; rtk: number }[]) {
          rows.set(r.id, (rows.get(r.id) || 0) + 1);
          const prev = byId.get(r.id);
          byId.set(r.id, { path: prev?.path === "rtk" || r.rtk ? "rtk" : "bash", deny: !!prev?.deny || r.decision === "deny" });
        }
      }
      return { state: "ok", byId, duplicates: [...rows.values()].filter((n) => n > 1).length };
    } catch {
      return { state: "error", byId: new Map(), duplicates: 0 };
    } finally { db?.close(); }
  };
  // The sessions rtk saw in a UTC day window (first..last, inclusive) and their Bash calls, so the page can say which have no digest.
  // timestamp is ISO text, so a plain range compare on the day prefixes uses the index; "~" sorts after every time-of-day.
  const coverage = (first: string, last: string): RtkCoverage => {
    if (!existsSync(file)) return { state: "absent", sessions: new Map() };
    let db: Database | undefined;
    try {
      db = new Database(file, { readonly: true });
      const rows = db.query("SELECT session_id AS id, COUNT(*) AS n FROM hook_decisions WHERE timestamp >= ? AND timestamp <= ? GROUP BY session_id").all(first, `${last}~`) as { id: string; n: number }[];
      return { state: "ok", sessions: new Map(rows.map((r) => [r.id, r.n])) };
    } catch {
      return { state: "error", sessions: new Map() };
    } finally { db?.close(); }
  };
  return Object.assign(join_, { coverage });
}
