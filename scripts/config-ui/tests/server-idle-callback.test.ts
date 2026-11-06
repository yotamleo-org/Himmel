// startServer's default idle action is process.exit(0). A config-ui test that starts a server and never reaches stop() (a hung
// row, a timed-out hook) would, once the idle time passes, end the whole bun run with exit 0 and no summary line: CI printed PASS
// over failing rows. Every test passes an idle callback (a do-nothing `onIdle`) or `noIdle`, so the default never runs.
import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const HERE = import.meta.dir;
const SERVER = join(HERE, "../server.ts");
const SELF = "server-idle-callback.test.ts";

// The 1-based line of every `startServer(` call in src whose argument has no onIdle or noIdle. A bare-identifier argument
// (`startServer(opts)`) is judged by the `const opts = ...;` statement that defines it.
function callsWithoutIdleCallback(src: string): number[] {
  const bad: number[] = [];
  for (const m of src.matchAll(/\bstartServer\(/g)) {
    const lineStart = src.lastIndexOf("\n", m.index) + 1;
    if (/^\s*(\/\/|\*)/.test(src.slice(lineStart, m.index))) continue; // a comment or a quoted title
    let depth = 0, i = m.index! + "startServer".length;
    for (; i < src.length; i++) {
      if (src[i] === "(") depth++;
      else if (src[i] === ")" && --depth === 0) break;
    }
    const arg = src.slice(m.index! + "startServer(".length, i).trim();
    let judged = arg;
    if (/^[A-Za-z_$][\w$]*$/.test(arg)) {
      const def = src.search(new RegExp(`\\bconst ${arg.replace(/\$/g, "\\$")}\\b`));
      judged = def < 0 ? "" : src.slice(def, src.indexOf(";\n", def));
    }
    if (!/\b(onIdle|noIdle)\b/.test(judged)) bad.push(src.slice(0, m.index).split("\n").length);
  }
  return bad;
}

test("the scan flags a call with no idle callback, accepts onIdle and noIdle, follows an identifier argument, skips comments", () => {
  expect(callsWithoutIdleCallback(`const s = startServer({ port: 0, token: T });`)).toEqual([1]);
  expect(callsWithoutIdleCallback(`const s = startServer({ port: 0, onIdle: () => {} });`)).toEqual([]);
  expect(callsWithoutIdleCallback(`\nconst s = startServer({\n  port: 0,\n  noIdle: true,\n});`)).toEqual([]);
  expect(callsWithoutIdleCallback(`const opts = { port: 0 };\nconst s = startServer(opts);\n`)).toEqual([2]);
  expect(callsWithoutIdleCallback(`const opts = { port: 0, onIdle: () => {} };\nconst s = startServer(opts);\n`)).toEqual([]);
  expect(callsWithoutIdleCallback(`// startServer(x) is quoted here\n * startServer({ a }) too\n`)).toEqual([]);
});

test("every config-ui test that starts a server passes an idle callback or noIdle", () => {
  const offenders: string[] = [];
  let calls = 0;
  for (const f of readdirSync(HERE).filter((n) => n.endsWith(".test.ts") && n !== SELF).sort()) {
    const src = readFileSync(join(HERE, f), "utf8");
    calls += (src.match(/\bstartServer\(/g) ?? []).length;
    for (const line of callsWithoutIdleCallback(src)) offenders.push(`${f}:${line}`);
  }
  expect(calls, "the scan found no startServer call at all").toBeGreaterThan(0);
  expect(offenders, `startServer without onIdle or noIdle (its default idle exit is process.exit(0)): ${offenders.join(", ")}`).toEqual([]);
});

// The defect, end to end: a bun test run held past the server's idle time. Without a callback the server's idle timer ends the
// process with exit 0 and no summary while a row is still running; with a do-nothing one the run finishes and reports the real status.
function heldPastIdle(idleOpt: string) {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-idle-"));
  try {
    writeFileSync(join(dir, "held.test.ts"), `import { test, expect } from "bun:test";
import { startServer } from ${JSON.stringify(SERVER)};
const s = startServer({ port: 0, token: "t".repeat(64), ${idleOpt} env: { PATH: process.env.PATH, HOME: ${JSON.stringify(dir)}, CONFIG_UI_IDLE_MS: "300" } } as never);
test("a row held past the server's idle time", async () => { await new Promise((r) => setTimeout(r, 1500)); s.stop(); });
test("a failing row after it", () => { expect(1).toBe(2); });
`);
    const r = spawnSync(process.execPath, ["test", "./held.test.ts"], { cwd: dir, encoding: "utf8", timeout: 60_000 });
    return { rc: r.status, out: String(r.stdout) + String(r.stderr) };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test("without an idle callback a run held past the idle time exits 0 with no bun summary (the defect)", () => {
  const r = heldPastIdle("");
  expect(r.rc).toBe(0);
  expect(r.out).not.toMatch(/\bRan \d+ tests?\b/);
}, 70_000);

test("with a do-nothing idle callback the same run prints the bun summary and exits with the real status", () => {
  const r = heldPastIdle("onIdle: () => {},");
  expect(r.out).toMatch(/\bRan 2 tests across 1 file\b/);
  expect(r.out).toMatch(/\b1 fail\b/);
  expect(r.rc).not.toBe(0);
}, 70_000);
