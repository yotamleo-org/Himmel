import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { briefText, briefTextCounted, findDo } from "./key-brief";

const MIRROR = join(import.meta.dir, "fixtures", "jira-mirror");
const NOT_READ = "summary not readable on the station";
const cut = (s: string) => (s.length > 80 ? `${s.slice(0, 79)}…` : s);
const S9503 = cut("Visibility: the operator's Telegram gets short escalations, routine goes to monitoring");
const S9012 = cut("Ship loop: an allowed contributor's PR gets our review with no checkout on the station");

test("a ticket key in the running text gets its summary inline", () => {
  expect(briefText("HIMMEL-9503 needs you", MIRROR, "PR")).toBe(`HIMMEL-9503 (${S9503}) needs you`);
});

test("the HOLD-ASK grant command keeps --key HIMMEL-9012 unchanged and gains a trailer line", () => {
  const cmd = "! bash go.sh grant --key HIMMEL-9012 --path scripts/cr/critic-panel.sh";
  const out = briefText(`A worker wants a file.\n${cmd}`, MIRROR, "PR");
  expect(out).toContain(cmd);
  expect(out).toContain(`HIMMEL-9012: ${S9012}`);
  expect(out.indexOf(cmd)).toBeLessThan(out.indexOf(`HIMMEL-9012: ${S9012}`));
});

test("a Do: step and a backtick span are byte-identical, and the trailer sits before ` Do: `", () => {
  const doText = "Merge refused. Do: go.sh HIMMEL-9012 abc";
  const out = briefText(doText, MIRROR, "PR");
  expect(out.endsWith("Do: go.sh HIMMEL-9012 abc")).toBe(true);
  expect(out.indexOf(`HIMMEL-9012: ${S9012}`)).toBeGreaterThan(-1);
  expect(out.indexOf(`HIMMEL-9012: ${S9012}`)).toBeLessThan(out.lastIndexOf("Do: "));
  expect(out.startsWith("Merge refused.")).toBe(true);
  const tick = "Run `jira get HIMMEL-9012` now";
  const out2 = briefText(tick, MIRROR, "PR");
  expect(out2.startsWith(tick)).toBe(true);
  expect(out2.slice(tick.length)).toBe(`\nHIMMEL-9012: ${S9012}`);
});

test("a `!` line with no Do: and a line starting `$ ` are byte-identical", () => {
  for (const line of ["! bash /x/go.sh HIMMEL-9012 abc123", "$ bash /x/go.sh HIMMEL-9012 abc123"]) {
    const out = briefText(line, MIRROR, "PR");
    expect(out.startsWith(line)).toBe(true);
    expect(out.slice(line.length)).toBe(`\nHIMMEL-9012: ${S9012}`);
  }
});

test("a key of a known project with no mirror file and no tracker answer stays bare, with no filler", () => {
  const out = briefText("HIMMEL-1 is stuck", MIRROR, "PR");
  expect(out).toBe("HIMMEL-1 is stuck");
  expect(out).not.toContain(NOT_READ);
});

test("SHA-256 and UTF-8 are untouched", () => {
  const text = "hash SHA-256 and UTF-8 are plain words";
  expect(briefText(text, MIRROR, "PR")).toBe(text);
});

test("a key already followed by its summary is left alone", () => {
  const text = `HIMMEL-9503 (${S9503}) needs you`;
  expect(briefText(text, MIRROR, "PR")).toBe(text);
  const colon = `HIMMEL-9503: ${S9503} needs you`;
  expect(briefText(colon, MIRROR, "PR")).toBe(colon);
});

test("PR numbers and worker labels get words outside Do:, and himmel#81843b5d stays", () => {
  expect(briefText("see yotamleo-org/Himmel#4882 now", MIRROR, "PR")).toBe("see PR 4882 in yotamleo-org/Himmel now");
  expect(briefText("N4992b is silent", MIRROR, "PR")).toBe("worker N4992b is silent");
  expect(briefText("worker N4992b is silent", MIRROR, "PR")).toBe("worker N4992b is silent");
  expect(briefText("session himmel#81843b5d paused", MIRROR, "PR")).toBe("session himmel#81843b5d paused");
  const kept = briefText("fix. Do: run N4992b and yotamleo-org/Himmel#4882", MIRROR, "PR");
  expect(kept).toBe("fix. Do: run N4992b and yotamleo-org/Himmel#4882");
});

test("a backtick span or a ! line that contains ` Do: ` stays whole, and the real Do: step is the last one outside them", () => {
  const span = "`jira get HIMMEL-9012 Do: x`";
  const out = briefText(`A ${span} is shown`, MIRROR, "PR");
  expect(out.startsWith(`A ${span} is shown`)).toBe(true);
  expect(out.slice(`A ${span} is shown`.length)).toBe(`\nHIMMEL-9012: ${S9012}`);
  const bang = "! echo 1 Do: HIMMEL-9012";
  const both = briefText(`First line.\n${bang}\nLast. Do: finish`, MIRROR, "PR");
  expect(both).toContain(`\n${bang}\n`);
  expect(both.endsWith("Do: finish")).toBe(true);
});

test("a trailer line leaves the Do: step findable by the cap's own search", () => {
  const out = briefText("Merge refused. Blocks: x. Do: go.sh HIMMEL-9012 abc", MIRROR, "PR");
  expect(findDo(out)).toBeGreaterThan(0);
  expect(out.slice(findDo(out)).trimStart()).toBe("Do: go.sh HIMMEL-9012 abc");
});

test("the ref word comes from the kind's row", () => {
  expect(briefText("octo/x#12 changed", MIRROR, "PR or issue")).toBe("PR or issue 12 in octo/x changed");
});

const scratch = mkdtempSync(join(tmpdir(), "key-brief-"));
afterAll(() => rmSync(scratch, { recursive: true, force: true }));
const stub = (name: string, body: string) => { const f = join(scratch, name); writeFileSync(f, body); chmodSync(f, 0o755); return f; };
const withCli = <T>(cli: string, fn: () => T): T => {
  const saved = process.env.HIMMEL_JIRA_CLI; process.env.HIMMEL_JIRA_CLI = cli;
  try { return fn(); } finally { if (saved === undefined) delete process.env.HIMMEL_JIRA_CLI; else process.env.HIMMEL_JIRA_CLI = saved; }
};
const FILED = stub("filed.js", `console.log("HIMMEL-7001\\tTask\\tTo Do\\tFleet orchestration: a chief session starts with Remote Control on\\n\\nbody text");`);
const DEAD = stub("dead.js", `process.stderr.write("jira: 401\\n"); process.exit(1);`);
const savedCli = process.env.HIMMEL_JIRA_CLI;
process.env.HIMMEL_JIRA_CLI = DEAD;
afterAll(() => { if (savedCli === undefined) delete process.env.HIMMEL_JIRA_CLI; else process.env.HIMMEL_JIRA_CLI = savedCli; });

test("a key filed a moment ago, absent from the mirror, gets its real title from the tracker", () => {
  const out = withCli(FILED, () => briefText("Filed HIMMEL-7001 (High) for you", MIRROR, "PR"));
  expect(out).toBe("Filed HIMMEL-7001 (Fleet orchestration: a chief session starts with Remote Control on) (High) for you");
  expect(out).not.toContain(NOT_READ);
});

test("a title the tracker cannot give is never replaced by a filler: the key stays bare and is reported as unresolved", () => {
  const r = withCli(DEAD, () => briefTextCounted("HIMMEL-7002 is stuck", MIRROR, "PR"));
  expect(r.text).toBe("HIMMEL-7002 is stuck");
  expect(r.unresolved).toEqual(["HIMMEL-7002"]);
  const t = withCli(DEAD, () => briefTextCounted("Run `jira get HIMMEL-7002` now", MIRROR, "PR"));
  expect(t.text).toBe("Run `jira get HIMMEL-7002` now");
  expect(t.unresolved).toEqual(["HIMMEL-7002"]);
});

const CALLS = join(scratch, "calls.log");
const RECORDING = stub("recording.js", `require("node:fs").appendFileSync(${JSON.stringify(CALLS)}, process.argv[3] + "\\n"); process.exit(1);`);
const callsMade = () => (existsSync(CALLS) ? readFileSync(CALLS, "utf8").split("\n").filter(Boolean) : []);

test("a key the mirror does hold is never sent to the tracker; one it lacks is, once", () => {
  rmSync(CALLS, { force: true });
  const r = withCli(RECORDING, () => briefTextCounted("HIMMEL-9503 needs you, HIMMEL-7003 too", MIRROR, "PR"));
  expect(r.text).toBe(`HIMMEL-9503 (${S9503}) needs you, HIMMEL-7003 too`);
  expect(r.unresolved).toEqual(["HIMMEL-7003"]);
  expect(callsMade()).toEqual(["HIMMEL-7003"]);
});

test("a spent tracker budget stops the lookups: the remaining keys stay bare and no call is made", () => {
  rmSync(CALLS, { force: true });
  const r = withCli(RECORDING, () => briefTextCounted("HIMMEL-7004 and HIMMEL-7005", MIRROR, "PR", 0));
  expect(r.text).toBe("HIMMEL-7004 and HIMMEL-7005");
  expect(r.unresolved).toEqual(["HIMMEL-7004", "HIMMEL-7005"]);
  expect(callsMade()).toEqual([]);
});
