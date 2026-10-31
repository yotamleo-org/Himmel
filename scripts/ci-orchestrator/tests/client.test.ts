import { describe, test, expect, vi } from "vitest";
import { claimFromVm, completeOnVm, holdLease, degradeToDirect, localRoute, type HttpPostFn } from "../src/client.js";
import { type JobAttrs } from "../src/ledger.js";
import { type LaneAvailability } from "../src/routing.js";
import { type ActMatrix } from "../src/act-matrix.js";

const T0 = "2026-07-05T00:00:00Z";
const MATRIX: ActMatrix = { "ci:shell-unit-shard": { fidelity: "act-faithful", os: ["linux", "windows", "macos"], heavy: true } };

function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j", headSha: "HEAD", runSha: "HEAD", workflow: "ci", job: "shell-unit-shard", required: false,
    needsSecrets: false, publicSafe: false, os: "windows", heavy: true, deterministic: false,
    treeHash: "t", enqueuedAt: T0, ...over,
  };
}

function lanes(over: Partial<LaneAvailability> = {}): LaneAvailability {
  return {
    "self-hosted-runner": { up: false, inFlight: 0, cap: 1, native: true },
    "private-gha-hosted": { up: false, inFlight: 0, cap: 2, native: true },
    "act-exec": { up: false, inFlight: 0, cap: 1 },
    "public-fork": { up: false, inFlight: 0, cap: 4 },
    "local-exec": { up: true, inFlight: 0, cap: 1 },
    ...over,
  };
}

describe("claimFromVm", () => {
  test("VM unreachable → degrade marker (never throws)", async () => {
    const post: HttpPostFn = async () => {
      throw new Error("ECONNREFUSED");
    };
    const out = await claimFromVm("http://vm:9000", "tok", "shared", post);
    expect(out.kind).toBe("degraded");
  });

  test("publishes the workProfile in the claim body + returns the claimed job", async () => {
    const post = vi.fn<HttpPostFn>(async () => ({ job: job({ id: "claimed" }), lease: "L" }));
    const out = await claimFromVm("http://vm:9000", "tok", "drain", post);
    expect(out).toEqual({ kind: "claimed", job: job({ id: "claimed" }), lease: "L" });
    expect(post.mock.calls[0][2]).toEqual({ daemon: "local", workProfile: "drain" });
  });

  test("VM reachable but empty queue → empty", async () => {
    const post: HttpPostFn = async () => ({ job: null });
    expect((await claimFromVm("http://vm:9000", "tok", "focus", post)).kind).toBe("empty");
  });
});

describe("degradeToDirect", () => {
  test("VM down → dispatch the light gate directly, defer heavy (never drop)", () => {
    const light = job({ id: "lint", job: "lint", required: true, heavy: false });
    const heavy = job({ id: "sec", job: "security-scan", required: true, heavy: true });
    const plan = degradeToDirect([light, heavy]);
    expect(plan.dispatch.map((j) => j.id)).toEqual(["lint"]);
    expect(plan.defer.map((j) => j.id)).toEqual(["sec"]);
  });
});

describe("localRoute (client-side local-exec decision, protect-local)", () => {
  test("focus → defer even when the VM offers a local-eligible job", () => {
    const d = localRoute({
      job: job(), // windows heavy, not act-eligible, not public-safe
      workProfile: "focus",
      loadBelowThreshold: true,
      lanes: lanes(),
      actMatrix: MATRIX,
      privateMinutesHeadroom: true,
      githubUp: true,
    });
    expect(d.lane).toBe("defer");
  });

  test("drain + load below threshold → local-exec", () => {
    const d = localRoute({
      job: job(),
      workProfile: "drain",
      loadBelowThreshold: true,
      lanes: lanes(),
      actMatrix: MATRIX,
      privateMinutesHeadroom: true,
      githubUp: true,
    });
    expect(d.lane).toBe("local-exec");
  });
});

describe("completeOnVm (HIMMEL-8439)", () => {
  test("sends the claimant id with /complete", async () => {
    const post = vi.fn<HttpPostFn>(async () => ({ ok: true }));
    expect(await completeOnVm("http://vm:9000", "tok", "j1", "success", post, "local")).toBe("completed");
    expect(post.mock.calls[0][0]).toBe("http://vm:9000/complete");
    expect(post.mock.calls[0][2]).toEqual({ jobId: "j1", conclusion: "success", daemon: "local" }); // t13b-ok: daemon is the wire field name
  });

  test("a refusal or unreachable VM is reported, never thrown", async () => {
    const refuse: HttpPostFn = async () => ({ error: "not the claimant" });
    expect(await completeOnVm("http://vm:9000", "tok", "j1", "success", refuse, "local")).toBe("refused");
    const down: HttpPostFn = async () => {
      throw new Error("ECONNREFUSED");
    };
    expect(await completeOnVm("http://vm:9000", "tok", "j1", "success", down, "local")).toBe("unreachable");
  });
});

describe("holdLease (HIMMEL-8438)", () => {
  test("renews on an interval while the job runs and stops when told", async () => {
    vi.useFakeTimers();
    try {
      const post = vi.fn<HttpPostFn>(async () => ({ ok: true }));
      const stop = holdLease("http://vm:9000", "tok", "j1", post, 1000, "local");
      await vi.advanceTimersByTimeAsync(3500);
      expect(post).toHaveBeenCalledTimes(3);
      expect(post.mock.calls[0][0]).toBe("http://vm:9000/renew");
      expect(post.mock.calls[0][2]).toEqual({ jobId: "j1", daemon: "local" }); // t13b-ok: daemon is the wire field name
      stop();
      await vi.advanceTimersByTimeAsync(5000);
      expect(post).toHaveBeenCalledTimes(3);
    } finally {
      vi.useRealTimers();
    }
  });
});
