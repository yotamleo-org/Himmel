---
name: release-manager
description: "Rule version intake, reversion, discharge; status, burn-down, READY."
---

# release-manager — every placement into a release is a reasoned ruling

> **Parked.** The model judge is parked. `jira release rm-run <R>`
> places every request by the door's fixed rules (`scripts/jira/src/release/door.ts`),
> with no model call. `release claim` and `release rule` refuse. The ruling
> procedure below is the parked judge's: only `HIMMEL_RM_JUDGE=model` reaches it,
> and nothing sets that by default. STATUS, BURN-DOWN and READY are unchanged.
>
> An INTAKE is placed by the first rule that matches:
>
> | Rule | When | Placement (ground) |
> |---|---|---|
> | R | a version-repair request from the repair run | the version Jira shows (`door:repair`) |
> | O | the key's newest operator decision is newer than its newest ruling | what the record says (`door:operator:<O-id>`) |
> | Ch | the chief placed it (`request --chief-reason`) | the asked version (`door:chief`) |
> | F | closed with a merged PR | the asked version (`door:done`) |
> | A | labelled `operator-directed`, or a bridge ask | the version it names, else current (`door:operator-ask`) |
> | S | the required remainder of a parent | the parent's version (`door:rest-of:<P>`) |
> | W | In Progress | current (`door:started`) |
> | H | High or Highest | current (`door:serious:<prio>`) |
> | M | anything else | the next version (`door:mild`), else the backlog (`door:mild-no-next`) |
>
> A key never leaves a version it holds: only rules Ch to W move it nearer
> current, and anything else keeps it where it is (`door:stays:<W>`). Rules R and
> O are not clamped. A REVERSION toward current moves only when rules Ch to W
> place the key in that version or nearer current; any other REVERSION keeps the
> key. Only the operator moves a key out. A DISCHARGE is
> accepted for a resolved ticket. A ruling made on the operator's authority
> stands until a newer operator record (`door:operator-standing:<R-id>`).

For the release manager only (`HIMMEL_RELEASE_MANAGER=1`). Requests are ruled
by the on-demand batch `jira release rm-run <R>`, which places them by the door's
rules with no model call (the parked judge's instructions are the rest of this skill); STATUS, BURN-DOWN and READY run in an on-demand session
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
- **Follow-ups**: a follow-up enters current only if it blocks a bucket ticket (its why names it, or `--remainder`) or is critical, a regression or a broken flow; otherwise BACKLOG. A required remainder is typed evidence on the request (`remainder: true` with `follow_up_of: <parent>`, filed by `create --follow-up-of --remainder` or `request --required-by <parent>`); optional hardening carries no flag. The relation is the child's newest live INTAKE-to-current request (a later request that drops it or names another parent replaces it; `request --required-by` on an open request updates that request's evidence once). `state --json` lists every such child of an open current parent that is still outside the version under `remainder_conflicts` with its owner and next command (`unknown` names what the mirror cannot say); the list admits nothing, so a conflict is ruled like any request: a gated placement (operator-directed, High or Highest) needs the operator's words and an ordinary ungated one is ruled on its merits. A refusal's ack ends the notice, not the contradiction: the child stays the chief's, with a refile remedy, never `rm-run`.
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
   The chief's INTAKE or REVERSION into a version for an open ticket labelled
   operator-directed, or of priority High or Highest, cites a `decision` record
   with `words: 1` in its evidence (`operator`) and its why (`operator words:
   <O-id>`). That record's `verbatim` is the operator's own words, checked
   against the decision's verbatim file: admit on it when the words say this
   placement, under `--authority operator --ref <O-id>`; when they do not, rule
   as you would without it. Words that direct placement by priority or urgency
   and name no version (decision 948: "high tickets into" the current release)
   say this placement for an INTAKE of a High or Highest ticket into the
   current release: admit it; the words say nothing for a Medium, Low or
   unprioritised ticket. A request filed by a worker, by the close-time Done
   fold, by the version repair or by the blocker pull (evidence `rule:
   blocker-pull`, ruled under `O-<R>-blocker-pull`) is not gated and may cite no
   such record: rule it as before, never hold it for the missing record. A
   `BACKLOG` (or REVERSION `KEEP`) ruling on a request from the backlog into a
   version wakes the chief, so its reason names the missing condition and the fix:
   what record or fact would let the key in. For a High, Highest or security
   ticket `rm-run` prints that reason as an alert line on the chief's console. A record with no
   `words: 1` (the legacy form) is read as before.
   A REVERSION restoring a key to a version rules `MOVE` with `--op move
   --from backlog --to <v>`. Only for a key whose current ruling carries
   operator authority: when the key's newest operator decision is the
   `add backlog→<v>` that places it, the engine files that ruling as the add
   under that record, and any newer operator word on the key, in any version,
   keeps the restore refused. A key whose current ruling is an RM ruling is
   moved as an ordinary RM move.
3. `release apply <R> <R-id>` — writes Jira, reads it back, records `applied`,
   posts the receipt comment, records `receipted`, and prints the RULING line.
   Re-run it after any failure: it is idempotent and never posts twice.
4. Send the chief the printed line, verbatim:
   `RULING <id> <req> <verb> <key> <op> <from>→<to> <outcome> <class> sector=<s> — <ground>: <reason>`.
   Only a receipted ruling is sent.

A refusal is a fact to act on, not to route around: UNKNOWN state, a pending
intent, a missing supersedes, an uncovered authority. Report a refusal you
cannot resolve to the chief as a `FINDING`. The parked `rm-run` judge reports a request it
cannot rule (no sector, missing input) as `{"req","outcome":"HOLD","reason"}`: no
ruling is written and the request stays claimed for the next batch.

Verify the outcome, not the printed line. An out-of-version approval is a 14-day work permission only: it files no
placement and answers for none, so `request` queues, or refuses, an INTAKE with or without it (`REQ Q-…` is the queued
placement; an ordinary key needs no words). A gated request files without words only when one words-checked operator decision already on record names that key and that exact placement; it must be the newest decision on the key among those for the request's versions, for no version, or keeping the key in the backlog (two at the same instant refuse), newer than every ruling on the key, and the operator and rulings chains must verify to their end. Otherwise the words are required as before, and a work permission never counts. A ruling is finished when
`state --json` lists it under no `unfinished_rulings` (intent or applied means the Jira write, the admissions row or the
receipt is still owed). `status: replay` means `rm-run` finishes it; `status: blocked` is a cross-version move the mirror
shows in neither version with no journalled proof the removal was this ruling's own write: `rm-run` writes no Jira change,
admissions row or receipt for it (each run still takes its lease and writes its run record, and the first records one
`mismatch` event; a repeat on the unchanged move adds none), and `observed` and `next` name the chief's two repairs (`jira fix-version`), after which `rm-run` writes the row and
receipt once. Never read a blocked move as an `rm-run` job. A
BACKLOG or KEEP refusal of a backlog-to-version ask is not fulfilled intent: it appears in `refused_asks` with its
ground and exact `remedy`, and the same ask repeated word for word queues nothing until its evidence, the operator's
words or an `ack` changes.

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
