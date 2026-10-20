# HIMMEL-6431-N2769-ci-gcp-kill-switch-carve-out-2026-10-19.md

> **Scope / do not:** writes confined to Files: the hook and its suite only. RED first: `gh variable set CI_GCP --body off -R yotamleo/Himmel` (plus the `on` twin) is denied on main and allowed on the branch. Controls must still deny: another variable name, a secret set, a value other than on/off, a different repo, a chained or substituted second command, and an env-prefix spelling. Probe only through fixture files fed to the worktree copy. Trust path: say TRUST-PATH in READY; the console runs an opus judge. Impacted suites with a verdict per suite. Never run the command live. completes-ticket: yes, unless an allow rule is deferred, in which case no. Other live legs and their files: N2767 (K7 AFTER rows + census + industry comparison), N2768 (fail closed on missing/non-string/unmapped executeWrite name), N2770 (up preflight + full cleanup on create failure (stubbed gcloud)), N2771 (fix stale claims in docs/daily-loop.md), N2772 (graph.json + check-dev-graph.sh drift check). Stay off those. No settings, CI workflows, SKIP_CR, --no-verify, amend, force-push, bisect or old-commit checkout; READ ONLY `scripts/hooks/lib/` and anything in `scripts/ci/ci-trust-paths.txt` unless the ticket requires it (then ask the console first). Remove any fixture you create under the real HOME before you wrap.

## Results

- 15:55 SUCCESSION accepted: console is now HIMMEL-nextleg-2026-10-19R-roadmap-c
- 16:53 READY 3194 a208247933198be444a506e0b5ec18de822f3573 GREEN — TRUST-PATH y
- 17:09 SUCCESSION accepted: console is now HIMMEL-nextleg-2026-10-19S-roadmap-c
- 17:43 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19T-roadmap-console replaces
