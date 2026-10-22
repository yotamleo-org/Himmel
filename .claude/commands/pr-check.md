---
description: Run the multi-agent CR review on the current branch and clear the pre-push marker on clean output
---

Status-check the CR gate: run the cross-model CR matrix (critic panel; the `pr-review-toolkit:*` Claude reviewer agents only when `CR_CLAUDE_AGENTS=1` — HIMMEL-926). CodeRabbit is NOT part of this matrix: it is the GitHub App and reviews the PR after it exists (HIMMEL-2704) for the current branch and clear the pre-push marker if the review is clean. This is the in-session counterpart to the pre-push hook — the hook writes a marker, this command reviews and clears it. Without a clean run, `gh pr create` is blocked by the PreToolUse hook.

**Usage:** `/pr-check` — **no arguments, ever** (HIMMEL-2226). It reviews the repo the session is already in; to review another repo, start a session whose cwd IS that repo. Read the `repo=` and `branch=` step 0 prints and confirm they are the repo you meant.

## How this runbook is organised

This file is the driver: the steps in order, what each decides, and where its detail lives. The detail (every fence, rule and rationale, verbatim) sits in reference files under `scripts/cr/pr-check-ref/`. **Read a stage's reference file when that stage runs, not before** — a run that stops early never loads the later ones. Before step 0 has printed `himmel_dir=`, read a reference as the cwd-relative `scripts/cr/pr-check-ref/<file>` only in a himmel worktree root; after step 0, read `<himmel_dir>/scripts/cr/pr-check-ref/<file>`. "Above" and "below" inside a reference file mean the reference file of that step.

Rules every fence obeys (full contract, the enumerated refused shapes and their history: `00-preamble.md` — read it when a fence is refused, or before editing one):

- Every ```bash fence runs VERBATIM as its own Bash call; fences inherit no variables and no cwd. No fence `cd`s. Values step 0 prints (`himmel_dir=`, `branch=`, `head=`, …) are substituted into later fences as LITERALS, never re-derived.
- **Single-quote every repo- or reviewer-controlled value** (`'<branch>'`, `<slug>`, `<class>`, free-text `--reason`, paths built from them); a value containing `'` is escaped `'\''`, and if you cannot escape it confidently REFUSE the fence and say why. Leave `<head>`, `<db_sha>`, `<severity>`, `<status>`, `<verdict>`, `<today>`, `<pr-num>` unquoted; `"<himmel_dir>/scripts/…"` keeps its double quotes, the quote spanning the whole path.
- Spelling of a himmel script call: when cwd is a himmel worktree root whose `scripts/cr/` matches the anchor's (HIMMEL-4040; the himmel lane, whether or not `himmel_dir=` equals `repo=`), run the cwd-relative literal `bash scripts/cr/<script>.sh <literal args>`; otherwise (adopter lane, drifted `scripts/cr/`) keep `bash "<himmel_dir>/scripts/cr/<script>.sh" <literal args>`. `pr-check-env.sh` is the exception (HIMMEL-3375): spell it relative only when step 0 itself ran by the himmel-lane spelling (lane proof and guarded-path diff check both passed, branch unchanged since); otherwise keep the anchored `bash "<himmel_dir>/scripts/cr/pr-check-env.sh"`. A denied call is retried ONCE as the relative literal, then goes to the console. A denial naming a deny rule or policy is never respelled around — stop and report it.
- Never fall back to a bare `rm` of a marker, a hand-written ledger row or a hand-computed tier filter: the scripts named in each step are the only write paths.

## Steps

0. **Resolve the himmel checkout and the run context through the trusted anchor** (HIMMEL-2035, HIMMEL-2226, HIMMEL-2335, HIMMEL-3798). One call, no argument, no `cd`:
   ```bash
   bash "$HIMMEL_REPO/scripts/cr/pr-check-step0.sh"
   ```
   It prints `pr-check-context: key=value` lines (`repo=`, `branch=`, `himmel_dir=`, `head=`, `base=`, `marker=`, `lane=`, `anchor_lane=`, `delegated=`, `cr_diff_files=`, `behind_base=`, `main_ahead=`); carry them forward as literals. `behind_base=` is how many commits the branch lacks from `origin/<base>` and `main_ahead=` how many commits local `<base>` carries beyond `origin/<base>` (HIMMEL-5601; informational on every profile, `unknown` when a ref is missing): a large number means a stale base, so `git merge origin/<base>` before trusting a 2-dot diff. Exit 2 = fail closed (`HIMMEL_REPO` unset or empty, not a himmel checkout, not a git work tree) and exit 4 = the session resolved to the default branch or a detached HEAD: stop, never trust a context from a non-zero exit, never fall back to a bare relative spelling outside the himmel-lane conditions. Details, the himmel-lane spelling (a cwd-relative literal, himmel checkout only, after a lane proof and a guarded-paths diff check), delegation and the verdict-scratch resets: `10-step0.md`. If this fence is refused as "cannot be shown not to run git", the session is EnterWorktree-pinned — `docs/internals/stuck-playbook.md` (HIMMEL-3536), not a respelling.

2. **Marker and lane.** If the `marker=` path step 0 printed does not exist, report `no pending CR for <branch> (HEAD=<head>) — nothing to do` and stop. Otherwise use the `lane=` value step 0 printed (there is no fence): `docs-audit` runs the docs-audit lane (2.5) instead of the full matrix; `full` or empty (legacy markers) is the normal flow. Reference: `20-step2-lanes.md` (also 2.5 docs-audit lane and its charter, 2.7 doc-freshness advisory, 2.8 known-findings self-review — advisory, run before any critic spends a round).

3. **Cross-model finding pass, then adjudication** (HIMMEL-178, HIMMEL-270, HIMMEL-415, HIMMEL-926, HIMMEL-2704). The operator has authorised sending review diffs to Codex from legs (HIMMEL-3338); a denial on an external-critic call is most likely a spelling problem — check the himmel-lane spelling first.
   - 3.0 critic panel first pass via `scripts/cr/panel-first-pass.sh --head <head> --branch '<branch>'`, which prints `pr-check: round N of 3 on <branch>` (a delta round after round 3; a 4th full round exits 8 — take it to the chief; a later change clears on a signed judge GO at its exact head, `review-round.sh judge-go`, not a round). Exit 3 = the automatic step 2.8 preflight found open hits: close them with the two commands it prints, then re-run. Exit 9 = the preflight could not run or be recorded: run `known-findings.sh --diff --area` by hand, then re-run; no round was started either way. Panel exit 7 = input-pin mismatch: ABORT, never degrade. Exit 6 = certify refusal: claude-only, marker stays held. Read stdout and stderr separately. `CR_PROFILE=none` skips the panel. Reference: `30-step3-panel.md`.
   - 3.2 adjudicate every panel `[<slug>-N]` Critical/Important candidate yourself (verify-before-critical), write one `VERDICT [<slug>-N] = agreed|disproved|conflict|unaddressed|deferred -> <TICKET>` line per candidate through `scripts/cr/write-verdicts.sh`. Reference: `31-step3-adjudicate.md`.
   - 3.5 reviewer stage: inline adjudication by default; Claude agents only when `CR_CLAUDE_AGENTS=1`; claude-only floor and cross-model floor rules. Reference: `32-step3-reviewers.md`.
   - 3.6 impacted suites: one verdict per suite, runs in BOTH lanes. Reference: `33-step3-impacted.md`.

4. **Cross-check.** Recompute the Critical/Important counts from the persisted `VERDICT` lines as the single source (excluded from the blocking count only when every collected verdict is disproved or deferred; everything else blocks) and run `scripts/cr/orphan-check.sh`. Reference: `40-step4-crosscheck.md`.

4.5. **Ledger append** (after verdict extraction, before the gate decision). Single writer: this session only. Availability rows are ALWAYS appended; the producers already wrote the finding rows, so record verdicts with `amend`; a deferred finding needs a ticket and a follow-up class; the handover bridge files findings and bugs. Reference: `45-step4.5-ledger.md`.

4.8. **Unresolved-thread gate** (HIMMEL-949) — blocking, skipped only when no PR exists yet. 4.9. **Round-4 cap disposition** (HIMMEL-2780) — only when step 3.0 printed round 4 or later. Reference: `48-step4.8-threads.md`.

5. **Clear.** Only if step 4.9 did not already clear the marker and `N == 0` AND step 4.8 reported `threads_rc = 0` AND step 3.6 reported `impacted_rc = 0`: clear the marker through the chokepoint `clear-cr-marker.sh '<branch>'`, never a bare `rm`. Then promote agreed findings to fixed. 6. Otherwise the marker stays held: report the blockers. 6.5. Append the critic-score footer. Reference: `50-step5-decision.md`.

7. **Auto-file deferred nits** (HIMMEL-30) — runs whenever the review surfaced low-severity findings worth tracking, independently of the clear decision. Reference: `70-step7-nits.md`.
