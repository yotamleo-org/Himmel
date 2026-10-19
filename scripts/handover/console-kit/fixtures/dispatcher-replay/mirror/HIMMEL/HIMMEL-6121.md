---
key: "HIMMEL-6121"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["ci","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-5654"
created: "2026-10-17T15:38:09.356+0200"
updated: "2026-10-18T01:21:24.403+0200"
resolution: "Done"
resolved: "2026-10-18T01:02:04.153+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6121: CI: on pull_request the first failed job cancels the whole run

## Description

Files: .github/workflows/ci.yml (trust path: adversarial judge + trust-reviewed GO). Collides with PR 2990 (ci.yml): start after it merges. Related: HIMMEL-5057 (stop a shard at its first failing suite).
PR #3026 (yotamleo/Himmel) merged @ 24c8015d4f485618f05815753b099e98136ea2d9. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
Finding [Suggestion]: in .github/workflows/ci.yml:178, fork pull requests normally get a read-only GITHUB_TOKEN even when the workflow declares actions: write. Cancellation then fails, and the watcher exits after its first attempt. Either document this limitation or provide a trusted cancellation pa
