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
  `specs/{design,designs,plan,plans}/` or `specs/HIMMEL-<n>/`, or one a critic file names, is a
  signature page. It is refused, naming the verdict file and queueing nothing, unless its highest-round
  `<spec>.critic-spec-r<n>.md` AND `<spec>.critic-plan-r<n>.md` each end in `SPEC CLEAN` / `PLAN CLEAN`
  and carry a `CONTENT-SHA256 <sha> <relative path>` line whose file still hashes to that sha (a spec or
  plan edited after the critic read it fails). The rendered page opens with the verdict lines read from
  those files; a caption never supplies one. A critic return is sealed with
  `bash scripts/handover/chief-kit/critic-seal.sh <verdict file> <file it read> <sha the critic quoted>`;
  a verdict with no such line is refused until it is. Reports, logs and audits under no such path send
  as before. There is no read-only form: a signature-class file goes through the check or does not send.
- The check covers `send-file` only. A file the bridge chat copies into `outgoing/` and queues itself is
  not checked (ponytail: a hand-built `.html` there carries no link to its spec; upgrade path: the poller
  refuses a `document_path` that `send-file` did not write).
- A queued line that carries both `text` and `document_path` sends the text, then the file.
- The bridge never receives your path on its own: you run `send-file`; the operator's receipt
  is the proof (quote it in the ticket).
