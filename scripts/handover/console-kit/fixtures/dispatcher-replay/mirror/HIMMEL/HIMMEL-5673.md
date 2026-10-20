---
key: "HIMMEL-5673"
type: "Task"
status: "In Progress"
statusCategory: "In Progress"
priority: "Medium"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6213"
created: "2026-10-14T20:51:46.129+0200"
updated: "2026-10-19T16:32:07.748+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-5683"]
---

# HIMMEL-5673: qmd fork: Jina remote backend for rerank and embedding (selectable per role), and stop exitIfRerankHung restarting on every hang

## Description

Egress: content egress needs an explicit row in scripts/guardrails/egress-matrix.json (provider jina, purposes embedding and rerank, corpora luna and himmel, salus stays denied). That row ships in a separate himmel PR.
