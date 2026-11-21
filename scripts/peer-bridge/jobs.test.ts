import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Chain, drainSpool, writeResult } from "./chain";
import type { Config } from "./config";
import { JobsError, approveCmd, cancelCmd, capacityCmd, haltCmd, listCmd, requestCmd, showCmd, type JobsDeps } from "./jobs";
import { procHooks } from "./proc";
import { render, renderLine } from "./resolve";
import { inJob, outJob } from "./testlib-jobs";

const NOW_MS = Date.UTC(2026, 10, 20, 12);
const NOW_S = NOW_MS / 1000;
const SUITE = "scripts/ci/test-b.sh";
const SUITE2 = "scripts/hooks/test-a.sh";

let root: string, origin: string, checkout: string, peerDir: string, shaOnMain: string, shaPullOnly: string, shaEmpty: string;
const git = (cwd: string, ...a: string[]) => {
  const r = spawnSync("git", a, { cwd, encoding: "utf8", env: { PATH: process.env.PATH, HOME: root, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid", GIT_CONFIG_GLOBAL: "/dev/null" } });
  if (r.status !== 0) throw new Error(`git ${a.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
};
const orig = procHooks.spawn;
let spawned: string[][];

beforeEach(() => {
  root = fs.mkdtempSync(join(tmpdir(), "peer-jobs-"));
  origin = join(root, "origin.git");
  checkout = join(root, "checkout");
  peerDir = join(root, "state", "example");
  fs.mkdirSync(join(peerDir, "spool"), { recursive: true, mode: 0o700 });
  git(root, "init", "-q", "--bare", "-b", "main", origin);
  const work = join(root, "work");
  fs.mkdirSync(work);
  git(work, "init", "-q", "-b", "main");
  for (const s of [SUITE, SUITE2]) { fs.mkdirSync(join(work, s, ".."), { recursive: true }); fs.writeFileSync(join(work, s), "#!/bin/bash\n"); }
  git(work, "add", "."); git(work, "commit", "-q", "-m", "one");
  shaOnMain = git(work, "rev-parse", "HEAD");
  git(work, "remote", "add", "origin", origin);
  git(work, "push", "-q", "origin", "main");
  git(work, "checkout", "-q", "-b", "pr");
  fs.writeFileSync(join(work, "pr.txt"), "x");
  git(work, "add", "."); git(work, "commit", "-q", "-m", "pr");
  shaPullOnly = git(work, "rev-parse", "HEAD");
  git(work, "push", "-q", "origin", "HEAD:refs/pull/1/head");
  git(work, "checkout", "-q", "--orphan", "bare");
  git(work, "rm", "-rqf", ".");
  fs.writeFileSync(join(work, "readme"), "x");
  git(work, "add", "."); git(work, "commit", "-q", "-m", "bare");
  shaEmpty = git(work, "rev-parse", "HEAD");
  git(work, "push", "-q", "origin", "HEAD:refs/heads/bare");
  git(root, "clone", "-q", origin, checkout);
  git(checkout, "fetch", "-q", "origin", "refs/pull/1/head");
  spawned = [];
  procHooks.spawn = ((cmd: string, args: string[], o: any) => { spawned.push([cmd, ...args]); return (orig as any)(cmd, args, o); }) as any;
});
afterEach(() => { procHooks.spawn = orig; fs.rmSync(root, { recursive: true, force: true }); });

const cfg = (over: Record<string, unknown> = {}): Config => ({
  self: { stationName: "yotam" }, operatorBotId: "9", operatorChatId: 1, bridgeRoot: root, himmelRoot: checkout, maxTextChars: 4000, addressing: "command",
  peers: { example: { chatId: -1001234567890, theirs: { stationName: "example", keys: [] }, serves: [], budgets: {}, ...over } },
} as unknown as Config);

function deps(over: Partial<JobsDeps> = {}): JobsDeps & { lines: string[] } {
  const lines: string[] = [];
  return { cfg: cfg(), peerDir: () => peerDir, env: { PATH: process.env.PATH }, tty: true, ask: async () => "yes", out: l => lines.push(l), now: () => NOW_MS, waitMs: 3000, lines, ...over };
}
const jobsFile = () => join(peerDir, "jobs.jsonl");
const seed = (...recs: Record<string, unknown>[]) => recs.reduce((p, r) => p.then(() => new Chain().append(jobsFile(), r)), Promise.resolve() as Promise<unknown>);
const capacityRec = (over: Record<string, unknown> = {}) => ({ kind: "capacity", peer: "example", re: "89abcdef", ts: NOW_S - 600, state: "idle", capacity: "ok", queue: "free", ...over });

function responder(result: Record<string, unknown>): { recs: any[]; stop(): void } {
  const recs: any[] = [];
  const t = setInterval(() => {
    for (const d of drainSpool(peerDir)) { if ("rec" in d) { recs.push(d.rec); writeResult(peerDir, d.name, result as any); } }
  }, 20);
  return { recs, stop: () => clearInterval(t) };
}
async function refused(p: Promise<unknown>, code: number, rule?: string): Promise<JobsError> {
  try { await p; } catch (e) { expect(e).toBeInstanceOf(JobsError); expect((e as JobsError).code).toBe(code); if (rule) expect((e as JobsError).message).toContain(rule); return e as JobsError; }
  throw new Error("expected a JobsError");
}


test("request sends a req for a SHA on our origin branches, with the suites present at it", async () => {
  const r = responder({ ok: true, job: 7 });
  try {
    const d = deps();
    await requestCmd("example", "run-suite", shaOnMain, [SUITE, SUITE2], d);
    expect(d.lines).toEqual(["J7 sent to example"]);
    expect(r.recs).toEqual([{ type: "env-out", kind: "req", body: { sha: shaOnMain, suites: [SUITE, SUITE2] } }]);
  } finally { r.stop(); }
});

test("request refuses a SHA reachable only through refs/pull/*, and a SHA that is nowhere", async () => {
  const r = responder({ ok: true, job: 1 });
  try {
    expect(shaPullOnly).not.toBe(shaOnMain);
    await refused(requestCmd("example", "run-suite", shaPullOnly, [SUITE], deps()), 2, "unknown-sha");
    await refused(requestCmd("example", "run-suite", "f".repeat(40), [SUITE], deps()), 2, "unknown-sha");
    expect(r.recs).toEqual([]);
  } finally { r.stop(); }
});

test("request refuses a suite missing at the SHA", async () => {
  const r = responder({ ok: true, job: 1 });
  try {
    await refused(requestCmd("example", "run-suite", shaOnMain, [SUITE, "scripts/ci/nope.sh"], deps()), 2, "suite-missing");
    await refused(requestCmd("example", "run-suite", shaEmpty, [SUITE], deps()), 2, "suite-missing");
    expect(r.recs).toEqual([]);
  } finally { r.stop(); }
});

test("the argv it spawns are exactly the two git verbs", async () => {
  const r = responder({ ok: true, job: 1 });
  try {
    await requestCmd("example", "run-suite", shaOnMain, [SUITE, SUITE2], deps());
    expect(spawned).toEqual([
      ["git", "-C", checkout, "branch", "-r", "--contains", shaOnMain],
      ["git", "-C", checkout, "cat-file", "-e", `${shaOnMain}:${SUITE}`],
      ["git", "-C", checkout, "cat-file", "-e", `${shaOnMain}:${SUITE2}`],
    ]);
  } finally { r.stop(); }
});

test("request honours a recent capacity: not-served and no budget refuse, an old or absent one does not", async () => {
  const r = responder({ ok: true, job: 1 });
  try {
    const go = () => requestCmd("example", "run-suite", shaOnMain, [SUITE], deps());
    await go();
    await seed(capacityRec({ ts: NOW_S - 7200, state: "not-served", capacity: "none" }));
    await go();
    await seed(capacityRec({ ts: NOW_S - 1800, state: "not-served", capacity: "none" }));
    await refused(go(), 2, "not-served");
    await seed(capacityRec({ ts: NOW_S - 600, state: "idle", capacity: "none" }));
    await refused(go(), 2, "no-budget");
    await seed(capacityRec({ ts: NOW_S - 300, state: "no-vm", capacity: "none" }));
    await refused(go(), 2, "no-vm");
    await seed(capacityRec({ ts: NOW_S - 100, state: "idle", capacity: "low" }));
    await go();
    expect(r.recs.length).toBe(3);
  } finally { r.stop(); }
});

test("each argument is checked against its token class before anything is spawned", async () => {
  const bad: [string, () => Promise<unknown>][] = [
    ["peer", () => requestCmd("../etc", "run-suite", shaOnMain, [SUITE], deps())],
    ["peer upper", () => requestCmd("Example", "run-suite", shaOnMain, [SUITE], deps())],
    ["op", () => requestCmd("example", "run-prompt", shaOnMain, [SUITE], deps())],
    ["short sha", () => requestCmd("example", "run-suite", shaOnMain.slice(0, 39), [SUITE], deps())],
    ["upper sha", () => requestCmd("example", "run-suite", shaOnMain.toUpperCase(), [SUITE], deps())],
    ["ref name", () => requestCmd("example", "run-suite", "main", [SUITE], deps())],
    ["dotdot", () => requestCmd("example", "run-suite", shaOnMain, ["scripts/../x.sh"], deps())],
    ["absolute", () => requestCmd("example", "run-suite", shaOnMain, ["/etc/passwd"], deps())],
    ["not .sh", () => requestCmd("example", "run-suite", shaOnMain, ["scripts/x.py"], deps())],
    ["no suite", () => requestCmd("example", "run-suite", shaOnMain, [], deps())],
    ["eleven suites", () => requestCmd("example", "run-suite", shaOnMain, Array.from({ length: 11 }, (_, i) => `scripts/t${i}.sh`), deps())],
    ["spaces", () => requestCmd("example", "run-suite", shaOnMain, ["scripts/a b.sh"], deps())],
    ["unknown peer", () => requestCmd("nobody", "run-suite", shaOnMain, [SUITE], deps())],
    ["job class", () => cancelCmd("12", deps())],
    ["job class 2", () => showCmd("J", deps())],
    ["job class 3", () => showCmd("J1x", deps())],
    ["peer in halt", () => haltCmd("a b", deps())],
  ];
  for (const [name, fn] of bad) { const e = await fn().then(() => null, e => e); expect([name, e instanceof JobsError && e.code]).toEqual([name, 2]); }
  expect(spawned).toEqual([]);
});

test("a peer that is not set up refuses with the rule, not a crash", async () => {
  await refused(requestCmd("example", "run-suite", shaOnMain, [SUITE], deps({ cfg: { ...cfg(), self: {} } as Config })), 2, "not-set-up");
  await refused(requestCmd("example", "run-suite", shaOnMain, [SUITE], deps({ cfg: cfg({ chatId: null }) })), 2, "not-set-up");
});

test("a poller that never answers leaves the request queued, exit 4, do not resend", async () => {
  const e = await refused(requestCmd("example", "run-suite", shaOnMain, [SUITE], deps({ waitMs: 150 })), 4, "do not resend");
  expect(e.message).toContain("queued");
  expect(drainSpool(peerDir)).toHaveLength(1);
});

test("a refusal from the poller names its rule", async () => {
  const r = responder({ ok: false, rule: "egress" });
  try { await refused(requestCmd("example", "run-suite", shaOnMain, [SUITE], deps()), 2, "refused: egress"); } finally { r.stop(); }
});


test("cancel and halt spool their envelope; cancel names a job we sent and has not finished", async () => {
  const r = responder({ ok: true });
  try {
    await seed(outJob({ jobNo: 3, state: "ACCEPTED" }), outJob({ jobNo: 4, state: "DONE", by: null }), inJob({ jobNo: 5 }));
    await cancelCmd("J3", deps());
    await haltCmd("example", deps());
    expect(r.recs).toEqual([{ type: "env-out", kind: "cancel", body: { jobNo: 3 } }, { type: "env-out", kind: "halt", body: {} }]);
    await refused(cancelCmd("J4", deps()), 2, "already over");
    await refused(cancelCmd("J5", deps()), 2, "not a job we sent");
    await refused(cancelCmd("J99", deps()), 2, "unknown-job");
  } finally { r.stop(); }
});

test("capacity asks the peer and prints the last answer in our words", async () => {
  const r = responder({ ok: true });
  try {
    const d = deps();
    await capacityCmd("example", d);
    expect(d.lines).toEqual(["asked example; no capacity answer on record yet"]);
    await seed(capacityRec({ capacity: "low", queue: "full", state: "busy" }));
    const d2 = deps();
    await capacityCmd("example", d2);
    expect(d2.lines).toEqual(["asked example", "example capacity: low, queue: full, station: busy"]);
    expect(r.recs.map(x => x.kind)).toEqual(["capacity-ask", "capacity-ask"]);
  } finally { r.stop(); }
});


test("show prints exactly render(record), list one line per job, and neither prints a peer_* field", async () => {
  const a = outJob({ jobNo: 1, state: "DONE", by: null, results: ["pass", "fail"], peer_minutes: 7, peer_image: "d".repeat(64), peer_log_sha256: "c".repeat(64), image: "unpinned" });
  const b = inJob({ jobNo: 2, peer_sha: "9".repeat(40) });
  await seed(a, b, { ...a, state: "DONE", late: "done" });
  const d = deps();
  await showCmd("J1", d);
  expect(d.lines.join("\n")).toBe(render({ ...a, late: "done" }));
  const out = d.lines.join("\n");
  expect(out).not.toMatch(/peer_|dddd|cccc|9999/);
  const l = deps();
  await listCmd(undefined, l);
  expect(l.lines).toEqual([renderLine({ ...a, late: "done" }), renderLine(b)]);
  const one = deps();
  await listCmd("example", one);
  expect(one.lines).toHaveLength(2);
  await refused(listCmd("nobody", deps()), 2, "unknown peer");
  await refused(showCmd("J42", deps()), 2, "unknown-job");
});


test("approve exits 3 without a TTY and under CLAUDECODE, and writes nothing", async () => {
  await seed(inJob({ jobNo: 2, state: "RESOLVED" }));
  await refused(approveCmd("J2", deps({ tty: false })), 3);
  await refused(approveCmd("J2", deps({ env: { CLAUDECODE: "1" } })), 3);
  await refused(approveCmd("J2", deps({ env: { CLAUDE_CODE_SESSION_ID: "abc-123" } })), 3);
  expect(drainSpool(peerDir)).toEqual([]);
});

test("approve asks about the resolved job, then spools the approval; anything but yes does not", async () => {
  const r = responder({ ok: true });
  try {
    await seed(inJob({ jobNo: 2, state: "RESOLVED", sha: "a".repeat(40), suites: ["alias-a"] }), inJob({ jobNo: 3, state: "RECEIVED" }), outJob({ jobNo: 4 }));
    const shown: string[] = [];
    const d = deps({ ask: async q => { shown.push(q); return "yes"; } });
    await approveCmd("J2", d);
    expect(d.lines.join("\n")).toContain("alias-a");
    expect(d.lines.join("\n")).toContain("sha: aaaaaaa");
    expect(r.recs).toEqual([{ type: "job-event", job: 2, event: { type: "approve" } }]);
    await refused(approveCmd("J2", deps({ ask: async () => "y" })), 2, "not approved");
    await refused(approveCmd("J3", deps()), 2, "not resolved");
    await refused(approveCmd("J4", deps()), 2, "not a job a peer sent");
    expect(r.recs).toHaveLength(1);
  } finally { r.stop(); }
});


test("the process: approve with no TTY exits 3, and a bad job argument exits 2", () => {
  const env = { PATH: process.env.PATH!, HOME: root };
  const run = (...a: string[]) => spawnSync("bun", [join(import.meta.dir, "jobs.ts"), ...a], { env, encoding: "utf8", input: "" });
  expect(run("approve", "J1").status).toBe(3);
  const bad = run("show", "12");
  expect(bad.status).toBe(2);
  expect(bad.stderr).toContain("refused");
  expect(run("frobnicate").status).toBe(2);
  expect(run().status).toBe(2);
});

test("jobs.ts imports neither the poller nor setup, and runs git only through proc.ts", () => {
  const src = fs.readFileSync(join(import.meta.dir, "jobs.ts"), "utf8");
  expect(src).not.toMatch(/from "\.\/(poller|setup|reader|read|send)"/);
  expect(src).not.toMatch(/child_process/);
  expect(src).not.toMatch(/["'`]claude["'`]|claude -p|claude --/);
});
