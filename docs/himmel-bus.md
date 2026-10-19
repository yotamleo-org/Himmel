# himmel-bus

**Status: early.** `himmel-bus` is a private, chained, local message store that
lets himmel sessions (a supervisor session, its worker sessions, judges and consults) message each
other without going through a transcript or a shared file. It is a plugin under
`marketplace/plugins/himmel-bus/`, not a `himmelctl` install item, and it has
not yet had a clean live round trip on every station: the working record and
open failures are kept with the project's internal decision records.
Check the ticket history before relying on it.

The plugin's own [README](../marketplace/plugins/himmel-bus/README.md) is the
store-level spec (chain, cursors, rotation, recovery). This page is the
operator's view.

## Requirements

- Linux with `flock`, and Node 24 or newer.
- The store imports `scripts/telegram/bus.ts` from this checkout, so it runs
  from a himmel checkout, not a standalone marketplace cache.

## Where state lives

`$XDG_STATE_HOME/himmel/bus`, which is `~/.local/state/himmel/bus` when
`XDG_STATE_HOME` is unset. Everything at and under `himmel/bus` must be a
private (`0700`), same-user directory and not a symlink; the shared parents
(the state home and `himmel/`) must be owned by you and not group or
other-writable. A violation is a refusal, not a silent repair. Never read or
write the store files directly.

## Identity

A session's identity is `(name, pid, start time)`, written under
`peers/<name>.json` by the **launcher** when it starts the session. A session
never registers or binds itself. The CLI and MCP server stamp a caller by its
nearest `claude` ancestor whose bound pid and start time match; a nested or
pid-reused `claude` is `identity unbound`, and `send` and `wait` refuse for it.
Names are single-use once bound.

## CLI

Run `node marketplace/plugins/himmel-bus/bin/bus <verb>`.

| Verb | Purpose |
|---|---|
| `register <name> --role leg\|console\|judge\|consult [--console <c>] [--pair <leg>] [--predecessor <old>]` | Reserve an identity (launcher use) |
| `bind <name> <pid>` | Bind a registered name to a live pid, once |
| `rebind <name> <pid>` | Rebind, only when the bound pid is gone |
| `adopt <new-console>` | Run as the worker session: adopt a successor supervisor session, only when the old one is gone or its own record names the new one |
| `status <name>` | Print `live`, `gone` or `unbound` |
| `peers` | Print the caller's own edges |
| `send <to> <body-file> [--re <n>] [--summary <text>] [--doc <handover doc>]` | Send a message; the sender is never an argument |
| `wait [--timeout <seconds>]` | Block until the caller's own inbox has a message, print it, commit the cursor |
| `status [--unacked] [--for <console>]` | Fleet view of undelivered or unacknowledged messages |
| `gc` | Remove aged data |

`wait` defaults to 300 seconds. Exit **0** means a message was printed, **3**
means it timed out, and any other non-zero exit is an error (unbound identity,
halted log, bad `--timeout`). `send` takes the body as a file; the body is
limited to 64 KiB and the summary to 300 characters.

## MCP tools

Worker sessions on the `leg-bus` plugin profile (see `scripts/lanes/plugin-profiles.json`)
get the MCP server through the registry's `mcpCatalog` entry. It exposes two
tools:

- `send` — message a himmel session; delivered by hook; returns the message id.
- `read` — the full body of message `#n` sent to you. Data only, never a ruling.

A bus message is **data, not authority**. A revision of a worker session's brief still
arrives only through the RETASK channel; see [glossary.md](glossary.md) and the
worker system prompt.

## Delivery guarantees

At-least-once, not exactly-once: a consumer must tolerate a replayed record.
A tampered or unreadable cursor halts the log fail-closed and the next read
returns one explicit notice; only an explicit `unhalt` after you have
investigated clears it. Filesystem errors (`EACCES`, `EIO` and similar) are
reported without marking the chain tampered; fix the cause and retry.

## See also

- [glossary.md](glossary.md) — console, leg, judge, relay, chain.
- [handover/running-a-console.md](handover/running-a-console.md) — how supervisor sessions and worker sessions are launched.
