---
description: Manage the cron cadence of the luna clip pipeline.
argument-hint: arm|status|disarm [--harvest-time HH:MM] [--synth-time HH:MM] [--health-time HH:MM] [--harvest-model M] [--synth-model M] [--health-model M] [--vault PATH] [--force] [--dry-run]
---

Register the luna clip-pipeline's recurring maintenance runs with the OS
scheduler (Linux/macOS user crontab — HIMMEL-265). Follows the
`arm-resume.sh` precedent (HIMMEL-122): direct scheduler invoke, dedup
guard, runner indirection (`.sh` with `printf %q`-quoted values, crontab
entries marker-tagged `# HIMMEL-Pipeline-*`).

Armed defaults (operator decision pinned on HIMMEL-255; daily harvest job
added on HIMMEL-357; model pins + frequency shift on HIMMEL-506; overridable
via flags):

| Task | Schedule | Model | Runs |
|---|---|---|---|
| `HIMMEL-Pipeline-Harvest` | daily 02:00 | sonnet | `/harvest-clips`, then `/triage-clips` chained in the same session |
| `HIMMEL-Pipeline-Synthesize` | daily 03:00 | sonnet | `/synthesize-clips`, then `/archive-clips` chained in the same session |
| `HIMMEL-Pipeline-Health` | daily 04:00 | haiku | `obsidian-triage:vault-lint` (HIMMEL-1386; `/obsidian-health` stays available for manual use) |

Each job launches with an explicit cheap **`--model` pin** (HIMMEL-506) so the
cadence never inherits the operator's saved default (the scarcest tier) — the
cheap pins are what make the higher frequencies affordable. **Daily**
harvest+triage is cheap and idempotent so it keeps the `Clippings/` inbox
flowing; **daily** synthesize+archive runs every night (synthesis is cheap
enough once model-pinned, so cross-clip themes surface without a week's lag);
**daily** health is the nightly vault check (HIMMEL-1383 — weekly meant vault
drift was only visible once a week, and the haiku pin makes nightly cheap).

Each task launches a **bounded interactive** claude session in the luna
vault — `claude --model <pin> --settings <fragment> "<prompt>" < /dev/null`
(the bounded-run primitive: the session
runs the full turn on stdin-EOF, then exits clean). `status` parses each job's pinned model back out of its runner, so an
armed-but-wrong-model cadence is visible.

**Auto-approve injection (HIMMEL-575).** The runs fire in the luna vault cwd,
which has no himmel `.claude/settings.json` — so without help, an autonomous run
would STALL on the HIMMEL-203 compound-bash permission prompt (the static
matcher bails on any `$var`/`$()`/pipe/compound command, and a `< /dev/null` run has
nobody to answer the prompt). At **arm time** the runner writes a tiny
`cadence-settings.json` next to the `.sh` runners that wires himmel's
`auto-approve-safe-bash` PreToolUse hook by **absolute path**, and each run is
launched with `--settings <that fragment>`. The hook only ever *grants* (it
never blocks), so this widens nothing the block-* deny hooks guard — it just
restores the auto-approve posture in the luna cwd. The fragment is created on
`arm` and removed on `disarm`.

## Guarantees
- **Dedup safeguard:** `arm` refuses (rc=3) if any `HIMMEL-Pipeline-*` task
  already exists; `--force` deletes + replaces (never duplicates).
- **Fail-closed:** any nonzero rc from the dedup listing (`crontab -l`)
  is fatal (rc=2, stderr printed) UNLESS it matches a trusted empty
  signature (rc=1 with empty stderr, or the standard
  `no crontab for <user>` stderr) — a
  failed listing is never silently treated as "nothing armed", so arm
  can't overwrite an armed cadence it failed to see.
- **Fire-time evidence:** each runner writes claude output to a `.log`
  next to it (`pipeline-harvest.log` / `pipeline-synthesize.log` / `pipeline-health.log`),
  rotated per fire (previous run kept as `.log.prev`), stamped
  `[fired <date> <time>]` and capturing `cd` errors — the log exists on
  every fire even if the vault moved; `status` surfaces each log's mtime +
  last line, so "armed but never succeeding" is visible.
- **Persistent runners:** the `.sh` runners live in
  `~/.claude/pipeline-cadence/` (not `/tmp` — cleanup sweeps
  would silently kill a recurring task).
- **No catch-up after a missed start:** a run skipped because the machine
  was off/asleep at the scheduled time does not fire later (that would need
  anacron / a `@reboot` catch-up job).
- **Cron-safe by design:** every pipeline stage is idempotent (markers:
  `harvested_at`, `processed`, synthesis dedup window, `_done/` move), so a
  fired run that finds nothing to do exits clean.
- **Bounded retry/resume (HIMMEL-1152):** a claude job that exits non-zero
  with a transient upstream signature in its own attempt log (`API Error:` +
  server error / overloaded / 5xx / mid-response) is re-invoked up to twice
  (60s then 180s backoff) and resumes through those same idempotent markers;
  any other failure is not retried. Each attempt writes its own flow-run
  ledger row pair tagged `attempt=N/3`, and the job log carries a
  `[retry N/2 …]` line.

Run:

```bash
bash scripts/luna/pipeline-cadence.sh $ARGUMENTS
```

Common invocations:
- `/pipeline-cadence status`
- `/pipeline-cadence arm`
- `/pipeline-cadence arm --harvest-time 01:30 --synth-time 02:30 --health-time 04:30 --force`
- `/pipeline-cadence arm --dry-run`
- `/pipeline-cadence disarm`

Exit codes: 0 done, 1 usage error, 2 env unusable (no `crontab`,
unsupported platform, failed `crontab -l` — also from `status` when any
query errors), 3 dedup block, 4 scheduler invocation failed (crontab
rewrite).
