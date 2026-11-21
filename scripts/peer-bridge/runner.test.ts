// runner.ts on real git; only vmsdk-job.py is stubbed (its stub backend), and a
// fake poller applies each spool event with the real jobstate table.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import * as cp from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { drainSpool, writeResult } from "./chain";
import type { Config } from "./config";
import { step, type JobEvent } from "./jobstate";
import { procHooks } from "./proc";
import type { JobRecord } from "./resolve";
import { MIN_SHA, RunnerRefused, start, tick, type RunnerDeps } from "./runner";
import { writeSpoolEvent, type SpoolJobEvent } from "./spool-events";
import { NOW_S, inJob } from "./testlib-jobs";

const REPO = join(import.meta.dir, "..", "..");
const PEER = "goomal";
const GIT_ENV = { PATH: process.env.PATH, HOME: "/nonexistent", GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };

let fx: string, origin: string, home: string, sentinel: string, listener: net.Server, connections = 0;
const sha: Record<"old" | "min" | "tip" | "pr", string> = { old: "", min: "", tip: "", pr: "" };

function g(cwd: string, ...args: string[]): string {
  const r = cp.spawnSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", ...args], { cwd, env: GIT_ENV, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}
function commit(dir: string, files: Record<string, string>, msg: string): string {
  for (const [f, text] of Object.entries(files)) { fs.mkdirSync(join(dir, f, ".."), { recursive: true }); fs.writeFileSync(join(dir, f), text); }
  g(dir, "add", "-A");
  g(dir, "commit", "-q", "-m", msg);
  return g(dir, "rev-parse", "HEAD");
}

beforeAll(async () => {
  fx = fs.mkdtempSync(join(tmpdir(), "peer-runner-fx-"));
  listener = net.createServer(s => { connections++; s.destroy(); });
  await new Promise<void>(r => listener.listen(0, "127.0.0.1", r));
  const port = (listener.address() as net.AddressInfo).port;
  sentinel = join(fx, "sentinel");
  home = join(fx, "home");
  fs.mkdirSync(join(home, "hooks"), { recursive: true });
  const hook = `#!/bin/sh\necho "$0 $*" >> ${sentinel}\ncat\n`;
  fs.writeFileSync(join(home, "filter.sh"), hook, { mode: 0o755 });
  for (const h of ["reference-transaction", "post-checkout", "post-merge"]) fs.writeFileSync(join(home, "hooks", h), hook, { mode: 0o755 });
  fs.writeFileSync(join(home, ".gitconfig"), `[filter "lfs"]\n\tsmudge = ${home}/filter.sh smudge\n\tclean = ${home}/filter.sh clean\n\trequired = true\n[core]\n\thooksPath = ${home}/hooks\n`);

  const w = join(fx, "work");
  fs.mkdirSync(w);
  g(w, "init", "-q", "-b", "main");
  sha.old = commit(w, { "scripts/test-a.sh": "exit 0\n" }, "old");
  g(w, "branch", "old");
  sha.min = commit(w, { "scripts/test-b.sh": "exit 0\n" }, "min");
  sha.tip = commit(w, {
    ".gitattributes": "* filter=lfs diff=lfs merge=lfs -text\n",
    ".lfsconfig": `[lfs]\n\turl = http://127.0.0.1:${port}/\n`,
    "scripts/ci/run-shell-tests.sh": `#!/bin/sh\necho tree >> ${sentinel}\n`,
    "big.bin": "payload\n",
  }, "tip");
  g(w, "checkout", "-q", "-b", "pr");
  sha.pr = commit(w, { "scripts/test-pr.sh": "exit 0\n" }, "pr");
  g(w, "checkout", "-q", "main");
  origin = join(fx, "origin.git");
  g(fx, "init", "-q", "--bare", origin);
  g(w, "push", "-q", origin, "main", "old", `${sha.pr}:refs/pull/1/head`);
});
afterAll(() => { listener.close(); fs.rmSync(fx, { recursive: true, force: true }); });

type Call = { argv: string[]; env: NodeJS.ProcessEnv };
type World = {
  root: string; S: string; C: string; stub: string; calls: Call[]; events: SpoolJobEvent[];
  backstop: number; deps: RunnerDeps; jobs: () => JobRecord[]; put: (r: JobRecord) => void; stubCalls: () => any[];
  onExec?: (w: World) => string[] | undefined;
};
const realSpawn = procHooks.spawn;
let world: World | undefined;

function mkWorld(over: { peerSha?: string; exec?: unknown; fail?: Record<string, number>; env?: NodeJS.ProcessEnv } = {}): World {
  const root = fs.mkdtempSync(join(tmpdir(), "peer-runner-"));
  const S = join(root, "S"), C = join(root, "C"), stub = join(root, "stub");
  for (const d of [S, C, stub, join(S, PEER, "spool")]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(join(stub, "golden.img"), "golden");
  fs.writeFileSync(join(C, "golden.digest"), "ab".repeat(32) + "\n");
  if (over.exec !== undefined) fs.writeFileSync(join(stub, "exec.json"), JSON.stringify(over.exec));
  if (over.fail) fs.writeFileSync(join(stub, "fail.json"), JSON.stringify(over.fail));
  const jobsFile = join(S, PEER, "jobs.jsonl");
  const w: World = {
    root, S, C, stub, calls: [], events: [], backstop: 3600,
    jobs: () => { const m = new Map<number, JobRecord>(); for (const l of fs.readFileSync(jobsFile, "utf8").split("\n").filter(Boolean)) { const r = JSON.parse(l); m.set(r.jobNo, r); } return [...m.values()]; },
    put: r => fs.appendFileSync(jobsFile, JSON.stringify(r) + "\n"),
    stubCalls: () => fs.existsSync(join(stub, "calls.jsonl")) ? fs.readFileSync(join(stub, "calls.jsonl"), "utf8").split("\n").filter(Boolean).map(l => JSON.parse(l)) : [],
    deps: undefined as unknown as RunnerDeps,
  };
  w.put(inJob({ peer: PEER, jobNo: 2, created: NOW_S, peer_sha: over.peerSha ?? sha.tip, suites: ["a", "b"], paths: ["scripts/test-a.sh", "scripts/test-b.sh"] }));
  const apply = (job: JobRecord, ev: JobEvent) => { const r = step(job, ev, NOW_S + 60); w.put(r.record); return r.record; };
  const poller = () => {
    for (const d of drainSpool(join(S, PEER))) {
      if ("malformed" in d || d.rec.type !== "job-event") throw new Error(`fake poller: unexpected spool file ${d.name}`);
      const e = d.rec.event as any;
      w.events.push(e);
      const job = w.jobs().find(j => j.jobNo === (d.rec as any).job)!;
      const ev: JobEvent = e.type === "vm-start" ? { type: "vm-start", backstop_s: w.backstop } : e;
      const after = apply(job, ev);
      if (e.type === "resolve-ok" && after.state === "RESOLVED") apply(after, { type: "approve" });
      writeResult(join(S, PEER), d.name, { ok: true });
    }
  };
  const cfg = {
    himmelRoot: REPO, self: { stationName: "ours" },
    peers: { [PEER]: { serves: ["run-suite"], approve: { "run-suite": "auto" }, repoUrl: `file://${origin}` } },
  } as unknown as Config;
  let t = 1_000_000;
  w.deps = {
    cfg, stateDir: S, configDir: C, minSha: sha.min, watchMs: 5,
    env: { PATH: process.env.PATH, HOME: home, PEER_JOB_BACKEND: "stub", PEER_JOB_STUB_DIR: stub, ...over.env },
    now: () => (t += 30_000),
    log: () => {},
    submit: async (peer, job, event) => {
      const name = writeSpoolEvent({ t: "job-event", peer, job, event }, join(S, peer));
      poller();
      return JSON.parse(fs.readFileSync(join(S, peer, "spool", "results", name), "utf8")).ok === true;
    },
  };
  procHooks.spawn = ((cmd: string, args: string[], opts: cp.SpawnOptions) => {
    w.calls.push({ argv: [cmd, ...args], env: { ...opts.env } });
    const swap = args.includes("vm-exec") ? w.onExec?.(w) : undefined;
    return swap ? realSpawn(swap[0], swap.slice(1), opts) : realSpawn(cmd, args, opts);
  }) as typeof procHooks.spawn;
  world = w;
  return w;
}
beforeEach(() => { connections = 0; fs.rmSync(sentinel, { force: true }); });
afterEach(() => { procHooks.spawn = realSpawn; if (world) fs.rmSync(world.root, { recursive: true, force: true }); world = undefined; });

const RESULT = { files: { ".job-result.json": JSON.stringify({ results: [{ suite: 0, outcome: "pass" }, { suite: 1, outcome: "fail" }], minutes: 1 }), "job.log": "suite log\n" } };
const run = async (w: World) => { await start(w.deps); await tick(w.deps); };
const done = (w: World) => w.events.filter(e => e.type === "vm-done");

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
function closedList(w: World): RegExp[] {
  const G = "git -c core\\.hooksPath=/dev/null", cache = esc(join(w.S, "cache", PEER)), jobDir = `${esc(join(w.S, PEER, "jobs"))}/[0-9]+`;
  const V = `python3 ${esc(join(REPO, "scripts/lib/vmsdk-job.py"))}`, id = `${PEER}-j[0-9]+`, H = "[0-9a-f]{40}";
  const originUrl = esc("file:" + "//" + origin);
  return [
    `${G} init -q --bare ${cache}`,
    `${G} -C ${cache} fetch -q --prune ${originUrl} \\+refs/heads/\\*:refs/remotes/origin/\\*`,
    `${G} -C ${cache} cat-file -e ${H}\\^\\{commit\\}`,
    `${G} -C ${cache} branch -r --contains ${H}`,
    `${G} -C ${cache} merge-base --is-ancestor ${H} ${H}`,
    `${G} init -q ${jobDir}/src`,
    `${G} -C ${jobDir}/src fetch -q --depth 1 file://${cache} ${H}`,
    `${V} vm-sweep`,
    `${V} vm-clone ${id}`,
    `${V} vm-push ${id} (${jobDir}/src\\.tar|${jobDir}/suites\\.txt|${esc(join(REPO, "scripts/peer-bridge/job-entry.sh"))})`,
    `${V} vm-exec ${id} --timeout [0-9]+ -- bash /tmp/job/job-entry\\.sh /tmp/job/suites\\.txt [0-9]+`,
    `${V} vm-pull ${id} /tmp/job/\\.job-result\\.json ${jobDir}/result\\.json --max-bytes 16384`,
    `${V} vm-pull ${id} /tmp/job/job\\.log ${esc(join(w.S, PEER, "logs"))}/[0-9]+\\.log --max-bytes 5242880`,
    `${V} vm-destroy ${id}`,
  ].map(s => new RegExp(`^${s}$`));
}

test("every argv the runner spawns is on the closed list, and every git spawn has the neutral config", async () => {
  const w = mkWorld({ exec: RESULT });
  await run(w);
  const list = closedList(w);
  const lines = w.calls.map(c => c.argv.join(" "));
  expect(lines.filter(l => !list.some(re => re.test(l)))).toEqual([]);
  expect(list.filter(re => !lines.some(l => re.test(l))).map(String)).toEqual([]);
  for (const c of w.calls.filter(c => c.argv[0] === "git")) expect([c.env.GIT_CONFIG_GLOBAL, c.env.GIT_CONFIG_NOSYSTEM]).toEqual(["/dev/null", "1"]);
  expect(done(w)).toHaveLength(1);
});

test("a commit asking for LFS on a host with a global LFS filter and hooks: no host filter or hook runs, no connection", async () => {
  const ctl = join(fx, "control");
  cp.spawnSync("git", ["clone", "-q", `file://${origin}`, ctl], { env: { PATH: process.env.PATH, HOME: home }, encoding: "utf8" });
  const controlRan = fs.existsSync(sentinel);
  fs.rmSync(ctl, { recursive: true, force: true });
  fs.rmSync(sentinel, { force: true });
  expect(controlRan).toBe(true);

  const w = mkWorld({ exec: RESULT });
  await run(w);
  expect(w.events.map(e => e.type)).toEqual(["resolve-ok", "vm-start", "vm-done"]);
  expect(fs.existsSync(sentinel) ? fs.readFileSync(sentinel, "utf8") : "").toBe("");
  expect(connections).toBe(0);
});

test("the host never executes a file from the job tree; the tar carries the .git and its FETCH_HEAD only", async () => {
  const w = mkWorld({ exec: RESULT });
  let tarList = "";
  w.onExec = () => {
    tarList = cp.spawnSync("tar", ["-tf", join(w.stub, "vms", `${PEER}-j2`, "tmp", "job", "src.tar")], { encoding: "utf8" }).stdout;
    return undefined;
  };
  await run(w);
  expect(fs.existsSync(sentinel)).toBe(false);
  const names = tarList.split("\n").filter(Boolean);
  expect(names.filter(n => !n.startsWith(".git/"))).toEqual([]);
  expect(names).toContain(".git/FETCH_HEAD");
  expect(w.calls.every(c => ["git", "python3"].includes(c.argv[0]))).toBe(true);
});

test("a sha reachable only from refs/pull/1/head is refused unknown-sha and nothing runs", async () => {
  const w = mkWorld({ peerSha: sha.pr, exec: RESULT });
  await run(w);
  expect(w.events).toEqual([{ type: "resolve-fail", refused: "unknown-sha" }]);
  expect(w.stubCalls().map(c => c.verb)).toEqual(["vm-sweep"]);
});

test("a sha the cache never saw is refused unknown-sha", async () => {
  const w = mkWorld({ peerSha: "f".repeat(40), exec: RESULT });
  await run(w);
  expect(w.events).toEqual([{ type: "resolve-fail", refused: "unknown-sha" }]);
});

test("a branch cut before MIN_SHA is refused too-old", async () => {
  const w = mkWorld({ peerSha: sha.old, exec: RESULT });
  await run(w);
  expect(w.events).toEqual([{ type: "resolve-fail", refused: "too-old" }]);
});

test("MIN_SHA is the recorded min-sha.txt", () => {
  expect(MIN_SHA).toBe(fs.readFileSync(join(import.meta.dir, "min-sha.txt"), "utf8").trim());
  expect(MIN_SHA).toMatch(/^[0-9a-f]{40}$/);
});

test("vm-sweep runs at start, before anything else", async () => {
  const w = mkWorld({ exec: RESULT });
  await run(w);
  expect(w.stubCalls()[0].verb).toBe("vm-sweep");
});

test("no backend: start refuses and nothing is cloned", async () => {
  const w = mkWorld({ exec: RESULT, env: { PEER_JOB_BACKEND: "" } });
  await expect(start(w.deps)).rejects.toBeInstanceOf(RunnerRefused);
  expect(w.calls.map(c => c.argv[2])).toEqual(["vm-sweep"]);
});

test("the backstop comes from the RUNNING record", async () => {
  const w = mkWorld({ exec: RESULT });
  w.backstop = 4321;
  await run(w);
  const exec = w.calls.find(c => c.argv.includes("vm-exec"))!.argv;
  expect([exec[exec.indexOf("--timeout") + 1], exec.at(-1)]).toEqual(["4321", "4321"]);
});

test("a full run submits vm-done with the outcomes, the golden digest and integer minutes", async () => {
  const w = mkWorld({ exec: RESULT });
  await run(w);
  const [d] = done(w) as any[];
  expect(d.results).toEqual(["pass", "fail"]);
  expect(d.golden).toBe("ab".repeat(32));
  expect(Number.isSafeInteger(d.runner_minutes)).toBe(true);
  expect(w.jobs().find(j => j.jobNo === 2)!.state).toBe("DONE");
  expect(w.stubCalls().at(-1).verb).toBe("vm-destroy");
});

test("the log is kept 0600 under S/<peer>/logs and only its sha256 and size are submitted", async () => {
  const w = mkWorld({ exec: RESULT });
  await run(w);
  const log = join(w.S, PEER, "logs", "2.log");
  expect(fs.statSync(log).mode & 0o777).toBe(0o600);
  const [d] = done(w) as any[];
  expect([d.log_sha256, d.log_bytes]).toEqual([createHash("sha256").update("suite log\n").digest("hex"), 10]);
  expect(JSON.stringify(w.events)).not.toContain("suite log");
});

test("logs older than 14 days are deleted at start", async () => {
  const w = mkWorld({ exec: RESULT });
  const dir = join(w.S, PEER, "logs");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(join(dir, "1.log"), "old");
  fs.writeFileSync(join(dir, "0.log"), "fresh");
  const nowMs = NOW_S * 1000;
  w.deps.now = () => nowMs;
  fs.utimesSync(join(dir, "1.log"), (nowMs - 15 * 86_400_000) / 1000, (nowMs - 15 * 86_400_000) / 1000);
  fs.utimesSync(join(dir, "0.log"), nowMs / 1000, nowMs / 1000);
  await start(w.deps);
  expect(fs.readdirSync(dir).sort()).toEqual(["0.log"]);
});

test.each([
  ["a malformed result file", { files: { ".job-result.json": "{not json", "job.log": "x" } }, ["error", "error"]],
  ["no result file", { files: { "job.log": "x" } }, ["error", "error"]],
  ["a result with one suite missing", { files: { ".job-result.json": JSON.stringify({ results: [{ suite: 0, outcome: "pass" }], minutes: 1 }), "job.log": "x" } }, ["pass", "error"]],
  ["a result with an unknown outcome", { files: { ".job-result.json": JSON.stringify({ results: [{ suite: 0, outcome: "skipped" }], minutes: 1 }), "job.log": "x" } }, ["error", "error"]],
  ["a timed-out exec keeps the finished suites", { hang: true, files: { ".job-result.json": JSON.stringify({ results: [{ suite: 0, outcome: "pass" }], minutes: 1 }) } }, ["pass", "error"]],
])("%s gives the right outcomes", async (_name, exec, want) => {
  const w = mkWorld({ exec });
  await run(w);
  expect((done(w)[0] as any).results).toEqual(want);
  expect(w.stubCalls().at(-1).verb).toBe("vm-destroy");
});

test.each([
  ["vm-clone", ["error", "error"]],
  ["vm-push", ["error", "error"]],
  ["vm-exec", ["pass", "fail"]],
  ["vm-pull", ["error", "error"]],
])("a %s failure still destroys the VM; only suites the guest finished keep an outcome", async (verb, want) => {
  const w = mkWorld({ exec: RESULT, fail: { [verb]: 1 } });
  await run(w);
  expect(w.stubCalls().at(-1).verb).toBe("vm-destroy");
  expect((done(w)[0] as any).results).toEqual(want);
  expect(fs.existsSync(join(w.S, PEER, "jobs", "2"))).toBe(false);
});

test("a job cancelled or killed mid-exec: the exec is stopped, the VM destroyed, nothing is submitted", async () => {
  const w = mkWorld({ exec: RESULT });
  w.onExec = ww => {
    const job = ww.jobs().find(j => j.jobNo === 2)!;
    ww.put(step(job, { type: "kill" }, NOW_S + 120).record);
    return ["tail", "-f", "/dev/null"];
  };
  await run(w);
  expect(w.jobs().find(j => j.jobNo === 2)!.state).toBe("CANCELLED");
  expect(done(w)).toEqual([]);
  expect(w.calls.at(-1)!.argv.slice(2, 3)).toEqual(["vm-destroy"]);
});

test("only the oldest APPROVED job starts, and none while one is RUNNING", async () => {
  const w = mkWorld({ exec: RESULT });
  w.put({ ...inJob({ peer: PEER, jobNo: 3, created: NOW_S - 10, peer_sha: sha.tip }), state: "RUNNING", running_at: NOW_S, backstop_s: 3600 });
  await run(w);
  expect(w.events.map(e => e.type)).toEqual(["resolve-ok"]);
  expect(w.stubCalls().map(c => c.verb)).toEqual(["vm-sweep"]);
});
