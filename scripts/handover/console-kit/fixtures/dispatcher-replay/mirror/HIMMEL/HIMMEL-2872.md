---
key: "HIMMEL-2872"
type: "Task"
status: "In Review"
statusCategory: "In Progress"
priority: "Medium"
labels: ["theme-ship-loop-gates","unscheduled"]
fixVersions: ["v1.1.4"]
parent: "HIMMEL-5654"
created: "2026-09-09T20:02:15.637+0200"
updated: "2026-10-19T17:03:20.509+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-3973"]
---

# HIMMEL-2872: CI: run Linux jobs in a prebuilt GHCR container image (rebuilt only on Dockerfile change) + shard the shell suite across runners

## Description

- Dockerfile under .github/ci-image/ (Ubuntu LTS base): at, git, jq, shellcheck, pre-commit, python3, node (pinned to the version .nvmrc/CI uses), bun (pinned), gh, and whatever else ci.yml's setup steps install today (read every run: step above the suite invocations and fold them in).
- A small workflow ci-image.yml: builds and pushes ghcr.io/yotamleo/himmel-ci:<sha> + :latest on push to main when .github/ci-image/** changes, plus a weekly schedule so base-image security updates land; GHCR is free for a public repo.
shell-unit (ubuntu-latest) runs 44–48 min and is the long pole on every PR; setup is ~1–2 min of that. Split scripts/ci/run-shell-tests.sh across a matrix (e.g. 4 shards by suite index or by duration ledger) with one aggregating job for the required-status-check contexts (branch protection names she
After HIMMEL-2871 (the immediate fix) and HIMMEL-2869 (armed merges back). Item 1 first, item 2 second; both are .github/ + scripts/ci/ only.
scripts/ci/run-shell-tests.sh gained --shard <i>/<n>, applied as the last filter in the execution loop — after SKIP_LIST/--skip-extra/tier/conditional/capability — so it partitions the final run list rather than raw discovery, and a host's skips cannot fall unevenly across shards. Round-robin on a s
.github/workflows/ci.yml: the working job is now shell-unit-shard (os matrix x shard: [1..8]); a new aggregating job keeps the name shell-unit with a single-value os matrix purely so the check-run context stays `shell-unit (ubuntu-latest)` byte-for-byte. That was the ticket's stated constraint and i
