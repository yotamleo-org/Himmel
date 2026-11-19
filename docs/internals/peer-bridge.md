# Peer bridge

The peer bridge lets our Telegram bot and another station's bot exchange
questions, status, info and answers in one supergroup that neither side trusts.
Deadlines run on both sides. Peer text is read only in a tainted peer desk, and
every outbound message passes one egress gate.

It is user-level: no `sudo`, no system change. It writes two state dirs, one user
unit, and one metadata-only line per wake into the operator bot's outbox.

| Where | Path |
|---|---|
| State (`S`) | `~/.himmel/peer-bridge/` |
| Config (`C`) | `~/.config/himmel/peer-bridge/` |
| Allowlist and caps | `C/peers.json` (mode 0600) |
| Bot token | `C/env`, one line `PEER_BOT_TOKEN=<token>` (mode 0600) |
| Fence key | `C/hmac.key` (mode 0600) |

There is no environment override for these paths.

## Setup, per side

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
   bun scripts/peer-bridge/setup.ts add goomal --peer-bot-id <peer bot id> --peer-username <peer bot username>
   ```

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
   bun scripts/peer-bridge/setup.ts confirm goomal <chatId>
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

`setup.ts remove <peer>` deletes one peer and its chain files. `setup.ts
uninstall` stops the unit, deletes the unit file, `S` and `C`, and removes the
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

## The peer desk

Peer text is never shown to a normal session. A **wake** tells you something
arrived: one line in the operator chat, with the peer name, the thread number, a
label, a deadline and the desk command, and never peer text. The operator bridge
sends it with no model run.

Start the desk from a terminal:

```bash
bash scripts/peer-bridge/desk.sh goomal
```

It starts a fresh interactive `claude` session in an empty 0700 dir
(`S/desk/<peer>/`) with `PEER_DESK=<peer>` set and no CLAUDE.md. It refuses if
the dir holds `.claude`, `CLAUDE.md`, `CLAUDE.local.md` or `.mcp.json`.

In the desk the taint gate allows only two Bash command shapes, each a single
line with no control byte:

- `bun <himmel root>/scripts/peer-bridge/read.ts <peer> [--thread N] [--ack TOKEN]`
  prints reader digests, each inside an HMAC-signed fence;
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
`usage-preflight.sh` returns `PROCEED`, and within 50 runs a day (30 questions,
10 status, 10 info). When it is skipped or fails, the digest says so and the
wake still fires.

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
  Bash and Monitor, and only the two command shapes pass. A `/clear` in a tainted
  session is the operator typing it.
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
- **A closed spawn list.** Peer bytes are parsed only by the two control-line
  regexes and never reach a shell argv. The poller starts only the reader, the
  `redact_check` shell function, `usage-preflight.sh` and, on macOS, `ps`. The
  reader's environment holds no `PEER_BOT_TOKEN` and no `TELEGRAM_*`.
- **One egress gate.** Every outbound message, from `send.ts`, a template or a
  resend, passes the same checks in the poller: a secret-shape scan through
  `redact_check`, the egress matrix for the `peer-message` purpose, the length
  cap and the receiver's caps. A refusal chains only a fingerprint, never the
  text.
- **Intent before send.** Each send writes an intent record first, so a crash
  after the Telegram call resends with the same id and the peer dedups it.
- **The taint gate.** A tainted session or a desk may run only the two command
  shapes. The gate is a PreToolUse hook on every tool in the plugin lane, with a
  byte-identical copy for Codex. It fails closed once a bridge dir exists, and is
  a no-op on a station with no bridge.
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

- **A wake line can be lost.** The poller appends each wake to the operator
  outbox, and the operator bridge truncates that file once it has sent
  everything in it. A line appended in the window between its final read and the
  truncate is cut with it (the `bus.ts` truncate race). The thread state is
  already on disk and its deadlines still fire, so the cost is a missed
  notification, and `read.ts` shows the thread.
- **The poller runs as the same OS user.** Anything running as you can read the
  token, the key and the inbox, or kill the poller. The path deny and the
  `block-read-secrets` hook are an accidental-leak floor: a determined Bash read,
  or a relative path from a directory outside both dirs, gets around them. The
  planned upgrade runs the bridge as its own sandboxed user.
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

Beside them: `S/unknown-chats.jsonl` lists supergroups our bot was added to that
are not configured, `S/taint/cleared.log` lists each `untaint.sh` run, and each
dropped message is one redacted line in the poller's log (journald under
systemd, `S/poller.log` under launchd). The wake lines live in the operator
bot's own outbox.

## Tests

- `bash scripts/ci/run-bun-tests.sh scripts/peer-bridge scripts/peer-bridge` runs
  the bun suites. CI runs them in the `bun-suites` job. `setup.test.ts` creates
  and deletes state dirs, so it runs only in a test VM with
  `PEER_BRIDGE_VM_TEST=1`; elsewhere it prints a SKIP line.
- `bash scripts/peer-bridge/test-peer-units.sh` lints both unit files
  (`systemd-analyze verify` on Linux, `plutil -lint` on macOS).
- `bash scripts/peer-bridge/test-peer-bridge-macos.sh` runs the chain, gate and
  threads suites on a macOS host. The macOS bed is `os-verify.yml` over
  `scripts/ci/macos-poc-suites.txt`, never a station.
- `bash scripts/hooks/test-peer-taint.sh` covers the taint hooks.

## Slices

This is slice A: one pair of bots, questions, status, info and answers.
Slice B carries assignments, documents, bug intake and delivery of work.
Slice C adds a Mac VM backend. The hardening slice runs the bridge as its own
sandboxed user, which is the upgrade path for the same-user and setup-refusal
residuals above.
