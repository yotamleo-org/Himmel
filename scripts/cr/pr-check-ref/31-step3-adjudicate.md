# /pr-check reference: step 3.2: adjudicate panel candidates

   **Step 3.2 — Adjudicate the panel candidates (HIMMEL-926, HIMMEL-1219 round 3; decimal substep, runs after the panel).** ONE phase since HIMMEL-2704. Adjudicate the panel (3.0) candidates NOW and persist the verdicts, so step 4's exclusion rule and `orphan-check.sh` read an adjudicated set rather than raw candidates. There is no longer a CodeRabbit phase here: **CodeRabbit is the GitHub App only** (operator ruling 2026-09-07, HIMMEL-2704), and the App reviews the PR AFTER `gh pr create` — nothing local to run or conserve. See step 7 for the App's post-PR contract. (The label **phase A** is kept below and in step 4 for the verdict-persisting write — it is the name those steps already cross-reference. There is no phase B to look for.)

   **Why adjudication happens HERE and not later (HIMMEL-1219 round 3, kept after HIMMEL-2704).** Rounds 1–2 let the raw *candidate* count drive decisions that were made BEFORE adjudication, so a round whose candidates were all later DISPROVED still behaved as if the diff were dirty. The fix was to adjudicate first and let only candidates that SURVIVE adjudication count. HIMMEL-2704 retired the CodeRabbit CLI pass that was the original consumer of that count, but the ordering stays: step 4's cross-check, `clear-cr-marker.sh` gate 4 and `orphan-check.sh` all read the persisted verdicts, and each of them is wrong if it reads candidates nobody adjudicated.

   **Adjudicate the panel candidates.** You — the orchestrating session — are the mandatory adjudicator (the default-path role described in step 3.5, pulled forward to here so the persisted verdicts are adjudicated ones). For EVERY panel `[<slug>-N]` Critical/Important candidate produced in 3.0, apply the HIMMEL-178 verify-before-critical rule (grep the diff / read the file at the cited line; downgrade or drop a Critical whose cited content is not in the diff) and the cross-model adjudication directive in step 3.5 (AGREE with cited evidence, or DISPROVE with evidence — grep/read/test), then emit exactly one verdict line per candidate in the standard format the rest of the runbook parses:

   ```text
   VERDICT [<slug>-N] = agreed|disproved|conflict|unaddressed
   ```

   **A 5th verdict, `deferred`, exists for a candidate that is a REAL finding but genuinely out-of-scope for this branch (HIMMEL-2375) — never write `agreed` (which leaves a residual the panel re-raises every round, so the gate can never clear) or `disproved` (a lie) for one of these.** It is accepted ONLY with a ticket, in the form `VERDICT [<slug>-N] = deferred -> <TICKET>` (the same ticket shape `ledger-append.sh --deferred-to` requires) — a bare `deferred` with no ticket is rejected by `write-verdicts.sh` like any other malformed line. **`deferred` never blocks**: step 4's exclusion rule treats it exactly like `disproved`, so an all-deferred round still clears. This is independent of, and does not replace, the CR ledger's own `--verdict deferred --deferred-to <TICKET> --fu-class <escape|hardening|polish>` (step 4.5) — record both: this line drives the reconciliation, the ledger record is the tracked, audited disposition.

   These verdict lines are NOT throwaway: they are the SAME verdicts step 4's cross-check reconciles against, so adjudicating here does the step-3.5/4 work once, not twice — carry them into the step-3.5 aggregate verbatim. A candidate you cannot confirm or refute gets `unaddressed`, which counts as a blocker below (fail-closed, matching step 4), forcing a resolution before the gate can clear. On the opt-in `CR_CLAUDE_AGENTS=1` path the dispatched agents re-adjudicate the full diff in 3.5 and may add verdicts; step 4 reconciles any session-vs-agent disagreement as a `conflict` (which blocks) — so an agent disagreeing with your early call can never ship a false-clean.

   **The signal must be STRUCTURAL, not instructional (HIMMEL-195 — prose does not enforce).** Persist the verdicts to the branch-scoped prior-blocking file — `<git-common-dir>/cr-prior-blocking/<branch>`, the same file rounds 1–2 used, now holding verdict lines instead of a raw integer count — and let step 4's cross-check DERIVE the blocking count from them with its exclusion rule (the "Excluded from blocking count" bullet), with `scripts/cr/orphan-check.sh` deriving the orphan half from the same file. That closes the "session forgot to flip the value" shape entirely: the count is computed from verdicts, not asserted. The `<branch>` scope is load-bearing (round 1b): `<git-common-dir>` is the SHARED git dir common to every worktree in the checkout, so an unscoped file would have two concurrent /pr-check runs on different branches racing on ONE file. himmel runs concurrent /pr-check by design (`/overnight-shift` treats per-ticket branches as independent products), so this is a normal scenario here, not a corner case.

   ```bash
   # Phase A — persist the panel/codex adjudication verdicts you just rendered.
   # Author one `VERDICT [<id>] = <verdict>` line per candidate in a scratch
   # file with the Write tool, then hand that file to
   # scripts/cr/write-verdicts.sh via --from-file, REPLACING the prior-blocking
   # file's contents (step 0 truncated it). The helper is the
   # classifier-sanctioned write path (HIMMEL-2131): an inline
   # `cat > ... <<EOF` heredoc is denied by the auto-mode classifier, which
   # silently degrades this structural signal to fail-open.
   # --branch takes step 0's printed `branch=` LITERAL (HIMMEL-2226: a runtime
   # value as a dash-flag operand is refused by the worktree-isolation guard,
   # and each fence is its own process anyway), SINGLE-QUOTED because a pasted
   # branch name is shell-parsed and a git ref may legitimately carry shell
   # metacharacters; the file is branch-scoped because git-common-dir is
   # SHARED across worktrees (round 1b).
   # Pass ZERO verdict lines (an empty scratch file) when 3.0
   # produced no candidates — the readers below then see an adjudicated-empty
   # set rather than an absent one. That empty write is ALSO the fail-open
   # default: a write that is skipped or left unfilled reads as 0 blockers,
   # never as a silent block (the invariant this file must never break). So
   # do NOT feed placeholder `VERDICT [<slug>-N] = <verdict>` lines verbatim —
   # step 4's cross-check and orphan-check.sh both read this file, and they
   # would count a placeholder as a real adjudication you never actually made;
   # feed the REAL verdicts, or nothing.
   #   Spelling: the fence shows the canonical adopter-safe absolute form. On
   #   the himmel lane run the cwd-relative literal `bash scripts/cr/write-verdicts.sh ...`
   #   instead (HIMMEL-4040, preamble) — the shape the allow rule
   #   `Bash(bash scripts/cr/write-verdicts.sh:*)` matches and
   #   `guard-pr-check-literal.sh` accepts. No extra operator rule is needed
   #   (HIMMEL-2601; the denial was fixed by HIMMEL-3383/3495).
   # `guard-pr-check-literal.sh` denies a pipe into this writer, and (as of
   # HIMMEL-3798 round 3, "CUT, do not patch") denies every heredoc and
   # `< <file>` redirect shape outright — three rounds of the same
   # regex-approximates-bash-grammar mechanism finding a new bypass meant the
   # mechanism itself, not the regex, was wrong. The sanctioned shape is
   # `--from-file <path>`: use the Write tool to author the verdict lines
   # into a scratch file first, then run ONE ordinary, argument-only command
   # naming that path as a plain literal — no heredoc, no redirect, nothing
   # for the guard's text-matching to approximate. The guard restricts the
   # `--from-file` value to a single literal token with no shell
   # metacharacters/quotes/glob/whitespace; the script itself fails closed
   # (refuses) if the path is a symlink, missing, unreadable, or empty.
   #   Example — write one VERDICT line per candidate you adjudicated to a
   #   scratch file (e.g. via the Write tool), then:
   #     bash "<himmel_dir>/scripts/cr/write-verdicts.sh" prior-blocking --branch '<branch>' --from-file <scratch-path>
   #   with <scratch-path> containing:
   #     VERDICT [codex-1] = disproved
   #     VERDICT [codex-2] = agreed
   #   Pass an EMPTY file (zero verdict lines) when 3.0 produced no
   #   candidates — do not skip the call.
   bash "<himmel_dir>/scripts/cr/write-verdicts.sh" prior-blocking --branch '<branch>' --from-file <scratch-path>
   ```

   **There is no CodeRabbit phase in `/pr-check` (HIMMEL-2704).** CodeRabbit is the GitHub **App**, and the App reviews the PR only AFTER `gh pr create` — there is nothing local to invoke here, nothing to conserve, and no `[coderabbit-N]` candidates to adjudicate at this step. The CLI wrapper (`scripts/cr/coderabbit-review.sh`) and the conserve-or-run gate (`scripts/cr/coderabbit-gate.sh`) that used to occupy this slot are DELETED, along with `CODERABBIT_BIN`, `CODERABBIT_WSL`, `CODERABBIT_TIMEOUT_SECS` and `CODERABBIT_CLI_DISABLE`. Do not reintroduce them: the operator's ruling (2026-09-07) is that every CodeRabbit finding is commented on and tracked **on the PR in GitHub**, and each CLI round was costing an extra paid codex panel row to satisfy the cross-model marker at the new head.

   **What this leaves the pre-PR gate.** The cross-model coverage `clear-cr-marker.sh` gate 3b requires under `CR_REQUIRE_CROSS_MODEL=1` comes from the panel/codex `avail … ok` rows, exactly as it has since the CLI was last armed — no shape change, one fewer possible source. The prior-blocking verdicts file written above is still read by step 4's exclusion rule and by `orphan-check.sh`; it simply no longer gates a CodeRabbit call.

   **The App's contract, which step 7 enforces after the PR exists — CodeRabbit is best effort (HIMMEL-3360).** It is one CI-only reviewer beside the panel: a finding it posts blocks like any other, its absence blocks nothing, and nothing schedules or holds work on it (`scripts/hooks/check-cr-best-effort.sh` gates the tracked text). Three things, none of which this step can do:
   - **One trigger per head, posted by CI hooks.** `scripts/hooks/trigger-cr-on-pr-create.sh` / `trigger-cr-on-push.sh` post `@coderabbitai review` once per new head (a new head DISCARDS the in-flight review); a manual push still owes that one comment. Whether the App answers is its business.
   - **The THREAD QUERY is the truth — a green check-run is not clean.** On 2026-09-06, PR #2209 carried six unresolved CodeRabbit threads under a `pass` check-run. `check-ci.sh` gates on unresolved review threads (exit 3) precisely because the rollup does not.
   - **Its commit status is a NOTE, never a verdict.** `coderabbit-signal.sh` reads CodeRabbit's **commit status** (it posts no check-run) and `check-ci.sh` prints it as advisory — `absent`, `pending`, `paged`, `skipped`, rate-limited and an unreadable status all pass through; only an unresolved thread or an undispositioned outside-diff body finding blocks. Armed per-clone with `git config --local himmel.coderabbit true`, which decides only whether the status is read at all.
