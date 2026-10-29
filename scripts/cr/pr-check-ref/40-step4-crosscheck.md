# /pr-check reference: step 4: cross-check and orphan check

4. Parse the aggregated output (from step 3) for the two count headings:
   - `Critical Issues (N found)`
   - `Important Issues (N found)`

   **Panel adjudication cross-check (HIMMEL-270, HIMMEL-415):** recompute the
   counts using `VERDICT` lines as the SINGLE verdict source (one parser, not
   two — retire the old `cross-model-adjudication:` prose parsing). The
   `[<slug>-N]` panel verdicts were rendered in **step
   3.2**. Collect them all here — this is the SAME exclusion rule
   `orphan-check.sh` applies, so the reconciliation and the gate decision can
   never disagree on what a surviving blocker is:

   For each `[<slug>-N]` Critical/Important forwarded in step 3:
   - Collect all `VERDICT [<id>-N] = <v>` lines emitted by any reviewer
     (the session in 3.2, plus agents on the opt-in path).
   - **Excluded from blocking count** ONLY when EVERY collected verdict for
     its ID is `disproved` OR `deferred`. (HIMMEL-1219 round 5 — ONE rule,
     stated here and nowhere else since HIMMEL-2704 deleted the phase-B awk
     that used to carry a second copy of it. The prior "at least one
     `disproved` AND zero `agreed`" wording let `{disproved, unaddressed}`
     slip through EXCLUDED, cancelling one reviewer's "cannot confirm or
     refute" with another's "no" — the opposite of fail-closed. `deferred`
     belongs in the exclusion set per HIMMEL-2375: it is a REAL finding
     tracked onto another ticket, not one to fix on this branch, so an
     all-deferred round must be able to clear. The awk always treated it that
     way; this line is now the only place that rule lives, so it has to say
     so.)
   - **Blocks** in every other state:
     - `agreed` (any) → blocks.
     - `conflict` (AGREE + DISPROVE both present) → blocks; surface verbatim
       to the operator.
     - `unaddressed` (no verdict line at all, or ANY verdict is
       `unaddressed`) → append to the Critical count, fail-closed.
   - **Suggestions never enter blocking counts, but they are NOT exempt from adjudication (HIMMEL-2339).** `scripts/cr/clear-review-marker.sh` gate 4b refuses with `reason=unadjudicated-findings` on ANY finding recorded with an empty verdict — `sev=sug` included, no carve-out. Every finding this run records, Suggestions included, needs a real disposition (fixed / deferred with a ticket / disproved) before the marker clears; only their COUNT is excluded from the Critical/Important blocking tally above.

   **Structural orphan-check (HIMMEL-1219 round 4; made programmatic round 5): every panel/codex candidate phase A adjudicated must appear in the aggregate.** This used to be prose only ("every forwarded candidate must have a VERDICT line") — instructional, and HIMMEL-195 says prose does not enforce. Round 4 added a fence, but it only PRINTED the phase-A candidate IDs and left the actual reconciliation to the session's eye — still instructional (emitting a set is not reconciling it). Round 5 makes the comparison itself programmatic. The obstacle is that the step-3.5 aggregate is markdown the session produces, not a file — so the fence had nothing to diff against. Solve that the same way phase A did: persist the aggregate VERDICT lines to a known path, then mechanically diff the two ID sets and count any phase-A candidate with no aggregate VERDICT line as a fail-closed orphan.

   First, persist YOUR aggregate VERDICT lines — every `VERDICT [<id>] = <v>` you emitted in step 3.2 (panel `[<slug>-N]`) — to the branch-scoped aggregate file, via the same `scripts/cr/write-verdicts.sh` helper phase A uses (same `<branch>` scope as phase A's prior-blocking file):
   ```bash
   # --branch takes step 0's printed `branch=` LITERAL (same rule
   # as phase A); branch-scoped because git-common-dir is SHARED across
   # worktrees (round 1b). write-verdicts.sh is the classifier-sanctioned
   # write path — it REPLACES the file contents every run, and
   # step 0 pre-truncates it, so a stale aggregate from a prior run can never
   # mask an orphan. Pass an EMPTY scratch file (zero verdict lines) when no
   # cross-model source produced any verdict — phase A wrote nothing either,
   # so there is nothing to reconcile (fail-open). Do NOT feed placeholder
   # `VERDICT [<id>] = <v>` lines; feed the REAL verdicts you emitted, or
   # nothing.
   #   Same spelling rule as phase A above.
   # `guard-pr-check-literal.sh` denies a pipe into this writer, and
   # denies every heredoc and
   # `< <file>` redirect shape outright — same cut as phase A above. The
   # sanctioned shape is `--from-file <path>`, same accepted shape as phase A.
   #   Example — write one VERDICT line per verdict you emitted in 3.2 to a
   #   scratch file (e.g. via the Write tool), then:
   #     bash "<himmel_dir>/scripts/cr/write-verdicts.sh" aggregate --branch '<branch>' --from-file <scratch-path>
   #   with <scratch-path> containing:
   #     VERDICT [codex-1] = disproved
   #     VERDICT [codex-3] = unaddressed
   bash "<himmel_dir>/scripts/cr/write-verdicts.sh" aggregate --branch '<branch>' --from-file <scratch-path>
   ```
   Then mechanically diff the two ID sets — every phase-A candidate ID (read from the prior-blocking file with the SAME VERDICT-line parse `orphan-check.sh` uses, so the two readers can never disagree about the ID set) that has NO matching aggregate VERDICT line is an orphan, treated fail-closed as `unaddressed`. The directions the reconciliation deliberately fails in: a missing / empty / unreadable prior-blocking file means there are no phase-A candidates to reconcile → 0 orphans (fail-open, implemented by `orphan-check.sh` itself: its `[ -s "$prior_file" ]` guard skips a missing or empty file, and a file `awk` cannot read leaves a non-numeric count that the script resets to 0); an aggregate file that is missing or empty while the prior-blocking file has candidates makes EVERY step-3.2 candidate an orphan → fail-closed, so a forgotten aggregate write reads as "every candidate unaddressed". **The comparison lives in `scripts/cr/orphan-check.sh` (HIMMEL-2226)** — the fence it replaces walked the orphan list with a `read` loop carrying an `IFS` prefix assignment, which Claude Code's worktree-isolation guard refuses, so it could never run inline in an isolated session. The script prints the identical `orphan-check: <N> unaddressed phase-A candidate(s)` line on stdout and the identical per-orphan diagnostic on stderr. **Pass step 0's captured branch explicitly — `--branch '<branch>'`, the same value the two `write-verdicts.sh` calls above are given (HIMMEL-1175).** The script's `--branch` is optional and falls back to the live `git branch --show-current`, and that fallback is exactly the hole: the two verdict files are WRITTEN under the captured branch and would then be READ under the live one. A mid-run same-SHA branch switch — the case the SHA pins cannot catch — points the orphan check at a different branch's scratch files, where it finds no phase-A candidates and reports **0 orphans fail-open**, silently dropping the fail-closed reconciliation this step exists to provide. Writer and reader must agree by construction, not because the checkout happened not to move; this is the same defect the round-3 captured-branch pin closed:
   ```bash
   bash "<himmel_dir>/scripts/cr/orphan-check.sh" --branch '<branch>'
   ```
   Add `orphan_count` to your Critical count (N) — each orphan is a phase-A candidate the carry-forward dropped, treated as `unaddressed` exactly like a verdict-less candidate in the bullets above; never silently drop it. The script emits the count (structural, not prose), so a forgotten carry-forward now fails closed instead of shipping a false-clean. Orphans = (step-3.2 IDs) − (aggregate IDs); the mandatory-adjudicator duty (the session in 3.2 by default, the `code-reviewer` agent under `CR_CLAUDE_AGENTS=1`) covers every one of them.
