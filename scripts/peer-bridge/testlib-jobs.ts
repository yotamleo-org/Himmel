import type { JobRecord } from "./resolve";

export const NOW_S = 1_730_973_600;
export const SHA = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678";
export const WIRE = "0123456789abcdef";
export const OUT_SUITES = ["scripts/hooks/test-a.sh", "scripts/ci/test-b.sh"];

export function outJob(over: Partial<JobRecord> = {}): JobRecord {
  return {
    kind: "job", jobNo: 1, peer: "example", dir: "out", state: "SENT", by: NOW_S + 86400 + 10200 + 7200, created: NOW_S, req_exp: NOW_S + 86400,
    sha: SHA, suites: [...OUT_SUITES], wire_job: WIRE, ...over,
  };
}

export function inJob(over: Partial<JobRecord> = {}): JobRecord {
  return {
    kind: "job", jobNo: 2, peer: "example", dir: "in", state: "RECEIVED", by: NOW_S + 600, created: NOW_S, req_exp: NOW_S + 86400,
    suites: ["alias-a"], paths: ["scripts/hooks/test-a.sh"], peer_job: WIRE, peer_sha: SHA, peer_suites: ["scripts/hooks/test-a.sh"], ...over,
  };
}
