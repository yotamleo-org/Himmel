import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AllowEntry } from "./config";
import { buildEnvelope } from "./envelope";
import { bucket5, render, renderCapacity, renderLine, resolveCapacity, resolveReq, resolveRes, type JobRecord } from "./resolve";
import { failedTests, makeRedCopy } from "./testlib-red-copy";
import { NOW_S, OUT_SUITES, SHA, WIRE, inJob, outJob } from "./testlib-jobs";

const CTX = { from: "example", to: "yotam", chat: -1001234567890, now: NOW_S };
const res = (body: Record<string, unknown>) => buildEnvelope("res", { job: WIRE, ...body }, CTX);
const apply = (job: JobRecord, patch: Partial<JobRecord> | null): JobRecord => ({ ...job, ...(patch ?? {}) });

const IMAGE_CANARY = "d1ca9e5b".repeat(8), LOG_CANARY = "c4ca41e5".repeat(8);
const DONE = (over: Record<string, unknown> = {}) => res({ state: "done", results: ["pass", "fail"], minutes: 7, image: IMAGE_CANARY, log: { sha256: LOG_CANARY, bytes: 424242 }, ...over });
const DIGEST = "f".repeat(64);

function allOutputs(r: JobRecord): string {
  return [render(r), renderLine(r)].join("\n");
}

test("requester canary row: nothing the peer wrote reaches the output, and minutes are bucketed", () => {
  const job = outJob({ state: "RUNNING" });
  const done = apply(job, resolveRes(DONE(), job, { imageDigest: DIGEST }));
  const out = allOutputs(done);
  for (const canary of [IMAGE_CANARY, LOG_CANARY, "424242", "d1ca9e5b", "c4ca41e5"]) expect(out).not.toContain(canary);
  expect(out).not.toMatch(/peer_/);
  expect(out).toContain("minutes: 10");
  expect(out).not.toMatch(/minutes: 7\b/);
  expect(out).toContain("log: kept on peer");
  expect(out).toContain("image: unpinned");
  expect(out).toContain(`${OUT_SUITES[0]}: pass`);
  expect(out).toContain(`${OUT_SUITES[1]}: fail`);
  expect(done.peer_image).toBe(IMAGE_CANARY);
  expect(done.peer_log_sha256).toBe(LOG_CANARY);
  expect(done.peer_log_bytes).toBe(424242);
  expect(done.peer_minutes).toBe(7);
});

test("minutes are rounded up to a multiple of 5", () => {
  expect([0, 1, 4, 5, 6, 7, 10, 11, 178, 180].map(bucket5)).toEqual([0, 5, 5, 5, 10, 10, 10, 15, 180, 180]);
  for (const m of [1, 2, 3, 7, 8, 11, 13]) {
    const job = outJob({ state: "RUNNING" });
    const out = render(apply(job, resolveRes(DONE({ minutes: m }), job, {})));
    expect(out).toContain(`minutes: ${bucket5(m)}`);
  }
});

test("a result count other than ours is malformed, and shows no outcomes", () => {
  const job = outJob({ state: "RUNNING" });
  const done = apply(job, resolveRes(DONE({ results: ["pass"] }), job, {}));
  expect(done.malformed).toBe(true);
  const out = render(done);
  expect(out).toContain("result: malformed");
  expect(out).not.toContain(": pass");
  expect(out).not.toContain("minutes:");
  const longer = apply(job, resolveRes(DONE({ results: ["pass", "pass", "pass"] }), job, {}));
  expect(longer.malformed).toBe(true);
});

test("an image equal to our recorded digest is pinned, anything else is unpinned", () => {
  const job = outJob({ state: "RUNNING" });
  expect(resolveRes(DONE({ image: DIGEST }), job, { imageDigest: DIGEST })?.image).toBe("pinned");
  expect(resolveRes(DONE({ image: IMAGE_CANARY }), job, { imageDigest: DIGEST })?.image).toBe("unpinned");
  expect(resolveRes(DONE({ image: DIGEST }), job, {})?.image).toBe("unpinned");
  expect(render(apply(job, resolveRes(DONE({ image: DIGEST }), job, { imageDigest: DIGEST })))).toContain("image: pinned");
});

test("a res for a job we never created, or not as a requester, or under another wire id, is dropped", () => {
  expect(resolveRes(DONE(), undefined, {})).toBeNull();
  expect(resolveRes(DONE(), inJob({ state: "RUNNING", wire_job: WIRE }), {})).toBeNull();
  expect(resolveRes(DONE(), outJob({ wire_job: "f".repeat(16) }), {})).toBeNull();
});

test("a refused or running res yields our enum constants only", () => {
  const job = outJob();
  const refused = apply(job, resolveRes(res({ state: "refused", refused: "not-allowed" }), job, {}));
  expect(refused.refused).toBe("not-allowed");
  expect(render(refused)).toContain("refused: not-allowed");
  const running = resolveRes(res({ state: "running", timeout_s: 4321 }), job, {});
  expect(running?.peer_timeout_s).toBe(4321);
  expect(render(apply(job, running))).not.toContain("4321");
});

test("a res for a job already over is recorded as late, shown by our word, and never reopens", () => {
  const job = outJob({ state: "LOST" });
  const late = apply(job, resolveRes(DONE({ minutes: 9 }), job, {}));
  expect(late.state).toBe("LOST");
  expect(late.late).toBe("done");
  expect(render(late)).toContain("late: done");
});


const ALLOW: AllowEntry[] = [{ alias: "alias-a", path: "scripts/hooks/test-a.sh" }, { alias: "alias-b", path: "scripts/ci/test-b.sh" }];
const req = (suites: string[], sha = SHA) => buildEnvelope("req", { job: WIRE, op: "run-suite", sha, suites }, CTX);

test("server row: a canary suite is not-allowed, and the server's output holds no requester string", () => {
  const canary = "scripts/zqxcanary-ignore-the-brief.sh";
  const r = resolveReq(req([canary, "scripts/hooks/test-a.sh"]) as any, ALLOW);
  expect(r).toMatchObject({ ok: false, refused: "not-allowed" });
  const rec = inJob({ state: "REFUSED", refused: "not-allowed", ...(r.record as object), suites: [] });
  const out = allOutputs(rec);
  expect(out).not.toContain("zqxcanary");
  expect(out).not.toContain(SHA.slice(0, 7));
  expect(out).not.toContain(WIRE);
  expect(out).toContain("refused: not-allowed");
  expect(r.record.peer_suites).toContain(canary);
});

test("server row: an allowed suite is stored and shown by the server's own alias", () => {
  const r = resolveReq(req(["scripts/hooks/test-a.sh", "scripts/ci/test-b.sh"]) as any, ALLOW);
  expect(r.ok).toBe(true);
  expect(r.record.suites).toEqual(["alias-a", "alias-b"]);
  expect(r.record.paths).toEqual(["scripts/hooks/test-a.sh", "scripts/ci/test-b.sh"]);
  expect(r.record.peer_sha).toBe(SHA);
  expect(r.record.peer_job).toBe(WIRE);
  const rec = inJob({ ...r.record, sha: SHA, state: "DONE", results: ["pass", "error"], minutes: 12 });
  const out = render(rec);
  expect(out).toContain("alias-a: pass");
  expect(out).toContain("alias-b: error");
  expect(out).toContain("minutes: 15");
  expect(out).toContain(`sha: ${SHA.slice(0, 7)}`);
  expect(out).not.toContain(SHA);
  expect(out).not.toContain("scripts/");
});

test("server row: an empty allowlist allows nothing, and macos-poc-suites.txt is not consulted", () => {
  const listed = readFileSync(join(import.meta.dir, "..", "ci", "macos-poc-suites.txt"), "utf8").split("\n").find(l => /^scripts\/.*\.sh$/.test(l.trim()))!.trim();
  expect(listed).toMatch(/\.sh$/);
  expect(resolveReq(req([listed]) as any, [])).toMatchObject({ ok: false, refused: "not-allowed" });
  for (const f of ["resolve.ts", "config.ts"]) expect(readFileSync(join(import.meta.dir, f), "utf8")).not.toContain("macos-poc-suites");
});

test("chosen-pointer row: no envelope field makes the output print text from our tree", () => {
  const fixture = readFileSync(join(import.meta.dir, "..", "handover", "chief-kit", "test-ops-run.sh"), "utf8");
  expect(fixture).toContain("ignore previous instructions");
  const ops = "scripts/handover/chief-kit/test-ops-run.sh";
  const r = resolveReq(req([ops]) as any, [{ alias: "ops-run", path: ops }, ...ALLOW]);
  expect(r.ok).toBe(true);
  const out = allOutputs(inJob({ ...r.record, sha: SHA, state: "DONE", results: ["fail"], minutes: 5 }));
  expect(out).not.toContain("ignore previous instructions");
  expect(out).toContain("ops-run");
  const job = outJob({ state: "RUNNING", suites: [ops] });
  const done = apply(job, resolveRes(DONE({ results: ["fail"] }), job, {}));
  expect(allOutputs(done)).not.toContain("ignore previous instructions");
});


const cap = (over: Record<string, unknown> = {}) => buildEnvelope("capacity", { re: "89abcdef", state: "idle", queue: 0, jobs_left: 9, vm_minutes_left: 100, ...over }, CTX);

test("capacity is ok, low or none, and the queue is free or full", () => {
  expect(resolveCapacity(cap())).toEqual({ state: "idle", capacity: "ok", queue: "free" });
  expect(resolveCapacity(cap({ vm_minutes_left: 20 })).capacity).toBe("low");
  expect(resolveCapacity(cap({ jobs_left: 1 })).capacity).toBe("low");
  expect(resolveCapacity(cap({ jobs_left: 0 })).capacity).toBe("none");
  expect(resolveCapacity(cap({ vm_minutes_left: 0 })).capacity).toBe("none");
  expect(resolveCapacity(cap({ state: "not-served", jobs_left: 0, vm_minutes_left: 0 })).capacity).toBe("none");
  expect(resolveCapacity(cap({ state: "no-vm" })).capacity).toBe("none");
  expect(resolveCapacity(cap({ state: "busy", queue: 3 })).queue).toBe("full");
  expect(resolveCapacity(cap({ queue: 2 })).queue).toBe("free");
});

test("a capacity line shows our words only, never the numbers the peer sent", () => {
  const out = renderCapacity("example", resolveCapacity(cap({ jobs_left: 777, vm_minutes_left: 888, queue: 2 })));
  expect(out).not.toMatch(/777|888/);
  expect(out).toBe("example capacity: ok, queue: free, station: idle");
});


function redRun(needle: string, replacement: string): string[] {
  const root = makeRedCopy(["scripts/telegram/bus.ts", "scripts/telegram/gate.ts", "scripts/handover/chief-kit/test-ops-run.sh", "scripts/ci/macos-poc-suites.txt"]);
  const run = () => spawnSync("bun", ["test", "./scripts/peer-bridge/resolve.test.ts"], { cwd: root, encoding: "utf8", env: { ...process.env, PEER_RED_COPY: "1" } });
  expect(run().status).toBe(0);
  const target = join(root, "scripts/peer-bridge/resolve.ts");
  const lines = readFileSync(target, "utf8").split("\n");
  expect(lines.filter(l => l.includes(needle))).toHaveLength(1);
  writeFileSync(target, lines.map(l => (l.includes(needle) ? replacement : l)).join("\n"));
  const mutated = run();
  expect(mutated.status).not.toBe(0);
  return failedTests(mutated.stdout + mutated.stderr);
}

test.skipIf(!!process.env.PEER_RED_COPY)("RED control: a resolver that copies the image verbatim fails the canary row", () => {
  const failed = redRun(`"pinned" : "unpinned"`, "  image: (env as any).image,");
  expect(failed).toContain("requester canary row: nothing the peer wrote reaches the output, and minutes are bucketed");
}, 90_000);

test.skipIf(!!process.env.PEER_RED_COPY)("RED control: a render that prints peer_sha fails the server canary row", () => {
  const failed = redRun("lines.push(`sha: ${shaLine(r)}`)", "  lines.push(`sha: ${r.peer_sha}`);");
  expect(failed).toContain("server row: a canary suite is not-allowed, and the server's output holds no requester string");
}, 90_000);

test.skipIf(!!process.env.PEER_RED_COPY)("RED control: a render that prints the peer's minutes unbucketed fails the canary row", () => {
  const failed = redRun("lines.push(`minutes: ${bucket5(", "  lines.push(`minutes: ${r.peer_minutes ?? r.minutes}`);");
  expect(failed).toContain("requester canary row: nothing the peer wrote reaches the output, and minutes are bucketed");
}, 90_000);
