---
key: "HIMMEL-5891"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "High"
labels: ["operator-directed","ps3-blocker"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6213"
created: "2026-10-16T15:54:26.601+0200"
updated: "2026-10-17T22:49:55.002+0200"
resolution: "Done"
resolved: "2026-10-17T22:49:54.983+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-5909"]
---

# HIMMEL-5891: qmd daemon: bursts of queries time out past the 120 s client limit

## Description

- bash scripts/lib/qmd-key-probe.sh: rc 0 (key present, no 401)
Closing burst run on the post-5961 pin (fork 44fd0609), 2026-10-17 15:23 CEST, scripts/eval/qmd-quality/qmd-burst-proof.sh from PR 3004. The daemon on :8181 (pid 17325) was restarted at 15:15, after the dist build at 01:05, so it runs the pin. 10 parallel vec queries, rerank off, limit 1, default sc
PR #3004 (yotamleo/Himmel) merged @ 0dc081f56df3202e7352cb0cbc2e4e3148c54413. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
