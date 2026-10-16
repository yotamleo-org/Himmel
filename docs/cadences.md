# Cadences reference

A **cadence** is a recurring job himmel can arm on your machine: a crontab entry
(Linux, macOS) or a scheduled task (Windows) that fires a runner on a schedule.
Every cadence is **off until you arm it**: the install wizard only offers the
ones whose precondition holds, and nothing arms itself.

The wizard menu is not a hand-written list. It reads
`scripts/himmelctl/lib/cadence-registry.json`, one row per cadence, and a
staleness lint asserts each row's script still exists and still exposes
`arm`, `status` and `disarm`. This page is derived from that file; when the two
disagree, the JSON wins.

## The common interface

Every cadence script takes the same three verbs:

```bash
bash <script> arm [--time HH:MM] [--force] [--dry-run]
bash <script> status
bash <script> disarm [--dry-run]
```

- `arm` installs the schedule. It refuses to double-arm (`already armed`);
  `--force` replaces the existing entry. `--dry-run` prints what it would register and registers nothing.
- `status` reports whether the job is armed, its schedule and its last run.
- `disarm` removes exactly what `arm` added.
- Some cadences (`doctor`, the reconcile, failure-review and qmd-quality
  scripts) also accept `run`, one pass, the verb the scheduler calls, so you
  can test the job by hand.

Per-script flags beyond that are in the table. Several cadences also register
themselves with the observability registry so `/himmel-doctor` can warn when a
task silently vanishes.

## Registry cadences (offered by the install wizard)

| Id | Script | Offered when | What it does |
|---|---|---|---|
| `pipeline` | `scripts/luna/pipeline-cadence.sh` | a vault exists | Daily fetch-health, harvest and synthesize, plus weekly health runs against the vault. The one wizard-recommended cadence. `arm --vault <path>` |
| `qmd` | `scripts/luna/qmd-cadence.sh` | a vault exists | Daily qmd update, embed and completeness assert over every configured collection, so the index never goes silently stale |
| `graphmap` | `scripts/luna/graphmap-cadence.sh` | a vault exists | Hourly free structural (AST) refresh, weekly semantic refresh of the vault and himmel graphify graphs, plus a 6-hourly refresh, publish and auto-merge PR for himmel's own graph. Arming it commits to the hourly job. `arm --vault <path>` |
| `vault-stall` | `scripts/luna/vault-stall-cadence.sh` | a vault exists | Every 15 minutes: detect a stalled vault auto-commit, remediate only the known-benign pre-commit refusals, alert on everything else without echoing the secret. `arm --vault <path>` |
| `codex-sweep` | `scripts/cleanup/codex-sweep-cadence.sh` | the codex lane is selected | Recurring sweep of orphaned codex broker and MCP-fleet processes. Daily, default 09:00 local |
| `drift-fix` | `scripts/upstreams/drift-fix-cadence.sh` | always | Nightly `/drift-fix` (bump auto-bumpable pins, open an ordinary PR) and `/fork-resync` (rebase carried forks, audit only). Stops at the PR or audit; never merges. Extra flag `--resync-time` |
| `upstream-watch` | `scripts/upstreams/upstream-watch-cadence.sh` | always | Daily scan of himmel's open upstream PRs and issues for a delta. No Claude session; Telegram-notified only when something changed |
| `doctor` | `scripts/doctor-cadence.sh` | always | Daily `himmel-doctor` run from the primary checkout. A FAIL or a new WARN goes to Telegram and the statusline shows the counts. Report only, fixes nothing. Cron only (Linux, macOS) |
| `repo-sync` | `scripts/sync/repo-sync-cadence.sh` | Windows only | Daily fetch and fast-forward-only pull of every git repo under `--github-root` / `--documents-root`, plus a stale scratch-worktree cleanup pass. Uses `schtasks`; there is no crontab path |
| `pull-cadence` | `scripts/luna-vitals/connectors/pull-cadence.sh` | `GOOGLE_HEALTH_REFRESH_TOKEN` is set | Daily Google Health connector pull to a review artifact. No Claude session. Setup: [luna/google-health-connector-setup.md](luna/google-health-connector-setup.md) |

## Cadences armed by hand (not in the wizard)

These have no wizard row; arm them directly with the same three verbs.

| Script | What it does | Notes |
|---|---|---|
| `scripts/handover/reconcile-cadence.sh` | Periodic seat-liveness check: runs `reconcile-workers.sh --report` and orphans only seats whose pid is confirmed dead past the grace window | `arm [--interval-min N]` (default 10; `N` must divide 60). One crontab entry tagged `HIMMEL-ReconcileCadence`; Windows twin is `reconcile-cadence.ps1` |
| `scripts/eval/leg-digest/failure-review-cadence.sh` | Daily failure review: runs the failure router over recorded worker session failures and shows what failed. No model is run | **Dry-run by default**: a scheduled run files nothing and calls no Jira. `arm --live` opts in to live routing. `arm [--vault PATH] [--live]` |
| `scripts/cleanup/steering-cull-cadence.sh` | Weekly read-only steering-file cull: runs `/writing-for-agents` (headless `claude -p`, plan mode, Read only, behind `bank-preflight.sh`) over himmel `CLAUDE.md`, `~/.claude/CLAUDE.md`, `RTK.md` and the memory index. Writes a dated proposal doc and appends one line naming it to the live supervisor session's bridge inbox: the newest held `*-console` queue lock (`queue-lock.sh status --sweep`), resolved at run time, so a console handover never strands it. No live console, or no inbox for it, raises the shared `cadence-alert.sh` alert instead. Never edits a file | `arm --proposal-dir <dir> [--console <supervisor session>] [--day 0-6] [--time HH:MM] [--backend claude-cli\|claude-api --api-account A\|B\|auto]` (default Monday 07:00). `--console` is an override that pins one session; omit it normally. `--backend claude-api` runs the call through the API lane (API credit, no subscription draw, no `bank-preflight`) and never falls back to the subscription; the default stays `claude-cli`. Medium cuts and any live-file cut are counted as escalated; low repo cuts are listed in the doc, not auto-opened as a PR |
| `scripts/eval/cache-health-cadence.sh` | Hourly scripted prompt-cache health check (no model, no `claude -p`): `cache-health.py` computes per-role hit rate, write share and compactions from session transcripts, writes `~/.himmel/state/cache-health/metrics.json` ([schema](internals/cache-health.md)), and sends ONE Telegram DM plus one line to the live console's bridge inbox only when a threshold is crossed (role hit rate more than 3 points under its 7-day baseline, a 1M-token session under 90 %, legs averaging over 4 compactions). One alert per crossing, one recovery message, no repeats. The console is resolved at run time like the steering cull; a failed run raises the shared `cadence-alert.sh` alert | `arm [--minute 0-59] [--every-hours 1|2|3|4|6|8|12]` (default minute 7, hourly; the interval must divide 24 so cron keeps an even spacing). One crontab entry tagged `HIMMEL-CacheHealth`; `run --dry-run` prints the metrics and the would-send text without sending |
| `scripts/eval/qmd-quality/qmd-quality-cadence.sh` | Weekly qmd retrieval-quality eval; appends metrics and alerts when MRR drops | `arm --golden <file> [--index <file>] [--day 0-6]`. The index snapshot is deleted after every run |

## Choosing

- Start with `doctor` and `upstream-watch`: report-only, no Claude session, no
  writes outside the state directory.
- Add the vault trio (`pipeline`, `qmd`, `vault-stall`) only if you run a
  companion vault.
- `graphmap` and `drift-fix` run Claude sessions or open PRs; read their
  headers before arming.

See also: [setup/updating.md](setup/updating.md) (what `ensure` re-arms),
[configuration.md](configuration.md) (off-switches), and `/pipeline-cadence`
in [commands-catalog.md](commands-catalog.md).
