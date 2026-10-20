---
key: "HIMMEL-6118"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6157"
created: "2026-10-17T15:30:17.972+0200"
updated: "2026-10-18T02:42:26.154+0200"
resolution: "Done"
resolved: "2026-10-17T17:40:04.241+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6118: A leg window whose session died stays open unnoticed for hours: tick reports deadwin and closes it

## Description

Files: scripts/handover/console-kit/tick.sh, close-wrapped-leg.sh, headed-arm-leg.sh and suites. Evidence: journalctl 2026-10-16 16:10:34 systemd-oomd; leg transcript 9146011b-6540-4ecc-a7e2-7f61d11734ec ends mid-Bash at 14:10Z.
PR #3015 (yotamleo/Himmel) merged @ 25bf428a876ee480ad706fa4913a272601a6dda2. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
