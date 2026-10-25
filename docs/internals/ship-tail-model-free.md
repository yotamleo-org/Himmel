# Ship tail is model-free

## Ruling

The deterministic ship tail — the scripts that drive a PR from CI-green to
merged, with no judgment call left in them — contains no `claude -p` /
`claude --print` / `claude --bg` invocation:

- `scripts/handover/merge-on-green.sh`
- `scripts/handover/chief-kit/ready-check.sh`
- `scripts/handover/chief-kit/tick.sh`
- `scripts/check-ci.sh`

Verified by grepping all four for the pattern
`(^|[^A-Za-z0-9_-])claude([^A-Za-z0-9_-].*)?[^A-Za-z0-9_-](-p|--print|--bg)($|[^A-Za-z0-9_-])`
(the pattern `scripts/cr/test-ship-tail-model-free.sh` uses, broadened past
an immediately-after-`claude` match so a flag appearing after other flags on
the same invocation also trips it — see "Regression guard" below) against
main at `92ee89588` (2026-09-26): zero matches.

## Scope: hermes-critic.sh is excluded, not missed

`scripts/cr/hermes-critic.sh:343` calls `claude -p --output-format json
--permission-mode plan ...`. This is the nearest headless call to the ship
tail, but it IS the automated review itself — the step where a model judges the
diff. "Model-free" describes the mechanical tail that acts on a review's
verdict (merge, ready-check, CI polling), not the review that produces the
verdict. Out of scope for this ruling by definition: a review needs
judgment.

## Regression guard

`scripts/cr/test-ship-tail-model-free.sh` names the four files above and
asserts none of them contain a headless call (a word-bounded grep for
`claude -p`/`--print`/`--bg`, broadened to also catch the flag appearing
after other flags on the same invocation). It has no opt-in escape, because
the ship tail staying model-free is a purity invariant, not a billing
decision: a future PR that adds a headless call to any of the four named
files fails this test.
