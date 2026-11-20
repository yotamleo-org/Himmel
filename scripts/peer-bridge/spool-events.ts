// The typed path's spool events. jobs.ts and runner.ts never write a chain file and
// never send: they leave one of these in the poller's spool (an O_EXCL file, as
// send.ts does) and the poller, the single writer, applies it.
import { SPOOL_ENV_KINDS, SPOOL_JOB_EVENTS, submitSpool } from "./chain";
import { peerDir } from "./ids";

// Events a runner or a chief may inject. The rest of jobstate.ts's events come from
// signed envelopes (res-*, cancel, halt) or from the poller itself (deadline, kill).
export { SPOOL_ENV_KINDS, SPOOL_JOB_EVENTS };
export type SpoolJobEvent = { type: (typeof SPOOL_JOB_EVENTS)[number]; [k: string]: unknown };

export type SpoolEvent =
  | { t: "env-out"; peer: string; kind: (typeof SPOOL_ENV_KINDS)[number]; body: Record<string, unknown> }
  | { t: "job-event"; peer: string; job: number; event: SpoolJobEvent };

// Returns the spool file's name; its result appears under spool/results/<name>.
export function writeSpoolEvent(e: SpoolEvent, dir: string = peerDir(e.peer)): string {
  return submitSpool(dir, e.t === "env-out" ? { type: "env-out", kind: e.kind, body: e.body } : { type: "job-event", job: e.job, event: e.event });
}
