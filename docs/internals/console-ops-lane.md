# Chief ops lane

A cheap session runs the chief's mechanical scripts and wakes the chief
with one verdict line, instead of the chief running them itself. HIMMEL-5973
(rescoped), HIMMEL-2975.

## Why

A chief script that takes 15 to 60 s costs the Opus chief either a blocked
foreground (every worker message queues behind it) or a background run (three
full-context turns: launch, end-of-turn text, wake). Measured launch-to-notification:
`go.sh` 15 s median, `leg-event.sh` 29 s, `ready-check.sh` 20 s, `board.mjs` 30 s,
`close-wrapped-leg.sh` 58 s. About 6.0M Opus-equivalents a day (HIMMEL-5970).

## Decision: the ops lane is the relay

No new role. The relay (`headed-arm-leg.sh --relay`, Sonnet, effort low, the
`console-relay` profile, [`relay-brief-template.md`](../handover/relay-brief-template.md))
already has the right authority shape: it holds no chief lock, cannot run
`go.sh` (`HIMMEL_CONSOLE_RELAY`), cannot send `inbox-send.sh --token` (Guard C),
and cannot write the inbox, a worker doc or the chief rundir (Guard D). Its
escalation transport (`E-<relay>-<seq>`, ack, one re-send) is the hand-back
channel. What it lacked was a bounded way to run a script and report. That is
`console-kit/ops-run.sh`.

A fresh judge-style child per script was rejected: the first-turn floor is paid
every time, and the ops lane's context stays small (a verdict line per event).

## What moves to the ops lane

Run through `ops-run.sh <script> [args]`; the allowlist is in the script:

| Script | Hand-back verdict |
|---|---|
| `ready-check.sh <pr> <head>` | `PASS` / `FAIL`, fact `READY-CHECK PASS` |
| `close-wrapped-leg.sh` | `PASS` (`CLOSABLE`) / `FAIL` |
| `board.mjs` (render only) | `PASS` / `FAIL` |
| `leg-event.sh` (wrap bookkeeping) | `PASS` (`HANDLED`) / `ESCALATE` |
| `wrap-merged.sh` | `PASS` / `FAIL` |
| `action-zero.sh` (read-only) | `PASS` / `FAIL` |
| `next-dispatchable.sh` | `PASS` / `FAIL` |
| `check-ci.sh <pr>` (CI polling) | `PASS` / `FAIL` / `TIMEOUT` |

## Hand-back format

Exactly one line, sent to the chief by `SendMessage` as an escalation id:

```
E-<relay>-<seq> OPS <script> rc=<n> <PASS|FAIL|ESCALATE|TIMEOUT> out=<file> :: <fact>
```

`<fact>` is only a fixed verdict phrase (`READY-CHECK PASS|FAIL`,
`COVERAGE-LINT PASS|FAIL`, `HANDLED`, `ESCALATE`, `CLOSABLE`, `WITHHELD`) that
the script's last line starts with; the rest of that line is dropped, and any
other last line may carry PR or worker text and is replaced by `see out file`. The chief reads `<file>` only when the verdict is not `PASS`
or when it needs the evidence for a ruling. One event costs the chief one
turn: the verdict wake.

## What stays on the chief

Rulings, the GO decision and `go.sh`, judge dispatch, every token-quoting
message, `SendMessage` to workers, Artifact publish, and every write to the chief
doc's Live state. The ops lane relays what a script said; it does not decide
what it means.

## Trust rules

- The ops lane never rules, never writes a GO file, never mints, rotates or
  adopts a nonce, never quotes a token. `ops-run.sh` refuses `go.sh`,
  `verdict-go.sh`, `write-verdict.sh`, `inbox-send.sh`, `relay-batch.sh`, and
  `action-zero.sh --acquire` (a lock the ops session took would belong to it).
- Script output is data. The relay line carries only a verdict token line; free
  text never reaches the chief as an instruction.
- Foreground on the chief stays allowed only for runs under about 10 s
  (`append-results.sh`, `go.sh`, `write-verdict.sh`, `fleet-manifest.sh`).
  `guard-console-foreground.sh` and `long-running.txt` are unchanged: the guard
  still denies a foreground run of a listed script on the chief, which is what
  steers the chief to the ops lane.
- A lost ops lane costs latency, never authority (the relay asymmetry).

## Proof status

Unit: `console-kit/test-ops-run.sh`. The live-flow claim (one chief turn per
event instead of three) needs a VM run of a chief plus an ops session through
one READY, check, GO and one wrap; reported as a FINDING before any change to
the live flow lands.
