// scripts/lanes/claudex-session-root.mjs
// The one resolver for where claudex worker sessions live. Claude Code refuses
// a worker's Write under a `.claude` directory (no allow rule overrides it), so
// the default root is under ~/.himmel, not ~/.claude/handover/bridge.
// An explicit bridge root (BRIDGE_ROOT, or --bridge-root) wins and has no legacy.
//
// CLI: node claudex-session-root.mjs primary|all [--bridge-root <dir>] [--no-env]
//   primary  the root new sessions are minted in
//   all      primary, then the legacy root (one line each)
//   --no-env ignore BRIDGE_ROOT in the environment (stop-worker's chokepoint)
import { homedir } from "node:os";
import { join } from "node:path";
import { isMain } from "../lib/is-main.mjs";

export function claudexSessionRoots(bridgeRoot = process.env.BRIDGE_ROOT, home = homedir()) {
  if (bridgeRoot) return { primary: join(bridgeRoot, "claudex-sessions"), legacy: null };
  return {
    primary: join(home, ".himmel", "bridge", "claudex-sessions"),
    // ponytail: legacy root is read-only fallback for sessions in flight at the move, drop one release after it ships
    legacy: join(home, ".claude", "handover", "bridge", "claudex-sessions"),
  };
}

if (isMain(import.meta.url)) {
  const argv = process.argv.slice(2);
  const mode = argv[0];
  const i = argv.indexOf("--bridge-root");
  const explicit = i >= 0 ? argv[i + 1] : argv.includes("--no-env") ? undefined : process.env.BRIDGE_ROOT;
  if (mode !== "primary" && mode !== "all") {
    console.error("usage: claudex-session-root.mjs primary|all [--bridge-root <dir>] [--no-env]");
    process.exit(2);
  }
  const r = claudexSessionRoots(explicit);
  console.log(r.primary);
  if (mode === "all" && r.legacy) console.log(r.legacy);
}
