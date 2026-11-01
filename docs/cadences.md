# Cadences reference

A **cadence** is a recurring job himmel can arm on your machine: a crontab entry
(Linux, macOS) that fires a runner on a schedule.
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
| `drift-fix` | `scripts/upstreams/drift-fix-cadence.sh` | always | Nightly `/drift-fix` (bump auto-bumpable pins, open an ordinary PR) and `/fork-resync` (rebase carried forks, audit only). Stops at the PR or audit; never merges. Extra flag `--resync-time` |
| `upstream-watch` | `scripts/upstreams/upstream-watch-cadence.sh` | always | Daily scan of himmel's open upstream PRs and issues for a delta. No Claude session; Telegram-notified only when something changed |
| `security-audit` | `scripts/security/security-audit-cadence.sh` | always | Weekly read-only diff of existing GitHub, Snyk, Arnica and CodeRabbit findings; optional sources skip. No new scan, paid call or LLM call. `arm --day 0-6 --time HH:MM` (default Monday 07:00). See [setup and sources](#weekly-security-findings-audit) |
| `doctor` | `scripts/doctor-cadence.sh` | always | Daily `himmel-doctor` run from the primary checkout. A FAIL or a new WARN goes to Telegram and the statusline shows the counts. Report only, fixes nothing. Cron only (Linux, macOS) |
| `pull-cadence` | `scripts/luna-vitals/connectors/pull-cadence.sh` | `GOOGLE_HEALTH_REFRESH_TOKEN` is set | Daily Google Health connector pull to a review artifact. No Claude session. Setup: [luna/google-health-connector-setup.md](luna/google-health-connector-setup.md) |

## Weekly security findings audit

`security-audit` reads **existing findings**, never starts a scan, calls a model,
upgrades a subscription or spends a Snyk test. It stays off until armed:

```bash
bash scripts/security/security-audit-cadence.sh run
bash scripts/security/security-audit-cadence.sh arm --day 1 --time 07:00 --dry-run
bash scripts/security/security-audit-cadence.sh status
bash scripts/security/security-audit-cadence.sh disarm --dry-run
```

The default is Monday 07:00, local cron time (Linux/macOS). Remove `--dry-run`
only when you intend to change the schedule. `arm --force` replaces its own
entry; other cron entries are preserved. `run --repo owner/name` or
`run --repo /checkout/path` overrides the primary checkout's GitHub origin.
The wizard row and script expose the same arm/status/disarm interface.

| Source | Probe / free-plan behavior |
|---|---|
| GitHub code scanning, Dependabot, secret scanning | Read-only, paginated `gh api` GETs using gh's existing authentication. Missing tools, inaccessible endpoints, disabled scanners and quota failures each print one `SKIP` line. Secret values and alert descriptions are never persisted; only secret type and location are read into the normalized inventory. `SECURITY_AUDIT_GITHUB=off` skips these API reads. |
| Snyk | Reads the latest dated JSON produced by `snyk-scan.sh`, by default in the same state-repo bucket's `specs/security/snyk/`. Override with `SECURITY_AUDIT_SNYK_DIR`. **Does not run Snyk**, even when the report is missing or over quota; the separate weekly scanner owns the 400-test Open Source allowance. Snyk Code skips retain their own baseline independently. Fork reports are outside this repository audit. |
| Arnica | Reads `arnica.csv` from the export folder. As checked on 2026-10-30, the [documentation index](https://docs.arnica.io/arnica-documentation/llms.txt), [billing page](https://docs.arnica.io/arnica-documentation/platform-operations/billing.md) and [Swagger entry](https://api.app.arnica.io/swagger) did not establish a free-plan findings-read API contract. No speculative API or paid fallback is used. |
| CodeRabbit | Prefers `coderabbit.csv` from the export folder. Otherwise, its [Deep Scan read API](https://docs.coderabbit.ai/api-reference/security-scans-code-list.md) explicitly supports **all plans** with a non-agentic `security:read` key, unlike the general Enterprise API listing. Set `SECURITY_AUDIT_CODERABBIT_REPO_ID` to the exact Git-provider numeric repository ID. The key is resolved internally via `himmel-secrets get --no-dotenv CODERABBIT_API_KEY`; store it through the keyring, not `.env`. The fixed HTTPS endpoint is GET-only, cursor-paginated and does not follow redirects or start scans. No key in argv, logs, reports or generated runners. `SECURITY_AUDIT_CODERABBIT=off` disables API access, not local exports. |

Exports go in `~/.himmel/security-exports/` (override:
`SECURITY_AUDIT_EXPORT_DIR`). Replace each named file atomically with a complete
export of that source's findings, including the repository field; a header-only
export is an authoritative empty inventory. Both observed CSV shapes are
supported: CodeRabbit's `repository,file,start_line,cwe,category,severity,state`
and Arnica's `Severity,Status,Asset,File,Type` (GitHub blob URLs with `#L` lines).
Only open rows for the chosen repository are included. Repository fields accept
`owner/name`, `github://owner/name#branch`, `https://github.com/owner/name`,
and the observed short repository name. An export containing rows but none for
the chosen repository, or any unknown repository shape, skips with a warning and
retains the baseline; it cannot prove closure. These files are untrusted
data: CSV quoting and multiline fields are parsed without executing content;
descriptions, recommendations and secret payloads are ignored. A deleted,
malformed or inaccessible source **retains its last baseline**, never reports all
its rows closed. Skips are visible in both stdout and the dated report.

State and dated reports default to
`~/.himmel/state/security-audit/<owner>/<repo>/` (override:
`SECURITY_AUDIT_STATE_DIR`, which must not be shared by different repositories).
Reports list new, newly closed and severity-escalated rows with file, line,
category, severity and source. Repeating an unchanged export reports zero new
rows. A complete refreshed source is compared with its previous successful
snapshot, not with a forced fresh scan; the cadence cannot detect vendor changes
until that export/report is refreshed. Concurrent runs on the same state skip.
New High/Critical rows, or promotions to those severities, notify through the
existing cadence alert/keyring-backed sender; a failed send leaves the baseline
unchanged for retry. Local state/report failures remain errors.

ponytail: cross-source deduplication requires the same normalized file, line and
category (for example matching CWE or GHSA IDs); unrelated vendor taxonomies
remain separate rather than guessing equivalence. Upgrade path: explicit
reviewed identifier mappings. The highest observed severity and every reporting
source survive an exact match. No absent source is treated as proof of closure.

`arm` captures only the non-secret configuration above and the arming PATH and
handover directory; it never arms the separate Snyk scanner. Runs need Python 3.9+
and Bash, with optional `gh` for GitHub reads.

## Cadences armed by hand (not in the wizard)

These have no wizard row; arm them directly with the same three verbs.

| Script | What it does | Notes |
|---|---|---|
| `scripts/handover/reconcile-cadence.sh` | Periodic seat-liveness check: runs `reconcile-workers.sh --report` and orphans only seats whose pid is confirmed dead past the grace window | `arm [--interval-min N]` (default 10; `N` must divide 60). One crontab entry tagged `HIMMEL-ReconcileCadence` |
| `scripts/eval/worker-digest/failure-review-cadence.sh` | Daily failure review: runs the failure router over recorded worker failures and shows what failed. No model is run | **Dry-run by default**: a scheduled run files nothing and calls no Jira. `arm --live` opts in to live routing. `arm [--vault PATH] [--live]` |
| `scripts/cleanup/steering-cull-cadence.sh` | Weekly read-only steering-file cull: runs `/writing-for-agents` (headless `claude -p`, plan mode, Read only, behind `usage-preflight.sh`) over himmel `CLAUDE.md`, `~/.claude/CLAUDE.md`, `RTK.md` and the memory index. Writes a dated proposal doc and appends one line naming it to the live chief's bridge inbox: the newest held `*-chief` queue lock (`queue-lock.sh status --sweep`), resolved at run time, so a chief handover never strands it. No live chief, or no inbox for it, raises the shared `cadence-alert.sh` alert instead. Never edits a file | `arm --proposal-dir <dir> [--chief <chief>] [--day 0-6] [--time HH:MM] [--backend claude-cli\|claude-api --api-account A\|B\|auto]` (default Monday 07:00). `--chief` is an override that pins one session; omit it normally. `--backend claude-api` runs the call through the API lane (API credit, no subscription draw, no `bank-preflight`) and never falls back to the subscription; the default stays `claude-cli`. Medium cuts and any live-file cut are counted as escalated; low repo cuts are listed in the doc, not auto-opened as a PR |
| `scripts/security/snyk-scan-cadence.sh` | Weekly station run of `snyk-scan.sh`: Snyk Open Source (`snyk test --all-projects`) and Snyk Code over the primary checkout, JSON plus a short summary written to the state repo under `specs/security/snyk/`. A High or Critical finding, or a failed scan (snyk missing, not authenticated, monthly quota reached), raises the shared `cadence-alert.sh` alert; a clean run clears it. On the station a monthly test-count ledger refuses a run that would pass the cap; the GitHub workflow starts every run with an empty ledger, so it is bounded only by its cadence times its count. `snyk-scan.sh --forks` (on demand, and on the first Monday of the month in the `snyk-weekly` GitHub workflow with `--no-upstream`, and on any dispatch; not in this station cadence) scans the forks himmel pins (qmd, graphify, claude-hud, claude-obsidian) at their pinned refs, one report section per fork under `specs/security/snyk/<date>.forks.*`. A station run also scans each tracking fork'"'"'s upstream HEAD and marks each finding fixed upstream or not, but skips any third-party tree (a pinned fork or an upstream HEAD) that holds a gradlew, mvnw, build.gradle*, pom.xml, build.sbt, Package.swift or mix.exs (snyk would run that build tool) and reports the skip. The workflow costs about 16 Open Source tests every Monday for the main scan plus about 48 for the forks on the first Monday, so 112 to 128 of the free 400 in a month; Snyk cannot read `uv.lock`, so those are exported with `uv export` and looked up on osv.dev. Never runs per PR | `arm [--day 0-6] [--time HH:MM] [--force] [--dry-run]` (default Monday 06:30), `status`, `disarm`. Cron only (Linux) |
| `scripts/eval/cache-health-cadence.sh` | Hourly scripted prompt-cache health check (no model, no `claude -p`): `cache-health.py` computes per-role hit rate, write share and compactions from session transcripts, writes `~/.himmel/state/cache-health/metrics.json` ([schema](internals/cache-health.md)), and sends ONE Telegram DM plus one line to the live chief's bridge inbox only when a threshold is crossed (role hit rate more than 3 points under its 7-day baseline, a 1M-token session under 90 %, workers averaging over 4 compactions). One alert per crossing, one recovery message, no repeats. The chief is resolved at run time like the steering cull; a failed run raises the shared `cadence-alert.sh` alert | `arm [--minute 0-59] [--every-hours 1|2|3|4|6|8|12]` (default minute 7, hourly; the interval must divide 24 so cron keeps an even spacing). One crontab entry tagged `HIMMEL-CacheHealth`; `run --dry-run` prints the metrics and the would-send text without sending |
| `scripts/eval/stability-scorecard.sh` | Daily stability scorecard row (no model): measures the last 24 h from `ci-metrics.sh` (CI queue wait p50/p90, failed-job rate, cancelled runner-minute share), failed `CI` runs on main, classifier denials, tickets created on the current version (residuals) and `deferred-escape` tickets (labelled by `scripts/cr/mark-deferred-escape.sh`; the note cell splits them per `class-<id>` and priority), and appends one row per UTC day to `specs/research/stability-scorecard.tsv` in the state repo. A date already recorded is skipped, a failed source reads `unknown` and the run exits 1. `stuck_playbook_hits` is `n/a` (no ledger) | `arm [--hour 0-23] [--minute 0-59]` (default 06:20 daily). One crontab entry tagged `HIMMEL-StabilityScorecard`; the runner exports `HANDOVER_DIR` from the arming shell |
| `scripts/eval/judge-accuracy/judge-accuracy-cadence.sh` | Weekly judge-accuracy run (no model call, no budget draw): reads PR and main-run state with `gh` from the primary checkout, runs `judge_accuracy.py` (one eval-runs row; new adjudication candidates are queued for a judge-ro call to rule), appends the five-question answer row with `decision-158-answers.py`, and renders the reviewer page with `review-page.py` to `~/.himmel/state/review-page/review-page.md` (`REVIEW_PAGE_FILE` overrides), which the config-ui serves at `GET /api/reviewers`. A failed run raises the shared `cadence-alert.sh` alert; a clean run clears it | `arm --verdicts <dir> [--day 0-6] [--time HH:MM] [--force] [--dry-run]` (default Monday 07:30), `status`, `disarm`. One crontab entry tagged `HIMMEL-JudgeAccuracy` |
| `scripts/eval/qmd-quality/qmd-quality-cadence.sh` | Weekly qmd retrieval-quality eval; appends metrics and alerts when MRR drops | `arm --golden <file> [--index <file>] [--day 0-6]`. The index snapshot is deleted after every run |
| `scripts/cleanup/reap-mcp-orphans.sh` | Finds MCP and LSP children (context7-mcp, graphify-mcp, tsserver and similar) whose ancestor chain holds no live owner and logs them to `~/.cache/himmel/reap-mcp-orphans.log`. Report-only by default; `--kill` arms it | Manual and report-only until the SessionEnd hook and the daily sweep are wired after a one-week soak (deferred slices of HIMMEL-1620). Run `bash scripts/cleanup/reap-mcp-orphans.sh` by hand; add `--kill` only after the soak |

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
