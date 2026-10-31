import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { request, type Server } from "node:http";
import { createQueueServer } from "../src/server.js";
import { type JobAttrs } from "../src/ledger.js";

const TOKEN = "test-token-abc";
const T0 = "2026-07-05T00:00:00Z";

function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j1", headSha: "HEAD", runSha: "HEAD", workflow: "ci", job: "lint", required: true,
    needsSecrets: false, publicSafe: false, os: "linux", heavy: false, deterministic: false,
    treeHash: "t", enqueuedAt: T0, ...over,
  };
}

let server: Server;
let port: number;
let ledger: string;
let clockNow = Date.parse(T0);

function call(
  method: string,
  path: string,
  body: unknown,
  token: string | null,
): Promise<{ status: number; json: any }> {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? "" : JSON.stringify(body);
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (token) headers["authorization"] = `Bearer ${token}`;
    const req = request({ host: "127.0.0.1", port, method, path, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c) => chunks.push(c as Buffer));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        resolve({ status: res.statusCode ?? 0, json: raw ? JSON.parse(raw) : null });
      });
    });
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

beforeEach(async () => {
  ledger = join(mkdtempSync(join(tmpdir(), "ci-server-")), "q.jsonl");
  clockNow = Date.parse(T0);
  server = createQueueServer({ token: TOKEN, env: {}, ledgerPath: ledger, now: () => clockNow });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const addr = server.address();
  port = typeof addr === "object" && addr ? addr.port : 0;
});

afterEach(async () => {
  await new Promise<void>((r) => server.close(() => r()));
});

describe("VM queue HTTP API", () => {
  test("/claim without the bearer token → 401", async () => {
    const res = await call("POST", "/claim", { daemon: "local" }, null);
    expect(res.status).toBe(401);
  });

  test("/submit then /state round-trips the reduced state", async () => {
    const sub = await call("POST", "/submit", { job: job() }, TOKEN);
    expect(sub.status).toBe(200);
    const state = await call("GET", "/state", undefined, TOKEN);
    expect(state.status).toBe(200);
    expect(state.json.jobs.j1.status).toBe("queued");
  });

  test("THE real race: two concurrent /claim for one job → exactly one wins", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    const [a, b] = await Promise.all([
      call("POST", "/claim", { daemon: "d1" }, TOKEN),
      call("POST", "/claim", { daemon: "d2" }, TOKEN),
    ]);
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    const gotJob = [a, b].filter((r) => r.json.job !== null);
    const gotNull = [a, b].filter((r) => r.json.job === null);
    expect(gotJob).toHaveLength(1); // exactly one carries the job
    expect(gotNull).toHaveLength(1); // the other carries none
    expect(gotJob[0].json.job.id).toBe("j1");
  });

  test("HIMMEL-8438: /renew by the claimant keeps the job past the TTL; a second /claim gets nothing", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    expect((await call("POST", "/claim", { daemon: "A" }, TOKEN)).json.job.id).toBe("j1");
    clockNow += 14 * 60_000;
    const renew = await call("POST", "/renew", { jobId: "j1", daemon: "A" }, TOKEN);
    expect(renew.status).toBe(200);
    clockNow += 2 * 60_000; // past the ORIGINAL 15-minute lease
    expect((await call("POST", "/claim", { daemon: "B" }, TOKEN)).json.job).toBeNull();
  });

  test("HIMMEL-8438: without renews the job is re-granted only after the TTL", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    await call("POST", "/claim", { daemon: "A" }, TOKEN);
    clockNow += 14 * 60_000;
    expect((await call("POST", "/claim", { daemon: "B" }, TOKEN)).json.job).toBeNull();
    clockNow += 2 * 60_000;
    expect((await call("POST", "/claim", { daemon: "B" }, TOKEN)).json.job.id).toBe("j1");
  });

  test("HIMMEL-8438: /renew from a non-claimant is refused", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    await call("POST", "/claim", { daemon: "A" }, TOKEN);
    const res = await call("POST", "/renew", { jobId: "j1", daemon: "B" }, TOKEN);
    expect(res.status).toBe(409);
  });

  test("HIMMEL-8439: an expired holder's /complete cannot overwrite the claimant's conclusion", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    await call("POST", "/claim", { daemon: "A" }, TOKEN);
    clockNow += 16 * 60_000; // A's lease lapses
    await call("POST", "/claim", { daemon: "B" }, TOKEN);
    const ok = await call("POST", "/complete", { jobId: "j1", daemon: "B", conclusion: "success" }, TOKEN);
    expect(ok.status).toBe(200);
    const stale = await call("POST", "/complete", { jobId: "j1", daemon: "A", conclusion: "failure" }, TOKEN);
    expect(stale.status).toBe(409);
    const state = await call("GET", "/state", undefined, TOKEN);
    expect(state.json.jobs.j1.conclusion).toBe("success");
    expect(state.json.jobs.j1.claimant).toBe("B");
  });

  test("HIMMEL-8439: /complete from a non-claimant, without a daemon id, or on a done job is refused", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    await call("POST", "/claim", { daemon: "A" }, TOKEN);
    expect((await call("POST", "/complete", { jobId: "j1", daemon: "B", conclusion: "failure" }, TOKEN)).status).toBe(409);
    expect((await call("POST", "/complete", { jobId: "j1", conclusion: "failure" }, TOKEN)).status).toBe(400);
    expect((await call("POST", "/complete", { jobId: "j1", daemon: "A", conclusion: "success" }, TOKEN)).status).toBe(200);
    expect((await call("POST", "/complete", { jobId: "j1", daemon: "A", conclusion: "failure" }, TOKEN)).status).toBe(409);
    const state = await call("GET", "/state", undefined, TOKEN);
    expect(state.json.jobs.j1.status).toBe("done");
    expect(state.json.jobs.j1.conclusion).toBe("success");
  });

  test("/claim publishes the local workProfile into /state", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    await call("POST", "/claim", { daemon: "local", workProfile: "drain" }, TOKEN);
    const state = await call("GET", "/state", undefined, TOKEN);
    expect(state.json.localWorkProfile).toBe("drain");
  });
});
