---
key: "HIMMEL-5756"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "High"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6213"
created: "2026-10-15T04:09:06.171+0200"
updated: "2026-10-19T10:06:21.555+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-5712"]
  blocked_by: []
  relates: ["relates to HIMMEL-5942","relates to HIMMEL-5943"]
---

# HIMMEL-5756: qmd rollout: re-embed every non-salus index with the A/B winner, salus local-only, fleet access via the shared daemon

## Description

- 2. Salus stays on a SEPARATE local-only index and daemon. qmd refuses mixed embed models in one index, and salus is hard-denied for cloud providers (scripts/guardrails/egress-matrix.json).
Slice 1 done in PR 2725: scripts/guardrails/egress-matrix.json rows allow openrouter embedding and rerank for himmel-code, luna-personal, luna-clippings, operator-repos, jira-mirror, roadmap-plan and skill-index. Salus is HARD-denied for both purposes, placed ahead of every allow row. Test block 6e
- scripts/qmd/qmd-jina-gate.mjs, scripts/qmd/qmd-collection-corpus.json, scripts/qmd/test-qmd-jina-gate.sh: qmd enforcement is Jina-specific; check whether an openrouter equivalent is needed.
- scripts/qmd/ensure-qmd-daemon.ps1, register-qmd-daemon-logon.ps1 and their tests: daemon launch.
- scripts/lib/qmd-bin.sh, qmd-bounded.sh: open now that PR 2717 merged; merge main forward before touching them.
- docs/internals/egress-matrix.md: add to the openrouter bullet if rows change.
