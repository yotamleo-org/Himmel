---
key: "HIMMEL-5276"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["guards","security","theme-guard-safety"]
fixVersions: []
parent: "HIMMEL-6182"
created: "2026-10-11T20:04:57.488+0200"
updated: "2026-10-17T18:13:01.003+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: ["HIMMEL-5720"]
  relates: ["relates to HIMMEL-5720","relates to HIMMEL-5720"]
---

# HIMMEL-5276: Guard gap G3: the Codex lane hook chain covers 7 hooks and has no deny list

## Description

Port the permissions.deny equivalents and the missing Bash guards (edit-live-settings, write-into-main-checkout, git-stash, and the others on the Claude chain) into the Codex lane .codex/hooks.json. Move the deny list into one shared hook wired into both chains, and add a parity test that diffs the
- Fix sketch: move the L1 deny list into a shared hook (block-deny-list.sh); wire it in both chains from one inventory; add a parity test diffing the Bash hook sets of .claude/settings.json and .codex/hooks.json.
- Hook files touched: .codex/hooks.json; .claude/settings.json; new scripts/hooks/block-deny-list.sh; the parity test.
