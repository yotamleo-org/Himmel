# HIMMEL-6393-N2774-ci-atd-start-fails-loudly-2026-10-19.md

> **Scope / do not:** writes confined to RED first: a lint or test row that fails on the current `|| true` line, then the fixed step that ends in a check that atd is active (systemctl is-active --quiet atd, else echo a clear error and exit 1). Only the atd step changes in ci.yml. Run the new row plus every suite that references ci.yml (bash scripts/cr/impacted-suites.sh), a verdict per suite. ci.yml is a trust path: say TRUST-PATH in READY; the console runs an opus judge. completes-ticket: yes. Other live legs and their files: N2775 (mirror op writes resolved: (iso|null), RED row first, no live backfill), N2776 (search upstream, draft issue, console GO, file, record URL on 6056). Stay off those. No settings, CI workflows, SKIP_CR, --no-verify, amend, force-push, bisect or old-commit checkout; READ ONLY `scripts/hooks/lib/` and anything in `scripts/ci/ci-trust-paths.txt` unless the ticket requires it (then ask the console first). Remove any fixture you create under the real HOME before you wrap.

## Results

- 16:03 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19R-roadmap-console replaces
- 17:11 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19S-roadmap-console replaces
- 17:41 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19T-roadmap-console replaces
- 17:51 LIVE — round 2 /pr-check clean at 161bb2f7c (0 findings, 161 suites verd
