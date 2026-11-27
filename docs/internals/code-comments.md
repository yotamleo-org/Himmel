# Code comments and accepted ceilings

## Code comments

Comments that stay (the keep list is poteto's `comment-sicko`, MIT, cursor/plugins
`pstack`):

- license headers;
- behaviour forced by an external dependency, platform or protocol we cannot reshape;
- doc comments that define a public API contract;
- issue or RFC links explaining a constraint the code cannot express;
- lint suppressions, only when the rule is faulty or style-only;

Every other comment goes. A surprise in our own code is a refactor target, not a
comment. History does not belong in code: ticket IDs, review rounds, "CR fix" notes
and judge qids live in git and Jira. A known limitation does not belong in code
either: it is a row in the ceilings ledger (below). A comment that explains a
workaround is a signal to fix the code, or to file one ticket for the workaround. A
decision worth keeping is a short record in the state repo bucket `specs/decisions/`.

### The new-comment gate

`scripts/lint/check-new-comments.sh` refuses a new comment outside the keep list, at
pre-commit (`--staged`) and in CI (`--range <base>`, run from the BASE copies). It
counts, per code file, the comment lines its classifier `scripts/lint/comment-count.awk`
does not keep, and compares the count with the file's row in
`scripts/lint/comment-baseline.tsv` (`key<TAB>count`). The key is the git blob hash of
the path, `printf '%s' <path> | git hash-object --stdin`, so the baseline carries no
file name for a tree-wide name scan to count:

- Only the code files a change touches are judged, so a change that touches no
  commented file can never fail. A touched file's count may not exceed its row; a file
  with no row is allowed none, so a new file starts at zero.
- A touched file's limit is the lower of its row and the count of the base's version of
  the file (the path it was renamed from, for a rename). A sweep that deletes comments
  therefore never has to write the baseline: it lowers the file's limit by itself, a
  later change that adds one back is refused, and a separate PR rewrites the rows
  afterwards. The refusal then names the base's count instead of the row.
- The baseline only goes down. A row may not rise above the base's row for that path,
  or for the path the file was renamed from in the same change; a new row above zero
  is refused. CI reads the base's baseline, so a change cannot raise the rows that
  judge it.
- A change that adds no comment always passes: a count or a row above that limit is
  accepted when it is no higher than the count of the base's version of the file, so a
  row that fell behind the tree bills nobody. A change to `comment-count.awk` recounts
  the tree, so for a file that change does not touch the changed classifier takes that
  count; a file it does touch is counted by the classifier the gate runs.
- A merge in progress (`--staged` with `MERGE_HEAD`) is judged against both parents: a
  path's row limit is the higher of the two parents' rows, and a file may keep as many
  comments as either parent's version holds. A count above both parents' is refused.
- Rewording a comment in place, or editing a code line that carries one, leaves the
  count unchanged and passes. The refusal names the file by its path, its count and its
  row, then the added comment lines as `path:line: text`. A raised row whose key matches
  no file at the tip or the base is refused by its key.

What the classifier keeps, because a line-based check can recognise it: the leading
comment block of a file before its first code line (purpose, usage, exit codes); a
license or copyright line; a lint suppression directive (`shellcheck`, `eslint`,
`prettier-ignore`, `@ts-…`, `noqa`, `type: ignore`, `pylint`, and the `<name>-ok:`
markers this repo's own lints read); a comment carrying an `http(s)` link; a `/** */`
doc block. There is no keep marker. A comment about behaviour forced by an external
dependency, platform or protocol stays by carrying the link to that constraint.
Detection is line-based: a heredoc body and a Python triple-quoted string are skipped;
a `#` inside any other multi-line string is not tracked. A changed path git has to
quote (a double quote, backslash or control character in its name), a classifier
that prints no count, or a baseline row whose count is not a plain number of at most
nine digits makes the gate exit 2 (cannot evaluate), as does any lookup or compare
that itself fails. The paths left out are the
whole-file rows of `scripts/lint/ticket-ref-allow.tsv` (fixtures, archives, generated
and vendored trees).

`bash scripts/lint/check-new-comments.sh --write-baseline` rewrites the baseline from
the working tree, and handles a root file named like an awk assignment (`a=b.sh`) as a
file. A sweep PR leaves the baseline alone; run it in its own PR after sweeps
merge, and in the PR that renames a file so the row moves with the file. The sweep itself is the `/no-comments` skill
(`.claude/skills/no-comments/SKILL.md`).

To read a baseline diff, hash the paths the change touches and match the keys:

```bash
git diff --name-only origin/main... | while IFS= read -r p; do printf '%s\t%s\n' "$(printf '%s' "$p" | git hash-object --stdin)" "$p"; done
```

The counts by path, highest first. This is a repo-wide look, not the baseline's file set:
it does not leave out the whole-file rows of `scripts/lint/ticket-ref-allow.tsv` as
`--write-baseline` does:

```bash
git ls-files -z '*.sh' '*.bash' '*.zsh' '*.ps1' '*.psm1' '*.py' '*.js' '*.mjs' '*.cjs' '*.ts' '*.tsx' '*.mts' '*.cts' | xargs -0 awk -f scripts/lint/comment-count.awk -v mode=tree | sort -t "$(printf '\t')" -k2,2nr
```

### The history-comment gate

`scripts/lint/check-history-comments.sh` enforces this at pre-commit (`--staged`)
and in CI (`--range <base>`, run from the BASE copies). It reads one classifier,
`scripts/lint/ticket-refs.awk`, and one rule list,
`scripts/lint/ticket-ref-allow.tsv`, which owns the ticket-key pattern in its `key`
row. An added line carrying a key in any tracked text file (code, comments, output,
Markdown, YAML, JSON, TSV) is refused unless a row of the list covers it. The
other rows are kinds of kept text: K1 dated history records (changelog, release and
migration docs), K2 fixture inputs a test reads verbatim, K3 ticket mirror copies,
K4 provenance records and generated trees, K6 data a program reads (one row per
file and line shape, found by tracing which program parses the key), K7 the list
itself. A key a program reads needs a K6 row, landed in its own change before the
change that needs it, because CI judges a PR with the base list. In a test file a
key is data (K5), refused only on a whole-line comment and in four citation shapes:
keys in parentheses right before a closing quote, `SKIP` or `FAIL` followed by a
key, a quoted message that opens with a key and a colon, and a trailing comment
outside every quote. The escape for a test that asserts product text carrying a key
is a fixture file or a key built at runtime. Review-round, "CR fix" and judge-qid
wording is refused on whole-line comments in code files only. Binary files are
skipped by content; there is no `history-ok` or `ticket-ok` exemption. Detection is
line-based, not a language parser: split calls and strings on continuation lines
are not tracked. Existing unchanged lines are not touched; the removal of the keys
already in the tree is a separate piece of work, checked by hand with
`scripts/one-shot/check-ticket-refs.sh`, which is never wired into a hook, a suite
or CI. A missing or unreadable classifier or rule list makes the gate exit 2 (cannot
evaluate), at pre-commit and in CI.

### The strict ticket-key lint

`scripts/lint/check-new-ticket-ids.sh` is the rule the history-comment gate cannot be:
a change that adds a ticket key to any tracked file, or adds a file name that carries
one, is refused, with no allow list (a test file, a fixture, a changelog and a data file
are judged like any other text). It judges added lines only and skips binary files.
Run it by hand with `--staged` (the index against HEAD) or `--range <base> [--tip <ref>]`;
it exits 0 clean, 1 on findings, 2 when it cannot evaluate. It is not yet a pre-commit
entry or a CI step: that waits until the test files stop carrying keys, because about three
in ten merged changes today add a key to a test file. Its suite is
`scripts/lint/test-check-new-ticket-ids.sh`.

## Ceilings

A ceiling is a known, deliberate limit of the code: what it does not do or
guarantee, and the condition that would justify lifting it. It used to be written
next to the code as a ponytail marker. It now lives in one private ledger per
state bucket, `<bucket>/specs/ledgers/ceilings.tsv`, so the code carries no
limitation notes and review still sees them.

- **Writing a row.** `scripts/ledger/ceiling-add.sh add --file <path> --anchor
  <name> --ceiling <text> --trigger <text> [--ticket <key>]` appends an open row
  and prints its id (`C-0001`, …). The anchor is a function, case label, variable
  or JSON key in that file, never a line number. `set --id <id> --state
  lifted|obsolete|dropped --note <why>` closes a row by appending a new one; the
  ledger is never rewritten. `import --check` and `import --pr <n>` load a draft
  of many rows at once.
- **Reading it in review.** `/pr-check` prints a `CEILINGS:` header on stderr with
  the open rows for the files a diff touches, and the judge agents and the API
  judge read the same lookup, `scripts/ledger/ceiling-lookup.sh --range
  <base>...<head>`. Row text is shown only in a Claude session; any other session
  sees `CEILINGS: withheld`. A verdict record carries row ids only.
- **Citing a row.** A review finding that restates an open row at its anchor is
  answered with the row id. A ceiling never excuses a defect the change
  introduces, and a row that no longer matches the code is itself a finding.
  Row text never goes into a GitHub reply, a PR body or a verdict reason.
- **Keeping it fresh.** The himmel-update gap audit lists open rows whose ticket
  is Done, whose file is gone or whose anchor no longer matches.
- **The gate.** `check-history-comments.sh` refuses an added ponytail marker (the
  word and a colon, any case) in any tracked text file outside a whole-file row
  of the rule list; a deleted marker line is never refused. The refusal says to
  record the ceiling with `ceiling-add.sh add`, then delete the marker.
