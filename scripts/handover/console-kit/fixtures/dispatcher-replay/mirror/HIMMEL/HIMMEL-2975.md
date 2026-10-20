---
key: "HIMMEL-2975"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["theme-bank-ci-cost","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-2763"
created: "2026-09-12T20:23:46.924+0200"
updated: "2026-10-19T10:05:05.661+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-2980","relates to HIMMEL-3976"]
---

# HIMMEL-2975: Console split: Sonnet/Haiku relay session + on-demand Fable judge under lean profiles (79 % of console wakes are machine events)

## Description

1. Relay — a Sonnet (or Haiku) session under a new console-relay profile in scripts/lanes/plugin-profiles.json (mcpServers: [], minimal plugins, no graphify/obsidian/context7 — all user-level servers in ~/.claude.json). It owns the monitors, the leg-doc polling, inbox-send.sh delivery, tick.sh, the
- docs/handover/running-a-console.md + the console doc template: the relay-vs-judge contract (who holds the lock, who issues GO, how the relay escalates — a JUDGE bullet + Agent spawn with a full brief, never a bare message), and the RETASK nonce ownership (judge-issued).
- Measure before/after with the same jq accounting (extract.sh / cost.awk in the 03Y scratchpad — copy them into scripts/lanes/bench/ as the repeatable recipe).
Task 26 (Guard D: scripts/hooks/guard-relay-writes.sh) shipped: PR #753 merged as a3b131f91b07373fe4c09e3a5280f3c0de015aab. Frozen-seam CR findings (guarded-prefix canonicalization, env -i identity-var-clearing bypass, unanchored write-verb substrings) are ledger-deferred to this ticket for a follow
  leg-brief template, docs/handover/running-a-console.md and the console doc   template should use these seven terms and no synonyms. A lexicon that lives   only in a Jira comment is how "communicator", "relay" and "orchestrator" came   to mean three overlapping things in the first place.
PR #799 (yotamleo/Himmel) merged @ 941b441acbc2477da0f623603bf55fe9dca96a73. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
