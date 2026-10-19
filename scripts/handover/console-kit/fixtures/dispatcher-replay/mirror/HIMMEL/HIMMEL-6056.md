---
key: "HIMMEL-6056"
type: "Task"
status: "In Progress"
statusCategory: "In Progress"
priority: "Medium"
labels: ["blocked","operator-directed","ps3-blocker","sector2-quality"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6212"
created: "2026-10-17T03:27:32.923+0200"
updated: "2026-10-19T17:29:05.157+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6056: File upstream graphify issue: print semantic rationale in query and explain output

## Description

Installed graphify 0.9.91. NODE builder around serve.py lines 1193-1225 (_subgraph_to_text); explain around cli.py lines 2139-2175. Fixture and workaround: scripts/graphify/fixtures/rationale-graph.json, scripts/graphify/append-rationale.py, test row file scripts/graphify/test-leg-graph-rationale.sh
Fold-in from HIMMEL-6141 (PR #3029, merged as eaef7bccf5f4264983046a182fc8309e5e2a8a0b), scripts/graphify/rank-why-how.py. Both items fail safe and are LOW:
