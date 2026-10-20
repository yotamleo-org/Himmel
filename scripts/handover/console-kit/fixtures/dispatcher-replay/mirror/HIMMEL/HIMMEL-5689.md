---
key: "HIMMEL-5689"
type: "Task"
status: "In Progress"
statusCategory: "In Progress"
priority: "Medium"
labels: ["ps3-blocker"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6217"
created: "2026-10-14T23:24:34.616+0200"
updated: "2026-10-17T18:12:15.681+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-5729","HIMMEL-5701"]
  blocked_by: ["HIMMEL-5629","HIMMEL-5508","HIMMEL-5691"]
  relates: []
---

# HIMMEL-5689: Rename the code-side jargon to the plain names, with read-both aliases

## Description

Inventory check: for each old name in the docs/glossary.md alias tables, git grep lists the code hits, and the inventory table has one row per hit. Fails today: no table exists. Scope for the slice: docs/glossary.md, scripts/handover/console-kit, scripts/hooks. Each rename family then gets its own a
Sizing: Plan-first slice S: the identifier inventory. The rename PRs are not sized until the inventory lands, so the version figure is a floor for this ticket. Open question for the supervisor session: docs/glossary.md says repo identifiers (ids, env vars, file names, flags, command names) are never
Operator ruling, 2026-10-15 (supervisor session AM): GO. The rename supersedes the docs/glossary.md rule that repo identifiers are never renamed, so this PR removes that rule. Dispatch only when the fleet is quiet, because the rename touches nearly every file.
Step 1 (inventory) merged: PR #2726, merge sha 3216b410b004c673ca31bc2d3a4a981288dac785. Doc: docs/internals/identifier-rename-inventory.md. 15 families, 9 rename PRs (P0-P8); P0-P5 can start now, P6 waits on 5629, P7 on 5508, P8 on 5691. New names other than chief are PROPOSED pending operator ruli
P0 merged: PR 2885, squash d9694b0905f21f5963f6111bd11727e62c9d21bb. Adds scripts/lib/env-alias.sh (alias_env, env_alias_any), its 18-row test, and the glossary alias table. Renames nothing in code; HIMMEL-5689 stays open for P1-P8.
PR 3000 merged: docs/internals/identifier-rename-proposal.md is the per-name rename table (52 rows: whole-repo hit counts, proposed new name, alias plan, risk, do-not-rename list, Freeze section, approve / change / drop decision list, re-run recipe). It awaits operator approval. No code rename happe
