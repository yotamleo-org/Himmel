---
key: "HIMMEL-5512"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["cost-reduction","operator-directed","theme-bank-ci-cost","unscheduled"]
fixVersions: ["v1.1.4"]
parent: "HIMMEL-6214"
created: "2026-10-13T14:39:24.897+0200"
updated: "2026-10-19T10:04:26.965+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5512: Lean steering: run the lean-CLAUDE.md bench, trim CLAUDE.md toward 6KB, compound MEMORY.md under 4KB

## Description

# HIMMEL-5512: Lean steering: run the lean-CLAUDE.md bench, trim CLAUDE.md toward 6KB, compound MEMORY.md under 4KB
Every session loads the repo CLAUDE.md (12.5KB) and the MEMORY.md index (10.4KB). The lean-CLAUDE.md benchmark that would prove a smaller file works was never run.
Run the lean-CLAUDE.md benchmark. If it holds, cut CLAUDE.md toward 6KB by moving workflow detail into the subdirectory CLAUDE.md files and docs. Separately, compound MEMORY.md down to under 4KB of pointers with the memory-compound skill.
- Benchmark first: POC before build. CLAUDE.md is frame-shaping, so every removed rule must keep its named enforcer or doc.
PR #3125 merged as 8330d33ef7d7156bd84fd3d8c4f67405f723bdc6 (head 867b2983f503401e4515acf71da87f08de01bd62). Bench run (sonnet-5-5, N=3), CLAUDE.md 10,427 B to 5,989 B, budget gate 6,144 B. The MEMORY.md compound is still open, so the ticket stays In Progress.
HIMMEL-6440 triage 2026-10-19: back to To Do. CLAUDE.md trim and bench shipped (PR 3125); residual is the MEMORY.md compound under 4KB (operator reviews the memory-compound output).
