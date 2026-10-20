---
key: "HIMMEL-1056"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Low"
labels: ["needs-standard","phase-0","security","tech-debt","theme-ship-loop-gates","unscheduled"]
fixVersions: []
parent: "HIMMEL-6177"
created: "2026-07-16T03:34:58.187+0200"
updated: "2026-10-17T18:09:44.787+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: ["HIMMEL-1530"]
  relates: ["relates to HIMMEL-1042"]
---

# HIMMEL-1056: Harden armed-chain auto-merge gate against self-adversarial agent (HIMMEL-1042 codex-adv-1)

## Description

Problem: scripts/handover/merge-on-green.sh and its gate scripts/check-ci.sh live in the agent-writable feature worktree. The standing allow-rule Bash(bash scripts/handover/merge-on-green.sh:*) runs whatever is on disk, and the wrapper's inner gh pr merge bypasses the PreToolUse merge guard by desig
Independently corroborated by CodeRabbit on the HIMMEL-1042 PR (#1236), CR round 4 — raised as a critical against scripts/handover/merge-on-green.sh:10-12:
1. Immutable launcher (Critical) — the dimension this ticket already has, now independently raised a THIRD time. "The standing allow-rule trusts code that the armed chain can rewrite. Authorize an immutable or externally verified launcher rather than the active worktree copy." Also asks that check-c
2. NEW — the gate is repository-bound but not BASE-BRANCH-bound (Major, quick win). merge-on-green.sh gates on: ARMAUTOMERGE + the PR's own repo being private + the PR being in the cwd repo + check-ci green + --match-head-commit. It never inspects baseRefName. So it will merge ANY open PR in that pr
