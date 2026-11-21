import fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Config } from "./config";
import { buildEnvelope, encodeCanonical, type Envelope, type Kind } from "./envelope";
import { keygen, sign, STATION_KEY, type KeyInfo } from "./sign";

export const BOT_US = "ours_bot", BOT_THEM = "example_bot";
export const OUR_BOT_ID = "111000111", PEER_BOT_ID = "555000111";
export const ENV_CHAT = -1001234567890;
export const NOW_S = 1_730_973_600;
export const HEX16 = "0123456789abcdef", SHA40 = "a".repeat(40), H64 = "b".repeat(64);

export type Station = { name: string; dir: string; keyPath: string; key: KeyInfo };
export function mkStation(name: string): Station {
  const dir = fs.mkdtempSync(join(tmpdir(), `peer-station-${name}-`));
  fs.chmodSync(dir, 0o700);
  const key = keygen(dir);
  return { name, dir, keyPath: join(dir, STATION_KEY), key };
}
export const dropStation = (s: Station) => fs.rmSync(s.dir, { recursive: true, force: true });

export const iso = (s: number) => new Date(s * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

export function envConfig(keys: { id: string; pub: string; addedAt?: string }[], over: Record<string, unknown> = {}): Pick<Config, "peers" | "maxTextChars" | "self"> {
  return {
    maxTextChars: 4000,
    self: { stationName: "yotam" },
    peers: {
      example: {
        peerBotId: PEER_BOT_ID, chatId: ENV_CHAT, allowFrom: [PEER_BOT_ID], opens: ["question", "status", "info"],
        maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30,
        theirs: {
          username: BOT_THEM, opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, copiedAt: "2026-11-07",
          stationName: "example", keys: keys.map(k => ({ addedAt: iso(NOW_S - 86400), ...k })),
        },
        ...over,
      } as any,
    },
  };
}

export const fromPeer = (kind: Kind, body: Record<string, unknown>, now = NOW_S): Envelope =>
  buildEnvelope(kind, body, { from: "example", to: "yotam", chat: ENV_CHAT, now });

export const REQ_BODY = { job: HEX16, op: "run-suite", sha: SHA40, suites: ["scripts/hooks/test-a.sh"] };
export const KIND_SAMPLES: [string, Kind, Record<string, unknown>][] = [
  ["req", "req", REQ_BODY],
  ["res accepted", "res", { job: HEX16, state: "accepted" }],
  ["res done", "res", { job: HEX16, state: "done", results: ["pass"], minutes: 5, image: H64, log: { sha256: H64, bytes: 10 } }],
  ["capacity-ask", "capacity-ask", {}],
  ["capacity", "capacity", { re: "89abcdef", state: "idle", queue: 0, jobs_left: 5, vm_minutes_left: 60 }],
  ["cancel", "cancel", { job: HEX16 }],
  ["halt", "halt", {}],
];

export function envLines(env: Envelope, st: Station, opts: { kid?: string; to?: string } = {}): string[] {
  const line2 = `#env:v1 k=${opts.kid ?? st.key.id} id=${env.msg}`;
  const line3 = encodeCanonical(env);
  return [`/peer@${opts.to ?? BOT_US}`, line2, line3, `sig=${sign(line2, line3, st.keyPath)}`];
}

let uid = 9000, mid = 7000;
export function tgUpdate(text: string, over: Record<string, unknown> = {}): any {
  return { update_id: ++uid, message: { message_id: ++mid, from: { id: Number(PEER_BOT_ID), is_bot: true, username: BOT_THEM }, chat: { id: ENV_CHAT, type: "supergroup", title: "bridge" }, date: NOW_S, text, ...over } };
}
export const envUpdate = (env: Envelope, st: Station, opts: { kid?: string; to?: string } = {}) => tgUpdate(envLines(env, st, opts).join("\n"));
