import type { SpoolRec } from "./chain";
import { utcDay } from "./ids";
import { renderNotify } from "./notify";
import { C0_C1_TEST, INVISIBLE_TEST } from "./sanitize";

export const DRAFT_TTL_MS = 30 * 60_000;
export const MAX_PENDING_DRAFTS = 3;
export const MAX_DRAFTS_PER_DAY = 20;
export const REVIEW_MAX = 4096;

export type DraftState = "PENDING" | "SENDING" | "SENT" | "FAILED" | "REJECTED" | "EXPIRED" | "REFUSED";
export const FINAL_STATES: readonly DraftState[] = ["SENT", "FAILED", "REJECTED", "EXPIRED", "REFUSED"];

type Rec = Record<string, any>;
type DraftSpool = Extract<SpoolRec, { type: "draft" }>;

export function draftState(outbox: Rec[], id: string): DraftState | null {
  if (!outbox.some(r => r.kind === "draft" && r.id === id)) return null;
  const done = outbox.find(r => r.kind === "draft-result" && r.draft === id);
  if (done) return done.state as DraftState;
  const intent = outbox.find(r => r.kind === "intent" && r.draft === id);
  if (!intent) return "PENDING";
  if (outbox.some(r => r.kind === "sent" && r.intent === intent.n)) return "SENT";
  if (outbox.some(r => r.kind === "failed" && r.intent === intent.n)) return "FAILED";
  if (outbox.some(r => r.kind === "refused" && r.intent === intent.n)) return "REFUSED";
  return "SENDING";
}

export const badChars = (text: string): boolean => C0_C1_TEST.test(text) || INVISIBLE_TEST.test(text);

export function reviewTooLong(d: { peer: string; root: number; draft: string; source: DraftSpool["source"]; deadline: number; text: string }, himmelRoot: string): boolean {
  const { text } = renderNotify({ kind: "notify", type: "draft", ts: 0, ...d }, himmelRoot);
  return text.length > REVIEW_MAX;
}

export const pendingCount = (outboxes: Rec[][]): number => outboxes.reduce((n, o) => n + o.filter(r => r.kind === "draft" && draftState(o, r.id) === "PENDING").length, 0);
export const draftsToday = (outboxes: Rec[][], nowMs: number): number => outboxes.reduce((n, o) => n + o.filter(r => r.kind === "draft" && utcDay(r.ts * 1000) === utcDay(nowMs)).length, 0);
