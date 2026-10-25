---
key: "HIMMEL-3724"
type: "Bug"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["classifier","console","sector2-safety"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-09-27T04:11:03.317+0200"
updated: "2026-10-19T11:26:09.673+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-3724: Auto-mode classifier denies console leg dispatch (brief writes, leg-doc edits) as Auto-Mode Bypass: shifts drain to 0 legs and idle on operator launches

## Description

Both are anchored /pr-check runbook script calls (scripts/cr/*.sh via the <himmel_dir> absolute-path spelling), same pattern as this ticket's existing evidence — not console leg-dispatch calls, but the same classifier misfiring on legitimate structural gate writes/reads mid-/pr-check.
- The denied command, verbatim: cd <worktrees>/fix+himmel-3648-write-fence-install-rsync-dd && bash scripts/quiet-run.sh suite -- bash scripts/ci/test-run-shell-tests.sh
2. N666 (HIMMEL-3787 S2a), 17:08. An in-worktree one-line edit of scripts/test-uninstall-provenance.sh was denied with [Out-of-Place Publication]. The edit dropped the unused out59=$(…) and out60=$(…) captures so the pre-push shellcheck SC2034 gate would pass. A fresh leg (N666b) applied the same ed
3. N671 (PR #1407, HIMMEL-3795), ~17:20. bash scripts/cr/write-verdicts.sh prior-blocking, in the anchor absolute-path form that the guard's own denial message recommends, was denied with [Out-of-Place Publication]. A fresh leg (N671b) ran the same step without a denial. N671 had been running for ab
4. N654b (PR #1396), ~17:55. A cp that temporarily replaced tracked scripts/ci/run-shell-tests.sh with the e6bd8ec1 content, for a RED check, was denied with [Irreversible Local Destruction]. That denial is arguably correct, and the RED check moved to a judge's tarball scratch tree.
  - quoted absolute bash "/.../scripts/cr/X.sh": 35   - the /pr-check step-0 if himmel_repo=$(...) fence: 18   - printf | bash write-verdicts.sh: 8   - quiet-run suites in unlisted dirs or with a redirect suffix: 14 of 14   - handover state-repo Edits: 19   - worktree Edits whose relative Edit(.clau
