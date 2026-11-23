import { appendOutboxLine } from "../telegram/bus";
import type { Config } from "./config";
import { PEER_NAME_RE, utcDay } from "./ids";
import { WAKE_LABELS, type WakeEvent } from "./threads";

const COALESCE_MS = 10 * 60_000;
const pad = (n: number) => String(n).padStart(2, "0");
const stamp = (ms: number) => { const d = new Date(ms); return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };

type WakeCfg = Pick<Config, "bridgeRoot" | "operatorChatId" | "himmelRoot"> & { peers: Record<string, { maxWakesPerDay: number }> };

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
  private perDay = new Map<string, { day: string; sent: number; warned: boolean }>();
  constructor(private cfg: WakeCfg, private clock: () => number = Date.now) {}

  async wake(ev: WakeEvent): Promise<void> {
    if (!(WAKE_LABELS as readonly string[]).includes(ev.label)) throw new Error("wake: unknown label");
    if (!PEER_NAME_RE.test(ev.peer)) throw new Error("wake: bad peer name");
    if (!Number.isSafeInteger(ev.root) || ev.root < 0) throw new Error("wake: bad root");
    const now = this.clock();

    const key = `${ev.peer}:${ev.root}`;
    const last = this.lastByThread.get(key);
    if (last !== undefined && now - last < COALESCE_MS) return;

    const cap = this.cfg.peers[ev.peer]?.maxWakesPerDay ?? 0;
    let budget = this.perDay.get(ev.peer);
    if (!budget || budget.day !== utcDay(now)) { budget = { day: utcDay(now), sent: 0, warned: false }; this.perDay.set(ev.peer, budget); }
    if (budget.sent >= cap) {
      if (budget.warned) return;
      budget.warned = true;
      await this.write(`peer ${ev.peer} · wake budget reached (${cap} today) · later wakes stay silent until tomorrow`);
      return;
    }
    budget.sent += 1;
    this.lastByThread.set(key, now);
    const by = ev.replyBy ? ` · reply by ${stamp(ev.replyBy)}` : "";
    await this.write(`peer ${ev.peer} · T${ev.root} · ${ev.label}${by} · open the desk: bash ${this.cfg.himmelRoot}/scripts/peer-bridge/desk.sh ${ev.peer}`);
  }

  async alert(peer: string, count: number): Promise<void> {
    if (!PEER_NAME_RE.test(peer) || !Number.isSafeInteger(count) || count < 1) throw new Error("alert: bad peer or count");
    const now = this.clock();
    const cap = this.cfg.peers[peer]?.maxWakesPerDay ?? 0;
    let budget = this.perDay.get(peer);
    if (!budget || budget.day !== utcDay(now)) { budget = { day: utcDay(now), sent: 0, warned: false }; this.perDay.set(peer, budget); }
    if (budget.sent >= cap) {
      if (budget.warned) return;
      budget.warned = true;
      await this.write(`peer ${peer} · wake budget reached (${cap} today) · later wakes stay silent until tomorrow`);
      return;
    }
    budget.sent += 1;
    await this.write(`peer ${peer}: ${count} bad signatures in 1 h`);
  }

  private write(text: string): Promise<void> {
    return appendOutboxLine(this.cfg.bridgeRoot, this.cfg.operatorChatId, { text });
  }
}
