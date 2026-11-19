// The wake: one metadata-only line in the operator chat's outbox. The operator
// bridge sends it with no model run. The line carries the peer name, the thread
// number, a label this code wrote and a deadline, never peer or digest text.
import { appendOutboxLine } from "../telegram/bus";
import type { Config } from "./config";
import { PEER_NAME_RE } from "./ids";
import { WAKE_LABELS, type WakeEvent } from "./threads";

const COALESCE_MS = 10 * 60_000;
const pad = (n: number) => String(n).padStart(2, "0");
const day = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const stamp = (ms: number) => { const d = new Date(ms); return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };

type WakeCfg = Pick<Config, "bridgeRoot" | "operatorChatId" | "himmelRoot"> & { peers: Record<string, { maxWakesPerDay: number }> };

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
    if (!budget || budget.day !== day(now)) { budget = { day: day(now), sent: 0, warned: false }; this.perDay.set(ev.peer, budget); }
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

  private write(text: string): Promise<void> {
    return appendOutboxLine(this.cfg.bridgeRoot, this.cfg.operatorChatId, { text });
  }
}
