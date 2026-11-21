// runner.ts - the serving side of the peer bridge's run-suite jobs. It is a user
// unit, installed only on a station whose peers.json lists run-suite in some
// peer's `serves`. It reads jobs.jsonl, never writes a chain file, and moves a
// job only by submitting events through the peer's spool.
//
// Exit: 0 refused (says why; the unit does not restart), 1 error.
import { createHash } from "node:crypto";
import fs, { constants } from "node:fs";
import { join } from "node:path";
import { acquirePidLock, readChain } from "./chain";
import { readPeersFile, type Config } from "./config";
import { ALLOWANCE_S, OUTCOMES, type Outcome } from "./envelope";
import { configDir, peersFile, stateDir } from "./ids";
import { procHooks, runProc } from "./proc";
import type { JobRecord } from "./resolve";
import { writeSpoolEvent, type SpoolJobEvent } from "./spool-events";

export const MIN_SHA = fs.readFileSync(join(import.meta.dir, "min-sha.txt"), "utf8").trim();
const SHA_RE = /^[0-9a-f]{40}$/;
const RESULT_MAX = 16384;
const LOG_MAX = 5 * 1024 * 1024;
const LOG_KEEP_MS = 14 * 86_400_000;
const TICK_MS = 30_000;
const GIT_TIMEOUT_MS = 10 * 60_000;
const VM_TIMEOUT_MS = 30 * 60_000;
const EXIT_REFUSED = 2;

export class RunnerRefused extends Error {
  constructor(message: string) { super(message); this.name = "RunnerRefused"; }
}

export class RunnerFatal extends Error {
  constructor(message: string) { super(message); this.name = "RunnerFatal"; }
}

export type RunnerDeps = {
  cfg: Config;
  reload?: () => Config;
  stateDir: string;
  configDir: string;
  minSha: string;
  env: NodeJS.ProcessEnv;
  now: () => number;
  watchMs: number;
  submit: (peer: string, job: number, event: SpoolJobEvent) => Promise<boolean>;
  log: (line: string) => void;
};

const peerDir = (deps: RunnerDeps, peer: string) => join(deps.stateDir, peer);
const cacheDir = (deps: RunnerDeps, peer: string) => join(deps.stateDir, "cache", peer);
const vmsdkJob = (deps: RunnerDeps) => join(deps.cfg.himmelRoot, "scripts", "lib", "vmsdk-job.py");

function gitEnv(deps: RunnerDeps): NodeJS.ProcessEnv {
  return { PATH: deps.env.PATH ?? "/usr/bin:/bin", HOME: deps.env.HOME ?? "/nonexistent", GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", GIT_TERMINAL_PROMPT: "0" };
}

function vmEnv(deps: RunnerDeps): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { PATH: deps.env.PATH ?? "/usr/bin:/bin", HOME: deps.env.HOME ?? "/nonexistent" };
  for (const k of ["PEER_JOB_BACKEND", "PEER_JOB_STUB_DIR", "VBOXMANAGE_PATH"]) if (deps.env[k] !== undefined) env[k] = deps.env[k];
  return env;
}

async function git(deps: RunnerDeps, cwd: string | null, ...argv: string[]): Promise<{ code: number | null; stdout: string }> {
  const r = await runProc(["git", "-c", "core.hooksPath=/dev/null", ...(cwd ? ["-C", cwd] : []), ...argv], { env: gitEnv(deps), timeoutMs: GIT_TIMEOUT_MS });
  return { code: r.code, stdout: r.stdout };
}

async function vm(deps: RunnerDeps, ...argv: string[]): Promise<number | null> {
  const r = await runProc(["python3", vmsdkJob(deps), ...argv], { env: vmEnv(deps), timeoutMs: VM_TIMEOUT_MS });
  if (r.code !== 0) deps.log(`runner: ${argv[0]} exited ${r.code}: ${r.stderr.trim().slice(0, 300)}`);
  return r.code;
}

function vmExec(deps: RunnerDeps, id: string, backstop: number, live: () => boolean): Promise<{ code: number | null; stopped: boolean }> {
  return new Promise(resolve => {
    const b = String(backstop);
    const child = procHooks.spawn("python3", [vmsdkJob(deps), "vm-exec", id, "--timeout", b, "--", "bash", "/tmp/job/job-entry.sh", "/tmp/job/suites.txt", b], { env: vmEnv(deps), stdio: ["ignore", "ignore", "ignore"] });
    let stopped = false, finished = false;
    const watch = setInterval(() => { if (!live()) { stopped = true; child.kill("SIGKILL"); } }, deps.watchMs);
    const hard = setTimeout(() => { stopped = true; child.kill("SIGKILL"); }, (backstop + ALLOWANCE_S) * 1000);
    const finish = (code: number | null) => { if (finished) return; finished = true; clearInterval(watch); clearTimeout(hard); resolve({ code, stopped }); };
    child.once("error", () => finish(null));
    child.once("close", code => finish(code));
  });
}

function jobsOf(deps: RunnerDeps, peer: string): JobRecord[] {
  const m = new Map<number, JobRecord>();
  for (const r of readChain(join(peerDir(deps, peer), "jobs.jsonl"))) if (r.kind === "job") m.set(r.jobNo as number, r as unknown as JobRecord);
  return [...m.values()].filter(j => j.dir === "in" && j.peer === peer);
}

const servingPeers = (deps: RunnerDeps): string[] => Object.keys(deps.cfg.peers).filter(p => deps.cfg.peers[p].serves?.includes("run-suite"));

async function resolveJob(deps: RunnerDeps, peer: string, j: JobRecord): Promise<void> {
  const url = deps.cfg.peers[peer].repoUrl, sha = j.peer_sha;
  if (!url) return deps.log(`runner: ${peer} has no repoUrl; job ${j.jobNo} waits`);
  if (!sha || !SHA_RE.test(sha)) return deps.log(`runner: job ${j.jobNo} has no sha`);
  const cache = cacheDir(deps, peer);
  if (!fs.existsSync(join(cache, "HEAD"))) {
    fs.mkdirSync(cache, { recursive: true, mode: 0o700 });
    if ((await git(deps, null, "init", "-q", "--bare", cache)).code !== 0) return deps.log(`runner: cannot create the cache for ${peer}`);
  }
  if ((await git(deps, cache, "fetch", "-q", "--prune", url, "+refs/heads/*:refs/remotes/origin/*")).code !== 0) return deps.log(`runner: fetch from ${peer}'s repoUrl failed; job ${j.jobNo} waits`);
  let refused: "unknown-sha" | "too-old" | undefined;
  if ((await git(deps, cache, "cat-file", "-e", `${sha}^{commit}`)).code !== 0) refused = "unknown-sha";
  else {
    const on = await git(deps, cache, "branch", "-r", "--contains", sha);
    if (on.code !== 0 || on.stdout.trim() === "") refused = "unknown-sha";
    else if ((await git(deps, cache, "merge-base", "--is-ancestor", deps.minSha, sha)).code !== 0) refused = "too-old";
  }
  await deps.submit(peer, j.jobNo, refused ? { type: "resolve-fail", refused } : { type: "resolve-ok", sha });
}

function tarHeader(name: string, size: number, type: "0" | "5", mode: number, mtime: number): Buffer {
  let prefix = "", base = name;
  if (name.length > 100) {
    const i = name.indexOf("/", name.length - 101);
    if (i < 0 || i > 155) throw new Error(`path too long for ustar: ${name}`);
    prefix = name.slice(0, i);
    base = name.slice(i + 1);
  }
  const h = Buffer.alloc(512);
  const put = (s: string, at: number, len: number) => h.write(s, at, len, "ascii");
  const oct = (n: number, len: number) => n.toString(8).padStart(len - 1, "0") + "\0";
  put(base, 0, 100);
  put(oct(mode, 8), 100, 8);
  put(oct(0, 8), 108, 8);
  put(oct(0, 8), 116, 8);
  put(oct(size, 12), 124, 12);
  put(oct(mtime, 12), 136, 12);
  put("        ", 148, 8);
  put(type, 156, 1);
  put("ustar\0", 257, 6);
  put("00", 263, 2);
  put(prefix, 345, 155);
  let sum = 0;
  for (const b of h) sum += b;
  put(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8);
  return h;
}

function tarDir(root: string, top: string, out: string): void {
  const fd = fs.openSync(out, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    const walk = (rel: string) => {
      const st = fs.lstatSync(join(root, rel));
      const mtime = Math.floor(st.mtimeMs / 1000);
      if (st.isDirectory()) {
        fs.writeSync(fd, tarHeader(`${rel}/`, 0, "5", 0o755, mtime));
        for (const n of fs.readdirSync(join(root, rel)).sort()) walk(`${rel}/${n}`);
      } else if (st.isFile()) {
        const data = fs.readFileSync(join(root, rel));
        fs.writeSync(fd, tarHeader(rel, data.length, "0", 0o644, mtime));
        fs.writeSync(fd, data);
        fs.writeSync(fd, Buffer.alloc((512 - (data.length % 512)) % 512));
      } else throw new Error(`not a file or directory: ${rel}`);
    };
    walk(top);
    fs.writeSync(fd, Buffer.alloc(1024));
  } finally { fs.closeSync(fd); }
}

export function parseResult(text: string | null, n: number): Outcome[] {
  const out: Outcome[] = Array(n).fill("error");
  if (text === null) return out;
  let doc: any;
  try { doc = JSON.parse(text); } catch { return out; }
  if (!doc || !Array.isArray(doc.results)) return out;
  const got: Outcome[] = [...out];
  for (const r of doc.results) {
    if (!r || !Number.isSafeInteger(r.suite) || r.suite < 0 || r.suite >= n || !OUTCOMES.includes(r.outcome)) return out;
    got[r.suite] = r.outcome;
  }
  return got;
}

const readIf = (path: string): string | null => { try { return fs.readFileSync(path, "utf8"); } catch { return null; } };

function golden(deps: RunnerDeps): string | undefined {
  const d = (readIf(join(deps.configDir, "golden.digest")) ?? "").trim();
  return /^[0-9a-f]{64}$/.test(d) ? d : undefined;
}

async function runJob(deps: RunnerDeps, peer: string, j: JobRecord): Promise<void> {
  if (!(await deps.submit(peer, j.jobNo, { type: "vm-start" }))) return;
  const current = () => jobsOf(deps, peer).find(r => r.jobNo === j.jobNo);
  const rec = current();
  if (rec?.state !== "RUNNING" || !rec.backstop_s || !rec.sha || !SHA_RE.test(rec.sha)) return;
  const live = () => current()?.state === "RUNNING";
  const n = rec.suites.length, paths = rec.paths ?? [];
  const id = `${peer}-j${j.jobNo}`;
  const work = join(peerDir(deps, peer), "jobs", String(j.jobNo));
  const logs = join(peerDir(deps, peer), "logs");
  let results: Outcome[] = Array(n).fill("error");
  let log: { log_sha256: string; log_bytes: number } | undefined;
  let stopped = false, destroyed = false, t0 = deps.now();
  try {
    const src = join(work, "src"), from = `file://${cacheDir(deps, peer)}`;
    fs.rmSync(work, { recursive: true, force: true });
    fs.mkdirSync(src, { recursive: true, mode: 0o700 });
    if ((await git(deps, null, "init", "-q", src)).code !== 0) throw new Error("git init failed");
    if ((await git(deps, src, "fetch", "-q", "--depth", "1", from, rec.sha)).code !== 0) throw new Error("fetch of the job's commit failed");
    tarDir(src, ".git", join(work, "src.tar"));
    fs.writeFileSync(join(work, "suites.txt"), paths.map(p => `${p}\n`).join(""), { mode: 0o600 });
    t0 = deps.now();
    if ((await vm(deps, "vm-clone", id)) !== 0) throw new Error("vm-clone failed");
    for (const f of [join(work, "src.tar"), join(deps.cfg.himmelRoot, "scripts", "peer-bridge", "job-entry.sh"), join(work, "suites.txt")]) {
      if ((await vm(deps, "vm-push", id, f)) !== 0) throw new Error("vm-push failed");
    }
    const exec = await vmExec(deps, id, rec.backstop_s, live);
    stopped = exec.stopped || !live();
    if (!stopped) {
      if (exec.code !== 0 && exec.code !== 124) deps.log(`runner: vm-exec for job ${j.jobNo} exited ${exec.code}`);
      const resultFile = join(work, "result.json");
      if ((await vm(deps, "vm-pull", id, "/tmp/job/.job-result.json", resultFile, "--max-bytes", String(RESULT_MAX))) !== 0) throw new Error("vm-pull of the result failed");
      results = parseResult(readIf(resultFile), n);
      fs.mkdirSync(logs, { recursive: true, mode: 0o700 });
      const logFile = join(logs, `${j.jobNo}.log`);
      if ((await vm(deps, "vm-pull", id, "/tmp/job/job.log", logFile, "--max-bytes", String(LOG_MAX))) === 0) {
        const bytes = fs.readFileSync(logFile);
        log = { log_sha256: createHash("sha256").update(bytes).digest("hex"), log_bytes: bytes.length };
      }
    }
  } catch (e) {
    results = Array(n).fill("error");
    deps.log(`runner: job ${j.jobNo}: ${(e as Error).message}`);
  } finally {
    destroyed = (await vm(deps, "vm-destroy", id)) === 0;
    fs.rmSync(work, { recursive: true, force: true });
  }
  let failed: unknown;
  try {
    if (!stopped && live()) {
      const runner_minutes = Math.max(0, Math.ceil((deps.now() - t0) / 60_000));
      await deps.submit(peer, j.jobNo, { type: "vm-done", results, golden: golden(deps), ...log, runner_minutes });
    }
  } catch (e) { failed = e; }
  if (!destroyed) throw new RunnerFatal(`vm-destroy ${id} failed; exiting so the restart sweeps it`);
  if (failed) throw failed;
}

function sweepLogs(deps: RunnerDeps): void {
  for (const peer of servingPeers(deps)) {
    const dir = join(peerDir(deps, peer), "logs");
    let names: string[];
    try { names = fs.readdirSync(dir); } catch { continue; }
    for (const n of names) {
      try { if (deps.now() - fs.statSync(join(dir, n)).mtimeMs > LOG_KEEP_MS) fs.rmSync(join(dir, n), { force: true }); } catch {}
    }
  }
}

export async function start(deps: RunnerDeps): Promise<void> {
  const code = await vm(deps, "vm-sweep");
  if (code === EXIT_REFUSED) throw new RunnerRefused("no VM backend (vmsdk-job.py vm-sweep refused)");
  if (code !== 0) throw new Error(`vm-sweep exited ${code}`);
  sweepLogs(deps);
}

export async function tick(deps: RunnerDeps): Promise<void> {
  if (deps.reload) deps.cfg = deps.reload();
  const peers = servingPeers(deps);
  for (const peer of peers) for (const j of jobsOf(deps, peer)) if (j.state === "RECEIVED") await resolveJob(deps, peer, j);
  const all = peers.flatMap(p => jobsOf(deps, p));
  if (all.some(j => j.state === "RUNNING")) return;
  const next = all.filter(j => j.state === "APPROVED").sort((a, b) => a.created - b.created || a.jobNo - b.jobNo)[0];
  if (next) await runJob(deps, next.peer, next);
}

async function submitAndWait(peer: string, job: number, event: SpoolJobEvent): Promise<boolean> {
  const dir = join(stateDir(), peer);
  const name = writeSpoolEvent({ t: "job-event", peer, job, event }, dir);
  const file = join(dir, "spool", "results", name);
  for (const end = Date.now() + 120_000; Date.now() < end; await Bun.sleep(500)) {
    const text = readIf(file);
    if (text !== null) { try { return JSON.parse(text).ok === true; } catch { return false; } }
  }
  return false;
}

async function main(): Promise<number> {
  const cfg = readPeersFile(peersFile());
  const deps: RunnerDeps = {
    cfg, reload: () => readPeersFile(peersFile()), stateDir: stateDir(), configDir: configDir(), minSha: MIN_SHA, env: process.env, now: Date.now, watchMs: 5000,
    submit: submitAndWait, log: line => process.stderr.write(`${line}\n`),
  };
  if (servingPeers(deps).length === 0) throw new RunnerRefused("no peer lists run-suite in serves");
  const release = acquirePidLock(join(deps.stateDir, "runner.pid"));
  try {
    await start(deps);
    for (;;) {
      try { await tick(deps); } catch (e) { if (e instanceof RunnerFatal) throw e; deps.log(`runner: tick failed: ${(e as Error).message}`); }
      await Bun.sleep(TICK_MS);
    }
  } finally { release(); }
}

if (import.meta.main) {
  main().then(code => process.exit(code), e => {
    if (e instanceof RunnerRefused) { process.stderr.write(`runner: refused: ${e.message}; not restarting\n`); process.exit(0); }
    process.stderr.write(`runner: ${(e as Error).stack ?? e}\n`);
    process.exit(1);
  });
}
