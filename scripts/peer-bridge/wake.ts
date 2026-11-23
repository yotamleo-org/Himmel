import { readChain, type Chain } from "./chain";
import { PEER_NAME_RE, utcDay } from "./ids";
import { appendNotify, type NotifyRec } from "./notify";
import type { Digest } from "./reader";
import { WAKE_LABELS, type WakeEvent } from "./threads";

const COALESCE_MS = 10 * 60_000;
export const ESCALATIONS_PER_DAY = 20;

type WakeCfg = { peers: Record<string, { maxWakesPerDay: number }> };
type Budget = { day: string; sent: number; warned: boolean; escalated: number; escWarned: boolean };

export class Tripwire {
  private fails = new Map<string, number[]>();
  private alerted = new Map<string, number>();
  constructor(private max = 3, private windowMs = 3_600_000) {}
  note(peer: string, nowMs: number): boolean {
    const list = (this.fails.get(peer) ?? []).filter(t => nowMs - t < this.windowMs);
    list.push(nowMs);
    this.fails.set(peer, list);
    if (list.length < this.max) return false;
    const last = this.alerted.get(peer);
    if (last !== undefined && nowMs - last < this.windowMs) return false;
    this.alerted.set(peer, nowMs);
    return true;
  }
}

export class Waker {
  private lastByThread = new Map<string, number>();
  private perDay = new Map<string, Budget>();
  private charged = new Map<string, "escalated" | "fallback-wake">();
  constructor(private cfg: WakeCfg, private chain: Chain, private file: string, private clock: () => number = Date.now) {
    const today = utcDay(this.clock());
    for (const r of readChain(file) as unknown as NotifyRec[]) {
      if (r.kind !== "notify") continue;
      if (r.type === "escalate") this.charged.set(`${r.peer}:${r.message_id}`, "escalated");
      if (r.type === "wake" && r.message_id !== undefined) this.charged.set(`${r.peer}:${r.message_id}`, "fallback-wake");
      if (utcDay(r.ts) !== today) continue;
      const b = this.budget(r.peer, r.ts);
      if (r.type === "wake" || r.type === "alert") b.sent += 1;
      if (r.type === "wake") this.lastByThread.set(`${r.peer}:${r.root}`, r.ts);
      if (r.type === "escalate") b.escalated += 1;
      if (r.type === "budget" && r.which === "wake") b.warned = true;
      if (r.type === "budget" && r.which === "escalate") b.escWarned = true;
    }
  }

  private budget(peer: string, now: number): Budget {
    let b = this.perDay.get(peer);
    if (!b || b.day !== utcDay(now)) { b = { day: utcDay(now), sent: 0, warned: false, escalated: 0, escWarned: false }; this.perDay.set(peer, b); }
    return b;
  }

  private check(ev: WakeEvent) {
    if (!(WAKE_LABELS as readonly string[]).includes(ev.label)) throw new Error("wake: unknown label");
    if (!PEER_NAME_RE.test(ev.peer)) throw new Error("wake: bad peer name");
    if (!Number.isSafeInteger(ev.root) || ev.root < 0) throw new Error("wake: bad root");
  }

  private async spendWake(peer: string, now: number): Promise<boolean> {
    const cap = this.cfg.peers[peer]?.maxWakesPerDay ?? 0;
    const b = this.budget(peer, now);
    if (b.sent < cap) { b.sent += 1; return true; }
    if (!b.warned) {
      b.warned = true;
      await this.append({ kind: "notify", type: "budget", peer, which: "wake", cap, ts: now });
    }
    return false;
  }

  async wake(ev: WakeEvent, message_id?: number): Promise<"sent" | "coalesced" | "capped"> {
    this.check(ev);
    const now = this.clock();
    const key = `${ev.peer}:${ev.root}`;
    const last = this.lastByThread.get(key);
    if (last !== undefined && now - last < COALESCE_MS) return "coalesced";
    if (!(await this.spendWake(ev.peer, now))) return "capped";
    this.lastByThread.set(key, now);
    await this.append({ kind: "notify", type: "wake", peer: ev.peer, root: ev.root, dir: ev.dir, label: ev.label, ...(ev.replyBy ? { replyBy: ev.replyBy } : {}), ...(message_id ? { message_id } : {}), ts: now });
    if (message_id) this.charged.set(`${ev.peer}:${message_id}`, "fallback-wake");
    return "sent";
  }

  async escalate(ev: WakeEvent & { message_id: number; digest: Digest }): Promise<"escalated" | "fallback-wake" | "suppressed"> {
    this.check(ev);
    if (!Number.isSafeInteger(ev.message_id) || ev.message_id <= 0) throw new Error("escalate: bad message id");
    const done = this.charged.get(`${ev.peer}:${ev.message_id}`);
    if (done) return done;
    const now = this.clock();
    const b = this.budget(ev.peer, now);
    if (b.escalated < ESCALATIONS_PER_DAY) {
      b.escalated += 1;
      this.charged.set(`${ev.peer}:${ev.message_id}`, "escalated");
      const d = ev.digest;
      await this.append({ kind: "notify", type: "escalate", peer: ev.peer, root: ev.root, dir: ev.dir, message_id: ev.message_id, label: ev.label, ...(ev.replyBy ? { replyBy: ev.replyBy } : {}), summary: d.summary, asks: d.asks, ...(d.reason ? { reason: d.reason } : {}), ts: now });
      return "escalated";
    }
    if (!b.escWarned) {
      b.escWarned = true;
      await this.append({ kind: "notify", type: "budget", peer: ev.peer, which: "escalate", cap: ESCALATIONS_PER_DAY, ts: now });
    }
    const { message_id, digest: _d, ...wake } = ev;
    return (await this.wake(wake, message_id)) === "sent" ? "fallback-wake" : "suppressed";
  }

  async alert(peer: string, count: number): Promise<void> {
    if (!PEER_NAME_RE.test(peer) || !Number.isSafeInteger(count) || count < 1) throw new Error("alert: bad peer or count");
    const now = this.clock();
    if (!(await this.spendWake(peer, now))) return;
    await this.append({ kind: "notify", type: "alert", peer, count, ts: now });
  }

  private async append(rec: NotifyRec): Promise<void> {
    await appendNotify(this.chain, this.file, rec);
  }
}
