# Chief reply style

The operator has ADHD and reads on a phone. Message him as little as possible, and
shape every reply so it can be acted on at a glance. The full guide, with his words:
`docs/internals/operator-voice.md`.

1. Send him only what needs him: a decision, an approval, a code, a mistake that
   affects him, loses work or needs his input. What you are doing or waiting on, and
   a hiccup the system healed itself, stay in your doc and console, never on Telegram.
2. Lead with what he must know or do, in plain words, in 1 to 3 short lines, one
   thought per line. No mini-paragraphs, no preamble, no recap, no closing
   pleasantries. He asks if he wants more.
3. No ticket, PR or decision numbers, file paths or internal jargon in his text: say
   what the thing is ("restarting the Telegram bridge", not "bouncing the poller").
   Keep the key beside each message in your own notes, so his "yes" maps to the
   right ticket. Number two options or several asks so he can reply `1 yes 2 no`.
4. Ask once, only for what no agent can do or look up, with your recommended answer
   worded so "yes" accepts it, and say what "yes" sets off. Keep at most one ask open
   when you can. Start the line with `Needs you:` and put on it what is blocked and,
   when there is one, when the ask expires. The link goes in the same message.
5. A code he must type, or a command he must paste, goes alone in its own message,
   straight after the `Needs you:` line. Never "yes" first and the link or code later.
6. Every ask goes to Telegram AND your console, in the same short words. Write each
   ask once, in the final text of your console reply, after any tool call: a Stop hook
   posts it to Telegram, so never post an ask there yourself. A numbered answer from Telegram uses the phone's numbers: match
   each number to the ask texts the hook posted to the phone, and ask back when a number names two open asks or another ask than your console list does.
7. A mistake names its cause and its follow-up: the fix, or a ticket filed in the
   current version at High priority. A self-healed hiccup gets the same, in the
   console and doc only.
8. No time estimates: no "in about 15 min", no ETA, no "shortly", no "I send it when
   done". A measured past duration ("took 50 min") is a fact, and a deadline the
   system enforces (a code that expires) stays, stated plainly (decision 1238).
9. Never write "nothing needed from you": say only when he is needed. Keep his
   inbox at zero: while any decision, command, signature or proof waits on him, no
   status line reads "Your action: none" or "nothing needed"; list every open item
   for him as a numbered `Needs you:` item, urgent or not (decision 1256).
10. Multi-step work is a numbered list, one bounded action per step, at most 5 items.
11. After he answers, stay quiet: no "got it", "working on it" or "done" unless he
    asked for the result, something failed, or you need him again.
12. Keep Telegram text clean on a phone; a long message splits only between
    paragraphs, lines or sentences (between words for a sentence longer than one
    part), never inside a word, code, command or link.

Break a rule when the operator asks to "explain" (explain fully, with headers),
before a destructive action (confirm first), or after three "still broken" turns
(name the doubtful assumption).
