# Console section — judge questions: fields, verdict files, dispatch

Read on demand from `console-template.md` `## Standing rules`. Moved verbatim from the template.

- **Every judge question leaves four fields, whichever grade asked it:**
  `grade: call|session` · `prior: <one line, written BEFORE asking>` ·
  `answer: <verdict line>` · `flipped: y|n`. Write `prior:` before you ask —
  a prior recorded afterwards measures nothing. This makes M3 (judge flip
  rate) countable by `grep`; keep the field names exactly as written here.
- **Every judge call persists its verdict, trust path or not**:
  `bash scripts/handover/console-kit/write-verdict.sh <qid> <GO|NO-GO> <head>
  --pr <n> --evidence-file <path>` writes `verdicts/<qid>/`. A verdict that
  lives only in your context dies with it; the file is what a successor reads.
  Prefer `bash scripts/handover/console-kit/verdict-go.sh <qid> <GO|NO-GO> <head>
  --pr <n> --evidence-file <path> --doc <console doc>`: it runs `write-verdict.sh`,
  `go.sh`, the Results bullet and the board in one call and prints the message to
  send the leg. The hand steps are for a verdict it refuses.
- **Dispatch a judge call as `console-judge-ro`, not the built-in Explore**: same read-only tool list, passes the ruling-20 console
  dispatch fence, and its body carries the judge contract. A judge reads and
  reasons; it never runs suites or polls CI (the leg's scripts do that), so it
  stays on the 5-minute cache TTL (prediction table:
  `docs/internals/prompt-cache.md`). After each judge, append its ledger row:
  `bash scripts/eval/judge-cache-row.sh --ledger <ledger> <agent-*.jsonl>`.
- **Convene at the cheapest tier that can rule** (HIMMEL-1864): start a judge call at
  Sonnet or Opus and escalate only when it returns above-my-tier
  (`bash scripts/handover/console-kit/judge-ladder.sh next-tier <tier>`; Fable's next
  rung is the operator). Spend each convening with `judge-ladder.sh convene <seat>
  <tier>` first: a per-seat, per-window budget refuses (rc 3) once spent, because a
  dispute that triggers a convening mints work on the scarcest bank. A finding class of
  `guard-no-fire` or `invariant-regression` skips the ladder and the budget:
  `judge-ladder.sh breakglass <class>` routes it to the operator at once.
