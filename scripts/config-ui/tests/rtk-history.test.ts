// rtk history reader (build spec 0.4 d): joins hook_decisions.tool_use_id to Bash call ids, read-only.
import { test, expect, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as sources from "../health-sources";

const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });
const SCHEMA = `CREATE TABLE hook_decisions (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, session_id TEXT NOT NULL, tool_use_id TEXT NOT NULL,
  project_path TEXT DEFAULT '', raw_cmd TEXT NOT NULL, decision TEXT NOT NULL, rewritten_cmd TEXT, rtk_version TEXT NOT NULL)`;

function home(rows: [string, string, string, string | null][] = [], extra = 0) {
  const dir = mkdtempSync(join(tmpdir(), "rtk-history-")); dirs.push(dir);
  mkdirSync(join(dir, ".local", "share", "rtk"), { recursive: true });
  const db = new Database(join(dir, ".local", "share", "rtk", "history.db"));
  db.run(SCHEMA);
  const add = db.prepare("INSERT INTO hook_decisions (timestamp, session_id, tool_use_id, raw_cmd, decision, rewritten_cmd, rtk_version) VALUES ('t', 's', ?, ?, ?, ?, '1.1.0')");
  db.transaction(() => {
    for (const r of rows) add.run(...r);
    for (let i = 0; i < extra; i++) add.run(`toolu_bulk${i}`, "ls", "allow", "rtk ls");
  })();
  db.close();
  return dir;
}

test("matched, unmatched and duplicate call ids; the rtk path is a rewrite or an rtk command", async () => {
  const { rtkHistory } = await import("../rtk-history");
  const dir = home([
    ["toolu_a", "git status", "allow", "rtk git status"],
    ["toolu_b", "rtk git log -1", "allow", null],
    ["toolu_c", "cat /etc/SECRET-RAW", "deny", null],
    ["toolu_c", "cat /etc/SECRET-RAW", "allow", null],
  ]);
  const r = rtkHistory({ HOME: dir })(["toolu_a", "toolu_b", "toolu_c", "toolu_z"]);
  expect(r.state).toBe("ok");
  expect(r.duplicates).toBe(1);
  expect([...r.byId]).toEqual([["toolu_a", { path: "rtk", deny: false }], ["toolu_b", { path: "rtk", deny: false }], ["toolu_c", { path: "bash", deny: true }]]);
  expect(JSON.stringify([...r.byId])).not.toContain("SECRET");
});

test("ids are queried in chunks, so a long window stays under the SQLite variable limit", async () => {
  const { rtkHistory } = await import("../rtk-history");
  const ids = Array.from({ length: 1200 }, (_, i) => `toolu_bulk${i}`);
  const r = rtkHistory({ HOME: home([], 1200) })(ids);
  expect(r).toMatchObject({ state: "ok", duplicates: 0 });
  expect(r.byId.size).toBe(1200);
});

test("a missing database is absent and an unreadable one is error, never zero rtk", async () => {
  const { rtkHistory } = await import("../rtk-history");
  const empty = mkdtempSync(join(tmpdir(), "rtk-history-none-")); dirs.push(empty);
  expect(rtkHistory({ HOME: empty })(["toolu_a"]).state).toBe("absent");
  mkdirSync(join(empty, ".local", "share", "rtk"), { recursive: true });
  writeFileSync(join(empty, ".local", "share", "rtk", "history.db"), "not a database");
  expect(rtkHistory({ HOME: empty })(["toolu_a"]).state).toBe("error");
});

test("the page reader joins the station's history.db by default", () => {
  const ledgers = { HIMMEL_EVAL_RUNS_LEDGER: "/no/evals", HIMMEL_WORKER_SESSION_FAILURES_LEDGER: "/no/failures" };
  const withDb = home([["toolu_a", "git status", "allow", "rtk git status"]]);
  expect((sources as any).readToolHealth({ ...ledgers, HOME: withDb }, new URLSearchParams(), 0).bash.rtk.state).toBe("ok");
  const without = mkdtempSync(join(tmpdir(), "rtk-history-none-")); dirs.push(without);
  expect((sources as any).readToolHealth({ ...ledgers, HOME: without }, new URLSearchParams(), 0).bash.rtk).toMatchObject({ state: "absent", matched: null });
});
