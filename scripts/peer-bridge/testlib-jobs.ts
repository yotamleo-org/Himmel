// Job-record fixtures shared by the resolver, state-machine and CLI tests.
import type { JobRecord } from "./resolve";

export const NOW_S = 1_730_973_600;   // 2024-11-07 10:00 UTC, far from local midnight in the usual zones
export const SHA = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678";
export const WIRE = "0123456789abcdef";
export const OUT_SUITES = ["scripts/hooks/test-a.sh", "scripts/ci/test-b.sh"];

// A job we sent (requester side), by default just sent.
export function outJob(over: Partial<JobRecord> = {}): JobRecord {
  return {
    kind: "job", jobNo: 1, peer: "goomal", dir: "out", state: "SENT", by: NOW_S + 86400 + 10200 + 7200, created: NOW_S, req_exp: NOW_S + 86400,
    sha: SHA, suites: [...OUT_SUITES], wire_job: WIRE, ...over,
  };
}

// A job a peer sent us (server side), by default just received.
export function inJob(over: Partial<JobRecord> = {}): JobRecord {
  return {
    kind: "job", jobNo: 2, peer: "goomal", dir: "in", state: "RECEIVED", by: NOW_S + 600, created: NOW_S, req_exp: NOW_S + 86400,
    suites: ["alias-a"], paths: ["scripts/hooks/test-a.sh"], peer_job: WIRE, peer_sha: SHA, peer_suites: ["scripts/hooks/test-a.sh"], ...over,
  };
}
