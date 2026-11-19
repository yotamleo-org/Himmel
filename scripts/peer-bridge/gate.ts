import fs from "node:fs";
import { constants } from "node:fs";
import { GROUP_ANONYMOUS_BOT_ID } from "../telegram/gate";
import { readChain } from "./chain";
import type { Config } from "./config";
import { parseControl, type Control } from "./grammar";

export class DedupWindow {
  private keys = new Set<string>();
  private order: string[] = [];
  constructor(private max = 1000) {}
  has(k: string) { return this.keys.has(k); }
  add(k: string) {
    if (this.keys.has(k)) return;
    this.keys.add(k); this.order.push(k);
    if (this.order.length > this.max) this.keys.delete(this.order.shift()!);
  }
}

export type GateState = {
  ourBotId: string;
  ourUsername: string;
  committed: number;            // highest update_id already processed
  recent: DedupWindow;          // `${chat}:${from}:${id}` of the last 1000 admitted records
  roots: Set<string>;           // `${chat}:${message_id}` of every thread root, ours or theirs
  rate: Map<string, number[]>;  // peer -> ms timestamps of admitted messages
  now: number;                  // ms; the caller sets it before each batch
};

export function createGateState(init: { ourBotId: string; ourUsername: string; committed: number; now: number }): GateState {
  return { ...init, recent: new DedupWindow(1000), roots: new Set(), rate: new Map() };
}

export type PeerMsgRec = {
  kind: "peer-msg"; untrusted: true; peer: string; from_id: string; from_is_bot: boolean; chat_id: number;
  message_id: number; root_id: number; id?: string; tag: string; ts: number; text: string;
  tpl_root?: number; by?: number;
};
export type UnknownChat = { chat_id: number; type: string; title?: string; migrated_from?: number };
export type Admit =
  | { ok: true; peer: string; rec: PeerMsgRec; truncated: boolean }
  | { ok: false; rule: 1 | 2 | 3 | 4 | 5 | 6 | 7; reason: string; log: string; peer?: string; unknownChat?: UnknownChat };

export function noteAdmitted(state: GateState, rec: Pick<PeerMsgRec, "peer" | "chat_id" | "from_id" | "id" | "ts">): void {
  if (rec.id) state.recent.add(`${rec.chat_id}:${rec.from_id}:${rec.id}`);
  const list = state.rate.get(rec.peer) ?? [];
  list.push(rec.ts * 1000);
  state.rate.set(rec.peer, list);
}

export function rebuildFromInbox(state: GateState, records: Pick<PeerMsgRec, "peer" | "chat_id" | "from_id" | "id" | "ts">[]): void {
  for (const rec of records) noteAdmitted(state, rec);
  for (const [peer, list] of state.rate) state.rate.set(peer, list.filter(t => state.now - t < 60_000));
}

// Telegram counts UTF-16 code units, so the cap is on .length, and a cut never
// leaves half a surrogate pair.
function cap(text: string, max: number): { text: string; truncated: boolean } {
  if (text.length <= max) return { text, truncated: false };
  let out = text.slice(0, max);
  const last = out.charCodeAt(out.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) out = out.slice(0, -1);
  return { text: out, truncated: true };
}

const FORWARD_FIELDS = ["forward_origin", "forward_from", "forward_from_chat", "forward_date", "forward_sender_name", "forward_signature", "is_automatic_forward"];

export function admit(update: any, cfg: Pick<Config, "peers" | "maxTextChars">, state: GateState): Admit {
  const msg = update?.message ?? update?.edited_message ?? update?.channel_post ?? update?.edited_channel_post;
  const chatId = msg?.chat?.id;
  const fromId = msg?.from?.id;
  const drop = (rule: 1 | 2 | 3 | 4 | 5 | 6 | 7, reason: string, extra: Partial<Extract<Admit, { ok: false }>> = {}): Admit => ({
    ok: false, rule, reason, log: `drop rule=${rule} reason=${reason} update=${update?.update_id} chat=${chatId} from=${fromId}`, ...extra,
  });

  // 1. Dedup.
  if (!Number.isSafeInteger(update?.update_id) || update.update_id <= state.committed) return drop(1, "replayed update_id");
  if (!msg) return drop(6, "not a message");
  const text: string | undefined = typeof msg.text === "string" ? msg.text : undefined;
  const control: Control | undefined = text === undefined ? undefined : parseControl(text, state.ourUsername);
  const controlId = control && !control.untagged ? control.id : undefined;
  if (controlId && state.recent.has(`${chatId}:${fromId}:${controlId}`)) return drop(1, "duplicate message id");

  // 2. Supergroup only.
  const configured = Object.entries(cfg.peers).find(([, p]) => p.chatId === chatId);
  if (msg.chat?.type !== "supergroup") {
    if (configured && Number.isSafeInteger(msg.migrate_to_chat_id)) {
      return drop(2, `MIGRATED to ${msg.migrate_to_chat_id}`, { unknownChat: { chat_id: msg.migrate_to_chat_id, type: "supergroup", migrated_from: chatId } });
    }
    return drop(2, "not a supergroup");
  }

  // 3. Configured chat.
  if (!configured) {
    const title = typeof msg.chat.title === "string" ? msg.chat.title.slice(0, 128) : undefined;
    return drop(3, "unknown chat", { unknownChat: { chat_id: chatId, type: msg.chat.type, title } });
  }
  const [peerName, peer] = configured;

  // 4. Allowed sender.
  if (fromId === undefined || fromId === null) return drop(4, "no sender", { peer: peerName });
  if (peer.allowFrom.length === 0) return drop(4, "empty allowFrom", { peer: peerName });
  if (!peer.allowFrom.includes(String(fromId))) return drop(4, "sender not in allowFrom", { peer: peerName });

  // 5. No disguised sender.
  if (msg.sender_chat) return drop(5, "sender_chat", { peer: peerName });
  if (String(fromId) === String(GROUP_ANONYMOUS_BOT_ID)) return drop(5, "anonymous admin", { peer: peerName });
  if (String(fromId) === state.ourBotId) return drop(5, "own bot", { peer: peerName });

  // 6. Plain text, addressed to us.
  if (update.edited_message || msg.edit_date !== undefined) return drop(6, "edit", { peer: peerName });
  if (FORWARD_FIELDS.some(f => msg[f] !== undefined)) return drop(6, "forward", { peer: peerName });
  if (msg.via_bot) return drop(6, "via_bot", { peer: peerName });
  if (msg.external_reply) return drop(6, "external_reply", { peer: peerName });
  if (msg.quote) return drop(6, "quote", { peer: peerName });
  if (text === undefined || !control) return drop(6, "not plain text", { peer: peerName });
  const replyTo = msg.reply_to_message;
  if (!replyTo) {
    if (!control.addr) return drop(6, "unaddressed root", { peer: peerName });
  } else if (!state.roots.has(`${chatId}:${replyTo.message_id}`)) {
    // Every thread message replies to its root, so a reply to anything else
    // (our #answer, a template, a stranger's message) has no thread to join.
    return drop(6, "reply to a message that is not a thread root", { peer: peerName });
  }

  // 7. Rate. Every admitted message counts, templates included.
  const inWindow = (state.rate.get(peerName) ?? []).filter(t => state.now - t < 60_000);
  if (inWindow.length >= peer.maxPerMinute) return drop(7, "rate", { peer: peerName });

  // 8. Length: cut, never drop.
  const tagged = !control.untagged && (control.tpl === undefined || String(fromId) === peer.peerBotId);
  const afterAddress = text.split("\n").slice(control.addr ? 1 : 0).join("\n");
  const { text: body, truncated } = cap(tagged ? control.body : afterAddress, cfg.maxTextChars);
  const rec: PeerMsgRec = {
    kind: "peer-msg", untrusted: true, peer: peerName,
    from_id: String(fromId), from_is_bot: msg.from?.is_bot === true, chat_id: chatId,
    message_id: msg.message_id, root_id: replyTo ? replyTo.message_id : msg.message_id,
    tag: !tagged ? "untagged" : control.tpl ? `tpl:${control.tpl}` : control.kind!,
    ts: Math.floor(state.now / 1000), text: body,
  };
  if (tagged) {
    rec.id = control.id;
    if (control.tpl) {
      rec.tpl_root = control.root;
      if (control.by) rec.by = Math.floor(control.by.getTime() / 1000);
    }
  }
  return { ok: true, peer: peerName, rec, truncated };
}

// One row per unknown chat id, 0600, so `setup.ts confirm` can offer it.
export function appendUnknownChat(file: string, row: UnknownChat): void {
  if (readChain(file).some(r => (r as any).chat_id === row.chat_id)) return;
  const fd = fs.openSync(file, constants.O_WRONLY | constants.O_CREAT | constants.O_APPEND | constants.O_NOFOLLOW, 0o600);
  try {
    const buf = fs.readFileSync(file);
    if (buf.length > 0 && buf[buf.length - 1] !== 10) fs.ftruncateSync(fd, buf.lastIndexOf(10) + 1);
    fs.writeFileSync(fd, JSON.stringify({ ...row, ts: Math.floor(Date.now() / 1000) }) + "\n");
  } finally { fs.closeSync(fd); }
}
