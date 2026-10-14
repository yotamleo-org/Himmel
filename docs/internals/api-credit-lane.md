# API credit lane

Billing counterpart to the `claude -p` rule in
[enforcement.md](enforcement.md#claude-invocation-billing). The lane
spends a Console organization's API credit, not the subscription usage budget. It is
**OFF by default** and has exactly one entry point:
`scripts/api-lane/claude-api.sh`.

## Which auth wins (answered from the docs, 2026-10-08)

On a subscription-logged-in station, an `ANTHROPIC_API_KEY` in the environment
of `claude -p` **wins**, and the Console org that owns the key is billed. In `-p`
mode "the key is always used when present"; there is no approval prompt. Order,
first present wins: cloud-provider flags (`CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY`),
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`,
`CLAUDE_CODE_OAUTH_TOKEN`, profile/federation, subscription OAuth.
Not proven without a live call: promotional-grant-first debit and the exact
stop point of `--max-budget-usd`. A live proof needs the supervisor session's GO.

## Does the credit cover this lane (answered from the docs, 2026-10-13)

Yes. The Help Center article on the Max/Team API credits says the credit covers
`claude -p` and the Agent SDK "when you run them yourself with an API key from
your linked Console organization, because that usage is billed as Agent SDK
usage"; runs started by the GitHub Action, an IDE extension or the desktop app
count as Claude Code usage "even with `-p`". The platform page's "Doesn't
cover: Claude Code" row is interactive Claude Code. So `claude -p` under the
key is the covered surface, and the lane needs no switch to the SDK or the raw
Messages API. A lane call launched from inside a Claude Code session would
inherit that session's markers (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT=cli`,
session id, messaging token), so the launcher drops every `CLAUDE_CODE_*`,
`CLAUDECODE`, `AI_AGENT`, `CLAUDE_PID` and `CLAUDE_EFFORT` variable.
Sources: https://support.claude.com/en/articles/17154008,
https://support.claude.com/en/articles/15036540.

To measure it, the operator runs ONE Haiku call (budget $0.05) with the key
read by the script itself, never typed into a model session:

```bash
bash scripts/api-lane/measure-credit.sh <A|B> <key-id> <op://ref | env file> <promotional-remaining-usd>
```

Read Console > Billing (Promotional credits) and Console > Cost before the run
and again 5-15 minutes after; the script refreshes the account's snapshot with
the before figure and prints only the launcher verdict, outcome and cost.

Measured 2026-10-13, account B, Haiku: the call returned success with
`total_cost_usd` 0.0032, and Console > Billing (Promotional credits) went from
$199.91 to $199.90 of $200. The spend landed on the credit, not on a card.
Account A had a second $200 grant that expired unused on 2026-10-13.

Should the lane spend it by default? Not in this change: the lane stays OFF
(`HIMMEL_API_LANE` unset) until its switch-on worker session (HIMMEL-4987). The credit
does not roll over, so once that worker session turns it on, `HIMMEL_API_ACCOUNT=auto`
spends the grant that expires first, inside each account's own cap.

## What the launcher enforces

| Rule | Where |
|---|---|
| `HIMMEL_API_LANE=on`, `HIMMEL_API_ACCOUNT=A\|B\|auto`, key present (never printed) | `claude-api.sh` |
| Key: the caller's `ANTHROPIC_API_KEY` (then `HIMMEL_API_KEY_ID` is required), else `key-<account>.env` beside the ledger, which must be mode 600 and yours; the key is handed only to claude's env, never exported | `claude-api.sh` |
| `HIMMEL_API_KEY_ID`, when set, must equal the roster `key_id` of that account | `claude-api.sh`, `roster.mjs` |
| Conflicting provider flags / `ANTHROPIC_AUTH_TOKEN` / openrouter or claudex lane: refuse | `claude-api.sh` |
| `-p` only; caller flags are an allowlist (`-p`, `--model`, `--permission-mode`, `--max-budget-usd`, `--output-format json`, `--effort`), so no `--bg`, `--cloud`, `--daemon`, bypass or skip-permissions; `--model` and `--effort` values must not start with a dash; `--permission-mode` is one of `default`, `plan`, `acceptEdits`, `dontAsk`, `auto` (exact case, never the bypass mode); explicit `--permission-mode`, `--model`, `--max-budget-usd` | `claude-api.sh` |
| Usage budget gate is the API credit row only (`CADENCE_BANK_LANE=api`, opt-in via `HIMMEL_API_LANE=on`); the native subscription usage budget is never read, so an exhausted native subscription usage budget does not block and a funded one does not rescue an empty API account | `bank-preflight.sh` |
| Reserve the full budget first; settle only on a verified result with `total_cost_usd`, else mark `unknown` and keep the reservation | `api-credit-state.mjs`, `outcome.mjs` |
| `auto` picks the account whose grant expires first among those with room for the whole budget under their own cap; a caller key is refused under `auto`; no subscription fallback: a refusal is final | `claude-api.sh`, `api-credit-state.mjs pick` |
| Child env: OAuth, profile and federation vars removed, `ANTHROPIC_BASE_URL` pinned to `https://api.anthropic.com`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` (live probe 2026-10-13, claude 2.1.296: Bash runs inside the bwrap sandbox) | `claude-api.sh` |
| Claude Code session markers dropped (`CLAUDECODE`, `AI_AGENT`, `CLAUDE_PID`, `CLAUDE_EFFORT`, every `CLAUDE_CODE_*`), so the child is not billed as that session | `claude-api.sh` |
| Tools fixed to `Read,Edit,Write,Glob,Grep,Bash` via `--tools` and `--allowedTools`, because the scrub forces permission mode `default` | `claude-api.sh` |
| Non-API children run through `strip-env.sh -- <cmd>`, which drops the key and every `HIMMEL_API_*` selector | `strip-env.sh` |
| Secret-free launch record (account, org, key id, cycle, model, budget, snapshot source, outcome, cost) appended to `launches.jsonl` beside the ledger | `claude-api.sh` |

## Credit config

`~/.himmel/state/api-credit/config.json` (outside the repo, never committed):

```json
{ "version": 1, "ledger_path": "/home/<user>/.himmel/state/api-credit/ledger.json",
  "accounts": { "A": { "organization_id": "...", "cycle_id": "...", "cap_usd": "5.00", "key_id": "..." } } }
```

`ledger_path` is required, absolute and pinned: `HIMMEL_API_CREDIT_STATE` may
only restate it, and the config location comes from the account home, not
`$HOME`. Two sentinels (`<ledger>.initialized` and one beside the config) make
deleting the ledger refuse instead of resetting spent credit. `key_id` is a
non-secret label chosen by the operator; the key itself is in
`key-A.env` / `key-B.env` beside the config (one `ANTHROPIC_API_KEY=` line,
mode 600), or in the launching shell's `ANTHROPIC_API_KEY`.

The snapshot row of each account is refreshed from a Console reading with
`node scripts/api-lane/grant-snapshot.mjs <A|B> <remaining-usd> [<grant-usd>
<starts YYYY-MM-DD> <expires YYYY-MM-DD>]`; the long form (re)writes the grant
(dates as 00:00 UTC), run from the primary checkout. A refresh also moves `reconciled_spent_usd` up by the
billed spend added since the previous reading, never by more than the ledger
spend added since, so a settled call is counted once whether or not the
Console shows it yet. A new grant row starts it at zero. The refresh holds the
ledger lock.
`HIMMEL_API_CREDIT_CONFIG` can still point at a second config with its own
ledger; pinning it is HIMMEL-5444.

### Unattended running (HIMMEL-5519)

- **No freshness window on an operator reading.** The remaining credit is derived:
  the last reading minus the ledger's settled and reserved spend. The cap and the
  reserve accounting stay the hard stop, and a derived remainder at or below zero
  refuses (`insufficient-headroom`). Only a row whose `source` is
  `automatic-snapshot` goes `BANK-STALE` after 600 s.
- **Automatic pull, opt-in:** `node scripts/api-lane/grant-snapshot.mjs --pull <A|B>`
  reads the Admin API cost report (`GET /v1/organizations/cost_report`, daily buckets,
  paged) since the row's `starts_at` and writes `grant - spend` as the remaining credit.
  The admin key is `ANTHROPIC_ORG_A_KEY` / `ANTHROPIC_ORG_B_KEY`, from the environment or the
  repo `.env`; it is read inside `api-credit-state.mjs` only, goes to
  `api.anthropic.com` only, and is never printed or put on argv. A failed pull leaves the
  snapshot untouched and returns `BANK-UNKNOWN`. **Limit:** the cost report has no
  promotional-vs-card field, so every dollar since the grant start is attributed to the
  grant; spend past the grant reads as zero remaining, never as credit.
  A pull keeps the row's own `source` (an operator reading stays an operator
  reading, so it never goes stale on its own and a pull that stops running strands
  nothing) and stamps `pulled_at`. Within one grant remaining credit can only
  fall, so a pull that reports more than the row holds keeps the smaller figure,
  and a pull refuses (`grant-changed`) when the row's grant, reading or
  watermark changed while the report was in flight.
- **Own concurrency cap:** a reservation belongs to the api lane by its `lane`
  file (written from the launch lane), not by its name, so an inherited
  `CADENCE_BANK_LEG` cannot escape it. api-lane launches are not counted in the
  subscription FLEET cap; they are held to `HIMMEL_API_MAX_CONCURRENT` (default 10),
  refusing `SKIPPED-FLEET` with `api lane at/over its own cap`. `claude-api.sh`
  owns its reservation with its own pid, which waits on `claude`, and releases it
  when the call ends (EXIT trap), so the cap bounds calls actually in flight.
- **Keys:** the launcher unsets `ANTHROPIC_ORG_A_KEY` / `ANTHROPIC_ORG_B_KEY` for the
  bank gate and for the `claude` child.
- **Ledger lock retry:** the mkdir lock is retried with jittered backoff for up to
  `HIMMEL_API_LOCK_WAIT_MS` (default 5000; unset or empty means the default)
  before `ledger-locked-or-unwritable`.

## Prompt cache (HIMMEL-5570)

A cache read costs 0.1x input, a 5m write 1.25x, a 1h write 2x
([prompt-cache.md](prompt-cache.md) is the model of record). The prefix is tools,
then system prompt, then messages, and the match is exact: a byte that differs
anywhere re-writes everything after it. Measured 2026-10-14, claude 2.1.299,
Haiku 5.5, tool-free, a one-word prompt, account B:

| Arm | Runs | Input | Cache write | Cache read | Hit rate | Cost |
|---|---|---|---|---|---|---|
| before (no flag, cwd in the system prompt) | 3 | 6 | 12,430 | 7,820 | 38.6 % | $0.001709 |
| after (`--exclude-dynamic-system-prompt-sections`) | 3 | 6 | 11,041 | 9,197 | 45.4 % | $0.001500 (-12 %) |

Each arm ran dir X, dir Y, dir X again, inside 5 minutes. Runs 1 and 2 of an arm
write whatever differs from the shared prefix; run 3 returns to dir X and reads its
whole prefix (6,750 and 6,746 tokens) in both arms. Three runs per arm and a
one-word prompt: the figures show direction, not a rate to quote. The record is
`launches.jsonl`; `node scripts/api-lane/cache-report.mjs` prints the hit rate and
TTL pick per kind, model and organization (only those share a cache) from it. Before this change the record held cost only, so no
earlier run had a hit rate to read back.

**Prefix rules (one run kind = one row of the same prefix):**

1. The launcher fixes everything above the prompt: `--tools`, `--strict-mcp-config`
   (on every call: no caller can be granted an `mcp__` tool, and hooks are off), the model and effort are the caller's and must be the same
   for every run of a kind (each model has its own cache).
2. `--exclude-dynamic-system-prompt-sections` is always passed: the working
   directory, platform, memory paths and git status ride in the first user
   message, so two runs from different directories still share the system prompt.
   They do not share the first user message, which still names the directory:
   **launch every run of a kind from the same directory**, an empty scratch one,
   never a checkout (the sandbox leaves stubs there, see Deferred).
3. Per-run content goes last, in the `-p` prompt. A timestamp, nonce, job id or path
   in a fixed instruction text re-writes it, so keep them in the per-run tail.
4. Name the kind: `HIMMEL_API_KIND=<label>` (`[A-Za-z0-9._-]`, default `other`) lands
   in the launch record with the TTL and the usage split (`input_tokens`,
   `cache_creation_tokens`, `cache_read_tokens`; `null` when the result had none).
5. The launcher states the TTL itself through `CLAUDE_CODE_PROMPT_CACHE_TTL`
   (`HIMMEL_API_CACHE_TTL=5m|1h`, default `5m`). A key-authenticated call gets 5m by
   default; a caller's own `CLAUDE_CODE_PROMPT_CACHE_TTL` is dropped like every
   `CLAUDE_CODE_*` variable. Confirm the tier a run really used from
   `usage.cache_creation.ephemeral_1h_input_tokens` in its result.

**TTL by run kind.** 1h pays 2x instead of 1.25x on every write and wins only when
gaps between runs of a kind fall between 5 and 60 minutes. The 48 recorded runs
(2026-10-12 to 2026-10-14) have 44 gaps of 300 s or less, 1 between 300 s and 1 h and
2 above 1 h, so every kind stays on **5m**. Re-decide per kind with
`cache-report.mjs` once a kind has runs with usage: it prices the observed gaps on
both tiers and prints `recommended_ttl`. Set `HIMMEL_API_CACHE_TTL=1h` for that kind
only when it says so; a burst finishing inside 5 minutes never earns the premium.

## Judge-call bridge (HIMMEL-4987)

`scripts/api-lane/judge-call.sh` sends ONE verdict-grade question to the lane instead of a
native subagent and hands the parent a bounded artifact. It is a console-side caller of
`claude-api.sh`; it adds no launch path of its own.

```bash
bash scripts/api-lane/judge-call.sh --qid <qid> --pr <n> --head <40-hex> --question-file <f> \
  --model claude-opus-5-5 --max-budget-usd 0.50 [--effort high] [--timeout 600] [--judge <name>]
```

stdout is the artifact path; exit 0 only when the verdict was recorded.

| Rule | Where |
|---|---|
| Read-only: `HIMMEL_API_TOOLS=Read,Glob,Grep`, `--permission-mode dontAsk`, `HIMMEL_API_KIND=judge`; a caller's own `HIMMEL_API_TOOLS` is overwritten | `judge-call.sh` |
| Explicit judgment-tier model (`claude-opus-*` or `claude-sonnet-*`, never haiku or fable) and a budget above 0 and at most $2.00; a refusal happens before any call | `judge-call.sh` |
| Fixed instruction first, head, PR and question last, run from an empty scratch cwd, so the prefix caches across judge calls; the question names every file by ABSOLUTE path, since a repo-relative name resolves nowhere in that cwd | `judge-call.sh` |
| Verdict semantics are the in-process judge's: the first line is `**GO**` / `**NO-GO**` `for head <sha>`, evidence follows, and a valid verdict is recorded by `write-verdict.sh` (mac-signed, NO-GO needs its `class:` line) | `judge-result.mjs`, `write-verdict.sh` |
| Status instead of a ruling: `STALE` (names another head), `MISSING` (no verdict first line, no head, or no evidence), `DENIED` (any `permission_denials`, whatever the rc), `ERROR` (error result, or evidence over 32 KiB, which is never recorded cut), `UNRECORDED` (the writer refused), `REFUSED` (the launcher refused), `TIMEOUT` | `judge-result.mjs`, `judge-call.sh` |
| Bounded parent artifact (`<judge dir>/judge-call-<qid>.json`, mode 600): status, reason, verdict, heads, model, budget, cost, verdict path and an excerpt of the evidence cut at 8 KiB; the full evidence is in the verdict record | `judge-result.mjs` |
| Deadline through `qmd_bounded` (process group killed); the bridge never touches the ledger, so a timed-out or errored call keeps its full reservation (`claude-api.sh` settles on a verified cost or keeps it unknown) | `judge-call.sh` |
| No bank fallback: a refusal is final and the native subscription is never consulted | `claude-api.sh` |

Run it from a console, not a leg: `write-verdict.sh` refuses a console-spawned leg (`HIMMEL_CONSOLE_LEG`), so
a leg's call ends `UNRECORDED` with the ruling in the artifact excerpt.

Measured cost of a real call (one 60-line file, `--effort low`): `claude-opus-5-5` spent $0.107 and hit a
$0.10 cap before answering (status `ERROR`, cost kept in the artifact); `claude-sonnet-5-5` answered a GO
with evidence for $0.078. Budget opus judge calls at $0.25 or more.

Not converted: headed judge SESSIONS (`headed-arm-leg.sh --judge`) keep their own worktree and lifecycle.
Routine routing of judge calls onto the lane waits on a measured quality and cost per ruling.

## Proposed CLAUDE.md line (for the operator or supervisor session to apply)

> API credit lane: `scripts/api-lane/claude-api.sh` is the only API-key launch
> path, OFF unless `HIMMEL_API_LANE=on`. Never export `ANTHROPIC_API_KEY` into a
> general shell; non-API children go through `scripts/api-lane/strip-env.sh`.
> Detail: [`docs/internals/api-credit-lane.md`](docs/internals/api-credit-lane.md).

## Deferred

Sandbox under the scrub (HIMMEL-5073): with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`
claude runs Bash in bwrap, and its built-in deny list names
`/run/containerd/containerd.sock`, `/run/podman/podman.sock` and
`/run/buildkit/buildkitd.sock`. When one of `/run/containerd`, `/run/podman`
or `/run/buildkit` exists but is not traversable (root `0700`), bwrap fails
and every Bash call fails with it. ponytail: the launcher does not check for
this, so the defect returns on a station that installs containerd, podman or
buildkit; upgrade path: a launcher precheck that refuses with that reason.

The same sandbox leaves empty mount stubs (`package.json`, lockfiles,
`.npmrc`, `.env.*`, `.gitmodules`) in the working directory of a call
(observed 2026-10-13, claude 2.1.296). An empty `package.json` at a repo
root breaks node there, so launch from a scratch directory, as
`measure-credit.sh` does, never from a checkout root.

Wiring `strip-env.sh` into the lane launchers (`claude-lane.sh`, `lanes.json`)
and a `backends.json` row are outside this PR's write scope and need a supervisor session
ruling. Until then `claude-headless.sh` already strips `ANTHROPIC_*` for native
children.
