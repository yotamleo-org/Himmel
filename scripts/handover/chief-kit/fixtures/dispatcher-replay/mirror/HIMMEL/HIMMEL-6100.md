---
key: "HIMMEL-6100"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["judge-residual"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-17T11:45:54.241+0200"
updated: "2026-10-18T02:42:24.890+0200"
resolution: "Done"
resolved: "2026-10-17T18:10:43.102+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6100: check-plugin-drift: git rename detection lets a renamed or symlink-swapped plugin skip the version-bump gate

## Description

1. scripts/check-plugin-drift.sh: add --no-renames to both git diff --name-only calls (~l.204 and ~l.221).
2. scripts/test-check-plugin-drift.sh: RED rows first for (a) git mv marketplace/plugins/foo marketplace/plugins/bar with a small edit, marketplace entry still named foo; (b) case-only rename foo to Foo; (c) foo replaced by a symlink to an edited copy at marketplace/plugins/foo-copy. Each must fail
- bash scripts/test-check-plugin-drift.sh passes.
Files: scripts/check-plugin-drift.sh, scripts/test-check-plugin-drift.sh only. Trust path: adversarial judge and trust-reviewed GO. Also collides with HIMMEL-6086 (same files): do them in sequence, not in parallel. Suites: scripts/test-check-plugin-drift.sh, scripts/test-himmel-update-plugin-update.
PR #2995 (yotamleo/Himmel) merged @ 257b0f1407095c42e87e9e9905c1715f34ee5c2e. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
