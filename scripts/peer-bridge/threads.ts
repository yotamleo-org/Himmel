// Thread state and deadlines. Neither side waits forever: every state entry
// assigns a fresh absolute deadline, and the tick fires each overdue timer once,
// oldest first. The deadlines come only from this side's own config and clock;
// a peer's text sets none of them, and its `by=` only ever stretches the wait of
// the thread it concerns, clamped.
import type { Peer } from "./config";
import { byStamp, type Tpl } from "./grammar";
import type { PeerMsgRec } from "./gate";
import type { ModelRoute } from "./reader";

const MIN = 60_000, H = 3_600_000;
export const ACK_BY = 30 * MIN;
export const RESEND_ACK_BY = 12 * H;
export const ANSWER_BY = 24 * H;
export const CLOSE_BY = 72 * H;
export const DEFERRED_FOR = 72 * H;
export const REMIND_AFTER = 12 * H;
export const CLAMP_FROM_ALLOC = 73 * H;
export const MAX_AUTO_PER_THREAD = 3;
export const MAX_AUTO_PER_HOUR = 20;

export type Dir = "out" | "in";
export type ThreadRec = {
  kind: "thread"; peer: string; chat: number; root: number; dir: Dir; msgKind: string;
  state: string;
  alloc: number;                   // ms the thread was allocated
  deadline: number | null;         // ms of the next timer; null once terminal
  remindAt: number | null;         // inbound OPEN only
  resent: boolean;                 // outbound: the one resend of an unacked root happened
  deferred: boolean;               // outbound: the peer's `deferred` was applied
  auto: number;                    // automatic messages sent on this thread, closing excluded
  closingSent: boolean;
  autoAt?: number; autoTpl?: string;
  ts: number;
};
export const WAKE_LABELS = [
  "new question", "new status", "new info", "reminder", "answer", "closed by peer", "unreachable", "expired",
  "closed", "declined", "peer message", "answer on a closed thread", "message on a closed thread", "cap hit",
] as const;
export type WakeLabel = (typeof WAKE_LABELS)[number];
export type WakeEvent = { peer: string; root: number; dir: Dir; label: WakeLabel; replyBy?: number };
export type Action =
  | { send: { peer: string; tpl: Tpl; root: number; by?: Date } }
  | { resend: { peer: string; root: number } }
  | { wake: WakeEvent }
  | { state: ThreadRec };

export type Transition = "opened" | "answered-now" | "other";
export type Route = "escalate" | "ack" | "drop";

export function effectiveRoute(kind: string, transition: Transition, proposed: ModelRoute): Route {
  const model = proposed === "ack" || proposed === "drop" ? proposed : null;
  if (model === null) return "escalate";
  if (transition === "opened") {
    if (kind === "question") return model === "drop" ? "drop" : "escalate";
    if (kind === "status" || kind === "info") return model;
    return "escalate";
  }
  if (transition === "answered-now") return "escalate";
  return "drop";
}

export function templateLine(name: Tpl, root: number, id: string, by?: Date): string {
  return `#tpl:${name} #${root} id=${id}${by ? ` by=${byStamp(by)}` : ""}`;
}

type Ev = "receipt" | "answer" | "deferred" | "nudge" | "other" | "closing" | "declined";
function eventOf(tag: string): Ev {
  switch (tag) {
    case "tpl:receipt": return "receipt";
    case "answer": return "answer";
    case "tpl:deferred": return "deferred";
    case "tpl:nudge": return "nudge";
    case "tpl:closing": return "closing";
    case "tpl:declined-kind": case "tpl:busy": return "declined";
    default: return "other";
  }
}
const kindLabel = (tag: string) => `new ${tag.replace("ask:", "")}` as WakeLabel;

type Opts = { peers: Record<string, Pick<Peer, "opens" | "maxOpenThreads">>; clock: () => number };

export class Threads {
  private threads = new Map<string, ThreadRec>();
  private autoLog = new Map<string, number[]>();
  private constructor(private opts: Opts) {}

  static load(records: ThreadRec[], opts: Opts): Threads {
    const t = new Threads(opts);
    for (const rec of records) {
      if (rec.kind !== "thread") continue;
      t.threads.set(t.key(rec.peer, rec.root), rec);
      if (rec.autoAt !== undefined) t.logAuto(rec.peer, rec.autoAt);
    }
    return t;
  }

  private key = (peer: string, root: number) => `${peer}:${root}`;
  private now = () => this.opts.clock();
  get(peer: string, root: number): ThreadRec | undefined { return this.threads.get(this.key(peer, root)); }
  all(): ThreadRec[] { return [...this.threads.values()]; }
  roots(): string[] { return this.all().map(t => `${t.chat}:${t.root}`); }
  openOutbound(peer: string): number { return this.all().filter(t => t.peer === peer && t.dir === "out" && t.deadline !== null).length; }
  private openInbound(peer: string): number { return this.all().filter(t => t.peer === peer && t.dir === "in" && t.deadline !== null).length; }

  private logAuto(peer: string, at: number) { const l = this.autoLog.get(peer) ?? []; l.push(at); this.autoLog.set(peer, l); }
  private hourly(peer: string, now: number) { return (this.autoLog.get(peer) ?? []).filter(t => now - t < H).length; }

  private commit(actions: Action[], rec: ThreadRec, patch: Partial<ThreadRec>, now: number): ThreadRec {
    const next: ThreadRec = { ...rec, autoAt: undefined, autoTpl: undefined, ...patch, ts: now };
    this.threads.set(this.key(next.peer, next.root), next);
    actions.push({ state: next });
    return next;
  }

  private template(actions: Action[], rec: ThreadRec, tpl: Tpl, now: number, by?: Date): Partial<ThreadRec> {
    if (tpl === "closing") {
      if (rec.closingSent) return {};
      actions.push({ send: { peer: rec.peer, tpl, root: rec.root } });
      return { closingSent: true };
    }
    if (rec.auto >= MAX_AUTO_PER_THREAD || this.hourly(rec.peer, now) >= MAX_AUTO_PER_HOUR) {
      actions.push({ wake: { peer: rec.peer, root: rec.root, dir: rec.dir, label: "cap hit" } });
      return {};
    }
    actions.push({ send: { peer: rec.peer, tpl, root: rec.root, by } });
    this.logAuto(rec.peer, now);
    return { auto: rec.auto + 1, autoAt: now, autoTpl: tpl };
  }

  private declineRoot(actions: Action[], peer: string, root: number, tpl: "declined-kind" | "busy", now: number) {
    if (this.hourly(peer, now) >= MAX_AUTO_PER_HOUR) return;
    actions.push({ send: { peer, tpl, root } });
    this.logAuto(peer, now);
  }

  private wake(actions: Action[], rec: ThreadRec, label: WakeLabel, replyBy?: number) {
    actions.push({ wake: { peer: rec.peer, root: rec.root, dir: rec.dir, label, ...(replyBy ? { replyBy } : {}) } });
  }

  private clampDeferred(rec: ThreadRec, by: number | undefined, now: number): number {
    const own = now + ANSWER_BY;
    const wanted = by === undefined ? own : Math.max(own, by + H);
    return Math.min(wanted, rec.alloc + CLAMP_FROM_ALLOC);
  }

  onOutbound(send: { peer: string; chat: number; root: number; kind: string; isRoot: boolean }): Action[] {
    const now = this.now(), actions: Action[] = [];
    if (send.isRoot) {
      if (this.get(send.peer, send.root)) return actions;
      const rec: ThreadRec = { kind: "thread", peer: send.peer, chat: send.chat, root: send.root, dir: "out", msgKind: send.kind, state: "SENT", alloc: now, deadline: now + ACK_BY, remindAt: null, resent: false, deferred: false, auto: 0, closingSent: false, ts: now };
      this.threads.set(this.key(rec.peer, rec.root), rec);
      actions.push({ state: rec });
      return actions;
    }
    const rec = this.get(send.peer, send.root);
    if (rec && rec.dir === "in" && send.kind === "answer" && rec.deadline !== null) this.commit(actions, rec, { state: "ANSWERED", deadline: null, remindAt: null }, now);
    return actions;
  }

  decline(peer: string, root: number): Action[] {
    const now = this.now(), actions: Action[] = [];
    const rec = this.get(peer, root);
    if (!rec || rec.dir !== "in" || rec.deadline === null) return actions;
    const patch = this.template(actions, rec, "declined-kind", now);
    this.commit(actions, rec, { ...patch, state: "DECLINED", deadline: null, remindAt: null }, now);
    return actions;
  }

  onInbound(msg: PeerMsgRec): { actions: Action[]; transition: Transition } {
    const now = this.now(), actions: Action[] = [];
    if (msg.root_id === msg.message_id) {
      const known = this.get(msg.peer, msg.message_id);
      this.onInboundRoot(msg, now, actions);
      return { actions, transition: !known && this.get(msg.peer, msg.message_id) ? "opened" : "other" };
    }
    const rec = this.get(msg.peer, msg.root_id);
    if (!rec) return { actions, transition: "other" };
    if (rec.dir === "in") return { actions: this.inInbound(rec, msg, now, actions), transition: "other" };
    const before = rec.state;
    this.outInbound(rec, msg, now, actions);
    const after = this.get(msg.peer, msg.root_id)!.state;
    return { actions, transition: before !== "ANSWERED" && after === "ANSWERED" ? "answered-now" : "other" };
  }

  ack(peer: string, root: number): Action[] {
    const now = this.now(), actions: Action[] = [];
    const rec = this.get(peer, root);
    if (!rec || rec.deadline === null) return actions;
    const sends: Action[] = [];
    const patch = this.template(sends, rec, "closing", now);
    this.commit(actions, rec, { ...patch, state: "ACKED", deadline: null, remindAt: null }, now);
    actions.push(...sends);
    return actions;
  }

  drop(peer: string, root: number): Action[] {
    const now = this.now(), actions: Action[] = [];
    const rec = this.get(peer, root);
    if (!rec || rec.deadline === null) return actions;
    this.commit(actions, rec, { state: "DROPPED", deadline: null, remindAt: null }, now);
    return actions;
  }

  private onInboundRoot(msg: PeerMsgRec, now: number, actions: Action[]): Action[] {
    if (this.get(msg.peer, msg.message_id)) return actions;
    const peer = this.opts.peers[msg.peer];
    if (!peer || msg.tag.startsWith("tpl:")) return actions;
    const kind = msg.tag.replace("ask:", "");
    if (msg.tag === "untagged" || !(peer.opens as string[]).includes(kind)) {
      this.declineRoot(actions, msg.peer, msg.message_id, "declined-kind", now);
      return actions;
    }
    if (this.openInbound(msg.peer) >= peer.maxOpenThreads) {
      this.declineRoot(actions, msg.peer, msg.message_id, "busy", now);
      return actions;
    }
    const rec: ThreadRec = { kind: "thread", peer: msg.peer, chat: msg.chat_id, root: msg.message_id, dir: "in", msgKind: kind, state: "OPEN", alloc: now, deadline: now + ANSWER_BY, remindAt: now + REMIND_AFTER, resent: false, deferred: false, auto: 0, closingSent: false, ts: now };
    this.threads.set(this.key(rec.peer, rec.root), rec);
    const sends: Action[] = [];
    const receipt = this.template(sends, rec, "receipt", now);
    // The state record goes first so a crash keeps the thread.
    this.commit(actions, rec, receipt, now);
    actions.push(...sends);
    this.wake(actions, rec, kindLabel(msg.tag), rec.deadline!);
    return actions;
  }

  private outInbound(rec: ThreadRec, msg: PeerMsgRec, now: number, actions: Action[]): Action[] {
    const ev = eventOf(msg.tag);
    const terminal = rec.deadline === null;
    const by = msg.by === undefined ? undefined : msg.by * 1000;
    if (terminal) { if (ev === "answer") this.wake(actions, rec, "answer on a closed thread"); return actions; }
    switch (rec.state) {
      case "SENT":
        if (ev === "receipt") this.commit(actions, rec, { state: "AWAITING", deadline: now + ANSWER_BY }, now);
        else if (ev === "answer") { this.commit(actions, rec, { state: "ANSWERED", deadline: now + CLOSE_BY }, now); this.wake(actions, rec, "answer"); }
        else if (ev === "deferred") this.commit(actions, rec, { state: "AWAITING", deadline: this.clampDeferred(rec, by, now), deferred: true }, now);
        else if (ev === "closing") { this.commit(actions, rec, { state: "CLOSED-BY-PEER", deadline: null }, now); this.wake(actions, rec, "closed by peer"); }
        else if (ev === "declined") { this.commit(actions, rec, { state: "DECLINED", deadline: null }, now); this.wake(actions, rec, "declined"); }
        else this.wake(actions, rec, "peer message");
        break;
      case "AWAITING":
      case "NUDGED":
        if (ev === "answer") { this.commit(actions, rec, { state: "ANSWERED", deadline: now + CLOSE_BY }, now); this.wake(actions, rec, "answer"); }
        else if (ev === "deferred") { if (!rec.deferred) this.commit(actions, rec, { deadline: this.clampDeferred(rec, by, now), deferred: true }, now); }
        else if (ev === "closing") { this.commit(actions, rec, { state: "CLOSED-BY-PEER", deadline: null }, now); this.wake(actions, rec, "closed by peer"); }
        else if (ev === "nudge" || ev === "other") this.wake(actions, rec, "peer message");
        break;
      case "ANSWERED":
        if (ev === "answer") this.wake(actions, rec, "answer");
        else if (ev === "nudge" || ev === "other") this.wake(actions, rec, "peer message");
        else if (ev === "closing") { this.commit(actions, rec, { state: "CLOSED", deadline: null }, now); this.wake(actions, rec, "closed"); }
        break;
    }
    return actions;
  }

  private inInbound(rec: ThreadRec, msg: PeerMsgRec, now: number, actions: Action[]): Action[] {
    const ev = eventOf(msg.tag);
    if (rec.deadline === null) {
      if (ev !== "nudge" && ev !== "closing") this.wake(actions, rec, "message on a closed thread");
      return actions;
    }
    if (ev === "closing") { this.commit(actions, rec, { state: "CLOSED-BY-PEER", deadline: null, remindAt: null }, now); this.wake(actions, rec, "closed by peer"); }
    else this.wake(actions, rec, "peer message");
    return actions;
  }

  tick(now: number = this.now()): Action[] {
    const due: { at: number; rec: ThreadRec; type: "remind" | "deadline" }[] = [];
    for (const rec of this.threads.values()) {
      if (rec.deadline === null) continue;
      if (rec.remindAt !== null && rec.remindAt <= now) due.push({ at: rec.remindAt, rec, type: "remind" });
      if (rec.deadline <= now) due.push({ at: rec.deadline, rec, type: "deadline" });
    }
    due.sort((a, b) => a.at - b.at || a.rec.root - b.rec.root);
    const actions: Action[] = [];
    for (const d of due) {
      const rec = this.threads.get(this.key(d.rec.peer, d.rec.root))!;
      if (rec.deadline === null) continue;
      if (d.type === "remind") {
        if (rec.remindAt !== d.at) continue;
        this.commit(actions, rec, { remindAt: null }, now);
        this.wake(actions, rec, "reminder", rec.deadline);
      } else {
        if (rec.deadline !== d.at) continue;
        this.fire(rec, now, actions);
      }
    }
    return actions;
  }

  private fire(rec: ThreadRec, now: number, actions: Action[]) {
    if (rec.dir === "out") {
      switch (rec.state) {
        case "SENT":
          if (!rec.resent) {
            actions.push({ resend: { peer: rec.peer, root: rec.root } });
            this.commit(actions, rec, { resent: true, deadline: now + RESEND_ACK_BY }, now);
          } else this.end(rec, "UNREACHABLE", "unreachable", now, actions);
          break;
        case "AWAITING": {
          const patch = this.template(actions, rec, "nudge", now);
          this.commit(actions, rec, { ...patch, state: "NUDGED", deadline: now + ANSWER_BY }, now);
          break;
        }
        case "NUDGED": this.end(rec, "EXPIRED", "expired", now, actions); break;
        case "ANSWERED": this.end(rec, "CLOSED", "closed", now, actions); break;
      }
      return;
    }
    if (rec.state === "OPEN") {
      const until = now + DEFERRED_FOR;
      const patch = this.template(actions, rec, "deferred", now, new Date(until));
      this.commit(actions, rec, { ...patch, state: "DEFERRED", deadline: until, remindAt: null }, now);
    } else if (rec.state === "DEFERRED") this.end(rec, "EXPIRED", "expired", now, actions);
  }

  private end(rec: ThreadRec, state: string, label: WakeLabel, now: number, actions: Action[]) {
    const patch = this.template(actions, rec, "closing", now);
    this.commit(actions, rec, { ...patch, state, deadline: null, remindAt: null }, now);
    this.wake(actions, rec, label);
  }
}
