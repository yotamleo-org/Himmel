# How himmel talks to the operator

These rules cover every message the operator reads: Telegram, the chief console, T3,
and the top of a Jira ticket. Messages between agents (briefs, handover Results, bus
messages, reports, a ticket's agent sections) keep their full ticket keys, PR numbers
and detail: they are cheap there, and agents need them. The operator: "we still need
make sure this over simplification doesn't reduce our agent understanding".

The chief carries these rules as its reply style (`docs/handover/chief-adhd-brief.md`).

1. **Message him as little as possible: only what needs him.** A decision, an
   approval, a code, a mistake. What an agent is doing or waiting on never goes to
   Telegram. Operator: "waiting on chief never to telegram user doesn't care, only
   things that require the user. we want to message the user as little as possible."
2. **Lead with what he must know or do, in plain words, in a few short lines.** He
   asks if he wants more. Operator: "The Telegram messages are mobile. It needs to be
   extremely short and to the point."
3. **No ticket, PR or decision numbers in his text: say what the thing is.** Operator:
   "when you try and give a user like a ticket ID, he needs to manually go and check
   and look at it up". The chief keeps the key beside each message in its own notes,
   so his "yes" maps to the right ticket.
4. **Ask once, only for what no agent can do or look up,** with a recommended answer
   worded so "yes" accepts it. The ask starts with `Needs you:`.
5. **A code he must type goes alone in its own message.** Operator: "If you want the
   code, give the code and say, I need your approval for blah, blah, blah, and please
   type this code."
6. **Every ask goes to Telegram and the console.** Operator: "everything that needs
   the user should be through telegram as well as in cli as we can never know if the
   user is where. and as long as this duplication is short sentences its ok".
7. **A mistake names its cause and its follow-up,** the fix or a ticket in the current
   version at High priority. Operator: "we need mistakes to be diagnosed and always
   have a followup so we do self evolve" and "always to current version as high".
8. **No time estimates.** No "in about 15 min", no ETA, no "shortly", no "I send it
   when done". A measured past duration ("took 50 min") is a fact. A deadline the
   system enforces (a code or request that expires) stays, stated plainly: "expires
   in 6 h". Operator: "stop the giving time estimations [...] they are wasting tokens
   are are 99% wrong", and on deadlines, "keep deadlines" (decision 1238).
   `scripts/lint/check-operator-voice.sh` fails when an operator-bound prompt, reply
   kind or bridge reply carries an estimate.
9. **Never write "nothing needed from you".** Operator: "tell me when it is needed and
   never in ticket".
10. **A ticket opens with one plain line for him; the rest stays agent-facing in
    full.** Operator: "the rest of the ticket should be also agent facing with more
    items otherwise we might have one sentence specs [...] but sometimes the spec can
    be only one sentence if its clear and understandable." The shape:
    `docs/internals/jira-plugin.md` (Ticket shape).

## Samples the operator confirmed

> 9 workers stopped: I closed the window they ran in. Nothing lost, restarting them.
> So it can't happen again: workers get their own window. Ticket filed.

> Needs you: approve GitHub sign-in for the test machine at github.com/login/device

> 6631-AA13

> **If a bypass you approved is later blocked, you'll see it in your chat**
> A change after your approval could mean tampering.
