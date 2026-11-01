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
- A queued line that carries both `text` and `document_path` sends the text, then the file.
- The bridge never receives your path on its own: you run `send-file`; the operator's receipt
  is the proof (quote it in the ticket).
