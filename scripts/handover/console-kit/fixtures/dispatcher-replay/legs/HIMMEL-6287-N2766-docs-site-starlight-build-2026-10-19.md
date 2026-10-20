# HIMMEL-6287-N2766-docs-site-starlight-build-2026-10-19.md

> **Scope / do not:** writes confined to Files: site/ (sidebar allowlist, build config, copy step, Pagefind), site/test-site-build.sh plus the J1 journey rows, .github/workflows/pages.yml (a CI trust path: say TRUST-PATH in READY, the console runs an opus judge), and the 'Publishing these docs' section of docs/README.md. Do not move any docs/ file. Pin exact versions at least two weeks old. RED first: J1 rows for one page per IA section, /adoption-trail.html, a raw setup/install.md and setup/settings-template.json fail before the change. Proof stays LOCAL (operator decision 18): npm run build, then serve site/dist locally and paste the curl status lines for the DoD URLs under the /Himmel base, plus a Pagefind hit for 'stuck playbook' and a deliberate broken link failing the build in a scratch run. Do NOT run workflow_dispatch on the Pages workflow and do not deploy: the operator reviews the local site first, and the deploy run is owed after merge. Impacted suites with a verdict per suite. completes-ticket: no (the live Pages deploy proof closes it). Other live legs and their files: N2765 (20 KB under 1 s via early exit and pass merge; j2178 rows judged). Stay off those. No settings, CI workflows, SKIP_CR, --no-verify, amend, force-push, bisect or old-commit checkout; READ ONLY `scripts/hooks/lib/` and anything in `scripts/ci/ci-trust-paths.txt` unless the ticket requires it (then ask the console first). Remove any fixture you create under the real HOME before you wrap.

## Results

- 15:51 LIVE — holding at READY 3188 7d2e2760e62e579e4feaa8fc2828439c6c85c1de; c
- 15:53 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19R-roadmap-console replaces
- 17:08 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19S-roadmap-console replaces
- 17:37 SUCCESSION accepted: HIMMEL-nextleg-2026-10-19T-roadmap-console replaces
