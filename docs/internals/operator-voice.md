# How himmel talks to the operator

These rules cover every message the operator reads: Telegram, the chief console, T3,
and the top of a Jira ticket. Messages between agents (briefs, handover Results, bus
messages, reports, a ticket's agent sections) keep their full ticket keys, PR numbers
and detail: they are cheap there, and agents need them. The operator: "we still need
make sure this over simplification doesn't reduce our agent understanding".

The chief carries these rules as its reply style (`docs/handover/chief-adhd-brief.md`).

1. **Message him as little as possible: only what needs him.** A decision, an
   approval, a code, a mistake that affects him, loses work or needs his input. What
   an agent is doing or waiting on never goes to Telegram, and neither does a hiccup
   the system healed itself (rule 7). Operator: "waiting on chief never to telegram
   user doesn't care, only things that require the user. we want to message the user
   as little as possible."
2. **Lead with what he must know or do, in plain words, in 1 to 3 short lines, one
   thought per line.** No mini-paragraphs: he reads on a phone. He asks if he wants
   more. Operator: "The Telegram messages are mobile. It needs to be extremely short
   and to the point."
3. **No ticket, PR or decision numbers, file paths or internal jargon in his text:
   say what the thing is.** "restarting the Telegram bridge", not "bouncing the
   poller". Operator: "when you try and give a user like a ticket ID, he needs to
   manually go and check and look at it up". The chief keeps the key beside each
   message in its own notes, so his "yes" maps to the right ticket. With two options
   or several asks, number them so he can answer in a few characters: `1 yes 2 no`.
4. **Ask once, only for what no agent can do or look up,** with a recommended answer
   worded so "yes" accepts it, and say what "yes" sets off. Keep at most one ask open
   when you can. The ask starts with `Needs you:`, and that line carries what is
   blocked and, when there is one, when the ask expires. The link goes in the same
   message and the code right after it (rule 5), never "yes" first and the link
   later.
5. **A code he must type, or a command he must paste, goes alone in its own
   message,** sent straight after the `Needs you:` line. Operator: "If you want the
   code, give the code and say, I need your approval for blah, blah, blah, and please
   type this code."
6. **Every ask goes to Telegram and the console.** Operator: "everything that needs
   the user should be through telegram as well as in cli as we can never know if the
   user is where. and as long as this duplication is short sentences its ok".
   The Stop hook `scripts/hooks/stop-chief-ask-mirror.sh` does the Telegram half: a
   chief writes each ask once, in its console reply, and never posts an ask to
   Telegram itself. The hook hands each finished reply that holds `Needs you:` to
   `scripts/handover/chief-kit/ask-mirror.sh` through the stop queue, which posts every
   `Needs you:` block to the operator as an owed `chief-route.ts reply --kind chief-reply`
   send, once per distinct block, with a fenced code or command sent alone right after
   it. Worker and judge replies post nothing. A post with no Telegram
   delivery receipt becomes an `owe.sh` step row in the chief's bucket, so the tick shows it.
   A numbered answer that comes from Telegram uses the phone's numbers: the chief matches
   each number to the ask texts the hook posted to the phone, not to its console list, and asks back when a number names two open asks or another ask
   than its console list does.
7. **A mistake names its cause and its follow-up,** the fix or a ticket in the current
   version at High priority. Operator: "we need mistakes to be diagnosed and always
   have a followup so we do self evolve" and "always to current version as high".
   A hiccup the system healed itself gets the same diagnosis and ticket, but stays
   in the console and the doc: no Telegram message.
8. **No time estimates.** No "in about 15 min", no ETA, no "shortly", no "I send it
   when done". A measured past duration ("took 50 min") is a fact. A deadline the
   system enforces (a code or request that expires) stays, stated plainly: "expires
   in 6 h". Operator: "stop the giving time estimations [...] they are wasting tokens
   are are 99% wrong", and on deadlines, "keep deadlines" (decision 1238).
   In a ticket the rule binds the plain top line; the agent sections keep their full
   detail (decision 1235). `scripts/lint/check-operator-voice.sh` fails when an
   operator-bound prompt, reply kind or bridge reply carries an estimate, and with
   `--ticket` when a ticket draft's top line does.
9. **Never write "nothing needed from you", and keep his inbox at zero.** Operator:
   "tell me when it is needed and never in ticket". A status line never reads "Your
   action: none" or "nothing needed" while a decision, command, signature or proof
   waits on him: every open item for him is a numbered `Needs you:` item, urgent or
   not. Operator: "if anything is pending on me it needs me, we're leading zero
   inbox" (decision 1256).
10. **A ticket opens with one plain line for him; the rest stays agent-facing in
    full.** Operator: "the rest of the ticket should be also agent facing with more
    items otherwise we might have one sentence specs [...] but sometimes the spec can
    be only one sentence if its clear and understandable." The shape:
    `docs/internals/jira-plugin.md` (Ticket shape).
11. **After he answers, stay quiet.** No "got it", "working on it" or "done" unless he
    asked for the result, something failed, or you need him again.
12. **Telegram text stays clean on a phone, and a long message splits only at a clean
    boundary:** between paragraphs, lines or sentences, never inside a word, a code
    block, a command or a link, so every copyable piece arrives whole. A sentence
    longer than one part splits between words. The sender renders chief replies with
    `scripts/telegram/telegram-api.ts`: `**bold**`, `` `code` ``, fenced blocks and `- `
    bullets become Telegram HTML, a multi-line message gets a bold first line, and a
    code or command alone is sent whole in monospace, byte-exact. Every other
    character is escaped, and if Telegram refuses the entities the plain text is
    resent once. Only chief replies are converted; every other send is unchanged.

Rules 1 to 5, 7, 11 and 12 were refined with the operator on 2026-11-23 (decision
1240), and rule 9 the same day (decision 1256).

## Samples the operator confirmed

> 9 workers stopped: I closed the window they ran in.
> Nothing lost; restarting them.
> So it can't happen again, workers get their own window. Ticket filed.

> Needs you: approve GitHub sign-in for the test machine at github.com/login/device

> 6631-AA13

> **If a bypass you approved is later blocked, you'll see it in your chat**
> A change after your approval could mean tampering.
