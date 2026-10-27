import { createHash } from "node:crypto";

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

// Compatibility for the server and poller after the GLM escalation source retired.
export function readEscalations(_bridgeRoot: string): EscalationsResult {
  return { escalations: [], parseErrors: 0 };
}

export function findByResumeToken(_bridgeRoot: string, _token: string): { state: "open" | "closed"; escalation: Escalation } | undefined {
  return undefined;
}
