# himmel observability Phase A

Phase A is a local, passive Prometheus/Grafana stack. The flow exporter is a
tiny Bun HTTP server bound to `127.0.0.1:9877`; Prometheus scrapes it every
60s.

## Passivity invariant

The exporter is a pure reader. It never writes ledgers, never mutates the vault,
never starts or kills processes, and never enforces quota or flow policy. Missing
data stays missing: metric families are omitted when their substrate is absent,
with two explicit-zero exceptions so a quiet, healthy state renders Normal in
Grafana rather than NoData: `flow_run_in_flight{flow} 0` for a silent
configured flow, and `hook_chain_budget_events_recent{action} 0`
when no hook-chain skip log is found anywhere.

The session substrate keeps that boundary intact: the ledger is
written by a separate hook-side script (`session-run-hook.ts`) riding existing
hook chokepoints, and the exporter only reads it. `GET /sessions.json` is a
second read shape, not a second responsibility.

Flow outcome counters are folded from the sliding 14 day ledger window at scrape
time, reading both `flow-runs.jsonl` and `flow-runs.jsonl.1`. The
`flow_run_outcome_total` family keeps the counter name and type the ratified
design (§3) pins, but its values are WINDOW-FOLDED: they decrease when rows age
past 14 days, which Prometheus reads as a counter reset — `rate()`/`increase()`
then briefly overcount around a slide. For the war-room panels (7d ranges over
a 14d window, low row churn) that artifact is small and accepted; if it ever
misleads, the fix is in-process monotonic accumulation in the collector child, not a family rename here.

The truncated / error / stalled alerts do NOT read `flow_run_outcome_total`
(HIMMEL-1634). They read two event-time families built from the same fold:
`flow_run_last_failure_timestamp{flow,outcome}` (epoch seconds of the newest
`truncated` or `error` end row in the window; absent when there is none, so an
expiring old failure simply disappears and cannot page) and
`flow_run_stalled_current{flow}` (unpaired starts past their deadline right now,
0 once the run ends or ages out). `HimmelFlowRunTruncated` / `HimmelFlowRunError`
fire while `time() - flow_run_last_failure_timestamp < 900`; `HimmelFlowRunStalled`
fires on `flow_run_stalled_current > 0`. `flow_run_outcome_total` stays for dashboards.

Unpaired `start` rows older than a flow deadline are split by liveness: a row whose pid is confirmed dead on this host is exported as
`abandoned` — real hygiene information, but nothing is hung and no human can
act, so it must not page; every other expired row (pid alive, unprobeable, no
pid, or minted on another host) is exported as `stalled`. The flow-run ledger
itself never contains `stalled` or `abandoned`.

## Configuration

Default config path:

```text
~/.himmel/observability.json
```

Override:

```text
HIMMEL_OBSERVABILITY_CONFIG=/path/to/observability.json
```

Shape:

```json
{
  "flows": [
    {
      "name": "pipeline-harvest",
      "cadence_seconds": 86400,
      "stall_deadline_seconds": 7200
    }
  ],
  "expected_tasks": [
    "himmel-pipeline-harvest"
  ],
  "vault_path": "C:/Users/you/Documents/luna",
  "sessions": {
    "stale_after_seconds": 900
  },
  "quota_sources": {
    "claude_cache_path": "/tmp/claude/statusline-usage-cache.json",
    "codex_sessions_dir": "C:/Users/you/.codex/sessions",
    "glm_ledger_path": "C:/Users/you/.himmel/quota-gauge.jsonl"
  }
}
```

Rules:

- `stall_deadline_seconds` wins when present.
- Otherwise the stall deadline is `2 * cadence_seconds`.
- Unknown flows seen only in the ledger default to a 6 hour stall deadline.
- Missing config is valid; the exporter still serves metrics derivable from
  ledgers alone.
- `expected_tasks` names the tasks the cadence scripts arm. `himmel-doctor`
  reads it; the exporter does not.
- `vault_path` is optional. Without it, Luna backlog metrics are omitted.
- `sessions.stale_after_seconds` is the transcript-inactivity threshold that
  flips a live session to dead. It defaults to 900.
- `quota_sources` is optional; every key has a derived default (claude:
  `$CLAUDE_USAGE_CACHE`, else `<tmp>/claude/statusline-usage-cache.json`;
  codex: `~/.codex/sessions`; glm: the quota-gauge ledger path).

## Metrics

Flow metrics are derived from `~/.himmel/flow-runs.jsonl` unless
`HIMMEL_FLOW_RUNS_LEDGER` overrides the path.

Daily clip-source fetch health is read passively from
`~/.himmel/fetch-health.json` unless `HIMMEL_FETCH_HEALTH_STATE` overrides the
path. The no-LLM probe runner writes one exact status per source:
`ok`, `auth-or-cookie-expired`, `blocked-or-rate-limited`, or `transport-fail`.
The exporter exposes:

- `clip_fetch_source_status{source,status}` — one-hot current classification.
- `clip_fetch_source_last_success_timestamp{source}` — epoch seconds of the
  latest successful known-good probe, preserved across later failures.

A missing state file omits both families. Malformed state also fails soft: the
scrape remains available and includes a `# clip_fetch_source_* omitted: ...`
comment. Probe response bodies and credential values are never exported.

Per-session tool-call health is read from
`~/.himmel/tool-call-census.jsonl` unless `HIMMEL_TOOL_CENSUS` overrides the
path. `scripts/observability/tool-call-census.sh` writes that file by folding
Claude Code session transcripts; the exporter never runs it. Rows whose
`ended_at` falls outside a trailing 24h window are ignored, and a row with no
parseable `ended_at` is dropped rather than dated to now. The exporter
exposes:

- `himmel_tool_calls_total{tool,project}` — tool calls in the window. MCP
  tools appear under their namespaced name (`mcp__qmd__query`), so per-server
  volume needs no second collector.
- `himmel_tool_errors_total{tool,project}` — errored tool results for the same
  tools. An explicit `0` means the tool ran cleanly, never that the census is
  absent.
- `himmel_tool_denials_total{class,project}` — guardrail denials by class: the
  hook name for a `PreToolUse:… hook error:` result, plus
  `auto-mode-classifier`, `user-rejected`, and `hook-unclassified` for a
  denial whose reason carries no nameable token.
- `himmel_tool_denial_sessions{guard,project}`,
  `himmel_tool_denial_max_per_session{guard,project}` and
  `himmel_tool_sessions{project}` (HIMMEL-6036) — the distinct-session view of
  the same denials: sessions with at least one denial by the guard, the most
  denials one session took from it, and the census sessions in the window
  (the denominator). `guard` carries the same value as `class` above.
  `HimmelGuardDenialShareHigh` fires when a guard hit more than 25 % of
  sessions; `HimmelGuardDenialRepeat` when one session took 3 or more denials
  from one guard. These three are plain gauges re-folded each scrape.

Like `flow_run_outcome_total`, these three are WINDOW-FOLDED counters: values
drop as sessions age out of the 24h window, which Prometheus reads as a
counter reset. A missing census file omits all three families; an unparseable
row is skipped with a `# himmel_tool_* partial: ...` comment rather than
costing the family.

Hook-chain budget pressure is read from
`.claude/logs/hook-chain-skips.jsonl`. By default the exporter folds the
primary checkout's own log together with every worktree's log
(`.claude/worktrees/*/.claude/logs/hook-chain-skips.jsonl`, summing per-action
counts across all of them) — a worktree session writes to its OWN
`.claude/logs`, invisible to the primary checkout's log otherwise. `RUN_HOOK_CHAIN_SKIP_LOG` overrides this to mean exactly one
file — the same override `scripts/hooks/run-hook-with-bash.js`'s own writer
honors, so it is the shared escape hatch for pointing both the writer and the
reader at one log when they run from different roots. Each row records one
hook-chain member that blew its time budget: `action` is `skip` (the guard
silently did not evaluate the tool call) or `deny` (the tool call was refused
fail-closed). The exporter folds rows whose `ts` falls in the trailing
10-minute window (a row more than 5 minutes in the future is dropped as clock
jitter, same grace as the tool census) into:

- `hook_chain_budget_events_recent{action}` — a GAUGE, deliberately NOT a
  window-folded counter: a folded counter reads its own window slide as a
  reset, which is how `increase()` invents phantom spikes. Once at least one
  log in the fold was readable, both actions (`skip`, `deny`) are emitted, `0`
  included, so a quiet box renders Normal rather than NoData; when every log
  that exists failed to read, neither series is emitted at all, and the two
  Grafana rules reading this metric use `noDataState: NoData` for exactly that
  case.

No log found anywhere emits both actions at `0` plus a
`# hook_chain_budget_events_recent: skip log absent, reporting 0` comment.
That is a limitation, not proof of a healthy fleet: `run-hook-with-bash.js`'s
`logChainSkip` swallows every write error by design (logging must never be
able to gate a tool call), so a writer that could never create the file in the
first place looks identical on disk to a checkout that has simply never
starved a chain member. A writer-health beacon that would
close that gap is a planned follow-up. A log that exists but cannot be read omits the whole family
with a `# hook_chain_budget_events_recent omitted: ...` comment — a fault
worth alerting on, which is why the Grafana rules do not treat that absence
as healthy — unless at least one OTHER log in the fold was readable, in which
case its counts still render and a
`# hook_chain_budget_events_recent partial: ...` comment names how many logs
were unreadable; an unparseable row inside a readable log is skipped with its
own `# hook_chain_budget_events_recent partial: ...` comment rather than
costing the family, same fail-soft contract as the tool census.

- `hook_chain_skip_log_unreadable` — a GAUGE, always emitted, `0` when
  healthy (a `#` scrape comment is not
  alertable, so the two failure classes above used to have no real series a
  rule could fire on). Counts, at scrape time, each path that exists but
  could not be read, plus `1` if `.claude/worktrees` exists but could not be
  enumerated — an absent worktrees directory (an adopter with none) and an
  absent log both contribute `0`. A non-zero value means
  `hook_chain_budget_events_recent` may be under-counting and the budget
  alerts cannot be trusted while it is set.

Lane quota gauges (`lane_quota_used_pct{lane,bank,window}`) read
real bank sources via `scripts/observability/quota-sources.ts`: the claude
bank from the statusline usage cache (5h + weekly windows), the codex bank
from the newest `~/.codex/sessions` rollout `rate_limits` row (weekly;
`used_percent` is emitted verbatim — live-verified USED semantics), and the
glm bank from the quota-gauge ledger (`~/.himmel/quota-gauge.jsonl`, or
`HIMMEL_QUOTA_GAUGE_LEDGER`). Each `scripts/lanes/lanes.json` lane that
declares `quota.bank` emits one series per live window of its bank; every
reading is gated on a live `resets_at`/`reset_at` (an expired window is
omitted, never re-emitted). Lanes without a machine-readable quota source —
and banks with no live reading — appear as explicit
`# lane_quota_used_pct omitted: ...` comments instead of fabricated values.

Luna backlog walks are cached for 60s. The flow ledger fold
runs on every scrape so in-flight age and stall inference are fresh.

`quiet_run_orphan_count{kind="suite"|"tail"}` is the orphan signal,
read straight from `/proc` by `quiet-run-orphans.ts` (report-only, never signals
a process; a scan is ~15 ms). `kind="suite"` counts a `quiet-run.sh` wrapper, or a
process holding a `quiet-run-*.log` open for writing, that has been reparented to
init/`systemd` (its owning session is gone, or its wrapper was SIGKILLed).
`kind="tail"` counts `tail -f` followers of a `quiet-run-*.log` that no process
holds open for writing. Linux only: elsewhere, or when `/proc` is unreadable,
the family is omitted with a `# quiet_run_orphan_count omitted: ...` comment.
A suite launched on purpose from a systemd unit or a `setsid`/`nohup` is
counted too, and a log written by a different user reads as writer-less.

`luna_git_unpushed_commits`/`luna_git_uncommitted_files` are a
local-refs-only divergence read of the `vault_path` git clone, cached for 60s
alongside the Luna backlog walk:

- `luna_git_unpushed_commits` - `git rev-list --count @{u}..HEAD`. Omitted
  (no sample, not a fabricated `0`) when the branch has no upstream
  configured. This is the exact signal for a known incident: an
  auto-sync push silently blocked by a gitleaks false positive, so
  auto-committed commits piled up unpushed with zero visible signal. No
  fetch is ever run — a true "behind" count needs a fetch, which would
  violate the passivity invariant above, so it is intentionally not
  implemented.
- `luna_git_uncommitted_files` - line count of `git status --porcelain`;
  catches a commit-gate block, complementing the push-gate signal.

Any git error, missing repo, or timeout omits the whole family with an
explanatory `# luna_git_* omitted: ...` comment, the same fail-soft contract
as the other families.

## Eval results

The exporter reads the eval-runs ledger (`~/.himmel/eval-runs.jsonl`, or
`$HIMMEL_EVAL_RUNS_LEDGER`; writer `scripts/eval/lib/eval_runs.py`) and exports
one series set per eval. Passive read like every family here; an absent ledger
omits the whole family, an unparseable line is skipped and counted in a
`# himmel_eval_* partial:` comment.

The candidate is the eval's newest `ok` row. Its baseline is the newest earlier
`ok` row with the same `confighash`, the pick `scripts/eval/eval-compare` makes.

| Series | Labels | Meaning |
|---|---|---|
| `himmel_eval_metric_value` | `eval`, `metric` | latest ok value (null metrics omitted) |
| `himmel_eval_metric_ci_lower` / `_ci_upper` | `eval`, `metric` | CI bounds, only when the run recorded one |
| `himmel_eval_run_samples` | `eval` | `n` of the latest ok run |
| `himmel_eval_metric_baseline_delta` | `eval`, `metric` | value minus baseline; absent with no baseline |
| `himmel_eval_metric_regression` | `eval`, `metric` | 1 = worse than baseline beyond the noise band, 0 = within it; absent when ungated |
| `himmel_eval_last_run_age_seconds` | `eval` | seconds since the newest row of any status |
| `himmel_eval_last_run_ok` | `eval` | 1 when the newest row is `ok` |

The regression gauge ports `eval-compare`'s verdict: CI bounds when the ledger
has them, else the band in `scripts/eval/eval-compare.json`
(`HIMMEL_EVAL_COMPARE_THRESHOLDS` overrides the path). A metric with no
direction there is never gated; an unreadable (or non-object) thresholds file
omits only `himmel_eval_metric_regression`, with a comment, and the other
series still export. A newest row that is `partial`/`inconclusive` leaves the values
on the last ok run and shows as `himmel_eval_last_run_ok 0`.

**Rules** (Prometheus `alerts.rules.yml`, Grafana twin in
`provisioning/alerting/rules.yaml`, both `warn`, `noDataState: OK`):

- `HimmelEvalRegression`: `himmel_eval_metric_regression == 1` for 10m. It
  holds until a newer ok run clears it.
- `HimmelEvalStale`: no run in 14 days, for the evals named in the selector's
  regex (`qmd-quality` today). Add an eval to the regex in both copies when it
  gets a timer; an eval run only by hand must stay out.
- `HimmelEvalAbsent`: a scheduled eval with no
  `himmel_eval_last_run_age_seconds` series at all for 1h (never ran, or the
  ledger is gone), while `up{job="flow-exporter"} == 1`. One
  `absent_over_time` per scheduled eval; the exporter does not know the
  schedule, so the eval name is written in the rule: add it here too when an
  eval gets a timer.

**Dashboard:** the `Eval results` row in `himmel-health` (a score table with CI,
delta and a worse-than-noise flag, plus days since each eval last ran).

**Deploy (VM first, not done by this change):** the exporter, rules and dashboard
reach the station only through the stack's own install path. (1) On a test VM
run the three suites below, run `promtool check rules alerts.rules.yml` and
`promtool test rules alerts.rules.test.yml` with a real promtool (the suites
skip when it is absent), append a fixture row to the VM's ledger, and confirm
`curl -s 127.0.0.1:<port>/metrics | grep himmel_eval_`. (2) Only after the
operator's go: restart the exporter and reload Prometheus/Grafana, then
re-import `himmel-health.json`.
Suites: `flow-exporter.test.ts`, `test-promtool-validation.sh`,
`test-dashboard-lint.sh`.

## Live sessions and subagents

Three session populations exist in this harness, with three different owners:

1. **Pipeline-cadence workers** (harvest/synthesize/health/armed-resume/vitals) —
   `flow-runs.jsonl`, the Flows row above.
2. **Dispatched lane workers** (GLM/claudex) — their own per-session
   `meta.json`/`outbox.jsonl` under the bridge root.
3. **Interactive/foreground Claude Code sessions and the Task-tool subagents
   fanned out inside them** — this section. Nothing tracked these before: a
   process-tree `class="claude"` reading is a *sum* over every process wearing
   that class and cannot say how many distinct sessions are alive, which have
   subagents under them, or which one died three hours ago instead of
   finishing.

### The ledger

```text
~/.himmel/session-runs.jsonl            (override: HIMMEL_SESSION_RUNS_LEDGER)
```

Same shape discipline as `flow-runs.jsonl`: append-only JSONL, a fixed field
list in a fixed order, rotation at 10MB into `.jsonl.1` (both files are read).
Written by `session-run-hook.ts` (below); read by the exporter. Four row kinds,
schema `v: 2`:

| kind / ev | fields |
|---|---|
| `session` / `start` | `v`, `kind`, `ev`, `session_id`, `cwd`, `transcript_path`, `host`, `started_at`, `pid`, `source`, `permission_mode` |
| `session` / `end` | `v`, `kind`, `ev`, `session_id`, `ended_at`, `reason`, `permission_mode`, `model`, `effort`, `duration_s`, `tool_calls`, `tool_call_errors`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `context_tokens` |
| `subagent` / `start` | `v`, `kind`, `ev`, `subagent_id`, `parent_session_id`, `subagent_type`, `description`, `started_at` |
| `subagent` / `end` | `v`, `kind`, `ev`, `subagent_id`, `parent_session_id`, `ended_at`, `outcome` |

`v: 2` only ADDS fields, so v1 rows written before 2026-08-16 stay readable and
the exporter accepts both versions. Everything new on the end row is DERIVED
and nullable — one bounded pass over the session transcript at teardown, never
a guess:

- `model` / `effort` — last assistant turn's `message.model` and top-level
  `effort` (a payload field of the same name wins if a future harness build
  starts carrying one). The SessionEnd payload carries neither today.
- `input_tokens` / `output_tokens` / `cache_read_tokens` — SUMMED across the
  session's assistant turns (consumption).
- `context_tokens` — NOT a sum: the LAST turn's `input + cache_read +
  cache_creation`, i.e. how full the context window was at teardown.
- `tool_calls` / `tool_call_errors` — `tool_use` blocks and `tool_result`
  blocks with `is_error: true`. Subagent (`isSidechain`) records live in the
  same transcript, so these are whole-session totals including fan-out.
- `duration_s` — first to last transcript record the pass parses (first model
  turn to last), not the true SessionStart instant, which the transcript does
  not record. Join the start row if that gap matters.
- `source` (start) — `startup` / `resume` / `clear` / `compact`, straight off
  the payload; it separates a real start from a re-entry into the same id.

Cost, measured 2026-08-22: 196 ms end-to-end (bun startup included) on the
largest transcript in the live corpus, 69 MB; ~95 ms on a typical one. The
SessionEnd hook timeout stays at 10 s — a 50x margin. Reads above
`TRANSCRIPT_MAX_BYTES` (200 MB) are skipped rather than attempted.

- `reason` is normalized into a closed enum: `clear`, `logout`,
  `prompt_input_exit`, `other`. Anything else becomes `other` — it is a
  Prometheus label downstream, and an open label is a cardinality explosion.
- `outcome` is `success` / `error` / `unknown`, classified coarsely from the
  Agent tool response (an `is_error` flag). Unclassifiable is `unknown`, never
  an assumed success.
- `subagent_id` is the payload's native `tool_use_id` when present — the exact
  correlator shared by the Pre and Post hook events. Without it, the writer
  falls back to a 12-hex sha256 of `session_id` + `tool_input`, which pairs
  deterministically but collides for two identical dispatches from one session
  (the live *count* stays right; only per-instance identity blurs).
- `pid` is best-effort and nullable: a SessionStart hook is a grandchild of the
  Claude Code process and is not handed its parent's pid. Nothing depends on it.
- `description` is truncated to 200 characters — the ledger wants a handle, not
  a copy of every dispatch brief.

### Wiring the writer

`session-run-hook.ts` is a pure writer: it appends one line and exits. It is
fail-open on every path (exit 0, empty stdout, no `permissionDecision`), so a
telemetry gap can never block or slow the tool call it rides on. Four hook
entries, all additive to chokepoints that already exist:

```jsonc
// SessionStart array (.claude/settings.json)
"bun \"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts\" session-start"
// SessionEnd array
"bun \"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts\" session-end"
// PreToolUse, matcher "Agent"
"bun \"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts\" subagent-start"
// PostToolUse, matcher "Agent"
"bun \"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts\" subagent-end"
```

Until those entries are wired, the ledger stays empty, every session family is
omitted, and `session_runs_ledger_rows` reads 0 — the exporter degrades to
silent, never to a fabricated reading.

### When the writer fails: `session-runs.errors.log`

```text
~/.himmel/session-runs.errors.log       (override: HIMMEL_SESSION_RUNS_ERROR_LOG)
```

Fail-open used to mean fail-SILENT, and that cost five days. Between
2026-08-16 and 2026-08-22 the hook exited 0 on every invocation and wrote
nothing: `main()` was a floating `main().catch().finally()` around
`await Bun.stdin.text()`, and under Bun 1.4.0 a pending stdin read does not ref
the event loop, so Bun drained it and exited before stdin was ever consumed.
Nothing anywhere recorded a problem. The stdin read is synchronous now
(`readFileSync(0)`), which cannot lose that race — and every swallowed failure
leaves one bounded line here first:

```text
2026-08-22T04:52:10.539Z session-start SyntaxError: JSON Parse error: Unexpected identifier "not"
2026-08-22T04:52:10.770Z session-end Error: EISDIR: illegal operation on a directory, read
```

One line per failure, message capped at 500 chars and flattened to a single
line, the file capped at 256 KB (past that, new lines are dropped rather than
rotated — this is a breadcrumb trail, not a second ledger). The logger itself
cannot throw, and the hook still exits 0. An unreadable transcript costs the
enriched fields, not the row: the v2 end row lands with nulls.

If the ledger ever goes quiet again, this file is the first place to look —
and if it is empty while the ledger is stale, the hook is not being invoked at
all (check the four `.claude/settings.json` entries and that `bun` is on the
hook's PATH).

### Liveness: transcript mtime, not wall clock

**The record that never gets written is the important one.** SessionEnd is a
graceful-exit hook: a crash, an OOM, a SIGKILL, or a wedged session the
operator eventually closes the window on emits `session_start` and *no*
`session_end`, ever. A purely start/end-paired ledger cannot express that, and
only recording clean completions would be useless.

The flow fold's rule (unpaired start past `cadence*2` = stalled) does not
transfer: an interactive session has no cadence and can legitimately sit idle
waiting on the operator — thinking, on a permission prompt, at lunch. Wall
clock alone cannot tell that from a crash. The transcript file can: it advances
exactly while, and only while, the session is doing something, independent of
whether any hook fires cleanly at exit.

- unpaired start, transcript mtime **fresh** → `running`
- unpaired start, transcript mtime **stale** → `dead`
- start with a matching end row → `ended`, tagged by `reason`

Freshness defaults to 15 minutes and is operator-tunable:

```json
{ "sessions": { "stale_after_seconds": 900 } }
```

Too short flags a thinking session as dead; too long delays real-crash
detection. A transcript that cannot be read at all is not evidence of life —
the session's own age is measured against the same threshold instead, so a
session whose transcript never appeared ages into `dead` rather than counting
as live forever.

### Metric families

Aggregated only. `session_id` and `subagent_id` are unique per occurrence and
unbounded over time, so they are **never** Prometheus labels.

- `session_active_total{host}` — sessions running per the rule above.
- `session_dead_total{host}` — crashed/orphaned/wedged sessions. It
  only counts a dead session for `SESSION_DEAD_ALERT_TTL_SECONDS` (24h) after
  it went dead, so `HimmelSessionDead` fires for recent deaths, not the whole
  14d ledger backlog — the dashboard-facing `/sessions.json` status stays
  `dead` for the full window regardless. `HimmelSessionDead` is
  `severity: warn`, not `page` — the himmel end-row hook is already on the
  detach/enqueue path, yet ghost sessions (transcript idle,
  no end row) still occur, traced to the SessionEnd envelope
  cancellation upstream of this repo's hooks; neither pid (never populated
  in a SessionStart hook payload) nor the transcript carries a crash-vs-
  clean-exit signal this exporter can honestly act on. Severity alone does
  NOT reduce Telegram noise under the flat notification policy (every
  severity shared one repeat_interval) — `provisioning/alerting/policies.yaml`
  now carries a nested `severity = warn` route dropping the repeat interval
  to 168h (7d) instead of the page-level 12h, so warn alerts still deliver,
  just far less often. Revisit once the upstream cancellation is fixed.
- `session_end_outcome_total{reason}` — graceful exits in the sliding 14d
  window (same window-fold caveat as `flow_run_outcome_total`).
- `subagent_active_total{host,subagent_type}` — subagents with an unpaired
  start row **under a still-running parent**. The parent qualifier is
  deliberate: a subagent whose parent crashed can never emit its end row, and
  an unqualified reading would pin phantom subagents live for the whole window.
  `host` is joined through the parent session's start row; the subagent rows
  carry no host of their own.
- `subagent_outcome_total{subagent_type,outcome}` — subagent completions in
  the window.
- `session_runs_ledger_rows` — parsed rows in the window, exporter self-health
  parity with `flow_exporter_ledger_rows`.

Hosts observed in the window keep a zeroed sample, so a dead-session alert
stays evaluable after the last live session on that host goes away. Label
values that originate in hook payloads (a hostname, a `subagent_type`) are
stripped of control characters and bounded at 64 chars before rendering —
`escLabel` does not escape carriage returns, which would otherwise inject a new
exposition line.

### Per-session detail: `GET /sessions.json`

The exporter serves the per-session view the metric families deliberately
cannot carry:

```text
http://127.0.0.1:9877/sessions.json
```

```json
{
  "v": 1,
  "generated_at": "2026-08-07T09:00:00.000Z",
  "stale_after_seconds": 900,
  "ledger_rows": 42,
  "sessions": [
    {
      "session_id": "a1b2c3d4-...",
      "cwd": "C:\\Users\\you\\Documents\\github\\himmel",
      "host": "OVERLORD8",
      "started_at": "2026-08-07T06:00:03Z",
      "status": "running",
      "end_reason": null,
      "age_seconds": 10797,
      "last_activity_seconds": 42,
      "subagents_started": 3,
      "subagents_active": 1
    }
  ]
}
```

Same passive read, same ledger, same liveness rule — one reader, so the table
and the gauges can never disagree. `last_activity_seconds` is `null` when the
transcript is unreadable, never 0. To render this as a Grafana table, add an
Infinity/JSON datasource pointed at that URL; the dashboard ships the stat
tiles (Prometheus-backed) plus a text panel naming this endpoint.

## Install on Linux

Opt-in: set `"observability": {"grafana": true}` in `~/.himmel/config.json`, then
`himmelctl ensure observability-grafana` (or run
`bash scripts/observability/install-grafana.sh install|status|uninstall` directly).
Until opted in the item reads n/a, never red. macOS is deferred.

It installs nothing as root. Pinned upstream tarballs (Prometheus 3.15.0,
Grafana 13.2.3; amd64 and arm64) are downloaded to
`${XDG_DATA_HOME:-~/.local/share}/himmel/observability`, verified against the
sha256 pins in the script (a mismatch aborts before anything is installed), and
run as three systemd **user** units, all bound to loopback:

| Unit | Port | Role |
|---|---|---|
| `himmel-observability-prometheus.service` | 9090 | scrapes flow-exporter, evaluates `alerts.rules.yml`; capped at 30d / 5GB retention |
| `himmel-observability-grafana.service` | 3000 | serves the provisioned `himmel-health` dashboard (anonymous Viewer; random admin password in a 0600 file) |
| `himmel-observability-grafana-alert-hook.service` | 9878 | Bun receiver: Grafana can only POST webhooks, so this turns a firing/resolved alert into `cadence-alert.sh fail\|clear grafana-<alertname>` |

The contact point is the webhook above (one dedupe path and one log through
`cadence-alert`, no Telegram variables), and Grafana telemetry, update checks,
news and external snapshots are off. Doctor C19 checks this stack only when the
item is desired, comparing `prometheus.yml`, `alerts.rules.yml` and
`dashboards/` against the install dir. `uninstall` disables and removes the
units and the data dir.

## Health dashboard

`dashboards/himmel-health.json` (uid `himmel-health`) is the operator-facing
dashboard. It answers, in this order: is himmel healthy, what is failing and
what to do, are the scheduled jobs on time, sessions and the usage bank,
search and graph freshness, the Luna vault, and 7-day trends. `war-room-system.json`
stays the engineer's view.

It reads only series that exist: the `flow-exporter.ts` families, plus the
Prometheus built-ins `ALERTS` (from `alerts.rules.yml`) and `up`. Every
datasource reference is the provisioned uid `prometheus`. Status colours are
colour-blind safe and always come with a word and an icon: blue `#1f78c8`
for good, amber `#e69f00` for warn, red-orange `#d6352f` for critical, grey
`#8a8f98` for no data. The firing-alerts table maps each `alertname` to a
plain "what to do" sentence. An alert without one shows its raw name.

**Provisioning is inert until an installer renders it.**
`provisioning/dashboards/himmel-dashboards.yaml.tmpl` carries a
`@HIMMEL_DASHBOARDS_DIR@` path. Grafana loads only `*.yaml`/`*.yml`, so the
template does nothing as shipped. A provider whose path is missing would
break Grafana on the station. The Linux Grafana installer copies `dashboards/` to a
machine-local dir, then renders the template into the machine-local
provisioning copy. Until then, import the JSON by hand.

`test-dashboard-lint.sh` guards it. It checks that the file is valid JSON,
that panel ids are unique, that every PromQL metric is an exporter family,
`ALERTS` or `up`, and that the datasource uid matches
`provisioning/datasources/prometheus.yaml`. It also fails if an active
provider `*.yaml` appears under `provisioning/dashboards/`.

**Not shown yet (gaps; listed, never faked):**

| Gap | Wanted | Where it goes |
|---|---|---|
| G1 | Chief workers and their cost | Machine-readable output is a planned follow-up; `/obs-report` shows it |
| G4 | Advice per alert in the rules | The advice lives in the dashboard's `alertname` mapping instead |
| G5 | Usage bank reset time | The exporter does not keep the usage cache's `resets_at` |
| G7 | Daily health check (himmel-doctor results) | `/obs-report` |
| G8 | Machine setup (`himmelctl status`) | `/obs-report` |
| G9 | qmd search index age | `/obs-report` |

## Alerting (a boundary change)

The flow exporter above stays a pure Prometheus reader — no alerting lives
inside `flow-exporter.ts` or its request path. `luna-sync-alert.ts` is a
**separate, small scheduled checker**. No installer registers it on Linux, and
its sweeper-status trigger below reads a heartbeat file that no POSIX writer
produces (a missing file reads as RED `sweeper-dead`), so do not schedule it
on Linux until one exists. It reuses the same git read the exporter uses
(`runGitDivergence`, imported from `flow-exporter.ts`, so the two never drift
on what "unpushed" means) and sends a Telegram message via
`scripts/telegram/telegram-api.ts`'s `sendMessage` when the luna vault clone
has unpushed commits — debounced by a tiny state file
(`~/.himmel/luna-sync-alert-state.json`): immediate on the rising edge,
re-alerting only after a cooldown (default 6h) while the condition persists.
It reads the bot token the same way the bridge does
(`~/.claude/channels/telegram/.env`'s `TELEGRAM_BOT_TOKEN`) and the chat_id
from the bridge's own allowlist (`access.json`'s `allowFrom[0]`, override via
`LUNA_SYNC_ALERT_CHAT_ID`). It never runs `git fetch`, same passivity
invariant as the exporter.

### Sweeper-status extension (LUNA-131 — a second, independent trigger)

The headless vault sweeper (`vault-autosync.ps1 -Sweep`) writes a heartbeat,
`<StateDir>\status.json` (default `~/.himmel/luna-sync/status.json`, override
via `HIMMEL_LUNA_SWEEPER_STATUS`), on **every tick**. `luna-sync-alert.ts`
reads and `JSON.parse`s that file in `main()` (never inside `checkLunaSync`,
which stays fs/network-free by design) and passes the parsed value — or
`null` on a missing/unparseable file — into `checkLunaSync` as a
`sweeperStatus` opt. The pure, exported `evaluateSweeperStatus(status, nowMs)`
turns it into a `red | yellow | green` level plus a reason:

- **RED** if any of: the status file is missing/unparseable or its `ts` is
  more than 30 min old (`sweeper-dead` — the sweeper itself is not running);
  `last_clean_ts` is more than 60 min old (`stale`);
  `consecutive_pull_skips >= 12` (`pull-backlog`);
  `consecutive_push_failures >= 6` (`push-blocked`); or `alarm_class` is one
  of `auth`, `plugin-resurrected`, `wrong-remote` (reported as that class).
- **YELLOW** if not RED and `last_alarm_ts` falls within the last 24h.
  YELLOW never wakes the operator on its own — it is only appended as a note
  to an alert that RED (or a genuine git divergence) is already sending.
- **GREEN** otherwise. A GREEN sweeper reading never resets the git-divergence
  debounce state on its own — GREEN is not evidence about the git tree; only
  a genuinely-clean git tree does that (and not when the sweeper itself is RED).

This is a **second, independent trigger** on the same alert: a RED sweeper
reading fires even on an otherwise git-clean vault (the swallow regression
the existing `clean` early-returns would otherwise cause), and a genuine git
divergence still fires regardless of sweeper level, exactly as before. Same
rising-edge + 6h cooldown debounce; same Telegram delivery path.

**Detection-latency budget: ≤90 min** from outage onset to operator
notification. Achieved: ≤70 min for a stalled sync (60 min `stale` threshold
+ ≤10 min poll granularity), and ≤40 min for a dead sweeper (30 min
`sweeper-dead` threshold + ≤10 min poll granularity).

## Alert rules + Telegram delivery

Design doc: `observability-live-system-check.md` §5. Same passivity
invariant as everything above — no alerting logic lives inside
`flow-exporter.ts` or its request path. The rules themselves live in two
places that must be kept in sync (grep both for a rule name before changing
one):

- `alerts.rules.yml` — Prometheus-native rule-file format, the source of
  truth for every expression, loaded via `prometheus.yml`'s `rule_files` so
  Prometheus's own `/rules`/`/alerts` UI shows them and
  `promtool test rules alerts.rules.test.yml` unit-tests them against
  recorded series. **No Alertmanager is installed in this stack**, so
  nothing here is ever delivered from Prometheus's side — purely
  self-visibility + testability.
- `provisioning/alerting/rules.yaml` — the same 18 rules re-implemented in
  Grafana's file-provisioning dialect (query `data` + a `__expr__` threshold
  condition; structurally different from Prometheus's `expr:`/`for:` rule
  format, so it can't just include the file above). **This is what actually
  evaluates and delivers to Telegram** — RATIFIED F3.

`install-grafana.sh` copies `provisioning/` into
`$DATA/grafana-provisioning` and points
Grafana's `[paths] provisioning` at it, alongside the datasource
(`provisioning/datasources/prometheus.yaml`, fixed `uid: prometheus`) and
the notification policy (`provisioning/alerting/policies.yaml`) — the
default route (12h repeat) to the contact point, plus
a nested `severity = warn` route on the SAME contact point at a 168h (7d)
repeat, so a warn-severity alert still delivers but far less often than a
page.

**`noDataState` policy (corrected after a measured
false-alert bug):** the criterion is what the query returns in the HEALTHY
case, not whether `refId A` happens to be a bare selector. `NoData` is
correct only when the healthy query still returns a PRESENT series valued 0
— so an EMPTY result means the series' absence IS the alarm. When `refId A`
instead embeds a comparison, that comparison is a PromQL filter, so the
healthy case returns an empty vector — `NoData` there turns "healthy" into a
firing `DatasourceNoData` alert. 9 of the original 14 rules had exactly that shape;
measured live, Grafana reported `grafana_alerting_alerts{state="nodata"} 9`
against `{state="alerting"} 0` while sending ~125 Telegram messages/day for
~2/day of genuine alerts. The 3 of those 9 still shipped
(`HimmelFlowLastSuccessAgeExceeded`, `HimmelWatcherDown`,
`HimmelLunaInboxBacklogRising`; the other 6 were Windows-only and are gone)
use `noDataState: OK`, as do `HimmelFlowRunTruncated` and `HimmelFlowRunError`
since HIMMEL-1634 (their refId A is now a recency filter). `HimmelFlowStalled`
keeps `KeepLast` (see its comment in `rules.yaml`); the remaining 4
(`HimmelSessionDead` and the
three hook-chain rules — `HimmelHookChainBudgetPressure`,
`HimmelHookChainBudgetDenials`, `HimmelHookChainLogUnreadable`) keep the
`NoData` default — for the hook-chain rules, refId A IS a bare metric
selector, unlike the OK rules, but their series genuinely goes absent when
`hookChainMetrics`/`defaultHookChainSkipLogPaths` (flow-exporter.ts) fails to
read the skip log (or enumerate the worktrees directory, for
`HimmelHookChainLogUnreadable`), and that absence is a fault worth alerting on, not a healthy filter match. Full
per-rule reasoning + the code smell that flags a rule needing `OK`
(`refId B`'s `gt -1` evaluator) lives in `rules.yaml`'s header comment —
this table is the enforced expectation in
`test-promtool-validation.sh`.

### Failure-mode coverage

Every failure mode from the original incident postmortem maps to a rule whose evaluation does not
depend on the failing component itself (the design's acceptance test, §5):

| Incident mode | Rule(s) | Depends on the failing component? |
|---|---|---|
| 600s background-wait truncation | `HimmelFlowRunTruncated` (+ `HimmelFlowLastSuccessAgeExceeded` backstop) | No — reads the ledger's end row, written by the wrapper, not the model |
| Permission-prompt stall / SIGKILL, no exit code | `HimmelFlowRunStalled` | No — exporter-inferred from an unpaired start row past deadline |
| Transient CLI/API death | `HimmelFlowRunError` (or `HimmelFlowRunStalled` if it never writes an end row) | No |
| 4-day silently-disabled scheduled task | `HimmelFlowLastSuccessAgeExceeded` | No — a job that stops running stops writing success rows, so its last-success age grows |
| The exporter/collector itself dying | `HimmelWatcherDown` (`up == 0`) | No — Prometheus's own scrape health, not the exporter's output |
| 2026-09-03 spawn-storm hang | `HimmelHookChainBudgetPressure` + `HimmelHookChainBudgetDenials` + `HimmelHookChainLogUnreadable` | No — reads the skip log `scripts/hooks/run-hook-with-bash.js` writes when a chain member blows its time budget, independent of the starved member itself; `HimmelHookChainLogUnreadable` covers the reader's own read/enumeration failures, which would otherwise degrade the first two silently |

Three more rules extend coverage past that postmortem: `HimmelQuietRunOrphans`
(host-level, design §4, read from Linux `/proc`), `HimmelLunaInboxBacklogRising`
(pipeline-level, design §3), and `HimmelSessionDead` (session-level).

### Delivery choice — the cadence-alert webhook

`install-grafana.sh` renders Grafana's one contact point as a webhook to
`grafana-cadence-hook.ts`, which calls `scripts/luna/cadence-alert.sh` — one
dedupe path, one log. The shipped `contact-points.yaml` (the native Telegram
notifier reading `$GRAFANA_TELEGRAM_BOT_TOKEN`/`$GRAFANA_TELEGRAM_CHAT_ID`) is
not used by that installer, so no `GRAFANA_TELEGRAM_*` variable needs setting.
The hook token lives in `$DATA/hook-token` (mode 600), generated on first
install.

### Fixed-field content only

Every rule's `summary` annotation renders only `$labels`/`$value` —
`flow`/`task`/`class`/`stage`/`job`/`outcome`, all exporter-derived from
`observability.json` config or fixed enums, plus numeric values. None of
these can carry ledger `note` free text; `flow-exporter.ts` never turns
`note` into a label or annotation value anywhere in the exporter (design
§6.6's injection-carry guard).

### Tuning

- `HimmelFlowRunStalled`'s alerting bucket
  (`flow_run_stalled_current`) is capped at
  `FLOW_STALLED_ALERT_TTL_SECONDS` (24h) measured from when a
  row became stalled — same shape as `SESSION_DEAD_ALERT_TTL_SECONDS` above.
  Without it a single killed worker paged on the alert's 12h interval for up
  to 14 days as its ghost start row aged through the ledger window.
  That killed-worker case is now caught upstream — a row whose
  pid is confirmed dead on its own host is exported as `abandoned`, not
  `stalled`, so it never reaches this bucket at all. What remains (`stalled`,
  a live/unprobeable/foreign-host pid) still needs damping against a flapping
  series, which is why the alert also carries `for: 10m` (damps a transient
  count) and `keep_firing_for: 30m` (rides out a scrape gap without
  resolving) — safe only because `prometheus.yml`'s `scrape_timeout: 30s`
  first stopped the exporter's ~6.6s-avg/~9.9s-peak render from blowing
  Prometheus's 10s default and staling the series 51x/day. That flap alone
  produced 53 pages in one night for zero real incidents.
- `HimmelLunaInboxBacklogRising`'s 3-day/1h grace is a literal default in
  both rule files — no config surface exists yet in
  `observability.json`/`flow-exporter.ts`. Edit both files together.
- `HimmelQuietRunOrphans` (`quiet_run_orphan_count > 0` for 30m, both rule
  files) covers orphaned quiet-run suites and writer-less `tail -f` followers
  on Linux (both missed on 2026-08-29).
- `HimmelFlowLastSuccessAgeExceeded` needs a flow's `cadence_seconds`
  declared in `observability.json` (`flow_cadence_seconds{flow}`) — a flow with no declared cadence is excluded from the `on
  (flow)` join and never fires. If every flow lacks a declared cadence the
  whole query is empty; that resolves as `noDataState: OK` (see the
  `noDataState` policy above), not a fabricated healthy/unhealthy state.

### Deliberately not here

- Loki or log ingestion, and the two §7 log-based rules (error burst, log
  silence) that depend on it — Loki/Alloy are a planned build, not yet
  shipped.
- A second delivery channel split by `severity` (`page` vs `warn`) — one
  flat policy today; the labels are there if an operator wants to add a
  nested route later.
- In-loop subagent *step* counting. The session substrate gives
  start/running/end + outcome, not "3rd of 5 planned steps": there is no
  existing signal for that, and producing one would need subagents to
  self-report over an outbox-style progress channel.
- Reconciling the `armed-resume` double coverage — the scheduler's own
  `flow-runs.jsonl` row and this ledger's `session_start` row for the same
  launch are genuinely different moments (arm event vs. process lifecycle)
  and both are kept.
- Docker, brew, apt, or other Phase B packaging.
