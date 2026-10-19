---
key: "HIMMEL-6015"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "High"
labels: ["operator-directed","sector2-ship"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6181"
created: "2026-10-17T01:03:13.639+0200"
updated: "2026-10-18T13:14:55.513+0200"
resolution: "Done"
resolved: "2026-10-18T13:13:33.390+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6249","relates to HIMMEL-6274","relates to HIMMEL-6338"]
---

# HIMMEL-6015: feat(console-kit): himmel-gate <name> <args> as the single exec path for gate/ledger writers; guards match only that command position

## Description

- New scripts/handover/console-kit/himmel-gate.sh dispatcher, the single exec path for the registered gate and ledger writers.
PR #3050 (yotamleo/Himmel) merged @ d5d535bc593bfcfe0cf37662417e48a0a5a5b440. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
The tail-pipe and chokepoint-env-prefix guards now deny only direct execution outside himmel-gate, through the shared command-position logic in scripts/hooks/lib-cmdpos-clean.sh. The himmel-gate allow literal is in .claude/settings.json.
