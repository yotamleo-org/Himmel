---
key: "HIMMEL-1515"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["needs-standard","theme-sessions-console-locks","unscheduled"]
fixVersions: ["v1.1.4"]
parent: "HIMMEL-6157"
created: "2026-08-04T00:49:09.416+0200"
updated: "2026-10-17T18:23:21.399+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-1515: worker blocked-escalation channel + orchestrator-owned suite queue (workers starve silently on the machine-wide test lock)

## Description

ROOT CAUSE IS NOT PERMISSIONS (checked, and explicitly ruled out): bash scripts/* was already allow-listed, the workers invoked the runner fine. They queued behind scripts/ci/run-shell-tests.sh's MACHINE-WIDE ADVISORY LOCK, which is working exactly as designed -- its own header records why it exists
DEFECT 1 -- NO BLOCKED-ESCALATION CHANNEL (worker -> parent). A blocked worker has no way to say "I am blocked on X, advise" and get a decision. It just burns turns and dies with finished work uncommitted. Note the RETASK channel already covers parent->child revisions; the CHILD->PARENT direction is
- Child -> parent DOES NOT: scripts/telegram/spawn-claudex.ts's own header records it as deliberately deferred — "HIMMEL-1003 v1 scope: deferred — the grants/escalation channel (spawn-glm's ...)". So this was anticipated at design time and parked, not overlooked.
