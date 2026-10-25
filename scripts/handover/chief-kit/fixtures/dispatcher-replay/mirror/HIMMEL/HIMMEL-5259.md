---
key: "HIMMEL-5259"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["theme-tool-evals-upstream-drift","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6201"
created: "2026-10-11T18:20:26.367+0200"
updated: "2026-10-19T03:18:53.364+0200"
resolution: "Done"
resolved: "2026-10-19T03:18:53.346+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6136"]
---

# HIMMEL-5259: Re-vendor claude-hud to upstream v0.10.0 via fork-resync (carried delta rebase)

## Description

- Tree: marketplace/plugins/claude-hud/ (VENDORED.md re-vendor rule, scripts/statusline/check-hud-drift.sh --write).
- Done when: check-plugin-drift.sh shows claude-hud CURRENT, upstream suite shows no net-new failures vs pristine v0.10.0, scripts/context-fill.sh suite green, plugin version bumped.
- marketplace/plugins/claude-hud/VENDORED.md:17: pinned_commit 5621429b8...  # v0.11.3; line 75 records the re-vendor to v0.11.3, lines 85 and 93 the earlier v0.11.2 and v0.11.1 re-vendors (HIMMEL-5505, HIMMEL-5440).
- Not re-run here: scripts/check-plugin-drift.sh CURRENT and the upstream suite (network and VM needed). Reopen if the nightly drift check reports claude-hud BEHIND.
