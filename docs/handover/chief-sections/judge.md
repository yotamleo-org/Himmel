# Chief section — judge questions: fields, verdict files, dispatch

Read on demand from `chief-template.md` `## Standing rules`. Moved verbatim from the template.

- **Every judge question leaves four fields, whichever grade asked it:**
  `grade: call|session` · `prior: <one line, written BEFORE asking>` ·
  `answer: <verdict line>` · `flipped: y|n`. Write `prior:` before you ask —
  a prior recorded afterwards measures nothing. This makes M3 (judge flip
  rate) countable by `grep`; keep the field names exactly as written here.
  `flipped` is computed, never typed: pass `--prior <GO|NO-GO>` to
  `write-verdict.sh` (or `verdict-go.sh`) and the signed verdict file gets
  `prior:` and `flipped: y|n` lines; evidence carrying either line is refused.
- **Every judge subagent persists its verdict, trust path or not**:
  `bash scripts/handover/chief-kit/write-verdict.sh <qid> <GO|NO-GO> <head>
  --pr <n> --evidence-file <path> --model <id> --effort <level>` writes
  `verdicts/<qid>/`. `--model` and `--effort` are required and signed into the
  file; the values may come from the flags or from the environment
  (`HIMMEL_VERDICT_MODEL`; `HIMMEL_VERDICT_EFFORT`, then `CLAUDE_CODE_EFFORT_LEVEL`),
  and a write with no value for either is refused (exit 2). A verdict that
  lives only in your context dies with it; the file is what a successor reads.
  Prefer `bash scripts/handover/chief-kit/verdict-go.sh <qid> <GO|NO-GO> <head>
  --model <id> --effort <level>
  --pr <n> --evidence-file <path> --doc <chief doc>`: it runs `write-verdict.sh`,
  `go.sh`, the Results bullet and the board in one call and prints the message to
  send the worker. The hand steps are for a verdict it refuses.
- **Residuals are depth-gated** (HIMMEL-6115): a ticket labelled `residual-depth-<n>`
  (n >= 1) is a judge, CR or panel residual. `write-verdict.sh --residual-of <KEY>`
  stamps `residual-depth-<depth of KEY + 1>` on each ticket the residual lines cite;
  `next-dispatchable.sh` drops depth >= 1 unless the chief doc has a
  `residual-must <KEY>` line (security, data loss or a broken operator flow only),
  and depth >= 2 files to ICE with no fixVersion. Pass `--residual-of <PR ticket key>`
  (to `write-verdict.sh` or `verdict-go.sh`) on EVERY verdict whose residual lines
  cite tickets; an unlabelled parent is depth 0, so its residuals stamp depth 1.
- **Dispatch the judge as `judge-ro`, not the built-in Explore**: same read-only tool list, passes the ruling-20 chief
  dispatch fence, and its body carries the judge contract. A judge reads and
  reasons; it never runs suites or polls CI (the worker's scripts do that), so it
  stays on the 5-minute cache TTL (prediction table:
  `docs/internals/prompt-cache.md`). After each judge, append its ledger row:
  `bash scripts/eval/judge-cache-row.sh --ledger <ledger> <agent-*.jsonl>`.
- **A judge reads the PR at its head sha, never FETCH_HEAD** (HIMMEL-7062): parallel
  judges share one checkout and each `git fetch` overwrites `FETCH_HEAD`. Tell the
  judge to check `gh pr view <N> --json headRefOid` equals the dispatched head,
  check `git cat-file -t <sha>` prints `commit` (a bare `git fetch origin` if not,
  never a refspec fetch: the primary-checkout guard refuses it), then read with
  `git diff origin/main...<sha>` and `git show <sha>:<path>`; never FETCH_HEAD.
- **Convene at the cheapest tier that can rule** (HIMMEL-1864): start a judge subagent at
  Sonnet or Opus and escalate only when it returns above-my-tier
  (`bash scripts/handover/chief-kit/judge-ladder.sh next-tier <tier>`; Fable's next
  rung is the operator). Spend each convening with `judge-ladder.sh convene <seat>
  <tier>` first: a per-seat, per-window budget refuses (rc 3) once spent, because a
  dispute that triggers a convening mints work on the scarcest usage budget. A finding class of
  `guard-no-fire` or `invariant-regression` skips the ladder and the budget:
  `judge-ladder.sh breakglass <class>` routes it to the operator at once.
- **A later push needs a judge only when its delta does** (HIMMEL-7637): after a judge's GO,
  `bash scripts/handover/chief-kit/delta-class.sh --qid <qid> <judged head> <new head>`,
  run in the checkout holding both commits, prints one word and always exits 0:
  `trust` (a changed file, either name of a rename, matches `scripts/ci/ci-trust-paths.txt`
  on `origin/main`), `finding` (the delta rewrites the lines of a finding the judge named, or of a
  CR-ledger finding at the judged head) or `none`. A trust hit wins over a finding hit, and any read
  error (unknown sha, unreadable trust list, verdict or ledger, bad regex) prints `trust`, never
  `none`. The judge names its findings in the verdict file as `finding: <path>[:<n>[-<m>]]` lines
  (no line numbers means the whole file; the line holds nothing else, and any other line starting
  `finding:` reads `trust`); a NO-GO that names none classifies `finding`.
  `trust` and `finding` get a judge as before. On `none` skip the judge and record
  `bash scripts/handover/chief-kit/write-verdict.sh <qid> GO <new head> --pr <n> --evidence-file <path>
  --delta-noop <judged head>` (run in the repo under review): it re-runs the classifier, refuses
  (exit 2) unless it prints `none`, and signs `delta: no-op`, `delta-judged: <sha>` and
  `delta-class: none` into `verdicts/<qid>/delta-noop-<head>.md`. The judged head must carry the
  qid's signed GO; a no-op is never itself a judged head, so each later push is classified against
  the last real judge and the delta stays cumulative. `go.sh --trust-reviewed` re-runs the
  classifier whenever a head's only GO is a no-op and refuses (exit 10) unless it still prints
  `none`, so a trust-path delta cannot merge on a no-op. Running the delta judge on Sonnet needs a
  model-guard change that is not made here (HIMMEL-7650); until it lands, a delta judge runs at the
  tier the guard allows.
- **A deferred Critical or Important finding needs a disposition before GO**
  (HIMMEL-6377): past the round cap such a finding is never dropped. `go.sh` runs
  `cr-disposition.sh check <pr> <head>` and refuses (exit 9) while any
  Critical/Important on the PR's branch is deferred with no valid row at that head.
  The judge rules one of two, which the chief (never the worker) records with
  `bash scripts/handover/chief-kit/cr-disposition.sh record <pr> <head> <fid>@<finding head> fix-here|follow-up:<KEY> --source judge:<qid>|console [--attest ci-green --attest no-data-loss --attest no-weakened-guard]`:
  (a) **fix-here**: fixed in this PR, so the finding's own ledger verdict must
  read fixed or disproved; (b) **follow-up:<KEY>**: merge now with the follow-up
  ticket already filed, and only if the merge cannot break main. The record must
  carry all three attests (CI green at the head, no data loss, no weakened guard)
  or it is refused. **Who decides:** a Critical always needs a judge verdict
  (`judge:<qid>`, a signed GO at the same head whose verdict carries the line
  `<fid>@<finding head> <disposition>`); an Important on a trust-path PR
  needs one too; any other Important may take `console`.
