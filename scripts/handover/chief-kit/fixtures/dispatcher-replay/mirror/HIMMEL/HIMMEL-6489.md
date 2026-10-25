---
key: "HIMMEL-6489"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["residual-depth-1","security","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T17:16:30.346+0200"
updated: "2026-10-19T17:33:30.336+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6489: CR pr-create hook: parse stacked and attached gh short flags for the head branch

## Description

1. In scripts/hooks/check-cr-marker-on-pr-create.sh head parsing (~344-357), for any single-dash token containing H take the text after the first H with a leading '=' stripped, else the next token; keep --head= and --head forms.
Files: scripts/hooks/check-cr-marker-on-pr-create.sh, its test suite (grep scripts/hooks/test-cr-marker). Trust path: hooks are in ci-trust-paths.txt, needs adversarial review. Parent finding: HIMMEL-2053 (N2702, verdict jS2053d). Editing scripts/hooks/*.sh in a leg trips the hook-integrity guard: l
