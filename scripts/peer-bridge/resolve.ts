import type { AllowEntry } from "./config";
import { DEFAULT_BUDGETS } from "./config";
import { RANGES, type CapacityState, type Envelope, type Outcome, type Refused } from "./envelope";
import { isTerminal } from "./jobstate";

export type JobRecord = {
  kind: "job";
  jobNo: number;
  peer: string;
  dir: "out" | "in";
  state: string;
  by: number | null;
  created: number;
  req_exp: number;
  sha?: string;
  suites: string[];
  paths?: string[];
  wire_job?: string;
  resolved_at?: number;
  running_at?: number;
  ended_at?: number;
  backstop_s?: number;
  results?: Outcome[];
  minutes?: number;
  runner_minutes?: number;
  golden?: string;
  log_sha256?: string;
  log_bytes?: number;
  image?: "pinned" | "unpinned";
  refused?: Refused;
  malformed?: boolean;
  late?: string;
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

const LOW_SHARE = 0.2;

export const bucket5 =(n: number): number => Math.ceil(n / 5) * 5;
const sha7 = (s: string): string => s.slice(0, 7);

type Req = Extract<Envelope, { kind: "req" }>;

export function resolveReq(env: Req, allow: AllowEntry[]):
  | { ok: true; record: Pick<JobRecord, "dir" | "suites" | "paths" | "peer_job" | "peer_sha" | "peer_suites" | "req_exp"> }
  | { ok: false; refused: "not-allowed"; record: Pick<JobRecord, "dir" | "suites" | "paths" | "peer_job" | "peer_sha" | "peer_suites" | "req_exp"> } {
  const base = { dir: "in" as const, peer_job: env.job, peer_sha: env.sha, peer_suites: [...env.suites], req_exp: env.exp };
  const hits = env.suites.map(p => allow.find(a => a.path === p));
  if (hits.some(h => h === undefined)) return { ok: false, refused: "not-allowed", record: { ...base, suites: [], paths: [] } };
  return { ok: true, record: { ...base, suites: hits.map(h => h!.alias), paths: hits.map(h => h!.path) } };
}

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

export function resolveCapacity(env: Envelope): CapacityView {
  if (env.kind !== "capacity") throw new Error("not a capacity envelope");
  const none = env.state === "not-served" || env.state === "no-vm" || env.jobs_left === 0 || env.vm_minutes_left === 0;
  const low = env.jobs_left < DEFAULT_BUDGETS.jobsPerDay * LOW_SHARE || env.vm_minutes_left < DEFAULT_BUDGETS.vmMinutesPerDay * LOW_SHARE;
  return { state: env.state, capacity: none ? "none" : low ? "low" : "ok", queue: env.queue >= RANGES.queue[1] ? "full" : "free" };
}

export const renderCapacity = (peer: string, c: CapacityView): string => `${peer} capacity: ${c.capacity}, queue: ${c.queue}, station: ${c.state}`;

const shaLine = (r: JobRecord): string => (r.sha ? sha7(r.sha) : "unresolved");

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

export function renderLine(r: JobRecord): string {
  return `J${r.jobNo} ${r.peer} ${r.dir === "out" ? "sent" : "received"} ${r.state} ${shaLine(r)} ${r.suites.length} suite${r.suites.length === 1 ? "" : "s"}`;
}
