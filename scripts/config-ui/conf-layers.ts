// the behaviour keys (docs/internals/config-layers.md) set in ~/.himmel/himmel.conf.local and ~/.himmel/himmel.conf, as one map.
// himmel.conf.local wins over himmel.conf and an empty value reads as unset, as in scripts/lib/load-dotenv.sh.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseDotEnv } from "../himmelctl/lib/probes.js";

type Env = Record<string, string | undefined>;

// the keys scripts/lib/load-dotenv.sh serves from himmel.conf (_himmel_key_class "config"); any other key there is not read.
const CONF_KEYS = new Set([
  "HANDOVER_DIR", "USER_SLUG", "LUNA_VAULT_PATH", "HIMMEL_DOC_FRESHNESS", "HIMMEL_INITIATIVE", "HIMMEL_INITIATIVE_AFK",
  "HIMMEL_AFK", "HIMMEL_INITIATIVE_OVERNIGHT", "HIMMEL_OVERNIGHT", "HIMMEL_WHERE_ARE_WE", "HIMMEL_WHERE_ARE_WE_STALE_HOURS",
  "HIMMEL_WORKTREE_NUDGE", "HIMMEL_UPDATE_AUTOSTASH", "CR_PROFILE", "CR_CLAUDE_AGENTS", "TICKET_ID_REQUIRED",
  "TICKET_ID_PATTERN", "TICKET_ID_EXEMPT_AUTHORS", "TRACKER",
]);

export function readConfLayers(env: Env): Record<string, string> {
  const dir = join(env.HOME || homedir(), ".himmel");
  const out: Record<string, string> = {};
  for (const file of ["himmel.conf", "himmel.conf.local"]) {
    let raw = "";
    try { raw = readFileSync(join(dir, file), "utf8"); } catch { continue; }
    for (const [k, v] of Object.entries(parseDotEnv(raw) as Record<string, string>)) if (v && CONF_KEYS.has(k)) out[k] = v;
  }
  return out;
}
