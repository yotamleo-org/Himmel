# Per-ticket usage records

One append-only record per ticket answers "what did it cost and how many review
rounds did it take". It joins two computations that previously lived apart and
is computed once; consumers read the store, never transcript JSONL. A third,
opt-in join (PR and CI facts from `gh`) fails closed by
construction; see "PR/CI join" below.

| Input | Source |
|---|---|
| per-session tokens | `scripts/lib/usage-attribution.sh` output, reused not re-parsed |
| automated review rounds, verdicts, estimated critic tokens | the automated review critic ledger (`scripts/cr/ledger-append.sh`) |
| PR and CI facts (opt-in) | `gh pr list` / `gh run list`, only with `--repo` |

## Commands

```
bash scripts/usage/usage-compute.sh --range PROJ-100..PROJ-120   # append changed records
bash scripts/usage/usage-compute.sh --tickets PROJ-123 --print      # stdout only, no store
bash scripts/usage/usage-read.sh [--ticket KEY] [--all]                # latest per ticket / every version
```

Flags: `--projects` (default `~/.claude/projects`), `--ledger` (default the
repo's `cr-critic-scores.jsonl`), `--store` (default `~/.himmel/state/usage`,
or `HIMMEL_USAGE_STORE`), `--since`, `--budget-seconds` and `--max-windows` (see "The
build" below), and one selector, `--range` or
`--tickets` (never both). `--range` is `KEY-a..KEY-b` with one key prefix;
`--tickets` is comma-separated `KEY-n` entries and must match at least one
ticket; `--since ""` is rejected. The store is `<store>/records.jsonl`,
outside the tree.

## Join keys

- **Ticket** is the key. A session joins by its custom title starting `KEY-n`;
  an automated review ledger row joins by the `KEY-n` inside its branch name.
- A session whose title contains `console` is kind `console`; `judge` is kind
  `judge`; everything else is `leg`.
- A chief spans many tickets, so its title does not name one. Chief
  sessions with no `KEY-n` prefix go to the pseudo-ticket `_chief` as a pool,
  **with no allocation to tickets** (an allocation rule would change every
  ticket's record whenever the range changes). Sessions with no key and no
  `console` go to `_unattributed`. A chief titled with a ticket key stays
  under that ticket, in `totals.console`.

## Record (one JSON object per line, keys sorted)

| Field | Meaning |
|---|---|
| `schema` | `1` |
| `ticket` | `KEY-n`, `_chief` or `_unattributed` |
| `workers[]` | per session: `name`, `kind`, `turns`, `input`, `cache_read`, `cache_create`, `output`, `sub_*` (same five for its subagents) |
| `totals.leg`, `totals.console`, `totals.judge` | the same ten counters summed per kind, as separate fields |
| `cr` | `rounds` (distinct reviewed heads), `findings` (count by final verdict after amends; `open` when none), `est_tokens` (the ledger's estimated critic tokens) |
| `digest` | sha256 of the record without this field |

Numbers and ids only: neither `records.jsonl` nor the `phase-cost-state/` directory beside it holds message text or a session title (the state keeps message ids, counts and a class word per transcript).

## Phase-cost rows (`kind: "phase-cost"`)

The same run also appends one row per **(day, session, phase)** to `records.jsonl`,
the one record a cost view reads. A phase-cost row has **no `ticket`**; readers that
want ticket records skip rows without one (`usage-read.sh` does).

| Field | Meaning |
|---|---|
| `kind` | `phase-cost` |
| `day` | the local day (the station's `TZ`) of the call |
| `session` | the transcript's file name; a subagent's is its `agent-…` id |
| `parent` | the session id a subagent belongs to, else `null` |
| `lane` | `claude` (all models `claude-*`), `codex` (all `gpt-*`), else `other` |
| `class` | `chief`, `worker`, `judge`, `brief-drafter`, `subagent`, `critic`, `release-mgr`, `other` |
| `model` | the models of the row's calls, sorted, comma-joined |
| `phase` | see below |
| `phase_rule` | `v1`: the rule set of the cost-page audit |
| `calls`, `in`, `out`, `cache_read`, `cc_5m`, `cc_1h` | API calls (a message id seen earlier anywhere in the same transcript counts once, as `usage-attribution.sh` does) and their tokens |
| `usd` | the calls priced per model from `scripts/lanes/lib/model-prices.tsv`; `null` when no call was priced |
| `mark` | `counted` (the phase is the session's whole class), `derived` (the phase is the last-tool rule), `unpriced` (some call's model has no price row; `usd` covers only the priced calls) |

A model with no price row is never priced as another model: a `gpt-6.1-sol` call is
priced at its own row, an unknown model counts toward `calls` and tokens with no dollars.

**Phase.** A call goes to the phase of the most recent tool call before it (`boot`
before any tool; `compaction` after a compaction boundary until the next tool):
`review`, `ci`, `ticket-filing`, `ticket-read`, `ship`, `tests`, `comms`, `retrieval`,
`vm`, `skill`, `tool-load`, `agent`, else `build`. A `judge`, `critic` or `release-mgr`
session has that one phase; a chief or brief-drafter (and a subagent of a chief) has
`chief-turns`; a subagent of a worker has phase `agent`. All of these are mark `counted`. Classes `graph-eval` and `bots` are not detected yet (class `other`).

**Rows are cumulative.** Each run reads every transcript from its saved byte offset
(`<store>/phase-cost-state/`, one file per transcript, named by a checksum of its path, the offset inside it), complete lines only (a last line with no newline waits), and appends a key's row only when
its totals changed; the latest row for a (day, session, phase) is the total. What was
emitted is kept per session in `<store>/phase-cost-state/emitted/`, one file per session.
A key that disappears (a class change moved it) is closed with a zero row. The whole run
renices itself to 19 and, where `ionice` exists, to the idle io class. `--since` and
the ticket selectors do not apply to phase-cost rows.

**Reading them.** `usage-read.sh --phase-cost` prints the latest row per (day, session,
phase), in key order; `--day YYYY-MM-DD` keeps one day, `--all` prints every stored
version in append order. It does not combine with `--ticket`, and without `--phase-cost`
the reader still prints ticket records only. A row the writer closed with zero calls is
still a row; the Cost page (`scripts/config-ui/cost.ts`) drops it. With no
`records.jsonl` at all, the page says the usage store has not been built yet and names
`scripts/usage/usage-compute.sh`, rather than "no data yet".

**What the Cost page's dollars are.** The collector reads Claude transcripts only (by
default `$HOME/.claude/projects`), and prices each call at list price, so every figure on
the page is a list-price equivalent: not an invoice, not cash, and not all-provider spend.
Native Codex and other provider stores are not collected. In every state (data, no data,
no store) the page says so, with `basis` and `coverageNote` in the model, and says
"Collection freshness and completeness unknown": it infers no health from a file's age.
Under the build group, `phase=agent` rows split by class: `build-agent` ("Child sessions")
holds `class=subagent` rows, `build-agent-followup` ("Parent follow-ups after delegation")
holds the others; the group's total and call count are unchanged by the split.

## The build: windows, checkpoint, budget and resume

The first build on a station reads every transcript (43 GB on the first station), so it
runs in windows rather than all at once.

- **A window** is the set of sessions that changed since the last run, grouped by the
  local day of each session's newest file. A session is a top-level transcript plus its
  subagents. The windows run newest day first, so the Cost page has today before history.
  A session that changed is read again in full (`usage-attribution.sh`, unchanged, on a
  scratch root of symlinks to that window's files). Its table rows then replace the
  ones it had, so the ticket totals equal one pass over the whole root.
- **The checkpoint** is `<store>/build-checkpoint.json`. For each session it holds a
  fingerprint of its files (count and total bytes), the per-session table rows, the
  `--since` they were read with, and the last committed window. A different `--since`
  makes every session stale. The rows carry the same session names that the ticket
  records' `legs[]` carry.
- **A commit per window.** The window's phase-cost rows, its sessions' emitted maps and
  the new checkpoint are staged under `<store>/.commit.new`, renamed to `.commit`, and
  then applied: the part of the staged rows that `records.jsonl` lacks is appended, and
  each state file is replaced by copy then rename. An applied commit is renamed to
  `.commit.done` before it is removed, so it is never replayed. A run that finds
  `.commit` applies it first. A kill at any point therefore leaves each row appended once or not yet, never
  twice and never lost. Each transcript's phase state is saved as soon as it is read, so
  a kill loses at most the transcript in flight.
- **Ticket records** are computed and appended only in the run's last window, once every
  changed session is in. A reader never sees a ticket's partial total. When nothing
  changed, a run still recomputes them, so a new CR ledger row shows up.
- **The budget.** `--budget-seconds` (default 240, `0` = no bound) stops a run from
  starting another window once that time has passed. The window in flight always
  finishes, so every run commits at least one. `--max-windows <n>` stops after `n`
  windows. A stopped run exits 0 and prints
  `stopped by the budget of 240s after K window(s), N window(s) remain; rerun to continue`.
- **The resume rule.** The next run begins at the first window that was not committed.
  Committed sessions are not read again unless their files grew. A rerun with nothing
  new builds `0 window(s)` and appends nothing.
- `--print` and `--repo` run as one window over everything that changed. With `--repo`,
  the gh join keeps its all-or-nothing contract.

**Stopping a run.** A plain `timeout` (SIGTERM) or Ctrl-C ends the run through its exit
trap, which releases `<store>/.lock`. A cadence caller must use plain `timeout <secs>`,
never `-k` or `-s KILL`. A SIGKILL skips the trap and leaves the lock with the run's pid
in `<store>/.lock/pid`. After 300 s the next run refuses with
`store locked: <path> (owner pid N, not running; remove it with rm -r if no run is active)`.
The lock is never taken over automatically. A lock that `usage-read.sh` holds carries
no pid, and the refusal says `owner unknown`.

**A store written before the windows** has one `phase-cost-state/emitted.json` and no
checkpoint. Its first windowed run reads every session once and appends each phase row
once more with the same values. `usage-read.sh --phase-cost` keeps the latest row per
(day, session, phase) (`scripts/usage/usage-read.sh`, the `reduce` in its jq program),
and the Cost page reads only through it, so the totals do not double. The old
`emitted.json` is left unread.

## PR/CI join (`--repo OWNER/NAME [--gh <executable>]`)

Opt-in: without `--repo` records carry no `pr`/`ci` and nothing calls gh. The
repo is never inferred from the cwd; every call is `gh ... -R OWNER/NAME`. `--gh`
is ONE executable path (default `gh`; a path with a space works, arguments do
not). Real tickets only; `_chief` and `_unattributed` get no `pr`/`ci`.

| Field | Values |
|---|---|
| `pr` | `{state:"none"}` (no PR title names the ticket), or `{state:"found", numbers[], merged, open, closed}` |
| `ci` | `{state:"no-pr"}`, or `{state:"found", runs, completed, secs, basis}` |

A title matches a ticket only on the whole key (`PROJ-90019` is not
`PROJ-9001`). `ci` covers the runs on every matching PR's head branch,
deduped by run id. `secs` sums `updatedAt - startedAt` over **completed** runs,
so queue wait and in-flight runs are excluded; if any completed run lacks
`startedAt`, all use `createdAt` and `basis` says `createdAt` (`none` when no run
completed). "No PR" (`no-pr`) is distinct from a PR with zero runs (`runs:0`).

**Fail closed.** An unknown fact is never stored: gh missing, a non-zero gh
(auth, network, rate limit, a wrong repo), malformed or unexpected JSON, a
100-row truncation, or a negative duration aborts the WHOLE run with exit 1
before anything is appended; the store, and every ticket's previous version,
is untouched and the lock is released. An unknown run status (outside gh's
`queued`, `in_progress`, `completed`, `waiting`, `requested`, `pending`) is
malformed JSON for this purpose. `usage-read.sh` takes the same store lock, so
it never reads a torn last line; on a store the reader cannot write (shared or
read-only) it cannot lock, so it reads lock-free and exits 1 if the file does
not end in a newline.

## Idempotency and append-only

A record has no compute timestamp, so the same inputs give the same bytes. The
compute step appends a ticket's record only when its `digest` differs from that
ticket's latest stored line; older versions stay (`usage-read.sh --all`). A
`--print` rerun is byte-identical. Token counts follow `usage-attribution.sh`
exactly (per-requestId dedup), and a skipped or unreadable transcript makes the
run fail rather than store incomplete totals.

## Consumers

The usage-records epic's readers: the effort model, the tool
re-audit, routing, worker A/B, the
improvement lane, the tracker UI and cost reports. Siblings that
will feed it: PR-body cost aggregation and the automated review loop ledger.

## Limits

`--since` windows session tokens only; automated review stays all-time, so use it
for token questions, not for a stored record you mean to compare across runs.
A whole compute-then-append run holds a `<store>/.lock` directory, so an older
snapshot never publishes after a newer one. A reader waits up to 60 s for it, so a
budget much above that delays the Cost page while a build runs.
`usage-attribution.sh` stops on a transcript it cannot parse, so the window that holds
that transcript is refused, and every later run stops at that window until the file is
readable again. Table parsing assumes session
titles contain no ` | `. Sessions are keyed by title, so distinct sessions
sharing a title merge into one `workers[]` entry. Judge subagents are counted as
`judge`-titled sessions only. An explicit `--projects` or `--ledger` that is
missing or unreadable exits non-zero before anything is written; the default
projects dir and default ledger may be absent (a note on stderr, treated as
empty). `cr.rounds` counts heads with a responding review
(`unavailable` availability rows are not rounds).

## CI minutes (billed beside wall)

`scripts/usage/ci-minutes.sh` is the one writer of `<store>/ci-minutes.jsonl`
(same store as above): one row per Actions run, the run id is the key, so a
second pass over the same window appends nothing for a run it already holds. A
run that was rerun since it was recorded (`gh run rerun`) is listed again with a
higher `run_attempt`; its row is then replaced, never added to, so the run id
stays unique in the file.

```bash
bash scripts/usage/ci-minutes.sh write  --repo OWNER/NAME [--days 7] [--until <iso>] [--store <dir>]
bash scripts/usage/ci-minutes.sh report --repo OWNER/NAME [--days 7] [--until <iso>] [--store <dir>]
```

Row: `{schema, repo, run_id, workflow, created_at, run_attempt, wall_min, billed_min}`.
A row written before `run_attempt` existed counts as attempt 1.
`wall_min` is `run_started_at` to `updated_at` of the run list, which shows the
latest attempt only. `billed_min` is
`GET /repos/{repo}/actions/runs/{id}/timing`, `.billable.<OS>.total_ms` summed
over every OS. A run whose billing answer is absent (HTTP 404/410, or no
`.billable` entry) is stored as the string `"unknown"`, never 0; an answer of 0
ms is a real 0 (this public repo bills 0). Any other gh failure aborts the run
and rows already written stay. `report` prints runs beside the `gh api`
total_count for the window, billed beside wall minutes, and the unknown runs on
their own line (unknowns are left out of the billed sum).

How a rerun is stored: the timing endpoint is cumulative over attempts (checked
on a real `gh run rerun --failed` run: its `jobs` count is the sum of both
attempts' jobs, while `run_duration_ms` is the latest attempt's), so the new
answer already holds the earlier attempt's billed time and is stored whole.
`wall_min` is the latest attempt's wall time, not the sum of attempts.

The runs endpoint returns at most 1,000 rows for a filtered window however large
`total_count` is, and `gh run list --limit` stops there too. The writer pages
each window with `--paginate`, and halves a window whose listing is short of
`total_count` until each half is complete; a single second that holds more than
the API returns fails closed rather than storing a partial window. Cost: one
`timing` call per new run.
