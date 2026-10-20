# HIMMEL-6443-N2778-claudex-probe-chunk-script-2026-10-19.md

> **Scope / do not:** writes confined to RED first: a test that runs the script for k=0 and k=last and checks chunk size (100000 bytes except the last), determinism (same bytes twice), that concatenating all chunks equals the reference pipeline's output, and that a k past the end exits non-zero with a message. Then the script (read-only, no network, set -euo pipefail). Update HIMMEL-1907-probe-brief.md in the bucket to call it (that file is outside the repo; edit it in place). Do NOT re-run the claudex probe itself: report READY and the console schedules the re-run. Run the new test plus impacted suites (bash scripts/cr/impacted-suites.sh), a verdict per suite. completes-ticket: yes. Other live legs and their files: N2777 (five containment gaps closed, one RED row each). Stay off those. No settings, CI workflows, SKIP_CR, --no-verify, amend, force-push, bisect or old-commit checkout; READ ONLY `scripts/hooks/lib/` and anything in `scripts/ci/ci-trust-paths.txt` unless the ticket requires it (then ask the console first). Remove any fixture you create under the real HOME before you wrap.

## Results

- 15:22 FINDING CI home-canary (7) red on PR 3197 at 69d3390c: read-sink check f
- 15:56 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19R-roadmap-console replaces
- 17:12 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19S-roadmap-console replaces
- 17:42 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19T-roadmap-console replaces
