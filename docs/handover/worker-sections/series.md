# Worker preface section — a stacked series leg

Read on demand: a brief's `> **Series:**` line names this file. A series is several
tickets that touch the same files, written one after another by a chain of legs, each
leg one item. The state of the series is on disk, not in your context: the ledger
(`<sid>.json`), git and gh.

## The rules

- **One item per leg.** `series-next.sh start` refuses a second start from the same doc
  with `one item per leg: hand off at READY`. Hand off instead.
- **Only the ledger's writer writes.** `start`, `commit`, `pass` and `abandon` refuse a
  `--doc` that is not the ledger's `writer` and name the real one. Only `pass` moves the
  writer.
- **The ledger is not yours to write: never edit the ledger JSON.** Every read and write goes through `series-ledger.py`,
  which `series-next.sh` calls for you. Do not open the file with an editor or a script.
- **No compact mode.** A compact checkpoint needs a pushed commit at HEAD, and an
  unpublished item is never pushed. gen-briefs refuses a series brief whose context
  guard is `compact`; if yours is, tell the chief.
- **After any compaction, run `series-next.sh status` before your next write.** The
  summary is lossy; the ledger, git and gh are not. Trust `status` over the summary and
  over the RESUME prose.
- **Item worktrees skip `worktree.sh`'s setup.** `start` runs `git worktree add` itself
  (`worktree.sh new` refuses a `series/` branch and cuts only from `origin/main`), so
  nothing installs dependencies. If your item needs the jira deps or another install
  step, run it by hand in the item worktree.

## The commands

Run them from your worktree or the primary checkout. `<p>` is the ledger path from the
brief's Series line, `<doc>` is your own handover doc.

```
bash scripts/handover/chief-kit/series-next.sh status --ledger <p>
bash scripts/handover/chief-kit/series-next.sh start --ledger <p> --doc <doc> <KEY>
bash scripts/handover/chief-kit/series-next.sh commit --ledger <p> --doc <doc> <KEY>
bash scripts/handover/chief-kit/series-next.sh pass --ledger <p> --doc <doc> <resume doc>
bash scripts/handover/chief-kit/series-next.sh abandon --ledger <p> --doc <doc> <KEY>
```

- `status` is read-only and takes no `--doc`. One `ITEM` row per item: key, state, the
  ledger's `wip`, commits ahead of `cut_from`, and the PR from gh (looked up by
  `publish_branch`; the ledger keeps no PR copy). It adds `SERIES-DRIFT <key> wip` when
  a worktree HEAD is not what the ledger recorded, `PARENT-ABANDONED <key>` for the item
  after an abandoned one, and `GO-FILE <pr> <path>` when a published item's PR already
  has a GO file under `.locks/go/`.
- `start` takes the `planned` item `<KEY>`, creates its worktree on
  `series/<sid>/<KEY>` cut from the previous item's `wip` (the first item: from
  `origin/main`), locks the worktree so `worktree.sh prune` keeps it, and records the
  branch, worktree, `cut_from`, `wip` and state `authoring`.
- `commit` records the authoring item's worktree HEAD as `wip` and moves it to
  `committed`. The worktree must be clean: git-commit your work first.
- `pass` hands the series to the RESUME doc. It refuses, naming the key and moving
  nothing, while an `authoring` or `committed` item's worktree is dirty, and prints
  `SERIES-DRIFT <key> wip` and refuses while any worktree HEAD differs from the ledger.
- `abandon` marks the item `abandoned`, for a ticket that was split, dropped or NO-GO'd.

## The item's own scope

A follow-on item's scope, do-not lines and commit text live in its ledger item, not in
your brief. `series-next.sh start` prints the item's `scope`, `do_not` and `commit_text` from the ledger item
for the worker that authors it, after its state lines:

```
ITEM-SCOPE <KEY>
  <scope>
DO-NOT <line>
COMMIT-TEXT <text>
```

A field the item does not carry prints nothing, and an item with none of the three
prints no block; the brief's own text then applies. Treat the printed `DO-NOT` lines as
binding as the brief's Do-not section.

## Hand-off at READY

At your item's READY you hand the series on. The order matters, because the context
guard frees a RESUME write past its threshold but not a later call:

1. Write the RESUME doc FIRST. It carries pointers only: the ledger path, the series id
   and the new writer. Branches, shas and states come from `status`.
2. Run `series-next.sh commit` for any item you are still authoring.
3. Run `series-next.sh pass --ledger <p> --doc <doc> <resume doc>`. If it refuses,
   fix what it names (commit the work, or find out why a HEAD moved) and run it again.
4. Append `WRAPPED` to your doc.
5. Stop.

Your successor carries your item's tail (CI, review fixes, GO, merge) and starts the
next item.

## Waiting

Check the previous item's CI at your own boundaries with a short foreground
`check-ci.sh <pr> --max-wait 60`. Run the long blocking wait only when you have nothing
left to write. Nothing runs in the background.
