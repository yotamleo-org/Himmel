---
key: "HIMMEL-5788"
type: "Bug"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6194"
created: "2026-10-15T17:51:17.866+0200"
updated: "2026-10-19T10:04:32.611+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5788: run-shell-tests --impacted over-wide on merge-forward branches starves the 3 shared suite slots

## Description

- Files: scripts/ci/run-shell-tests.sh (the --impacted range), the suite semaphore (scripts/lib/suite-semaphore.sh), tick.sh for the slot-age field.
- Trust path: scripts/ci/ is in ci-trust-paths, so the PR needs a trust judge.
Deferral from PR 2799 (HIMMEL-5779, merged): the stale comment in scripts/ci/run-shell-tests.sh around line 156 ("suite it did not reach, so the NEXT run") is still a half-finished sentence left by the prune. It was left untouched because this ticket holds that file. Please repair it as a complete w
PR 2932 merged: the --impacted merge-forward clamp in scripts/ci/run-shell-tests.sh now reads the rev-list merge count as a number and treats an empty or non-numeric answer as no merge-forward (range left as passed). New rows 24t (empty and garbage count) and 24u (shallow clone refuses with rc 2) in
