# steering-cull eval

What does each approved cut of the always-on steering text save, and does the rule it
shortens still hold? The rows are the approved cuts of the steering-cull proposal
(decision 345, `specs/proposal/steering-cull-2026-10-26.md` in the state repo), frozen in
`rows.json` against byte copies of the repo and user `CLAUDE.md` in `fixtures/baseline/`.
A row ships only when its cut does no worse than the baseline on every probe that can see
the rule.

| path | what |
|---|---|
| `rows.json` | one row per approved cut: the operator's row number, its line range, the `old` span and its `cut` text |
| `probes.json` | one question per rule a row carries, with its pass checks (`first`, `must`, `must_not`, `in`) |
| `fixtures/baseline/` | the repo `CLAUDE.md` at 399e7a88, the user `~/.claude/CLAUDE.md` and `RTK.md` it imports |
| `cull.py` | `check`, `build`, `cost`, `summarize`, `rescore`, `valid` and `report` (stdlib, no model call) |
| `run.sh` | the billed behaviour arm, resumable |
| `test-steering-cull.sh` | the suite: a stub `claude` and a stub preflight, no model call |

## The two arms

- **Cost** (no model call): bytes and tokens (UTF-8 bytes / 4) of the always-on text, baseline
  vs every row cut, per row and per file. The repo file is counted without its `## graphify`
  section, which the graphify installer owns. The `MEMORY.md` index and `RTK.md` are constants.
  `AGENTS.md` is regenerated from both repo files with `scripts/agents-md/generate.mjs` and is
  reported apart, since codex reads it. A saved token is priced on the newest 50 session JSONLs
  (`--sessions`, `--last`): one cache write (1.25) plus a cache read (0.1) per later turn, at the
  median turn count, and as a share of the median per-turn cache read.
- **Behaviour** (`run.sh`, billed): each probe runs as a fresh `claude -p` with no tools under
  three arms: BASELINE, CUT (every row cut) and RED (only its row's span deleted). The `red`
  phase runs BASELINE and RED. A probe is **valid** when it passes BASELINE and fails RED by
  majority of reps. The `cut` phase then runs CUT on the valid probes only.

| verdict | meaning |
|---|---|
| SHIP | every valid probe passes CUT at least as often as BASELINE |
| KEEP | a valid probe passes CUT less often: the cut lost the rule |
| SHIP-UNMEASURED | every probe of the row is invalid: the model gives the right answer with the rule gone, so no probe can see the rule |
| UNPROBED | no probe (the LOW rows ruled cost-only) |
| PENDING | a probe of the row lacks its runs |

The child sees only the arm's text: its cwd `<arm>/repo` holds the repo `CLAUDE.md`, the parent
holds the user `CLAUDE.md` and `RTK.md`, and `--setting-sources project` keeps the real
`~/.claude/CLAUDE.md` out. With no tools there are no hooks and no memory. A rule that a hook
enforces (`r1`, `l64`) or that memory repeats (`l65`) is therefore measured without that backup.

## Running

`run.sh` makes real, billed model calls, so it needs `HIMMEL_BILLED_OK=1`. Before each probe
`usage-preflight` must print `PROCEED`, and `--ceiling <cost-eq>` stops the sweep before the
call that would pass it. Defaults: sonnet, effort medium, 3 reps.

```bash
out=~/.himmel/eval/steering-cull/<date>
HIMMEL_BILLED_OK=1 bash scripts/eval/steering-cull/run.sh --phase red --out "$out" --ceiling 1500000
HIMMEL_BILLED_OK=1 bash scripts/eval/steering-cull/run.sh --phase cut --out "$out" --ceiling 1500000
python3 scripts/eval/steering-cull/cull.py report --runs "$out" --memory <MEMORY.md> --ledger
```

After a probe's checks change, `cull.py rescore --runs "$out"` re-scores the saved replies
without a call. A change to a row's span or cut, or to a probe's prompt or checks,
changes the ledger row's `rows_sha` / `probes_sha`, so runs before and after it never read as
one series; comment and note keys do not count.

## First run (2026-10-26, sonnet, effort medium, 3 reps, $0.92)

Ledger row `20261026T205437Z-steering-cull-ea2b9d`, written at the eval's first commit. 16 rows: 3 SHIP (`r2-trailers`, `r3-jira`,
`r5-invariants`), 8 SHIP-UNMEASURED, 5 UNPROBED, no KEEP. All cuts together save 608 of 4,381
always-on tokens, about 3,800 cost-eq per session (0.6 % of a turn's cache read); AGENTS.md
drops from 9,540 to 7,577 bytes. Four of 13 probes were valid. Every forced-choice probe
(`r4`, `r5-one-writer`, `r6`, `l65`, `u8`, `u9`, `u11`, `u12`) passed with its rule deleted:
sonnet answers those from general judgement, so the cut cannot be seen to cost anything there.
