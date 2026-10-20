---
key: "HIMMEL-2035"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["sector2-deployment"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6179"
created: "2026-08-22T23:18:30.771+0200"
updated: "2026-10-18T20:12:04.404+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-2035: CR ledger + pre-push marker for repos OUTSIDE the himmel checkout — adopters' repos and upstream-PR clones get the same structural CR evidence (ledger at target .git, /pr-check --worktree external, marker hook install, pr-create gate)

## Description

h2. Why (2026-08-22) Today the CR ledger + pre-push marker gate (scripts/cr/ledger-append.sh, clear-cr-marker.sh, check-cr-marker-on-pr-create.sh, the /pr-check runbook) only work for branches inside the himmel checkout: the ledger lives in the checkout's .git (git-common-dir), /pr-check computes ma
Pre-push marker hook: install into the target repo on demand (scripts/setup-hooks.sh --target <path> or a himmelctl hooks install <path>), idempotent, removable.
Docs: one section in docs/internals/enforcement.md "CR gate outside the himmel checkout (adopters + upstream PRs)"; harness-compat note.
