import { homedir } from "node:os";
import { join } from "node:path";

export const PEER_NAME_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;
export const SESSION_ID_RE = /^[A-Za-z0-9-]{1,64}$/;
export const TOKEN_RE = /^[0-9]{8,10}:[A-Za-z0-9_-]{35}$/;
export const BOT_ID_RE = /^[0-9]{1,15}$/;
export const KINDS = ["question", "status", "info"] as const;
export type OpenKind = (typeof KINDS)[number];

export const utcDay = (ms: number): string => new Date(ms).toISOString().slice(0, 10);

// A bot's numeric id is the part of its token before the colon.
export function botIdFromToken(token: string): string {
  const i = token.indexOf(":");
  return i < 0 ? "" : token.slice(0, i);
}

const home = () => process.env.HOME || homedir();
// The state and config dirs are fixed; tests point HOME at a temp dir.
export const stateDir = () => join(home(), ".himmel", "peer-bridge");
export const configDir = () => join(home(), ".config", "himmel", "peer-bridge");
export const peersFile = () => join(configDir(), "peers.json");
export const peerDir = (peer: string) => join(stateDir(), peer);
