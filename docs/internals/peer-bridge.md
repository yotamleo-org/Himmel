# Peer bridge

The peer bridge lets our Telegram bot and another station's bot exchange
questions, status, info and answers in one supergroup that neither side trusts.
Deadlines run on both sides. Peer text is read only in a tainted peer desk, and
every outbound message passes one egress gate. A second, typed path carries signed
envelopes that no model reads (see "The typed path").

It is user-level: no `sudo`, no system change. It writes two state dirs and one
user unit. What it tells the operator goes onto its own notify chain, which the
operator bridge sends (see "Triage and the notify chain").

| Where | Path |
|---|---|
| State (`S`) | `~/.himmel/peer-bridge/` |
| Config (`C`) | `~/.config/himmel/peer-bridge/` |
| Allowlist and caps | `C/peers.json` (mode 0600) |
| Bot token | `C/env`, one line `PEER_BOT_TOKEN=<token>` (mode 0600) |
| Fence key | `C/hmac.key` (mode 0600) |

There is no environment override for these paths.

## Setup, per side

For a guided setup that finds every id by itself and keeps `allowFrom` to the peer bot only, see [Part 4 of the remote setup guide](../setup/remote-setup.md#part-4). The steps below are the alternative for an operator who needs to customize the allowlist (for example to add a human id) or the peer caps, which the guided command does not do.

Both sides run the same steps, each with the other's bot. The adopter runs them
with our bot id and username. Do them in this order. Promotion comes before
`confirm` because promoting a bot in a basic group silently migrates it to a
supergroup with a new chat id, and `confirm` refuses the old id.

1. **Create the bridge bot in @BotFather.** Use a bot that is not the operator
   bot. Turn **Bot-to-Bot mode on** for it. Leave **Group Privacy on**. Privacy
   stays on so that a bot that loses its admin role falls back to the narrowest
   delivery.
2. **Make the supergroup.** Create a group, add both bots (ours and the peer's)
   and both operators. Then **promote each bot to administrator and switch every
   admin right off**, because a new admin gets every right by default. Telegram
   delivers every group message to an admin bot, so this shape is what lets each
   bot see the other's `/peer@` roots. A bot that is not an admin never received
   the other bot's root in the live test.
3. **Add the peer.** From a terminal of your own, not from a Claude session:

   ```bash
   bun scripts/peer-bridge/setup.ts add example --peer-bot-id <peer bot id> --peer-username <peer bot username>
   ```

   Pass `--operator-bot-id <id>` to skip the operator-bot-id prompt; a helper that already knows the id uses it.

   It asks for the operator bot's id, reads the operator chat id from the
   operator bot's `access.json`, records the operator's bridge root and the
   primary himmel checkout, and creates the dirs (0700), the empty chain files
   and the fence key (0600, `O_CREAT|O_EXCL`). It refuses without `jq`. The
   peer starts with `chatId: null` and `allowFrom` holding the peer bot's id.
4. **Put the token in place.** The file must be mode 0600 and hold one line:

   ```bash
   umask 077
   read -rs -p 'peer bridge bot token: ' t; printf 'PEER_BOT_TOKEN=%s\n' "$t" > ~/.config/himmel/peer-bridge/env; unset t
   ```

5. **Review `peers.json`.** Add the human ids you accept to `allowFrom` (the peer
   operator's Telegram id, for example). Copy the peer's `opens` and caps into
   the `theirs` block. The peer's own `peers.json` stays authoritative for its
   side. Keep the file at mode 0600 and owned by you, or every tool refuses to
   start.
6. **Confirm the chat.** Use the supergroup's id:

   ```bash
   bun scripts/peer-bridge/setup.ts confirm example <chatId>
   ```

   It calls `getChat` and `getChatMember` and refuses, writing nothing, unless:
   - the chat is a `supergroup` (a migrated basic-group id is refused and the
     new id is named);
   - our bot and the peer bot are each `administrator`, with `is_anonymous`
     false, `user.id` equal to the id asked about, and `user.is_bot` true;
   - every field whose name starts with `can_` is false, except
     `can_manage_chat`, which Telegram implies for any admin. A field the code
     does not name counts the same.

   It prints the sanitized chat title, writes the chat id and submits a
   `confirm` record to the spool. The poller reloads its config when it drains
   it.
7. **Run the poller.** Install the unit for your OS. Replace `@HIMMEL_ROOT@`
   (and `@HOME@` on macOS) with absolute paths.
   - Linux: `units/himmel-peer-bridge.service` goes to
     `~/.config/systemd/user/`, then
     `systemctl --user daemon-reload && systemctl --user enable --now himmel-peer-bridge.service`.
     It sets `RestartPreventExitStatus=78`, so a refusal that a restart cannot
     fix is not retried.
   - macOS: `units/com.himmel.peer-bridge.plist` goes to
     `~/Library/LaunchAgents/`, then `launchctl bootstrap gui/$(id -u) <file>`.
     It runs `run.sh`, which loads the env file and maps exit 78 to 0 so
     `KeepAlive` with `SuccessfulExit=false` does not respawn it.

`setup.ts runner` installs and starts the runner unit
(`units/himmel-peer-runner.service` or `units/com.himmel.peer-runner.plist`)
while some peer's `serves` holds `run-suite`, and stops and deletes it
otherwise. Run it after you edit `serves`. `setup.ts remove <peer>` deletes one
peer and its chain files, then does the same check. `setup.ts
uninstall` stops both units, deletes the unit files, `S` and `C`, and removes the
parent dirs it created if they are empty. Both ask for a typed `yes`. Every
subcommand refuses when `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` is set and when
there is no terminal. No message, template or wake can trigger any of them, and
no inbound module imports `setup.ts`.

The poller exits 78 when the token is unset, when the token's bot id equals the
operator bot's id, when `peers.json` is not mode 0600 or not owned by you, or
when a peer name does not match `^[a-z0-9][a-z0-9-]{0,31}$`.

## What crosses the wire

Every message we send starts with one control line, a kind line or a template
line, each carrying a message id minted by the sender:

```text
#(ask:question|status|info|answer) id=<8 hex>
#tpl:(receipt|nudge|deferred|closing|declined-kind|busy) #<root> id=<8 hex>[ by=<UTC stamp>]
```

A root message starts with the line `/peer@<peer bot username>`, and its control
line is line 2. A thread opens only with `ask:question`, `status` or `info`;
`answer` is accepted only as a reply on an existing thread. Replies need no
prefix. Text is plain: no `parse_mode`, link previews off, at most 4000 UTF-16
code units.

Admission is one predicate, applied in order to every update: dedup; supergroup
only; configured chat; sender in `allowFrom`; no `sender_chat`, no anonymous-admin
id, not our own bot; plain text addressed to us (a root must open with our
`/peer@` line, a reply must answer one of our messages or a root we admitted);
the per-minute rate; the length cap. Because an admin bot receives all chatter,
this predicate and not Telegram does the filtering. A dropped message is never
queued and produces one redacted log line.

Deadlines: `ack_by` is +30 min with one resend at +12 h; `answer_by` and
`reply_by` are +24 h with a reminder at +12 h; DEFERRED lasts +72 h; `close_by`
is +72 h. The poller ticks every 30 s and fires each overdue timer once, oldest
first. Each side's deadlines come from its own config; the peer's `by=` only
sets how long the sender waits, clamped to `min(max(own, by+1h), alloc+73h)`.
Caps: 3 automatic messages per thread plus one reserved `closing`, 20 automatic
messages per peer per hour, `maxOpenThreads` 5 counted on allocation only,
`maxPerMinute` 10.

## The typed path (slice B1)

Beside the text channel there is a second, separate path for work that needs no
free text: our chief asks the peer's station to run shell suites and reads the
result. The two paths never mix. A message whose second line starts `#env:` goes
to the typed path and never to the reader or the desk; a text message never goes
to the resolver. Nothing a peer wrote reaches a chief's output on either side, so
a chief may read this path, unlike the desk's digests.

| | Text path | Typed path |
|---|---|---|
| Carries | questions, status, info, answers | signed envelopes: `req`, `res`, `capacity-ask`, `capacity`, `cancel`, `halt` |
| Reaches | reader, digest, tainted desk, operator | verifier, resolver, `jobs.jsonl`, `jobs.ts`, any chief |
| Parser | two control-line regexes | a third control-line regex, then an Ed25519 check, then a closed schema |
| LLM | the tool-less reader | none, on either side |

This path is inert while `serves` is empty, which is the default and what our own
station keeps. A station that serves runs the runner (see "The runner" below);
while the runner is down, a job still unresolved after 10 minutes is refused
`no-vm`.

### Names, keys and trust (at a terminal)

`setup.ts` subcommands, each behind the same local-only guard as the rest (no
Claude session, a TTY):

| Command | Does |
|---|---|
| `station-name <name>` | sets our `self.stationName` (what `from` carries). A name `egress.ts` `badHost` would refuse (the host's name or first label, `localhost`, a `.local` name) is refused, because egress would refuse every envelope that holds it |
| `keygen` | creates `C/station.ed25519` (PKCS8, 0600, `O_CREAT\|O_EXCL`) and prints the public key (base64), its key id (8 hex of `sha256(pub)`) and its fingerprint (20 hex in groups of four) |
| `trust <peer> <station-name> <pubkey>` | prints the key's fingerprint and asks you to **type** the one the peer's operator gave you out of band. It writes `theirs.stationName` and adds the key to `theirs.keys` (at most two) only on a match. The public key may travel over the group; the fingerprint must not |
| `keygen --rotate`, `--activate` | `--rotate` makes a next key and prints it while we keep signing with the current one; the peer runs `trust` with it; `--activate` switches and deletes the old key file |
| `untrust <peer> [--key <id>]` | removes one trusted key, or all. A key also ages out 30 days after its successor was added |
| `allow-suite <peer> <alias> <path>`, `deny-suite <peer> <alias>` | the only writers of `C/<peer>.suites` (0600): the suites this station will run for that peer, by the alias you type |
| `kill <peer>`, `unkill <peer>` | the only writers of `C/<peer>.killed` |

### The envelope

A typed message is exactly four lines:

```text
/peer@<their bot username>
#env:v1 k=<8 hex key id> id=<8 hex>
<canonical JSON, one line, printable ASCII, at most 3000 bytes>
sig=<86 base64url characters>
```

The signature is Ed25519 over `"himmel-peer-env-v1\n" + line 2 + "\n" + line 3`, the
exact bytes, so the domain tag and line 2 are bound. Line 3 must equal its own
canonical re-encode (schema order, integers only, no whitespace), which refuses a
duplicate key, a key out of order, `1.0`, an exponent and any whitespace. Common
fields, in order: `v`, `msg` (equals line 2's `id`), `from`, `to` (station names),
`chat` (a string), `iat`, `exp`, `kind`. We set `exp` to `iat + 86400` for every
kind; a receiver accepts any `exp` with `iat < exp <= iat + 86400`. The
body is closed per kind; `envelope.ts` owns the schema, the suite-path regex
`^scripts/[a-z0-9_/.-]{1,120}\.sh$` and the two time constants `TIMEOUT_S_MAX`
(10200 s) and `ALLOWANCE_S` (1200 s).

| Kind | Direction | Body |
|---|---|---|
| `req` | requester to server | `job` (16 hex, the requester's), `op` (`run-suite`), `sha` (40 hex), `suites` (1 to 10 paths) |
| `res` | server to requester | `job`, `state` (`accepted`, `refused`, `running`, `done`, `cancelled`, `expired`); `refused` names `not-served`, `unknown-sha`, `too-old`, `not-allowed`, `budget` or `no-vm`; `running` carries `timeout_s`; `done` carries one outcome per suite (`pass`, `fail`, `error`), `minutes`, `image` (64 hex) and the log's `sha256` and `bytes` |
| `capacity-ask` | either way | empty |
| `capacity` | reply | `re`, `state` (`idle`, `busy`, `not-served`, `no-vm`), `queue`, `jobs_left`, `vm_minutes_left` |
| `cancel` | requester to server | `job` |
| `halt` | either way | empty: stop every job I sent you |

### Admission, in order

One predicate, one test row per step. A refusal at steps 2 to 7 drops the message
and logs the step, the `msg` id and a sha256, never the text.

1. The text path's rules 1 to 8, and rule 1 also checks a separate envelope id
   window keyed on `(chat, sender, id)`. The window keeps each id until its
   verified `exp`, has no count eviction, and is persisted to
   `S/<peer>/envelope-ids.jsonl`, so a flood of text cannot flush it.
2. Four lines, the first our address line, line 2 matching `#env:v1`.
3. Line 3 printable ASCII and at most 3000 bytes; line 4 the signature shape.
4. The peer is not killed, and has a live key whose id is `k`. A killed peer is
   dropped here, silently.
5. The Ed25519 signature verifies, before any parse. A failure feeds the tripwire.
6. `JSON.parse`, the canonical re-encode, then the closed schema.
7. Binding: `msg`, `from`, `to`, `chat`, `iat` (not more than 10 minutes in our
   future) and `exp` (still ahead). Only now is the id inserted in the window.
8. Matching: a `req` needs an op in `serves`; a `cancel` a job that peer sent us; a
   `res` a job we sent it; a `capacity` an ask we sent it and nobody has answered.
   `halt` and `capacity-ask` always pass.
9. Budgets, for a `req` only.

A `req` refused at step 8 or 9 is answered with a signed `res refused`
(`not-served` or `budget`). An unmatched `res`, `capacity` or `cancel` is dropped
and logged, never answered. Answers to a peer's asks go at most once per `msg` and
under the text path's 20-per-hour automatic cap. Nothing here starts a process or
a model.

### Serving, approval and budgets

The receiver decides, from its own `peers.json` and `C/<peer>.suites`; a git pull
or a peer message changes neither.

- `serves` is a subset of `["run-suite"]`, default none. `approve["run-suite"]` is
  `tty` (default) or `auto`. `cancel`, `halt` and `capacity-ask` are always
  handled, because they only narrow or report.
- `budgets`: `jobsPerDay` 1 to 1000, `vmMinutesPerDay` 1 to 10000, `queueMax` 1 to
  3, `maxJobMinutes` 30 up to `TIMEOUT_S_MAX/60 - ALLOWANCE_S/60` (150). Reported
  values are clamped to the wire's ranges before they are encoded.
- The server resolves every requester value against its own state. A suite must
  equal a path in the allowlist and is stored by the alias its operator typed; the
  SHA is the requester's string until the runner resolves it in its own clone of
  `origin`. The envelope policy does not re-establish that the SHA is on `origin`
  or that the suites exist there; that is no wider than the spool send path of
  slice A.
- **Backstop.** At `vm-start` the poller writes `min(maxJobMinutes, VM minutes
  left today)` into the RUNNING record, and the runner reads it there. A backstop
  under `ALLOWANCE_S` refuses the job `budget`. The requester is told
  `timeout_s = backstop + ALLOWANCE_S` once, in `res running`.
- VM minutes are charged from RUNNING entry to the terminal timestamp. `jobsPerDay`
  counts every job that reached RESOLVED and every job received today that is
  still waiting to resolve, so a burst cannot run past the day's budget.
- **Tripwire.** Three bad signatures from one peer in an hour send one alert
  line naming the peer and the count. It is an alert, never a kill, so a key rotation
  or a junk sender cannot cut the link. The count and the hourly cap on answers
  are kept on disk, so a poller restart does not reset either.
- **Kill switch.** While `C/<peer>.killed` exists the peer is dropped at step 4 and
  answered nothing, its live jobs are cancelled with nothing sent, and nothing it
  asked for starts. The peer sees silence and its own deadlines end its jobs.

### Job states and deadlines

`jobstate.ts` owns both tables. The server (`in`) walks RECEIVED, RESOLVED,
APPROVED, RUNNING and ends DONE, CANCELLED, EXPIRED or REFUSED. The requester
(`out`) walks SENT, ACCEPTED, RUNNING and ends DONE, REFUSED, EXPIRED, CANCELLED
or LOST. Every non-terminal state sets an absolute deadline and every cell not
named in the tables is logged and ignored.

| Side | State | Deadline |
|---|---|---|
| server | RECEIVED | +10 minutes, then REFUSED `no-vm` (the runner is down) |
| server | RESOLVED, APPROVED | the `req`'s `exp`, then EXPIRED |
| server | RUNNING | start + backstop + `ALLOWANCE_S`, then DONE with every unfinished suite `error` |
| requester | SENT, ACCEPTED | `req.exp + TIMEOUT_S_MAX + 2 h`, then LOST (SENT also sends one `cancel`) |
| requester | RUNNING | running-at + `timeout_s` + 2 h, then LOST |

The latest a server job can end is `req.exp + TIMEOUT_S_MAX`, so every requester
deadline falls after the matching server deadline, even when `res running` is
lost. A late `res` on a finished job is recorded as `late` and never reopens it.
On start the poller drains the Telegram backlog and applies every admitted
envelope before its first deadline tick, so a `res` waiting there is not beaten by
an overdue SENT deadline. The poller's 30 s tick then fires each overdue deadline
once, oldest first.

### The runner

`runner.ts` runs a job; it never decides one. It reads `jobs.jsonl`, submits each
transition (`resolve-ok`, `resolve-fail`, `vm-start`, `vm-done`) through the
spool, and the poller applies it. It runs only from its own unit, which reads no
env file, so it holds no bot token and no signing key. It exits 0 on a refusal
(no peer serves, no VM backend) so the unit does not restart it, and 1 on an
error.

On start it runs `vm-sweep`, which destroys every VM left from a crash, and
deletes job logs older than 14 days. Every 30 s it then:

1. **Resolves** each RECEIVED job in a bare cache of the peer's `origin` under
   `S/<peer>/`. The SHA must be a commit on a branch of `origin` (a SHA reachable
   only from `refs/pull/*` is `unknown-sha`) and must descend from `MIN_SHA`
   (`min-sha.txt`, the first commit holding `job-entry.sh`), else `too-old`.
2. **Runs** the oldest APPROVED job, one at a time. It reads the backstop from
   the RUNNING record, fetches the one commit into an empty repo and packs only
   its `.git` into a tar, so no file of the tree runs on the host. It then
   clones the golden VM, pushes the tar, `job-entry.sh` and the suite list, and
   runs `job-entry.sh` in the guest under `backstop + ALLOWANCE_S`. A job that
   leaves RUNNING (cancel, halt, deadline) kills the exec within one watch tick.
3. **Reports** the guest's `.job-result.json` (16 KB cap), parsed against the
   job's own suite list: a suite the guest did not finish is `error`. The log
   (5 MB cap) stays on the host, mode 0600, under `S/<peer>/logs/`; only its
   SHA-256 and byte count go into `vm-done`, with the golden image's digest and
   the VM minutes. The VM is destroyed and the work dir deleted on every path.

#### A macOS peer: the Tart backend

On macOS the runner unit (`units/com.himmel.peer-runner.plist`) sets
`PEER_JOB_BACKEND=tart` and puts `/opt/homebrew/bin` on `PATH`, so `vmsdk-job.py`
drives [Tart](https://tart.run) and runs every job in a throwaway macOS VM, never
on the host. Each job VM is a clone of the local image `sequoia-base` named
`himmel-peerjob-<job>`, set to 4 CPUs and 8 GB with a fresh MAC, and started with
`tart run --no-graphics --no-audio --no-clipboard --net-host`. No `--dir` or
`--disk` is ever passed, so the guest has no shared folder. The host reaches the
guest by SSH at the address `tart ip` reports. A timeout kills the job's guest
session through a small perl wrapper, because the macOS guest has no `setsid`.
`vm-sweep` deletes only `himmel-peerjob-` VMs; `sequoia-base` and `himmel-proof`
are never deleted. `vm-clone` refuses while any other Tart VM is running, local
or pulled from an OCI registry, because a job guest could reach it over the
host-only network.

What the peer's operator sets up once:

1. **Tart and the image.** Install Tart at `/opt/homebrew/bin/tart` and keep a
   local macOS image named `sequoia-base` with Remote Login on and the
   user `admin`. `job-entry.sh` runs under the guest's stock `/bin/bash` 3.2 and
   needs `git`, `tar` and `jq` there. The suites need what `macos-cadence.yml`
   installs (bun, shfmt, the pre-commit venv). The guest has no internet route
   while a job runs, so everything must already be in the image.
2. **The guest key.** Create an SSH key only for this purpose; it is never the
   bridge key. Put its private half at `~/.config/himmel/peer-bridge/tart.guest`
   (mode 600) and its public half in the `admin` user's `~/.ssh/authorized_keys`
   inside the image. Boot the image once and record its host key
   under the alias `himmel-peerjob-guest` in
   `~/.config/himmel/peer-bridge/tart.known_hosts` (mode 600), for example
   `ssh-keyscan <ip> | sed 's/^[^ ]*/himmel-peerjob-guest/'`. Every clone shares
   that host key, so SSH checks it strictly. A missing file, or one not mode 600,
   makes every job verb refuse (exit 2), so the unit does not restart. Three
   verbs skip the check: `vm-destroy` and `golden-record` never use it, and
   `vm-sweep` deletes leftover job VMs first and refuses only after that.
3. **Serve and allow.** Add `run-suite` to that peer's `serves`, list the suites
   with `setup.ts allow-suite`, and leave `approve["run-suite"]` at `tty`, so each
   job waits for a typed `yes` from `jobs.ts approve`, unless you choose `auto`.
   Then run `setup.ts runner` to install and start the runner unit.
4. **Record the image.** Run `vmsdk-job.py golden-record` (with
   `PEER_JOB_BACKEND=tart`), which hashes the image's `config.json`, `disk.img`
   and `nvram.bin` under `~/.tart/vms/sequoia-base/` into `C/golden.digest`.

Residual: `--net-host` is Tart's "host-only network". The guest has no route to
the internet, but it can reach any service on the host that listens on the
host-only bridge, and any other VM on that network (which is why a foreign
running Tart VM refuses the clone). The check sees only the Tart VMs of the
runner's user and `TART_HOME`: a VM run by another hypervisor, another user or
another `TART_HOME` on that bridge is not checked, so the peer keeps none running
while it serves jobs. The live check for a new peer: in a job guest,
`curl -m 10 https://github.com` must fail. It belongs to the first live round
trip with a macOS peer, not to the suite rows, which use a fake `tart` and `ssh`.

Every `git` call runs with `core.hooksPath=/dev/null`, `GIT_CONFIG_GLOBAL=/dev/null`
and `GIT_CONFIG_NOSYSTEM=1`, so no hook, filter (LFS included) or user config
runs. The runner's closed list of git verbs is `init --bare`, `fetch --prune` of
`origin`'s branches, `cat-file -e`, `branch -r --contains`,
`merge-base --is-ancestor`, `init` and `fetch --depth 1` of one SHA from the
cache. `policy.test.ts` pins the list.

Testing the runner and the VM verbs:

- `bun test scripts/peer-bridge/runner.test.ts` runs the runner on real git
  against the stub backend, on any host.
- `python3 scripts/lib/test-vmsdk-job.py` runs the verbs on the stub backend;
  with `PEER_BRIDGE_VM_TEST=1` inside a test VM it also runs the VirtualBox rows.
  Its Tart rows run on any host against a fake `tart` and a fake `ssh` that log
  every call.
- `scripts/peer-bridge/e2e-linux.sh` is the end-to-end run, only inside a test VM
  that already holds the golden fixture (`vmsdk-job.py golden-build-linux`). It
  needs `PEER_BRIDGE_VM_TEST=1`, `E2E_BOTS_FILE` (a 0600 file with the two test
  bot tokens) and `E2E_CHAT_FILE` (the test supergroup id), and prints
  `E2E PASS`. It never runs on a station host.

### What a chief sees

`jobs.ts` is the CLI, and it prints only values this station produced or looked up
by a key it issued itself (`resolve.ts`, the only formatter):

| Peer field | Shown as |
|---|---|
| `job` | our job number `J<n>` |
| `state`, `refused`, each outcome | our enum constant |
| result position | our own recorded suite path (the server's alias on the other side); a count that is not ours makes the result `malformed` |
| `minutes` | rounded up to a multiple of 5 |
| `jobs_left`, `vm_minutes_left`, `queue` | `capacity: ok`, `low` or `none`; the queue as `free` or `full` |
| `image` | `pinned` if equal to `theirs.imageDigest`, else `unpinned` |
| the log's hash and size | `log: kept on peer` |
| `re`, `iat`, `exp`, `msg`, `from`, `to`, `chat`, `timeout_s` | not shown |

Other peer values are stored in `peer_*` fields of `jobs.jsonl`, which the
formatter never reads. A peer value is never shown, never selects which of our
texts is shown, and what it can still influence (an enum choice, a bucketed number,
the leading hex of a SHA) is a few bytes per job, a recorded ceiling. A signature
proves origin, not truth, so a peer's result is an attested claim: it is never a CI
check, a status, a merge input or a Jira transition, and no merge, check or Jira
script imports `scripts/peer-bridge/` (`routes.test.ts` pins it).

Commands (exit 0 ok, 2 refused with the rule, 3 `approve` without a TTY, 4 queued
but unconfirmed, do not resend): `jobs.ts request <peer> run-suite --sha <40 hex>
--suite <path>...`, `capacity <peer>`, `cancel J<n>`, `halt <peer>`, `list [--peer
P]`, `show J<n>`, `approve J<n>`. `request` first checks, on our own checkout, that
the SHA is on one of our `origin/*` branches (`git branch -r --contains`) and each
suite exists at it (`git cat-file -e`); these are the only two processes the
typed path starts. It also refuses on a fresh `capacity` that says `not-served` or
no budget. `approve` is the server's gate: at a terminal, outside a Claude session,
it shows the resolved job and waits for a typed `yes`.

### Outbound

Every envelope is built by our code from resolved values, signed by the poller
with `C/station.ed25519`, and passed through `checkEnvelopeOutbound`: line 1 and 2
by their own anchored shapes against our config, line 3 re-validated with the
receiver's schema and bound to our station name, the peer's and the chat, the
content rules of the text path on line 3 alone, and line 4 accepted only by
verifying as our signature over lines 2 and 3 (a line that merely looks like a
signature is refused, since a bot token's secret part fits that shape). The matrix
row is `peer-jobs` to `peer-telegram` for `peer-message`. No thread or `opens`
check runs: an envelope opens no text thread.

### Routes

The peer-origin data on a station are the raw envelopes in `inbox.jsonl`, the
`peer_*` fields in `jobs.jsonl` and, on a serving station, job logs. All sit under
the path-denied `S/` and none is printed; peer files are outside every indexed
root. A log never leaves the serving station: only its size and sha256 cross, and
neither is shown. The tainted desk is still the only path for peer free text.

## The peer desk

Peer text is never shown to a normal session. A **wake** tells you something
arrived: a message in the operator chat with the peer name, the thread number, a
label and a deadline on line 1 and the desk command on line 2, and never peer
text. An **escalation** carries the reader's digest instead, marked untrusted.
The operator bridge sends both with no model run.

Start the desk from a terminal:

```bash
bash scripts/peer-bridge/desk.sh example
```

It starts a fresh interactive `claude` session in an empty 0700 dir
(`S/desk/<peer>/`) with `PEER_DESK=<peer>` set and no CLAUDE.md. It refuses if
the dir holds `.claude`, `CLAUDE.md`, `CLAUDE.local.md` or `.mcp.json`.

The desk starts with no MCP server, plugin, skill or user hook. `desk.sh` passes
`--strict-mcp-config` with an empty `--mcp-config`, `--setting-sources project`
(so the user settings never load), `--tools Bash`, `--permission-mode default`
and `--disable-slash-commands`. It writes `S/desk/<peer>.mcp.json` and
`S/desk/<peer>.settings.json` (mode 0600, beside the desk dir, never in it) at
each launch; the settings file wires only the taint gate and the read-secrets
guard, from the himmel root's tracked scripts. The gate also denies any tool but
Bash when `PEER_DESK` is set, so a tool the flags missed is still refused.

In the desk the taint gate allows only two Bash command shapes, each a single
line with no control byte:

- `bun <himmel root>/scripts/peer-bridge/read.ts <peer> [--thread N] [--ack TOKEN]`
  prints reader digests, each inside an HMAC-signed fence (`--thread` is a
  read-only view with no ack line; only an unfiltered read advances the cursor);
- `bun <himmel root>/scripts/peer-bridge/send.ts <peer> --kind status|info --text '...'`
  or `--kind answer --reply-to N --text '...'` replies.

Every other tool is denied. The read shape is auto-approved so the gate's 5 s
stamp cannot go stale while a prompt waits. The send shape is not, so you approve
every peer-bound message. `read.ts` refuses unless `PEER_DESK` names the peer,
the gate stamped this session within 5 s, and it has first written the session's
taint file. `read.ts <peer> --raw` is the human-terminal path to the unreduced
inbox: it needs a TTY and no `CLAUDECODE`.

A digest is made by the reader: `claude -p --safe-mode --strict-mcp-config`
with an empty MCP config, no tools, `--model haiku`, one turn, a 60 s timeout
that kills the process group, and a 4 kB output cap. It runs only when
`usage-preflight.sh` returns `PROCEED`, and within 50 runs a day in total, of
which at most 30 questions, 10 status, 10 info and 15 follow-ups. When it is skipped or fails, the digest
says so and the message escalates with that reason instead of a summary.

### Triage and the notify chain

Every admitted free-text message that opens a thread or belongs to one we know
is read, and the reader also proposes a route: `escalate`, `ack` or `drop`. Its
output must be exactly `{"route","summary","asks"}` inside one optional code
fence; anything else is a failed run. The proposal does not decide.
`effectiveRoute` in `threads.ts` does, from what the message did to its thread:

| Message | model escalate | model ack | model drop | model failed |
|---|---|---|---|---|
| opens a question | escalate | escalate | drop | escalate |
| opens a status or info | escalate | ack | drop | escalate |
| answers our open thread | escalate | escalate | escalate | escalate |
| anything else on a known thread | escalate | drop | drop | escalate |

- **escalate** puts the digest in front of the operator, at most 20 per peer per
  UTC day. The first one past that sends one "escalation budget reached" line,
  and later ones fall back to a metadata wake under the wake budget.
- **ack** closes the thread as `ACKED` and sends the peer the `closing`
  template.
- **drop** sends nothing. A thread it opened ends as `DROPPED`.

The poller records a `job` record before it reads, then the digest record with
its route, then an `effect` record, all in `S/<peer>/digests.jsonl`. On start it
replays any job whose effect is missing, once. The desk shows each digest's
route, and once a day the operator gets one triage count per peer.

Wakes, escalations, budget lines and daily counts are chained records in
`S/notify/notify.jsonl`, written only by the peer poller. The operator bridge's
flusher (`scripts/telegram/peer-notify-route.ts`) verifies the chain from its
cursor (`S/notify/cursor`), renders each record with `notify.ts`, and sends it
to the operator chat with link previews off, recording each sent message in
`S/notify/sent/`. Line 1 of every message is built from our own values only.
A failed verification sends one alert and stops the flusher until it restarts.
A message Telegram refuses outright is skipped with one fallback line.

The flusher sends nothing while a Claude session could also be polling the
operator bot and so read the reply text:

- the bridge's last good `getUpdates` is over 60 s old;
- it got a 409 in the last 10 minutes;
- a `telegram-himmel` plugin process that polls (`TELEGRAM_OWN_POLLER=1` in its
  environment or its state-dir `.env`) resolves to the operator bot, or to no
  single bot. A send-only plugin process never holds. Where the environment
  cannot be read (or, on macOS, reads ambiguously), the plugin's `bot.pid`
  decides, or the process holds.

The queue waits. After 10 minutes held, one line says the notifications are held
and why. A reply to a peer notification is never routed to a session: in this
slice it gets one fixed line saying drafts arrive with the next update, and
nothing is sent to the peer.

### The signed tap

A peer draft is approved or rejected only by a `tap` spool record the Telegram
poller wrote after a real button press by the operator. The poller signs the
record: an HMAC-SHA256 over a fixed domain tag (`himmel-peer-tap-v1`), the draft
id, the verdict, the operator id (`by`) and `ts`, in the record's `sig` field (64
hex), and over the peer name so a signed tap cannot be copied into another peer's spool. The bridge's `applyTap` recomputes it, compares in constant time, and only
then checks `by` against the operator chat id. A tap with no `sig` is refused
`tap-unsigned`; a malformed, wrong-length or mismatched one `tap-bad-sig`. The
refusal is written to the spool result and logged as
`tap-refused peer=<p> draft=<id> rule=<rule>`, never the signature or the key,
before any draft state changes: the draft stays PENDING and nothing is sent. The
tap's age is not bounded separately: the draft's own deadline and its settled
state (`already-*`) stop a replayed tap.

The key is `C/tap.key` (mode 0600, owned by you, 32 random bytes as hex), a file
of its own and not the fence key. Whichever side reads first creates it (written
complete, then linked into place, so a race cannot leave a half key). It is opened
`O_NOFOLLOW` and refused unless it is a regular file owned by you with mode 0600.
On the Telegram side an unusable key means no record is written and the button
answers `Could not record the tap.`; on the bridge side every tap is refused.

### Clearing taint

A session is tainted when `read.ts` prints to it, when a verified fence marker
shows up in any tool output, or when a resumed session's transcript holds one.
Only a human at a terminal clears it:

```bash
bash scripts/peer-bridge/untaint.sh <session_id>
```

It reads `yes` from `/dev/tty`, which a Claude session's Bash cannot open,
removes the taint files and appends who cleared it and when to
`S/taint/cleared.log`. It refuses inside a Claude session.

### Why `/clear` does not weaken the gate

- A tainted session cannot run `/clear` itself: the gate denies every tool except
  Bash and Monitor (a desk denies Monitor too: only Bash), and only the two
  command shapes pass. A `/clear` in a tainted session is the operator typing it.
- `/clear` wipes the context. While tainted, the session could write no files and
  could start only the two command shapes, so nothing the peer said has been
  carried anywhere that outlives the context.
- `read.ts` refuses without `PEER_DESK`, and `PEER_DESK` survives `/clear`. The
  desk stays restricted under its new session id, which is what the gate test
  "PEER_DESK set, no taint file, Read x denied" proves.
- The gate stamp still holds: the session id in the environment and the id the
  hook sees change together, and the live check confirms it.

## Trust model

The peer's group is untrusted. Its messages are data, and the design assumes a
hostile peer, a compromised peer bot and a human in the group who is not who they
claim.

### Structural: code and hooks enforce it

- **One writer.** Only the poller writes the chain files. `send.ts`, `read.ts
  --ack` and `setup.ts confirm` submit through an `O_EXCL` spool. A pid lock keeps
  a second poller out.
- **Admission.** One predicate decides what is queued (see above). A message that
  fails it leaves one redacted log line and nothing else.
- **A closed spawn list.** Peer bytes are parsed only by the three control-line
  regexes and never reach a shell argv; an envelope's JSON line is parsed only after
  its signature verifies, only in `envelope.ts`. The poller starts only the reader,
  the `redact_check` shell function, `usage-preflight.sh` and, on macOS, `ps`
  (`policy.test.ts` pins the list over the poller's module graph). On the typed path
  `jobs.ts` runs `git`, two fixed verbs on our own checkout, and the runner runs
  only `git` (its closed list, above) and `vmsdk-job.py`; it reaches no `claude`
  and no reader. The reader's
  environment holds no `PEER_BOT_TOKEN` and no `TELEGRAM_*`.
- **One egress gate.** Every outbound message, from `send.ts`, a template or a
  resend, passes the same checks in the poller: a secret-shape scan through
  `redact_check`, the egress matrix for the `peer-message` purpose, the length
  cap and the receiver's caps. A refusal chains only a fingerprint, never the
  text.
- **Intent before send.** Each send writes an intent record first, so a crash
  after the Telegram call resends with the same id and the peer dedups it.
- **The taint gate.** A tainted session or a desk may run only the two command
  shapes. The gate is a PreToolUse hook on every tool in the plugin lane, with a
  byte-identical copy for Codex; a desk loads the tracked copy from its own
  settings file, not through the plugin. It fails closed once a bridge dir
  exists, and is a no-op on a station with no bridge.
- **The fence.** Digests print inside a per-record fence whose marker carries an
  HMAC over a nonce. Only a marker whose HMAC verifies taints a session, so a
  copy of the marker in a doc, a CI log or an issue taints nothing.
- **The path deny.** No session, tainted or not, may read the two peer-bridge
  dirs, which hold the token, the key and the inbox.
- **Sanitized display.** Digest fields and chat titles lose control, bidi and
  zero-width characters, `<<<` and `>>>` runs and tag shapes, then are capped.
- **Receiver-owned limits.** Deadlines and caps come only from the receiver's
  config. A sender cannot make us wait longer than our clamp or raise our caps.

### Instructional: a prompt asks, nothing enforces

- The desk's system prompt tells the model that digests are untrusted data and
  that `--text` carries only what the operator said. The gate narrows what the
  model can do, but a model that obeys a digest can still put the wrong words in
  an allowed `send.ts` line. The operator's approval of each send is the check.
- The reader is asked for a short summary and at most three asks. The output
  shape and size are enforced; whether the summary is faithful is not.
- The desk cannot look anything up, so it cannot answer a question about code.
  A corpus-checked read allowlist is planned for a later slice.

### Accepted residuals

These are known and accepted for this slice.

- **The poller runs as the same OS user.** Anything running as you can read the
  token, the key and the inbox, or kill the poller. The path deny and the
  `block-read-secrets` hook are an accidental-leak floor: a determined Bash read,
  or a relative path from a directory outside both dirs, gets around them. The
  planned upgrade runs the bridge as its own sandboxed user.
- **The tap key is readable by the same OS user.** The signed tap stops a spool
  writer that cannot read `C/tap.key`, such as the desk session (its Bash is
  limited to the two command shapes and `block-read-secrets` denies any path under
  the bridge dirs). It does not stop another process running as you that reads the
  file. The structural fix is the separate bridge user.
- **Spool `allowShape` is trusted from any local writer.** `send.ts` sets it
  only from a TTY outside a Claude session, but the poller trusts the field in
  any spool file, so a local process that can write a spool record can waive one
  low-precision secret-shape refusal for that message. The text still passes
  every other check.
- **A crash between the Telegram send and the `sent` record loses the root's
  message id.** On restart the poller resends the intent with its original id.
  The peer dedups the second copy and answers the first, but our thread is keyed
  on the second copy's message id, and we never learned the first one's. Peer
  replies to that first copy are replies to an unknown root and are dropped.
- **A harness timeout kill allows the call.** The gate is one `jq` call and string
  tests so it finishes far inside its 10 s timeout, but a kill still fails open.
- **Admin rights are checked once, at `confirm`.** The group owner can grant a
  right later. Our client makes only four Bot API calls, so it never uses a
  right, but a granted right changes what the other bot may do. Re-checking
  `getChatMember` at poller start is the planned upgrade.
- **The setup refusals stop accidents, not a determined session.** From an
  untainted Claude Bash, clearing `CLAUDECODE` and `CLAUDE_CODE_SESSION_ID` and
  allocating a pseudo-terminal passes the checks, and `remove` or `uninstall`
  then deletes the state dir and so clears every session's taint. Running the
  bridge as its own sandboxed user closes this.
- **Codex coverage is narrower than the plugin lane.** The Codex port wires the
  gate on PreToolUse, the mark hook on PostToolUse and the resume hook on
  SessionStart. Codex has no PostToolUseFailure event and no Monitor tool, so a
  verified marker in a failed tool's output does not taint a Codex session
  through the mark hook. `read.ts` still taints before it prints.
- **Peer content can mislead the operator.** A digest is bounded and fenced, but
  it is text from an outsider. The operator reads it as untrusted.
- **The station key is readable by the same OS user as the bot token.** A full
  station compromise yields both, and `block-read-secrets` is an accidental-leak
  floor, not a sandbox. A separate user for the bridge is the fix.
- **A TTY gate stops accidents, not a determined session.** A session that clears
  `CLAUDECODE` and `CLAUDE_CODE_SESSION_ID` and allocates a pty can pass the guard
  on `setup.ts` and `jobs.ts approve`, so a station's own chief could approve its
  own job. A separate user closes it.
- **A few bytes per job still cross the typed path.** A peer chooses among three
  outcomes for each of up to ten suites, one minutes bucket and the leading hex of
  a SHA. A chief treats them as data; the ceilings ledger records it.

## Audit trail

Each peer's `S/<peer>/` holds chained JSON-lines files. Every record carries a
sequence number and a hash over the previous record, and `verifyChain` in
`scripts/peer-bridge/chain.ts` checks a file end to end.

| File | Holds |
|---|---|
| `inbox.jsonl` | each admitted message, as received |
| `outbox.jsonl` | intents, `sent` records, refusals (fingerprint only), failures, `confirmed` |
| `threads.jsonl` | every thread state change with its absolute deadline |
| `digests.jsonl` | one record per reader run |
| `envelope-ids.jsonl` | the id and `exp` of each envelope, written when it is admitted and again (`env-id-done`) once its handling completes; the replay window reloads only the done ids, so an envelope cut short by a crash is handled again on redelivery |
| `jobs.jsonl` | the typed path's jobs (one snapshot per state change), capacity asks and answers; `peer_*` fields are never printed |

Beside them: `S/unknown-chats.jsonl` lists supergroups our bot was added to that
are not configured, `S/taint/cleared.log` lists each `untaint.sh` run, and each
dropped message is one redacted line in the poller's log (journald under
systemd, `S/poller.log` under launchd). Every operator-bound record is in
`S/notify/notify.jsonl`, and each one the flusher sent has an entry in
`S/notify/sent/` for 7 days.

## Tests

- `bash scripts/ci/run-bun-tests.sh scripts/peer-bridge scripts/peer-bridge` runs
  the bun suites. CI runs them in the `bun-suites` job. `setup.test.ts` creates
  and deletes state dirs, so it runs only in a test VM with
  `PEER_BRIDGE_VM_TEST=1`; elsewhere it prints a SKIP line.
- `bash scripts/peer-bridge/test-peer-units.sh` lints both unit files
  (`systemd-analyze verify` on Linux, `plutil -lint` on macOS).
- `bash scripts/peer-bridge/test-peer-bridge-macos.sh` runs the chain, gate,
  threads, envelope, signing, resolver and job-state suites on a macOS host. The
  macOS bed is `os-verify.yml` over `scripts/ci/macos-poc-suites.txt`, never a
  station.
- The typed path's suites: `envelope.test.ts` (schema, canonical form, admission
  steps 1 to 9), `sign.test.ts`, `resolve.test.ts` (canary rows on both sides, with
  RED controls that copy a field verbatim), `jobstate.test.ts` (every cell, the
  deadline-order property), `jobs.test.ts` (real temporary repos),
  `bridge-roundtrip.test.ts` (two bridges on a fake Telegram), `tripwire.test.ts`,
  `routes.test.ts` and the typed rows of `policy.test.ts`.
- `bash scripts/hooks/test-peer-taint.sh` covers the taint hooks.

## Slices

Slice A is one pair of bots, questions, status, info and answers. Slice B1 adds the
typed path above: signed envelopes that let a chief ask a peer station to run suites
and read the outcome. Its runner (the VM verbs and the in-guest contract) is the
next change. Slice B2, a separate ticket, carries documents, bug intake and delivery
of work, where peer-authored text does cross. Slice C adds a Mac VM backend. The hardening slice runs the bridge as its own
sandboxed user, which is the upgrade path for the same-user and setup-refusal
residuals above.
