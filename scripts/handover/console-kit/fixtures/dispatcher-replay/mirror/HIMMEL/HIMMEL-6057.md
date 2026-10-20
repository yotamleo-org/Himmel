---
key: "HIMMEL-6057"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6176"
created: "2026-10-17T03:28:14.313+0200"
updated: "2026-10-19T13:29:56.103+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6057: known-findings: refresh shipped evidence with the new attribution and widen the jq match

## Description

- Files: scripts/cr/known-findings.json (evidence fields; the match of jq-alternative-swallows-false, currently jq[^.\n]*//|alternative operator, skips any text with a period between jq and the double slash; try jq[^\n]{0,60}//|alternative operator).
- Done when: known-findings.sh --refresh output is committed and bash scripts/cr/test-known-findings.sh passes.
