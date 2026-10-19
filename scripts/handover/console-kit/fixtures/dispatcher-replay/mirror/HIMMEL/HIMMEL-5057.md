---
key: "HIMMEL-5057"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["needs-standard","theme-bank-ci-cost","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-5654"
created: "2026-10-09T01:42:24.167+0200"
updated: "2026-10-19T16:48:10.077+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5057: CI: stop a shell-unit shard at its first failing suite on pull_request (after #2177)

## Description

A RED row (Case 26a and 26c in scripts/ci/test-run-shell-tests.sh) failing before the change, with Case 26b as the negative control, shown green after.
Files: scripts/ci/run-shell-tests.sh, scripts/ci/test-run-shell-tests.sh, .github/workflows/ci.yml. Both code files are ci-trust-paths, so the trust judge applies.
