# How a rename lands

A rename is finished when no reader, writer, doc or test still uses the old
name, not when the new name works. The rename audit (HIMMEL-8298) found two
places that broke because a rename landed halfway: a doc that showed a
command the code refused, and a status reader that kept its own copy of a
retired marker. This page is the rule that stops a third one. The rows it
refers to live in `scripts/lib/rename-aliases.tsv` (the registry); the gates
that enforce it are `scripts/ci/check-rename-diff.sh` and
`scripts/ci/check-doc-literals.sh`.

## The steps, in order

1. **Alias row first.** Add the registry row before any code moves: old name,
   new name, `kind`, the `direction` that says how the old name is treated,
   the slice, and a `remove-at` version. The direction is the mode the gate
   reads (below). A name that is never renamed gets a `keep` row, so the gate
   can tell "kept on purpose" from "forgotten".
2. **One shared reader.** Every reader accepts both names through the one
   helper that already owns that vocabulary: `scripts/lib/env-alias.sh` /
   `env-alias.mjs` / `env_alias.py` for variables, `status-marker.sh` /
   `.mjs` / `.py` for status markers, `canonicalProfileName` for profile
   ids, the bus normalize for roles. Never a private regex copy of the
   vocabulary. A deny marker (a variable whose presence refuses something)
   refuses when **either** spelling is set; the new name never wins over the
   old one.
3. **Writers, docs and tests switch in the same PR.** The PR that makes the
   new name live also moves every writer, every doc that shows the name, and
   every test that pins it. A doc is part of the interface: a command literal
   in a doc is checked against the CLI (`check-doc-literals.sh`), and the
   accept row for that CLI is edited in the same PR as its parser.
4. **Stored records and directories.** Anything written to disk under the old
   name (identity records, inbox directories, decision files, marker lines in
   handover docs) gets either a `himmel-update` migration that moves it
   (pattern: `scripts/handover/move-renamed-dirs.sh`, tested in
   `scripts/test-himmel-update-migrations.sh`) or a permanent read alias.
5. **File the removal ticket in the alias PR**, with its fix version, so
   `remove-at` has an owner. The removal drops the read-both path for that row
   and flips its direction so a returning old name is refused.

## The gates

| Gate | Reads | Refuses |
|---|---|---|
| `scripts/ci/check-rename-diff.sh` | the lines a PR **adds**, against every registry row | a retired name (see the mapping below) |
| `scripts/ci/check-doc-literals.sh` | `docs/**/*.md`, `marketplace/**/SKILL.md`, `.claude/commands/*.md` | a `--flag`, or a `--role` value, on a documented invocation of `bus`, `tick.sh`, `board.mjs`, `chief.sh`, `headed-arm-worker.sh`, `gen-briefs` or `append-results.sh` that the CLI does not accept |

**Registry direction as mode.** `check-rename-diff.sh` scans, per `kind`:
prose, path and directory rows when the direction is `fail`; identifier and
marker rows when it is `old-to-new` (a row whose new name is still
`pending-N2892` counts: the old name is retired even before the new one is
ruled); env and env-prefix rows always (they are read-both until `remove-at`,
but a **new** line should not add the old spelling). `keep` rows and `warn`
prose rows are not scanned. A name that starts with a `keep` prefix
(`HIMMEL_CONSOLE_`) is exempt.

**Exemptions are two, nothing else.** A keep row, and the inline marker
`old-term-ok: <reason>` on the line (`# old-term-ok: ...` in shell,
`<!-- old-term-ok: ... -->` in markdown). Use the marker for a line that
must show the old spelling: a reader of the old name, a test that asserts the
refusal, a page that inventories old names. The registry file itself is never
scanned.

**Report mode.** Until the v1.1.3 rename batches have merged, both CI steps
run with `--warn`: they print their findings and exit 0, so no PR fails.
After that the flag is dropped and the steps fail the PR. For a tree-wide
view, `bash scripts/ci/check-rename-diff.sh --report <dir>` writes
`<dir>/by-file.tsv` (hits per file, most first) and `<dir>/hits.txt` (every
hit with its old and new name). It takes about a minute and exits 0; it is
the work list for the cosmetic rename batches.

## The doc-literal accept row

`check-doc-literals.sh --list-accept` prints one line per CLI: its name, its
source file, the pattern that finds an invocation in a doc, the flags it
accepts, the `--role` values it accepts, and the flags its parser refuses on
purpose (shown in a doc, those are reported as refused). The row is declared
by hand and `scripts/ci/test-check-doc-literals.sh` pins it to the CLI's own
source, so a parser change without its row fails that test. A rename that
changes a CLI's flag or role vocabulary edits the row in the same PR, which is
what makes the doc, the parser and the gate agree.

`ponytail:` the declared row can drift if the test is skipped or the parser is
written in a style the test cannot read; the upgrade path is to generate the
row from the parser's option table.

## Known limits

- The diff gate flags a line that still carries an old name it already had
  when the PR edits that line. Add the marker, or finish the rename on that
  line. (`ponytail:` net the added hits against the removed lines of the same
  file.)
- A prose row matches whole words, case-insensitive, with an optional plural
  `s`; a word followed by `.name` is code and is skipped. Words with other
  senses (the browser console, a lane worker) are decided by the registry
  rows, not by the gate.
