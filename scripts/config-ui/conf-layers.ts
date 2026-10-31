// the behaviour keys (docs/internals/config-layers.md) set in ~/.himmel/himmel.conf.local and ~/.himmel/himmel.conf, as one map.
// himmel.conf.local wins over himmel.conf and an empty value reads as unset, as in scripts/lib/load-dotenv.sh.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseDotEnv } from "../himmelctl/lib/probes.js";
import configKeys from "../himmelctl/lib/config-keys.json";

type Env = Record<string, string | undefined>;

// the himmel.conf keys scripts/lib/load-dotenv.sh serves (_himmel_key_class "config", minus the env-only ones), from the one key list the wizard pins to it.
const CONF_KEYS = new Set(
  configKeys.keys.filter((k: { name: string; class: string; envOnly?: boolean }) => k.class === "config" && !k.envOnly).map((k: { name: string }) => k.name),
);

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
