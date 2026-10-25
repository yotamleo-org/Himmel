---
key: "HIMMEL-5592"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["console","cost","operator-directed","operator-gated","sector2-cost"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-14T02:35:41.791+0200"
updated: "2026-10-17T22:26:37.551+0200"
resolution: "Done"
resolved: "2026-10-17T22:26:37.535+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5592: console load: inventory recurring supervisor-session jobs, then a POC moving the top ones to scripts or a middle worker that escalates

## Description

Source: the 10 consoles of 2026-10-14 (AA..AJ), 2,313 deduped API requests, ~69M input-token-equivalent (input + cachecreation + 0.1 x cacheread). Script: scripts/eval/console-load-inventory.py --match 2026-10-14A (read-only, no model call). Each request is attributed to the action class of its own
- Cause 1: git grep wrap-merged|verdict-go hits only the scripts and their tests. docs/handover/console-template.md and docs/handover/running-a-console.md still teach the multi-step path; no console is told the one-shots exist.
- Cause 2: .claude/settings.json has an allow rule for close-wrapped-leg.sh (line 73) and none for wrap-merged.sh or verdict-go.sh, so a console that tries them hits a prompt or the classifier.
POC: scripts/handover/console-kit/leg-event.sh --doc <console doc> --fleet <manifest> <message-file|->. A script, not a model. It reads the first marker, finds the leg doc in the manifest by the N<k> label, and runs wrap-merged.sh (with --pr <n> for MERGED #<n>). Prints HANDLED wrap-merged <label> (
Tests: test-leg-event.sh 27 ok lines, ALL PASS (RED shown first with the script absent). Analysis: scripts/eval/console-load-inventory.py plus test-console-load-inventory.sh 7/7.
docs/handover/console-template.md and docs/handover/running-a-console.md now point consoles at leg-event.sh, wrap-merged.sh and verdict-go.sh as the default, with the hand sequence as fallback. Overlaps HIMMEL-5608 (template documents wrap-merged) and HIMMEL-5613 (template Merges section).
