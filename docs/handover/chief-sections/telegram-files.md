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
  send, naming the folder. Today a page whose critic return carries no `CONTENT-SHA256` line is refused,
  and so is one whose latest critic ended `SPEC FINDINGS <n>` even when it passed with minors. The seal
  line is proof of the bytes read, not of who wrote it: a chief could append a sha it computed itself, and
  `send-file` does not check the quote. The Telegram caption opens with the verdict lines
  read from those files (your own caption follows), and a rendered page opens with them too. A critic
  return is sealed, once per file the critic read, with
  `bash scripts/handover/chief-kit/critic-seal.sh <verdict file> <file it read> <sha the critic quoted>`
  (the return itself must quote that sha); a verdict with no such line is refused until it is. Reports, logs and audits under no such path send
  as before. There is no read-only form: a signature-class file goes through the check or does not send.
- The check covers `send-file` only. A file the bridge chat copies into `outgoing/` and queues itself is
  not checked (ponytail: a hand-built `.html` there carries no link to its spec; upgrade path:
  a follow-up that starts with a ruling on how to tell a report from a spec page; the PR names its ticket).
- A queued line that carries both `text` and `document_path` sends the text, then the file.
- The bridge never receives your path on its own: you run `send-file`; the operator's receipt
  is the proof (quote it in the ticket).
