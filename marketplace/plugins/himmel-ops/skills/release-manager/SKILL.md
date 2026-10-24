---
name: release-manager
description: "The release manager's verbs: rule INTAKE/REVERSION/DISCHARGE requests, report STATUS and BURN-DOWN, check READY."
---

# release-manager — every placement into a release is a reasoned ruling (HIMMEL-6796)

For the release manager only (`HIMMEL_RELEASE_MANAGER=1`). Requests are ruled
by the on-demand batch `jira release rm-run <R>`, which reads this skill as its
judge's instructions; STATUS, BURN-DOWN and READY run in an on-demand session
armed from `docs/handover/rm-brief-template.md`. Every verb is a thin procedure over
`jira release`; the engine holds the formulas, the signatures and the checks,
so the board, the tick and this skill count the same way. Run the CLI by its
absolute path from the primary checkout:
`node <repo>/scripts/jira/dist/index.js release <sub> <R> …`.

There are **no count gates**: a ruling never cites a quota, a cap or a depth
(decision 104). It weighs effort and delivery, and the sector and dependency
chain (decision 100), and names its ground.

## Grounds and classes

- **Ground** (`--ground`): `critical`, `regression`, `broken-operator-flow`,
  `chain:<name>`, `receipt`, `defer:<why>`, `resequence:<why>` (a move within
  the release), `resolved:<resolution>` (a DISCHARGE). A ground explains the
  ruling; it never authorizes a placement by itself.
- **Class** is derived by the engine from the target version: `current` (the
  active version), `next` (a later version of the release), `backlog`.
- **Sector** (`--sector`) is required. A ticket with no sector: ask the chief
  to set it, then rule.
- **Emergencies are always current** (decision 109): an evidenced emergency is
  placed under the standing record `O-<R>-emergency`. Record its class and
  sector; only an operator record moves it out.

## INTAKE / REVERSION / DISCHARGE — one procedure for every request

The chief writes the request and sends `REQ <id>`. Then:

1. `release claim <R>` — claims every open request, and any claimed by an
   older lease epoch. One line per request.
2. Per request, `release rule <R> --req <Q-id> --outcome <O> --op <kind>
   --from <v|backlog> --to <v|backlog> --sector <s> --ground <g>
   --reason-file <f> [--supersedes <ids>] [--authority operator --ref <O-id>]`.

   | Verb | Outcomes (op) |
   |---|---|
   | INTAKE | `ADMIT` (add, move), `BACKLOG` (remove, move, none), `AD-HOC` (none) |
   | REVERSION | `MOVE` (move, remove), `KEEP` (keep) |
   | DISCHARGE | `ACCEPT` (discharge), `REJECT` (none) |

   When a ruling (or the baseline, `baseline-<v>-g<n>`) is already in effect
   for the key and version, `--supersedes` must name it; the error names it.
   An operator ruling cites the chief's `O-` record, which must cover the
   exact key, op and versions; a bare decision number authorizes nothing.
3. `release apply <R> <R-id>` — writes Jira, reads it back, records `applied`,
   posts the receipt comment, records `receipted`, and prints the RULING line.
   Re-run it after any failure: it is idempotent and never posts twice.
4. Send the chief the printed line, verbatim:
   `RULING <id> <req> <verb> <key> <op> <from>→<to> <outcome> <class> sector=<s> — <ground>: <reason>`.
   Only a receipted ruling is sent.

A refusal is a fact to act on, not to route around: UNKNOWN state, a pending
intent, a missing supersedes, an uncovered authority. Report a refusal you
cannot resolve to the chief as a `FINDING`. The `rm-run` judge reports a request it
cannot rule (no sector, missing input) as `{"req","outcome":"HOLD","reason"}`: no
ruling is written and the request stays claimed for the next batch.

## STATUS

`release state <R> --json`. Write `release/<R>/status-<ISO date>-<HHMM>.md`
under the state directory: each input and its freshness, the lease, the open
and claimed requests, the leaks (unauthorized members and ruled-in
non-members), the integrity lines, the burn-down and the trend. Send
`STATUS <path>`. A state that is `UNKNOWN` is reported as UNKNOWN, never as a
clean result.

## BURN-DOWN

From the same state: per version, baseline open of baseline, admitted open,
emergency open and deferred out; then the open keys grouped by sector, with
the next keys per lane you would dispatch from. Write
`release/<R>/burndown.md` and send `BURN-DOWN <path>`. You advise; the
chief dispatches.

## READY [v|R]

Every row is PASS, FAIL or UNKNOWN, and UNKNOWN fails:

1. every baseline key of `v` is terminal or carries an effective move out;
2. every effective `in` key of `v` is terminal;
3. no open Critical, Blocker or Highest bug is `in` (or emergency) for `v`;
4. no leaks, no open or claimed requests for `v`, no integrity lines;
5. every required check succeeded on the candidate sha;
6. the fold covers every Done key merged in the tag range;
7. no open PR is linked to an `in` key of `v` without a deferral ruling.

Sync the mirror first (`mirror`), then read the state. Write
`release/<R>/ready-<v>-<sha7>.md` and send
`READY <v|R> <sha> TAG-READY|NOT-READY <path>`. The operator tags and judges
stability; a FAIL row is overridden only by an operator record naming it.

## Lease and hand-off

- No release manager stands by between requests. `rm-run` takes the lease,
  applies every older-epoch intent, claims, rules and applies each request,
  releases the lease and exits; a held lease refuses a second batch.
- Session start: `release lease acquire <R> --expect-epoch <n> --doc <your doc>
  --session <name>` (the brief names `n`), then `release apply` every
  older-epoch intent it lists in the state (resolved by readback; one Jira
  never saw is voided and its request reopened), then the armed verb.
- Hand-off (after the verb, 45 % context or HALT): apply or void every intent,
  `release lease release <R>`, write `<doc stem>-RM-HANDOFF.md` (release,
  epoch, chain heads, last STATUS path), append `WRAPPED — handoff <path>` and
  send the chief `WRAPPED <path>`.
- You never run `release operator`, `release request`, `create` or
  `transition`; the engine refuses them for you anyway.
