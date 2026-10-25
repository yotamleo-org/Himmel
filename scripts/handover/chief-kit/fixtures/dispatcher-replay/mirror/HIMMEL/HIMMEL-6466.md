---
key: "HIMMEL-6466"
type: "Task"
status: "In Progress"
statusCategory: "In Progress"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T13:46:10.240+0200"
updated: "2026-10-19T17:26:56.873+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-5747"]
---

# HIMMEL-6466: write guard: batch the per-target git forks in guardrails/lib.sh

## Description

1. Profile a 20 KB redirect-clause command and list the repeated lookups in scripts/guardrails/lib.sh (branch, isonmain, maincheckout_verdict).
- bash scripts/hooks/test-block-write-into-main-checkout-forms.sh passes with the redirect-clause row bounded at 1 s.
Follow-up to HIMMEL-5747 (link: relates). Files: scripts/guardrails/lib.sh, scripts/hooks/block-write-into-main-checkout.sh, scripts/hooks/test-block-write-into-main-checkout-forms.sh. lib.sh is a trust-path-adjacent shared library: every guard sources it, so the verdict fuzz against the old copy mu
