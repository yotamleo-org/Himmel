// scripts/ci-orchestrator/src/client.ts
// The local claiming client + degrade-to-direct fallback.
//
// The local daemon is a claiming CLIENT of the VM queue authority — it never
// appends to the ledger directly (OQ1 B2/B3). It claims work through the VM's
// HTTP API; on connection failure it DEGRADES to direct-dispatch: it dispatches
// the required light gate itself and defers heavy jobs (spec §Architecture "VM
// down"). On VM return, the VM re-derives outstanding work from git — no
// client-side durable queue is needed.
//
// WORK-PROFILE OWNERSHIP: the VM (queue authority) can't see the LOCAL machine's
// live load, so `local-exec` routing is decided by the local daemon ITSELF —
// before claiming it resolves its own workProfile/load and runs route()
// client-side; the VM never routes to local-exec. The local daemon also PUBLISHES
// its profile to the VM on each /claim (a `workProfile` field) so /state — and
// the future C&C board — can display it.
import { type JobAttrs } from "./ledger.js";
import { route, type LaneAvailability } from "./routing.js";
import { type WorkProfile } from "./workprofile.js";
import { type ActMatrix } from "./act-matrix.js";

// Injected POST so the client stays hermetic. Resolves to the parsed JSON body on
// success; REJECTS on a connection failure (→ the caller degrades).
export type HttpPostFn = (
  url: string,
  token: string,
  body: unknown,
) => Promise<unknown>;

export type ClaimOutcome =
  | { kind: "claimed"; job: JobAttrs; lease?: string }
  | { kind: "empty" } // VM reachable, nothing to claim
  | { kind: "degraded" }; // VM unreachable — caller must direct-dispatch

// Claim the next job from the VM, publishing this host's workProfile. Any
// connection failure → {kind:"degraded"} (never throws).
export async function claimFromVm(
  vmUrl: string,
  token: string,
  workProfile: WorkProfile,
  post: HttpPostFn,
  daemon = "local",
): Promise<ClaimOutcome> {
  let body: unknown;
  try {
    body = await post(`${vmUrl}/claim`, token, { daemon, workProfile });
  } catch {
    return { kind: "degraded" };
  }
  const job = (body as { job?: JobAttrs | null }).job;
  if (!job) return { kind: "empty" };
  const lease = (body as { lease?: string }).lease;
  return { kind: "claimed", job, lease };
}

// Report a finished job to the VM. The daemon id is sent so the VM can refuse a
// caller that is not the job's current claimant. Never throws.
export async function completeOnVm(
  vmUrl: string,
  token: string,
  jobId: string,
  conclusion: "success" | "failure" | "cancelled",
  post: HttpPostFn,
  daemon = "local",
): Promise<"completed" | "refused" | "unreachable"> {
  let body: unknown;
  try {
    body = await post(`${vmUrl}/complete`, token, { jobId, conclusion, daemon });
  } catch {
    return "unreachable";
  }
  return (body as { ok?: boolean }).ok ? "completed" : "refused";
}

// Renew the lease on a claimed job every `intervalMs` while it runs,
// so the VM does not re-grant it when the TTL lapses. Returns stop(); call it when
// the job finishes. A failed or refused renew is swallowed — the VM stays the
// authority, and /complete will refuse a lapsed holder.
export function holdLease(
  vmUrl: string,
  token: string,
  jobId: string,
  post: HttpPostFn,
  intervalMs: number,
  daemon = "local",
): () => void {
  const timer = setInterval(() => {
    post(`${vmUrl}/renew`, token, { jobId, daemon }).catch(() => {});
  }, intervalMs);
  return () => clearInterval(timer);
}

// Degrade-to-direct plan when the VM is unreachable: dispatch only the required
// light gate directly (so required checks keep flowing), defer everything heavy
// until the VM returns. Never drops a job (deferred work is re-derived from git).
export type DegradePlan = { dispatch: JobAttrs[]; defer: JobAttrs[] };

export function degradeToDirect(candidates: JobAttrs[]): DegradePlan {
  const dispatch: JobAttrs[] = [];
  const defer: JobAttrs[] = [];
  for (const job of candidates) {
    if (job.required && !job.heavy) dispatch.push(job);
    else defer.push(job);
  }
  return { dispatch, defer };
}

// Decide client-side whether THIS local host should run a claimed job locally,
// using the host's own live profile/load. In `focus` (or busy), a local-exec-only
// job routes to `defer` — protect-local — even if the VM offered it. Returns the
// route() decision so the local daemon can act (dispatch to local-exec) or hold.
export function localRoute(opts: {
  job: JobAttrs;
  workProfile: WorkProfile;
  loadBelowThreshold: boolean;
  lanes: LaneAvailability;
  actMatrix: ActMatrix;
  privateMinutesHeadroom: boolean;
  githubUp: boolean;
}) {
  return route({
    job: opts.job,
    lanes: opts.lanes,
    workProfile: opts.workProfile,
    loadBelowThreshold: opts.loadBelowThreshold,
    privateMinutesHeadroom: opts.privateMinutesHeadroom,
    actMatrix: opts.actMatrix,
    githubUp: opts.githubUp,
  });
}
