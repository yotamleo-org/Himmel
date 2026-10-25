# HIMMEL-6449-N2777-cadence-approve-containment-gaps-2026-10-19.md

> **Scope / do not:** writes confined to RED first: one test row per gap that fails on main (paste the counts), then the fixes: nav accepted only into the vault (resolve the cd target, deny outside), containment resolves symlinks (realpath) before the vault-prefix check, model downloads denied unless the model id is on the existing allowlist (or denied outright if there is none; say which). Only scripts/hooks/cadence-approve-engines.sh and its test. Run the suite plus every impacted suite (bash scripts/cr/impacted-suites.sh), a verdict per suite. Trust path: say TRUST-PATH in READY; the console runs an opus judge. completes-ticket: yes. Other live legs and their files: N2778 (probe-chunk.sh <k>, RED test on size/determinism/concat, brief updated). Stay off those. No settings, CI workflows, SKIP_CR, --no-verify, amend, force-push, bisect or old-commit checkout; READ ONLY `scripts/hooks/lib/` and anything in `scripts/ci/ci-trust-paths.txt` unless the ticket requires it (then ask the console first). Remove any fixture you create under the real HOME before you wrap.

## Results

- 17:17 SUCCESSION accepted — console is now HIMMEL-nextleg-2026-10-19S-roadmap-
- 17:17 READY 3198 c7d4ad341f0d2925fca85070a18eaaa8e60f13cd GREEN — CI 45/45 pas
- 17:23 FINDING — judge NO-GO at c7d4ad34: fixing F1 tab-split tokens, F2 whispe
- 17:39 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19T-roadmap-console replaces
