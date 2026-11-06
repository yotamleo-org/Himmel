// GET /api/roadmap/history?key=<KEY> — the Board drawer's stage history: the status moves of one ticket, read through the Jira CLI's
// `history <KEY> --json` (a stub here; nothing reaches live Jira). Read-only: it takes no lock, writes no audit row, and a failed
// read answers an error, never an empty list.
import { test, expect, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const JIRA = join(import.meta.dir, "stub-jira.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot(extra: Record<string, string> = {}, mirrors: string[] = ["HIMMEL"]) {
  const dir = mkdtempSync(join(tmpdir(), "roadmap-history-"));
  const home = join(dir, "home"), root = join(dir, "root"), log = join(dir, "jira.log"), envLog = join(dir, "env.log"), own = join(dir, "checkout");
  mkdirSync(home); mkdirSync(root); mkdirSync(own);
  for (const k of mirrors) mkdirSync(join(home, ".himmel", "state", "jira-mirror", k), { recursive: true });
  const s = startServer({ onIdle: () => {},
    port: 0, token: TOKEN, root: own,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_JIRA_CLI: JIRA, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root,
      STUB_JIRA_LOG: log, STUB_JIRA_ENV_LOG: envLog, ...extra },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  const lines = (f: string) => (existsSync(f) ? readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
  const get = (q: string, o: { token?: string | null; method?: string } = {}) => fetch(`http://127.0.0.1:${s.port}/api/roadmap/history${q}`, {
    method: o.method ?? "GET", headers: o.token === null ? {} : { "x-himmel-token": o.token ?? TOKEN } });
  return { home, get, calls: () => lines(log) as string[][], envs: () => lines(envLog) as { verb: string; key: string | null }[],
    audit: () => existsSync(join(home, ".himmel", "state", "config-ui", "actions.jsonl")) };
}

test("a key's status moves come back oldest first, and no other field's change is among them", async () => {
  const b = boot();
  const r = await b.get("?key=HIMMEL-2");
  expect(r.status).toBe(200);
  const j = await r.json();
  expect(j.key).toBe("HIMMEL-2");
  expect(j.events).toEqual([
    { at: "2026-10-27T09:00:00.000+0000", who: "Bot", from: "To Do", to: "In Progress" },
    { at: "2026-10-28T08:00:00.000+0000", who: "Bot", from: "In Progress", to: "In Review" },
  ]); // the stub's Fix Version change is not a stage move
  expect(b.calls()).toEqual([["history", "HIMMEL-2", "--json"]]); // one read, the verb alone
  expect(b.envs()[0]).toMatchObject({ verb: "history", key: "HIMMEL" }); // run as the key's own project
  expect(b.audit()).toBe(false); // a read leaves no write audit row
});

test("a non-HIMMEL key reads its own project", async () => {
  const b = boot({}, ["HIMMEL", "SALUS"]);
  const r = await b.get("?key=SALUS-12");
  expect(r.status).toBe(200);
  expect(b.calls()).toEqual([["history", "SALUS-12", "--json"]]);
  expect(b.envs()[0].key).toBe("SALUS");
});

test("a key that is not <PROJECT>-<n>, or whose project is not on the Board, is refused with 400 and runs nothing", async () => {
  const b = boot();
  for (const q of ["", "?key=", "?key=HIMMEL", "?key=himmel-2", "?key=HIMMEL-2%20--x", "?key=HIMMEL-2;ls", "?key=--json", "?key=HIMMEL-2&key=HIMMEL-3", "?key=OTHER-5"]) {
    const r = await b.get(q);
    expect([q, r.status]).toEqual([q, 400]);
  }
  expect(b.calls()).toEqual([]);
});

test("a failed read answers 502 with an error and no events, never an empty list", async () => {
  const failed = await boot({ STUB_JIRA_FAIL: "history" }).get("?key=HIMMEL-2");
  expect(failed.status).toBe(502);
  const j = await failed.json();
  expect(j.error).toBe("history unavailable");
  expect(j).not.toHaveProperty("events");
  const garbled = await boot({ STUB_JIRA_HISTORY_RAW: "not json" }).get("?key=HIMMEL-2"); // an answer that is not the changelog is also a failed read
  expect(garbled.status).toBe(502);
  expect(await garbled.json()).toMatchObject({ error: "history unavailable" });
  for (const raw of ["[{}]", '[{"created":"2026-10-27T09:00:00.000+0000"}]', '[{"created":"t","items":[null]}]', "[1]"]) { // an entry that is not a changelog entry is no more a read that worked than text is
    const r = await boot({ STUB_JIRA_HISTORY_RAW: raw }).get("?key=HIMMEL-2");
    expect([raw, r.status]).toEqual([raw, 502]);
  }
});

test("a ticket with no status move answers an empty list: that is a read that worked", async () => {
  const r = await boot({ STUB_JIRA_HISTORY_RAW: "[]" }).get("?key=HIMMEL-2");
  expect(r.status).toBe(200);
  expect(await r.json()).toMatchObject({ key: "HIMMEL-2", events: [] });
});

test("the route is token-gated and GET-only", async () => {
  const b = boot();
  expect((await b.get("?key=HIMMEL-2", { token: null })).status).toBe(401);
  expect((await b.get("?key=HIMMEL-2", { method: "POST" })).status).toBe(405);
  expect(b.calls()).toEqual([]);
});
