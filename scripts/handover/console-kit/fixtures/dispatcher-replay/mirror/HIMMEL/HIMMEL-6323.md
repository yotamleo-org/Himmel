---
key: "HIMMEL-6323"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6217"
created: "2026-10-18T04:10:41.462+0200"
updated: "2026-10-19T10:06:16.032+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6323: Prune Jira ids from user-facing output (373 lines, 137 files) and the remaining history comments (286 lines), and gate new output ids

## Description

Adopters see internal Jira ids in what himmel prints. himmel-update alone shows about 16 of them ("==> probe-mode station tools (HIMMEL-4088)", "(HIMMEL-1032)", ...), so the tool reads like an internal build log. Ticket-citing comments are still spread through the source despite the HIMMEL-5629 prun
- User-facing output (echo/printf/console.log/print/die/warn) naming a HIMMEL id: 373 lines in 137 files. Top: scripts/handover/arm-resume.sh 33, headed-arm.sh 18, himmel-update.sh 16, machine-setup/uninstall-plugins.sh 14, cr/review-round.sh 13, ci/run-shell-tests.sh 12, check-ci.sh 11, cr/critic-p
- History comments naming a HIMMEL id: 286 lines in 67 files (scripts/hooks/block-edit-live-settings.sh alone carries the largest share).
1. Gate: extend scripts/lint/check-history-comments.sh (or a sibling) to refuse an ADDED user-facing output string that carries a Jira key (echo/printf/console.*/print/die/warn), with a ponytail: and a debug-only carve-out.
3. Slices B-D: output strings by directory (scripts/handover, scripts/cr, scripts/ci + rest), each slice disjoint from the files open PRs hold at dispatch time.
