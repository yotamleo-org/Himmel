# claudex legs hang on BLOCKED and wrap PRs as orphans instead of finishing them

Impact
Claudex (gpt-6.1-sol) legs hold for hours on BLOCKED, then wrap their PR as an "orphan" without finishing it. PR 3070 (N2615) sat unowned with red CI for ~15 h; N2651 and N2647 each held on a console ruling for long stretches today. Every orphan needs operator attention to notice and costs a second leg to finish.
What
Find the root cause of claudex legs hanging and abandoning PRs, with evidence from today's leg docs and transcripts, and fix it.
Why
Operator 10-18: "understand why we have hangs/abandoned PRs in claudex and fix it, probably again items with the bus". Claudex legs have no SendMessage socket: rulings reach them through the file inbox (inbox-send.sh, claudex-inbox-hook.sh PostToolUse), which only fires on the leg's next tool call. A leg waiting idle on an inbox Monitor ("window 2 of 8") may never see the ruling. HIMMEL-6127 (himmel-bus cannot wake an idle leg across succession) is the likely shared cause.
Plan
1. Evidence: for N2615, N2647, N2651 (and every claudex leg in the last 3 days of leg docs in the handover bucket), time from BLOCKED to the ruling's inbox append vs time to the leg's RESOLVED; count orphan WRAPs.
2. Name the mechanism(s): inbox delivery only on tool call, Monitor window expiry, deadline-driven wrap, bus edges lost at succession (HIMMEL-6127), claudex model behaviour.
3. Propose the smallest structural fix per mechanism, each as its own ticket or folded into HIMMEL-6127; implement only what is outside the himmel-bus freeze (decision 9: no himmel-bus feature work except HIMMEL-6127).
DoD
- A findings doc with per-leg timings and the named mechanism(s).
- Each fix filed or folded, with a RED repro named.
Proof
Timings table from the leg docs; a repro that shows a ruling appended to a claudex inbox not delivered to an idle leg.
Agent detail
Files to read: scripts/handover/console-kit/inbox-send.sh, scripts/hooks/claudex-inbox-hook.sh, scripts/hooks/claudex-inbox-sessionstart.sh, scripts/claude-codex (lane launcher), scripts/handover/console-kit/headed-arm-leg.sh, the himmel-bus code and HIMMEL-6127. Evidence: leg docs HIMMEL-5873-N2615-, HIMMEL-5647-N2647-, HIMMEL-4979-N2651-* in the himmel handover bucket and their transcripts. Related: HIMMEL-6127.

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/handover/test-friction-gate-docs.sh`

The checks it must pass include:

- `scripts/handover/test-friction-gate-docs.sh`: claudex preface: a pending CI is never an external blocker
- `scripts/handover/test-friction-gate-docs.sh`: claudex preface: DEADLINE-PENDING re-runs check-ci until green or red
- `scripts/handover/test-friction-gate-docs.sh`: claudex preface: a red CI is the leg's to triage per ci-red.md
- `scripts/handover/test-friction-gate-docs.sh`: claudex preface: the CI wait is bounded and escalates as BLOCKED ci-pending
- `scripts/handover/test-friction-gate-docs.sh`: claudex preface: BLOCKED ci-pending takes the bounded hold, never a wrap
- `scripts/handover/test-friction-gate-docs.sh`: claudex preface: zero reported checks escalates at once, no wait

Run the tests you touch before you finish. Report what you changed and what you checked.
