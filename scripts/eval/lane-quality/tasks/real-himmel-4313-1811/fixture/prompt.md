# himmelctl update drift pass skips the qmd skills-collection ensure (NOT auto-fixed)

Found during the 2026-10-04 qwen embed-model swap on the station (console AM, leg N1185).
himmelctl update did not run the qmd-index ensure for the skills collection. Its drift pass printed the skills collection as "NOT auto-fixed" and moved on, so an update leaves the skills collection unbuilt or stale even though HIMMEL-4302 (#1780) added build-and-register on install/ensure.
Ask: when update's drift pass finds the qmd skills collection missing or stale, it runs the same ensure step that install runs (or reports a remedy line naming the exact command if an auto-fix is unsafe). Add a test that reproduces the "NOT auto-fixed" path.
Related: HIMMEL-4302, HIMMEL-4246 (himmel-update self-heals installer drift).

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/test-himmel-update-drift.sh`

Run the tests you touch before you finish. Report what you changed and what you checked.
