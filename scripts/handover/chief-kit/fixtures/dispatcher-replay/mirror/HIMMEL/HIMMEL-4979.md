---
key: "HIMMEL-4979"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["ci","security","theme-bank-ci-cost","unscheduled"]
fixVersions: ["v1.1.4"]
parent: "HIMMEL-6180"
created: "2026-10-08T16:10:46.475+0200"
updated: "2026-10-19T10:05:59.033+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-4979: sandbox runner follow-ups: aggregator installs bubblewrap, close inherited fds, lint launch shapes (from j2177)

## Description

2. Inherited file descriptors reach the sandbox. scripts/lib/sandbox-run.sh lets a caller's open fd (fd 9 was writable inside). Current call sites pass only 0-2. Fix: close fds above 2 before exec (or pass bwrap the right flags), with a test row.
Items 2–4 are in progress on the sandbox-runner follow-up branch: inherited descriptor closure, sh/env launch lint coverage, and the two /tmp-checkout test rows. Item 1 (aggregator installs bubblewrap and treats missing confinement as failure) remains deferred until PR #3061, which owns .github/work
This is a partial delivery, not ticket completion. Item 1 (aggregator bubblewrap installation and hard failure when confinement is unavailable) remains deferred pending PR #3061 ownership of .github/workflows/ci.yml. HIMMEL-4979 remains In Progress.
