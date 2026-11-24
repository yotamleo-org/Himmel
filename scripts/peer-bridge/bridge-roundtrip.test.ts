import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseEnvelopeLine } from "./envelope";
import { writeSpoolEvent } from "./spool-events";
import { verify } from "./sign";
import { makeWorld, type World } from "./testlib-bridge";

const SHA = "a".repeat(40);
const SUITE = "scripts/hooks/test-a.sh";
const ALLOW = [{ alias: "alias-a", path: SUITE }];

const request = (w: World) => writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "req", body: { sha: SHA, suites: [SUITE] } }, w.alpha.peerDir);
const bravoEvent = (w: World, job: number, event: Record<string, unknown>) => writeSpoolEvent({ t: "job-event", peer: "alpha", job, event: event as any }, w.bravo.peerDir);

test("capacity round trip: alpha asks, bravo answers, alpha records ok / free / idle", async () => {
  const w = await makeWorld({ allow: ALLOW });
  writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "capacity-ask", body: {} }, w.alpha.peerDir);
  await w.step("alpha");
  expect(w.alpha.chain("jobs.jsonl")).toMatchObject([{ kind: "cap-ask" }]);
  await w.step("bravo");
  await w.step("alpha");
  const recs = w.alpha.chain("jobs.jsonl");
  expect(recs.map(r => r.kind)).toEqual(["cap-ask", "capacity"]);
  expect(recs[1]).toMatchObject({ kind: "capacity", peer: "bravo", state: "idle", capacity: "ok", queue: "free", re: recs[0].msg });
  expect(JSON.stringify(recs[1])).not.toMatch(/jobs_left|vm_minutes_left/);
});

test("a capacity reply for an ask we never sent, or one already answered, is dropped", async () => {
  const w = await makeWorld({ allow: ALLOW });
  writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "capacity-ask", body: {} }, w.alpha.peerDir);
  await w.step("alpha");
  await w.step("bravo");
  const reply = w.alpha.inbox[0];
  w.alpha.inbox.push({ ...reply, update_id: reply.update_id + 100, message: { ...reply.message, message_id: reply.message.message_id + 100 } });
  await w.step("alpha");
  expect(w.alpha.chain("jobs.jsonl").filter(r => r.kind === "capacity")).toHaveLength(1);
});

test("req round trip: alpha sends, bravo records RECEIVED by alias, resolve-ok makes it RESOLVED and alpha ACCEPTED", async () => {
  const w = await makeWorld({ allow: ALLOW });
  const name = request(w);
  await w.step("alpha");
  expect(w.alpha.jobs()).toMatchObject([{ jobNo: 1, dir: "out", state: "SENT", sha: SHA, suites: [SUITE] }]);
  expect(JSON.parse(readFileSync(join(w.alpha.peerDir, "spool", "results", name), "utf8"))).toEqual({ ok: true, job: 1 });

  await w.step("bravo");
  expect(w.bravo.jobs()).toMatchObject([{ jobNo: 1, dir: "in", state: "RECEIVED", suites: ["alias-a"], paths: [SUITE] }]);
  expect(w.bravo.jobs()[0].sha).toBeUndefined();
  expect(w.bravo.jobs()[0].peer_sha).toBe(SHA);

  bravoEvent(w, 1, { type: "resolve-ok", sha: SHA });
  await w.step("bravo");
  expect(w.bravo.jobs()[0]).toMatchObject({ state: "RESOLVED", sha: SHA });
  await w.step("alpha");
  expect(w.alpha.jobs()[0]).toMatchObject({ state: "ACCEPTED" });
});

test("a req for a suite outside bravo's allowlist is refused not-allowed, and alpha ends REFUSED", async () => {
  const w = await makeWorld({ allow: ALLOW });
  writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "req", body: { sha: SHA, suites: ["scripts/hooks/test-other.sh"] } }, w.alpha.peerDir);
  await w.step("alpha");
  await w.step("bravo");
  expect(w.bravo.jobs()[0]).toMatchObject({ state: "REFUSED", refused: "not-allowed", suites: [] });
  await w.step("alpha");
  expect(w.alpha.jobs()[0]).toMatchObject({ state: "REFUSED", refused: "not-allowed" });
});

test("alpha's cancel and halt reach bravo", async () => {
  const w = await makeWorld({ allow: ALLOW });
  request(w);
  await w.step("alpha");
  await w.step("bravo");
  bravoEvent(w, 1, { type: "resolve-ok", sha: SHA });
  await w.step("bravo");
  await w.step("alpha");
  writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "cancel", body: { jobNo: 1 } }, w.alpha.peerDir);
  await w.step("alpha");
  await w.step("bravo");
  expect(w.bravo.jobs()[0].state).toBe("CANCELLED");
  await w.step("alpha");
  expect(w.alpha.jobs()[0].state).toBe("CANCELLED");

  request(w);
  await w.step("alpha");
  await w.step("bravo");
  writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "halt", body: {} }, w.alpha.peerDir);
  await w.step("alpha");
  await w.step("bravo");
  expect(w.bravo.jobs().map(j => j.state)).toEqual(["CANCELLED", "CANCELLED"]);
});

test("every message on the wire is a four-line envelope, signed by its sender's key", async () => {
  const w = await makeWorld({ allow: ALLOW });
  writeSpoolEvent({ t: "env-out", peer: "bravo", kind: "capacity-ask", body: {} }, w.alpha.peerDir);
  request(w);
  await w.step("alpha");
  await w.step("bravo");
  bravoEvent(w, 1, { type: "resolve-ok", sha: SHA });
  await w.step("bravo");
  await w.step("alpha");
  expect(w.wire.length).toBeGreaterThanOrEqual(4);
  for (const m of w.wire) {
    const lines = m.text.split("\n");
    expect(lines).toHaveLength(4);
    expect(lines[0]).toBe(m.from === "alpha" ? "/peer@bravo_bot" : "/peer@alpha_bot");
    expect(parseEnvelopeLine(lines[2]).ok).toBe(true);
    expect(verify(lines[1], lines[2], lines[3].slice(4), w[m.from].key.pub)).toBe(true);
  }
  for (const m of w.wire) {
    const seen = w[m.from].checked.filter(c => c.lines.join("\n") === m.text);
    expect([m.text.split("\n")[1], seen.map(c => c.ok)]).toEqual([m.text.split("\n")[1], [true]]);
  }
  expect(w.alpha.checked.length + w.bravo.checked.length).toBe(w.wire.length);
  expect(w.alpha.chain("threads.jsonl")).toEqual([]);
  expect(w.bravo.chain("threads.jsonl")).toEqual([]);
});

test("a malformed spool event is dropped with a result, and an event for no job names the rule", async () => {
  const w = await makeWorld({ allow: ALLOW });
  const { submitSpool } = await import("./chain");
  const bad = submitSpool(w.bravo.peerDir, { type: "job-event", job: 1, event: { type: "frobnicate" } } as any);
  const none = bravoEvent(w, 99, { type: "approve" });
  await w.bravo.poller.drainSpool();
  const res = (n: string) => JSON.parse(readFileSync(join(w.bravo.peerDir, "spool", "results", n), "utf8"));
  expect(res(bad)).toEqual({ ok: false, rule: "malformed", why: "job-event: bad event" });
  expect(res(none)).toEqual({ ok: false, rule: "unknown-job" });
  expect(w.bravo.logs.some(l => l.includes("malformed spool"))).toBe(true);
});
