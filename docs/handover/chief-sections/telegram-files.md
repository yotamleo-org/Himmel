# Send the operator a file on Telegram

Specs and plans to approve go as HTML (Markdown is hard to read on a phone); any other
file (report, log, PDF, image) up to 50 MB goes as it is.

**A text reply is short.** The operator reads `chief-route.ts reply` on a phone: one idea per message,
plain words, the ask on its own last line. Several short replies beat one long one. A reply over 3000
characters is never cut: it goes as several messages in order, each opening `(1/3)`, `(2/3)`, `(3/3)`,
split at a paragraph, then a line, then a sentence break. Needing the split usually means the reply is
too long: say less, or send the detail as a file.

Read on demand from `chief-template.md` step 11 (Telegram inbox). Run from the repo root:

```
bun scripts/telegram/chief-route.ts send-file <chat_id> <path> ["<caption>"]
```

- A `.md` or `.markdown` path is rendered to a standalone HTML page first (raw HTML in the
  source is shown as text; the page blocks scripts).
- The file is COPIED into `<bridge root>/outgoing/<id>/` and one `document_path` line is
  queued in the chat's outbox; the poller uploads it with `sendDocument`. The poller ships
  only a regular, non-symlink file whose real path is inside `outgoing/`, so a path elsewhere
  is refused and the chat is told. A group session's outbox never sends a file.
- A missing path, a directory or a file over 50 MB is refused with a clear error and a
  non-zero exit; nothing is queued.
- **A spec or plan page is checked before it queues (a sign ask; see "Read send and sign ask" below)**. A file under
  `specs/{design,designs,spec,plan,plans}/` or `specs/HIMMEL-<n>/`, or one a plan critic file names, is a
  signature page. It is refused, naming the verdict file and queueing nothing, unless its highest-round
  `<spec>.critic-spec-r<n>.md` AND `<spec>.critic-plan-r<n>.md` each end in `SPEC CLEAN` / `PLAN CLEAN`
  and carry a `CONTENT-SHA256 <sha> <relative path>` line whose file still hashes to that sha (a spec or
  plan edited after the critic read it fails). The plan critic may sit beside the spec, or beside the plan
  as `<same name>.critic-plan-r<n>.md` in a `plan`/`plans` folder of the same `specs/` root (the higher
  round wins; the same round in two folders needs both clean); the latest plan critic of ANY spec that
  seals the page must also be clean, or the send is refused naming it; a plan in `plans/` that has a same-named spec in a
  `design`/`designs`/`spec` folder with spec critic files is governed by that spec. A `<stem>.html`
  sign page beside a `<stem>.md` is governed by the `.md`'s critics first: it goes only when the `.md`'s
  latest spec critic is clean and also sealed that `.html`. A companion page `<stem>.<suffix>.html` (an
  executive brief or another summary) beside a `<stem>.md` and with no critic file of its own is governed by
  the `.md`'s seal, clean or capped as above, and needs one more record: its latest page critic
  `<page>.critic-page-r<n>.md` beside it ends `PAGE CLEAN` and seals the page's exact bytes. Seal it with
  `critic-seal.sh <page>.critic-page-r<n>.md <page> <sha256 the critic quoted>`; a page seal adds no
  ledger row. The refusal names which record is missing, the parent's seal or the page critic, and the
  caption adds `PAGE CLEAN r<n>`. A folder that cannot be listed refuses the
  send, naming the folder. The latest critic file of each kind, clean or not, must also pass
  `bun scripts/telegram/chief-route.ts ledger-verify <verdict file>`: its return is a sealed round of its ticket in
  the round ledger (`specs/ledgers/spec-rounds/<KEY>.jsonl`), it is that kind's latest round, and each
  `CONTENT-SHA256` line matches the ledger's seal rows, so an unsealed or hand-sealed return does not send. A page
  whose latest critic ended `SPEC FINDINGS <n>` is refused until the ticket's round of that kind is 5 or more **in the
  ledger**; from then a sealed `FINDINGS` page goes, with the block opening it: the round count, how many critics did
  not end clean, "Rule, don't just sign", each such return verbatim, and every open operator-critical finding of the
  ticket. An `.html` page is its sealed bytes with the block after `<body>`; a page with no `<body>` is refused.
  Rounds are counted per ticket, spec and plan apart, from the ledger and never from file names, so a renamed spec,
  a new file or a deleted critic file changes nothing. `critic-seal.sh` applies the cap when it seals:

  | Round of a kind | Sealed when |
  |---|---|
  | 1 to 5 | always, as a full round |
  | 6 | round 5 of either kind left a blocking finding (major, unrated, `reopens` or `regression`), or a `round-critical` record without `--restores` (a finding ruling or a `--closure` round) opens it; it is a closure check, built with `closure-pack <KEY> <spec\|plan> --specs <bucket>/specs` |
  | 7 and on | only a `round-critical` record opens it: under standing decision 1418 the chief writes the verbatim-decision file itself (it names the ticket, quotes the operator's words of 1418 and gives the chief's own reason; decision 1419 is the worked example), then runs `round-critical <KEY> --decision <d> --quote "<operator words>" --closure` (or `--finding <id>` for an operator-critical finding); the chief never skips the file |

  The cap was 3 before decision 1420. A ledger row sealed or recorded under that cap (a closure round 4 or 5, a record
  opening one) still reads.

  A record opens a round only for the kind or kinds whose next round it is: a finding ruling or an unscoped `--closure`
  opens round N for each kind whose next round is N (both kinds when spec and plan are level), a `round-override` for the
  kinds of the findings it names, a `round-extension` for the kinds it names. A kind that lags the writer round gets its
  round with `round-critical ... --closure --round <spec|plan>:<n>`; when the targets of a bare `--closure` sit at two
  different rounds the verb refuses and names each `--round`. A `round-reset` is refused, and read as invalid, on a
  decision any earlier record already spent. The refusal text of a lagging kind ends with the `--closure --round` line to type.

  The four records run only from the chief's console (`HIMMEL_CONSOLE=1`), each with `--specs <bucket>/specs` like
  `closure-pack` and `round-status`, and each is checked again on every read: `round-override <KEY> --findings <id,...> --why "<line>" --chief <session> --decision <d> --quote "<operator words>"`, once per ticket, ever, naming
  open blocking ids, with the same decision file and quote as `round-critical` (a call without them is refused; an old ledger row without them still reads); `round-reclass <KEY> --round <spec|plan>:<n> --why "<line>" --chief <session>`, once per closure round, which re-classes a closure round stored before a classifier fix towards blocking and is refused once a `reset`, `critical`, `override` or `extension` record, or a later round or re-class of the same critic, follows that round; `round-critical <KEY> --finding <id> --decision <d> --quote "<operator words>" [--no-round]`, the
  operator's ruling on an operator-critical finding, which closes it and, without `--no-round`, also opens one
  further writer round; `round-critical <KEY> --decision <d> --quote "<operator words>" --closure [--round <spec|plan>:<n>]`, with no `--finding`,
  the operator's yes to one more round when no finding is operator-critical, which opens the next refused round as a
  closure check, for the kinds whose next round it is (`--round` names the one refused target to open, and is required when
  the targets sit at different rounds; refused when that round needs no record, and once per decision: a decision any record already used is refused); and `round-reset <KEY> --decision <d> --quote "<operator words>"`, the operator's order to
  start over, once per ticket. The decision file `specs/decisions/verbatim-decision-<d>-*.txt` must name the ticket
  and hold the quote. A quote under 20 characters counts only as the operator's answer to a Question block, written with
  `bun <himmel>/scripts/handover/chief-kit/ask-question.ts ask` and answered with `bun <himmel>/scripts/handover/chief-kit/ask-question.ts answer`.
  In such a file only the answer paragraph is the operator's words. **Never pick `<d>` by hand** (a chief and a T3 thread did, on one station, and gave two rulings one
  number): take it with `bash <himmel>/scripts/handover/chief-kit/rulings-in-force.sh next-id --bucket <bucket>`, which
  reserves the next free number under a lock and prints it, then write the file with that number and `record` it;
  `record` refuses a number whose file or ledger row sits at another path. A `round-critical ... --restores` record, for a reverses-ruling finding whose fix restores a
  ruling on record, needs neither the key in the decision file nor a fresh file: the finding must say it reverses
  that decision, the quote must be in the file byte for byte, and the finding's kind's next round, which opens by
  itself, checks it. A `<spec>.operator-round-r<n>.md` file no longer counts. A judge round is neither counted nor
  limited. **Adopter stations:** after `himmel-update` brings the round ledger, run
  `bun scripts/telegram/chief-route.ts round-seed --all <bucket>/specs` once for every bucket on that station, and
  add `*.jsonl.lock` (that pattern only, never the ledger) to each bucket's ignore list. Until a bucket is seeded,
  every seal there is refused. The Telegram caption opens with the verdict lines
  read from those files (your own caption follows), and a rendered page opens with them too. A critic
  return is sealed, once per file the critic read, with
  `bash scripts/handover/chief-kit/critic-seal.sh <verdict file> <file it read> <sha the critic quoted>`
  (the return itself must quote that sha); a verdict with no such line is refused until it is. Minerva seals its own
  returns: after each critic round it runs that command once per file under review, so a spec it wrote a page for
  goes with no hand seal, and a spec it wrote no page for (a build `core-check` answers `NOT-CORE`) goes as its `.md`.
  The hand command stays for any other page and for a return in flight when this landed. Reports, logs and audits under no such path send
  as before.
- **Read send and sign ask.** The check above is the **sign ask**: it applies only to
  `send-file --sign <chat_id> <path>`, the form the spec-sign copy (`spec-cc.sh`) runs, and a refusal there
  stands. A send **without `--sign`** is for reading: a page that passes the check goes as above, with its verdicts
  in the caption; a `.md` or `.html` spec or plan page that does not pass (its name opens with a ticket key, or a critic file,
  a `spec-source` marker or a plan critic governs it) goes marked **DRAFT, not for signing**, in the caption and at the top of the
  page; any other file under `specs/` (a report, log, PDF, image, or a `.md`/`.html` with no ticket key and no critic) goes as it is, unmarked.
  A DRAFT copy never replaces a signing send: ask for a signature only with `--sign`, after the critics pass. `--sign` and
  `--by-request` cannot be combined. A companion page (above) sent for reading without its page critic goes DRAFT; with both
  records it goes with its verdicts.
- **Signing frozen nonblocking findings.** Sending a capped `FINDINGS` page does
  not itself authorize signing. The normal `release operator spec` and
  `release operator spec-review` commands automatically try verified carry only
  after their existing residual-disposition check fails. Give one key, canonical
  `--spec`, explicit distinct canonical `--plan` and both actual latest paired
  SPEC/PLAN `--verdict` returns. Findings-bearing kinds must be at their refused
  cap, with required genuine artifact seals, only minor/medium residuals and no blocking/critical tags; unresolved
  historical operator-critical findings still need the operator's ruling. Keep
  frozen bytes unchanged, even with zero inline dispositions. Refused/missing/
  incompatible verification stays refused; partial semantic review coverage
  still needs its owner. Existing approvals, permission fences and lints apply;
  `spec-review` remains a review record, not a signature.
  The five-flag `capped-fold --key --spec --plan --spec-return --plan-return`
  diagnostic takes a value for each flag and prints read-only JSON, with no
  authority or coverage repair. Use current Bun (`.bun-version`) and compatible
  Jira source/built dist and verifier dependencies in the recording checkout;
  retain that checkout while signatures depend on it. File, ledger, manifest,
  decision-mtime or decision filename selection drift can stale them. Build briefs
  retain full provenance and require separate coverage for `spec:F1` and `plan:F1`.
  A signature of two or more keys, or of a one-key spec the shipped verifier refuses, is the separate v2 route: see
  "Ledger-bound capped carry (proof v2)" below, and do not use it for a real signing yet.
- **The operator asked to see a page that has not passed: the by-request form.** Run
  `bun scripts/telegram/chief-route.ts send-file --by-request "<the operator's request, in words>" <chat_id> <path> ["<caption>"]`.
  It skips the critic check and sends the `.md` or `.html` page marked **NOT PASSED. Not for signature.** at the top of the page,
  with the request quoted there, and the caption opens `NOT PASSED - not for signature (sent on request)`. An empty request is
  refused, a file that is not a `.md` or `.html` page is refused, and nothing queues. The words "Not for signature" stay in the
  sent bytes, so that copy can never pass the signature check: when the critics pass, send the page again with `--sign` instead.
  Use it only when the operator asked; a page that merely is not ready yet is not a reason (decisions 725 and 729).
- **Make a spec's sign page with the shared generator, then run the critic.** Generate first:
  `python3 -I scripts/telegram/spec-page-gen.py <spec.md> <out.html>` prints two lines, the sha256 of the
  md it read and of the page it wrote. The critic reads the md AND the page and quotes both shas; seal
  both, one `critic-seal.sh` run per file (the spec critic file, the md, its sha; then the same file, the
  page, its sha); then `send-file --sign` the `.html`. The page names its spec in a `spec-source` meta tag (the
  md's absolute path), so `send-file --sign` applies the spec's critic check to a copy in any folder under any
  name, and refuses it when the critic's seals do not include the page's own bytes; a send without `--sign` goes marked DRAFT instead. The generator leaves
  the front matter status out and refuses, naming the line and writing nothing, an md body line that
  starts with `Status:` or says "not for signature": the draft state lives in the missing critic seal.
  The page draws the spec's `svg` fence under `## Diagrams` as a figure and carries send-file's own CSP meta; a
  spec with no such fence, or with one the generator will not draw (a script, an event, a `style` attribute or a
  link out of the figure), is refused, naming the line, and nothing is written. A spec already in a round when this
  landed gets its diagram in that round's fix when its page is regenerated; a spec at its cap keeps its sealed
  page untouched.
  Edit the spec after that and the md, the page and the critic all start over. A hand-built page with no
  marker, outside the folders above, still reads as a report.
- The check covers `send-file` only. A file the bridge chat copies into `outgoing/` and queues itself is
  not checked. Limit: a hand-built `.html` there carries no link to its spec; lifting it takes
  a follow-up that starts with a ruling on how to tell a report from a spec page; the PR names its ticket.
- A queued line that carries both `text` and `document_path` sends the text, then the file.
- The bridge never receives your path on its own: you run `send-file`; the operator's receipt
  is the proof (quote it in the ticket).

## Ledger-bound capped carry (proof v2)

**Do not use this route for any real signing until the operator has approved live issuance (item 6); until then every
command below is for fixtures only.** It is a way to sign a frozen spec of one or more keys that stopped at its review cap
with only minor or medium findings. It is built and tested only in hermetic fixture roots, and a signature is not Done.

**1. The verifier flags and the signing root.** `bun scripts/telegram/chief-route.ts capped-fold` takes exactly one of
`--key <K>` (the shipped one-key verifier: its arguments, output, exit codes and refusal order are unchanged) or
`--keys <K1,K2,...>` (proof v2, one or more keys), each with `--spec`, `--plan`, `--spec-return` and `--plan-return`,
each flag once. Both together, an empty, repeated or trailing-comma key, or a missing flag exits 1 with a
`capped-fold:` message. It is read-only, prints one JSON line and grants no authority. A signing is
`jira release operator spec <release> --keys <K,...> --spec <file> --plan <file> --verdict <file> --verdict <file>
--decision <n> --verbatim-file <f>` for the chief, or with `--signer operator --words "<his exact words>"` in place of
`--verbatim-file` for a spec the operator marked as his, and `--source-root <path>` names where the spec's citations
are read: the primary or a registered live linked worktree of this repository (default: the primary).

**2. The producer route and its order.** Only `jira release operator spec` takes it, and only after the normal
residual-disposition check has refused. One key runs the shipped `--key` verifier first; only when that verifier exits
non-zero does the engine try `--keys <K>` (v2). Two or more keys go to v2 only. A timeout, a spawn error (no `bun`, output
over the bound), a child killed by a signal, output that is not JSON, and a proof that fails validation, the binding to
the signing inputs or the pin check are final and never retried on v2. When v2 was tried, a refusal reads
`...; capped verifier unavailable/refused: <first reason>; v2: <v2 reason>`, and for a group the first reason is the shipped
one-key guard text labelled `v1 route:`. A guard that refuses before any spawn (no `--plan`, or the spec given as the
plan) refuses once with the shipped words `capped carry requires one key, an explicit distinct plan and paired SPEC/PLAN
returns`, and a final failure of the shipped one-key verifier ends at `capped verifier unavailable/refused: <reason>`, with
no `v2:` part. A one-key signature that the shipped verifier accepts is still stored as a schema-1 record; the v2 route
stores schema 2 (`mode: capped-carry-ledger`).

**3. The keys are the spec's own `tickets:` line.** `--keys` must equal, as a set, the keys on the one `tickets:` line
of the spec's front matter (a flow list or a comma list; each item a key with at most one trailing parenthetical
note of 200 characters or fewer): no missing, extra or repeated key. The anchor is the key in the spec's file name (or its `specs/<KEY>/` folder); it must be
one of the keys, and the spec, the plan and every return carry it in their file names. The anchor owns the ledger and no
flag chooses it. A spec head or plan header that states keys must state exactly these keys. The engine checks the
declaration against the signed spec bytes at signing and on every read.

**4. The two accepted quote shapes.** A critic return's `READ` quote is read in exactly one of two shapes: `READ` or
`READ-SHA256`, a 64-hex sha, one or two spaces, then the path; or (the legacy order) `READ` or `READ-SHA256`, an absolute
path, a space, then the sha. Any other `READ` line refuses (`capped-fold: malformed seal or READ quote`), and the quotes
must equal the ledger's seals. A return's `Keys?:` line and its `Reviewed: spec <sha>` line are each optional on their own:
a `Keys?:` line, when present, must be the only such line and name exactly the declared keys; a `Reviewed: spec <sha>`
line, when present, must be the only such line and carry the current spec hash; a return with either, both or neither is
accepted when each line it has agrees. The verifier checks this, and the engine checks it again at signing and on every read.

**5. What does not change.** Members must hold no ledger state (item 8). The cap rule is unchanged: only a kind that
stopped at its refused review cap carries, only its latest minor or medium findings carry and at least one must; a major,
a reserved tag, a closure major, an open historical operator-critical finding without the operator's ruling, or a kind
whose next round is admitted (a live override included) refuses. Carried findings are stored as `open-carried` entries and
nothing in code closes one: a signature is not Done. `spec-review` is unchanged: it never takes the v2 route, stays a
review record and not a signature, and still needs its `Key:` lines and the spec header. A direct `--key`
verification, every stored schema-1 record and the normal signing path behave as before.

**6. The live issuance gate.** No live schema-2 record is written, and no frozen family is signed through v2, until the
operator decides one of two gates. Gate (A) is normal adoption of this change on the primary (merge and station update),
which removes the pre-capped readers. Gate (B) needs both a separately reviewed exact changed-candidate build with its own
explicit adoption approval and an actual bounded ceilings entry (`scripts/ledger/ceiling-add.sh`) naming the
pre-capped-reader exposure and the containment; neither decision exists today. Relying on gate (B) is a full pause of normal
automatic fleet dispatch and of new normal headed launches that reach the primary `brief-lint.sh`; it is
not a per-family filter, and no code selects the family keys. Eight consumers must be stopped against v2 state while the
primary is pre-capped, and none is accepted as display-only and none is claimed to check a proof. No consumer is stopped by
this plan and no acceptance exists: nothing in code stops any of the eight, and none is stopped today. The eight are
`next-dispatchable.sh`, `gen-briefs.py`, `brief-lint.sh` and `roadmap.ts`, all through the primary dist's `release spec-check`; `tracker.py`
(`operator_owed`) and `board.ts` (`specItems`), which read `release/<version>/operator.jsonl` directly and treat any
`kind: spec` row as signed without checking `capped_carry`; and the manual primary `jira release spec-check` and
`jira roadmap get` of the operator and the chief. Gate (B) cannot open until each one's quiescence or safe routing is
shown in a reviewable operational plan, with the explicit future operator approval and the ceilings entry; no wrapper,
environment bypass or extra source path is added. Before any consumer resumes, gate (A) must hold and every
candidate-issued record must read `SPEC ok` under the merged engine or be normally superseded. No gate may be inferred from
the existing exact-candidate exception (04bc and its 988 words), from the placement of decision 988 or from the single
aggregate PR, and normal dispatch resumed earlier voids the containment.

**7. The signing rules.** `lintSpec` and both minerva scripts load from the primary checkout, found through the git
common directory, even when the engine runs from a candidate worktree: only the citation root is selectable. A gate-(B)
signing therefore (1) passes `--source-root <the exact reviewed candidate worktree>`, which binds that root's identity
and HEAD; (2) before signing, records both primary-loaded lint-script hashes and compares them with the candidate's
copies, and any difference is a STOP, by the command below; after signing, the readback is the record's `source_root`
and `source_head` equal to the candidate's and `jira release spec-check` by the candidate build's own path; (3) takes the
member-absence listing fresh at that signing (the verifier and the engine re-run the one predicate), so no earlier absence
note is an input and none grants authority. The same rule applies to the CORE signature of 10278 itself while its
citations are branch-only. Real issuance is the chief's or the root's.

**How to run the command below (checked on scratch directories).** Run it through bash and never paste it into your own
shell: `CAND=<the candidate worktree's absolute path> bash -c '<the block below, between the single quotes>'`. It is bash
syntax: it is not valid as typed in fish, and its `exit 1` would end your own shell. With `CAND` a non-empty absolute path
that is not the primary, it prints nothing and exits 0 only when both lint scripts exist on both sides and are byte-equal.
Any output at all, or a non-zero exit, is a STOP: a changed copy prints `STOP` and exits 1; a script missing on one side
prints a `sha256sum` error and `STOP` and exits 1; a script missing on both sides exits 0 but prints `sha256sum` errors.
What it does not detect: `CAND` empty, unset or equal to the primary (the primary is then compared with itself, and an
empty `CAND` passes silently in zsh), so check by hand that `CAND` is the candidate before you run it.

<!-- signing-hash-check -->
```bash
h() { (cd "$1" && sha256sum marketplace/plugins/himmel-ops/scripts/minerva-spec-gate.sh marketplace/plugins/himmel-ops/scripts/minerva-trace-lint.sh); }; PRIMARY=$(dirname "$(git -C "$CAND" rev-parse --path-format=absolute --git-common-dir)"); [ "$(h "$PRIMARY")" = "$(h "$CAND")" ] || { echo STOP >&2; exit 1; }
```

**8. The member-key operating rule.** No member key opens its own spec round while the group record is live; an
independent design for a member uses a new follow-up ticket key. Any member ledger file, snapshot folder or manifest entry
under the anchor's specs root makes every key of the record read `SPEC-STALE`, the anchor included, and the same group
cannot be re-signed while it exists: a supersession is itself a fresh group signing, so it must keep every key of the old
record and releases no member. The check covers only the anchor's specs root; a member ledger under another specs root
is not seen. No ledger is deleted to recover signability, and no automatic recovery is described or built.
