---
key: "HIMMEL-6142"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Highest"
labels: ["knowledge-critical","must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6212"
created: "2026-10-17T16:37:33.415+0200"
updated: "2026-10-18T01:46:06.980+0200"
resolution: "Done"
resolved: "2026-10-18T01:45:53.208+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6142: K6: delivery as a token-capped repo map injected at session start

## Description

PR #3034 (yotamleo/Himmel) merged @ afe6a368833e13728cf8b3e20510eecbfa00c328. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
- New scripts/graphify/repo-map.py builds a PageRank repo map from graph.json, capped at 2000 tokens by default.
