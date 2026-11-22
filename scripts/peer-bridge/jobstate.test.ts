import { expect, test } from "bun:test";
import { DEFAULT_BUDGETS } from "./config";
import { ALLOWANCE_S, TIMEOUT_S_MAX, buildEnvelope, type Envelope } from "./envelope";
import { REQUESTER_STATES, SERVER_STATES, chargedMinutes, deadlineFor, dueJobs, queueDepth, remaining, step, type JobEvent, type SendSpec } from "./jobstate";
import { resolveRes, type JobRecord } from "./resolve";
import { NOW_S, SHA, WIRE, inJob, outJob } from "./testlib-jobs";

const H = 3600, MIN = 60;
const REQ_EXP = NOW_S + 86400;
const CTX = { from: "example", to: "yotam", chat: -1001234567890, now: NOW_S };
const EV = {
  resolveOk: { type: "resolve-ok", sha: SHA } as JobEvent,
  resolveFail: { type: "resolve-fail", refused: "unknown-sha" } as JobEvent,
  vmStart: (backstop_s = 9000) => ({ type: "vm-start", backstop_s }) as JobEvent,
  vmDone: { type: "vm-done", results: ["pass"] } as JobEvent,
};


type Expect = null | [state: string, send: string | null];
const SERVER_EVENTS = ["resolve-ok", "resolve-fail", "approve", "vm-start", "vm-done", "cancel", "halt", "kill", "deadline"] as const;
const eventOf = (type: string): JobEvent => {
  switch (type) {
    case "resolve-ok": return EV.resolveOk;
    case "resolve-fail": return EV.resolveFail;
    case "vm-start": return EV.vmStart();
    case "vm-done": return EV.vmDone;
    default: return { type } as JobEvent;
  }
};
const SERVER: Record<string, Record<string, Expect>> = {
  RECEIVED: { "resolve-ok": ["RESOLVED", "accepted"], "resolve-fail": ["REFUSED", "refused"], approve: null, "vm-start": null, "vm-done": null, cancel: ["CANCELLED", "cancelled"], halt: ["CANCELLED", "cancelled"], kill: ["CANCELLED", null], deadline: ["REFUSED", "refused"] },
  RESOLVED: { "resolve-ok": null, "resolve-fail": null, approve: ["APPROVED", null], "vm-start": null, "vm-done": null, cancel: ["CANCELLED", "cancelled"], halt: ["CANCELLED", "cancelled"], kill: ["CANCELLED", null], deadline: ["EXPIRED", "expired"] },
  APPROVED: { "resolve-ok": null, "resolve-fail": null, approve: null, "vm-start": ["RUNNING", "running"], "vm-done": null, cancel: ["CANCELLED", "cancelled"], halt: ["CANCELLED", "cancelled"], kill: ["CANCELLED", null], deadline: ["EXPIRED", "expired"] },
  RUNNING: { "resolve-ok": null, "resolve-fail": null, approve: null, "vm-start": null, "vm-done": ["DONE", "done"], cancel: ["CANCELLED", "cancelled"], halt: ["CANCELLED", "cancelled"], kill: ["CANCELLED", null], deadline: ["DONE", "done"] },
  DONE: {}, CANCELLED: {}, EXPIRED: {}, REFUSED: {},
};
for (const t of ["DONE", "CANCELLED", "EXPIRED", "REFUSED"]) for (const e of SERVER_EVENTS) SERVER[t][e] = null;

const serverAt = (state: string): JobRecord =>
  inJob({ state, by: NOW_S + 100, ...(state === "RUNNING" ? { running_at: NOW_S - 600, backstop_s: 3000, sha: SHA } : {}), ...(state !== "RECEIVED" ? { sha: SHA, resolved_at: NOW_S - 900 } : {}), ...(["DONE", "CANCELLED", "EXPIRED", "REFUSED"].includes(state) ? { by: null, ended_at: NOW_S - 100 } : {}) });

test("every cell of the server table: state x event gives the spec's next state and message", () => {
  expect(Object.keys(SERVER).sort()).toEqual([...SERVER_STATES].sort());
  for (const state of SERVER_STATES) {
    for (const type of SERVER_EVENTS) {
      const want = SERVER[state][type];
      const before = serverAt(state);
      const r = step(before, eventOf(type), NOW_S);
      const label = `${state} x ${type}`;
      if (want === null) {
        expect([label, r.record.state, r.record.by, r.send]).toEqual([label, state, before.by, undefined]);
      } else {
        expect([label, r.record.state]).toEqual([label, want[0]]);
        const sent = r.send ? (r.send.body.state as string) : null;
        expect([label, r.send?.kind ?? "res", sent]).toEqual([label, "res", want[1]]);
      }
    }
  }
});

test("a res sent by the server carries the requester's job id, and the refusal reason", () => {
  const refused = step(serverAt("RECEIVED"), EV.resolveFail, NOW_S);
  expect(refused.send).toEqual({ kind: "res", body: { job: WIRE, state: "refused", refused: "unknown-sha" } });
  expect(refused.record.refused).toBe("unknown-sha");
  const noVm = step(serverAt("RECEIVED"), { type: "deadline" }, NOW_S);
  expect(noVm.send?.body).toEqual({ job: WIRE, state: "refused", refused: "no-vm" });
  const running = step(serverAt("APPROVED"), EV.vmStart(3000), NOW_S);
  expect(running.send?.body).toEqual({ job: WIRE, state: "running", timeout_s: 3000 + ALLOWANCE_S });
  expect(running.record).toMatchObject({ state: "RUNNING", running_at: NOW_S, backstop_s: 3000, by: NOW_S + 3000 + ALLOWANCE_S });
});

const REQ_EVENTS = ["res-accepted", "res-running", "res-done", "res-refused", "res-expired", "res-cancelled", "deadline"] as const;
const REQUESTER: Record<string, Record<string, Expect>> = {
  SENT: { "res-accepted": ["ACCEPTED", null], "res-running": ["RUNNING", null], "res-done": ["DONE", null], "res-refused": ["REFUSED", null], "res-expired": ["EXPIRED", null], "res-cancelled": ["CANCELLED", null], deadline: ["LOST", "cancel"] },
  ACCEPTED: { "res-accepted": null, "res-running": ["RUNNING", null], "res-done": ["DONE", null], "res-refused": ["REFUSED", null], "res-expired": ["EXPIRED", null], "res-cancelled": ["CANCELLED", null], deadline: ["LOST", null] },
  RUNNING: { "res-accepted": null, "res-running": null, "res-done": ["DONE", null], "res-refused": ["REFUSED", null], "res-expired": ["EXPIRED", null], "res-cancelled": ["CANCELLED", null], deadline: ["LOST", null] },
  DONE: {}, REFUSED: {}, EXPIRED: {}, CANCELLED: {}, LOST: {},
};
for (const t of ["DONE", "REFUSED", "EXPIRED", "CANCELLED", "LOST"]) for (const e of REQ_EVENTS) REQUESTER[t][e] = null;

function resEvent(job: JobRecord, type: string, over: Record<string, unknown> = {}): JobEvent {
  const bodies: Record<string, Record<string, unknown>> = {
    "res-accepted": { state: "accepted" }, "res-running": { state: "running", timeout_s: 4200 },
    "res-done": { state: "done", results: ["pass", "fail"], minutes: 20, image: "b".repeat(64), log: { sha256: "c".repeat(64), bytes: 9 } },
    "res-refused": { state: "refused", refused: "budget" }, "res-expired": { state: "expired" }, "res-cancelled": { state: "cancelled" },
  };
  const env = buildEnvelope("res", { job: WIRE, ...bodies[type], ...over }, CTX);
  return { type, patch: resolveRes(env, job, {}) ?? undefined } as JobEvent;
}
const requesterAt = (state: string): JobRecord =>
  outJob({ state, by: NOW_S + 100, ...(state === "RUNNING" ? { running_at: NOW_S - 600, peer_timeout_s: 4200 } : {}), ...(["DONE", "REFUSED", "EXPIRED", "CANCELLED", "LOST"].includes(state) ? { by: null, ended_at: NOW_S - 100 } : {}) });

test("every cell of the requester table", () => {
  expect(Object.keys(REQUESTER).sort()).toEqual([...REQUESTER_STATES].sort());
  for (const state of REQUESTER_STATES) {
    for (const type of REQ_EVENTS) {
      const want = REQUESTER[state][type];
      const before = requesterAt(state);
      const ev: JobEvent = type === "deadline" ? { type } : resEvent(before, type);
      const r = step(before, ev, NOW_S);
      const label = `${state} x ${type}`;
      if (want === null) {
        expect([label, r.record.state, r.send]).toEqual([label, state, undefined]);
      } else {
        expect([label, r.record.state]).toEqual([label, want[0]]);
        expect([label, r.send?.kind ?? null]).toEqual([label, want[1]]);
      }
    }
  }
});

test("the server's own events do nothing to a requester record, and the requester's res events nothing to a server record", () => {
  for (const t of ["resolve-ok", "approve", "vm-start", "vm-done", "kill", "cancel", "halt"]) {
    const r = step(requesterAt("SENT"), eventOf(t), NOW_S);
    expect([t, r.record.state, r.send]).toEqual([t, "SENT", undefined]);
  }
  for (const t of ["res-accepted", "res-running", "res-done"]) {
    const r = step(serverAt("RESOLVED"), { type: t } as JobEvent, NOW_S);
    expect([t, r.record.state, r.send]).toEqual([t, "RESOLVED", undefined]);
  }
});

test("step does not mutate its input and keeps the peer's fields out of what it sends", () => {
  const before = serverAt("RECEIVED");
  const copy = JSON.stringify(before);
  const r = step(before, EV.resolveOk, NOW_S);
  expect(JSON.stringify(before)).toBe(copy);
  expect(r.record).not.toBe(before);
});


test("requester SENT and ACCEPTED deadline is req.exp + TIMEOUT_S_MAX + 2 h, importing no server config", () => {
  expect(deadlineFor(outJob({ state: "SENT" }))).toBe(REQ_EXP + TIMEOUT_S_MAX + 7200);
  expect(deadlineFor(outJob({ state: "ACCEPTED" }))).toBe(REQ_EXP + TIMEOUT_S_MAX + 7200);
  expect(deadlineFor(outJob({ state: "RUNNING", running_at: NOW_S + 50, peer_timeout_s: 4200 }))).toBe(NOW_S + 50 + 4200 + 7200);
  expect(deadlineFor(outJob({ state: "DONE" }))).toBeNull();
});

test("server deadlines: RECEIVED +10 min, RESOLVED and APPROVED at req.exp, RUNNING at start + backstop + allowance", () => {
  expect(deadlineFor(inJob({ state: "RECEIVED", created: NOW_S }))).toBe(NOW_S + 10 * MIN);
  expect(deadlineFor(inJob({ state: "RESOLVED" }))).toBe(REQ_EXP);
  expect(deadlineFor(inJob({ state: "APPROVED" }))).toBe(REQ_EXP);
  expect(deadlineFor(inJob({ state: "RUNNING", running_at: NOW_S + 5, backstop_s: 600 }))).toBe(NOW_S + 5 + 600 + ALLOWANCE_S);
  expect(deadlineFor(inJob({ state: "REFUSED" }))).toBeNull();
});

test("every requester deadline falls after every server deadline reachable from one req", () => {
  const t0 = NOW_S, exp = t0 + 86400;
  const times = [t0, t0 + 12 * H, exp - 60];
  for (const recvAt of times) {
    for (const backstop of [ALLOWANCE_S, 3000, 9000]) {
      for (const startAt of [recvAt, recvAt + 3600, exp - 60].filter(s => s >= recvAt)) {
        const servers: JobRecord[] = [
          inJob({ state: "RECEIVED", created: recvAt, req_exp: exp }), inJob({ state: "RESOLVED", req_exp: exp }), inJob({ state: "APPROVED", req_exp: exp }),
          inJob({ state: "RUNNING", running_at: startAt, backstop_s: backstop, req_exp: exp }),
        ];
        for (const learnedAt of [startAt, startAt + 2 * H]) {
          const requesters: JobRecord[] = [
            outJob({ state: "SENT", req_exp: exp }), outJob({ state: "ACCEPTED", req_exp: exp }),
            outJob({ state: "RUNNING", req_exp: exp, running_at: learnedAt, peer_timeout_s: backstop + ALLOWANCE_S }),
          ];
          for (const s of servers) for (const q of requesters) {
            if (q.state === "RUNNING" && s.state !== "RUNNING") continue;
            expect([s.state, q.state, deadlineFor(q)! > deadlineFor(s)!]).toEqual([s.state, q.state, true]);
          }
        }
      }
    }
  }
});

test("dueJobs lists overdue non-terminal jobs, oldest deadline first", () => {
  const jobs = [
    outJob({ jobNo: 1, state: "SENT", by: NOW_S + 5 }), outJob({ jobNo: 2, state: "SENT", by: NOW_S - 50 }), outJob({ jobNo: 3, state: "DONE", by: null }),
    inJob({ jobNo: 4, state: "RESOLVED", by: NOW_S - 100 }), inJob({ jobNo: 5, state: "RUNNING", by: NOW_S }),
  ];
  expect(dueJobs(jobs, NOW_S).map(j => j.jobNo)).toEqual([4, 2, 5]);
});


type Pair = { req: JobRecord; srv: JobRecord; sent: string[] };
function pair(): Pair {
  return { req: outJob({ state: "SENT", created: NOW_S, req_exp: REQ_EXP, by: deadlineFor(outJob({ req_exp: REQ_EXP })) }), srv: inJob({ state: "RECEIVED", created: NOW_S, req_exp: REQ_EXP, by: NOW_S + 600 }), sent: [] };
}
function toRequester(p: Pair, spec: SendSpec | undefined, at: number): void {
  if (!spec || spec.kind !== "res") return;
  const env = buildEnvelope("res", spec.body, CTX) as Envelope;
  const state = (env as any).state as string;
  const r = step(p.req, { type: `res-${state}`, patch: resolveRes(env, p.req, {}) ?? undefined } as JobEvent, at);
  p.req = r.record;
  if (r.send) p.sent.push(`requester:${r.send.kind}`);
}
function server(p: Pair, ev: JobEvent, at: number): SendSpec | undefined {
  const r = step(p.srv, ev, at);
  p.srv = r.record;
  return r.send;
}

test("a req delivered 12 h late still runs, and a res delivered 12 h late still lands", () => {
  const p = pair();
  let at = NOW_S + 12 * H;
  p.srv = { ...p.srv, created: at, by: at + 600 };
  toRequester(p, server(p, EV.resolveOk, at), at + 12 * H - 100);
  expect(p.req.state).toBe("ACCEPTED");
  server(p, { type: "approve" }, at);
  at += 60;
  toRequester(p, server(p, EV.vmStart(3000), at), at);
  expect(p.srv.state).toBe("RUNNING");
  expect(p.req.state).toBe("RUNNING");
  at += 1800;
  toRequester(p, server(p, { type: "vm-done", results: ["pass", "fail"] }, at), at);
  expect(p.srv.state).toBe("DONE");
  expect(p.req.state).toBe("DONE");
  expect(p.sent).toEqual([]);
});

test("a job started at req.exp - 60 s whose res running arrives 2 h late ends DONE and is never cancelled", () => {
  const p = pair();
  server(p, EV.resolveOk, NOW_S + 10);
  server(p, { type: "approve" }, NOW_S + 20);
  const start = REQ_EXP - 60;
  const running = server(p, EV.vmStart(9000), start);
  expect(due(p.req, start + 2 * H)).toBe(false);
  toRequester(p, running, start + 2 * H);
  expect(p.req.state).toBe("RUNNING");
  toRequester(p, server(p, { type: "vm-done", results: ["pass", "pass"] }, start + 3000), start + 3000);
  expect(p.req.state).toBe("DONE");
  expect(p.sent).toEqual([]);
});

const due = (r: JobRecord, now: number) => r.by !== null && r.by <= now;

test("a 150-minute job approved at req.exp - 60 s whose res running is lost ends DONE, never LOST", () => {
  const p = pair();
  server(p, EV.resolveOk, NOW_S + 10);
  server(p, { type: "approve" }, NOW_S + 20);
  const start = REQ_EXP - 60;
  server(p, EV.vmStart(150 * 60), start);
  const serverEnd = p.srv.by!;
  expect(due(p.req, serverEnd)).toBe(false);
  toRequester(p, server(p, { type: "deadline" }, serverEnd), serverEnd + 60);
  expect(p.srv.state).toBe("DONE");
  expect(p.req.state).toBe("DONE");
  expect(p.sent).toEqual([]);
});

test("normal expiry is EXPIRED on both sides, and an unapproved job frees the queue at req.exp", () => {
  const p = pair();
  toRequester(p, server(p, EV.resolveOk, NOW_S + 10), NOW_S + 20);
  expect(queueDepth([p.srv])).toBe(1);
  expect(due(p.srv, REQ_EXP - 1)).toBe(false);
  expect(due(p.srv, REQ_EXP)).toBe(true);
  toRequester(p, server(p, { type: "deadline" }, REQ_EXP), REQ_EXP + 30);
  expect(p.srv.state).toBe("EXPIRED");
  expect(p.req.state).toBe("EXPIRED");
  expect(queueDepth([p.srv])).toBe(0);
  expect(p.sent).toEqual([]);
});

test("the requester's SENT deadline sends one cancel; ACCEPTED and RUNNING lose without one", () => {
  const sent = outJob({ state: "SENT", by: NOW_S });
  const r = step(sent, { type: "deadline" }, NOW_S + 1);
  expect(r.record.state).toBe("LOST");
  expect(r.send).toEqual({ kind: "cancel", body: { job: WIRE } });
  expect(step(outJob({ state: "ACCEPTED", by: NOW_S }), { type: "deadline" }, NOW_S).send).toBeUndefined();
  expect(step(outJob({ state: "RUNNING", by: NOW_S, running_at: NOW_S - 9 }), { type: "deadline" }, NOW_S).send).toBeUndefined();
});

test("a late res on LOST is recorded as late and never reopens", () => {
  const lost = step(outJob({ state: "SENT", by: NOW_S }), { type: "deadline" }, NOW_S + 1).record;
  const r = step(lost, resEvent(lost, "res-done"), NOW_S + 100);
  expect(r.record.state).toBe("LOST");
  expect(r.record.late).toBe("done");
  expect(r.record.results).toBeUndefined();
  expect(r.send).toBeUndefined();
});

test("a restart in the middle of a deadline fires it once", () => {
  const jobs = [outJob({ jobNo: 1, state: "SENT", by: NOW_S - 10 })];
  const first = dueJobs(jobs, NOW_S);
  expect(first).toHaveLength(1);
  const after = [step(first[0], { type: "deadline" }, NOW_S).record];
  expect(dueJobs(after, NOW_S + 1)).toEqual([]);
});

test("a kill during RUNNING ends CANCELLED and sends nothing", () => {
  const r = step(serverAt("RUNNING"), { type: "kill" }, NOW_S);
  expect(r.record.state).toBe("CANCELLED");
  expect(r.send).toBeUndefined();
});

test("a backstop under the allowance refuses with budget before RUNNING", () => {
  const low = step(serverAt("APPROVED"), EV.vmStart(ALLOWANCE_S - 1), NOW_S);
  expect(low.record).toMatchObject({ state: "REFUSED", refused: "budget" });
  expect(low.send?.body).toEqual({ job: WIRE, state: "refused", refused: "budget" });
  expect(low.record.running_at).toBeUndefined();
  expect(step(serverAt("APPROVED"), EV.vmStart(ALLOWANCE_S), NOW_S).record.state).toBe("RUNNING");
});


test("a job cancelled at minute 110 is charged 110", () => {
  const running = step(serverAt("APPROVED"), EV.vmStart(9000), NOW_S).record;
  const cancelled = step(running, { type: "cancel" }, NOW_S + 110 * MIN).record;
  expect(cancelled.state).toBe("CANCELLED");
  expect(chargedMinutes(cancelled)).toBe(110);
  expect(remaining([cancelled], DEFAULT_BUDGETS, NOW_S + 111 * MIN).vmMinutes).toBe(DEFAULT_BUDGETS.vmMinutesPerDay - 110);
});

test("a charge rounds up to a whole minute, and a job that never ran is charged nothing", () => {
  const running = step(serverAt("APPROVED"), EV.vmStart(9000), NOW_S).record;
  expect(chargedMinutes(step(running, { type: "cancel" }, NOW_S + 61).record)).toBe(2);
  expect(chargedMinutes(step(running, { type: "cancel" }, NOW_S + 60).record)).toBe(1);
  expect(chargedMinutes(step(serverAt("RESOLVED"), { type: "cancel" }, NOW_S).record)).toBe(0);
  expect(chargedMinutes(running, NOW_S + 600)).toBe(10);
});

test("a vm-done on a cancelled job is accounting only: it does not reopen and the charge stays", () => {
  const running = step(serverAt("APPROVED"), EV.vmStart(9000), NOW_S).record;
  const cancelled = step(running, { type: "cancel" }, NOW_S + 110 * MIN).record;
  const r = step(cancelled, { type: "vm-done", results: ["pass"], runner_minutes: 113 }, NOW_S + 112 * MIN);
  expect(r.record.state).toBe("CANCELLED");
  expect(r.send).toBeUndefined();
  expect(r.record.runner_minutes).toBe(113);
  expect(chargedMinutes(r.record)).toBe(110);
});

test("jobsPerDay counts every job that reached RESOLVED, and not one refused at resolve", () => {
  const refused = step(serverAt("RECEIVED"), EV.resolveFail, NOW_S).record;
  const cancelled = step(step(serverAt("RECEIVED"), EV.resolveOk, NOW_S).record, { type: "cancel" }, NOW_S + 5).record;
  const expired = step(serverAt("RESOLVED"), { type: "deadline" }, NOW_S).record;
  expect(refused.resolved_at).toBeUndefined();
  expect(cancelled.resolved_at).toBe(NOW_S);
  expect(remaining([refused], DEFAULT_BUDGETS, NOW_S).jobs).toBe(DEFAULT_BUDGETS.jobsPerDay);
  expect(remaining([refused, cancelled, expired], DEFAULT_BUDGETS, NOW_S + 10).jobs).toBe(DEFAULT_BUDGETS.jobsPerDay - 2);
});

test("remaining counts only today, only server jobs, and floors at zero", () => {
  const yesterday = inJob({ jobNo: 9, state: "DONE", resolved_at: NOW_S - 36 * H, running_at: NOW_S - 36 * H, ended_at: NOW_S - 35 * H, by: null });
  const mine = outJob({ jobNo: 8, state: "DONE", by: null });
  const today = inJob({ jobNo: 7, state: "DONE", resolved_at: NOW_S - 600, running_at: NOW_S - 600, ended_at: NOW_S - 300, by: null });
  expect(remaining([yesterday, mine, today], DEFAULT_BUDGETS, NOW_S)).toEqual({ jobs: DEFAULT_BUDGETS.jobsPerDay - 1, vmMinutes: DEFAULT_BUDGETS.vmMinutesPerDay - 5 });
  const many = Array.from({ length: 20 }, (_, i) => inJob({ jobNo: 100 + i, state: "DONE", resolved_at: NOW_S - 100, running_at: NOW_S - 100, ended_at: NOW_S - 50, by: null }));
  expect(remaining(many, { ...DEFAULT_BUDGETS, jobsPerDay: 10 }, NOW_S).jobs).toBe(0);
});

test("a job that ran across local midnight is charged to each day for the minutes it ran in it", () => {
  const midnight = new Date(2026, 10, 20).getTime() / 1000;
  const across = (over: Partial<JobRecord> = {}) => inJob({ jobNo: 50, state: "DONE", by: null, resolved_at: midnight - 4000, running_at: midnight - 30 * MIN, ended_at: midnight + 40 * MIN, ...over });
  expect(remaining([across()], DEFAULT_BUDGETS, midnight + H).vmMinutes).toBe(DEFAULT_BUDGETS.vmMinutesPerDay - 40);
  expect(remaining([across()], DEFAULT_BUDGETS, midnight - 5 * MIN).vmMinutes).toBe(DEFAULT_BUDGETS.vmMinutesPerDay - 25);
  expect(remaining([across({ state: "RUNNING", by: midnight + 2 * H, ended_at: undefined })], DEFAULT_BUDGETS, midnight + 20 * MIN).vmMinutes).toBe(DEFAULT_BUDGETS.vmMinutesPerDay - 20);
  expect(remaining([across({ running_at: midnight - 3 * H, ended_at: midnight - 2 * H })], DEFAULT_BUDGETS, midnight + H).vmMinutes).toBe(DEFAULT_BUDGETS.vmMinutesPerDay);
  expect(remaining([across({ running_at: midnight + 10 * MIN, ended_at: midnight + 25 * MIN })], DEFAULT_BUDGETS, midnight + H).vmMinutes).toBe(DEFAULT_BUDGETS.vmMinutesPerDay - 15);
});

test("the queue holds jobs waiting for a slot, not the one that is running or ones that are over", () => {
  const jobs = [serverAt("RECEIVED"), serverAt("RESOLVED"), serverAt("APPROVED"), serverAt("RUNNING"), serverAt("DONE"), serverAt("EXPIRED"), requesterAt("SENT")];
  expect(queueDepth(jobs)).toBe(3);
});

test("a res done builds a schema-clean body: results, minutes, image and log", () => {
  const two = { ...serverAt("APPROVED"), suites: ["alias-a", "alias-b"], paths: ["scripts/hooks/test-a.sh", "scripts/ci/test-b.sh"] };
  const running = step(two, EV.vmStart(9000), NOW_S).record;
  const done = step(running, { type: "vm-done", results: ["pass", "error"], golden: "e".repeat(64), log_sha256: "d".repeat(64), log_bytes: 77 }, NOW_S + 7 * MIN);
  expect(done.send?.body).toEqual({ job: WIRE, state: "done", results: ["pass", "error"], minutes: 7, image: "e".repeat(64), log: { sha256: "d".repeat(64), bytes: 77 } });
  const env = buildEnvelope("res", done.send!.body, CTX);
  expect(env.kind).toBe("res");
  const wrong = step(running, { type: "vm-done", results: ["pass"] }, NOW_S + 60);
  expect((wrong.send!.body.results as string[])).toEqual(["error", "error"]);
});

test("a deadline on a RUNNING job marks every suite error and sends the result", () => {
  const running = step(serverAt("APPROVED"), EV.vmStart(1500), NOW_S).record;
  const r = step(running, { type: "deadline" }, running.by!);
  expect(r.record.state).toBe("DONE");
  expect(r.send?.body).toMatchObject({ state: "done", results: ["error"] });
  expect(r.record.results).toEqual(["error"]);
});

test("a job still RECEIVED today counts toward jobsPerDay once, and the same job counts once more only if it resolves", () => {
  const received = serverAt("RECEIVED");
  expect(remaining([received], DEFAULT_BUDGETS, NOW_S).jobs).toBe(DEFAULT_BUDGETS.jobsPerDay - 1);
  const resolved = step(received, EV.resolveOk, NOW_S + 5).record;
  expect(remaining([resolved], DEFAULT_BUDGETS, NOW_S + 5).jobs).toBe(DEFAULT_BUDGETS.jobsPerDay - 1);
  const stale = inJob({ jobNo: 9, state: "RECEIVED", created: NOW_S - 36 * H });
  expect(remaining([stale], DEFAULT_BUDGETS, NOW_S).jobs).toBe(DEFAULT_BUDGETS.jobsPerDay);
});
