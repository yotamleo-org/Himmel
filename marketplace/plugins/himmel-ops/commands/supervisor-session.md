---
description: Alias of /himmel-ops:chief — start a supervisor session (new) or hand it over (next).
argument-hint: new|next [--bucket <slug>] [--name <slug>] [--arm] [--dry-run] [--doc <path>] [--model <m>] [--project <dir>]
---

Alias of [`/himmel-ops:chief`](chief.md) (HIMMEL-6641). Kept so the old
`/himmel-ops:supervisor-session` spelling keeps working. Run
`/himmel-ops:chief $ARGUMENTS` — it carries the himmel-checkout resolver, the
`--project` derivation and the full flag reference.
