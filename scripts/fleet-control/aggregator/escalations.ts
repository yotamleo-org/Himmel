import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export type Escalation = { escalation_id: string; resume_token: string; sessionDir: string; capability: string; step: string | number; ts: string; shape: "read" | "write"; raw: Record<string, unknown> };

export function escalationId(e: { sessionDir: string; step: string | number; capability: string; ts: string }): string {
  return createHash("sha256").update([e.sessionDir, String(e.step), e.capability, e.ts].join("\0")).digest("hex").slice(0, 12);
}

// The resume token is the handle a paused worker (or the Telegram bridge) quotes
// to find its escalation again; it extends the escalation_id schema, never forks it.
export function resumeToken(escalation_id: string): string {
  return createHash("sha256").update(`${escalation_id}\0resume`).digest("hex").slice(0, 16);
}

export function capabilityShape(capability: string): "read" | "write" {
  const parts = capability.split(".");
  const verb = parts[parts.length - 1]?.toLowerCase() ?? "";
  if (capability === "net.fetch" || verb === "read" || verb === "get" || verb === "list" || verb === "fetch") return "read";
  if (verb === "write" || verb === "delete" || verb === "exec" || verb === "mutate" || verb === "push" || verb === "post") return "write";
  return "write";
}

export type EscalationsResult = { escalations: Escalation[]; parseErrors: number };

// A dropped (malformed) escalation line = an invisible blocked worker. Skip the
// bad line but COUNT it, so the incompleteness is surfaced rather than hidden.
function jsonl(path: string, onParseError: () => void): Record<string, unknown>[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8").split(/\r?\n/).filter((l) => l.trim() !== "").flatMap((l) => {
    try {
      const parsed: unknown = JSON.parse(l);
      return typeof parsed === "object" && parsed !== null ? [parsed as Record<string, unknown>] : [];
    } catch {
      onParseError();
      return [];
    }
  });
}

function scan(bridgeRoot: string): { all: { escalation: Escalation; closed: boolean }[]; parseErrors: number } {
  const root = join(bridgeRoot, "glm-sessions");
  if (!existsSync(root)) return { all: [], parseErrors: 0 };
  const all: { escalation: Escalation; closed: boolean }[] = [];
  let parseErrors = 0;
  const bump = () => { parseErrors++; };
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const sessionDir = join(root, entry.name);
    const closed = new Set(jsonl(join(sessionDir, "grants.jsonl"), bump).map((r) => r.escalation_id).filter(Boolean));
    for (const row of jsonl(join(sessionDir, "outbox.jsonl"), bump)) {
      if (row.type !== "escalation" || typeof row.capability !== "string") continue;
      const step = (typeof row.step === "string" || typeof row.step === "number") ? row.step : "";
      const ts = String(row.ts ?? "");
      const escalation_id = escalationId({ sessionDir, step, capability: row.capability, ts });
      all.push({ escalation: { escalation_id, resume_token: resumeToken(escalation_id), sessionDir, capability: row.capability, step, ts, shape: capabilityShape(row.capability), raw: row }, closed: closed.has(escalation_id) });
    }
  }
  return { all, parseErrors };
}

export function readEscalations(bridgeRoot: string): EscalationsResult {
  const { all, parseErrors } = scan(bridgeRoot);
  return { escalations: all.filter((r) => !r.closed).map((r) => r.escalation), parseErrors };
}

export function findByResumeToken(bridgeRoot: string, token: string): { state: "open" | "closed"; escalation: Escalation } | undefined {
  const hit = scan(bridgeRoot).all.find((r) => r.escalation.resume_token === token);
  return hit && { state: hit.closed ? "closed" : "open", escalation: hit.escalation };
}
