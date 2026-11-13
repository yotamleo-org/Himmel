# The API lane: failure alert and subscription fallback

`scripts/api-lane/claude-api.sh` runs one print-mode `claude` call billed to an
API account (`HIMMEL_API_ACCOUNT=A|B|C|auto`; auto only for the himmel graph pass, or a kind the role map maps) instead of the subscription. It is
OFF unless the launching shell sets `HIMMEL_API_LANE=on`. This page covers what
happens when a call on it fails. The launcher's header lists the
full argument and environment contract.

`auto` picks the account among those allowed; whether a feature runs at all is that
feature's own switch.

## Who uses it

| Caller | Default backend | How it reaches the API lane |
|---|---|---|
| `scripts/api-lane/judge-call.sh` | API lane | always (a chief's verdict question) |
| `scripts/api-lane/bulk-call.sh` | API lane | always |
| `jira release rm-run` (release manager) | the subscription | only in the himmel repo with `judge` mapped in `roles.json` (see [The role map](#the-role-map)); there the launcher's fallback is off, and a failed lane call, a policy refusal included, makes `rm-run` rule the batch once on the subscription itself; a timed-out call ends the run |
| `scripts/cr/critic-first-pass.sh` (claude critic) | the registry row's provider | provider `claude-api`; with the lane off, the refusal alerts (one per hour) and the review runs on the subscription; a policy refusal (exit 2 with the launcher's `claude-api: policy refusal:` line) makes the critic print `claude critic BROKE` and exit 1, never a clean skip |
| `scripts/graphify/graph-cadence.sh --semantic` | `claude-cli` when run bare; the armed `graph-publish-himmel` runner passes `claude-api` on auto | `GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api` |
| `scripts/cleanup/steering-cull-cadence.sh` | `claude-cli` | `STEERING_CULL_BACKEND=claude-api`, or `arm --backend claude-api --api-account A\|B\|C` |

Both cadences default to the subscription (`claude-cli`) because every API
account (A, B and C) can run dry; the API lane is an explicit opt-in there.

## The failure path

A failed call still fails first, exactly as before: the refusal line
(`claude-api: refused: …`, exit 2), a rejected account (exit 6, the account is
marked), or the call's own non-zero exit. A TERM, INT or HUP sent to the launcher
itself is its caller stopping it, for example `bulk-call.sh --cancel`, and sends
no alert and runs no fallback. During the call the launcher stops it, settles
and exits 143; once the call has ended it exits with its usual code, and a stop
that lands in the failure path ends that path too.
The call watchdog (`HIMMEL_API_CALL_TIMEOUT_S`) signals only the call, so a call
it stops is a failed call and takes the path below.

A policy refusal is the one refusal that takes no part of it: a call asking for account
`auto` under a kind the limit does not allow (see [Account C and auto routing](#account-c-and-auto-routing))
prints `claude-api: policy refusal: …` and exits 2, with no alert, no alert stamp and no
fallback, whatever `HIMMEL_API_FALLBACK` says. It means a caller regressed, so it leaves
one line in `policy-refusals.jsonl` in the alert directory (`HIMMEL_API_ALERT_DIR`, by
default the stamp directory below), and the doctor's `C91-api-policy-refusals` check prints
one WARN per kind and repo, with a count, for a refusal in the last 48 h.

For every other failure the launcher:

1. **Decides whether to fall back** (first match wins):

   | Condition | Decision |
   |---|---|
   | `HIMMEL_API_FALLBACK=off` | no fallback |
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
   kind judge, account auto, refused (exit 2): api lane is OFF (set HIMMEL_API_LANE=on); fallback: running on the subscription (preflight PROCEED)
   ```

   - The class is `refused`, `rejected` (exit 6) or `call-failed`.
   - The reason is one line of at most 200 characters. The key, any key the caller
     holds and anything shaped like `sk-ant-…` become `[key]`. The call's result
     text is never included.
   - At most one alert per run kind and class per hour. The stamp is written only
     after the sender exits 0, so a failed send does not mute the next failure.
     The stamp files live in `~/.himmel/state/api-lane-alerts/`.
   - The sender runs with every `ANTHROPIC_*`, `LQ_API_*` and
     `CLAUDE_CODE_OAUTH_TOKEN` variable removed. An explicitly empty
     `TELEGRAM_GROUP_CHAT_ID` suppresses it. Without a chat id or `bun`, nothing
     is sent and the fallback still runs.

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

`HIMMEL_API_FALLBACK` is **on by default**. A caller that must never spend
the subscription sets `HIMMEL_API_FALLBACK=off`: the failure still alerts (the
alert says `fallback: off (HIMMEL_API_FALLBACK=off)`) and the original exit code
stands. `judge-call.sh`, `bulk-call.sh` and `critic-first-pass.sh` leave it on.
The usage preflight remains the gate on the subscription bank.

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

### The native release judge row

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

A reader that sums API dollars skips every row with a `lane` other than `api` (the API launcher's own rows carry
no `lane`): `shift-spend.mjs` does, so the native and `sub-fallback` rows are neither summed nor counted as unpriced.
`scripts/usage/release-judge-reconcile.sh` is the read-only check that each release judge transcript has its row.

## Account C and auto routing

Account C is a third API org with a 200.00 USD cap. A, B and C are treated identically: the same refusals (key from
the caller `ANTHROPIC_API_KEY` or a mode-600 `key-C.env` beside the ledger, `HIMMEL_API_KEY_ID` equal to the roster
`key_id`, lane on, ledger spend estimate under the account's cap) and `pickAccount` ranks all three by grant expiry.
The batch client (`semantic-batch.mjs`) takes C the same way. The lane never reads the keyring or `.env`.

Auto routing is off for every call except the himmel semantic graph pass. `HIMMEL_API_ACCOUNT=auto` is accepted
only with `HIMMEL_API_KIND=graphify` (or a kind the role map maps, see below) and a caller whose git common dir is the launcher's own checkout. For the
graph pass, `semantic-update.sh` judges the corpus repo once, before any pick, in both the batch and the synchronous
path (the shim runs the lane from a scratch directory, so it hands the judged repo over in
`HIMMEL_API_AUTO_REPO_DIR`). Any other kind, or a graph pass over another repo (the luna graph map), exits 2 before
any spawn or batch submit, with no subscription fallback. Naming the account (`HIMMEL_API_ACCOUNT=A`, `B` or `C`)
works for every kind and every repo, judge, critic, bulk and cull included.

Config name: `ANTHROPIC_API_ORG_ID_C`, matching `ANTHROPIC_API_ORG_ID_A` and `_B`. Every site that unsets the A and B keys before a subscription `claude -p` also unsets
`ANTHROPIC_ORG_C_KEY`. The key file `key-C.env` is written by the operator, never by a script.

### The role map

`roles.json` says which accounts auto routing may use for each routable kind. It sits beside the account roster
`config.json` (default `~/.himmel/state/api-credit/roles.json`; `HIMMEL_API_CREDIT_CONFIG` moves both) and holds no
secret, only role names and account letters:

```json
{ "version": 1, "roles": { "judge": ["B"], "graphify": ["A", "C"] } }
```

- **Known roles** are the `ROLES` export of `scripts/lib/api-roles.mjs`, the one owner of reading, validating and
  writing the file: `graphify` and `judge`. `probe` and `other` are never roles.
- **No map means the default.** With no file, the graph pass uses every configured account and every other kind is
  refused (exit 2, no alert, no fallback). A role with no entry gets the same default.
- **Four states.** `absent` (no file): the default. `valid`: the map. `partial` (the file parses but an entry has an
  error): the live entries apply, each ignored role falls back to the default. `invalid` (not JSON, `version` is not 1
  or `roles` is not an object): the whole file is ignored and the default applies, with `invalid-role-map:<reason>`.
  For every kind but the graph walk a broken map only takes away widening; it never refuses what the default allows
  and never touches `config.json`. The graph walk refuses instead, see below.
- **Dropped letters.** An unknown role (`unknown-role:<name>`) is ignored. An unknown letter in a list
  (`unknown-account:<role>:<letter>`) is dropped and the entry stays live with the rest: `judge: ["B", "D"]` routes
  to B. An empty or non-array list (`empty-role:<role>`) is ignored. A duplicate letter is deduped silently. A known
  letter with no roster row is valid in the map and skipped at pick time; `api-roles.mjs check` warns
  `no-configured-account:<role>` when none of a role's letters is configured.
- **A pick stays inside the role.** The launcher asks `api-roles.mjs accounts <kind>` (the graph walk asks `walk
  graphify`, below) and passes the answer to `api-credit-state.mjs pick --usd N --only <letters>`. A role mapped to B
  is served by B or refused (`no account has room`), never by A. A named account never reads the map.
- **The graph walk has one owner.** `node scripts/lib/api-roles.mjs walk graphify` prints the letters the station's
  graph pass walks on auto, comma-joined: the map's live `graphify` letters, else every configured account, else A, B
  and C when the roster cannot be read (the pick then refuses on the same roster). The batch walk and the shim count
  in `semantic-update.sh`, the up-front check and shim count in `refresh-graph-map.sh`, the launcher's auto branch for
  `HIMMEL_API_KIND=graphify` and doctor C92 all read this answer; none of them reads the map's state itself. The
  station's walk is whatever `roles.json` says; no code pins a letter.
- **A map that would widen the graph walk refuses it.** Two kinds of damage would put back every configured account:
  an `invalid` map, and a `graphify` entry with no letter from A, B and C (`empty-role:graphify`). For these `walk
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
  role`); another kind sets the tag alone. The walk moves on to the next letter, never to the subscription. Doctor
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
  one-file floor. `--result-file F` writes one word on every exit, and a second line `rejected <letters>` when a key
  was rejected; the script header lists the words. With neither flag the pass runs as before.
- **An exhausted marker clears on its own.** `api-credit-state.mjs exhausted` writes `exhausted_at` for the account.
  Auto skips a marked account for `EXHAUSTED_TTL` (3600 seconds), or sooner when the operator snapshot holds a reading
  newer than the marker (refresh the snapshot after funding the account and the next pick uses it). An account marked
  while no other has room still serves, the one marked longest ago first, so a pick is never refused for the marker
  alone. Covered by the rows T93 and T93b of `scripts/graphify/test-semantic-update.sh`, which run the real pick over a
  marker older than an hour with a valid reading taken before the marker, and by `api-credit-state.test.mjs`.
- **Nothing chosen on the API backend makes no API call.** With `GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api` and the lane
  off (`HIMMEL_API_LANE` unset) the cadence refuses the whole fire (exit 1) before any call; a direct call of
  `semantic-update.sh` refuses with exit 2 and says no API semantic call is made. Either way graphify makes no API semantic call. The
  `claude-cli` backend does not read the lane: it draws the subscription.
- **The judge opt-in.** With `judge` mapped, the release judge tries the mapped account through the launcher first
  (fallback off, no tools, an empty working directory, a two-dollar cap) and answers from the subscription on any
  failure. With `judge` unmapped it never touches the launcher. Only the himmel project's mirror reaches this route.
- **Tools.** `node scripts/lib/api-roles.mjs check` prints the map state, warnings and `ROLES`;
  `write` takes the full document on stdin, validates it, and writes atomically with mode 600 (an empty `roles`
  removes the file); `node scripts/lib/api-credit-state.mjs accounts` prints each account's cap and a bank tag.
- **In the config UI.** Configure, then Secrets, then Multi accounts lists accounts A, B and C with their bank tag and
  roles, and edits the map through the same `write` command (`GET`/`POST /api/api-roles`). After a change to that
  section, run `bash scripts/vm/multi-accounts-e2e.sh <vm>` on a free test VM that holds this checkout: it starts the
  config UI once per role-map state on a throwaway HOME and asserts the route and what auto routing reads.

ponytail: auto routes only from the himmel repo even for a mapped role, upgrade path: plan P1 widens it per repo once the launcher reads the egress matrix (`scripts/guardrails/egress-matrix.json`).

ponytail: nothing stops an agent with Write or Bash from creating `roles.json` and widening auto to the judge; hand edits are supported and validated on read, upgrade path: plan P4's write guard on `~/.himmel/state/api-credit/` plus a sha256 attestation sidecar and a doctor WARN.

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

## Test seams

- `HIMMEL_API_ALERT_CMD=<path>` replaces the Telegram sender. Every test that
  can reach the failure path sets a stub, so no test sends a real message.
- `HIMMEL_API_ALERT_DIR=<dir>` moves the rate-limit stamps.
- `HIMMEL_API_CLAUDE_BIN` already stubs `claude`, and the fallback runs the same binary.

## Known limits

- ponytail: a SIGKILL or an OOM kill of the launcher leaves the mode-600 stdin prompt file in `TMPDIR`, because the EXIT trap cannot run, upgrade path: sweep `claude-api-prompt.*` files older than the call timeout at launch.
- ponytail: two failures of the same kind and class at the same moment can both send an alert (the stamp is checked, then written after the send, up to 30 seconds later), upgrade path: an atomic `mkdir` lock if duplicate alerts show up.
- ponytail: the fallback has no watchdog of its own; it is bounded by the caller's timeout (judge-call's `--timeout`) and its budget cap, upgrade path: reuse the launcher's watchdog for the fallback.
- ponytail: a looping caller (bulk, graphify) continues item by item on the subscription after the API account is marked, one alert per hour, upgrade path: a per-run circuit breaker if the subscription draw becomes a problem. graphify's own breaker trips only when the fallback does not run (`HIMMEL_API_FALLBACK=off` or a skipped usage preflight, the lane's exit 6), and it books a replayed chunk's cost to neither its API spend nor its reserve file.
- ponytail: fallback rows carry no API cost, so the shift-spend report does not price them, upgrade path: price `sub_cost_usd` in the subscription spend view.
- ponytail: a call stopped by the API watchdog (`HIMMEL_API_CALL_TIMEOUT_S`) counts as a failed call, so its prompt reruns on the subscription, upgrade path: skip the fallback for a timeout if reruns of long calls cost too much.
