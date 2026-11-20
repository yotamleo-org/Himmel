//   jobs.ts request <peer> run-suite --sha <40hex> --suite <path> [--suite <path>…]
//   jobs.ts capacity <peer> | halt <peer> | cancel <job> | show <job> | list [--peer P] | approve <job>
// Exit: 0 ok, 2 refused (names the rule), 3 not a TTY (approve), 4 queued but unconfirmed: do not resend.
import fs from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { readChain } from "./chain";
import { readPeersFile, type Config } from "./config";
import { SUITE_PATH_RE } from "./envelope";
import { PEER_NAME_RE, peerDir as defaultPeerDir, peersFile } from "./ids";
import { isTerminal } from "./jobstate";
import { runProc } from "./proc";
import { render, renderCapacity, renderLine, type CapacityView, type JobRecord } from "./resolve";
import { writeSpoolEvent } from "./spool-events";

export class JobsError extends Error {
  constructor(public code: 2 | 3 | 4, message: string) { super(message); this.name = "JobsError"; }
}
const refuse = (rule: string, code: 2 | 3 | 4 = 2): never => { throw new JobsError(code, code === 2 ? `refused: ${rule}` : rule); };

export type JobsDeps = {
  cfg: Config;
  peerDir: (peer: string) => string;
  env: NodeJS.ProcessEnv;
  tty: boolean;
  ask: (question: string) => Promise<string>;
  out: (line: string) => void;
  now: () => number;
  waitMs: number;
};

const SHA_RE = /^[0-9a-f]{40}$/;
const JOB_RE = /^J([0-9]{1,9})$/;
const CAPACITY_FRESH_S = 3600;


function peerArg(deps: JobsDeps, peer: string): string {
  if (!PEER_NAME_RE.test(peer)) refuse("bad-peer");
  if (!deps.cfg.peers[peer]) refuse("unknown peer");
  return peer;
}
function jobArg(job: string): number {
  const m = JOB_RE.exec(job);
  return m ? Number(m[1]) : refuse("bad-job");
}


function allJobs(deps: JobsDeps, only?: string): JobRecord[] {
  const m = new Map<number, JobRecord>();
  for (const peer of Object.keys(deps.cfg.peers)) {
    if (only && peer !== only) continue;
    for (const r of readChain(join(deps.peerDir(peer), "jobs.jsonl"))) if (r.kind === "job") m.set(r.jobNo as number, r as unknown as JobRecord);
  }
  return [...m.values()].sort((a, b) => a.jobNo - b.jobNo);
}
function jobOf(deps: JobsDeps, arg: string): JobRecord {
  const n = jobArg(arg);
  return allJobs(deps).find(j => j.jobNo === n) ?? refuse("unknown-job");
}
function lastCapacity(deps: JobsDeps, peer: string): (CapacityView & { ts: number }) | undefined {
  let last: any;
  for (const r of readChain(join(deps.peerDir(peer), "jobs.jsonl"))) if (r.kind === "capacity") last = r;
  return last;
}


async function wait(deps: JobsDeps, peer: string, name: string): Promise<{ ok: true; job?: number } | { ok: false; rule: string }> {
  const file = join(deps.peerDir(peer), "spool", "results", name);
  const deadline = Date.now() + deps.waitMs;
  while (Date.now() < deadline) {
    try {
      const r = JSON.parse(fs.readFileSync(file, "utf8"));
      fs.rmSync(file, { force: true });
      return r;
    } catch (e) { if (!(e instanceof SyntaxError) && (e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
    await new Promise(r => setTimeout(r, 25));
  }
  return refuse(`queued as ${name}; the poller will send it; do not resend`, 4);
}

async function submit(deps: JobsDeps, peer: string, kind: "req" | "capacity-ask" | "cancel" | "halt", body: Record<string, unknown>): Promise<{ job?: number }> {
  const name = writeSpoolEvent({ t: "env-out", peer, kind, body }, deps.peerDir(peer));
  const r = await wait(deps, peer, name);
  if (!r.ok) return refuse(r.rule);
  return r;
}

function setUp(deps: JobsDeps, peer: string): void {
  const p = deps.cfg.peers[peer];
  if (!deps.cfg.self?.stationName || !p.theirs?.stationName || p.chatId === null || p.chatId === undefined) refuse("not-set-up");
}


async function git(deps: JobsDeps, ...argv: string[]): Promise<{ code: number | null; stdout: string }> {
  const r = await runProc(["git", "-C", deps.cfg.himmelRoot, ...argv], { env: { PATH: deps.env.PATH ?? "/usr/bin:/bin", HOME: deps.env.HOME ?? "/nonexistent" }, timeoutMs: 15_000 });
  return { code: r.code, stdout: r.stdout };
}


export async function requestCmd(peerName: string, op: string, sha: string, suites: string[], deps: JobsDeps): Promise<void> {
  const peer = peerArg(deps, peerName);
  if (op !== "run-suite") refuse("bad-op");
  if (!SHA_RE.test(sha)) refuse("bad-sha");
  if (suites.length < 1 || suites.length > 10) refuse("bad-suites");
  for (const s of suites) if (!SUITE_PATH_RE.test(s) || s.includes("..")) refuse("bad-suite");
  setUp(deps, peer);

  const cap = lastCapacity(deps, peer);
  if (cap && deps.now() / 1000 - cap.ts < CAPACITY_FRESH_S) {
    if (cap.state === "not-served") refuse("not-served");
    if (cap.state === "no-vm") refuse("no-vm");
    if (cap.capacity === "none") refuse("no-budget");
  }

  const on = await git(deps, "branch", "-r", "--contains", sha);
  if (on.code !== 0 || !on.stdout.split("\n").some(l => /^\s*origin\/(?!HEAD\b)\S+/.test(l))) refuse("unknown-sha");
  for (const s of suites) if ((await git(deps, "cat-file", "-e", `${sha}:${s}`)).code !== 0) refuse(`suite-missing`);

  const r = await submit(deps, peer, "req", { sha, suites });
  deps.out(`J${r.job} sent to ${peer}`);
}

export async function capacityCmd(peerName: string, deps: JobsDeps): Promise<void> {
  const peer = peerArg(deps, peerName);
  setUp(deps, peer);
  const cap = lastCapacity(deps, peer);
  await submit(deps, peer, "capacity-ask", {});
  if (!cap) deps.out(`asked ${peer}; no capacity answer on record yet`);
  else { deps.out(`asked ${peer}`); deps.out(renderCapacity(peer, cap)); }
}

export async function haltCmd(peerName: string, deps: JobsDeps): Promise<void> {
  const peer = peerArg(deps, peerName);
  setUp(deps, peer);
  await submit(deps, peer, "halt", {});
  deps.out(`halt sent to ${peer}`);
}

export async function cancelCmd(jobArgText: string, deps: JobsDeps): Promise<void> {
  const job = jobOf(deps, jobArgText);
  if (job.dir !== "out") refuse("not a job we sent");
  if (isTerminal(job)) refuse("already over");
  await submit(deps, job.peer, "cancel", { jobNo: job.jobNo });
  deps.out(`cancel sent for J${job.jobNo}`);
}

export async function showCmd(jobArgText: string, deps: JobsDeps): Promise<void> {
  deps.out(render(jobOf(deps, jobArgText)));
}

export async function listCmd(peer: string | undefined, deps: JobsDeps): Promise<void> {
  if (peer !== undefined) peerArg(deps, peer);
  for (const j of allJobs(deps, peer)) deps.out(renderLine(j));
}

function needTerminal(env: NodeJS.ProcessEnv, tty: boolean): void {
  if (env.CLAUDECODE || env.CLAUDE_CODE_SESSION_ID) refuse("run this yourself in a terminal, not from a Claude session", 3);
  if (!tty) refuse("needs a human at a terminal", 3);
}

export async function approveCmd(jobArgText: string, deps: JobsDeps): Promise<void> {
  needTerminal(deps.env, deps.tty);
  const job = jobOf(deps, jobArgText);
  if (job.dir !== "in") refuse("not a job a peer sent");
  if (job.state !== "RESOLVED") refuse("not resolved");
  deps.out(render(job));
  if ((await deps.ask(`Approve J${job.jobNo}? Type yes: `)).trim() !== "yes") refuse("not approved");
  const name = writeSpoolEvent({ t: "job-event", peer: job.peer, job: job.jobNo, event: { type: "approve" } }, deps.peerDir(job.peer));
  const r = await wait(deps, job.peer, name);
  if (!r.ok) refuse(r.rule);
  deps.out(`approved J${job.jobNo}`);
}


export async function main(argv: string[]): Promise<void> {
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  const [cmd, ...a] = argv;
  try {
    const tty = Boolean(process.stdin.isTTY && process.stdout.isTTY);
    if (cmd === "approve") needTerminal(process.env, tty);
    let cfg: Config;
    try { cfg = readPeersFile(peersFile()); } catch { return refuse("not-set-up"); }
    const deps: JobsDeps = {
      cfg, peerDir: defaultPeerDir, env: process.env, tty,
      ask: q => new Promise(res => rl.question(q, res)), out: l => console.log(l), now: Date.now, waitMs: Number(process.env.PEER_JOBS_WAIT_MS) || 10_000,
    };
    if (cmd === "request" && a.length >= 6 && a[1] === "run-suite" && a[2] === "--sha") {
      const suites: string[] = [];
      for (let i = 4; i < a.length; i += 2) { if (a[i] !== "--suite" || a[i + 1] === undefined) return refuse("bad-arguments"); suites.push(a[i + 1]); }
      await requestCmd(a[0], a[1], a[3], suites, deps);
    }
    else if (cmd === "capacity" && a.length === 1) await capacityCmd(a[0], deps);
    else if (cmd === "halt" && a.length === 1) await haltCmd(a[0], deps);
    else if (cmd === "cancel" && a.length === 1) await cancelCmd(a[0], deps);
    else if (cmd === "show" && a.length === 1) await showCmd(a[0], deps);
    else if (cmd === "list" && a.length === 0) await listCmd(undefined, deps);
    else if (cmd === "list" && a.length === 2 && a[0] === "--peer") await listCmd(a[1], deps);
    else if (cmd === "approve" && a.length === 1) await approveCmd(a[0], deps);
    else refuse("usage: jobs.ts request <peer> run-suite --sha <40hex> --suite <path>… | capacity <peer> | halt <peer> | cancel <job> | show <job> | list [--peer P] | approve <job>");
  } catch (e) {
    if (e instanceof JobsError) { console.error(e.message); process.exitCode = e.code; return; }
    throw e;
  } finally { rl.close(); }
}

if (import.meta.main) main(process.argv.slice(2));
