---
key: "HIMMEL-5377"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["config","needs-standard","security","theme-config-ui-himmelctl","unscheduled"]
fixVersions: []
parent: "HIMMEL-6183"
created: "2026-10-12T15:05:37.365+0200"
updated: "2026-10-17T18:13:37.689+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-5376"]
  blocked_by: []
  relates: []
---

# HIMMEL-5377: config: commit-message gate reads TICKET_ID_REQUIRED and TICKET_ID_EXEMPT_AUTHORS as env-proof policy

## Description

Move TICKETIDREQUIRED and TICKETIDEXEMPTAUTHORS to the policy class in `himmelkeyclass (scripts/lib/load-config.sh). Read them in check-commit-msg.sh through loadpolicy`, which ignores the process env. Keep the .ps1 twin in lockstep. TICKETID_PATTERN can stay behaviour config, because a narrower pat
- Files: scripts/hooks/check-commit-msg.sh + .ps1 twin, scripts/lib/load-config.sh, scripts/hooks/test-check-commit-msg*.sh, docs/internals/config-layers.md "Which keys go where".
