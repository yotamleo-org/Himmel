import { describe, test, expect } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { appendEvent, type JobAttrs } from "../src/ledger.js";
import { grantClaim, renewLease } from "../src/lease.js";

function freshLedger(): string {
  return join(mkdtempSync(join(tmpdir(), "ci-lease-")), "q.jsonl");
}
function jobAttrs(): JobAttrs {
  return {
    id: "j1", headSha: "h", runSha: "h", workflow: "ci", job: "lint", required: true,
    needsSecrets: false, publicSafe: false, os: "linux", heavy: false, deterministic: false,
    treeHash: "t", enqueuedAt: "t",
  };
}
const T0 = Date.parse("2026-07-05T00:00:00Z");

describe("grantClaim", () => {
  test("first claim wins; a second while the lease is live loses (deterministic)", () => {
    const p = freshLedger();
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    const a = grantClaim(J.id, "vm", 60000, T0, {}, p);
    const b = grantClaim(J.id, "vm", 60000, T0, {}, p);
    expect(a.ok).toBe(true);
    expect(b.ok).toBe(false);
  });

  test("a time-expired lease frees the job for a new claimant", () => {
    const p = freshLedger();
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    expect(grantClaim(J.id, "vm", 60000, T0, {}, p).ok).toBe(true);
    // 60s + 1ms later the first lease has expired.
    expect(grantClaim(J.id, "vm2", 60000, T0 + 60001, {}, p).ok).toBe(true);
  });

  test("heldBy reports the live holder; an explicit lease-expire re-opens it", () => {
    const p = freshLedger();
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    grantClaim(J.id, "vmA", 60000, T0, {}, p);
    const held = grantClaim(J.id, "vmB", 60000, T0, {}, p);
    expect(held.ok).toBe(false);
    if (held.ok === false) expect(held.heldBy).toBe("vmA");
    appendEvent({ t: "lease-expire", ts: "t", jobId: J.id }, {}, p);
    expect(grantClaim(J.id, "vmB", 60000, T0, {}, p).ok).toBe(true);
  });

  test("an unsubmitted job cannot be claimed", () => {
    expect(grantClaim("ghost", "vm", 1000, T0, {}, freshLedger()).ok).toBe(false);
  });
});

describe("renewLease (HIMMEL-8438)", () => {
  test("a renewing claimant keeps the job past the TTL; a second claim gets nothing", () => {
    const p = freshLedger();
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    expect(grantClaim(J.id, "A", 60000, T0, {}, p).ok).toBe(true);
    const r = renewLease(J.id, "A", 60000, T0 + 50000, {}, p);
    expect(r.ok).toBe(true);
    // t+61s: the ORIGINAL lease has lapsed but the renewed one (to t+110s) is live.
    expect(grantClaim(J.id, "B", 60000, T0 + 61000, {}, p).ok).toBe(false);
    // without a further renew it is re-granted only after the renewed lease lapses.
    expect(grantClaim(J.id, "B", 60000, T0 + 110001, {}, p).ok).toBe(true);
  });

  test("a non-claimant, an expired lease, or an unknown job cannot renew", () => {
    const p = freshLedger();
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    grantClaim(J.id, "A", 60000, T0, {}, p);
    expect(renewLease(J.id, "B", 60000, T0 + 1000, {}, p).ok).toBe(false);
    expect(renewLease(J.id, "A", 60000, T0 + 60001, {}, p).ok).toBe(false);
    expect(renewLease("ghost", "A", 60000, T0, {}, p).ok).toBe(false);
  });
});
