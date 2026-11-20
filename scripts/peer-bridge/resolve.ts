// The resolver: what a chief sees. Every shown value is one this station
// produced or looked up by a key it issued itself (§7a); a peer value is compared
// against ours or kept in a `peer_*` field the formatter below never prints. The
// only formatter is `render`, so one test pins the whole output.
import type { AllowEntry } from "./config";
import { DEFAULT_BUDGETS } from "./config";
import { RANGES, type CapacityState, type Envelope, type Outcome, type Refused } from "./envelope";
import { isTerminal } from "./jobstate";

export type JobRecord = {
  kind: "job";
  jobNo: number;                // our job number, J<n>
  peer: string;
  dir: "out" | "in";            // out: we asked a peer; in: a peer asked us
  state: string;
  by: number | null;            // absolute deadline, UTC seconds
  created: number;
  req_exp: number;              // the req's exp, from which the deadlines hang
  sha?: string;                 // out: the SHA we recorded; in: the SHA resolved in our own clone
  suites: string[];             // out: the paths we recorded; in: the aliases our operator typed
  paths?: string[];             // in: our allowlist's paths for those aliases
  wire_job?: string;            // out: the job id we minted
  resolved_at?: number;
  running_at?: number;
  ended_at?: number;
  backstop_s?: number;          // in: the job backstop the poller computed at vm-start
  results?: Outcome[];
  minutes?: number;             // in: charged from RUNNING entry to the end
  runner_minutes?: number;      // in: what our runner reported after the job was over, accounting only
  golden?: string;              // in: our image digest, reported with the result
  log_sha256?: string;          // in: our own log's hash and size
  log_bytes?: number;
  image?: "pinned" | "unpinned";
  refused?: Refused;
  malformed?: boolean;
  late?: string;                // the state of a res that arrived after the job was over
  // What the peer wrote. Stored for matching and echoing, never printed.
  peer_job?: string;
  peer_sha?: string;
  peer_suites?: string[];
  peer_minutes?: number;
  peer_image?: string;
  peer_log_sha256?: string;
  peer_log_bytes?: number;
  peer_timeout_s?: number;
};
export type JobRecordPatch = Partial<JobRecord>;

export const bucket5 = (n: number): number => Math.ceil(n / 5) * 5;
const sha7 = (s: string): string => s.slice(0, 7);

type Req = Extract<Envelope, { kind: "req" }>;

// The server's side of a req: each requested suite must equal a path in its own
// allowlist, and is then stored by the alias its operator typed. The SHA stays the
// peer's string until runner.ts resolves it in our own clone (unknown-sha, too-old).
export function resolveReq(env: Req, allow: AllowEntry[]):
  | { ok: true; record: Pick<JobRecord, "dir" | "suites" | "paths" | "peer_job" | "peer_sha" | "peer_suites" | "req_exp"> }
  | { ok: false; refused: "not-allowed"; record: Pick<JobRecord, "dir" | "suites" | "paths" | "peer_job" | "peer_sha" | "peer_suites" | "req_exp"> } {
  const base = { dir: "in" as const, peer_job: env.job, peer_sha: env.sha, peer_suites: [...env.suites], req_exp: env.exp };
  const hits = env.suites.map(p => allow.find(a => a.path === p));
  if (hits.some(h => h === undefined)) return { ok: false, refused: "not-allowed", record: { ...base, suites: [], paths: [] } };
  return { ok: true, record: { ...base, suites: hits.map(h => h!.alias), paths: hits.map(h => h!.path) } };
}

// The requester's side of a res: a res for a job we never sent is dropped (null).
// A res for a job that is already over is recorded as late and changes nothing else.
export function resolveRes(env: Envelope, job: JobRecord | undefined, ctx: { imageDigest?: string } = {}): JobRecordPatch | null {
  if (env.kind !== "res" || !job || job.dir !== "out" || job.wire_job !== env.job) return null;
  if (isTerminal(job)) return { late: env.state };
  switch (env.state) {
    case "refused": return { refused: env.refused };
    case "running": return { peer_timeout_s: env.timeout_s };
    case "done": {
      if (env.results.length !== job.suites.length) return { malformed: true };
      return {
        results: [...env.results],
        peer_minutes: env.minutes,
        image: ctx.imageDigest !== undefined && env.image === ctx.imageDigest ? "pinned" : "unpinned",
        peer_image: env.image,
        peer_log_sha256: env.log.sha256,
        peer_log_bytes: env.log.bytes,
      };
    }
    default: return {};
  }
}

export type CapacityView = { state: CapacityState; capacity: "ok" | "low" | "none"; queue: "free" | "full" };

// "Low" is under a fifth of the default day's budget; the peer's real budget is its own.
export function resolveCapacity(env: Envelope): CapacityView {
  if (env.kind !== "capacity") throw new Error("not a capacity envelope");
  const none = env.state === "not-served" || env.state === "no-vm" || env.jobs_left === 0 || env.vm_minutes_left === 0;
  const low = env.jobs_left < DEFAULT_BUDGETS.jobsPerDay / 5 || env.vm_minutes_left < DEFAULT_BUDGETS.vmMinutesPerDay / 5;
  return { state: env.state, capacity: none ? "none" : low ? "low" : "ok", queue: env.queue >= RANGES.queue[1] ? "full" : "free" };
}

export const renderCapacity = (peer: string, c: CapacityView): string => `${peer} capacity: ${c.capacity}, queue: ${c.queue}, station: ${c.state}`;

const shaLine = (r: JobRecord): string => (r.sha ? sha7(r.sha) : "unresolved");

// Detail for `show`. It names fields one by one: a new record field is invisible
// until someone adds it here, and nothing named `peer_*` is read at all.
export function render(r: JobRecord): string {
  const lines = [`J${r.jobNo} ${r.peer} ${r.dir === "out" ? "sent" : "received"} ${r.state}`];
  lines.push(`sha: ${shaLine(r)}`);
  if (r.refused) lines.push(`refused: ${r.refused}`);
  if (r.malformed) lines.push("result: malformed");
  if (r.suites.length > 0) {
    lines.push("suites:");
    r.suites.forEach((s, i) => lines.push(r.results && !r.malformed && r.results[i] ? `  ${s}: ${r.results[i]}` : `  ${s}`));
  }
  const mins = r.dir === "out" ? r.peer_minutes : r.minutes;
  if (mins !== undefined && !r.malformed) lines.push(`minutes: ${bucket5(mins)}`);
  if (r.image) lines.push(`image: ${r.image}`);
  if (r.dir === "out" && r.peer_log_sha256 !== undefined) lines.push("log: kept on peer");
  if (r.late) lines.push(`late: ${r.late}`);
  return lines.join("\n");
}

// One line for `list`.
export function renderLine(r: JobRecord): string {
  return `J${r.jobNo} ${r.peer} ${r.dir === "out" ? "sent" : "received"} ${r.state} ${shaLine(r)} ${r.suites.length} suite${r.suites.length === 1 ? "" : "s"}`;
}
