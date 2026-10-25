---
key: "HIMMEL-6109"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["ci","shellcheck"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-5654"
created: "2026-10-17T14:30:12.950+0200"
updated: "2026-10-19T03:18:39.043+0200"
resolution: "Done"
resolved: "2026-10-19T03:18:39.023+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6109: shellcheck PR-range falls back to a full serial sweep for any merge-on-green.sh neighbour and hits the 25 min lint cap

## Description

scripts/ci/shellcheck-pr-range.sh runs every tracked file when a changed file or neighbour has a source line that does not name a *.sh. merge-on-green.sh has two such lines: a real dynamic source at ~276 (. "$_csg_lib") and a false positive at ~442 (a jq filter containing . else, matched by the sour
1. scripts/handover/merge-on-green.sh ~276: give the dynamic source a # shellcheck source=<path> directive, and teach the range script to accept a dynamic source line that carries such a directive on the line above.
2. scripts/ci/shellcheck-pr-range.sh: do not count . inside a quoted string (the jq false positive) as a source line, e.g. require the ./source token at command position outside quotes, or skip lines whose match is inside a --jq '…' argument.
Trust path (scripts/ci/, possibly .github/workflows/ci.yml): adversarial judge before GO. src_re at shellcheck-pr-range.sh:68, the dynamic check at :92. Reporter: N2513 on PR 2997 (HIMMEL-6088).
1. The shard subshell in scripts/ci/shellcheck-pr-range.sh (~:91) has no pipefail. If tr died partway, xargs would lint a subset and record rc 0. This is a fail-open path, unlikely and pre-existing. Add set -o pipefail in the shard, or check the count per shard.
- DoD 1 (dry-run on a range touching merge-on-green.sh lists a bounded set): scripts/handover/merge-on-green.sh:274 now carries # shellcheck source=scripts/lib/chokepoint-seam-guard.sh; scripts/ci/shellcheck-pr-range.sh accepts a # shellcheck source= directive as a static edge (lines 21, 32, 78, 195
