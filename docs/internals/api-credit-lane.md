# API credit lane

Billing counterpart to the `claude -p` rule in
[enforcement.md](enforcement.md#claude-invocation-billing-himmel-128). The lane
spends a Console organization's API credit, not the subscription bank. It is
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
stop point of `--max-budget-usd`. A live proof needs the console's GO.

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
(`HIMMEL_API_LANE` unset) until its switch-on leg (HIMMEL-4987). The credit
does not roll over, so once that leg turns it on, `HIMMEL_API_ACCOUNT=auto`
spends the grant that expires first, inside each account's own cap.

## What the launcher enforces

| Rule | Where |
|---|---|
| `HIMMEL_API_LANE=on`, `HIMMEL_API_ACCOUNT=A\|B\|auto`, key present (never printed) | `claude-api.sh` |
| Key: the caller's `ANTHROPIC_API_KEY` (then `HIMMEL_API_KEY_ID` is required), else `key-<account>.env` beside the ledger, which must be mode 600 and yours; the key is handed only to claude's env, never exported | `claude-api.sh` |
| `HIMMEL_API_KEY_ID`, when set, must equal the roster `key_id` of that account | `claude-api.sh`, `roster.mjs` |
| Conflicting provider flags / `ANTHROPIC_AUTH_TOKEN` / openrouter or claudex lane: refuse | `claude-api.sh` |
| `-p` only; caller flags are an allowlist (`-p`, `--model`, `--permission-mode`, `--max-budget-usd`, `--output-format json`, `--effort`), so no `--bg`, `--cloud`, `--daemon`, bypass or skip-permissions; `--model` and `--effort` values must not start with a dash; `--permission-mode` is one of `default`, `plan`, `acceptEdits`, `dontAsk`, `auto` (exact case, never the bypass mode); explicit `--permission-mode`, `--model`, `--max-budget-usd` | `claude-api.sh` |
| Bank gate is the API credit row only (`CADENCE_BANK_LANE=api`, opt-in via `HIMMEL_API_LANE=on`); the native bank is never read, so an exhausted native bank does not block and a funded one does not rescue an empty API account | `bank-preflight.sh` |
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

## Proposed CLAUDE.md line (for the operator or console to apply)

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
and a `backends.json` row are outside this PR's write scope and need a console
ruling. Until then `claude-headless.sh` already strips `ANTHROPIC_*` for native
children.
