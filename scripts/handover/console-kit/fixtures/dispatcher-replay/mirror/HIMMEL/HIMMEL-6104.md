---
key: "HIMMEL-6104"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["console-kit","succession"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-3744"
created: "2026-10-17T13:36:25.132+0200"
updated: "2026-10-17T23:41:38.053+0200"
resolution: "Done"
resolved: "2026-10-17T23:39:36.760+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6264"]
---

# HIMMEL-6104: Succession relay text should hand legs the exact SUCCESSION accepted bullet; improvised forms read as missing

## Description

1. scripts/handover/console-kit/relay-batch.sh: put the literal line SUCCESSION accepted: <successor> replaces <predecessor> in the relay text, with "nothing after it on that line".
2. Same literal in the leg-side succession section (docs/handover/leg-sections/succession.md) if it does not already state it.
Tracker regex: scripts/handover/console-kit/succession-tracker.sh:119-125 (requires end of line after the outgoing name). Observed non-matching bullets: 13:20 LIVE — SUCCESSION accepted: C replaces B (relay from B, C live in List…, 13:23 LIVE — SUCCESSION accepted: relay from B, token … unchanged, C
PR #3038 (yotamleo/Himmel) merged @ 267dca46489ca224b698410f429f5744f8c605a2. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
