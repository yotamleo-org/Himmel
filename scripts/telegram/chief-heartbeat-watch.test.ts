// scripts/telegram/chief-heartbeat-watch.test.ts
// Hermetic: fixture dirs only, never the live consoles/ inbox.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  DEFAULT_STALE_MS,
  censusSessionAlive,
  checkStaleHeartbeats,
  parseHeartbeat,
  type AlertedState,
} from "./chief-heartbeat-watch";

let tmp: string;
beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), "chief-hb-watch-")); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

// --- parseHeartbeat -------------------------------------------------------

test("parseHeartbeat reads a well-formed waiting line", () => {
  const hb = parseHeartbeat("hb=1758000000 pid=4242 key=abc123 tick=ok state=waiting");
  expect(hb).toEqual({ hb: 1758000000, pid: 4242, key: "abc123", tick: "ok", state: "waiting", reason: undefined });
});

test("parseHeartbeat reads an exited line carrying exit=<reason>", () => {
  const hb = parseHeartbeat("hb=1758000000 pid=4242 key=abc123 tick=ok state=exited exit=wake-telegram");
  expect(hb?.state).toBe("exited");
  expect(hb?.reason).toBe("wake-telegram");
});

test("parseHeartbeat returns null for a malformed line", () => {
  expect(parseHeartbeat("not a heartbeat")).toBeNull();
  expect(parseHeartbeat("")).toBeNull();
  expect(parseHeartbeat("hb=abc pid=1 key=x tick=ok state=waiting")).toBeNull();
});

// --- checkStaleHeartbeats --------------------------------------------------

const writeHb = (dir: string, name: string, line: string) => {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${name}.md.wait`), line + "\n");
};

test("a stale waiting heartbeat plus a live console gives exactly one alert", async () => {
  const chiefs = join(tmp, "consoles");
  const nowSec = 1_758_000_600;
  writeHb(chiefs, "HIMMEL-A-chief", `hb=${nowSec - 600} pid=99 key=x tick=ok state=waiting`);
  const alerted: AlertedState = new Map();
  const alerts: Array<[string, number]> = [];
  const run = () => checkStaleHeartbeats(
    tmp, nowSec * 1000, DEFAULT_STALE_MS, alerted,
    async () => true,
    async (name, ageSec) => { alerts.push([name, ageSec]); },
  );
  await run();
  expect(alerts).toEqual([["HIMMEL-A-chief", 600]]);

  // a second check in the same episode gives none
  await run();
  expect(alerts.length).toBe(1);
});

test("a fresh heartbeat gives no alert and re-arms the episode", async () => {
  const chiefs = join(tmp, "consoles");
  const nowSec = 1_758_000_600;
  writeHb(chiefs, "HIMMEL-B-chief", `hb=${nowSec - 1} pid=99 key=x tick=ok state=waiting`);
  const alerted: AlertedState = new Map();
  const alerts: Array<[string, number]> = [];
  await checkStaleHeartbeats(
    tmp, nowSec * 1000, DEFAULT_STALE_MS, alerted,
    async () => true,
    async (name, ageSec) => { alerts.push([name, ageSec]); },
  );
  expect(alerts).toEqual([]);
});

test("state=exited gives no alert even when old", async () => {
  const chiefs = join(tmp, "consoles");
  const nowSec = 1_758_000_600;
  writeHb(chiefs, "HIMMEL-C-chief", `hb=${nowSec - 99999} pid=99 key=x tick=ok state=exited exit=wake-tick`);
  const alerted: AlertedState = new Map();
  const alerts: Array<[string, number]> = [];
  await checkStaleHeartbeats(
    tmp, nowSec * 1000, DEFAULT_STALE_MS, alerted,
    async () => true,
    async (name, ageSec) => { alerts.push([name, ageSec]); },
  );
  expect(alerts).toEqual([]);
});

test("a dead console process gives no alert despite a stale waiting heartbeat", async () => {
  const chiefs = join(tmp, "consoles");
  const nowSec = 1_758_000_600;
  writeHb(chiefs, "HIMMEL-D-chief", `hb=${nowSec - 600} pid=99 key=x tick=ok state=waiting`);
  const alerted: AlertedState = new Map();
  const alerts: Array<[string, number]> = [];
  await checkStaleHeartbeats(
    tmp, nowSec * 1000, DEFAULT_STALE_MS, alerted,
    async () => false,
    async (name, ageSec) => { alerts.push([name, ageSec]); },
  );
  expect(alerts).toEqual([]);
});

test("a re-gone-stale episode after a fresh re-arm alerts again", async () => {
  const chiefs = join(tmp, "consoles");
  const nowSec = 1_758_000_600;
  const file = join(chiefs, "HIMMEL-E-chief.md.wait");
  mkdirSync(chiefs, { recursive: true });
  const alerted: AlertedState = new Map();
  const alerts: Array<[string, number]> = [];
  const run = (nowMs: number) => checkStaleHeartbeats(
    tmp, nowMs, DEFAULT_STALE_MS, alerted,
    async () => true,
    async (name, ageSec) => { alerts.push([name, ageSec]); },
  );
  writeFileSync(file, `hb=${nowSec - 600} pid=99 key=x tick=ok state=waiting\n`);
  await run(nowSec * 1000);
  expect(alerts.length).toBe(1);
  writeFileSync(file, `hb=${nowSec} pid=99 key=x tick=ok state=waiting\n`);   // fresh again
  await run(nowSec * 1000);
  expect(alerts.length).toBe(1);
  writeFileSync(file, `hb=${nowSec - 700} pid=99 key=x tick=ok state=waiting\n`);   // stale again
  await run((nowSec + 100) * 1000);
  expect(alerts.length).toBe(2);
});

test("a malformed heartbeat file is never an alert", async () => {
  const chiefs = join(tmp, "consoles");
  writeHb(chiefs, "HIMMEL-F-chief", "garbage, not a heartbeat line");
  const alerted: AlertedState = new Map();
  const alerts: Array<[string, number]> = [];
  await checkStaleHeartbeats(
    tmp, Date.now(), DEFAULT_STALE_MS, alerted,
    async () => true,
    async (name, ageSec) => { alerts.push([name, ageSec]); },
  );
  expect(alerts).toEqual([]);
});

test("a missing chiefs directory is a no-op, not a throw", async () => {
  const alerted: AlertedState = new Map();
  await expect(checkStaleHeartbeats(
    join(tmp, "does-not-exist"), Date.now(), DEFAULT_STALE_MS, alerted,
    async () => true,
    async () => {},
  )).resolves.toBeUndefined();
});

test("a file that is not a .md.wait heartbeat is ignored", async () => {
  const chiefs = join(tmp, "consoles");
  mkdirSync(chiefs, { recursive: true });
  writeFileSync(join(chiefs, "HIMMEL-G-chief.md"), "- 04:00 [telegram from=1 chat=2] hi\n");
  const alerted: AlertedState = new Map();
  const alerts: Array<[string, number]> = [];
  await checkStaleHeartbeats(
    tmp, Date.now(), DEFAULT_STALE_MS, alerted,
    async () => true,
    async (name, ageSec) => { alerts.push([name, ageSec]); },
  );
  expect(alerts).toEqual([]);
});

// --- censusSessionAlive: fixture /proc + PATH-stubbed pgrep, mirrors
// scripts/lanes/test-ceiling-conformance.sh's fixture recipe (never a real
// process scan).

const mkcmdline = (procDir: string, pid: number, argv: string[]) => {
  mkdirSync(join(procDir, String(pid)), { recursive: true });
  writeFileSync(join(procDir, String(pid), "cmdline"), argv.map((a) => a + "\0").join(""));
};

const pgrepXStub = (binDir: string, pids: number[]) => {
  mkdirSync(binDir, { recursive: true });
  const script = `#!/usr/bin/env bash\nif [ "$1" = "-x" ]; then printf '%s\\n' ${pids.join(" ")}; exit 0; fi\nexit 1\n`;
  writeFileSync(join(binDir, "pgrep"), script, { mode: 0o755 });
};

test("censusSessionAlive is true for a live claude session named for this console", async () => {
  const proc = join(tmp, "proc");
  const bin = join(tmp, "bin");
  mkcmdline(proc, 501, ["claude", "--model", "claude-sonnet-5", "-n", "HIMMEL-nextleg-2026-09-23E-chief", "work"]);
  pgrepXStub(bin, [501]);
  const alive = await censusSessionAlive("HIMMEL-nextleg-2026-09-23E-chief", {
    env: { ...process.env, CLAUDE_SESSIONS_PROC: proc, PATH: `${bin}:${process.env.PATH}` },
  });
  expect(alive).toBe(true);
});

test("censusSessionAlive is false when no live session carries that name", async () => {
  const proc = join(tmp, "proc");
  const bin = join(tmp, "bin");
  mkcmdline(proc, 502, ["claude", "--model", "claude-sonnet-5", "-n", "some-other-chief", "work"]);
  pgrepXStub(bin, [502]);
  const alive = await censusSessionAlive("HIMMEL-nextleg-2026-09-23E-chief", {
    env: { ...process.env, CLAUDE_SESSIONS_PROC: proc, PATH: `${bin}:${process.env.PATH}` },
  });
  expect(alive).toBe(false);
});

test("censusSessionAlive is false (never throws) when the census itself fails", async () => {
  const bin = join(tmp, "bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, "pgrep"), "#!/usr/bin/env bash\nexit 2\n", { mode: 0o755 });
  const alive = await censusSessionAlive("anything", {
    env: { ...process.env, CLAUDE_SESSIONS_PROC: join(tmp, "no-such-proc"), PATH: `${bin}:${process.env.PATH}` },
  });
  expect(alive).toBe(false);
});

test("censusSessionAlive is false on a degraded scan even when a matching row printed (rc=3, HIMMEL-3510 codex-1)", async () => {
  // One live pid the census CAN read (matches consoleName) plus one it
  // CANNOT (unreadable cmdline) makes claude_sessions() print the matching
  // row and still return rc=3 (degraded) — that rc must win, never the row.
  const proc = join(tmp, "proc");
  const bin = join(tmp, "bin");
  mkcmdline(proc, 501, ["claude", "--model", "claude-sonnet-5", "-n", "HIMMEL-nextleg-2026-09-23E-chief", "work"]);
  mkdirSync(join(proc, "503"), { recursive: true });
  writeFileSync(join(proc, "503", "cmdline"), "unreadable", { mode: 0o000 });
  pgrepXStub(bin, [501, 503]);
  const alive = await censusSessionAlive("HIMMEL-nextleg-2026-09-23E-chief", {
    env: { ...process.env, CLAUDE_SESSIONS_PROC: proc, PATH: `${bin}:${process.env.PATH}` },
  });
  expect(alive).toBe(false);
});

test("censusSessionAlive kills a hung child at the timeout and returns false without hanging the caller (HIMMEL-3514)", async () => {
  const proc = join(tmp, "proc"); // must EXIST so claude_sessions() takes the `pgrep -x claude` path, not the -af lossy fallback
  const bin = join(tmp, "bin");
  mkdirSync(proc, { recursive: true });
  mkdirSync(bin, { recursive: true });
  // pgrep itself hangs — claude_sessions() never returns, so without a
  // timeout around the Bun.spawn this await (and this test) never resolves.
  writeFileSync(join(bin, "pgrep"), "#!/usr/bin/env bash\nif [ \"$1\" = \"-x\" ]; then sleep 30; fi\nexit 1\n", { mode: 0o755 });
  const start = Date.now();
  const alive = await censusSessionAlive("anything", {
    env: { ...process.env, CLAUDE_SESSIONS_PROC: proc, PATH: `${bin}:${process.env.PATH}` },
    timeoutMs: 200,
  });
  const elapsedMs = Date.now() - start;
  expect(alive).toBe(false);
  expect(elapsedMs).toBeLessThan(5_000);
});
