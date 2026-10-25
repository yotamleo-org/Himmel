---
key: "HIMMEL-2053"
type: "Task"
status: "In Progress"
statusCategory: "In Progress"
priority: "Medium"
labels: ["must-v1.1.3","needs-standard","operator-directed","theme-ship-loop-gates","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-414"
created: "2026-08-23T04:39:33.781+0200"
updated: "2026-10-19T03:34:40.746+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-2053: Hermes lane bypasses himmel's CR gates — no cross-family review enforcement, no hook parity

## Description

   (.codex/hooks.json parity exists for Codex, nothing for hermes), so an    agent pushing from a hermes session bypasses every gate the Claude lane    honors.
   for git pushes from hermes sessions (mirror of .codex/hooks.json parity,    HIMMEL-1981 pattern).
