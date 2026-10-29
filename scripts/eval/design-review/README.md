# design-review eval

Does a design reviewer catch a bad spec and leave a good one alone? Each case
is one spec or plan. A GOOD case is a real himmel spec that shipped cleanly. A
BAD case is the same spec with one defect planted on one of the five design
dimensions (`charter.md`: 9 traceability, 10 failure modes and rollback, 11
executable DoD and proof, 12 cheaper alternative, 13 conflicts) or a scope
creep. The reviewer sees only the case, never the label.

The set is not in this repo. Specs are internal artifacts, so the fixtures,
their builder and the key live in the state repo bucket at
`specs/eval/design-review/`:

| path | what |
|---|---|
| `build.py` | builds the set from 6 real specs: 12 BAD twins (2 per class: trace, rollback, dod, cheaper, conflict, scope) and the 6 GOOD originals, shuffled to opaque ids |
| `fixtures/case-NN.md` | the spec under review; `case-NN.parent.md` is the parent spec of a plan |
| `key/labels.json` | per case: verdict, class, expected dims, anchors, twin, split (open or sealed), fixture sha256; plus the canary and the set sha |

This directory holds the code:

| file | what |
|---|---|
| `charter.md` | the reviewer prompt under test |
| `charter-broken.md` | the control: a copy-edit-only prompt that must score low |
| `run.sh` | one billed api-lane call per case, then `score.py score` |
| `score.py` | `lint` checks the set against its key; `score` reads the answers and writes the results |
| `test-design-review.sh` | the scorer self-check (synthetic set, no model call); it does not measure the reviewer |

## Running

```
HIMMEL_BILLED_OK=1 bash scripts/eval/design-review/run.sh \
    --set <bucket>/specs/eval/design-review --out <fresh dir>
HIMMEL_BILLED_OK=1 bash scripts/eval/design-review/run.sh \
    --set <bucket>/specs/eval/design-review --out <fresh dir> \
    --charter scripts/eval/design-review/charter-broken.md --label broken
```

Each case runs opus at high effort on `scripts/api-lane/claude-api.sh` (account
`auto`, Read, Glob and Grep only, `--max-budget-usd 2`); a batch whose worst
case passes $40 refuses before any call. The fixture dir holds `SPEC.md`,
`PARENT-SPEC.md` for a plan, and `LOOKUP/`: the Jira mirror (this eval's own
tickets removed), the operator memory dir, the bucket's decisions and
matrices, and the project `CLAUDE.md` as of the spec's date. `CLAUDE_CONFIG_DIR`
is empty, and a free canary (`../docs-review/helper.py`) checks before each
billed call that no hook, extra tool, MCP server or memory text loads.
`--canary-only` runs only the canaries and needs no opt-in.

## What it writes

Per case, `<out>/<case>/` holds `review.md`, `meta.json` (rc, cost, turns) and
`audit.txt` (tool paths that left the fixture). `<out>/results.jsonl` holds one
row per case and one summary row, each carrying the run id, label, model,
effort, charter sha256 and set sha256, so two runs can be diffed row by row.
One row goes to the eval-runs ledger (`eval: design-review`, per-case `hit` and
`false_alarm`, compared by `scripts/eval/eval-compare.json`).

## The metrics

- **recall**: BAD cases where a Critical or Important finding sits on one of the
  case's dims AND names one of its anchors (the planted text). A right-dim
  finding about another part of the spec is a miss. `recall_dim` and
  `recall_anchor` are the looser halves.
- **paired_recall**: hits the GOOD twin does not also carry, so a finding
  the reviewer raises on every version of the spec does not count.
- **false_alarm**: GOOD cases with a Critical or Important finding on dims
  9-13. `false_alarm_any` counts every dim.
- Each splits by `open` and `sealed` (3 source specs each), with Wilson
  intervals. Tune on `open`; quote `sealed`.
- A case with no `SUMMARY` line is a no-answer: left out of the rates, and
  the run is `partial`. The key canary in any answer makes the run
  `inconclusive` (exit 3).

## Limits

- With 12 BAD and 6 GOOD cases, one case moves recall by 8 points and the
  false-alarm rate by 17. Read the intervals, not the point.
- Memory, decisions and matrices are today's copies, not as of the spec's date;
  only `CLAUDE.md` is dated. A conflict a later rule created can read as a hit.
- There is no code checkout, so a claim about the code is "not checkable".
- ponytail: 18 cases from 6 specs; grow the set with each spec that ships (or
  fails) through minerva, built by the same `build.py`.
