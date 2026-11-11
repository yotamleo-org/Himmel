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
  **The judge writes it, not you**: a `gen-judge-brief.py --dispatch-json`
  prompt for a PR head names the judge's own `write-verdict.sh` line (qid,
  head, PR, model and effort filled in), and `judge-ro` runs it through Bash
  with its evidence in the scratch dir `scripts/judge-dir.sh <PR>` makes. Its
  tools line stays `Read, Grep, Glob, Bash`, because `guard-chief-dispatch.sh`
  gives the read-only lane only to that exact line. You write the file by hand
  only when the judge's reply reports a refused write.
- **A judge whose verdict never landed is re-dispatched by code**: `chief.sh
  next` reads the outgoing session's subagent registry (the one
  `live-subagents.sh` reads). For every `judge-ro` call whose description is the
  generator's `Judge <qid> on <KEY>` and whose `verdicts/<qid>/` holds no file
  written since that dispatch (a reused qid keeps its older verdicts), it writes `JUDGE-OWED <qid> — <description> — brief: <transcript>` into the
  successor's pre-computed ACTION ZERO block. A `judge-ro` call with any other
  description is listed as `JUDGE-OWED unknown (<agent-id>: <description>)`; no
  owed judge reads `JUDGE-OWED: none`. The successor checks `verdicts/<qid>/`
  again for a file newer than the `.meta.json` beside the named transcript, then
  re-dispatches each one still owed from the prompt in that transcript, through
  the generator with a fresh nonce.
  Prefer `bash scripts/handover/chief-kit/verdict-go.sh <qid> <GO|NO-GO> <head>
  --model <id> --effort <level>
  --pr <n> --evidence-file <path> --doc <chief doc> --contract <yes|no>`: it runs
  `write-verdict.sh`, `go.sh`, the Results bullet and the board in one call and
  prints the message to send the worker. `--contract` is the brief's
  `Completes ticket:` answer; `go.sh` refuses a PR titled with a ticket key
  without it, and `no` leaves `--jira-transition` off the merge line. The hand
  steps are for a verdict it refuses.
- **Residuals are depth-gated**: a ticket labelled `residual-depth-<n>`
  (n >= 1) is a judge, CR or panel residual. `write-verdict.sh --residual-of <KEY>`
  stamps `residual-depth-<depth of KEY + 1>` on each ticket the residual lines cite;
  `next-dispatchable.sh` drops depth >= 1 unless the chief doc has a
  `residual-must <KEY>` line (security, data loss or a broken operator flow only),
  and depth >= 2 files to ICE with no fixVersion. Pass `--residual-of <PR ticket key>`
  (to `write-verdict.sh` or `verdict-go.sh`) on EVERY verdict whose residual lines
  cite tickets; an unlabelled parent is depth 0, so its residuals stamp depth 1.
- **Lock/succession model-check evidence is optional, never a replacement judge**:
  before judging a PR touching `queue-lock.sh` or
  `chief-kit/succession-tracker.sh`, the chief assigns an isolated worker or
  subagent to run
  `bash scripts/handover/chief-kit/model-check-report.sh <pr> <queue-lock|succession-tracker> <absolute-model.tla> <absolute-view.mjs>`.
  Never run statechart inside the chief: the chief and judge read the report,
  chart and retained `inputs/` (model, config, view and source snapshot) as
  needed for fidelity review, not the compiler execution transcript. Keep
  model execution cost/context in its own session.
  Java is an optional prerequisite; without it this step stays off and prints
  OpenJDK installation guidance. Preparation, fixed small constants (at most
  four busy-loop iterations), pinned external TLC jar and hard timeouts:
  [`docs/internals/model-check.md`](../../internals/model-check.md).
  The judge brief names the absolute `report.md` path and its full PR head;
  the judge cites the report path in their verdict, checks head freshness,
  model fidelity and every unchecked rule, and reasons independently. A clean
  report never replaces the judge: the with-skill arm missed the bug where an old token could delete a fresh queue lock,
  which the no-skill arm found. A missing chart or incomplete/timeout report
  is not a pass. Replay counterexamples against real code (destructive lock
  replays are VM-only); a succession run also leaves a `FINDINGS.md` verdict.
- **Dispatch the judge as `judge-ro`, not the built-in Explore**: same read-only tool list, passes the ruling-20 chief
  dispatch fence, and its body carries the judge contract. A judge reads and
  reasons; it never runs suites or polls CI (the worker's scripts do that), so it
  stays on the 5-minute cache TTL (prediction table:
  `docs/internals/prompt-cache.md`). After each judge, append its ledger row:
  `bash scripts/eval/judge-cache-row.sh --ledger <ledger> <agent-*.jsonl>`.
- **A judge reads the PR at its head sha, never FETCH_HEAD**: parallel
  judges share one checkout and each `git fetch` overwrites `FETCH_HEAD`. Tell the
  judge to check `gh pr view <N> --json headRefOid` equals the dispatched head,
  check `git cat-file -t <sha>` prints `commit` (a bare `git fetch origin` if not,
  never a refspec fetch: the primary-checkout guard refuses it), then read with
  `git diff origin/main...<sha>` and `git show <sha>:<path>`; never FETCH_HEAD.
- **Start an ordinary first or trust judge at Opus**: Sonnet is only for the
  re-judge of a later push whose delta classifies `finding` (below). Escalate only
  when a judge returns above-my-tier
  (`bash scripts/handover/chief-kit/judge-ladder.sh next-tier <tier>`; Fable's next
  rung is the operator). Spend each convening with `judge-ladder.sh convene <seat>
  opus` first (a Sonnet seat is `convene <seat> sonnet --delta finding`; it refuses
  without that context): a per-seat, per-window budget refuses (rc 3) once spent, because a
  dispute that triggers a convening mints work on the scarcest usage budget. A finding class of
  `guard-no-fire` or `invariant-regression` skips the ladder and the budget:
  `judge-ladder.sh breakglass <class>` routes it to the operator at once.
- **A per-page docs review is a helper, not a judge**: it goes to `sonnet` per the
  helper table in [`running-a-chief.md`](../running-a-chief.md#dispatching-workers).
- **A later push needs a judge only when its delta does**: after a judge's GO,
  `bash scripts/handover/chief-kit/delta-class.sh --qid <qid> <judged head> <new head>`,
  run in the checkout holding both commits, prints one word and always exits 0:
  `trust` (a changed file, either name of a rename, matches `scripts/ci/ci-trust-paths.txt`
  on `origin/main`), `finding` (the delta rewrites the lines of a finding the judge named, or of a
  CR-ledger finding at the judged head, or a merge in the delta has a non-empty remerge-diff, a
  resolved conflict, checked after every fail-closed read) or `none`. A trust hit wins over a
  finding hit, and any read error (unknown sha, unreadable trust list, verdict or ledger, bad
  regex) prints `trust`, never `none`. The judge names its findings in the verdict file as `finding: <path>[:<n>[-<m>]]` lines
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
  `none`, so a trust-path delta cannot merge on a no-op.
  **A delta judge may run on Sonnet**: the re-judge of a LATER push whose
  `delta-class.sh` prints `finding` puts one line of its own in the judge's prompt,
  `DELTA-JUDGE: <the head sha it judges, 7 to 40 lowercase hex>`, and `guard-agent-model.sh`
  then allows `model: sonnet` on a `judge` or `judge-ro` dispatch with no `ESCALATION:` line
  (it echoes `agent-model-delta-judge: …` on stderr). The marker rescues Sonnet only: haiku and
  fable stay denied. The first full judge of a PR keeps Opus, and so does a delta that prints
  `trust`: the guard only reads the declaration and cannot check the class, so the chief does.
  **Do not pick the model by hand**: put `"delta_class": "<what delta-class.sh printed>"` in the
  `gen-judge-brief.py` spec (`finding` or `trust`; a first judge omits it). `finding` runs on
  Sonnet and carries the `DELTA-JUDGE: <head>` line (it needs `pr` and `head`, takes no `tier`,
  and refuses another model); `trust` and no key keep Opus.
- **Dispatch an in-process judge from the generator's object, never by hand**:
  `python3 scripts/handover/chief-kit/gen-judge-brief.py <spec.json> --chief <you> --dispatch-json`
  prints ONE Agent input object (`description`, `subagent_type: "judge-ro"`, `model`, `prompt`,
  `run_in_background: false`; diagnostics on stderr). Pass that object unchanged as the Agent
  call: do not rebuild the model or copy marker lines yourself. Its `model` is the alias
  `opus`, `sonnet` (finding delta) or `fable`; Fable needs an `escalation_reason` in the spec
  that passes `scripts/guardrails/agent-model-policy.json` and is rendered as the
  `ESCALATION:` line, Haiku is refused, and any other id is refused rather than guessed.
  Dispatch mode writes nothing (no bucket document, queue lock or RESUME file), so a rerun for
  the same qid is safe. The prompt carries a fresh RETASK nonce with the direct-parent rule and
  a distinct `JUDGE-BRIEF: <nonce>` line: declared generator provenance, not proof the generator
  ran. `guard-agent-model.sh` only warns (additionalContext) on a judge call without it, and the
  digest counts marked and unmarked judge calls. Without `--dispatch-json` the generator writes
  the headed-session RESUME brief as before (its last stdout field is `model=<id>`).
- **Never leave the model out of a judge call**: after an `agent-model-deny`, re-dispatch with
  the explicit model the deny names (`opus` for a judge, `sonnet` only with a `DELTA-JUDGE:`
  line). `guard-subagent-model.sh` denies a dispatch with no model, so omitting it is not a
  remedy.
- **A deferred Critical or Important finding needs a disposition before GO**:
  past the round cap such a finding is never dropped. `go.sh` runs
  `cr-disposition.sh check <pr> <head>` and refuses (exit 9) while any
  Critical/Important on the PR's branch is deferred with no valid row at that head.
  The judge rules one of two, which the chief (never the worker) records with
  `bash scripts/handover/chief-kit/cr-disposition.sh record <pr> <head> <fid>@<finding head> fix-here|follow-up:<KEY> --source judge:<qid>|chief [--attest ci-green --attest no-data-loss --attest no-weakened-guard]`:
  (a) **fix-here**: fixed in this PR, so the finding's own ledger verdict must
  read fixed or disproved; (b) **follow-up:<KEY>**: merge now with the follow-up
  ticket already filed, and only if the merge cannot break main. The record must
  carry all three attests (CI green at the head, no data loss, no weakened guard)
  or it is refused. **Who decides:** a Critical always needs a judge verdict
  (`judge:<qid>`, a signed GO at the same head whose verdict carries the line
  `<fid>@<finding head> <disposition>`); an Important on a trust-path PR
  needs one too; any other Important may take `chief`.
  A `WAKE ready … disposition=open:<n>` already ran that same check at the
  READY head (`ok` = it passes): open findings need their disposition before GO.
