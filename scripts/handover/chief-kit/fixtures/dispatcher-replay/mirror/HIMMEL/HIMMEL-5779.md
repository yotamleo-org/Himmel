---
key: "HIMMEL-5779"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6217"
created: "2026-10-15T16:01:26.608+0200"
updated: "2026-10-19T10:04:29.861+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5779: Repair comment damage left by the HIMMEL-5629 prune (ponytail tickets, broken prose)

## Description

The ponytail convention (docs/internals/ponytail-convention.md) requires every ponytail: marker to name its ticket or trigger. The prune removed the ticket from continuation lines of these blocks:
- scripts/handover/merge-on-green.sh: the "out of this leg's scope" block lost HIMMEL-3437; the plugin-bump block lost HIMMEL-1105/5203
- scripts/cr/clear-cr-marker.sh: the sweep block lost HIMMEL-5364
- scripts/cr/anchor-handoff.sh: the "tracked as a follow-up" block
- scripts/cr/clear-cr-marker.sh:473: "the comment-only branch of / is NOT used here" (PR 2710 panel codex-1; fix: "of the tip check")
- scripts/lib (PR 2707, judge j2707a): claude-headless.sh:23, 534; bank-preflight.sh:2, 514, 836, 846; cr-merge-gate.sh:10, 62, 267; cr-available.sh:17, 29, 68; cr-signal.sh:33-34; ci-green-gate.sh:20; test-bank-attribution.sh:162, 256; test-bank-preflight-admit-gate.sh:123, 137; test-bank-preflight
