---
key: "HIMMEL-1620"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["needs-standard","theme-sessions-console-locks","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6168"
created: "2026-08-07T02:10:14.528+0200"
updated: "2026-10-17T18:04:58.239+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: ["HIMMEL-1158"]
  relates: []
---

# HIMMEL-1620: Session-end orphan reaper for MCP/LSP children + worker-lane MCP trim evaluation

## Description

Slice 1 shipped in PR 2873: scripts/cleanup/reap-mcp-orphans.sh (report-only by default, --kill arms it) plus its suite. Ticket stays open. Remaining slices:
PR 2873 merged as 872a5b974e1f7ac19930fa2f497c98884787dc25 (slice 1: scripts/cleanup/reap-mcp-orphans.sh, report-only by default, plus its suite and a docs/cadences.md row). This ticket stays open for the deferred slices: the SessionEnd hook and daily sweep wiring after a one-week soak, the pidfd PI
