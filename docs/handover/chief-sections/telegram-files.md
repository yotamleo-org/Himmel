# Send the operator a file on Telegram

Specs and plans to approve go as HTML (Markdown is hard to read on a phone); any other
file (report, log, PDF, image) up to 50 MB goes as it is.

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
- **A spec or plan page is checked before it queues**. A file under
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
  latest spec critic is clean and also sealed that `.html`. A folder that cannot be listed refuses the
  send, naming the folder. The latest critic file of each kind, clean or not, must also pass
  `bun scripts/telegram/chief-route.ts ledger-verify <verdict file>`: its return is a sealed round of its ticket in
  the round ledger (`specs/ledgers/spec-rounds/<KEY>.jsonl`), it is that kind's latest round, and each
  `CONTENT-SHA256` line matches the ledger's seal rows, so an unsealed or hand-sealed return does not send. A page
  whose latest critic ended `SPEC FINDINGS <n>` is refused until the ticket's round of that kind is 3 or more **in the
  ledger**; from then a sealed `FINDINGS` page goes, with the block opening it: the round count, how many critics did
  not end clean, "Rule, don't just sign", each such return verbatim, and every open operator-critical finding of the
  ticket. An `.html` page is its sealed bytes with the block after `<body>`; a page with no `<body>` is refused.
  Rounds are counted per ticket, spec and plan apart, from the ledger and never from file names, so a renamed spec,
  a new file or a deleted critic file changes nothing. `critic-seal.sh` applies the cap when it seals:

  | Round of a kind | Sealed when |
  |---|---|
  | 1 to 3 | always, as a full round |
  | 4 | round 3 of either kind left a blocking finding (major, unrated, `reopens` or `regression`), or a `round-critical` record opens it; it is a closure check, built with `closure-pack <KEY> <spec\|plan> --specs <bucket>/specs` |
  | 5 and on | the chief's one `round-override`, or a `round-critical` record, opens that writer round |

  The three records run only from the chief's console (`HIMMEL_CONSOLE=1`), each with `--specs <bucket>/specs` like
  `closure-pack` and `round-status`, and each is checked again on every read: `round-override <KEY> --findings <id,...> --why "<line>" --chief <session>`, once per ticket, ever, naming
  open blocking ids; `round-critical <KEY> --finding <id> --decision <d> --quote "<operator words>" [--no-round]`, the
  operator's ruling on an operator-critical finding, which closes it and, without `--no-round`, also opens one
  further writer round; and `round-reset <KEY> --decision <d> --quote "<operator words>"`, the operator's order to
  start over, once per ticket. The decision file `specs/decisions/verbatim-decision-<d>-*.txt` must name the ticket
  and hold the quote. A `<spec>.operator-round-r<n>.md` file no longer counts. A judge round is neither counted nor
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
  as before. Plain `send-file` has no read-only form: a signature-class file goes through the check or does not send.
- **The operator asked to see a page that has not passed: the by-request form.** Run
  `bun scripts/telegram/chief-route.ts send-file --by-request "<the operator's request, in words>" <chat_id> <path> ["<caption>"]`.
  It skips the critic check and sends the `.md` or `.html` page marked **NOT PASSED. Not for signature.** at the top of the page,
  with the request quoted there, and the caption opens `NOT PASSED - not for signature (sent on request)`. An empty request is
  refused, a file that is not a `.md` or `.html` page is refused, and nothing queues. The words "Not for signature" stay in the
  sent bytes, so that copy can never pass the signature check: when the critics pass, send the page again without the flag.
  Use it only when the operator asked; a page that merely is not ready yet is not a reason (decisions 725 and 729).
- **Make a spec's sign page with the shared generator, then run the critic.** Generate first:
  `python3 -I scripts/telegram/spec-page-gen.py <spec.md> <out.html>` prints two lines, the sha256 of the
  md it read and of the page it wrote. The critic reads the md AND the page and quotes both shas; seal
  both, one `critic-seal.sh` run per file (the spec critic file, the md, its sha; then the same file, the
  page, its sha); then `send-file` the `.html`. The page names its spec in a `spec-source` meta tag (the
  md's absolute path), so `send-file` applies the spec's critic check to a copy in any folder under any
  name, and refuses it when the critic's seals do not include the page's own bytes. The generator leaves
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
