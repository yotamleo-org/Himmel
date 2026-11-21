import type { PeerMsgRec } from "./gate";
import type { Action, Dir, ThreadRec } from "./threads";
import { Threads } from "./threads";

export const MIN = 60_000, H = 3_600_000;
export const T0 = Date.UTC(2026, 10, 9, 12, 0, 0);
export const CHAT = -1001234567890;

export const OPENS = ["question", "status", "info"] as const;
export const peerCfg = (maxOpenThreads = 5) => ({ opens: [...OPENS] as ("question" | "status" | "info")[], maxOpenThreads });

export function clock(start = T0) {
  const c = { t: start, now: () => c.t };
  return c;
}

export function threadsOf(recs: ThreadRec[], c = clock(), peers: string[] = ["example"], maxOpen = 5) {
  return Threads.load(recs, { peers: Object.fromEntries(peers.map(p => [p, peerCfg(maxOpen)])), clock: c.now });
}

export function mkThread(dir: Dir, state: string, over: Partial<ThreadRec> = {}): ThreadRec {
  return {
    kind: "thread", peer: "example", chat: CHAT, root: 100, dir, msgKind: "question", state,
    alloc: T0, deadline: T0 + 24 * H, remindAt: null, resent: false, deferred: false, auto: 0, closingSent: false, ts: T0,
    ...over,
  };
}

let mid = 5000;
export function inbound(tag: string, root: number, over: Partial<PeerMsgRec> = {}): PeerMsgRec {
  return { kind: "peer-msg", untrusted: true, peer: "example", from_id: "555000111", from_is_bot: true, chat_id: CHAT, message_id: ++mid, root_id: root, id: "0a0b0c0d", tag, ts: T0 / 1000, text: "x", ...over };
}
export function rootMsg(tag: string, message_id: number, over: Partial<PeerMsgRec> = {}): PeerMsgRec {
  return inbound(tag, message_id, { message_id, ...over });
}

// "send:nudge", "state:AWAITING", "wake:answer", "resend": one word per action.
export function sig(actions: Action[]): string[] {
  return actions.map(a => "send" in a ? `send:${a.send.tpl}` : "resend" in a ? "resend" : "wake" in a ? `wake:${a.wake.label}` : `state:${a.state.state}`);
}
export const states = (actions: Action[]) => actions.flatMap(a => ("state" in a ? [a.state] : []));
