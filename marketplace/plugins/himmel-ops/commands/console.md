---
description: Alias of /himmel-ops:supervisor-session — start a supervisor session (new) or hand it over (next).
argument-hint: new|next [--bucket <slug>] [--name <slug>] [--arm] [--dry-run] [--doc <path>] [--model <m>] [--project <dir>]
---

Alias of `/himmel-ops:supervisor-session` (HIMMEL-5585). Kept so the old
`/himmel-ops:console` spelling keeps working. Run
`/himmel-ops:supervisor-session $ARGUMENTS` — it carries the himmel-checkout
resolver, the `--project` derivation and the full flag reference.
