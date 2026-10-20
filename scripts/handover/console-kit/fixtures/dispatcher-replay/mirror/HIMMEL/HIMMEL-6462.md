---
key: "HIMMEL-6462"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["residual-depth-1","security","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T11:45:26.158+0200"
updated: "2026-10-19T11:45:44.915+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6462: CR ledger: ready-check row 4 requires a critic row; review-round ignores refs/replace

## Description

1. scripts/cr/review-round.sh: export GIT_NO_REPLACE_OBJECTS=1, as clear-cr-marker.sh:154 already does, so refs/replace cannot fake a tests-only tree.
2. scripts/handover/console-kit/ready-check.sh:287: row 4 requires a critic avail row, or an evidence/judge-go row tied to the branch. Today it accepts any ok row, whatever its kind or model.
3. scripts/cr/test-pr-check-rounds.sh: add a .head holding a ref name or a short sha that resolves, a symlinked .head, and a clear-cr-marker fallback that engages when the tip has only an evidence row (the fix-3 RED row).
5. Policy question for the console: add scripts/guardrails/test-*.sh and scripts/hooks/test-*.sh to scripts/ci/ci-trust-paths.txt, so tests-only evidence cannot gut a guard's RED suite with no judge.
Trust paths: scripts/cr/*, ready-check.sh. Every PR here needs a trust judge. Related: HIMMEL-5233, HIMMEL-6413, HIMMEL-6414.
