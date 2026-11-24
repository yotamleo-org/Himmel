import { createHmac, timingSafeEqual } from "node:crypto";
import fs from "node:fs";
import { join } from "node:path";
import { atomicWrite } from "../telegram/bus";
import { SESSION_ID_RE } from "./ids";
import type { ModelRoute } from "./reader";
import type { Dir, Route, Transition } from "./threads";

export type DigestRec = {
  kind: "digest"; peer: string; message_id: number; root_id: number; id?: string; tag: string; from_id: string; ts: number;
  summary: string | null; asks: string[]; reason?: string; n?: number; h?: string;
  route?: Route; model_route?: ModelRoute;
};
export type JobRec = { kind: "job"; peer: string; message_id: number; root: number; dir: Dir; transition: Transition; ts: number; n?: number; h?: string };
export type EffectRec = { kind: "effect"; peer: string; message_id: number; outcome: "escalated" | "fallback-wake" | "suppressed" | "acked" | "dropped"; ts: number; n?: number; h?: string };

export const digestFile = (peerDir: string) => join(peerDir, "digests.jsonl");
const cursorFile = (peerDir: string, sid: string) => join(peerDir, "cursors", sid);

const mac = (key: Buffer, sid: string, peer: string, n: number) => createHmac("sha256", key).update(`ack|${sid}|${peer}|${n}`).digest("hex").slice(0, 16);

// `<n>x<mac>`: alphanumeric, bound to the session id and the peer, so another
// session's token advances nothing.
export const ackToken = (key: Buffer, sid: string, peer: string, n: number): string => `${n}x${mac(key, sid, peer, n)}`;

export function parseAck(key: Buffer, sid: string, peer: string, token: string): number | null {
  const m = /^([0-9]{1,12})x([0-9a-f]{16})$/.exec(token);
  if (!m || !SESSION_ID_RE.test(sid)) return null;
  const n = Number(m[1]);
  const want = Buffer.from(mac(key, sid, peer, n)), got = Buffer.from(m[2]);
  return want.length === got.length && timingSafeEqual(want, got) ? n : null;
}

export function readCursor(peerDir: string, sid: string): number {
  if (!SESSION_ID_RE.test(sid)) return 0;
  try { const n = Number(JSON.parse(fs.readFileSync(cursorFile(peerDir, sid), "utf8")).n); return Number.isSafeInteger(n) && n > 0 ? n : 0; } catch { return 0; }
}

export async function writeCursor(peerDir: string, sid: string, n: number): Promise<void> {
  if (!SESSION_ID_RE.test(sid)) throw new Error("bad session id");
  fs.mkdirSync(join(peerDir, "cursors"), { recursive: true, mode: 0o700 });
  if (n <= readCursor(peerDir, sid)) return;
  await atomicWrite(cursorFile(peerDir, sid), JSON.stringify({ n }));
}
