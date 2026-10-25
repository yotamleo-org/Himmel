---
key: "HIMMEL-3832"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["needs-standard","post-v1-hf","theme-ship-loop-gates"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6174"
created: "2026-09-29T02:34:48.546+0200"
updated: "2026-10-19T03:18:40.605+0200"
resolution: "Done"
resolved: "2026-10-19T03:18:40.581+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6252"]
---

# HIMMEL-3832: Enforce the judge on guard-grade PRs structurally

## Description

Guard, hook and permission PRs need an independent judge GO, but only the console decides the grade and nothing gates it. go.sh should refuse a PR that touches the guard paths (scripts/hooks, scripts/cr, merge-on-green, console-kit gates, settings) unless a judge verdict file for that exact head exi
go.sh --trust-reviewed <qid> <pr> <head> now refuses with exit 5 unless a verdict file under <root>/<user>/<bucket>/verdicts/<qid>/ says GO for that exact head. An unparsed file or a NO-GO fails closed. merge-on-green already refuses a PR that touches a path in scripts/ci/ci-trust-paths.txt unless i
Not yet covered by this ticket's full ask: ci-trust-paths.txt lists only some of the guard paths. All of scripts/hooks/ (only scripts/hooks/lib/ and check-commit-msg.sh are listed), all of scripts/cr/ (only impacted-*, anchor-handoff.sh and clear-cr-marker.sh are listed) and the console-kit gates ot
- Coverage: 159 guard files in scripts/hooks, scripts/cr, scripts/handover/console-kit, .claude; 10 covered, 149 merge on a plain GO today (row per file in the doc).
- Slice 1: PR 1929 (2e860b6e3): go.sh --trust-reviewed exits 5 without a GO verdict file for the exact head; merge-on-green.sh requires a trust-reviewed GO for any path in scripts/ci/ci-trust-paths.txt.
- Slice 2 (extend ci-trust-paths.txt, one list, decision Q50): research doc specs/research/HIMMEL-3832-guard-path-coverage-audit-2026-10-17.md (159 guard files, 10 covered). Code slice HIMMEL-6252 is Done; scripts/ci/ci-trust-paths.txt on main now lists ^scripts/hooks/(block|guard|cadence-deny)-, fu
