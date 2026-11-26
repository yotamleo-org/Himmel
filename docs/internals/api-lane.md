# The API lane: failure alert and subscription fallback

`scripts/api-lane/claude-api.sh` runs one print-mode `claude` call billed to an
API account (`HIMMEL_API_ACCOUNT=A|B|C|D|auto`; auto only from the himmel repo; any kind, by the role map or the default order) instead of the subscription. It is
OFF unless the launching shell sets `HIMMEL_API_LANE=on`; the one exception is the routed release judge, which sets it on itself
(`judgeApiEnv` in `scripts/jira/src/commands/release.ts`) whenever `judge` is mapped in `roles.json`, so mapping `judge` is what turns
the lane on for it, and only the operator may write that file. This page covers what
happens when a call on it fails. The launcher's header lists the
full argument and environment contract.

`auto` picks the account among those allowed; whether a feature runs at all is that
feature's own switch.

## Who uses it

| Caller | Default backend | How it reaches the API lane |
|---|---|---|
| `scripts/api-lane/judge-call.sh` | API lane | always (a chief's verdict question) |
| `scripts/api-lane/bulk-call.sh` | API lane | always |
| `jira release rm-run` (release manager) | none: the model judge is parked and the door places each request with no call; the rest of this row is the parked judge's route (`HIMMEL_RM_JUDGE=model`) | only in the himmel repo with `judge` mapped in `roles.json` (see [The role map](#the-role-map)); there the launcher's fallback is off, and a failed lane call, a policy refusal included, makes `rm-run` rule the batch once on the subscription itself; a timed-out call ends the run |
| `scripts/cr/critic-first-pass.sh` (claude critic) | no standing row: the panel has no claude row, and the `claude_floor` critic (codex out of quota, with a loud alert from the panel) runs on the subscription, not the API lane; a claude row an adopter adds in `critics.local.json` is the only critic route here | provider `claude-api` for that adopter row; with the lane off, the refusal sends no alert (the lane is off by design) and the critic is skipped; a critic never runs on the subscription, for any refusal or failure; a policy refusal (exit 2 with the launcher's `claude-api: policy refusal:` line) makes the critic print `claude critic BROKE` and exit 1, never a clean skip |
| `scripts/graphify/graph-cadence.sh --semantic` | `claude-cli` when run bare; the armed `graph-publish-himmel` runner passes `claude-api` on auto | `GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api` |
| `scripts/cleanup/steering-cull-cadence.sh` | `claude-cli` | `STEERING_CULL_BACKEND=claude-api`, or `arm --backend claude-api --api-account A\|B\|C\|D` |

Both cadences default to the subscription (`claude-cli`) because every API
account (A, B, C and D) can run dry; the API lane is an explicit opt-in there.

## The failure path

A failed call still fails first, exactly as before: the refusal line
(`claude-api: refused: …`, exit 2), a managed fleet launch that was refused or
not committed (exit 10, before any request), a rejected account (exit 6, the
account is marked), or the call's own non-zero exit. A TERM, INT or HUP sent to the launcher
itself is its caller stopping it, for example `bulk-call.sh --cancel`, and sends
no alert and runs no fallback. During the call the launcher stops it, settles
and exits 143; once the call has ended it exits with its usual code, and a stop
that lands in the failure path ends that path too.
The call watchdog (`HIMMEL_API_CALL_TIMEOUT_S`) signals only the call, so a call
it stops is a failed call and takes the path below.

A policy refusal is the one refusal that takes no part of it: a call asking for account
`auto` under a kind the limit does not allow (see [Accounts C and D, and auto routing](#accounts-c-and-d-and-auto-routing))
prints `claude-api: policy refusal: …` and exits 2, with no alert, no alert stamp and no
fallback, whatever `HIMMEL_API_FALLBACK` says. It means a caller regressed, so it leaves
one line in `policy-refusals.jsonl` in the alert directory (`HIMMEL_API_ALERT_DIR`, by
default the stamp directory below), and the doctor's `C91-api-policy-refusals` check prints
one WARN per kind and repo, with a count, for a refusal in the last 48 h.

The api lane refuses a call only on a real block, and the refusal and its alert name it:
its own admission limit (`api bank gate said SKIPPED-FLEET`), a ledger lock another holder
keeps (`ledger-locked-or-unwritable`, with the lock path, age and holder), an invalid config
or ledger, a duplicate or invalid job id, or an api preflight that exits nonzero (a seam-guard
denial or a crash) or prints no known verdict (`api bank gate said BANK-UNKNOWN`, with a line
before it saying which). No budget figure refuses or delays a call, named
or auto: an unknown, stale or low credit reading (`BANK-UNKNOWN`, `BANK-STALE`,
`SKIPPED-BANK` from the api preflight), a past reset date or a ledger estimate over the
account's cap is our estimate, not a block. The launcher prints a note and the call goes on;
the per-call budget bounds it and the API's own credit answer decides. A credit-exhausted
answer marks the account (see the exhausted marker below), and a later successful call on
that account clears the mark. A mark never refuses a named call; auto routing ranks
unmarked accounts first.

`"enforce_budget": true` at the top level of the roster `config.json` opts back into the
enforcing gate: there the cap (`over-cap`), the headroom check and a stale reading refuse
as before. It is off by default.

On a credit-exhausted answer (exit 6) to an auto-routed call, the launcher marks the account
and re-runs the same call on the next unmarked account the call may use, one pass over the
accounts (`HIMMEL_API_ROTATE_TRIED` carries the tried letters to the re-run and only narrows
the pool). Only a replayable call rotates: one with its prompt in argv or buffered from stdin
and no `Edit`, `Write` or `Bash` grant. A named account never rotates. When no unmarked
account is left, the failure path below runs as usual.

A crashed ledger transaction can leave the lock directory behind. A waiter reclaims it only
when it is empty, older than the call timeout plus the kill grace, and its recorded holder
(`<lock>.pid`, beside the lock) is not running; a lock with contents, a young lock or a
running holder is never touched and refuses by name after the lock wait.

For every other failure the launcher:

1. **Decides whether to fall back** (first match wins):

   | Condition | Decision |
   |---|---|
   | `HIMMEL_API_FALLBACK` is not exactly `on` (unset, empty, `off` or any other value) | no fallback |
   | the call is kind `critic` (any refusal or failure) | no fallback; the critic is skipped |
   | the lane is off (`HIMMEL_API_LANE` not `on`), any kind | no fallback: the caller chose the API, not the subscription |
   | the request itself was refused (bad argument, run kind, cache TTL, job id or tool grant) | no fallback |
   | the call was granted `Edit`, `Write` or `Bash` and ran (it may have half-done its edits; a rejected account can answer on a later turn) | no fallback; only a refusal before any request (exit 2) falls back |
   | the native usage preflight says `PROCEED`, `BANK-STALE` or `BANK-UNKNOWN` | **runs the fallback** |
   | the preflight says `SKIPPED-BANK` or `SKIPPED-FLEET` (or nothing) | no fallback |

   The preflight is `scripts/lib/usage-preflight.sh` on the native lane, worker
   `sub-fallback:<kind>:<job>`, with every API-key variable removed.

2. **Sends one Telegram alert** through the existing notification sender
   (`scripts/telegram/session-status.ts notification`), type
   `api-lane <class>`:

   ```text
   kind judge, account A, call-failed (exit 1): error_during_execution; fallback: off (HIMMEL_API_FALLBACK unset: default off)
   ```

   - The class is `refused`, `rejected` (exit 6) or `call-failed`.
   - **Who is told.** A `call-failed` alert (a per-call budget cap such as
     `error_max_budget_usd`, a call timeout, any other non-zero exit) is the chief's
     to handle, so it is one line in a chief's bridge inbox
     (`<bridge root>/consoles/<name>.md`, tagged `[api-lane call-failed]`) and no
     Telegram message. Only a chief whose waiter heartbeat is under 30 minutes old
     and whose waiter has not exited counts as armed (a waiter that exited on a
     `wake-` reason still does; a chief that has stopped leaves its inbox file
     behind, and that file takes no line once its waiter has exited on a
     non-`wake-` reason or its heartbeat has aged out; a wait file with no
     recognised `state=` takes none either). The inbox is `HIMMEL_CONSOLE_NAME`'s when that
     chief is armed, else the armed chief with the freshest heartbeat across every
     project; the launcher never creates an inbox. With no armed chief inbox it pages the
     operator as below, so an alert is never lost. A `rejected` alert (credit gone,
     or the key is invalid) and an eval `refused` alert need an operator act and
     still page the operator, whatever chief is armed. The message class is
     `api-lane-call-failed` (`silent`) in `scripts/telegram/message-classes.json`.
   - **A refusal alerts for the eval only.** The API lane's own use is the eval
     (`HIMMEL_API_KIND=eval`). A `refused` call of any other kind (a critic, a
     judge, a bulk call, and a lane that is off by design) sends no alert: the
     launcher prints `claude-api: alert: none sent` on stderr and the refusal line
     stands. `rejected` and `call-failed` still alert for every kind.
   - The reason is one line of at most 200 characters. The key, any key the caller
     holds and anything shaped like `sk-ant-…` become `[key]`. The call's result
     text is never included.
   - At most one alert per run kind and class per hour. The stamp is written only
     after the sender exits 0, so a failed send does not mute the next failure.
     The stamp files live in `~/.himmel/state/api-lane-alerts/`.
   - The sender runs with every `ANTHROPIC_*`, `LQ_API_*` and
     `CLAUDE_CODE_OAUTH_TOKEN` variable removed. It goes to
     `TELEGRAM_GROUP_CHAT_ID`, or to the operator chat `TELEGRAM_CHAT_ID` when no
     group id is set (both read from the environment, `himmel.conf` or `.env`).
   - An alert is never dropped silently. With no chat id, with an explicitly empty
     `TELEGRAM_GROUP_CHAT_ID` (a deliberate suppression of the send), without
     `bun`, or when the sender fails (a timeout included), the launcher prints `claude-api: alert NOT delivered (<why>)` on stderr
     and appends one row to `undelivered.jsonl` in the alert directory (kind,
     class, exit code, the redacted reason and why; never a key or a chat id). It
     writes no stamp, so the next failure alerts again.

3. **Runs the fallback**: the same prompt, once, as a subscription `claude -p`.
   - Same model, permission mode, tool grant, budget cap and effort, with
     `--output-format json`.
   - Native auth (`scripts/lib/native-auth-pin.sh`), every `HIMMEL_API_*` and
     `LQ_API_*` variable removed, and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`. The
     launch is refused if any API-key name or the key's value is still in its
     environment.
   - A prompt on stdin is kept in a mode-600 scratch file
     (`claude-api-prompt.*` under `TMPDIR`) that the API call reads and the
     fallback replays byte for byte; the file is removed on every trapped exit
     path. A terminal on stdin is refused, the read is cut at
     `HIMMEL_API_CALL_TIMEOUT_S` on every host, and a prompt over 8 MiB is
     refused with no fallback. A refusal before the prompt is
     buffered has not read stdin, so a piped prompt still reaches the fallback.
   - The fallback's stdout is the launcher's stdout, and its exit code replaces
     the API exit code. A caller sees an ordinary result (judge-call records the
     verdict, bulk-call writes `OK`) when the fallback succeeds.

## The per-caller switch

`HIMMEL_API_FALLBACK` is **off by default** (operator decision 1140, which
supersedes the earlier default-on contract). Only the exact value `on`
opts a caller in; unset, empty, `off` and any other value are off. The failure
still alerts and the original exit code stands; the alert says which off it was:
`fallback: off (HIMMEL_API_FALLBACK unset: default off)`,
`fallback: off (HIMMEL_API_FALLBACK=off)` or
`fallback: off (HIMMEL_API_FALLBACK=<value> is not on)`. No caller sets `on`.
When a caller does, the usage preflight remains the gate on the subscription bank.

## Records

The fallback appends one row to the same `launches.jsonl` as the API call:

| Field | Value |
|---|---|
| `lane` | `sub-fallback` |
| `outcome` | `sub-fallback`, or `sub-fallback-failed` on a non-zero exit |
| `cost_usd` | empty (no API credit spent) |
| `sub_cost_usd` | the subscription call's reported cost |
| `rc` | the fallback's exit code |
| `api_rc` | the original API exit code |
| `api_class` | the original failure class |
| `kind`, `job_id`, `branch`, `head`, `pr` | as on the API row |

The API call's own row and its reservation are settled as before.

### The native release judge row (parked)

The release judge is parked: the door places requests with no model call, so this writer fires only under `HIMMEL_RM_JUDGE=model`.

`launches.jsonl` has a second writer: the release judge's subscription run (`liveJudge` in
`scripts/jira/src/commands/release.ts`) appends one `kind=judge` row per run, after the call returns. It is not
an API call, so it takes no reservation and `claude-api.sh` never sees it.

| Field | Value |
|---|---|
| `lane` | `native` |
| `outcome` | `native`, or `native-failed` on a non-zero exit or a timeout |
| `session_id` | the id passed to `claude --session-id`; the transcript is `<session_id>.jsonl` |
| `cost_usd` | empty (no API credit spent) |
| `sub_cost_usd` | the call's verified `total_cost_usd` (six places), empty when the call failed or printed none |
| `rc` | the call's exit code (1 when it threw without one) |
| `input_tokens` | the call's plain input tokens, read from the envelope's `usage` (the Opus call alone: the Haiku title call is in `modelUsage` only); null when the row has no cost or the call reported no usable usage |
| `cache_creation_tokens` | the call's cache-write tokens; null on the same condition |
| `cache_read_tokens` | the call's cache-read tokens; null on the same condition |
| `cache_ttl` | the tier the call's environment asks for: `off`, `5m` or `1h` |

A reader that sums API dollars skips every row with a `lane` other than `api` (the API launcher's own rows carry
no `lane`): `shift-spend.mjs` does, so the native and `sub-fallback` rows are neither summed nor counted as unpriced.
`scripts/usage/release-judge-reconcile.sh` is the read-only check that each release judge transcript has its row.

## Accounts C and D, and auto routing

Account C is a third API org with a 200.00 USD cap. Account D is a fourth API org. A, B, C and D are treated
identically: the same refusals (key from the caller `ANTHROPIC_API_KEY` or a mode-600 `key-<letter>.env` beside the
ledger, `HIMMEL_API_KEY_ID` equal to the roster `key_id`, lane on, and with `enforce_budget` on, a ledger spend estimate under the account's cap) and
`pickAccount` ranks all four by grant expiry. The batch client (`semantic-batch.mjs`) takes C and D the same way. The
lane never reads the keyring or `.env`. Any other letter (E and on) is refused everywhere.

The account list has one owner per language: `ACCOUNTS` in `scripts/lib/api-credit-state.mjs`, and
`LLM_API_ACCOUNTS` in `scripts/lib/llm-backend.sh` (with the forms callers need: the letter class, the readable
list, the `-u ANTHROPIC_ORG_<L>_KEY` arguments, the walk check and the pick extract). `test-llm-backend.sh` pins the
two equal. A new account is one letter in each.

To add account D:

1. Add a `D` row to the roster `~/.himmel/state/api-credit/config.json`, beside A, B and C:
   `organization_id`, `cycle_id`, `cap_usd` and `key_id` (all non-secret), and `reset_at` (D has no default date).
2. Write the key file `~/.himmel/state/api-credit/key-D.env` (beside the ledger) with one line,
   `ANTHROPIC_API_KEY=<key>`, mode 600, owned by you.
3. Optional: `ANTHROPIC_API_ORG_ID_D` in `~/.himmel/himmel.conf`, matching `_A`, `_B` and `_C`; and the Admin key
   `ANTHROPIC_ORG_D_KEY` in `.env`, only for the automatic credit snapshot
   (`node scripts/api-lane/grant-snapshot.mjs --pull D`).

Wherever an output names an account's key, it shows only the key's last 4 characters, as `...<last4>`: the
`api-credit-state.mjs accounts` listing (its `key` field), the config UI's account table, doctor C92 and the lane's
key-id and key-rejected lines. An account with no readable key file shows `key: none`. Nothing prints more of a key.

Auto routing is for the himmel repo only. `HIMMEL_API_ACCOUNT=auto` is accepted for any kind (the role map or the
default order picks the accounts, see below) and a caller whose git common dir is the launcher's own checkout. For the
graph pass, `semantic-update.sh` judges the corpus repo once, before any pick, in both the batch and the synchronous
path (the shim runs the lane from a scratch directory, so it hands the judged repo over in
`HIMMEL_API_AUTO_REPO_DIR`). A call from another repo (the luna graph map), exits 2 before
any spawn or batch submit, with no subscription fallback. Naming the account (`HIMMEL_API_ACCOUNT=A`, `B`, `C` or
`D`) works for every kind and every repo, judge, critic, bulk and cull included.

Config names: `ANTHROPIC_API_ORG_ID_C` and `ANTHROPIC_API_ORG_ID_D`, matching `ANTHROPIC_API_ORG_ID_A` and `_B`.
Every site that unsets the A and B keys before a subscription `claude -p` also unsets `ANTHROPIC_ORG_C_KEY` and
`ANTHROPIC_ORG_D_KEY`. The key files `key-C.env` and `key-D.env` are written by the operator, never by a script.

### The role map

`roles.json` says which accounts auto routing may use for each routable kind. It sits beside the account roster
`config.json` (default `~/.himmel/state/api-credit/roles.json`; `HIMMEL_API_CREDIT_CONFIG` moves both) and holds no
secret, only role names and account letters:

```json
{ "version": 1, "roles": { "judge": ["B"], "graphify": ["A", "C"] } }
```

- **Known roles** are the `ROLES` export of `scripts/lib/api-roles.mjs`, the one owner of reading, validating and
  writing the file: `graphify`, `judge` and `critic`. `probe` and `other` are never roles. Critics route on auto
  through the role map (operator decision 1066): a PR critic on auto uses the accounts its `critic` entry names.
- **No entry means the default order (decision 1185).** Under auto, a kind with no role entry, a missing file, or a
  kind outside `ROLES` is served from every configured account in the default order, the order the judge uses; the
  critic is served this way, from a temp directory too (`critic-first-pass.sh` passes `HIMMEL_API_AUTO_REPO_DIR`, the
  launcher's own repo, so the same-repo check holds). Only a broken map refuses (`walk <kind>` exit 3, no alert, no
  fallback), and a critic call never takes the subscription fallback.
- **Four states.** `absent` (no file): the default. `valid`: the map. `partial` (the file parses but an entry has an
  error): the live entries apply, each ignored role falls back to the default. `invalid` (not JSON, `version` is not 1
  or `roles` is not an object): the whole file is ignored and every auto call refuses (`walk <kind>` exit 3, `invalid-role-map:<reason>`); fix or
  remove the file. A broken map never touches `config.json`; the graph walk's refusal is described below.
- **Dropped letters.** An unknown role (`unknown-role:<name>`) is ignored. An unknown letter in a list
  (`unknown-account:<role>:<letter>`) is dropped and the entry stays live with the rest: `judge: ["B", "E"]` routes
  to B. An empty or non-array list (`empty-role:<role>`) is ignored. A duplicate letter is deduped silently. A known
  letter with no roster row is valid in the map and skipped at pick time; `api-roles.mjs check` warns
  `no-configured-account:<role>` when none of a role's letters is configured.
- **A pick stays inside the role.** The launcher asks `api-roles.mjs accounts <kind>` (the graph walk asks `walk
  graphify`, below) and passes the answer to `api-credit-state.mjs pick --usd N --only <letters>`. A role mapped to B
  is served by B or refused (`no account has room`), never by A. A named account never reads the map.
- **The graph walk has one owner.** `node scripts/lib/api-roles.mjs walk graphify` prints the letters the station's
  graph pass walks on auto, comma-joined: the map's live `graphify` letters, else every configured account, else every
  account letter (A, B, C and D) when the roster cannot be read (the pick then refuses on the same roster). The batch walk and the shim count
  in `semantic-update.sh`, the up-front check and shim count in `refresh-graph-map.sh`, the launcher's auto branch for
  `HIMMEL_API_KIND=graphify` and doctor C92 all read this answer; none of them reads the map's state itself. The
  station's walk is whatever `roles.json` says; no code pins a letter.
- **A map that would widen the graph walk refuses it.** Two kinds of damage would put back every configured account:
  an `invalid` map, and a `graphify` entry with no letter from A, B, C and D (`empty-role:graphify`). For these `walk
  graphify` prints `refuse <cause>` and exits 3, and each auto graph path stops before any account call:
  `semantic-update.sh` prints `semantic-update: refusing the batch: graph role map broken (<cause>); fix or remove
  roles.json` and exits 2 (on the synchronous path once, before extraction, so no chunk is sent and no file earns a
  stuck record); `refresh-graph-map.sh` prints `refresh-graph-map: refusing the semantic pass: graph role map broken
  (<cause>); fix or remove roles.json` once and exits 2; the launcher prints `claude-api: refused: graph role map
  broken (<cause>); fix or remove roles.json` and exits 2 before any spawn. That refusal is not a policy refusal: it
  writes no `policy-refusals.jsonl` row (C91 stays quiet), sends no alert and never runs the subscription fallback,
  whatever `HIMMEL_API_FALLBACK` says. Doctor C93 (`C93-graph-role`) WARNs on it and says the pass refuses. Other
  damage walks as before (an entry that keeps one live letter walks it; an entry naming only unconfigured letters is
  refused by the pick) and C93 still WARNs on it; an absent or valid map is OK.
- **A rejected key is flagged on every path.** A rejected key is the batch client's HTTP 401 or 403 (exit 6), or the
  launcher's `invalid api key` answer; the launcher's credit-too-low answer also exits 6 but is an empty account, not
  a rejected key. On every path (auto, a named account, `--account-order`) a rejected key runs
  `api-credit-state.mjs key-rejected`, which sets `key_rejected_at` on the account's ledger row, and `accounts` then
  tags the account `key rejected` (ahead of `marked exhausted`; the API roles card shows the tag). The graph batch and
  a launcher call of `HIMMEL_API_KIND=graphify` also raise the cadence alert `graph-key-<L>` (`account <L> API key
  rejected`, fix line `rotate ~/.himmel/state/api-credit/key-<L>.env, or remove <L> from the route or the graphify
  role`); another kind sets the tag alone. The graph batch walk moves on to the next letter, never to the
  subscription. A launcher call with the fallback on can still replay on the subscription after a rejected key, as
  before; the rule that a rejected key never reaches the subscription (A11) lands with the daily pass (S4, row P25). Doctor
  `C92-graph-key-<L>` WARNs, one id per letter, while a tagged letter is in the graph walk: `walk graphify` on a
  publisher or an unreadable graph config, the stored route on an adopter. A tagged letter no walk reaches, or one
  behind a refusing map, reads OK with a note. No reader opens a key file.
- **The tag clears on the next accepted call.** An accepted batch submit or launcher call of any kind on L runs
  `key-ok`, which removes the mark and prints `cleared` (or prints `none` and writes nothing when there was no mark);
  on `cleared` the caller runs `cadence-alert.sh clear graph-key-<L>`, so the alert's dedupe sentinel never outlives
  the tag and the next real rejection alerts again. A save on the API roles card that takes L out of the graph walk
  clears the alert too, but keeps the tag: the key is still wrong until a call on it is accepted.
- **The graph batch walks the accounts.** On auto, a credit-exhausted answer or a rejected key (HTTP 401 or 403, the
  batch client's exit 6) marks the account and the pick runs again over the accounts of the same list that were not
  yet tried, so a pass reaches C when A is out of credit and B's key is dead. Each account is tried at most once per
  pass, so a role mapped to one account is tried once and fails. When none is left the pass stops with
  `every account tried is out of credit or rejected its key (A credit exhausted, B API key rejected, C ...); nothing
  submitted`; each retry line and the final failure name the accounts tried. ONLY those two answers move on: a
  network or server error, a rate limit or a refusal stops the pass at once (`only a credit-exhausted or rejected-key
  answer tries the next account`), because the next account would fail the same way or bill for nothing. Walking the accounts never submits a second batch: one batch
  per pass, as before. The synchronous path's breaker stops dispatch after one rejection per account in play.
- **`--account-order` walks the letters it is given.** `semantic-update.sh --account-order C,A` (the claude-api
  batch only: `GRAPHIFY_API_BATCH=0` or another backend is refused) walks those letters in that order, and reads
  neither the role map nor a caller's account. It reads `api-credit-state.mjs accounts` once and skips, with a line, a
  letter with no configured roster row (an unconfigured letter, or one the roster does not know, such as D); an
  unreadable roster skips none. Each remaining letter goes through `pick --usd N --only <letter> --rows`, so the
  stated order wins over grant-expiry rank. A letter with no room is skipped with a line; a row reading
  `BANK-UNKNOWN` (a corrupt ledger, an unreadable roster), or an answer with no rows, stops the walk; a credit-exhausted or rejected-key answer
  marks the letter and moves on, as above; anything else stops. `--rows` adds each candidate's own verdict to a
  refusal, and only this walk passes it, so the refusal lines of the auto pass and the lane are unchanged. Under the
  flag an estimate still over `--max-run-usd` after sizing refuses the submit (`over-cap`) instead of sending the
  one-file floor. Without the flag the one-file floor still reaches the batch client, which refuses a batch whose
  estimate is over the cap (`semantic-batch.mjs submit`, exit 7, mapped to `over-cap` too): the cap is a ceiling for a
  batch, and `semantic-batch.mjs bound` gives the planner the same per-request figure the client sums. `--result-file F` writes one word on every exit, and a second line `rejected <letters>` when a key
  was rejected; the script header lists the words. With neither flag the pass runs as before.
- **An exhausted marker clears on its own.** `api-credit-state.mjs exhausted` writes `exhausted_at` for the account.
  Auto skips a marked account for `EXHAUSTED_TTL` (3600 seconds), or sooner when the operator snapshot holds a reading
  newer than the marker (refresh the snapshot after funding the account and the next pick uses it). An account marked
  while no other has room still serves, the one marked longest ago first, so a pick is never refused for the marker
  alone. Covered by the rows T93 and T93b of `scripts/graphify/test-semantic-update.sh`, which run the real pick over a
  marker older than an hour with a valid reading taken before the marker, and by `api-credit-state.test.mjs`.
  After a rotated key the operator clears the mark at once instead of waiting out the TTL:
  `HIMMEL_API_ACCOUNT=<L> node scripts/lib/api-credit-state.mjs clear-exhausted` removes `exhausted_at` and prints
  `cleared` (or prints `none` and writes nothing when the account had no mark). A successful `claude-api.sh` call
  clears it the same way, and `status` prints `marked_exhausted` while a mark is in force.
- **Nothing chosen on the API backend makes no API call.** With `GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api` and the lane
  off (`HIMMEL_API_LANE` unset) the cadence refuses the whole fire (exit 1) before any call; a direct call of
  `semantic-update.sh` refuses with exit 2 and says no API semantic call is made. Either way graphify makes no API semantic call. The
  `claude-cli` backend does not read the lane: it draws the subscription.
- **The judge opt-in (parked judge only).** With `judge` mapped, the release judge tries the mapped account through the launcher first
  (fallback off, no tools, an empty working directory, a two-dollar cap) and answers from the subscription on any
  failure. With `judge` unmapped it never touches the launcher. Only the himmel project's mirror reaches this route.
- **Tools.** `node scripts/lib/api-roles.mjs check` prints the map state, warnings and `ROLES`;
  `write` takes the full document on stdin, validates it, and writes atomically with mode 600 (an empty `roles`
  removes the file); `node scripts/lib/api-credit-state.mjs accounts` prints each account's cap, a bank tag and its
  key as `...<last4>` (or `none`).
- **In the config UI.** Configure, then Secrets, then Multi accounts lists accounts A, B, C and D with their bank tag,
  key (last 4 characters) and roles, and edits the map through the same `write` command (`GET`/`POST /api/api-roles`). After a change to that
  section, run `bash scripts/vm/multi-accounts-e2e.sh <vm>` on a free test VM that holds this checkout: it starts the
  config UI once per role-map state on a throwaway HOME and asserts the route and what auto routing reads.

Limit: auto routes only from the himmel repo even for a mapped role, upgrade path: plan P1 widens it per repo once the launcher reads the egress matrix (`scripts/guardrails/egress-matrix.json`).

Limit: `block-himmel-config-writes.sh` refuses an agent's Write, Edit, `apply_patch` and Bash write routes to `roles.json` (and a Bash `api-roles.mjs write`), but it is a speed bump, not a fence: Bash is a text match, so a renamed copy or an indirect spelling is not caught. Hand edits at the operator's own prompt are supported and validated on read; upgrade path: a sha256 attestation sidecar plus a doctor WARN.

### Caching recommendation for the graph pass

Measured from `launches.jsonl` (no new spend): across 470 untyped, 244 judge, 93 critic and 67 bulk launches the
lane writes 20.8M, 7.7M, 2.5M and 1.5M cache-creation tokens against 0.7M, 2.0M, 2.8M and 4.4M cache-read tokens.
Call kinds that do not reuse their prefix pay the cache write (1.25 x input at 5 minutes, 2 x at 1 hour) and
read little; the kinds that share a long prefix (bulk, eval) read three to ten times what they write.

The graph pass is the second kind: every chunk prompt opens with graphify's fixed extraction instructions.
Recommended, cheapest first:

1. Keep the Message Batches API (half price) with the shared prefix as one cached system block at the 1-hour tier,
   as `semantic-batch.mjs` already does. Batch and prompt caching combine: the batch discount applies to the cache
   write and read rates alike, and a batch runs longer than 5 minutes, so the 1-hour tier is the one that survives it.
2. Rely on graphify's on-disk extraction cache so only changed files are re-extracted; that cuts the chunk count,
   which is the largest lever.
3. Use synchronous calls (`GRAPHIFY_API_BATCH=0`) only for a small changed set; there the 5-minute tier is enough
   and the write premium is smaller, but the full price is twice the batch price.

The measured per-run cost and cache read/write split for C is posted on the account C ticket after the one bounded run.

## The OpenAI lane

`scripts/api-lane/openai-api.mjs` sends one tool-free prompt to the OpenAI Responses API, billed to a named
OpenAI account, under the same cap / reserve / settle ledger as the Anthropic lane. It keeps its own roster, so
an OpenAI account and an Anthropic account never share a ledger. It is OFF unless the launching shell sets
`HIMMEL_API_LANE=on`.

```text
node scripts/api-lane/openai-api.mjs -p [prompt] --model M --max-budget-usd N [--output-format text|json] \
    [--effort none|low|medium|high|xhigh] [--append-system-prompt-file F]
```

With no prompt after `-p` the prompt is read from stdin (a terminal and a prompt over 8 MiB are refused).
For GPT-6.2 Sol and Astra, the launcher sends the system-prompt file as a developer message before
the user prompt so reusable instructions are eligible for prefix caching. It maps `--effort none`
to `low`. Earlier models keep top-level `instructions` and receive effort as provided.
[OpenAI GPT-6.2 migration guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6.2-astra#migration-quickstart)

| Env | Meaning |
|---|---|
| `HIMMEL_API_LANE=on` | required |
| `HIMMEL_OPENAI_ACCOUNT=A\|B\|C\|D` | the account to bill; `auto` is refused |
| `HIMMEL_OPENAI_CREDIT_CONFIG` | the roster, default `~/.himmel/state/api-credit-openai/config.json` |
| `HIMMEL_OPENAI_BASE_URL` | test seam, default `https://api.openai.com/v1` |
| `HIMMEL_API_CALL_TIMEOUT_S` | the call is aborted at this age, default 3600 |

### Setup

The roster has the same shape as the Anthropic one; `cap_usd` is the credit left for the month:

```json
{
  "version": 1,
  "ledger_path": "/home/<you>/.himmel/state/api-credit-openai/ledger.json",
  "accounts": { "A": { "organization_id": "org-openai-a", "cycle_id": "2026-11", "cap_usd": "25.000000" } }
}
```

The key lives beside the ledger, in `key-<letter>.env` (`key-A.env` for account A): one line,
`OPENAI_API_KEY=<key>`, a regular file, mode 600, owned by the user running the launcher. The operator writes
it, and the launcher refuses any other shape. `OPENAI_API_KEY` in the environment is never used, and the key is
never printed, logged or put on a command line; a provider error line is redacted before it is shown.

This lane has no credit snapshot, so the ledger and `cap_usd` decide: a budget above the cap minus what is
settled and reserved is refused. When the monthly credit resets, put the new credit in `cap_usd`, give the
account a new `cycle_id` and a new `ledger_path` in the same directory (for example `ledger-2026-12.json`, so the
key file is still found). The ledger refuses a roster whose cycle differs from the one it recorded, so the old
cycle's spend is never hidden by an edit.

### Spend bound

A call cannot cost more than `--max-budget-usd`. The launcher takes an upper bound of the input (the UTF-8
bytes of the instructions and the prompt, plus 256), prices it at the model's input rate, and sets
`max_output_tokens` to what the rest of the budget buys at the output rate, at most 128000. Fewer than 16
tokens refuses with `budget too small`. The whole budget is reserved before the request, and the call is
settled afterwards at the priced usage (cached input at the cached rate, reasoning tokens counted as output).
Costs are whole micro-dollars, rounded up.

### Prices

`scripts/api-lane/openai-prices.json` holds the standard-tier rates in USD per 1M tokens (`input`,
`cached_input`, `output`) per model, with the date and the source page. A model that is not in the table is
refused. To add or change a model, edit that file from the pricing page and update `as_of`; a rate may have at
most three decimal places.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | the response completed |
| 1 | an HTTP error, a network error, or an incomplete response (an incomplete one is still settled and its text printed) |
| 2 | a refusal before any request (the line starts `openai-api: refused:`) |
| 6 | HTTP 401 or `invalid_api_key` (the account is marked key-rejected), or 429 `insufficient_quota` (marked exhausted) |
| 124 | the call timed out; its cost is unknown and the reservation is marked unknown |

### Not in this lane yet

There is no `auto` account routing, no role map, no subscription fallback, no Telegram alert and no launch
record row. A caller names one account, and a failure shows only as the exit code and the stderr line.

## Test seams

- `HIMMEL_API_ALERT_CMD=<path>` replaces the Telegram sender. Every test that
  can reach the failure path sets a stub, so no test sends a real message.
- `HIMMEL_API_ALERT_DIR=<dir>` moves the rate-limit stamps.
- `HIMMEL_API_ALERT_ENV_ROOT=<dir>` reads the alert's chat ids from `<dir>/.env`
  instead of the primary checkout's, so a test of the real route never reads the
  station's ids.
- `HIMMEL_API_CLAUDE_BIN` already stubs `claude`, and the fallback runs the same binary.

## Known limits

- A SIGKILL or an OOM kill of the launcher leaves the mode-600 stdin prompt file in `TMPDIR`, because the EXIT trap cannot run, upgrade path: sweep `claude-api-prompt.*` files older than the call timeout at launch.
- Two failures of the same kind and class at the same moment can both send an alert (the stamp is checked, then written after the send, up to 30 seconds later), upgrade path: an atomic `mkdir` lock if duplicate alerts show up.
- The fallback has no watchdog of its own; it is bounded by the caller's timeout (judge-call's `--timeout`) and its budget cap, upgrade path: reuse the launcher's watchdog for the fallback.
- With `HIMMEL_API_FALLBACK=on`, a looping caller (bulk, graphify) continues item by item on the subscription after the API account is marked, one alert per hour, upgrade path: a per-run circuit breaker if the subscription draw becomes a problem. graphify's own breaker trips only when the fallback does not run (`HIMMEL_API_FALLBACK` not `on`, the default, or a skipped usage preflight, the lane's exit 6), and it books a replayed chunk's cost to neither its API spend nor its reserve file.
- Fallback rows carry no API cost, so the shift-spend report does not price them, upgrade path: price `sub_cost_usd` in the subscription spend view.
- A call stopped by the API watchdog (`HIMMEL_API_CALL_TIMEOUT_S`) counts as a failed call, so its prompt reruns on the subscription, upgrade path: skip the fallback for a timeout if reruns of long calls cost too much.
