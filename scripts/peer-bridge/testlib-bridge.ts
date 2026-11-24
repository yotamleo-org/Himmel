import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readChain } from "./chain";
import { notifyFile, renderNotify } from "./notify";
import type { AllowEntry, Config } from "./config";
import { checkEnvelopeOutbound } from "./egress";
import { buildEnvelope, encodeCanonical, type Kind } from "./envelope";
import { Poller, type TgLike } from "./poller";
import { STATION_KEY, keygen, sign, type KeyInfo } from "./sign";

export const CHAT = -1001234567890;
export const T0_MS = Date.UTC(2026, 10, 20, 12);
const BOT_ID = { alpha: "100000001", bravo: "200000002" } as const;
const BOT_USER = { alpha: "alpha_bot", bravo: "bravo_bot" } as const;
export type Side = "alpha" | "bravo";

export type Bridge = {
  side: Side;
  other: Side;
  poller: Poller;
  cfg: Config;
  stateDir: string;
  configDir: string;
  peerDir: string;
  key: KeyInfo;
  logs: string[];
  inbox: any[];
  checked: { lines: string[]; ok: boolean }[];
  jobs(): any[];
  chain(file: string): any[];
};

export type World = {
  alpha: Bridge; bravo: Bridge; clock: { t: number; now: () => number }; wire: { from: Side; text: string }[];
  step(side: Side): Promise<void>;
  inject(from: Side, kind: Kind, body: Record<string, unknown>, opts?: { tamper?: boolean; text?: string }): string;
};

export type WorldOpts = { serves?: boolean; allow?: AllowEntry[]; approve?: "tty" | "auto"; budgets?: Record<string, number>; bravoPeer?: Record<string, unknown> };

export async function makeWorld(opts: WorldOpts = {}): Promise<World> {
  const clock = { t: T0_MS, now: () => clock.t };
  const wire: World["wire"] = [];
  const keys = { alpha: null as unknown as KeyInfo, bravo: null as unknown as KeyInfo };
  const dirs = {} as Record<Side, { stateDir: string; configDir: string }>;
  for (const s of ["alpha", "bravo"] as Side[]) {
    dirs[s] = { stateDir: mkdtempSync(join(tmpdir(), `peer-w-state-${s}-`)), configDir: mkdtempSync(join(tmpdir(), `peer-w-conf-${s}-`)) };
    writeFileSync(join(dirs[s].configDir, "hmac.key"), "k".repeat(32), { mode: 0o600 });
    keys[s] = keygen(dirs[s].configDir);
  }
  const bridges = {} as Record<Side, Bridge>;
  let updateId = 1000, messageId = 5000;

  for (const side of ["alpha", "bravo"] as Side[]) {
    const other: Side = side === "alpha" ? "bravo" : "alpha";
    const { stateDir, configDir } = dirs[side];
    const peerDir = join(stateDir, other);
    mkdirSync(join(peerDir, "spool"), { recursive: true, mode: 0o700 });
    const theirs = {
      username: BOT_USER[other], opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-20",
      stationName: other, keys: [{ id: keys[other].id, pub: keys[other].pub, addedAt: "2026-11-19T00:00:00Z" }],
    };
    const serving = side === "bravo" && opts.serves !== false;
    const cfg = {
      self: { stationName: side }, operatorBotId: "999000999", operatorChatId: 4242, bridgeRoot: mkdtempSync(join(tmpdir(), "peer-w-bridge-")), himmelRoot: join(import.meta.dir, "..", ".."), maxTextChars: 4000, addressing: "command",
      peers: {
        [other]: {
          serves: serving ? ["run-suite"] : [], approve: { "run-suite": opts.approve ?? "tty" },
          budgets: { jobsPerDay: 10, vmMinutesPerDay: 120, queueMax: 3, maxJobMinutes: 130, ...(opts.budgets ?? {}) },
          peerBotId: BOT_ID[other], chatId: CHAT, allowFrom: [BOT_ID[other]], opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 1000,
          maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30, theirs,
          ...(side === "bravo" ? opts.bravoPeer ?? {} : {}),
        },
      },
    } as unknown as Config;
    if (side === "bravo" && opts.allow) {
      writeFileSync(join(configDir, `${other}.suites`), opts.allow.map(a => `${a.alias} ${a.path}\n`).join(""), { mode: 0o600 });
    }
    const logs: string[] = [];
    const inbox: any[] = [];
    const tg: TgLike = {
      getUpdates: async () => inbox.splice(0),
      getChatMember: async () => ({ user: { username: BOT_USER[side] } }),
      sendMessage: async (_chat: number, text: string) => {
        wire.push({ from: side, text });
        bridges[other].inbox.push({ update_id: ++updateId, message: { message_id: ++messageId, from: { id: Number(BOT_ID[side]), is_bot: true, username: BOT_USER[side] }, chat: { id: CHAT, type: "supergroup" }, date: clock.t / 1000, text } });
        return { message_id: messageId };
      },
    };
    const checked: { lines: string[]; ok: boolean }[] = [];
    const checkEnvelope: typeof checkEnvelopeOutbound = async (lines, ctx) => { const r = await checkEnvelopeOutbound(lines, ctx); checked.push({ lines, ok: r.ok }); return r; };
    const poller = await Poller.create({ cfg, tg, ourBotId: BOT_ID[side], stateDir, configDir, clock: clock.now, hostname: "testbox", checkEnvelope, log: l => logs.push(l) });
    await poller.recover();
    bridges[side] = {
      side, other, poller, cfg, stateDir, configDir, peerDir, key: keys[side], logs, inbox, checked,
      chain: (f: string) => readChain(join(peerDir, f)),
      jobs() {
        const m = new Map<number, any>();
        for (const r of readChain(join(peerDir, "jobs.jsonl"))) if (r.kind === "job") m.set(r.jobNo as number, r);
        return [...m.values()];
      },
    };
  }
  const inject = (from: Side, kind: Kind, body: Record<string, unknown>, opts: { tamper?: boolean; text?: string } = {}): string => {
    const sender = bridges[from], to = sender.other;
    let text = opts.text;
    if (text === undefined) {
      const env = buildEnvelope(kind, body, { from, to, chat: CHAT, now: Math.floor(clock.t / 1000) });
      const line2 = `#env:v1 k=${sender.key.id} id=${env.msg}`, line3 = encodeCanonical(env);
      const sig = sign(line2, line3, join(sender.configDir, STATION_KEY));
      const sent = opts.tamper ? line3.slice(0, 20) + (line3[20] === "a" ? "b" : "a") + line3.slice(21) : line3;
      text = [`/peer@${BOT_USER[to]}`, line2, sent, `sig=${sig}`].join("\n");
    }
    bridges[to].inbox.push({ update_id: ++updateId, message: { message_id: ++messageId, from: { id: Number(BOT_ID[from]), is_bot: true, username: BOT_USER[from] }, chat: { id: CHAT, type: "supergroup" }, date: clock.t / 1000, text } });
    return text;
  };
  return {
    alpha: bridges.alpha, bravo: bridges.bravo, clock, wire, inject,
    async step(side: Side) {
      const b = bridges[side];
      await b.poller.processBatch(b.inbox.splice(0));
      await b.poller.drainSpool();
    },
  };
}

export function wakeLines(b: Bridge): string[] {
  return readChain(notifyFile(b.stateDir)).map(r => renderNotify(r as any, b.cfg.himmelRoot).text);
}
