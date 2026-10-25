---
key: "HIMMEL-6045"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","sector2-knowledge"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6176"
created: "2026-10-17T02:56:45.827+0200"
updated: "2026-10-19T10:05:39.386+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-1684"]
---

# HIMMEL-6045: .coderabbit.yaml learnings re-home per the HIMMEL-4109 audit, plus the dashboard prune list for 169 stale learning rows

## Description

- Lines 36–45: explicit knowledge_base.learnings.scope: local, approval_delay: 3, and knowledge_base.code_guidelines.filePatterns containing CLAUDE.md, scripts/handover/CLAUDE.md, and docs/internals/ponytail-convention.md. Scope was not changed to global.
- Lines 159–173: the misleading shell-lint gate claim was reworded to name scripts/lint/shell-lint.sh as advisory. This satisfies the ticket's permitted interim rewording; no new lint or CI change is claimed here.
