# merge-forward-check refuses every inherited red when the only covering main run already holds the fix

Impact
Internal: when main is fixed by a commit after a leg's merge-base and main has no CI run at that merge-base, every held leg is refused a legitimate merge-forward. Each refusal needs a console ruling by hand. On 2026-10-13 that blocked 9 legs at once.
What
merge-forward-check.sh should be able to prove that a red is inherited when the only covering main run already contains the fix. Today it takes that run's green as "base: success", so it reads every inherited red as the PR's own.
Why
Main CI runs only on a cron or a dispatch, so most merge-bases have no run of their own. The covering-run fallback (HIMMEL-5124) then picks the next completed run, and that run is usually the one that carries the fix. The polarity rule cannot express "red at the merge-base, fixed later".
Agent detail
- Repro (2026-10-13): HIMMEL-5449 (#2495, 915c81d1) fixed git-env-scrub red from the srt-poc files of #2473. PRs 2486, 2488, 2491, 2493, 2496 and 2498 each got "REFUSE: git-env-scrub (base: success - not inherited, the PR's own red) - base verdict from the next completed covering main run at 915c81d1 (range 65506b96..915c81d1)".
- RED rows first: the 2026-10-13 shape (cover holds the fix, the PR's red case is reproducible at the merge-base) must ALLOW. A PR whose own diff causes the case must still REFUSE.

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/handover/test-merge-forward-check.sh`

The checks it must pass include:

- `scripts/handover/test-merge-forward-check.sh`: fixed cover, no local reproduction: REFUSE as before (cannot tell inherited from the PR's own)
- `scripts/handover/test-merge-forward-check.sh`: fixed cover, reproduced case belongs to another job: REFUSE
- `scripts/handover/test-merge-forward-check.sh`: fixed cover, empty local reproduction: REFUSE
- `scripts/handover/test-merge-forward-check.sh`: fixed cover, two reds, only one reproduced at the merge-base: REFUSE
- `scripts/handover/test-merge-forward-check.sh`: fixed cover + local reproduction but latest main red: REFUSE (not proven fixed)
- `scripts/handover/test-merge-forward-check.sh`: merge-base's own completed green run + local reproduction, no cover: REFUSE (a flake is the PR's own red)
- `scripts/handover/test-merge-forward-check.sh`: malformed local reproduction row: usage, never ALLOW
- `scripts/handover/test-merge-forward-check.sh`: --base-cases-local file missing: usage, never ALLOW
- `scripts/handover/test-merge-forward-check.sh`: --base-cases-local given an empty path: usage, never silently skipped
- `scripts/handover/test-merge-forward-check.sh`: local-reproduction ALLOW does not claim a merge-base run supplied the evidence
- `scripts/handover/test-merge-forward-check.sh`: local reproduction without the merge-base header (a copied PR-cases file): usage, never ALLOW
- `scripts/handover/test-merge-forward-check.sh`: local reproduction bound to a different sha than --base-sha: usage, never ALLOW
- `scripts/handover/test-merge-forward-check.sh`: local reproduction with a non-sha merge-base header: usage, never ALLOW
- `scripts/handover/test-merge-forward-check.sh`: ALLOW cites the reproduction command and the local log
- `scripts/handover/test-merge-forward-check.sh`: cited local log does not exist: usage, never ALLOW
- `scripts/handover/test-merge-forward-check.sh`: cited local log is empty: usage, never ALLOW
- `scripts/handover/test-merge-forward-check.sh`: local reproduction with a command header but no log header: usage, never ALLOW
- `scripts/handover/test-merge-forward-check.sh`: one job with two PR cases, only one reproduced at the merge-base: REFUSE

Run the tests you touch before you finish. Report what you changed and what you checked.
