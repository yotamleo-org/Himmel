# HIMMEL-6057-N2759-known-findings-refresh-jq-match-2026-10-19.md

> **Scope / do not:** writes confined to scripts/cr/known-findings.json and scripts/cr/test-known-findings.sh only. RED row first in test-known-findings.sh: a finding text 'jq .flag // empty swallows false' is attributed to jq-alternative-swallows-false. Impacted suites: test-known-findings.sh plus every suite referencing known-findings.json or known-findings.sh (grep). Done when known-findings.sh --refresh output is committed and the suite passes. completes-ticket: yes. Other live legs and their files: N2760 (AG-UI source identity stable across census refresh), N2761 (jira versions archived column + merge-on-green skip). Stay off those. No settings, CI workflows, SKIP_CR, --no-verify, amend, force-push, bisect or old-commit checkout; READ ONLY `scripts/hooks/lib/` and anything in `scripts/ci/ci-trust-paths.txt` unless the ticket requires it (then ask the console first). Remove any fixture you create under the real HOME before you wrap.

## Results

- 17:16 BLOCKED — readiness hold persists; monitor bjck5g4h8 expired normally, h
- 17:37 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19T-roadmap-console replaces
- 17:37 BLOCKED — T accepted; unchanged readiness blockers since 16:15. PR 3186
- 17:46 BLOCKED — monitor bzj76d76e expired normally; benign hook drain delivere
