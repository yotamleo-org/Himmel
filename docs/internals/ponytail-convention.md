# The `ponytail:` convention

`ponytail:` is a code-comment marker for a known, deliberate simplification —
written at the exact line where a reader would otherwise mistake the partial
behavior for the complete one. It exists so "we simplified this on purpose"
is attached to the code, not left to survive only in a PR description or
someone's memory.

This is [upstream DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)'s
convention, not a homegrown one — we adopted the marker text but, until
a later change, neither credited it nor used its full shape. Upstream's own
`/ponytail-debt` skill (`skills/ponytail-debt/SKILL.md` in the installed
plugin, `~/.claude/plugins/marketplaces/ponytail/`) is what makes the shape
below load-bearing: it harvests every marker into a ledger and tags any that
lack the second half as `no-trigger` — "the ones that silently rot."

## Shape

```text
ponytail: <ceiling>, <upgrade path>
```

Both halves are required on a **new** marker:

- **Ceiling** — what the code does *not* do or guarantee, stated
  concretely. "Shape-based, so an unnamed or multi-word credential still gets
  through" (`run-hook-with-bash.js:306`), "AT-LEAST-ONCE, not
  exactly-once" (`stop-queue.mjs:53`). A marker that only gestures at a
  simplification ("this is simplified") without naming the limitation is not
  a conforming use.
- **Upgrade path** — the trigger or ticket that would justify revisiting the
  ceiling: name the work in words, never by its key (the gate refuses a ticket
  key on a `ponytail:` line; the open ticket stays findable in Jira by its
  summary), or a concrete condition ("upgrade to per-URL locking
  if throughput ever makes that a bottleneck",
  `scripts/handover/artifact-sync.sh:72`). "None planned, because X" is a
  valid upgrade path — it is a decision, not silence. What's not valid is
  leaving the second half off entirely.

Upstream's own illustration uses an HTML comment (`<!-- ponytail: browser has
one -->`) specifically so its README doesn't pollute its own ledger; that's a
formatting trick, not part of the convention.

- **Prefix.** A `#` or `//` line comment starting with `ponytail:` is the
  dominant shape in this repo.
- **Placement.** Directly on, or immediately above, the code exhibiting the
  simplification, in the same file — never centralized in a doc or a
  tracking issue.
- **Subject matter.** Runtime/algorithmic behavior a reviewer could
  otherwise assume is complete — a check that isn't exhaustive, a lock that
  doesn't cover a case, a comparison that's a prefix match. Not style
  commentary, not a TODO, not a changelog note.

## Where we stand today

The harvested ledger (kept in the state repo) is generated with
upstream's method (`grep -rnE '(#|//) ?ponytail:' .`, skipping
`node_modules`/`.git`/build output). Most existing markers predate this
rewrite and name only a ceiling; the ledger's `no-trigger` count is that
backlog, not a new problem this doc created. Backfilling triggers onto
existing markers is phase 2 (a planned follow-up, not this
PR) — this PR does not retro-edit any existing marker.

## Enforcement layer: documentation only, for now

Per `CLAUDE.md`'s "Adding a rule — pick the cheapest layer": escalate to a
structural gate only on the **second** drift instance, never on the first.
Requiring the upgrade-path half on new markers is itself the first
correction here — there is no prior documented instance of someone gaming
*that* requirement to escalate from. The honest read of the evidence is:
document the fuller shape, do not gate it yet.

**What would count as the second drift instance**, i.e. what would justify
adding a gate: a newly added `ponytail:` marker missing the upgrade-path
half, or naming one that just gestures without a real trigger or ticket. If
that happens, the shippable shape is a check scoped to **added** lines only
(new markers via the changed hunks) — it must never fire on pre-existing
markers, which would make it noise from day one and get it disabled within a
day.

## Writing a new one

Before writing `ponytail:`, consider whether the simplification should just
be fixed instead. If not, write the marker at the site, naming the concrete
limitation and the upgrade path — not merely that a limitation exists.

Run upstream's `/ponytail-debt` (or regenerate
the ledger the same way) whenever you want the
current backlog, rather than trusting a stale ledger snapshot.

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
and judge qids live in git and Jira. A `ponytail:` marker is no exception: it names
its upgrade path in words, not by key. A comment that explains a workaround is a
signal to fix the code, or to file one ticket for the workaround.

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
