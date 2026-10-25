---
key: "HIMMEL-5941"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6174"
created: "2026-10-16T19:05:43.644+0200"
updated: "2026-10-19T16:28:53.970+0200"
resolution: "Done"
resolved: "2026-10-19T16:28:53.946+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5941: go.sh writes an ordinary GO for a PR that touches a CI trust path (scripts/lib/), refusal only comes at merge

## Description

# HIMMEL-5941: go.sh writes an ordinary GO for a PR that touches a CI trust path (scripts/lib/), refusal only comes at merge
Make console-kit/go.sh refuse (exit 21, as documented) an ordinary GO for any PR whose diff matches scripts/ci/ci-trust-paths.txt, so the refusal happens when the GO is written, not at merge.
2026-10-16 18:3x: go.sh 2837 aae972cc wrote an ordinary GO although PR 2837 changes scripts/lib/qmd-bin.sh (pattern ^scripts/lib/). merge-on-green then refused with reason=trust-path phase=go. The console template says an ordinary GO on a trust-path PR exits 21.
- Repro: a PR touching only scripts/lib/<x>.sh plus docs; run go.sh without --trust-reviewed; expect exit 21, today it writes the GO file.
Verify-close (console R, 10-19): already fixed by 78ef532f1, HIMMEL-6033 / PR 2910 (merged 2026-10-17 06:41, after this ticket's 10-16 repro). go.sh now refuses an ordinary GO on a trust path at GO time (exit 21), and test-go.sh carries the 2837 shape (scripts/lib/ paths, test-go.sh:574-581). The 60
