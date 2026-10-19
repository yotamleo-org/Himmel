---
key: "HIMMEL-6358"
type: "Bug"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T17:03:46.304+0200"
updated: "2026-10-18T18:56:50.697+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6358: Console relaunches an orphan PR only on green, so an orphan whose CI goes red has no owner

## Description

Files: scripts/handover/console-kit/tick.sh (unowned-prs section), its test suite, docs/handover/running-a-console.md. Contract: dispatch-owed fires only for an open PR with no live leg and at least one failed required check; pending or green orphans keep today's behaviour. Suites: test-tick plus wh
Folded in from the HIMMEL-6357 judge (jH3099, suggestion): docs/handover/leg-preface-claudex.md around line 55 says the BLOCKED ci-pending hold should "never wrap", but the bounded inbox hold it points to ends in WRAPPED at the 4h deadline. Reword it to "never wrap before the hold deadline" when thi
