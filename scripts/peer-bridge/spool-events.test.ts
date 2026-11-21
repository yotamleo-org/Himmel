import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { drainSpool } from "./chain";
import { peerDir } from "./ids";
import { SPOOL_ENV_KINDS, SPOOL_JOB_EVENTS, writeSpoolEvent } from "./spool-events";

let home: string, saved: string | undefined;
beforeEach(() => { saved = process.env.HOME; home = mkdtempSync(join(tmpdir(), "peer-spool-events-")); process.env.HOME = home; });
afterEach(() => { if (saved === undefined) delete process.env.HOME; else process.env.HOME = saved; rmSync(home, { recursive: true, force: true }); });

test("an event goes to the peer's own spool dir by default, as one 0600 file the poller can drain", () => {
  mkdirSync(join(peerDir("example"), "spool"), { recursive: true, mode: 0o700 });
  const name = writeSpoolEvent({ t: "job-event", peer: "example", job: 7, event: { type: "vm-start" } });
  const file = join(peerDir("example"), "spool", name);
  expect(statSync(file).mode & 0o777).toBe(0o600);
  expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({ type: "job-event", job: 7, event: { type: "vm-start" } });
  expect(drainSpool(peerDir("example")).map(d => d.name)).toEqual([name]);
});

test("an env-out event keeps its kind and body, and an explicit dir wins over the peer's", () => {
  const dir = mkdtempSync(join(tmpdir(), "peer-spool-dir-"));
  mkdirSync(join(dir, "spool"));
  try {
    const name = writeSpoolEvent({ t: "env-out", peer: "example", kind: "cancel", body: { jobNo: 2 } }, dir);
    expect(JSON.parse(readFileSync(join(dir, "spool", name), "utf8"))).toEqual({ type: "env-out", kind: "cancel", body: { jobNo: 2 } });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("a missing spool dir refuses and writes nothing", () => {
  expect(() => writeSpoolEvent({ t: "env-out", peer: "example", kind: "halt", body: {} })).toThrow();
});

test("the lists of events a chief or runner may inject are closed and exclude the poller's own", () => {
  expect([...SPOOL_ENV_KINDS]).toEqual(["req", "capacity-ask", "cancel", "halt"]);
  expect([...SPOOL_JOB_EVENTS]).toEqual(["resolve-ok", "resolve-fail", "approve", "vm-start", "vm-done"]);
  for (const own of ["kill", "deadline", "cancel", "halt", "res-done", "res-accepted"]) expect((SPOOL_JOB_EVENTS as readonly string[]).includes(own)).toBe(false);
});
