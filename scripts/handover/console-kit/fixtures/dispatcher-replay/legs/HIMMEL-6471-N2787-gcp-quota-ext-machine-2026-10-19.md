# HIMMEL-6471-N2787-gcp-quota-ext-machine-2026-10-19.md

> **Scope / do not:** writes confined to writes confined to scripts/ci/gcp-runners.sh and scripts/ci/test-gcp-runners.sh. completes-ticket: yes. Other live legs and their files: N2786 (scripts/jira/src transition + versionless-done), N2788 (qmd fork rerank switch). Stay off those. No settings, CI workflows, SKIP_CR, --no-verify, amend, force-push, bisect or old-commit checkout; READ ONLY `scripts/hooks/lib/` and anything in `scripts/ci/ci-trust-paths.txt` unless the ticket requires it (then ask the console first). Remove any fixture you create under the real HOME before you wrap.

## Results

- 16:35 LIVE — RED then green (new -ext row failed before fix); impacted suites
- 17:08 LIVE — expansion done: quota read drops --filter (flatten plus awk CPUS)
- 17:18 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19S-roadmap-console replaces
- 17:38 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19T-roadmap-console replaces
