---
name: docs-reviewer
description: Use when a PR or diff changes a docs page - review it against the operator's past docs remarks; learn new ones.
---

# docs-reviewer — review docs the way the operator does

Lean-invoke: run it on any PR or diff that changes a docs page, and whenever
the operator makes a new remark about docs. The rules are the operator's own
remarks, one per row of `rules.tsv`, each with its date, source and verbatim
quote. Pattern and prose rules are checked by a script; judgement rules are
yours to apply by reading the page.

Docs pages are `README.md` and `docs/**/*.md|html`. `docs/archive/` and
`docs/release/` are history and exempt.

## Run it

```bash
D="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/skills/docs-reviewer}"
[ -f "$D/docs_review.py" ] || D="$(git rev-parse --show-toplevel)/marketplace/plugins/himmel-ops/skills/docs-reviewer"

python3 -I "$D/docs_review.py" check --pr 3865                 # the PR's added lines
python3 -I "$D/docs_review.py" check --pr 3865 --whole-file    # every line of each changed page
python3 -I "$D/docs_review.py" check --range origin/main...HEAD
python3 -I "$D/docs_review.py" check --diff change.diff        # or --diff - for stdin
```

| Output line | Meaning |
|---|---|
| `path:line: R04 <rule> \| matched: GLM` | a pattern or prose rule broke on that line |
| `CHECK path: R10 <rule>` | a judgement rule: read the page and decide |
| `CANDIDATE R17 …` | a learned remark not yet confirmed; not enforced |
| `docs-review: N finding(s) …` | the summary; exit 1 when N > 0, 2 on a usage error, input that is not a diff, or a broken rules file |

Use `--whole-file` when the operator will read the whole page, which is the
usual case for a docs PR: the remark on PR 3865 was about pages, not lines.
Also run `bash scripts/docs/test-docs-current-version.sh`; it owns the dropped
platform, old model and workstream-code checks, which this skill does not repeat.

## Report the findings

1. Run `check`. Each finding is a real line to read, not a verdict: a
   `shipped` inside a code sample or a GLM row in a migration note may be
   right. Keep the ones that break the rule's intent.
2. For each `CHECK` line, read the page against that rule and add a finding
   when it breaks it. Cite `file:line` and the rule id.
3. Write one list, worst first, in the format of the consolidated docs
   audits: `<n>. **<id>, BLOCKING|MINOR|NIT (<rule>).** Location: file:line.`,
   then the fix as the exact replacement text.

## Learn a new remark

When the operator makes a docs remark, in a PR or in a chief conversation,
record it as a candidate rule in the same step, quoting the operator verbatim.
`--pattern` is a Python regular expression (`\s`, not `[[:space:]]`):

```bash
python3 -I "$D/docs_review.py" learn --pattern '<regex>' --rule '<the rule, one line>' \
  --source 'decision <n>' --quote '<the operator, verbatim>'
python3 -I "$D/docs_review.py" learn --judgement --rule '…' --source '…' --quote '…'
```

A candidate is listed, never reported. It becomes active after one
confirmation: the operator says yes when asked "is this a standing docs rule?",
or makes the same remark again. Then:

```bash
python3 -I "$D/docs_review.py" confirm R17 --by 'decision <n>'
```

`rules.tsv` is in the repo, so a learned or confirmed rule ships in a PR like
any other change. `--rules <file>` or `DOCS_REVIEW_RULES` points at another copy.

## How the chief uses it

Docs PRs do not wait on the operator (decision 286). In place of that gate:

1. The docs worker runs on opus at high effort (decision 274) and runs `check
   --whole-file` before READY, fixing or answering each finding.
2. The chief's opus-high judge runs it again on the READY head, then the
   second-model pass audits it adversarially (decisions 279, 280).
3. The chief GOs the PR after that pipeline.
4. The chief lists every merged docs change in its report (PR, pages
   touched, one line on what changed) for the operator's review after the fact.
5. Each remark the operator makes in that review goes through **Learn a new
   remark** above, so the next docs PR is checked against it.

## Proof

`test-docs-reviewer.sh` checks the rule matching on the fixture diffs in
`fixtures/` and the learn → candidate → confirm → finding path.
