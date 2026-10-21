# Leg preface section — keep the cache warm or wrap

Read on demand: `scripts/hooks/guard-leg-cache-ttl.sh` names this file when it
refuses a leg's stop. The cost model behind it:
[`docs/internals/prompt-cache.md`](../../internals/prompt-cache.md#leg-keepalive-or-wrap).

## The rule

A leg that ends its turn while it holds its queue lock and has nothing armed
sleeps until something else wakes it, usually the next console relay about an
hour later. Past the 1 h prompt-cache TTL that wake re-writes the whole prefix,
about 20x the cost of a warm turn. So before you end a turn while you still hold
the lock, do ONE of these:

1. **The wait is bounded: arm a wait that returns within 50 minutes**
   (`HIMMEL_LEG_CACHE_KEEPALIVE_SECS`, default 3000), with Bash
   `run_in_background`, and re-arm it on each wake until the wait ends:
   - CI: `bash scripts/check-ci.sh <pr> --max-wait 3000`
   - a condition: `timeout 3000 bash -c 'until <condition>; do sleep 60; done'`
   - holding for `GO` or a console ruling: `sleep 3000`. A `SendMessage` still
     wakes you sooner.
2. **The wait is open-ended: WRAP with a resume brief.** Open-ended means the
   operator, another PR or ticket, or a hold with no end in sight. Follow the
   preface's "Wrapping up" (send `ORPHAN PR` first if your PR is open). The
   console relaunches a successor when the wait clears.

The hook refuses a stop once; a second stop in a row passes. Do not use that as
an escape: the refusal is the rule, not a suggestion.

## Choosing between them

Keep warm while the wait will likely end within a few hours (CI, a PR about to
merge, a `GO` the console has already queued). Wrap when you cannot name when
the wait ends. Over 24 h on 2026-10-19, 16 of 17 cold wakes came from a leg that
armed nothing; the waits were CI (7), another PR (5), the operator (4) and `GO`
(1). The CI and `GO` waits are option 1; the other-PR and operator waits are
option 2.
