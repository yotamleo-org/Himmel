import { describe, test, expect, vi, afterEach } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { tick, type SchedulerDeps } from "../src/scheduler.js";
import { appendEvent, readState, type JobAttrs } from "../src/ledger.js";
import { grantClaim } from "../src/lease.js";
import { type LaneName } from "../src/routing.js";
import { type ActMatrix } from "../src/act-matrix.js";
import { type LaneAdapter, type PollStatus } from "../src/adapters/types.js";
import { type Reporter } from "../src/reporter.js";

function freshLedger(): string {
  return join(mkdtempSync(join(tmpdir(), "ci-sched-")), "q.jsonl");
}

const MATRIX: ActMatrix = {
  "ci:lint": { fidelity: "act-faithful", os: ["linux"], heavy: false },
  "ci:security-scan": { fidelity: "needs-shim", os: ["linux"], heavy: true },
  "ci:node-suites": { fidelity: "act-faithful", os: ["linux"], heavy: true },
};

const T0 = Date.parse("2026-07-05T00:00:00Z");

function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j", headSha: "HEAD", runSha: "HEAD", workflow: "ci", job: "security-scan", required: false,
    needsSecrets: false, publicSafe: false, os: "linux", heavy: true, deterministic: false,
    treeHash: "t", enqueuedAt: new Date(T0).toISOString(), ...over,
  };
}

// A controllable fake adapter: available()/poll() return fixed values, dispatch()
// records nothing external (returns a synthetic runId).
function fakeAdapter(
  name: LaneName,
  opts: { up?: boolean; cap?: number; native?: boolean; poll?: PollStatus } = {},
): LaneAdapter {
  let n = 0;
  return {
    name,
    native: opts.native,
    available: async () => ({ up: opts.up ?? true, inFlight: 0, cap: opts.cap ?? 4 }),
    dispatch: async (j: JobAttrs) => ({ runId: `${name}-${j.id}-${n++}` }),
    poll: async () => ({ status: opts.poll ?? "running" }),
  };
}

function spyReporter(): Reporter & {
  postVerdict: ReturnType<typeof vi.fn>;
  retryUnposted: ReturnType<typeof vi.fn>;
} {
  return {
    postVerdict: vi.fn(async () => ({ posted: true })),
    retryUnposted: vi.fn(async () => ({ posted: [], deadLettered: [] })),
  };
}

function baseDeps(over: Partial<SchedulerDeps>): SchedulerDeps {
  return {
    discover: () => [],
    changedFiles: () => ["src/x.ts"],
    adapters: [],
    actMatrix: MATRIX,
    reporter: spyReporter(),
    gh: async () => {},
    workProfile: "focus",
    loadBelowThreshold: false,
    privateMinutesHeadroom: true,
    githubUp: true,
    now: () => T0,
    env: {},
    ...over,
  };
}

describe("tick — the scheduling pass", () => {
  test("per-lane concurrency cap: N+1 eligible jobs, cap N → exactly one stays queued", async () => {
    const p = freshLedger();
    const jobs = [job({ id: "a" }), job({ id: "b" })];
    const report = await tick(
      baseDeps({
        discover: () => jobs,
        adapters: [fakeAdapter("act-exec", { cap: 1, poll: "running" })],
        ledgerPath: p,
      }),
    );
    expect(report.dispatched).toHaveLength(1);
    expect(report.deferred).toHaveLength(1);
    const state = readState({}, p);
    const statuses = [...state.values()].map((s) => s.status).sort();
    expect(statuses).toEqual(["queued", "running"]);
  });

  test("defer path: no lane under cap → all jobs remain queued, none dropped", async () => {
    const p = freshLedger();
    const report = await tick(
      baseDeps({
        discover: () => [job({ id: "a" }), job({ id: "b" })],
        adapters: [fakeAdapter("act-exec", { cap: 0 })], // up but no capacity
        ledgerPath: p,
      }),
    );
    expect(report.dispatched).toHaveLength(0);
    expect(report.deferred).toHaveLength(2);
    const state = readState({}, p);
    expect([...state.values()].every((s) => s.status === "queued")).toBe(true);
  });

  test("dedup wiring: a doc-only discovery submits no code-matrix job", async () => {
    const p = freshLedger();
    const report = await tick(
      baseDeps({
        discover: () => [
          job({ id: "lint", job: "lint", heavy: false, required: true }),
          job({ id: "node", job: "node-suites" }),
        ],
        changedFiles: () => ["docs/readme.md"], // doc-only
        adapters: [fakeAdapter("act-exec")],
        ledgerPath: p,
      }),
    );
    expect(report.submitted).toContain("lint");
    expect(report.submitted).not.toContain("node"); // code-matrix dropped on doc-only
  });

  test("reporter wiring: a DISPATCHED-lane terminal verdict posts to headSha exactly once", async () => {
    const p = freshLedger();
    const reporter = spyReporter();
    await tick(
      baseDeps({
        discover: () => [job({ id: "sec", required: true, heavy: true })], // → act-exec (dispatched)
        adapters: [fakeAdapter("act-exec", { poll: "success" })],
        reporter,
        ledgerPath: p,
      }),
    );
    expect(reporter.postVerdict).toHaveBeenCalledTimes(1);
    expect(reporter.postVerdict.mock.calls[0][0].headSha).toBe("HEAD");
  });

  test("reporter wiring: a NATIVE-lane terminal verdict is NEVER re-posted", async () => {
    const p = freshLedger();
    const reporter = spyReporter();
    await tick(
      baseDeps({
        // required light gate → self-hosted-runner (native)
        discover: () => [job({ id: "lint", job: "lint", required: true, heavy: false })],
        adapters: [fakeAdapter("self-hosted-runner", { native: true, poll: "success" })],
        reporter,
        ledgerPath: p,
      }),
    );
    expect(reporter.postVerdict).toHaveBeenCalledTimes(0);
  });

  test("anti-starvation across classes (MULTI-TICK): an old non-required job is dispatched within a bounded number of ticks under a sustained required stream", async () => {
    const p = freshLedger();
    const reporter = spyReporter();
    const old = job({ id: "old", required: false, heavy: true, enqueuedAt: new Date(T0).toISOString() });
    let dispatchedAt = -1;
    for (let t = 0; t < 12; t++) {
      const now = T0 + t * 30 * 60_000; // +30 min per tick
      const fresh = job({ id: `req${t}`, required: true, heavy: true, enqueuedAt: new Date(now).toISOString() });
      const submittedOld = readState({}, p).has("old");
      const discovered = submittedOld ? [fresh] : [old, fresh];
      await tick(
        baseDeps({
          discover: () => discovered,
          adapters: [fakeAdapter("act-exec", { cap: 1, poll: "success" })], // completes same tick → lane frees
          reporter,
          now: () => now,
          ledgerPath: p,
        }),
      );
      const st = readState({}, p).get("old");
      if (st && st.status !== "queued") {
        dispatchedAt = t;
        break;
      }
    }
    expect(dispatchedAt).toBeGreaterThanOrEqual(0);
    expect(dispatchedAt).toBeLessThan(12); // aging eventually wins — never starves
  });
});

// A dispatch whose promise the test resolves by hand, so the test controls what
// happens "during the await".
function gatedAdapter(name: LaneName): { adapter: LaneAdapter; started: Promise<void>; release: () => void } {
  let release!: () => void;
  let started!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const startedP = new Promise<void>((r) => (started = r));
  const adapter: LaneAdapter = {
    name,
    available: async () => ({ up: true, inFlight: 0, cap: 4 }),
    dispatch: async (j: JobAttrs) => {
      started();
      await gate;
      return { runId: `${name}-${j.id}` };
    },
    poll: async () => ({ status: "running" }),
  };
  return { adapter, started: startedP, release };
}

describe("tick — stale snapshot and lease expiry during dispatch", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  test("HIMMEL-8440: a job completed during the scheduler's await stays done after the tick", async () => {
    const p = freshLedger();
    const gated = gatedAdapter("act-exec");
    const j1 = job({ id: "j1", required: true, heavy: true, enqueuedAt: new Date(T0 - 60_000).toISOString() });
    const j2 = job({ id: "j2", required: true, heavy: false });
    const ticking = tick(
      baseDeps({
        discover: () => [j1, j2],
        adapters: [gated.adapter, fakeAdapter("self-hosted-runner", { native: true })],
        ledgerPath: p,
      }),
    );
    await gated.started; // j1 is mid-dispatch; j2 is still in the scheduler's queued snapshot
    expect(grantClaim("j2", "local", 900_000, T0, {}, p).ok).toBe(true);
    appendEvent({ t: "verdict", ts: "t", jobId: "j2", conclusion: "success" }, {}, p);
    appendEvent({ t: "complete", ts: "t", jobId: "j2" }, {}, p);
    gated.release();
    await ticking;
    const st = readState({}, p).get("j2")!;
    expect(st.status).toBe("done");
    expect(st.conclusion).toBe("success");
  });

  test("HIMMEL-8441: a local /claim during an in-flight dispatch gets nothing, even past the TTL", async () => {
    vi.useFakeTimers({ now: T0 });
    const p = freshLedger();
    const gated = gatedAdapter("act-exec");
    const ticking = tick(
      baseDeps({
        discover: () => [job({ id: "j1" })],
        adapters: [gated.adapter],
        now: () => Date.now(),
        leaseTtlMs: 60_000,
        ledgerPath: p,
      }),
    );
    await gated.started;
    await vi.advanceTimersByTimeAsync(61_000); // the original lease would have lapsed
    expect(grantClaim("j1", "local", 60_000, Date.now(), {}, p).ok).toBe(false);
    gated.release();
    await ticking;
    const st = readState({}, p).get("j1")!;
    expect(st.status).toBe("running");
    expect(st.claimant).toBe("vm");
  });

  test("HIMMEL-8441: a dispatch that lost its claim does not append dispatch over another claimant's claim", async () => {
    const p = freshLedger();
    const gated = gatedAdapter("act-exec");
    const ticking = tick(
      baseDeps({ discover: () => [job({ id: "j1" })], adapters: [gated.adapter], ledgerPath: p }),
    );
    await gated.started;
    appendEvent({ t: "lease-expire", ts: "t", jobId: "j1" }, {}, p);
    expect(grantClaim("j1", "local", 900_000, T0, {}, p).ok).toBe(true);
    gated.release();
    const report = await ticking;
    const st = readState({}, p).get("j1")!;
    expect(st.status).toBe("claimed");
    expect(st.claimant).toBe("local");
    expect(report.dispatched).toHaveLength(0);
  });
});
