# fold-vs-keep eval

Is a recurring subagent class worth its cost? For each class this eval runs the
KEEP arm (what the harness dispatches today) and a FOLD arm (a cheaper tier, the
work done inline in the parent, or a script) on the same golden tasks, several
times each. The decision reads the tasks that flip, not the mean: a class may
fold only when no task does worse in the fold arm.

| class | keep | fold | tasks | how the runs are made |
|---|---|---|---|---|
| `judge` | opus judge-ro | sonnet judge-ro | `fixtures/tasks/judge.json`, 12 | `run.sh --class judge`: fresh `claude -p` replays on frozen evidence |
| `publisher` | haiku board/FOCUS publisher child | the chief publishes inline | `fixtures/tasks/publisher.json`, 12 | observational: `fvk.py publisher` reads existing transcripts, no new publish |
| `vm` | sonnet VM-proof child | a proof script the chief runs | `fixtures/tasks/vm.json`, 10 | `run.sh --class vm`: fresh child runs and `fixtures/tasks/vm-scripts/<id>.sh` on the test VM |

| path | what |
|---|---|
| `fixtures/tasks/*.json` | the golden tasks, each from a real subagent transcript (`source` / `historic`, under `~/.claude/projects`); `{HOME}` in a field is the invoking user's home |
| `fixtures/key/truth.json` | the answer per task: the judge verdict the PR's later history bears out, the VM proof's real result |
| `fixtures/tasks/vm-scripts/` | the fold arm's proof scripts; `_lib.sh` holds the shared VM helpers, `_7147-trial.sh` is a frozen trial script |
| `fvk.py` | `brief`, `summarize`, `publisher` and `score` (stdlib, no model call) |
| `run.sh` | one sweep of one class, resumable |
| `test-fold-vs-keep.sh` | the suite: a stub `claude`, a fixture repo and stub proof scripts, no model call and no VM |

## Running

`run.sh` makes real, billed model calls, so it needs `HIMMEL_BILLED_OK=1`. Before
each task `bank-preflight` must print `PROCEED`, and `--ceiling <cost-eq>` stops the
sweep before the call that would pass it.

```bash
HIMMEL_BILLED_OK=1 bash scripts/eval/fold-vs-keep/run.sh --class judge --out ~/.himmel/eval/fold-vs-keep/<date> --ceiling 6000000
HIMMEL_BILLED_OK=1 bash scripts/eval/fold-vs-keep/run.sh --class vm --out ~/.himmel/eval/fold-vs-keep/<date> \
    --repo <primary checkout> --arms fold --reps 2
python3 scripts/eval/fold-vs-keep/fvk.py publisher --tasks scripts/eval/fold-vs-keep/fixtures/tasks/publisher.json >pub.json
python3 scripts/eval/fold-vs-keep/fvk.py score --tasks scripts/eval/fold-vs-keep/fixtures/tasks \
    --key scripts/eval/fold-vs-keep/fixtures/key/truth.json --runs ~/.himmel/eval/fold-vs-keep/<date> \
    --publisher-rows pub.json --inline-cost-eq 2375
```

- **judge:** each replay gets a scratch git repo holding only the judged head's
  ancestry, so no later commit gives the outcome away. It also gets the PR diff
  and the task's frozen evidence. `gh`, fetch and web tools are denied. A run whose
  successful tool call touched a leak path (verdicts, the live checkouts, transcripts)
  is not scored.
- **vm:** both arms use the after-report clone `himmel-ar-2`, restored to
  `suite-ready-v4`, under its vm-lock. The guest is driven only through
  `guest-exec.sh` and `vmsdk.py push`. A task with a `head` gives the keep child a
  host bundle of that commit (and its `tags`), the same thing the fold arm's `stage`
  builds. The historic child run counts as one keep run.
  Reading the primary checkout is not a leak for this class: it is the task's own repo.
  A fold run costs its script's authoring cost-eq (`author_cost_eq`), which is an
  upper bound for a class that runs again: the script is reused.
- **publisher:** the inline cost is the parent-context growth HIMMEL-6825 measured
  for a delegated publish (median 1.9k tokens, priced as one cache write). The
  launch and hand-back are about the same size as an inline call and its result.
