---
name: docs-reviewer
description: Review a docs PR against the operator's own remarks, name the code each finding implies, learn new remarks.
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
  (`git diff <base>...<head>`).
- `remarks.tsv`: every row whose `state` is `active` or `candidate`.

## Procedure

1. Read the whole remarks table first.
2. List the changed docs pages. Read each one in full at the head
   (`git show <head>:<path>`), not only its hunks: "no clear bottom line" is a
   remark about the page, not a line.
3. **Remark pass, first.** Take the remarks one at a time, in table order. For
   each, read every changed page in full (tables and lists too) and ask only
   that remark's question of it. Write one list per remark:
   `### <id> — <rule>` then one line per page that breaks it,
   `- <file>:<line>[, <line>…] — <what breaks it, one sentence>`, or `- none`.
   A remark about a kind of thing (an integration we will not have, a dropped
   lane, an unexplained term) covers every instance of that kind on the page,
   not only the one its quote names. Do not check correctness in this pass.
4. **Correctness pass, second.** Check every claim the page makes about the
   system against the code at the head (`git grep`, read the script or file it
   names): a page that describes code that does not exist, or behaves
   otherwise, is a finding. At most 10, one line each:
   `- <file>:<line> — <the claim> is false: <what the code does>`.
5. Write the findings, at most 30, one line each, the remark-pass findings
   first (in remark order), then the correctness ones:
   `- [BLOCKING|SHOULD|NIT] <file>:<line> — <what is wrong, one sentence> (<remark id>: "<short verbatim quote>")`
   - BLOCKING: the page states something false, or breaks a remark the
     operator has made more than once: the same remark, repeated, so that more
     than one row of the table quotes it. A finding that also touches a second,
     different remark is not a repeat and stays SHOULD.
   - SHOULD: it clearly breaks one remark.
   - NIT: taste; also any finding no remark backs, marked `(no remark)`.
   Group repeats: one finding per page per remark, naming the other lines.
6. Read the PR's CodeRabbit comments and any judge findings on it.
7. Write the required section below. Never skip it.
8. End with one line:
   `docs-review: <N> findings (<B> blocking, <S> should, <K> nit); code changes implied: <M>`.

## Code changes implied (required)

For every finding above, and for every CodeRabbit comment and judge finding on
the PR, ask: is the page only describing code that is itself wrong, missing or
confusing? If so, the fix is in the code, not the words (decision 299). A
caveat such as "for now, run it from your clone" or "delete it yourself" is a
gap to close in code. One line each:

`- <code file> — <the change the code needs> (from: <remark id | CR comment | judge finding>)`

Write `none — <why>` only after checking each one.

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

Docs PRs do not wait on the operator (decision 286). In place of that gate:

1. The docs worker runs this review before READY and quotes the findings line
   and the code-changes section in its READY message
   (`docs/handover/worker-brief-template.md`).
2. The chief's judge runs it again on the READY head
   (`docs/handover/judge-brief-template.md`).
3. The chief lists every merged docs change in its report for the operator's
   review after the fact, and runs the learn step on each remark the operator
   makes there (`docs/handover/chief-sections/merges.md`).

## Measure

`scripts/eval/docs-review/` holds the frozen cases (a PR, its base and head, and
which remark rows the run may see) and the held-out pass bars. Re-run them
after a change to this file or to the table.
