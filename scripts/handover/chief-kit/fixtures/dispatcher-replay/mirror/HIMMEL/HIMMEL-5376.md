---
key: "HIMMEL-5376"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["config","needs-standard","sector2-deployment","security","theme-config-ui-himmelctl","unscheduled"]
fixVersions: []
parent: "HIMMEL-6183"
created: "2026-10-12T15:05:35.064+0200"
updated: "2026-10-17T18:13:34.145+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: ["HIMMEL-5377"]
  relates: []
---

# HIMMEL-5376: config: guard writes to himmel.conf, then let gate policy live in the tracked file

## Description

HIMMEL-3111 put policy in config.json only because nothing stops an agent from writing himmel.conf. An agent could plant CR_FLOOR_FALLBACK=claude-only there and loosen the review gate. The test row "(e) policy in himmel.conf is not honoured" in scripts/lib/test-load-config.sh pins the current refusa
- Files: scripts/hooks/ (a new guard, wired via wire-hook-bash.mjs), scripts/lib/load-config.sh (_himmel_config_layers, load_policy), scripts/lib/test-load-config.sh row (e), docs/internals/config-layers.md.
- Editing scripts/hooks/*.sh trips the hook-integrity guard in a leg; launch with the bypass.
- Spec: docs/internals/config-layers.md "Why this route".
- scripts/setup/migrate-env-config.sh --vault compares the raw readlink of an existing ~/.himmel/himmel.conf link with the tracked vault path. A relative link that resolves to the same tracked file is refused (exit 1) instead of accepted. This fails safe: nothing is moved, and the operator sees the
