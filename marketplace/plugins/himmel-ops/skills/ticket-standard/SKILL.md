---
name: ticket-standard
description: Check a ticket draft for Plan, DoD and named Proof before filing; a refused draft is parked in an intake queue.
---

# ticket-standard — no plan, no done-condition, no proof: no ticket (HIMMEL-5702)

Lean-invoke: run it when you are about to file a ticket, or to complete a
draft that was parked. Not always-on. The checker is a script, so the verdict
does not depend on you remembering the rules.

## The draft shape (six sections plus agent detail)

Write in plain user language. The first section says who notices and what
changes; jargon-only tickets are refused by a human at review even when the
script passes them.

1. **Impact** - who notices, what changes for them.
2. **What** - the change, one short paragraph.
3. **Why** - the decision or incident behind it.
4. **Plan** - numbered steps.
5. **DoD** - the observable done-condition, one line per check.
6. **Proof** - the named evidence (rule below).
7. **Agent detail** - what a worker session needs that a reader does not (files, suites, ordering).

Also give a primary **Sector**: `--sector NAME` or a `Sector: <name>` line.
Each section needs at least one real line; `TBD`, `TODO`, `N/A`, `none`, `...`
and `<placeholder>` count as empty.

A draft whose `Labels:` line carries `ci`, `guard`, `guardrail`, `stability` or `flake` (or a
`ci-…` / `guard-…` variant) also needs a `Metric: <scorecard column>` line naming
the stability-scorecard metric it moves (columns: `specs/research/stability-scorecard.tsv`).
`Metric:` may be bare, bulleted (`- Metric:`) or bold (`**Metric:**`), in any case.
Without one it is refused like a missing section.

A **Bug** draft also asks for two labels, so the weekly escape report
(`scripts/ci/escape-report.sh`) can group it: `found-by:<who>` (`operator`, `leg`,
`console`, `tick`, `ci-pr`, `ci-main`, `review` or `user`) and `escape:<class>`
(`contract`, `merge-skew`, `platform`, `guard` or `flake`). Ask for both when you file
a Bug; a Bug missing either is listed as UNLABELLED in the report. This is a request,
not a refusal: the checker does not gate on it.

## The title (HIMMEL-6968)

One of two kinds:

- **System:** `<Sector>: <the result>`, e.g. `Ship loop: merge waits for the signed GO`.
- **User-facing:** a short plain sentence of what the user can now do, e.g.
  `See which tickets are system work`.

No commit prefix (`feat(x):`), no ticket id, no internal names (`--flag`,
`field_name`, file paths, backticked code), at most 90 characters. `jira create`
warns with this template for a Task, Story or Bug that breaks it (exit 0, the
ticket is still filed); an Epic or Subtask is not checked.

## Proof rule per kind

| Kind | Proof names |
|---|---|
| Feature | an end-to-end run of the real user path, or a POC |
| Guard | a RED row plus a negative control |
| Hygiene | the check that would have caught it, shown green |

A check that cannot fail is not proof.

## Refuse and warn

| Type | Missing section | Missing Sector |
|---|---|---|
| Task, Story, Bug | refused: names every missing section, parks the draft, exit 1 | warns, exit 0 |
| Epic, Subtask | warns, exit 0 | warns, exit 0 |

## Run it

```bash
D="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT}"
[ -f "$D/scripts/ticket-standard-check.sh" ] || D="$(git rev-parse --show-toplevel)/marketplace/plugins/himmel-ops"

bash "$D/scripts/ticket-standard-check.sh" --type Task --sector "Planning & tracking" --draft draft.md
```

The draft file is never changed. A passing draft prints `ok:` and writes
nothing to the queue.

## The intake queue

A refused draft is copied to `<HANDOVER_DIR>/<USER_SLUG>/himmel/intake/<UTC time>-<Type>-<rand>.md`
(override: `TICKET_STANDARD_QUEUE_DIR`). Copies never overwrite each other. If
the copy cannot be written the script says `NOT PARKED` and still exits
non-zero. Without `HANDOVER_DIR` or the override it refuses to guess a queue.

To re-run a parked draft: edit the parked file (or your original), then run the
checker on it again with the same `--type`. Work the queue until it is empty:
a parked draft is unfinished work, not trash.

## File a passing draft

Use the Jira CLI by absolute path from the primary checkout, with the draft as
the description file; see `docs/internals/jira-plugin.md` for the ops.

```bash
JIRA_PROJECT_KEY=HIMMEL node <repo-root>/scripts/jira/dist/index.js create --type Task --title "<title>" --sector "<Sector>" --parent <EPIC-KEY> --desc-file draft.md
```

`create` also refuses a Task, Story or Bug with no `--sector`, or with neither
`--parent <EPIC-KEY>` nor `--labels standalone` (HIMMEL-6223); an Epic or Subtask
only warns. Sectors: Fleet orchestration, Ship loop, Safety & enforcement, Cost &
efficiency, Visibility, Quality & proof, Deployment, Knowledge & steering,
Planning & tracking.

HIMMEL-5643 enforces Plan and DoD inside `jira create` as well; this skill is the
earlier step that also checks the named Proof and keeps what it refuses.
