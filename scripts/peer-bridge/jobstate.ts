import { clampToSchema, type Budgets } from "./config";
import { ALLOWANCE_S, TIMEOUT_S_MAX, type Kind, type Outcome, type Refused } from "./envelope";
import type { JobRecord, JobRecordPatch } from "./resolve";

export const SERVER_STATES = ["RECEIVED", "RESOLVED", "APPROVED", "RUNNING", "DONE", "CANCELLED", "EXPIRED", "REFUSED"] as const;
export const REQUESTER_STATES = ["SENT", "ACCEPTED", "RUNNING", "DONE", "REFUSED", "EXPIRED", "CANCELLED", "LOST"] as const;
export type ServerState = (typeof SERVER_STATES)[number];
export type RequesterState = (typeof REQUESTER_STATES)[number];

const SERVER_TERMINAL: readonly string[] = ["DONE", "CANCELLED", "EXPIRED", "REFUSED"];
const REQUESTER_TERMINAL: readonly string[] = ["DONE", "REFUSED", "EXPIRED", "CANCELLED", "LOST"];
const QUEUED: readonly string[] = ["RECEIVED", "RESOLVED", "APPROVED"];

export const RECEIVED_WINDOW_S = 10 * 60;
export const REQUESTER_GRACE_S = 2 * 3600;
const EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

export const isTerminal = (r: Pick<JobRecord, "dir" | "state">): boolean =>
  (r.dir === "out" ? REQUESTER_TERMINAL : SERVER_TERMINAL).includes(r.state);

export type SendSpec = { kind: Kind; body: Record<string, unknown> };
export type ResEventType = "res-accepted" | "res-running" | "res-done" | "res-refused" | "res-expired" | "res-cancelled";
export type JobEvent =
  | { type: "resolve-ok"; sha: string }
  | { type: "resolve-fail"; refused: Refused }
  | { type: "approve" }
  | { type: "vm-start"; backstop_s: number }
  | { type: "vm-done"; results?: Outcome[]; golden?: string; log_sha256?: string; log_bytes?: number; runner_minutes?: number }
  | { type: "cancel" } | { type: "halt" } | { type: "kill" }
  | { type: ResEventType; patch?: JobRecordPatch }
  | { type: "deadline" };
export type StepResult = { record: JobRecord; send?: SendSpec };

export function deadlineFor(r: JobRecord): number | null {
  if (isTerminal(r)) return null;
  if (r.dir === "out") {
    if (r.state === "RUNNING") return (r.running_at ?? r.created) + (r.peer_timeout_s ?? TIMEOUT_S_MAX) + REQUESTER_GRACE_S;
    return r.req_exp + TIMEOUT_S_MAX + REQUESTER_GRACE_S;
  }
  switch (r.state) {
    case "RECEIVED": return r.created + RECEIVED_WINDOW_S;
    case "RESOLVED": case "APPROVED": return r.req_exp;
    case "RUNNING": return (r.running_at ?? r.created) + (r.backstop_s ?? 0) + ALLOWANCE_S;
    default: return null;
  }
}

function enter(r: JobRecord, state: string, now: number, patch: JobRecordPatch = {}): JobRecord {
  const next: JobRecord = { ...r, ...patch, state };
  return isTerminal(next) ? { ...next, by: null, ended_at: now } : { ...next, by: deadlineFor(next) };
}

export function chargedMinutes(r: JobRecord, now?: number): number {
  const end = r.ended_at ?? now;
  if (r.running_at === undefined || end === undefined) return 0;
  return Math.max(0, Math.ceil((end - r.running_at) / 60));
}

const startOfLocalDay = (nowS: number): number => { const d = new Date(nowS * 1000); d.setHours(0, 0, 0, 0); return d.getTime() / 1000; };

export function remaining(records: JobRecord[], budgets: Budgets, now: number): { jobs: number; vmMinutes: number } {
  const day = startOfLocalDay(now);
  const mine = records.filter(r => r.dir === "in");
  const jobs = mine.filter(r => (r.resolved_at ?? (r.state === "RECEIVED" ? r.created : -1)) >= day).length;
  const today = (r: JobRecord): number => r.running_at === undefined ? 0 : Math.max(0, Math.min(r.ended_at ?? now, now) - Math.max(r.running_at, day));
  const used = mine.reduce((n, r) => n + Math.ceil(today(r) / 60), 0);
  return { jobs: Math.max(0, budgets.jobsPerDay - jobs), vmMinutes: Math.max(0, budgets.vmMinutesPerDay - used) };
}

export const queueDepth = (records: JobRecord[]): number => records.filter(r => r.dir === "in" && QUEUED.includes(r.state)).length;

export function dueJobs(records: JobRecord[], now: number): JobRecord[] {
  return records.filter(r => !isTerminal(r) && r.by !== null && r.by <= now).sort((a, b) => a.by! - b.by! || a.jobNo - b.jobNo);
}

export function newOutJob(a: { jobNo: number; peer: string; wireJob: string; sha: string; suites: string[]; reqExp: number; now: number }): JobRecord {
  const r: JobRecord = { kind: "job", jobNo: a.jobNo, peer: a.peer, dir: "out", state: "SENT", by: null, created: a.now, req_exp: a.reqExp, sha: a.sha, suites: [...a.suites], wire_job: a.wireJob };
  return { ...r, by: deadlineFor(r) };
}

export function newInJob(a: { jobNo: number; peer: string; now: number; fields: Pick<JobRecord, "suites" | "paths" | "peer_job" | "peer_sha" | "peer_suites" | "req_exp"> }): JobRecord {
  const r: JobRecord = { kind: "job", jobNo: a.jobNo, peer: a.peer, dir: "in", state: "RECEIVED", by: null, created: a.now, ...a.fields };
  return { ...r, by: deadlineFor(r) };
}


const res = (r: JobRecord, body: Record<string, unknown>): SendSpec => ({ kind: "res", body: { job: r.peer_job, ...body } });
type Handler = (r: JobRecord, e: any, now: number) => StepResult;

const cancelled: Handler = (r, _e, now) => ({ record: enter(r, "CANCELLED", now), send: res(r, { state: "cancelled" }) });
const killed: Handler = (r, _e, now) => ({ record: enter(r, "CANCELLED", now) });
const expired: Handler = (r, _e, now) => ({ record: enter(r, "EXPIRED", now), send: res(r, { state: "expired" }) });

function finish(r: JobRecord, now: number, e: { results?: Outcome[]; golden?: string; log_sha256?: string; log_bytes?: number }): StepResult {
  const n = r.paths?.length ?? r.suites.length;
  const results: Outcome[] = e.results && e.results.length === n ? [...e.results] : Array(n).fill("error");
  const ended = enter(r, "DONE", now, { golden: e.golden ?? r.golden, log_sha256: e.log_sha256 ?? r.log_sha256, log_bytes: e.log_bytes ?? r.log_bytes, results });
  const record = { ...ended, minutes: chargedMinutes(ended) };
  return {
    record,
    send: res(r, {
      state: "done", results, minutes: clampToSchema("minutes", record.minutes), image: record.golden ?? "0".repeat(64),
      log: { sha256: record.log_sha256 ?? EMPTY_SHA256, bytes: clampToSchema("bytes", record.log_bytes ?? 0) },
    }),
  };
}

const SERVER: Record<string, Handler> = {
  "RECEIVED:resolve-ok": (r, e, now) => ({ record: enter(r, "RESOLVED", now, { sha: e.sha, resolved_at: now }), send: res(r, { state: "accepted" }) }),
  "RECEIVED:resolve-fail": (r, e, now) => ({ record: enter(r, "REFUSED", now, { refused: e.refused }), send: res(r, { state: "refused", refused: e.refused }) }),
  "RECEIVED:cancel": cancelled, "RECEIVED:halt": cancelled, "RECEIVED:kill": killed,
  "RECEIVED:deadline": (r, _e, now) => ({ record: enter(r, "REFUSED", now, { refused: "no-vm" }), send: res(r, { state: "refused", refused: "no-vm" }) }),

  "RESOLVED:approve": (r, _e, now) => ({ record: enter(r, "APPROVED", now) }),
  "RESOLVED:cancel": cancelled, "RESOLVED:halt": cancelled, "RESOLVED:kill": killed, "RESOLVED:deadline": expired,

  "APPROVED:vm-start": (r, e, now) => e.backstop_s >= ALLOWANCE_S
    ? { record: enter(r, "RUNNING", now, { running_at: now, backstop_s: e.backstop_s }), send: res(r, { state: "running", timeout_s: Math.min(TIMEOUT_S_MAX, e.backstop_s + ALLOWANCE_S) }) }
    : { record: enter(r, "REFUSED", now, { refused: "budget" }), send: res(r, { state: "refused", refused: "budget" }) },
  "APPROVED:cancel": cancelled, "APPROVED:halt": cancelled, "APPROVED:kill": killed, "APPROVED:deadline": expired,

  "RUNNING:vm-done": (r, e, now) => finish(r, now, e),
  "RUNNING:cancel": cancelled, "RUNNING:halt": cancelled, "RUNNING:kill": killed,
  "RUNNING:deadline": (r, _e, now) => finish(r, now, {}),
};
for (const s of SERVER_TERMINAL) SERVER[`${s}:vm-done`] = (r, e) => ({ record: e.runner_minutes === undefined ? r : { ...r, runner_minutes: e.runner_minutes } });


const merged = (r: JobRecord, e: { patch?: JobRecordPatch }): JobRecord => ({ ...r, ...(e.patch ?? {}) });
const toState = (state: string): Handler => (r, e, now) => ({ record: enter(merged(r, e), state, now) });
const toRunning: Handler = (r, e, now) => ({ record: enter(merged(r, e), "RUNNING", now, { running_at: now }) });
const lost: Handler = (r, _e, now) => ({ record: enter(r, "LOST", now) });
const late: Handler = (r, e) => ({ record: e.patch?.late === undefined ? r : { ...r, late: e.patch.late } });

const REQUESTER: Record<string, Handler> = {
  "SENT:res-accepted": toState("ACCEPTED"), "SENT:res-running": toRunning,
  "SENT:deadline": (r, _e, now) => ({ record: enter(r, "LOST", now), send: { kind: "cancel", body: { job: r.wire_job } } }),
  "ACCEPTED:res-running": toRunning, "ACCEPTED:deadline": lost,
  "RUNNING:deadline": lost,
};
for (const s of ["SENT", "ACCEPTED", "RUNNING"]) {
  REQUESTER[`${s}:res-done`] = toState("DONE");
  REQUESTER[`${s}:res-refused`] = toState("REFUSED");
  REQUESTER[`${s}:res-expired`] = toState("EXPIRED");
  REQUESTER[`${s}:res-cancelled`] = toState("CANCELLED");
}
for (const s of REQUESTER_TERMINAL) for (const t of ["res-accepted", "res-running", "res-done", "res-refused", "res-expired", "res-cancelled"]) REQUESTER[`${s}:${t}`] = late;

export function step(record: JobRecord, event: JobEvent, now: number): StepResult {
  const h = (record.dir === "out" ? REQUESTER : SERVER)[`${record.state}:${event.type}`];
  return h ? h(record, event, now) : { record };
}
