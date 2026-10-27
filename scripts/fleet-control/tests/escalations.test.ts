import { afterEach, test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { capabilityShape, escalationId, findByResumeToken, readEscalations, resumeToken } from "../aggregator/escalations";
import { startServer } from "../server";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "fleet-esc-"));
  roots.push(root);
  const s = join(root, "glm-sessions", "demo");
  mkdirSync(s, { recursive: true });
  const granted = { type: "escalation", capability: "net.fetch", step: 3, ts: "2026-07-07T00:00:00Z" };
  const open = { type: "escalation", capability: "fs.write", step: "ship", ts: "2026-07-07T00:01:00Z" };
  const id = escalationId({ sessionDir: s, step: granted.step, capability: granted.capability, ts: granted.ts });
  writeFileSync(join(s, "outbox.jsonl"), `${JSON.stringify(granted)}\n${JSON.stringify(open)}\n{not json\n`);
  writeFileSync(join(s, "grants.jsonl"), `${JSON.stringify({ escalation_id: id, capability: "net.fetch" })}\n`);
  return { root, id };
}

test("escalationId is deterministic first-12-hex of sha256 over the tuple", () => {
  const a = escalationId({ sessionDir: "/s", step: 3, capability: "net.fetch", ts: "2026-07-07T00:00:00Z" });
  const b = escalationId({ sessionDir: "/s", step: 3, capability: "net.fetch", ts: "2026-07-07T00:00:00Z" });
  expect(a).toBe(b);
  expect(a).toMatch(/^[0-9a-f]{12}$/);
});

test("retired GLM outboxes and grants no longer produce escalations or parse errors", () => {
  const { root } = fixture();
  expect(readEscalations(root)).toEqual({ escalations: [], parseErrors: 0 });
});

test("capabilityShape maps per the charter taxonomy", () => {
  expect(capabilityShape("net.fetch")).toBe("read");
  expect(capabilityShape("fs.read")).toBe("read");
  expect(capabilityShape("gh.list")).toBe("read");
  expect(capabilityShape("fs.write")).toBe("write");
  expect(capabilityShape("tool.delete")).toBe("write");
  expect(capabilityShape("mystery.cap")).toBe("write");
});

test("GET /escalations keeps its empty compatibility response", async () => {
  const { root } = fixture();
  const { server, port } = startServer({ port: 0, stateRoot: root, bridgeRoot: root, env: {} });
  try {
    const body = await (await fetch(`http://127.0.0.1:${port}/escalations`)).json();
    expect(body).toEqual({ escalations: [], parseErrors: 0 });
  } finally { server.stop(); }
});

test("retired GLM grants cannot resolve a resume token", () => {
  const { root, id } = fixture();
  expect(findByResumeToken(root, resumeToken(id))).toBeUndefined();
  expect(findByResumeToken(root, "0000000000000000")).toBeUndefined();
});
