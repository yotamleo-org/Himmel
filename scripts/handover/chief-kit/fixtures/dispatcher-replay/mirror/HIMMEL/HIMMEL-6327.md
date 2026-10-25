---
key: "HIMMEL-6327"
type: "Bug"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T04:34:42.338+0200"
updated: "2026-10-18T17:09:52.741+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6362"]
---

# HIMMEL-6327: Adopter commit gate ignores TICKET_ID_REQUIRED=0 in the project .env (load-dotenv.sh not copied), and the Linux wizard points at a Windows doc

## Description

In an adopter project, check-commit-msg.sh sources scripts/lib/load-dotenv.sh, which adopt.sh does not copy (not in PORTABLE_FILES, not in the hook payload), so .env is never read. The same variable set in the environment works. Repro: specs/research/HIMMEL-6284-docs-v4/repro-dotenv.sh in the state
1. Copy scripts/lib/load-dotenv.sh with the gate (PORTABLE_FILES and the hook payload), or have check-commit-msg.sh read .env itself.
Files: scripts/adopt.sh (PORTABLE_FILES, hook payload), scripts/hooks/check-commit-msg.sh, the wizard text, and their suites.
