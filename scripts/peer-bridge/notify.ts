import fs from "node:fs";
import { dirname, join } from "node:path";
import type { Chain } from "./chain";
import { PEER_NAME_RE } from "./ids";
import { sanitize } from "./sanitize";
import { WAKE_LABELS, type Dir, type WakeLabel } from "./threads";

export const LINE1_MAX = 200;
export const NOTIFY_LINE1_RE = /^peer [a-z0-9][a-z0-9-]{0,31} · /;

type Base = { kind: "notify"; peer: string; ts: number };
export type WakeNotify = Base & { type: "wake"; root: number; dir: Dir; label: WakeLabel; replyBy?: number };
export type EscalateNotify = Base & { type: "escalate"; root: number; dir: Dir; message_id: number; label: WakeLabel; replyBy?: number; summary: string | null; asks: string[]; reason?: string };
export type DraftNotify = Base & { type: "draft"; root: number; draft: string; source: "telegram" | "send.ts"; deadline: number; text: string };
export type ResultNotify = Base & { type: "result"; root: number; draft: string; state: "SENT" | "FAILED" | "REJECTED" | "EXPIRED" | "REFUSED"; message_id?: number; rule?: string };
export type DailyNotify = Base & { type: "daily"; day: string; escalated: number; digests: number; wakes: number; skipped: Record<string, number>; acked: number; dropped: number };
export type BudgetNotify = Base & { type: "budget"; which: "wake" | "escalate"; cap: number };
export type AlertNotify = Base & { type: "alert"; count: number };
export type NotifyRec = WakeNotify | EscalateNotify | DraftNotify | ResultNotify | DailyNotify | BudgetNotify | AlertNotify;

export const notifyFile = (stateDir: string) => join(stateDir, "notify", "notify.jsonl");

export function appendNotify(chain: Chain, file: string, rec: NotifyRec) {
  fs.mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  return chain.append(file, rec);
}

const pad = (n: number) => String(n).padStart(2, "0");
export const stamp = (ms: number) => { const d = new Date(ms); return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const hhmm = (ms: number) => { const d = new Date(ms); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };

const REASON_RE = /^[a-z0-9:-]{1,40}$/;
const DRAFT_RE = /^[0-9a-f]{8}$/;
const DAY_RE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
const count = (n: unknown) => Number.isSafeInteger(n) && (n as number) >= 0;

function need(ok: boolean, what: string) { if (!ok) throw new Error(`notify: bad ${what}`); }

function head(rec: NotifyRec & { root: number }): string {
  need(PEER_NAME_RE.test(rec.peer), "peer");
  need(Number.isSafeInteger(rec.root) && rec.root >= 0, "root");
  return `peer ${rec.peer} · T${rec.root}`;
}

function field(text: string, max: number): string {
  return sanitize(text, max).replace(/\r?\n/g, " ").replace(/(^|\s)\//g, "$1∕");
}

const desk = (himmelRoot: string, peer: string) => `bash ${himmelRoot}/scripts/peer-bridge/desk.sh ${peer}`;
const by = (ms: number | undefined) => (ms ? ` · reply by ${stamp(ms)}` : "");

export function renderNotify(rec: NotifyRec, himmelRoot: string): { text: string; keyboard?: { peer: string; draft: string } } {
  need(PEER_NAME_RE.test(rec.peer), "peer");
  switch (rec.type) {
    case "wake":
      need((WAKE_LABELS as readonly string[]).includes(rec.label), "label");
      return { text: `${head(rec)} · ${rec.label}${by(rec.replyBy)}\nopen the desk: ${desk(himmelRoot, rec.peer)}` };
    case "escalate": {
      need((WAKE_LABELS as readonly string[]).includes(rec.label), "label");
      const line1 = `${head(rec)} · ${rec.label}${by(rec.replyBy)}`;
      if (rec.summary === null) {
        need(REASON_RE.test(rec.reason ?? ""), "reason");
        return { text: `${line1}\ntriage skipped (${rec.reason}). Read it in the desk: ${desk(himmelRoot, rec.peer)}` };
      }
      const lines = [line1, "UNTRUSTED: written by the peer's bot, summarized by a model. Reply to this message to draft an answer.", `summary: ${field(rec.summary, 280)}`];
      if (rec.asks.length) lines.push("asks:", ...rec.asks.slice(0, 3).map(a => `- ${field(a, 140)}`));
      return { text: lines.join("\n") };
    }
    case "draft":
      need(DRAFT_RE.test(rec.draft), "draft");
      need(rec.source === "telegram" || rec.source === "send.ts", "source");
      need(Number.isSafeInteger(rec.deadline), "deadline");
      return { text: `${head(rec)} · draft ${rec.draft} from ${rec.source} · approve by ${stamp(rec.deadline)}\nText to send, exactly:\n${rec.text}`, keyboard: { peer: rec.peer, draft: rec.draft } };
    case "result": {
      need(DRAFT_RE.test(rec.draft), "draft");
      const words: Record<string, string> = { SENT: `sent as message ${rec.message_id}`, FAILED: "failed", REJECTED: "rejected", EXPIRED: "expired", REFUSED: `refused (${rec.rule})` };
      need(rec.state in words, "state");
      if (rec.state === "SENT") need(Number.isSafeInteger(rec.message_id) && rec.message_id! > 0, "message id");
      if (rec.state === "REFUSED") need(REASON_RE.test(rec.rule ?? ""), "rule");
      return { text: `${head(rec)} · draft ${rec.draft} · ${words[rec.state]}` };
    }
    case "daily": {
      need(DAY_RE.test(rec.day), "day");
      need([rec.escalated, rec.digests, rec.wakes, rec.acked, rec.dropped].every(count), "count");
      const skipped = Object.entries(rec.skipped).map(([r, n]) => { need(REASON_RE.test(r) && count(n), "skipped"); return `${n} skipped: ${r}`; });
      return { text: `peer ${rec.peer} · ${rec.day} · triage: ${rec.escalated} escalated (${[`${rec.digests} as digests, ${rec.wakes} as wakes`, ...skipped].join("; ")}) · ${rec.acked} acked · ${rec.dropped} dropped` };
    }
    case "budget":
      need(count(rec.cap), "cap");
      if (rec.which === "wake") return { text: `peer ${rec.peer} · wake budget reached (${rec.cap} today) · later wakes stay silent until tomorrow` };
      need(rec.which === "escalate", "which");
      return { text: `peer ${rec.peer} · escalation budget reached (${rec.cap} today) · later messages show as wakes` };
    case "alert":
      need(Number.isSafeInteger(rec.count) && rec.count > 0, "count");
      return { text: `peer ${rec.peer} · ${rec.count} bad signatures in 1 h` };
    default:
      throw new Error("notify: unknown type");
  }
}

export const renderHeld = (since: number, reason: string) => `peer notifications held since ${hhmm(since)} (${reason})`;
export const renderFallback = (n: number, code: number) => `peer notify #${n} could not be delivered (Telegram ${code}); read the desk`;
export const renderChainAlert = (n: number) => `peer notify chain failed verification at #${n}; nothing more is sent until it is checked`;
