# /pr-check reference: step 3.5: reviewer stage

   **Step 3.5 — reviewer stage: inline adjudication by default; Claude agents opt-in (HIMMEL-926).**

   **Default (`CR_CLAUDE_AGENTS` unset/empty/0): dispatch NO `pr-review-toolkit:*` agents.** The cross-model sources (the panel) carry finding generation; YOU — the orchestrating session — are the mandatory adjudicator. **Claude-only backstop (codex CR round on HIMMEL-926):** when EVERY cross-model source produced nothing — `CR_PROFILE=none`, or all passes skipped/failed — the gate must still be reviewed: perform the full review of the diff YOURSELF (the pre-existing claude-only contract) before rendering the step-4 counts. The gate never clears reviewless.

   **Claude-only floor & availability escape hatch (HIMMEL-1224).** This backstop IS the availability escape hatch, and it is airtight for **Claude-only adopters** (no codex/glm/CodeRabbit configured): when every external lane is genuinely ABSENT/unconfigured, your own diff review is the floor, recorded in step 4.5 as `avail --model claude --status ok` so `clear-cr-marker.sh` gate 3 certifies a review that DID happen and the marker clears WITHOUT a bypass. Two invariants keep the hatch honest — it opens for ABSENCE, never for a failed review:
   - **Fail-OPEN on ABSENCE only.** A genuinely absent/unconfigured lane writes NO ledger row (step 3.0 prints a skip note) and never blocks. The Claude floor covers the HEAD, so one `avail --model claude --status ok` is sufficient evidence.
   - **Fail-CLOSED on ATTEMPTED-but-failed (preserve HIMMEL-1126).** A lane that RAN but errored/timed-out/rate-limited is NOT absent and NOT clean: it records `avail … unavailable` (never `ok`), which the chokepoint counts as a MISSING signal. If such a failed lane is the SOLE evidence at this HEAD (no `… ok` row at all), the gate stays CLOSED (`clear-cr-marker.sh` exit 14) — it does not fall through to a reviewless clear. A blocker your own floor review finds is recorded as a `finding` and blocks the same way (exit 15).
   - **Opt-in cross-model floor (`CR_REQUIRE_CROSS_MODEL=1`, HIMMEL-1237).** The Claude-alone floor above is the right *default* (adopter-portable). A setup that wants cross-model coverage *required* — the Claude self-review is deliberately NOT sufficient — sets `CR_REQUIRE_CROSS_MODEL=1` in `.env`. `clear-cr-marker.sh` gate 3b then additionally requires ≥1 **non-Claude** `avail … ok` at the SHA, so a claude-only floor (whether the external lanes were absent OR attempted-but-failed) keeps the marker CLOSED (exit 14) until a codex/glm lane actually reviews — unless `CR_FLOOR_FALLBACK=claude-only` and a provenance-valid claude-floor row is present (HIMMEL-3107). **A clear through that escape is not a gate-3b pass (HIMMEL-3108):** a `claude-floor` row never counts toward the non-Claude responder tally, and under this opt-in the clearing record says which basis certified the SHA — `CLEARED … via=cross-model non_claude=<n>` vs `CLEARED … via=claude-floor same_model=1 context_free=1 exhausted=<lanes>`, with the CR-clean line naming the same-model floor in words. So the two are distinguishable in `<git-common-dir>/clear-cr-marker.log` per clear, not only in the mid-run `FLOOR-FALLBACK` note. Enforced structurally in the gate, not by this prose (HIMMEL-195). Default unset ⇒ unchanged Claude-alone floor, and an unchanged (untagged) `CLEARED` line.
   - **Context-free claude floor under `CR_REQUIRE_CROSS_MODEL=1` (`CR_FLOOR_FALLBACK=claude-only`, HIMMEL-2128 → HIMMEL-3107).** When every non-Claude lane is EXHAUSTED (quota / rate-limit, a CodeRabbit `vacuous` or rate-limited pass, or an empty panel in `critics.json`), the floor is NOT your own review and NOT a `--model claude` row you record: record the CodeRabbit state from `check-ci.sh` first (`ledger-append.sh avail --model coderabbit --status unavailable --reason rate-limit` or `--reason vacuous`), then run `bash "<himmel_dir>/scripts/cr/claude-floor-review.sh" --branch '<branch>' --base <base>`. It runs the `scripts/cr/floor-reviewer.md` code-reviewer definition as a fresh isolated headless session whose ONLY input is the diff + a repo snapshot, writes the provenance artifact the gate checks, and records the `claude-floor` avail row + its `[claude-floor-N]` findings — adjudicate those like panel candidates. Exit 3 = the floor is not eligible (a lane is auth/404/config-faulted, or not every lane is exhausted): do not force it. It is same-model coverage only — say so in the report: the shared-model blind spot remains, and the gate will say so too (HIMMEL-3108: its CR-clean line reads `… ON THE SAME-MODEL FLOOR …`, which you report verbatim rather than as a plain "CR clean"). This is the one sanctioned headless call in `/pr-check` (bank-preflighted through `scripts/lib/claude-headless.sh`); the line below forbids the others.

   This is the OPPOSITE of `SKIP_CR=1` (a documented no-review emergency bypass): under the floor a review genuinely happened (at least Claude-only), so the gate clears on that evidence with no bypass and no marker-suppression (unless `CR_REQUIRE_CROSS_MODEL` is set — gate 3b then refuses a Claude-only floor until a non-Claude critic reviews, per the opt-in bullet above — unless `CR_FLOOR_FALLBACK=claude-only` and a provenance-valid claude-floor row is present, HIMMEL-3107). You already adjudicated the panel `[<slug>-N]` candidates in **step 3.2** — carry those verdict lines forward into the aggregate below, then aggregate into the structured output format at the end of this step. There are no CodeRabbit findings to adjudicate here: the App's findings arrive as review THREADS on the PR and are handled in step 7 (HIMMEL-2704). This composition removes the ~5-agent Claude fan-out per run; instant revert = `CR_CLAUDE_AGENTS=1` in `.env`.

   Resolve the flag deterministically (same bridge as `CR_PROFILE`; a live-env value wins) — through `scripts/cr/pr-check-env.sh`, for the same reason step 2.5 does (HIMMEL-2226: the fence sourced `load-dotenv.sh` through a runtime-determined path, which the worktree-isolation guard refuses). An unset flag prints the runbook's own placeholder, `<unset: inline adjudication, no Claude reviewer agents>`:
   ```bash
   bash "<himmel_dir>/scripts/cr/pr-check-env.sh" CR_CLAUDE_AGENTS
   ```
   **Himmel-lane spelling (HIMMEL-3375):** the same rule as step 2.5 — run this INSTEAD of the anchored line, and ONLY when step 0 itself ran by the himmel-lane spelling (both of its checks passed on this diff and the branch has not changed since); otherwise use the anchored line:
   ```bash
   bash scripts/cr/pr-check-env.sh CR_CLAUDE_AGENTS
   ```

   **Opt-in blast-radius pass (`CR_CLAUDE_AGENTS=blast-radius`, HIMMEL-5851 POC).** That exact value runs ONE extra pass and dispatches NO agent matrix (the matrix below needs `1`). After adjudicating the panel, read `marketplace/plugins/pstack/skills/blast-radius/SKILL.md` from `<himmel_dir>` (the plugin may be disabled in your profile; the file is read, not invoked) and apply it to the diff YOURSELF: name the one or two facts the change's safety depends on and prove them by running code. A proven breakage becomes a `[claude-N]` finding adjudicated like any panel candidate; an unproven worry is reported as a note, never counted. Report the tokens and wall time the pass took beside the step-4 counts. Unset, empty or `0` is unchanged.

   **Default-on for guard and gate diffs (HIMMEL-5855).** When the diff changes a non-test file under `scripts/hooks/` or a gate script (`scripts/ci/check-*`, `scripts/cr/clear-cr-marker.sh`, `scripts/testing/check-*`, `scripts/handover/console-kit/ready-check.sh`), run the same pass even with the flag unset, empty or `0`. Other diffs are unchanged. Opt out with `CR_CLAUDE_AGENTS=blast-radius-off` (resolved above like any value), and say in the report that the pass was skipped by the switch. Basis, over 6 origin/fix pairs of merged guard and gate PRs: the pass proved a real defect the shipped suites missed on 6 of 6, caught the later-fixed defect on 2 (the panel on 2, a different 2), at about 71k tokens and 90 s a run; table in the state repo, `specs/research/HIMMEL-5855-blast-radius-vs-panel.md`.

   **Opt-in (`CR_CLAUDE_AGENTS=1`): ALSO dispatch the per-agent matrix below** (the pre-HIMMEL-926 default). All dispatches use the upstream `pr-review-toolkit:*` agent types — himmel's own `scripts/cr/floor-reviewer.md` is not an Agent-tool type (the floor script loads it as a prompt file). The HIMMEL-178 verify-before-critical rule is carried by prepending the directive below to EVERY agent prompt, code-reviewer included.

   Do NOT spawn `claude --print` as a subprocess (HIMMEL-128 billing — interactive only). Sole exception: `scripts/cr/claude-floor-review.sh` above (HIMMEL-3107).

   **Dispatch matrix (opt-in path only)** — always dispatch the first row; add others when the diff matches:

   | Condition | Agent | Namespace rationale |
   |---|---|---|
   | Always | `code-reviewer` | Upstream — `pr-review-toolkit:code-reviewer`, HIMMEL-178 directive prepended (fork agent type not registered) |
   | Test files changed (`*.test.*`, `**/test_*`, `**/tests/**`, `*.spec.*`, etc.) | `pr-test-analyzer` | Upstream — `pr-review-toolkit:pr-test-analyzer` |
   | Comments / docs changed (`**/*.md`, comment-only diffs in code) | `comment-analyzer` | Upstream — `pr-review-toolkit:comment-analyzer` |
   | Error-handling code changed (try/catch, error-return, panic, etc.) | `silent-failure-hunter` | Upstream — `pr-review-toolkit:silent-failure-hunter` |
   | Types added / modified (`*.ts`, `*.d.ts`, type-defs in Python/Rust/etc.) | `type-design-analyzer` | Upstream — `pr-review-toolkit:type-design-analyzer` |
   | Doc-freshness `advise` findings present AND `HIMMEL_DOC_FRESHNESS` `advise` leg on | `code-reviewer` with the **docs-audit charter** (step 2.5), SCOPED to only the mapped docs whose sources changed in range | Upstream — `pr-review-toolkit:code-reviewer`. Advisory: its findings are surfaced to the operator, NEVER added to the blocking Critical/Important counts of steps 4–6. |

   **Signal-3 (doc-freshness LLM advisory) is advisory-only.** When dispatched, scope its prompt to the specific mapped docs surfaced by step 2.7 (e.g. "audit `docs/internals/enforcement.md` for factual drift vs the changed `scripts/hooks/` code in this range") using the docs-audit charter text from step 2.5. Its output is reported to the operator but is excluded from the step-4 `Critical Issues (N found)` / `Important Issues (N found)` counts — doc-freshness never blocks the PR (the only blocker is `doc-guard` at pre-push). This row is the deferrable piece per the spec; the deterministic step 2.7 print ships regardless.

   `code-simplifier` (the 6th pr-review-toolkit agent) is intentionally NOT in this auto-dispatch matrix — matches the upstream `/pr-review-toolkit:review-pr` behavior, where simplification is invoked explicitly via `simplify` argument rather than auto-routed. If the operator wants simplification, they call `pr-review-toolkit:code-simplifier` directly. The verify-before-critical rule does not apply to it (simplification proposes refactors, not Critical findings).

   **On the opt-in path, prepend the following directive to each of the 5 Agent tool prompts** (`scripts/cr/floor-reviewer.md` embeds the rule in its definition, but the upstream agents carry no such rule). On the default path the same rule binds YOU when adjudicating:

   > **Hard rule (HIMMEL-178 verify-before-critical):** before reporting any Critical finding, grep the actual diff (or read the file at the cited line) for the cited line / token / pattern. If the cited content does NOT appear verbatim, downgrade to Minor or drop entirely. Note any downgrade with reason `verify-before-critical: cited content not in diff`. Hallucinated Critical findings derail overnight-mode fix batches (~6 reviewers/PR × 50-60 dispatches/session) and burn tokens. This rule applies ONLY to Critical (91-100) findings — Important (80-89) and below tolerate inference.

   The directive below governs ALL adjudication in step 3 — the panel/codex
   adjudication you already did in **step 3.2**. (There is no CodeRabbit
   adjudication here: CodeRabbit is the GitHub App and its findings arrive as
   review THREADS on the PR, adjudicated and resolved in step 7 — HIMMEL-2704.)
   On the default path YOU follow it directly; on the opt-in path ALSO prepend
   it plus the Critical/Important findings (`[<slug>-N]` panel)
   to each agent prompt — the agents re-adjudicate the full diff and may
   add verdicts that step 4 reconciles with yours:

   > **Cross-model adjudication (HIMMEL-270, HIMMEL-415):** the critic panel
   > findings below are blocking candidates, each tagged `[<slug>-N]`. For
   > each finding relevant to your role: AGREE (confirm with cited evidence
   > from the diff/file) or DISPROVE (grep the diff, read the file at the
   > cited line, or run a test proving it wrong). Emit exactly ONE verdict
   > line per adjudicated finding, using this exact format:
   > `VERDICT [<slug>-N] = agreed|disproved|conflict|unaddressed`
   > — `agreed` = confirmed with evidence; `disproved` = refuted with
   > evidence; `conflict` = evidence-backed AGREE AND DISPROVE (surface
   > verbatim to operator); `unaddressed` = relevant to your role but
   > cannot confirm or refute. Do not silently ignore a finding relevant
   > to your role.
   > A REAL finding that is genuinely out of scope for this branch takes
   > the 5th verdict instead — `VERDICT [<slug>-N] = deferred -> <TICKET>`
   > (HIMMEL-2375). The ticket is MANDATORY: a bare `deferred` is rejected
   > by `write-verdicts.sh`. Never reach for `unaddressed` on one of these
   > — `unaddressed` BLOCKS, and `deferred` is the non-blocking verdict
   > step 4's exclusion rule exists to honour.

   On the opt-in path the `code-reviewer` dispatch's prompt additionally gets:
   **"You are the mandatory adjudicator: render a `VERDICT [<slug>-N] = …`
   line on EVERY `[<slug>-N]` Critical/Important finding from the panel,
   whether or not it looks relevant to your role — read the cited file if
   it is outside the diff context you were given."** On the default path
   that mandatory-adjudicator duty is YOURS. (Closes the
   orphaned-finding hole — every cross-model finding gets at least one verdict.)

   Aggregate the per-source results (your inline verdicts; plus the per-agent results on the opt-in path) into the structured output format below (for downstream parsing by step 4):

   ```markdown
   # PR Review Summary

   ## Critical Issues (N found)
   - [agent-name]: Issue description [file:line]

   ## Important Issues (N found)
   - [agent-name]: Issue description [file:line]

   ## Suggestions (N found)
   - [agent-name]: Suggestion [file:line]

   ## Strengths
   - What's well-done in this PR
   ```

   The `(N found)` parenthetical on Critical / Important headings is the contract surface that step 4 parses. Keep it stable.
