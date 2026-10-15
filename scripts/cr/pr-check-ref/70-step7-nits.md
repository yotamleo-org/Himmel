# /pr-check reference: step 7: auto-file deferred nits

7. **Auto-file deferred nits (HIMMEL-30).** Runs whenever the review surfaces low-severity findings worth tracking, independently of steps 5/6. **Exception:** round-4+ findings dispositioned by step 4.9 already share the operator-supplied ticket; never auto-file another ticket for them, and never auto-file merely because step 4.9 reported a missing ticket.
   - Recognise findings tagged `NIT`, `LOW`, `SUGGESTION`, `IMPROVEMENT`, or `DEFERRED` (typically in a `## Suggestions (N found)` section per the `/pr-review-toolkit:review-pr` template) — and the critic panel's own shape, `## Suggestions (N found)` + `- [<slug>-N]: text [path:line]` (`scripts/cr/critic-panel.sh`, the DEFAULT path in step 3.0, not just the opt-in review-pr lane); `file-deferred-issues.sh` normalises the panel shape into the tagged shape before matching (HIMMEL-2068).
   - **Why MEDIUM is excluded:** MEDIUM findings warrant attention before merge. Auto-filing them would let them drift into a backlog. CRITICAL / HIGH / IMPORTANT block the PR via steps 5/6; NIT / LOW / SUGGESTION / IMPROVEMENT / DEFERRED get auto-filed by step 7. MEDIUM is the explicit gap — surface to the operator, don't file.
   - Skip this step if there is no open PR yet — there's no target to link the issue to. Re-run `/pr-check` after `gh pr create`.
   - **This fence has none of step 3's output in scope** — each `pr-check.md` fence runs independently, and step 3's findings arrived on a script's stdout, not in a variable any later fence can read (see the step-4.6/4.7 note on this same rule). Write EVERYTHING you (Claude) saw printed at step 3.0/2.5 (the critic panel's findings block) and, when it ran, the `/pr-review-toolkit:review-pr` markdown — into ONE temp file, so the script reads it via `--input <path>` (piping multi-line review markdown through `printf` would mangle backticks and special chars). Two fences: write the temp file and print its path, then hand that path to the filer.
     ```bash
     pr_num=""
     # --head takes step 0's printed `branch=` LITERAL, SINGLE-QUOTED.
     if pr_status=$(gh pr list --state open --head '<branch>' --json number --jq '.[0].number' 2>&1); then
         pr_num="$pr_status"   # empty when no PR yet
     else
         echo "WARN /pr-check: gh pr list failed: $pr_status" >&2
     fi

     if [ -n "$pr_num" ]; then
         review_tmpfile=$(mktemp -t cr-review.XXXXXX.md)
         echo "$review_tmpfile"
     fi
     ```
     Then, with the Write tool, write what you saw printed at step 3.0/2.5 into the path that fence printed — the critic panel's findings block, verbatim from `panel-first-pass.sh`'s (or `docs-audit-panel.sh`'s) stdout, plus the `/pr-review-toolkit:review-pr` markdown when that opt-in lane also ran this session. No heredoc: `guard-pr-check-literal.sh` denies one, and the filer reads the file by path.
     Then file, substituting the PR number and the temp-file path this printed
     as LITERALS (HIMMEL-2226 — a runtime value in a dash-flag operand is
     refused by the worktree-isolation guard, and no variable survives the
     fence boundary anyway):
     ```bash
     bash "<himmel_dir>/scripts/cr/file-deferred-issues.sh" --pr <pr-num> --input '<review-tmpfile>' --dry-run
     ```
     STOP HERE. Inspect the dry-run plan. If it looks right, rerun `file-deferred-issues.sh` without `--dry-run` (same `--pr` and `--input`) to actually file the issues, then delete the temp file. Re-invoking `/pr-check` only repeats the dry run.
   - The script is idempotent — dedupe is content-hash based, so re-running `/pr-check` on the same review output produces zero new issues. Editing a flagged file (which shifts line numbers) creates a new issue, which is correct: the finding moved.
   - **Fail-closed dedupe:** if the gh issue-list lookup errors (rate-limit, auth expired), the script skips that finding rather than silently filing a duplicate. Operator should re-run after fixing the gh state.
   - Auto-creates the `cr-deferred` label on first non-dry-run invocation.

Notes:
- The PreToolUse hook (`scripts/hooks/check-cr-marker-on-pr-create.sh`) blocks `gh pr create` whenever the marker exists, regardless of SHA match — stale or fresh, you have to clear it.
- Bypass for emergencies: `SKIP_CR=1 git push` skips the marker write at push time, and a missing marker means `gh pr create` is allowed. Document any bypass in the PR body.
- **Not a bypass — the Claude-only floor (HIMMEL-1224).** When external critics (codex/glm) are genuinely ABSENT, `/pr-check` still REVIEWS the diff itself (step 3.5 backstop) and clears the marker on that evidence — a recorded `avail --model claude --status ok` at this HEAD plus zero blocking findings. This is distinct from `SKIP_CR`: the floor is a review that *happened*; `SKIP_CR` is *no review at all*, so it is documented in the PR body while the floor needs no note. A lane that was CONFIGURED but failed/timed-out/rate-limited is NOT "absent" — it records `avail … unavailable` (never `ok`), and if it is the only evidence at this HEAD the chokepoint refuses (exit 14, fail-closed per HIMMEL-1126). Airtight-ness is covered by the Claude-only-floor cases in `scripts/cr/test-clear-cr-marker.sh`.
- COUPLING: this command parses the exact heading 'Critical Issues (N found)' / 'Important Issues (N found)' from TWO producers — `/pr-review-toolkit:review-pr` output (opt-in path) AND `scripts/cr/critic-panel.sh` (HIMMEL-415) — and recognises the deferred-class severities listed above. If either producer changes the format, update this command, the other producer, and `scripts/cr/file-deferred-issues.sh` in lockstep. Note: `file-deferred-issues.sh` keys on the `file:LINE: SEVERITY:` line shape; a normalisation pass (HIMMEL-2068) rewrites the panel's `## <section> (N found)` + `- [<slug>-N]: text [path:line]` shape into that canonical shape before matching — `Suggestions` maps to `SUGGESTION` (auto-filed), `Important Issues` / `Critical Issues` map to `IMPORTANT` / `CRITICAL` (deliberately outside the auto-filed severity set — those still block the PR via steps 5/6, never get filed).
