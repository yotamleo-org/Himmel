# pstack principles digest (HIMMEL-5810)

Six principles from pstack that himmel has no rule for, restated in our wording.
Nothing is installed or vendored: pstack ships 24 `principle-*` skills, most are
already himmel rules, and installing all of them would only add trigger noise
(audit: HIMMEL-5802, take-parts ticket HIMMEL-5810). Each entry cites its leaf at
the pin and says which layer it belongs on, per the `CLAUDE.md` rule "Adding a
rule - pick the cheapest layer". All six stay lean-invoke, so `CLAUDE.md` is
unchanged.

Source: [cursor/plugins](https://github.com/cursor/plugins) at
`99743e9c151c8537cbbf1f98bb38f34ef3368453` (MIT, Lauren Tan). Wording below is
ours; the ideas are theirs.

## attack-the-premise

Leaf: `pstack/skills/principle-attack-the-premise/SKILL.md`.

When two fixes that share one assumption have failed the same gate, stop fixing:
write the assumption down as one sentence, then make an observation that comes
out differently if it is false. Look at how the failures are distributed, not
just how big they are. Do not start a third fix before that check has run.

Layer: lean-invoke, linked from `systematic-debugging`. It is a debugging move
used after repeated failure, not a frame every session needs.

## build-the-lever

Leaf: `pstack/skills/principle-build-the-lever/SKILL.md`.

For non-trivial work, build the smallest script, codemod or generator that does
or proves the job, instead of doing it by hand. Do the first unit by hand to
learn the recipe, prove the tool by diffing it against that unit, and make it
safe to rerun. The tool is what a reviewer can rerun; hand edits can only be
redone. If you cite the principle and the diff has no script, you did not apply
it.

Layer: lean-invoke, linked from `writing-plans`. It shapes how a plan splits the
work, and himmel's gates already enforce the proof side.

## make-operations-idempotent

Leaf: `pstack/skills/principle-make-operations-idempotent/SKILL.md`.

Every step that changes state must survive two questions: what if it runs twice,
and what if the last run died halfway. Derive each step from the state that
exists now, compare it to the goal and apply only the difference. Leftovers (a
lock, a temp file, a claimed job) must be recognisable as stale by evidence that
holds wherever the last run stopped. Write to a temp path and rename into place.

Layer: lean-invoke, linked from `writing-plans`. It matters when a plan designs
a command or lifecycle step, which is a planning-time check.

## test-behavior-not-implementation

Leaf: `pstack/skills/principle-test-behavior-not-implementation/SKILL.md`.

Judge a test against two imagined edits: break the behavior (it must fail) and
restructure the internals while keeping every observable result (it must still
pass). Keep tests that do both, rewrite or delete the rest. Take the expected
value from the requirement, never from a run of the code under test. The
contract decides what counts as behavior: a payload a mocked external service
receives is behavior, a call to an internal helper is not.

Layer: lean-invoke, linked from `test-audit`, the skill that already audits low
value tests.

## outcome-oriented-execution

Leaf: `pstack/skills/principle-outcome-oriented-execution/SKILL.md`.

In a planned rewrite or migration with explicit phase boundaries, aim for the
verified end state instead of keeping every intermediate state working with
throwaway compatibility code. Intermediate breakage is fine when it is planned,
scoped and reversible; declare where it is allowed, keep checks on the areas
being touched, and require full static and runtime verification at plan
completion.

Layer: lean-invoke, linked from `systematic-debugging` because its failure mode
is repairing a transitional state that was meant to break; the plan side is
covered by the entry below.

## migrate-callers-then-delete-legacy-apis

Leaf: `pstack/skills/principle-migrate-callers-then-delete-legacy-apis/SKILL.md`.

When a new internal API replaces an old one and no external users depend on the
old shape, migrate every caller and delete the old API in the same wave instead
of keeping a compatibility layer. Update tests to assert the new contract and
delete tests that only protect pre-refactor internals. Does not apply when
outside users depend on backward compatibility.

Layer: lean-invoke, linked from `writing-plans`. It is a plan-shape decision for
refactors; it is not a frame every session carries.
