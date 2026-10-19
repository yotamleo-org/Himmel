---
key: "HIMMEL-6479"
type: "Task"
status: "In Review"
statusCategory: "In Progress"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T16:23:10.058+0200"
updated: "2026-10-19T16:54:36.954+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6479: A worker on a branch behind main has no merge-on-green spelling that the guard and classifier both accept

## Description

Seen twice on 10-19 (console R). The relative spelling is refused by guard-pr-check-literal because the worktree's copy of merge-on-green.sh differs from the anchor (main moved on). The absolute spelling and the anchored spelling (the HIMMEL_REPO variable form in .claude/settings.json:61) are denied
1. Investigate why the anchored allow rule in .claude/settings.json does not stop the classifier, and record the finding.
3. Update the leg brief Ship step (docs/handover/leg-brief-template.md, gen-briefs.py) to name the one spelling that works.
Files: scripts/hooks/guard-pr-check-literal.sh, scripts/handover/merge-on-green.sh, .claude/settings.json (allow rules, operator-reviewed), scripts/handover/console-kit/gen-briefs.py, docs/handover/leg-brief-template.md. Evidence: console R Results 10-19 16:1x-16:2x; N2715 doc 13:09 BLOCKED bullets.
