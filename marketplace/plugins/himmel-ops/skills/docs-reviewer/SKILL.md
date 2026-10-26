---
name: docs-reviewer
description: Review a docs PR's changed lines against the operator's own remarks, name the code a finding implies, learn new remarks.
---

# docs-reviewer — the operator's remarks as the bar

A docs change is judged against what the operator has already said about docs.
The bar is `remarks.tsv` beside this file: one row per verbatim operator remark,
with a one-line rule paraphrasing it, its date and its source. The quote is the
authority; the rule is only a reading of it. Nothing is pattern-matched: every
row is applied by judgement, on opus at high effort (decision 274).

Docs pages are `README.md`, `site/`, and any `.md` or `.html` under `docs/` a
reader sees. `docs/archive/` and `docs/release/` are history and exempt.
`scripts/docs/test-docs-current-version.sh` owns the dropped-platform, old-model
and workstream-code checks; do not repeat them.

## Inputs

- A PR number (`gh pr diff <n>`, `gh pr view <n> --json files,reviews,comments`,
  `gh api repos/<owner>/<repo>/pulls/<n>/comments`), or a diff range
  (`git diff <base>...<head>`). For a PR number, read the head with
  `gh pr view <n> --json headRefOid,baseRefOid` and run
  `git fetch origin <headRefOid>`, so that `git show <head>:<path>` resolves.
- `remarks.tsv`: every row whose `state` is `active` or `candidate`.

## Scope: the diff, not the page

A PR review is diff-scoped. A finding sits on a changed line: a line the diff
adds or rewrites. A breach on a line the PR did not touch is pre-existing: it
counts toward one line per page and is never a must-fix item. A review with no
diff (a named page, an audit) treats every line as changed.

## Procedure

1. Read the whole remarks table first.
2. List the changed docs pages. Read each one in full at the head
   (`git show <head>:<path>`), and mark which lines the diff changed.
3. **Page verdict, first and never capped.** For each changed page: its type
   (tutorial, how-to, reference, explanation, or map), its audience, whether
   its form fits that type, and one verdict word:
   - `keep`: right as it is;
   - `polish`: fix lines, keep the shape;
   - `restructure`: the content is right but the form is not (a list that
     should be a table, a page that mixes two types);
   - `generate-from-data`: the page restates data the code already holds;
   - `move-to-ADR`: it is history or a decision record, not a reader page;
   - `drop`: nothing on it is still true or needed.
   The verdict is about the whole page, so it may rest on unchanged lines.
   The form fits when the page does what good docs do (the T3 Code, gstack,
   hermes, mattpocock/skills and pstack docs, with cursor/plugins' grok-voice
   and orchestrate, are the exemplars):
   - its first sentence says what the thing does for the reader, not how the
     page is built;
   - a getting-started path is the shortest route to first use and says the
     rest is situational; a page that covers only part names its scope and
     links the page that holds the rest;
   - an optional part says so and what happens without it; an install step
     says how the thing updates;
   - it is one type; mechanism the reader never acts on belongs on an
     internals page;
   - items with the same fields sit in a table, one fact per cell, defaults
     stated;
   - each step of a how-to or tutorial says what the reader should see;
     a troubleshooting row goes symptom, cause, fix;
   - a caveat is in place and exact (what does not work, where), not vague;
   - a generated page names its source where an editor sees it, not in the
     reader's text;
   - it ends by pointing to the next page the reader needs.
   These shape the verdict only; a finding still needs a remark or a false
   claim.
4. **Remark pass.** Take the remarks one at a time, in table order, and ask
   only that remark's question of every changed page (tables and lists too).
   A remark about a kind of thing (an integration we will not have, a dropped
   lane, an unexplained term) covers every instance of that kind, not only the
   one its quote names. Keep these lists as notes; they are not the output.
5. **Correctness pass.** List every claim the changed lines make about the
   system and check each against the code at the head (`git grep`, read the
   script or file it names). A changed line that describes code that does not
   exist, or behaves otherwise, is a finding. Do not sample: check them all.
6. **Gate each finding before you keep it.** It needs an exact changed line,
   the failure in one sentence, the code or remark you read for it, and a
   severity you can defend; otherwise demote it or drop it. One defect is one
   finding, even when several remarks touch it. Zero findings is a valid
   result.
   - BLOCKING: the changed line states something false, or breaks a remark the
     operator has made more than once (the same remark, repeated, so that more
     than one row of the table quotes it). A finding that also touches a
     second, different remark is not a repeat and stays SHOULD.
   - SHOULD: it clearly breaks one remark.
   - NIT: taste, or a finding no remark backs, marked `(no remark)`.
   An honest caveat stays on the page: a sentence that truthfully says what
   does not work yet is not a breach of the remark it touches. Its gap goes to
   the code section.
7. Read the PR's CodeRabbit comments and any judge findings on it.
8. Write the code section, then the output below.

## Code changes implied (required)

A finding implies a code change in exactly three cases (decision 299):

1. the page is true and the behaviour is the gap: the page honestly describes
   something the code does badly or not at all. A caveat such as "for now, run
   it from your clone" or "delete it yourself" is this case;
2. the page is generated and the error is in the generator's logic or in the
   data it reads;
3. the page is true only because of a known bug, so fixing the bug will make
   it false.

Everything else is not a code change:

- The code is right and the page is wrong: a docs fix. It goes in the
  must-fix list, never here. Page copy that lives inside a generator is a docs
  fix made in that file.
- A change that only makes the docs easier to maintain (derive a list, add a
  check, print a hint) goes under "declined to judge" at most.

Test every finding, CodeRabbit comment and judge finding against the three
cases. Write at most 5 entries, one line each:

`- <code file> — <the change the code needs>; removes: <the reader's problem> (case <1|2|3>; from: <remark id | CR comment | judge finding>)`

With none, write `none — <why, in one sentence>`.

## Output (3 KB or less)

The whole answer, appendix included, is 3,072 bytes or less; aim for 2,500 so
the limit holds. Start with `## Page verdicts`: no preamble, no closing note.
A replacement text is one sentence. Write it in this order and nothing else:

1. `## Page verdicts`: one line per changed page,
   `- <file> — <type> for <audience>; form fits: <yes|no, why>; verdict: <word>`.
2. `## Must fix`: at most 7 findings on changed lines, BLOCKING first, then
   SHOULD, in remark order. One per line:
   `- [BLOCKING|SHOULD] <file>:<line> — <the problem> (<remark id | correctness>) → "<replacement text>"`.
   Under it, one line per page that has pre-existing breaches:
   `- <file>: <N> pre-existing (see appendix)`.
3. `## Code changes implied`: the code section above.
4. `## Declined to judge`: one line each, what you did not rule on and why.
   Write `none` when there is nothing.
5. The summary line:
   `docs-review: <N> findings (<B> blocking, <S> should, <K> nit); <P> pre-existing; code changes implied: <M>`.
6. `<details><summary>Appendix</summary>` … `</details>`: NIT findings,
   SHOULD findings past the seventh, and the pre-existing breaches, one short
   line each, until the 3 KB limit.

When the answer would pass 3 KB, cut appendix lines first, then the last
must-fix items; the summary line still counts every finding.

The caller measures, not the model: it saves the answer to a file and runs
`python3 fit_answer.py <file>` (beside this file). The script makes those cuts
by byte count and prints the answer that fits. It cuts only appendix lines and
SHOULD lines: a page verdict or a BLOCKING line is never cut. Exit 1 means it is
still over with only page verdicts and BLOCKING lines left: send the answer back
once with "cut to 3 KB", to shorten those lines and drop none.

## Learn step

When the operator makes a new docs remark (a verbatim line in a decisions file,
or a comment that is theirs and not an agent reply), the chief adds one row to
`remarks.tsv` in a PR: the next id, state `candidate`, a one-line rule, the
date, the source (decisions file and entry), and the quote, verbatim. A
candidate row is applied like an active one and its findings say `candidate`.
It becomes `active` once the operator confirms it, or when a later remark
repeats it; the repeat is its own row, so the remark now counts as made more
than once. A quote is never edited; a changed view is a new row, and the old
row becomes `retired`.

## How the chief uses it

Docs PRs do not wait on the operator (decision 286). In place of that gate,
the review runs once per PR, on the judge side:

1. The docs worker does not run it. Its READY message names the docs pages
   the PR changes (`docs/handover/worker-brief-template.md`); the
   deterministic docs checks already run in CI.
2. The chief's judge runs it on the READY head, holds the answer to 3 KB with
   `fit_answer.py`, and sends a BLOCKING finding back as a NO-GO line
   (`docs/handover/judge-brief-template.md`).
3. The chief lists every merged docs change in its report for the operator's
   review after the fact, and runs the learn step on each remark the operator
   makes there (`docs/handover/chief-sections/merges.md`).

## Measure

`scripts/eval/docs-review/` holds the frozen cases (a PR, its base and head, and
which remark rows the run may see) and the held-out pass bars. Re-run them
after a change to this file or to the table.
