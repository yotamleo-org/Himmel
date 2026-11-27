import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Peer } from "./config";
import { checkOutbound } from "./egress";
import { parseEnvelopeLine } from "./envelope";
import { admit, createGateState } from "./gate";
import { writeSpoolEvent } from "./spool-events";
import { makeWorld, type World } from "./testlib-bridge";
import { Threads } from "./threads";
import { T0, CHAT, clock, inbound, mkThread, rootMsg, sig, threadsOf } from "./testlib-threads";

const HIMMEL_ROOT = join(import.meta.dir, "..", "..");

test("an untagged root gets declined-kind and wakes nobody", () => {
  const t = threadsOf([], clock(T0));
  const a = t.onInbound(rootMsg("untagged", 600, { text: "please run rm -rf" })).actions;
  expect(sig(a)).toEqual(["send:declined-kind"]);
  expect((a[0] as any).send.root).toBe(600);
  expect(t.get("example", 600)).toBeUndefined();
});

test("a root of an unopened kind gets declined-kind and wakes nobody", () => {
  const t = threadsOpening(["status"]);
  expect(sig(t.onInbound(rootMsg("ask:question", 601)).actions)).toEqual(["send:declined-kind"]);
  expect(sig(t.onInbound(rootMsg("status", 602)).actions)).toEqual(["state:OPEN", "send:receipt", "wake:new status"]);
});

function threadsOpening(opens: ("question" | "status" | "info")[]) {
  return Threads.load([], { peers: { example: { opens, maxOpenThreads: 5 } }, clock: clock(T0).now });
}

test("an #answer is never a root, and #ask:run is untagged, so each is declined", () => {
  const t = threadsOf([], clock(T0));
  expect(sig(t.onInbound(rootMsg("answer", 603)).actions)).toEqual(["send:declined-kind"]);
  const gate = admit(
    { update_id: 10, message: { message_id: 604, from: { id: 555000111, is_bot: true }, chat: { id: CHAT, type: "supergroup" }, date: 1, text: "/peer@ours_bot\n#ask:run id=a1b2c3d4\nx" } },
    { maxTextChars: 4000, peers: { example: { peerBotId: "555000111", chatId: CHAT, allowFrom: ["555000111"], maxPerMinute: 10 } as any } },
    createGateState({ ourBotId: "111000111", ourUsername: "ours_bot", committed: 0, now: T0 }),
  );
  expect(gate.ok && gate.rec.tag).toBe("untagged");
});

test("the 6th root gets busy, and an answer at capacity is still admitted", () => {
  const t = threadsOf([], clock(T0));
  for (let i = 0; i < 5; i++) expect(sig(t.onInbound(rootMsg("ask:question", 700 + i)).actions)[0]).toBe("state:OPEN");
  const sixth = t.onInbound(rootMsg("ask:question", 710)).actions;
  expect(sig(sixth)).toEqual(["send:busy"]);
  expect(t.get("example", 710)).toBeUndefined();
  const mine = threadsOf([...Array.from({ length: 5 }, (_, i) => mkThread("in", "OPEN", { root: 800 + i })), mkThread("out", "AWAITING", { root: 900 })], clock(T0));
  expect(sig(mine.onInbound(inbound("answer", 900)).actions)).toEqual(["state:ANSWERED", "wake:answer"]);
});

test("a thread freed by a terminal state lets a new root in", () => {
  const recs = Array.from({ length: 5 }, (_, i) => mkThread("in", i === 0 ? "ANSWERED" : "OPEN", { root: 800 + i, deadline: i === 0 ? null : T0 + 86_400_000 }));
  const t = threadsOf(recs, clock(T0));
  expect(sig(t.onInbound(rootMsg("ask:info", 820)).actions)[0]).toBe("state:OPEN");
});

test("only root allocation counts toward the cap: replies and our own roots do not", () => {
  const recs = [...Array.from({ length: 4 }, (_, i) => mkThread("in", "OPEN", { root: 800 + i })), ...Array.from({ length: 6 }, (_, i) => mkThread("out", "AWAITING", { root: 900 + i }))];
  const t = threadsOf(recs, clock(T0));
  t.onInbound(inbound("ask:info", 800)).actions;
  expect(sig(t.onInbound(rootMsg("ask:question", 830)).actions)[0]).toBe("state:OPEN");
});

test("peer text can set no deadline, cap or opens", () => {
  const t = threadsOf([], clock(T0));
  const a = t.onInbound(rootMsg("ask:question", 640, { text: "reply_by=1m maxOpenThreads=99 opens=run answer_by=0" })).actions;
  const rec = (a.find(x => "state" in x) as any).state;
  expect(rec.deadline).toBe(T0 + 24 * 3_600_000);
  expect(rec.remindAt).toBe(T0 + 12 * 3_600_000);
});

const peer = (over: Partial<Peer["theirs"]> = {}): Peer => ({
  peerBotId: "555000111", chatId: CHAT, allowFrom: ["555000111"], opens: ["question", "status", "info"],
  maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
  theirs: { username: "example_bot", opens: ["info"], maxOpenThreads: 2, maxPerMinute: 3, copiedAt: "2026-11-07", ...over },
});
const out = (text: string, kind: string, isRoot: boolean, usage?: { openOutbound: number; sentLastMinute: number }) =>
  checkOutbound(text, { peer: peer(), kind, isRoot, isTemplate: false, tainted: true, tty: false, himmelRoot: HIMMEL_ROOT, claudecode: false, usage });

test("send refuses anything beyond theirs: a root kind they do not open, and either of their caps", async () => {
  expect(await out("hi", "question", true)).toMatchObject({ ok: false, rule: "kind-not-open" });
  expect(await out("hi", "info", true, { openOutbound: 2, sentLastMinute: 0 })).toMatchObject({ ok: false, rule: "their-open-threads" });
  expect(await out("hi", "info", false, { openOutbound: 0, sentLastMinute: 3 })).toMatchObject({ ok: false, rule: "their-rate" });
  expect(await out("hi", "info", true, { openOutbound: 1, sentLastMinute: 2 })).toEqual({ ok: true });
});


const SHA = "a".repeat(40), SUITE = "scripts/hooks/test-a.sh";
const ALLOW = [{ alias: "alias-a", path: SUITE }];
const askReq = (w: World, body: Record<string, unknown> = { sha: SHA, suites: [SUITE] }) => writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "req", body }, w.alpha.peerDir);
const bodiesOf = (w: World, from: "alpha" | "bravo") => w.wire.filter(m => m.from === from).map(m => (parseEnvelopeLine(m.text.split("\n")[2]) as any).env);

test("serves: [] refuses every req with a signed refused, and answers every capacity-ask with not-served", async () => {
  const w = await makeWorld({ serves: false, allow: ALLOW });
  askReq(w);
  writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "capacity-ask", body: {} }, w.alpha.peerDir);
  await w.step("alpha");
  await w.step("bravo");
  const answers = bodiesOf(w, "bravo");
  expect(answers.map((a: any) => [a.kind, a.state, a.refused])).toEqual([["res", "refused", "not-served"], ["capacity", "not-served", undefined]]);
  expect(answers[1]).toMatchObject({ queue: 0, jobs_left: 0, vm_minutes_left: 0 });
  expect(w.bravo.jobs()).toEqual([]);
  await w.step("alpha");
  expect(w.alpha.jobs()).toMatchObject([{ state: "REFUSED", refused: "not-served" }]);
  expect(w.alpha.chain("jobs.jsonl").find(r => r.kind === "capacity")).toMatchObject({ state: "not-served", capacity: "none" });
  // And alpha now refuses to ask again while that answer is fresh.
});

test("cancel and halt are handled even when nothing is served any more", async () => {
  const w = await makeWorld({ allow: ALLOW });
  askReq(w);
  await w.step("alpha");
  await w.step("bravo");
  w.bravo.cfg.peers.alpha.serves = [];
  w.inject("alpha", "cancel", { job: w.alpha.jobs()[0].wire_job });
  await w.step("bravo");
  expect(w.bravo.jobs()[0].state).toBe("CANCELLED");
  askReq(w);
  w.bravo.cfg.peers.alpha.serves = ["run-suite"];
  await w.step("alpha");
  await w.step("bravo");
  w.bravo.cfg.peers.alpha.serves = [];
  w.inject("alpha", "halt", {});
  await w.step("bravo");
  expect(w.bravo.jobs().map(j => j.state)).toEqual(["CANCELLED", "CANCELLED"]);
});

test("an unmatched res, capacity or cancel is dropped and logged, never answered", async () => {
  const w = await makeWorld({ allow: ALLOW });
  const before = w.wire.length;
  w.inject("alpha", "res", { job: "f".repeat(16), state: "accepted" });
  w.inject("alpha", "capacity", { re: "89abcdef", state: "idle", queue: 0, jobs_left: 3, vm_minutes_left: 60 });
  w.inject("alpha", "cancel", { job: "e".repeat(16) });
  await w.step("bravo");
  expect(w.wire.length).toBe(before);
  expect(w.bravo.logs.filter(l => l.startsWith("env-drop step=8")).length).toBe(3);
  expect(w.bravo.jobs()).toEqual([]);
});

test("a killed peer gets no answer at all, its live job is cancelled with nothing sent, and nothing it asks starts", async () => {
  const w = await makeWorld({ allow: ALLOW });
  askReq(w);
  await w.step("alpha");
  await w.step("bravo");
  writeSpoolEvent({ t: "job-event", peer: "alpha", job: 1, event: { type: "resolve-ok", sha: SHA } }, w.bravo.peerDir);
  await w.step("bravo");
  const sent = w.wire.length;
  fs.writeFileSync(join(w.bravo.configDir, "alpha.killed"), "", { mode: 0o600 });
  w.inject("alpha", "capacity-ask", {});
  w.inject("alpha", "req", { job: "d".repeat(16), op: "run-suite", sha: SHA, suites: [SUITE] });
  await w.step("bravo");
  await w.bravo.poller.tick();
  expect(w.wire.length).toBe(sent);
  expect(w.bravo.jobs()).toMatchObject([{ jobNo: 1, state: "CANCELLED" }]);
  expect(w.bravo.logs.filter(l => l.startsWith("env-drop step=4")).length).toBe(2);
  const name = writeSpoolEvent({ t: "job-event", peer: "alpha", job: 1, event: { type: "approve" } }, w.bravo.peerDir);
  await w.bravo.poller.drainSpool();
  expect(JSON.parse(fs.readFileSync(join(w.bravo.peerDir, "spool", "results", name), "utf8"))).toEqual({ ok: false, rule: "killed" });
  fs.rmSync(join(w.bravo.configDir, "alpha.killed"));
  w.inject("alpha", "capacity-ask", {});
  await w.step("bravo");
  expect(w.wire.length).toBe(sent + 1);
});

test("no envelope changes a config field, the allowlist or the kill file", async () => {
  const w = await makeWorld({ allow: ALLOW });
  const snapshot = () => ({
    cfg: JSON.stringify(w.bravo.cfg),
    files: fs.readdirSync(w.bravo.configDir).sort().map(n => [n, fs.readFileSync(join(w.bravo.configDir, n), "utf8")]),
  });
  const before = snapshot();
  w.inject("alpha", "req", { job: "d".repeat(16), op: "run-suite", sha: SHA, suites: [SUITE] });
  w.inject("alpha", "capacity-ask", {});
  w.inject("alpha", "capacity", { re: "89abcdef", state: "idle", queue: 0, jobs_left: 1, vm_minutes_left: 1 });
  w.inject("alpha", "res", { job: "f".repeat(16), state: "accepted" });
  w.inject("alpha", "cancel", { job: "d".repeat(16) });
  w.inject("alpha", "halt", {});
  w.inject("alpha", "req", { job: "c".repeat(16), op: "run-suite", sha: SHA, suites: ["scripts/not-allowed.sh"] });
  await w.step("bravo");
  expect(snapshot()).toEqual(before);
});


function graphOf(entry: string): string[] {
  const dir = fs.mkdtempSync(join(tmpdir(), "peer-meta-"));
  try {
    const r = spawnSync("bun", ["build", entry, "--target=bun", `--metafile=${join(dir, "meta.json")}`, `--outfile=${join(dir, "out.js")}`], { cwd: HIMMEL_ROOT, encoding: "utf8" });
    expect([entry, r.status]).toEqual([entry, 0]);
    return Object.keys(JSON.parse(fs.readFileSync(join(dir, "meta.json"), "utf8")).inputs).sort();
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
const read = (f: string) => fs.readFileSync(join(HIMMEL_ROOT, f), "utf8");
const CLAUDE_CALL = /["'`]claude["'`]|\bclaude\s+(-p|--)/;
const SPAWN_CALL = /(?<![.\w])(?:procHooks\.)?(spawnSync|spawn|execFileSync|execFile|execSync|runProc)\(\s*(\[?\s*"[^"]+"|[A-Za-z_.0-9]+)/g;
const spawnSites = (files: string[]): string[] => files.flatMap(f => [...read(f).matchAll(SPAWN_CALL)].map(m => `${f}: ${m[1]}(${m[2]}`));

test("envelope.ts reaches only itself, the grammar and the ids: no process, no claude", () => {
  const g = graphOf("scripts/peer-bridge/envelope.ts");
  expect(g).toEqual(["scripts/peer-bridge/envelope.ts", "scripts/peer-bridge/grammar.ts", "scripts/peer-bridge/ids.ts"]);
  for (const f of g) { expect([f, CLAUDE_CALL.test(read(f))]).toEqual([f, false]); expect(spawnSites([f])).toEqual([]); }
});

test("the poller reaches the one claude call it always had, in the text reader, and nothing the typed path added", () => {
  const g = graphOf("scripts/peer-bridge/poller.ts");
  expect(g).toContain("scripts/peer-bridge/gate.ts");
  expect(g).toContain("scripts/peer-bridge/jobstate.ts");
  expect(g).toContain("scripts/peer-bridge/resolve.ts");
  expect(g.filter(f => CLAUDE_CALL.test(read(f)))).toEqual(["scripts/peer-bridge/reader.ts"]);
  for (const f of ["envelope", "sign", "resolve", "jobstate", "spool-events", "jobs"]) expect([f, CLAUDE_CALL.test(read(`scripts/peer-bridge/${f}.ts`))]).toEqual([f, false]);
});

test("the poller's spawn list is slice A's: ps, redact_check, the usage preflight, the reader and flock", () => {
  const sites = spawnSites(graphOf("scripts/peer-bridge/poller.ts"));
  expect(sites).toEqual([
    'scripts/peer-bridge/chain.ts: spawnSync("ps"',
    'scripts/peer-bridge/egress.ts: runProc(["bash"',
    "scripts/peer-bridge/proc.ts: runProc(argv",
    "scripts/peer-bridge/proc.ts: spawn(argv",
    'scripts/peer-bridge/reader.ts: runProc(["bash"',
    'scripts/peer-bridge/reader.ts: spawn("claude"',
    'scripts/telegram/bus.ts: spawn("flock"',
  ]);
  expect(sites.filter(s => /git/.test(s))).toEqual([]);
});

test("the runner reaches no claude, and spawns only git, vmsdk-job.py and the lock helpers", () => {
  const g = graphOf("scripts/peer-bridge/runner.ts");
  expect(g.filter(f => CLAUDE_CALL.test(read(f)))).toEqual([]);
  expect(g).not.toContain("scripts/peer-bridge/reader.ts");
  expect(spawnSites(g)).toEqual([
    'scripts/peer-bridge/chain.ts: spawnSync("ps"',
    "scripts/peer-bridge/proc.ts: runProc(argv",
    "scripts/peer-bridge/proc.ts: spawn(argv",
    'scripts/peer-bridge/runner.ts: runProc(["git"',
    'scripts/peer-bridge/runner.ts: runProc(["python3"',
    'scripts/peer-bridge/runner.ts: spawn("python3"',
    'scripts/telegram/bus.ts: spawn("flock"',
  ]);
});

test("git runs only in jobs.ts and runner.ts on the typed path, each with its closed list of verbs", () => {
  const typed = fs.readdirSync(join(HIMMEL_ROOT, "scripts/peer-bridge")).filter(n => /\.ts$/.test(n) && !/\.test\.ts$|^testlib-/.test(n));
  const withGit = typed.filter(n => /["'`]git["'`]/.test(read(`scripts/peer-bridge/${n}`)));
  expect(withGit.sort()).toEqual(["jobs.ts", "runner.ts", "setup.ts"]);
  const jobs = read("scripts/peer-bridge/jobs.ts");
  expect(jobs.match(/await git\(deps,[^)]*\)/g)).toEqual(['await git(deps, "branch", "-r", "--contains", sha)', 'await git(deps, "cat-file", "-e", `${sha}:${s}`)']);
  expect(jobs.match(/runProc\(/g)).toHaveLength(1);
  const runner = read("scripts/peer-bridge/runner.ts");
  expect(runner.match(/await git\(deps, [^)]*\)/g)).toEqual([
    'await git(deps, null, "init", "-q", "--bare", cache)',
    'await git(deps, cache, "fetch", "-q", "--prune", url, "+refs/heads/*:refs/remotes/origin/*")',
    'await git(deps, cache, "cat-file", "-e", `${sha}^{commit}`)',
    'await git(deps, cache, "branch", "-r", "--contains", sha)',
    'await git(deps, cache, "merge-base", "--is-ancestor", deps.minSha, sha)',
    'await git(deps, null, "init", "-q", src)',
    'await git(deps, src, "fetch", "-q", "--depth", "1", from, rec.sha)',
  ]);
  expect(runner.match(/runProc\(/g)).toHaveLength(2);
  expect(runner).toContain('runProc(["git", "-c", "core.hooksPath=/dev/null", ');
  expect(runner).toContain('GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1"');
});

test("an envelope can only narrow: serves, approve, budgets and the allowlist have no inbound writer", () => {
  const src = (f: string) => fs.readFileSync(join(import.meta.dir, f), "utf8");
  expect(src("poller.ts")).not.toMatch(/writeFileSync|renameSync|replaceJson|\.suites`|killed`\),? *["']|openSync\([^)]*(peers|suites|killed)/);
  for (const f of ["gate.ts", "envelope.ts", "resolve.ts", "jobstate.ts", "jobs.ts", "poller.ts", "pairing.ts", "notify.ts", "host.ts", "egress.ts"]) expect(src(f)).not.toMatch(/from "\.\/setup"/);
  expect(graphOf("scripts/peer-bridge/poller.ts")).not.toContain("scripts/peer-bridge/setup.ts");
});

const bridgeSources = () => fs.readdirSync(import.meta.dir).filter(n => /\.ts$/.test(n) && !/\.test\.ts$|^testlib-/.test(n));
const bridgeSrc = (f: string) => fs.readFileSync(join(import.meta.dir, f), "utf8");
const calls = (text: string, name: string): number[] => [...text.matchAll(new RegExp(`(?<!function )(?<![A-Za-z0-9_])${name}\\(`, "g"))].map(m => m.index!);
function spans(text: string, name: string): [number, number][] {
  return calls(text, name).map(at => {
    let depth = 0, i = text.indexOf("(", at);
    for (; i < text.length; i++) {
      if (text[i] === "(") depth++;
      else if (text[i] === ")" && --depth === 0) break;
    }
    return [at, i];
  });
}
const outsideSpans = (text: string, name: string, within: string) => calls(text, name).filter(at => !spans(text, within).some(([a, b]) => at > a && at < b));
const declarationsOf = (text: string, re: RegExp): string[] => [...new Set(text.split("\n").reduce<[string, string[]]>(([current, found], line) => {
  const d = /^(?:export )?(?:async )?(?:function|const|type|class) ([A-Za-z0-9_]+)/.exec(line);
  if (d) current = d[1];
  if (re.test(line) && !/^import /.test(line)) found.push(current);
  return [current, found];
}, ["", []])[1])];

test("peers.json has one trust writer and one renaming path, and pairing.json is written only under the lock", () => {
  const writers = bridgeSources().flatMap(f => calls(bridgeSrc(f), "addTrustedKey").map(() => f));
  expect(writers.sort()).toEqual(["poller.ts", "setup.ts"]);
  expect(spans(bridgeSrc("poller.ts"), "addTrustedKey").map(([a, b]) => /firstOnly: true/.test(bridgeSrc("poller.ts").slice(a, b)))).toEqual([true]);
  expect(bridgeSources().filter(f => calls(bridgeSrc(f), "replacePeersJson").length).sort()).toEqual(["config.ts", "setup.ts"]);
  const setup = bridgeSrc("setup.ts");
  expect(setup).not.toMatch(/replaceJson\(|writePairing\(/);
  expect(outsideSpans(setup, "writePairingRecord", "withPeersLock")).toEqual([]);
  expect(bridgeSources().filter(f => calls(bridgeSrc(f), "writePairingRecord").length).sort()).toEqual(["config.ts", "setup.ts"]);
  expect(declarationsOf(bridgeSrc("config.ts"), /(?<!function )writePairingRecord\(/)).toEqual(["replacePeersJsonLocked"]);
  expect(declarationsOf(bridgeSrc("config.ts"), /(renameSync|linkSync)\(/).sort()).toEqual(["replacePeersJsonLocked", "withPeersLock", "writePairingRecord"]);
});

test("each lexical pin fires on a planted violation", () => {
  expect(outsideSpans("writePairingRecord(b);\nwithPeersLock(d, () => writePairingRecord(c), o);", "writePairingRecord", "withPeersLock")).toEqual([0]);
  expect("replaceJson(pairingFile(), x)").toMatch(/replaceJson\(|writePairing\(/);
  expect(calls("await addTrustedKey(a)\nexport async function addTrustedKey(", "addTrustedKey")).toHaveLength(1);
  expect(declarationsOf("export function sneaky() {\n  fs.renameSync(a, b);\n}", /(renameSync|linkSync)\(/)).toEqual(["sneaky"]);
});

test("answers to a peer's asks are capped per hour, like slice A's automatic templates", async () => {
  const w = await makeWorld({ allow: ALLOW });
  for (let i = 0; i < 25; i++) w.inject("alpha", "capacity-ask", {});
  await w.step("bravo");
  expect(bodiesOf(w, "bravo").length).toBe(20);
  expect(w.bravo.logs.filter(l => l.includes("hourly cap on answers")).length).toBe(5);
  w.clock.t += 61 * 60_000;
  w.inject("alpha", "capacity-ask", {});
  await w.step("bravo");
  expect(bodiesOf(w, "bravo").length).toBe(21);
});

test("req over budget is refused with budget, and the requester ends REFUSED", async () => {
  const w = await makeWorld({ allow: ALLOW, budgets: { jobsPerDay: 1 } });
  for (let i = 0; i < 2; i++) { askReq(w); await w.step("alpha"); await w.step("bravo"); if (i === 0) { writeSpoolEvent({ t: "job-event", peer: "alpha", job: 1, event: { type: "resolve-ok", sha: SHA } }, w.bravo.peerDir); await w.step("bravo"); } }
  await w.step("alpha");
  expect(w.alpha.jobs().map(j => j.state)).toEqual(["ACCEPTED", "REFUSED"]);
  expect(w.alpha.jobs()[1].refused).toBe("budget");
});

test("our open outbound threads feed their cap", async () => {
  const t = threadsOf([mkThread("out", "SENT", { root: 1 }), mkThread("out", "AWAITING", { root: 2 }), mkThread("out", "CLOSED", { root: 3, deadline: null })], clock(T0));
  expect(t.openOutbound("example")).toBe(2);
  expect(await out("hi", "info", true, { openOutbound: t.openOutbound("example"), sentLastMinute: 0 })).toMatchObject({ rule: "their-open-threads" });
});
