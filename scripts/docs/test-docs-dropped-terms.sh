#!/usr/bin/env bash
# selector: tree-scan
# test-docs-dropped-terms.sh — user docs name only the models, platforms and
# lanes true today.
#
# Scope: every user page (docs/ outside docs/internals/, site/, README.md) and
# each docs/internals/ page a user page names. Release notes and the rename
# table are history and exempt. A page fails when a line names a dropped
# platform (Windows, WSL, PowerShell, Git Bash, MSYS, schtasks), the dropped
# GLM or kimi lane, or a model id that is no longer current.
#
#   PENDING  pages held for a later sweep; the list only shrinks. A pending
#            page that is now clean fails too, so its entry is removed in the
#            PR that cleans it.
#   ALLOW    file<TAB>line: the whole of one line a page keeps on purpose (a
#            dated measurement, a guard that still parses the spelling, a
#            sentence saying the platform or lane is dropped). An entry no
#            line carries any more fails, so an edited kept line is reviewed
#            again.
#
# Lowercase wsl, powershell and git-bash are matched; lowercase "windows" is
# not, since pages use it for time and terminal windows.
#
# Platform guard: bash 3.2+, git, grep, awk.
# Usage: bash scripts/docs/test-docs-dropped-terms.sh
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# $LOCALAPPDATA in the pattern is literal page text.
# shellcheck disable=SC2016
PATTERN='Windows|\b(WSL|wsl)2?\b|PowerShell|powershell|\bpwsh\b|\.ps1\b|[Gg]it[- ]?[Bb]ash|\b(MSYS|msys)|%LOCALAPPDATA%|\$LOCALAPPDATA|schtasks|winget|cygwin|\b(GLM|glm|Z\.ai|zai-glm|kimi|Kimi|moonshot)\b|gpt-5\.[0-9]|gpt-6-(sol|astra)\b|GPT-5\.[0-9]|GPT-6 (Sol|Astra)|claude-(opus|sonnet|haiku)-4|\b(Haiku|Sonnet|Opus)[- ]4\.[0-9]|\b(Fable|Opus|Sonnet)[- ]5[.-]?([^.0-9-]|$)|claude-(opus|sonnet|fable)-5[.-]?([^.0-9-]|$)|ox-alpha'

PENDING='
'

# The backticks and dollars below are literal page text.
# shellcheck disable=SC2016
ALLOW=$(cat <<'EOF'
README.md	  run. Windows is not supported. Details in the
README.md	himmel is developed on Linux and macOS. **Windows (Git Bash, WSL) is not
README.md	supported.** Windows support was dropped; nothing about Windows is claimed as
README.md	| **Dropped** | Windows (Git Bash), WSL | Support was dropped: no CI gate, no guarantee. |
docs/architecture.md	            H2["marketplace/plugins/himmel-ops/<br/>hooks/hooks.json — 15 PreToolUse guards<br/>block-docker-privesc · block-infra-destroy · block-merged-pr-commit<br/>block-unresolved-cr-merge · block-glm-external-writes<br/>block-graphify-egress · block-rogue-codex-exec<br/>block-lesson-enforcement-writes · block-agent-native-egress<br/>guard-implementor-dispatch · guard-chief-dispatch<br/>guard-subagent-model · guard-chief-foreground · guard-judge-writes · guard-rm-writes"]
docs/commands-catalog.md	| /handover-arm-resume | Arm the OS scheduler to relaunch claude at a given time with a given handover. Dedup-guarded. | Arm the OS scheduler to relaunch claude at the given time with the given handover. Dedup-guarded. Direct schtasks/at invoke. |
docs/daily-loop.md	| Touches `*.sh`, `*.bash`, PowerShell files (`*.ps1`, `*.psm1`, `*.psd1`), `scripts/**`, `**/bin/*` | `Platforms tested: <os>` |
docs/daily-loop.md	arch mac darwin wsl posix gitbash git-bash powershell pwsh`.
docs/evals/README.md	| `codex:gpt-5.6-sol` | 2026-09-04 to 2026-09-05 | **84.1%** | 76.2 to 89.7 | 74.2 to 91.7 | as of 2026-10-27, n = 113 ruled findings over 27 PRs |
docs/evals/README.md	| `codex:gpt-6-astra` | 2026-09-05 to 2026-09-23 | **89.3%** | 87.4 to 90.9 | 86.1 to 92.0 | as of 2026-10-27, n = 1,231 ruled findings over 362 PRs |
docs/evals/README.md	| `codex:gpt-6-sol` | 2026-09-23 to 2026-09-29 | **70.7%** | 67.0 to 74.1 | 64.8 to 76.2 | as of 2026-10-27, n = 627 ruled findings over 169 PRs |
docs/evals/review-panel.md	model re-pin of the same slug show up as a new critic (`codex:gpt-6-sol`,
docs/evals/review-panel.md	| `codex:gpt-5.6-sol` | 231 | 27 | 95 | 18 | 35 | 83 | 84.1% | 74.2–91.7 |
docs/evals/review-panel.md	| `codex:gpt-6-astra` | 2,435 | 362 | 1,099 | 132 | 697 | 507 | 89.3% | 86.1–92.0 |
docs/evals/review-panel.md	| `codex:gpt-6-sol` | 872 | 169 | 443 | 184 | 234 | 11 | 70.7% | 64.8–76.2 |
docs/evals/review-panel.md	window covers three re-pins of the `codex` slug: gpt-5.6-sol → gpt-6-astra,
docs/evals/review-panel.md	→ gpt-6-sol on 2026-09-23 (#1155), → gpt-6.1-sol on
docs/evals/review-panel.md	| | gpt-6-sol (09-23 → 09-29) | gpt-6.1-sol (09-29 → 10-06) |
docs/evals/review-panel.md	by 12 points, with intervals that do not overlap. gpt-6-sol also called one
docs/getting-started.md	install profile lands, the Windows caveat, and the adaptation checklist for a
docs/glossary.md	| **`HIMMEL_WORKER`** | The dispatched-lane security marker (hook integrity, the GLM write fence, the claudex spawner). A worker does not carry it, so a worker name must never start with `HIMMEL_WORKER_` unless `SESSION_` follows. |
docs/glossary.md	| Lane-worker files (`stop-worker.sh`, `await-glm-worker.sh`, `reconcile-workers.sh`) | Other sense of worker. |
docs/glossary.md	| **worker** | A worker: one ticket, one worktree, one PR (formerly worker session, leg). | A lane worker (a process on a dispatch backend: `scripts/lanes/stop-worker.sh`, `await-glm-worker.sh`), a dispatched subagent worker (`internals/worker-spawn-matrix.md`), a Codex lane worker, `reconcile-workers.sh` and `max_workers`. Also `HIMMEL_WORKER`, the dispatched-lane marker, which a worker does not carry. | A bare "worker" is the fleet sense; every other sense is qualified (lane, subagent, Codex lane). Worker env names are `HIMMEL_WORKER_SESSION_*`, never `HIMMEL_WORKER_*`. |
docs/glossary.md	| Secrets never read | `block-read-secrets` (Bash, PowerShell, Read, Grep) | — | `block-read-secrets` (Bash, PowerShell, Read, Grep) | — | — | — |
docs/glossary.md	| No rogue scheduler job launches `claude` | `block-rogue-claude-schedule` (Bash, PowerShell) | — | `block-rogue-claude-schedule` (Bash, PowerShell) | — | — | — |
docs/glossary.md	| No `git stash` | `block-git-stash` (Bash, PowerShell) | — | `block-git-stash` (Bash, PowerShell) | — | — | — |
docs/glossary.md	| Live settings not writable | `block-edit-live-settings` (Bash, PowerShell, Edit) | — | `block-edit-live-settings` (Bash, PowerShell; not `apply_patch`, HIMMEL-5430 open) | — | — | — |
docs/glossary.md	| Egress stays inside policy | `mcp-policy`, `block-backend-tier` | `block-graphify-egress`, `block-agent-native-egress`, `block-glm-external-writes` | `mcp-policy`, `block-backend-tier`, `block-terminal-write-fence` | — | — | — |
docs/guide/installer-journey.html	<span class="d">  [ ] 2. add the vault's absolute path as a line in ~/.config/claude-glm/phi-roots</span>
docs/guide/installer-journey.html	<span class="d">  [ ] 3. add the relevant path(s)/pattern(s) to ~/.config/claude-glm/egress-denylist</span>
docs/guide/installer-journey.html	      term: function () { return [['d', '── PHI checklist — READ ONLY, himmelctl creates none of this ──────────────'], ['d', '  [ ] 1. drop a `.salus` marker file at the vault root (or an ancestor dir)'], ['d', '  [ ] 2. add the vault\'s absolute path as a line in ~/.config/claude-glm/phi-roots'], ['d', '  [ ] 3. add the relevant path(s)/pattern(s) to ~/.config/claude-glm/egress-denylist'], ['q', '? does this vault handle Protected Health Information (PHI)? [yes|no] (default: no)'], ['in', '> no']]; },
docs/handover/afk-mode.md	3. **Impl:** `superpowers:subagent-driven-development`. Sequential per task: implementer subagent → spec-compliance reviewer → code-quality reviewer → fix-on-finding → next task. **Verifier cadence (Fable-5 scaffolding):** every 3 completed tasks, dispatch one fresh-context verifier subagent that re-checks the accumulated branch diff against the Phase-1 plan. Fresh-context verification beats self-critique, and the per-task reviewers see one task at a time; this is the layer that catches cross-task drift before Phase 4. **Stop-check:** before EACH subagent dispatch in this loop, run `bash scripts/afk/stop-marker.sh check` (silent; rc=0 = stop marker present, rc=1 = clear). When rc=0, finish the in-flight subagent if one is running, then halt the loop gracefully (write a `next-session-N.md` snapshot at the partial-completion point, file followup tickets for remaining tasks, and exit Phase 3). Operator-triggered via `/stop` (soft) or `/stop --hard` (also `TaskStop`s in-flight). `/stop --reset` clears the marker.
docs/handover/afk-mode.md	[Fable-5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5)
docs/handover/afk-mode.md	counters context-budget anxiety (Fable 5 occasionally wraps up early when
docs/handover/afk-mode.md	written-deliverable padding (Opus 5 pads documents by default, and this
docs/handover/afk-mode.md	notification** (observed on Opus 4.8, community-measured, @PawelHuryn).
docs/handover/afk-mode.md	header contract before invoking it. A wrong repo slug, an MSYS-mangled
docs/handover/afk-mode.md	grant), and Windows sessions are not covered.
docs/handover/afk-mode.md	- **Effort tiering (Fable-5):** on Fable 5, `low` effort ≈ `xhigh` on prior models, which strengthens the raise-effort-before-tier rule of the Subagent delegation & escalation policy (root `CLAUDE.md`). For mechanical subagent work, raise effort before raising the model tier; reach for Opus-class only with a concrete reason. Default effort `high`; `max` is a re-verification tax (2-3× time for the same answer, community-measured); reserve it for capability-critical single calls, not pipeline phases.
docs/handover/chief-sections/waiter.md	    a closing `# pool=<rows>/<slack>` line, `,LOW` when the pool fills fewer slots than the slack, and `POOL-EMPTY` when it has nothing, followed by the next tier (tier-4 To Do rows in rank order) as `NEXT-TIER` rows: then unblock collisions, draft specs for the next priority items, or fill from the NEXT-TIER rows when the operator has ruled so); dispatch it with `gen-briefs.py`; both refuse Windows/WSL work per `chief-kit/platform-dropped.re` unless the ticket is labelled `windows-removal` / the worker sets `platform_removal` and its title says remove/drop/delete/retire/sweep/clean), or
docs/handover/running-a-chief.md	`[1m]` is appended to the model only for the 4.6 family (`claude-opus-4-6`,
docs/handover/running-a-chief.md	`claude-sonnet-4-6`); Opus 4.7+, Sonnet 5+, Haiku 5.5 and Fable run 1M natively
docs/handover/running-a-chief.md	and non-Anthropic ids (`gpt-*`, `glm-*`, anything with a `/`) never take it
docs/handover/running-a-chief.md	  `/Windows/1 newSession`), titled with the worker's session name.
docs/operator-conventions.md	- **Linux + macOS are Supported (Linux CI-gated per-PR, macOS on its own twice-weekly `os:macos` cadence workflow); Windows is not supported.**
docs/operator-conventions.md	  No `.ps1` twin is needed or wanted: Windows is dropped and the old twins are removed.
docs/operator-conventions.md	- **Chain ASAP: never park an arm hours out, never pause idle at a decision the model could make.** At a natural completion / context-saturation point, arm + chain the next session (ticket-named, cold-start-complete handover) instead of stopping: idle quota that isn't spent before its window resets simply evaporates. "The handover is written" is not the finish line: exhaust the planned queue in-session while budget remains, then re-arm for the SOONEST slot after true wrap (minutes out, not hours). If an arm exists and work continues past its slot, move/replace it BEFORE the fire time (double-fire risk). Only truly pause when the next step needs an operator decision that can't be pre-teed. Where the fleet spans multiple surfaces (machines, WSL distros), the same discipline applies **per-surface**: after wrapping on any box, verify an armed continuation exists on every configured surface, because an idle surface is wasted pipeline capacity.
docs/operator-conventions.md	  prompting guide flags that Fable 5.1 can write denser than Fable 5
docs/operator-conventions.md	qmd bun-install Windows hotfix (already a structural fix in
docs/why-himmel.md	  run, with each change attesting the platform it was tested on. Windows is
docs/internals/claude-md-detail.md	work routes to Claude tiers + Codex lanes only (never GLM)** — a routing
docs/internals/egress-matrix.md	ad-hoc egress decisions (ollama-only → DeepSeek override → GLM-Clippings
docs/internals/egress-matrix.md	  de-listed (bad results). The GLM enrichment cell that replaced it
docs/internals/egress-matrix.md	  (`luna-personal × zai-glm × enrichment`) was itself **REVERSED
docs/internals/egress-matrix.md	  2026-08-29: now `deny`** — see the GLM de-listing below. No
docs/internals/egress-matrix.md	- **`luna-personal × zai-glm × extraction`** was **ratified 2026-07-17**
docs/internals/egress-matrix.md	  now `deny`** — the GLM lane was dropped (below). The
docs/internals/egress-matrix.md	  second, additional vendor (Z.ai) that could not receive them before. What it
docs/internals/egress-matrix.md	  A/B on an identical corpus put glm-5.2 ahead of the incumbent on every axis
docs/internals/egress-matrix.md	  vault was paying for the weaker backend purely because the matrix had no GLM
docs/internals/egress-matrix.md	  - `luna-personal × zai-glm × inference` stayed **deny** — extraction only,
docs/internals/egress-matrix.md	    and it still denies by *default* (the GLM de-listing added explicit deny rows only
docs/internals/egress-matrix.md	    (the claude-only adopter story). GLM is a per-run opt-in for an
docs/internals/egress-matrix.md	  The sanctioned provider set for vault/handover egress is **GLM (zai-glm) +
docs/internals/egress-matrix.md	- **Provider policy — GLM (zai-glm) de-listed (2026-08-29).**
docs/internals/egress-matrix.md	  The GLM lane was resolved as **DROP** (Coding Plan auto-renew
docs/internals/egress-matrix.md	  `deny` on the same pattern as the DeepSeek/Alibaba de-listing: `luna-personal × zai-glm ×
docs/internals/egress-matrix.md	  extraction`, `luna-personal × zai-glm × enrichment`,
docs/internals/egress-matrix.md	  `luna-clippings × zai-glm × extraction` (the narrow G2.3
docs/internals/egress-matrix.md	  ladder exception) and `handover-state × zai-glm × inference` (the
docs/internals/egress-matrix.md	  brief-scoped worker cell). *(At the time, Kimi (`moonshot`)
docs/internals/egress-matrix.md	  was adopted as the replacement CN extraction lane — see the kimi/moonshot
docs/internals/egress-matrix.md	  was: `luna-personal` and `luna-clippings` **extraction** — `moonshot`
docs/internals/egress-matrix.md	  and `openrouter` plus `anthropic`/`local-ollama`. Kimi held
docs/internals/egress-matrix.md	  This was a *record-integrity* fix, not an incident: nothing routed to GLM —
docs/internals/egress-matrix.md	  no GLM lane appears in `scripts/lanes/resolve.mjs` — but a live `allow+log`
docs/internals/egress-matrix.md	  and loses the history), **not `hard`**, and `himmel-code × zai-glm` stays
docs/internals/egress-matrix.md	  `refresh-graph-map.sh`'s `--backend glm` remap still legitimately serves it.
docs/internals/egress-matrix.md	  Consumer sweep: `graphify-fence.sh` loses the `luna-clippings × zai-glm`
docs/internals/egress-matrix.md	  keeps its `glm` provider entry but its egress gate now refuses it, exactly
docs/internals/egress-matrix.md	- **Provider policy — kimi/moonshot retired (operator ruling
docs/internals/egress-matrix.md	  2026-08-24/2026-09-15: there is no kimi backend).** Unlike the
docs/internals/egress-matrix.md	  DeepSeek/Alibaba/GLM de-listings above, the `moonshot` provider entry and
docs/internals/egress-matrix.md	  its two `allow+log` rows (`luna-personal × moonshot × extraction`,
docs/internals/egress-matrix.md	  `luna-clippings × moonshot × extraction`) are **DELETED outright, not
docs/internals/egress-matrix.md	  just its egress authorization, and kimi was never de-listed for bad results
docs/internals/egress-matrix.md	  the way DeepSeek/Alibaba/GLM were, so there is no "why a vendor was ever
docs/internals/egress-matrix.md	  permitted" history worth preserving as a live row. `moonshot` now falls
docs/internals/egress-matrix.md	  `_map_kimi_endpoint` and its `kimi -> moonshot` mapping entirely;
docs/internals/egress-matrix.md	  `--backend kimi` now hits the same undeclared-literal-provider fail-closed
docs/internals/egress-matrix.md	`~/.config/claude-glm/{phi-roots,egress-denylist}` list files
docs/internals/egress-matrix.md	(`scripts/telegram/phi-egress-guard.ts` — renamed from `glm-guard.ts` — and `scripts/hermes/assets/parity_guard.py`),
docs/internals/egress-matrix.md	MSYS-form paths (`/c/…` → `c:/…`) for its **lexical** root comparisons (the
docs/internals/egress-matrix.md	filesystem marker walks use the original path form) so Windows Git-Bash
docs/internals/egress-matrix.md	candidates and the Bash tool's always-MSYS `$PWD` match the drive-lettered
docs/internals/egress-matrix.md	script makes itself (cron/schtasks). Non-hook callers — currently
docs/internals/egress-matrix.md	| `phi-egress-guard.ts` (renamed from `glm-guard.ts`) | same `salus`/denylist row |
docs/internals/egress-matrix.md	  an unreadable claude-glm config dir, a base URL carrying credentials, and a
docs/internals/egress-matrix.md	  Windows launchers are out of scope (Windows is dropped).
docs/internals/enforcement.md	   It appears to work on Windows only because CRLF normalization leaves
docs/internals/enforcement.md	leftover Codex copy, which was costing a `pwsh`→`cmd`→`bash` spawn on every
docs/internals/enforcement.md	`block-glm-external-writes.sh` (HIMMEL-654),
docs/internals/enforcement.md	OPEN (see its own section below); `block-glm-external-writes.sh` fails CLOSED on a detected
docs/internals/enforcement.md	GLM lane (a missing `jq` blocks rather than allows — see its own section
docs/internals/enforcement.md	| **synchronous external call** | `60` | the hook itself blocks on `gh`, `schtasks`, or ≥2 `py_armor` calls (each capped at `PY_ARMOR_TIMEOUT`, default 10 s) |
docs/internals/enforcement.md	`auto-arm-on-subagent-cap.sh` (`py_armor` + `arm-resume.sh` → `schtasks`),
docs/internals/enforcement.md	**What drops is the node launches, not the Git Bash ones** — the members stay one
docs/internals/enforcement.md	shell each by design (no extra wrapper shell), so the per-Git-Bash pool cost is
docs/internals/enforcement.md	- **Matchers are disjoint** — `Bash`, `PowerShell`, `Read|Grep`, the Edit/Write
docs/internals/enforcement.md	(measured 2026-08-22: the 10-member Bash chain 2.1 s p95, the 5-member PowerShell
docs/internals/enforcement.md	shell is **dominated by Windows process-start and therefore by whatever else the
docs/internals/enforcement.md	same resolver the wired hooks use: on Windows a bare `bash` can be the WSL
docs/internals/enforcement.md	launcher or a 0-byte WindowsApps alias, which would time a different shell than
docs/internals/enforcement.md	this inventory over Windows PATH roulette (the WSL stub, the 0-byte Store
docs/internals/enforcement.md	  spelling falls through, as does a drive-letter payload `cwd`. Windows Git
docs/internals/enforcement.md	- **Windows Git Bash drive-letter paths (HIMMEL-3192).** The three
docs/internals/enforcement.md	  Linux-only tested — the cases simulate the spelling; Git Bash itself was not run.
docs/internals/enforcement.md	  literal name. So Windows Git Bash always gets a prompt.
docs/internals/enforcement.md	Bash on Windows includes it) or `python3` (macOS default — uses
docs/internals/enforcement.md	Bash/PowerShell payload whose command is missing or not a string.
docs/internals/enforcement.md	Fires on Edit/Write/MultiEdit/NotebookEdit, plus a textual Bash/PowerShell
docs/internals/enforcement.md	**The Bash/PowerShell arm is textual and blunt (HIMMEL-1525, HIMMEL-3468,
docs/internals/enforcement.md	PowerShell arm's; the Bash arm judges EVERY segment holding a
docs/internals/enforcement.md	(backslash-newline) is removed as a pair. The PowerShell arm deletes quotes
docs/internals/enforcement.md	a PowerShell read of the file piped or redirected onward (the Bash arm
docs/internals/enforcement.md	- a POSIX-mount spelling (`/c/Users/…`) of a Windows drive root.
docs/internals/enforcement.md	Fires on Bash/PowerShell/Read/Grep. Refuses any tool call that would
docs/internals/enforcement.md	outer clause and the HIMMEL-440 recursed `bash -c` body; PowerShell's
docs/internals/enforcement.md	Fires on Bash/PowerShell. Shared floor with the Codex lane — ports the
docs/internals/enforcement.md	tool-permission config: recursive `rm` / Windows `del`/`erase`/`rd`/`rmdir`,
docs/internals/enforcement.md	spelling (HIMMEL-1821: `schtasks` mutating verbs, the PowerShell
docs/internals/enforcement.md	`Schedule.Service` COM object, while the read-only diagnostics `schtasks
docs/internals/enforcement.md	`pskill`/`kill -9`), system shutdown/reboot/logoff, Windows registry
docs/internals/enforcement.md	(`sudo`, `env`, `cmd /c`, `powershell`/`pwsh -c`) and an executable-path
docs/internals/enforcement.md	first — the Windows lane delivers the same file as `scripts\hooks\x.sh` — and
docs/internals/enforcement.md	Fires on Bash/PowerShell. Every worktree of a checkout shares ONE `refs/stash`,
docs/internals/enforcement.md	CLOSED on missing `jq` or malformed JSON. PowerShell is unguarded (ponytail in
docs/internals/enforcement.md	Fires on Bash/PowerShell. Refuses a tool call that registers an OS scheduler
docs/internals/enforcement.md	when the command BOTH (a) registers a job — `schtasks /create`,
docs/internals/enforcement.md	Why: a hand-rolled `schtasks /create … /tr <bat>` whose `.bat` is just
docs/internals/enforcement.md	scheduler's default cwd `C:\Windows\System32`, so the relaunch runs OUTSIDE the
docs/internals/enforcement.md	repo — a stray `~/.claude/projects/C--Windows-System32` project gets registered,
docs/internals/enforcement.md	split across two calls — write the `.bat` in call 1, `schtasks /create
docs/internals/enforcement.md	Fires on Bash/PowerShell. Denies a per-call env-prefixed invocation of a
docs/internals/enforcement.md	shell variables, PowerShell-native `$env:` syntax, `sudo`/`xargs`/`find
docs/internals/enforcement.md	Fires on Bash/PowerShell. Membership in the `docker` group is
docs/internals/enforcement.md	  (`.ssh .aws .gnupg .kube .docker .config`), and the Windows home tree
docs/internals/enforcement.md	project-local/allowed; Windows `\`→`/` with drive-colon-aware `-v` splitting;
docs/internals/enforcement.md	Fires on Bash/PowerShell. Blocks a `git commit` whose target branch has an
docs/internals/enforcement.md	Fires on Bash/PowerShell. Blocks a `gh pr merge` while the target PR has
docs/internals/enforcement.md	`scripts/cr/critics.json`'s panel is codex-only (the `glm` row was retired
docs/internals/enforcement.md	Fires on `Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell`, but only when
docs/internals/enforcement.md	exhaustive — the exact path is always in hand) plus the Bash/PowerShell
docs/internals/enforcement.md	(glued redirects, attached `-t`, PowerShell aliases) with no sign of
docs/internals/enforcement.md	interpreters/PowerShell readers like `Get-Content`/`Select-String`/...) is
docs/internals/enforcement.md	any PowerShell writer or its built-in alias, or a tool this fence has never
docs/internals/enforcement.md	flag (node/bun/deno `-e`/`--eval`, python `-c`, bash/sh `-c`, pwsh
docs/internals/enforcement.md	Claude subagents while the claudex/GLM entry points were available, consuming
docs/internals/enforcement.md	`spawn-glm.ts`) because the original failure was not knowing the dispatcher
docs/internals/enforcement.md	instructions. Read-only agent types and the claudex/GLM/Codex lane-wrapper
docs/internals/enforcement.md	`spawn-glm.ts`/`spawn-claudex.ts`. Thresholds are unchanged:
docs/internals/enforcement.md	### `block-glm-external-writes.sh` — GLM-lane external-write deny (HIMMEL-654)
docs/internals/enforcement.md	Fires on `Bash|PowerShell|mcp__.*`. The deterministic classifier substitute for
docs/internals/enforcement.md	`--permission-mode bypassPermissions` (GLM workers via `spawn-glm.ts`,
docs/internals/enforcement.md	`claude-glm` sessions). Detects the lane by `ANTHROPIC_BASE_URL` containing
docs/internals/enforcement.md	`api.z.ai` (set by `glm-env.ts` `buildGlmEnv` / the `scripts/claude-glm`
docs/internals/enforcement.md	Jira history and recoverable, so GLM workers may update status/comments and file
docs/internals/enforcement.md	**Fail-CLOSED:** missing `jq` on the GLM lane blocks (parity with
docs/internals/enforcement.md	`scripts/hooks/test-block-glm-external-writes.sh`.
docs/internals/enforcement.md	> arm (settings-chain entries are `Bash`/`PowerShell`-only), and a `--chain`
docs/internals/enforcement.md	  The hang armor (the Windows Store python stub was observed wedging
docs/internals/enforcement.md	rather than an unbounded call. The GNU part is load-bearing on Windows:
docs/internals/enforcement.md	`command -v timeout` also matches `C:\Windows\System32\timeout.exe`, which is a
docs/internals/enforcement.md	on expiry (`taskkill /T` on Windows, a process-GROUP signal on POSIX); a reap
docs/internals/enforcement.md	   Windows/Git-Bash set (`SystemRoot`, `ComSpec`,
docs/internals/enforcement.md	   `PATHEXT`, `MSYSTEM`, `APPDATA`/`LOCALAPPDATA`, the `ProgramFiles` roots …),
docs/internals/enforcement.md	   `FNM_*`, `VOLTA_HOME`, `ASDF_*`). Enumerated empirically on Windows Git-Bash
docs/internals/enforcement.md	the gate-off path previously cost ~1.7s of process spawns on Windows Git Bash.
docs/internals/enforcement.md	cross-platform-sensitive path (`*.sh`, `*.bash`, `*.zsh`, PowerShell files,
docs/internals/enforcement.md	`pwsh`. Empty (`Platforms tested:`) and unrecognised
docs/internals/enforcement.md	gate forces the operator to think about Linux/macOS-vs-Windows before
docs/internals/enforcement.md	**Bash-only.** There is no PowerShell execution path for
docs/internals/enforcement.md	`spawn-glm.ts`, the launcher family, `refresh-graph-map.sh`): a `-f`-gated
docs/internals/enforcement.md	POSIX plugin teardown verifies outcomes (HIMMEL-2796/2804/2800): removal tries plugin scopes plus the install-profile scope and re-lists marketplaces; a listed marketplace is repaired only after a scoped uninstall fails and is never transiently cleaned up; marketplaces-only previews subtract only exact plugin/scope/project handoff rows (legacy marketplace-only rows remain usable for scope replay, not subtraction). PowerShell parity is tracked separately by HIMMEL-2783.
docs/internals/enforcement.md	(`'VAR': 1`, `VAR: '1'`) and PowerShell `$env:VAR = 1`, and only exactly `1` (not
docs/internals/enforcement.md	`schtasks /run /tn HimmelTelegramBridge` — the already-registered logon task
docs/internals/enforcement.md	reboot). Non-Windows refuses rung 2 with rc **20** rather than pretending.
docs/internals/enforcement.md	`block-glm-external-writes.sh`.** Re-pinning off `origin/<default>` makes
docs/internals/enforcement.md	definition of "legitimately committed hook content." `block-glm-external-
docs/internals/enforcement.md	| A `Bash`/`PowerShell` command matching either (i) a keyword/substring hit — `refs/remotes/`, `remotes/origin/`, `symbolic-ref`, `remote set-head`, `remote set-url`, `remote add`, `remote remove`, `remote rm`, `remote rename`, `update-ref`, `insteadOf`, `remote.origin.url` — anywhere in the (lowercased) command text, or (ii) a command-position `git [global-flags] (fetch\|push\|pull)` shape carrying an explicit refspec whose **destination** writes remote-tracking space — `refs/remotes/…`, or an `<a>/<b>` shorthand whose `<a>` is a real remote/tracking namespace in this repo — regardless of which remote is named, and including via `git -C <dir>` | Any `worker_lane` session — GLM (`ANTHROPIC_BASE_URL` = api.z.ai) **or** a native dispatched worker (`HIMMEL_WORKER=1`); a headed operator session never reaches `worker_lane` and is unaffected | Deny, rc=2 | `HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1` set in the **launching** shell (same bypass var as the HIMMEL-2085 pin-dir class — one escape hatch covers both hook-integrity fences; since HIMMEL-3396 it is honoured only inside a linked worktree of the session's recorded repo and audited, so the primary checkout keeps both fences on) |
docs/internals/enforcement.md	denies (`scripts/hooks/test-block-glm-external-writes.sh`'s "glm prose remote
docs/internals/enforcement.md	already documents for the pre-existing GLM-lane classifiers.
docs/internals/enforcement.md	`test-block-glm-external-writes.sh` assert both chains deny, and go red under
docs/internals/enforcement.md	**Both fences in the file are fixed, by ONE shared joiner.** The GLM-lane
docs/internals/enforcement.md	The GLM lane is currently **dropped**; that is recorded as a fact, and it is
docs/internals/enforcement.md	   and the GLM-lane shape matchers (round 5).
docs/internals/graph-cadence.md	crontab/schtasks (an operator action after review); the chief's own
docs/internals/harness-compat.md	> **Platform tier:** Windows is dropped (HIMMEL-5729) and its PowerShell twins are
docs/internals/harness-compat.md	> target bash (still bash 3.2-safe, for macOS). Windows
docs/internals/harness-compat.md	| `codex-replay` | **unavailable**: it needs the hook-replay probe, which was Windows-only and is removed with Windows. It was the positive control that every project hook **executes** (separating "clean" from "never fired") |
docs/internals/harness-compat.md	`codex-exec` exits 2 where `pwsh` or `jq` is missing (it is skipped), 1 otherwise.
docs/internals/harness-compat.md	stubbed `claude`/`codex`/`pwsh` — it never spends a token.
docs/internals/harness-compat.md	### 1. Hooks — Claude-compatible; Windows wiring + block-decision fixed
docs/internals/harness-compat.md	- **execution:** Codex source falls back to `cmd.exe /C` (Windows) / `$SHELL -lc`
docs/internals/harness-compat.md	  (Unix) when no shell is configured, but **live on Windows (0.149.0, 2026-08-21)
docs/internals/harness-compat.md	  every hook ran as `pwsh.exe -NoProfile -Command "<command>"`** — see the
docs/internals/harness-compat.md	  Windows-runner subsection below for the two traps that follow. A hook entry may
docs/internals/harness-compat.md	  carry `commandWindows` (alias `command_windows`) as a per-platform override.
docs/internals/harness-compat.md	which fails on Windows under Codex because (1) `$CLAUDE_PROJECT_DIR` is **unset**
docs/internals/harness-compat.md	`cmd.exe` hits the **WSL `System32\bash.exe` stub trap** (can't read `C:/`, exit
docs/internals/harness-compat.md	Unix and `commandWindows` through `.codex/run-hook.cmd --sandbox` on Windows.
docs/internals/harness-compat.md	Both derive + export `CLAUDE_PROJECT_DIR` from their own location; the Windows
docs/internals/harness-compat.md	wrapper finds Git Bash explicitly (skipping the System32 stub). The wrapper
docs/internals/harness-compat.md	exit-2→deny translation, **exit-2→additionalContext for PostToolUse/SessionStart**, explicit sandbox/no-sandbox mode parsing, and Windows
docs/internals/harness-compat.md	Git-Bash-startup fail-closed handling
docs/internals/harness-compat.md	**Setup options / live-verification caveats (codex-cli 0.141.0, Windows):**
docs/internals/harness-compat.md	- **No-sandbox mode is diagnostic-only.** The Windows wrapper accepts
docs/internals/harness-compat.md	former WSL twin wrote them, `outcome` ∈ `complete|timeout|error`; and the
docs/internals/harness-compat.md	**1.6 s** end to end on this Windows box through `run-hook.sh` + the adapter
docs/internals/harness-compat.md	`msys*/cygwin*/Windows_NT`, so
docs/internals/harness-compat.md	under Codex on **Windows it captures nothing** —
docs/internals/harness-compat.md	#### Windows hook runner = `pwsh -Command` — the two traps
docs/internals/harness-compat.md	**Live finding (2026-08-21, codex-cli 0.149.0, native Windows, no WSL).** A
docs/internals/harness-compat.md	`pwsh.exe -NoProfile -Command "<hook command>"`. Two consequences:
docs/internals/harness-compat.md	1. **Bare `bash` = the WSL launcher.** PATH lookup from that pwsh resolves
docs/internals/harness-compat.md	   `bash` to `C:\Windows\System32\bash.exe` — the *machine* PATH lists System32
docs/internals/harness-compat.md	   after). With WSL wedged on the box (`wsl -l -v` itself hung) every bare-`bash`
docs/internals/harness-compat.md	   events). Codex kills the `pwsh` tree on timeout, but immediately spawns the
docs/internals/harness-compat.md	2. **A command that STARTS with a quoted path is a pwsh string expression.**
docs/internals/harness-compat.md	   leading `& ` (`& "C:\…\bash.exe" "…"`), or Codex's `commandWindows` field.
docs/internals/harness-compat.md	himmel's own `.codex/hooks.json` entries are immune to both — `commandWindows`
docs/internals/harness-compat.md	selects an unquoted relative `.cmd` that pins Git Bash internally. **A/B replay
docs/internals/harness-compat.md	**Tooling (this ticket):** a Windows-only probe (removed with Windows)
docs/internals/harness-compat.md	**Empirical event / tool-name matrix (codex-cli 0.149.0, Windows, `codex exec`
docs/internals/harness-compat.md	command text is **PowerShell** (`Get-Content`, `Remove-Item`, …), so reader/
docs/internals/harness-compat.md	`Bash|PowerShell` are harmless but the `PowerShell` half never matches.
docs/internals/harness-compat.md	runs hooks through Git Bash (`bash -c`) with `CLAUDE_PROJECT_DIR`/`CLAUDE_PLUGIN_ROOT`
docs/internals/harness-compat.md	himmel-ops / codex / qmd) on this Windows box: 51 replayed, **every one ≤1.0s**,
docs/internals/harness-compat.md	| `end-session-wiki.sh` | NA by choice | self-guards off on Windows and its config path is Claude-scoped (see the Codex caveats above) |
docs/internals/harness-compat.md	  stderr is forwarded, the chain always exits 0. It also resolves Git Bash
docs/internals/harness-compat.md	  itself, which a bare `bash` spawned by hermes on Windows would not (the
docs/internals/harness-compat.md	  `System32\bash.exe` WSL-stub trap).
docs/internals/harness-compat.md	superpowers ON both (its Codex SessionStart is rc=1 under pwsh — upstream
docs/internals/harness-compat.md	`commandWindows`/`&` fix wanted, harmless); himmel-ops ON both (Codex side inert
docs/internals/harness-compat.md	and the first, second and fourth also in the `PowerShell` chain, in the Claude
docs/internals/harness-compat.md	`PowerShell` matcher. Declared gap: `block-edit-live-settings`' Edit/Write arm
docs/internals/harness-compat.md	  a pwsh→cmd→bash chain for a guaranteed `exit 0`. Now removed, and
docs/internals/harness-compat.md	  `bash -c "exit 0"` startup smoke test before the adapter — pwsh → cmd →
docs/internals/harness-compat.md	  Windows. `/himmel-update` calls the `.sh` installer, so wiring the lint only
docs/internals/harness-compat.md	  into the Windows twin meant it never fired on the update path.
docs/internals/harness-compat.md	`pwsh → cmd.exe → Git Bash → adapter` stack **per hook entry**, so the nine
docs/internals/harness-compat.md	diagnostic batches peaked at 119–120 Git Bash processes). A `run-hook.cmd`
docs/internals/harness-compat.md	| PowerShell | 7 / ~21 | 2 / ~9 | 6-chain + `.*` auto-arm |
docs/internals/harness-compat.md	  the Windows hook-runner test; `test-codex-hook-parity.sh` refuses a comma outright.
docs/internals/harness-compat.md	- **Matchers had to become disjoint** for this to pay off: `Bash`, `PowerShell`,
docs/internals/harness-compat.md	over-declaration is both noise AND a hook killed mid-flight: on Windows the
docs/internals/harness-compat.md	Hermes-Codex work branches are named `codex/<slug>` (mirrors the spawn-glm
docs/internals/harness-compat.md	`glm/<slug>` convention). This prefix is the Codex lane's positive cheap-lane
docs/internals/known-findings.md	   | `STALE row=N uses=U reason=<r> …` | delete the CodeRabbit learning. Reasons, first hit wins: `windows`, `glm`, `private-repo-propagation`, `file-gone` (the row's file is absent from `git ls-files`; rows from another repository, or with no repository, are skipped), `closed-deferral HIMMEL-n (<status>)` (it defers to a ticket now Done/Closed) |
docs/internals/known-findings.md	  shell/PowerShell twin drift (5). Those became the `fix` / `checklist` detectors; the
docs/internals/known-findings.md	  Retired open-weight critics (kimi, qwen, gptoss, laguna) disproved at 70-90 %
docs/internals/known-findings.md	  and are already off the panel; codex 23 %, codex-adv 6 %, glm 17 %,
docs/internals/lane-calibration.md	| Sonnet 5.5 | scoped research; default implementor for well-specified impl briefs | medium default (a native worker runs at `lanes.json`'s `sonnet` lane effort, `medium`; an explicit `CLAUDE_CODE_EFFORT_LEVEL` in the launching shell overrides it — e.g. `CLAUDE_CODE_EFFORT_LEVEL=high` for a multi-step or guard-grade worker); high for multi-file/long briefs — raise effort before reaching for Opus. Effort is recalibrated vs Sonnet 5: `low` can skip verifying a change, and at `low`/`medium` on long tasks it is likelier to stop and check in (Anthropic migration guide) |
docs/internals/lane-calibration.md	| Opus 5.5 | multi-step reasoning; default parent | medium default (≈ Opus 5 `high`); `low` for scoped impl; `high` for heavy parenting; `xhigh`/`max` only where a gain was measured — see [Effort calibration](#effort-calibration) |
docs/internals/lane-calibration.md	$2.50 above; Haiku 4.5 was $1 / $5), a tokenizer about 30 % heavier than 4.5, and
docs/internals/lane-calibration.md	| Haiku 4.5 low | 1/4 | $0.706 | 432 | 3.00 / 4.50 / 2.00 / 3.00 |
docs/internals/lane-calibration.md	Cost hypothesis ("about 75 % cheaper than Haiku 4.5"): measured **91 % cheaper**
docs/internals/lane-calibration.md	acceptance. Part of the gap is that Haiku 4.5 needed 14-20 tool calls on three
docs/internals/lane-calibration.md	**Known stale rows.** The `[1m]` suffix table below was measured on Haiku 4.5;
docs/internals/lane-calibration.md	`anthropic/claude-haiku-4.5` stays selectable via `OPENROUTER_HAIKU`. Haiku 4.5 retirement is "not sooner than 2026-10-15" (no notice yet).
docs/internals/lane-calibration.md	vs. ruled, and the gpt-5.5 conflict on three of the five); this table only
docs/internals/lane-calibration.md	| `glm` — GLM lane (spawn-glm.ts) | impl | small-context discipline — chunk big plans | 1M | glm (flat-rate overflow, not per-token) | dormant (HIMMEL-1967) |
docs/internals/lane-calibration.md	| `hermes-critics` — hermes free critics (scripts/cr/hermes-critic.sh) | critic | — (critic pass, not effort-tiered) | unverified/varies | none (dashboard-omitted) | calibrated — model is PINNED to gpt-6.1-sol via `critics.json` (re-pinned 2026-09-29, operator moved codex lanes to GPT-6.1 Sol; gpt-6-sol before it, re-pinned 2026-09-23, operator adopted GPT-6 Sol for codex lanes; gpt-6-astra before it, re-pinned 2026-09-05, operator switched the codex CLI default; the pin-via-critics.json mechanism itself dates to operator ruling 2026-08-23, which pinned gpt-5.6-sol), not the himmel_agent profile default that `hermes-oneshot`/dispatch-trusted rides; not yet wired into the `/pr-check` gate |
docs/internals/lane-calibration.md	| `codex` (paid, via hermes) | critic | — (critic pass) | 900000 — raised by operator ruling (2026-08-17); pins gpt-6.1-sol via `critics.json` (2026-09-29; gpt-6-sol before it, 2026-09-23; gpt-6-astra before it, 2026-09-05) — the window figure predates and is independent of the model pin; least-verified of the four raised lanes | none (dashboard-omitted); opt-in `CR_PROFILE=paid` | calibrated — automated review escalation / second opinions only |
docs/internals/lane-calibration.md	| `codex-exec` — codex CLI sandbox | impl | well-scoped chunks; job registry is per-workspace | 900000 — raised by operator ruling (2026-08-17) despite the 360K rejection hermes measured on the gpt-5.5 pin it carried then (codex-exec now follows the `codex` critic's model, `gpt-6.1-sol` (`gpt-6-sol` before it; `gpt-6-astra` before that); that probe was not repeated there); least-verified of the four raised lanes | codex | calibrated |
docs/internals/lane-calibration.md	| `antigravity-cli` — Antigravity CLI (Google AI Plus) | bulk | simple tasks; `--output-format` drift seen on Windows builds | unverified/varies | none (dashboard-omitted); free AI-Plus quota | **not calibrated yet** — roster + quota shape TO VERIFY at eval; parity/guards UNVERIFIED (permission flags only, no hook surface); egress-DENIED for vault corpora, himmel-code only; route only for free-bank chores / second opinions |
docs/internals/lane-calibration.md	  qwen3coder/gptoss/kimi were dropped for noise/errors) — that reversal wants
docs/internals/lane-calibration.md	to one default. Raise effort before raising model tier: Fable-5 `low` ≈
docs/internals/lane-calibration.md	Opus 5.5 at `medium` (its default; Opus 5 defaulted to `high`) matches or beats
docs/internals/lane-calibration.md	Opus 5 at `high` on coding and knowledge work, `low` comes close on several
docs/internals/lane-calibration.md	fleet, and carrying `xhigh` over from Opus 4.8/5 would buy longer, costlier
docs/internals/lane-calibration.md	> OpenAI/Tibo says GPT-6 Astra on **low** performs better than GPT-5.6 Sol on
docs/internals/lane-calibration.md	   `gpt-6.1-sol` (`gpt-6-sol` before it) — at
docs/internals/lane-calibration.md	  `block-terminal-write-fence.sh` on Bash/PowerShell: `git push`, remote-URL
docs/internals/lane-calibration.md	| `claude-opus-5[1m]` | `claude-opus-5[1m]` | `Opus 5 (1M context)` | yes |
docs/internals/lane-calibration.md	| `opus[1m]` (alias) | `claude-opus-5[1m]` | `Opus 5 (1M context)` | yes |
docs/internals/lane-calibration.md	| `claude-opus-4-8[1m]` | `claude-opus-4-8[1m]` | `Opus 4.8 (1M context)` | yes |
docs/internals/lane-calibration.md	| `claude-haiku-4-5-20251001[1m]` | `claude-haiku-4-5-20251001[1m]` | `Haiku 4.5 (1M context)` | yes (4.5 only; 5.5 is natively 1M, unmeasured) |
docs/internals/lane-calibration.md	| `haiku[1m]` (alias) | `claude-haiku-4-5-20251001[1m]` | `Haiku 4.5 (1M context)` | yes |
docs/internals/lane-calibration.md	| `claude-sonnet-5[1m]` | `claude-sonnet-5[1m]` | `Sonnet 5` | passed through (Sonnet 5 is natively 1M here) |
docs/internals/lane-calibration.md	| `sonnet[1m]` (alias) | `claude-sonnet-5[1m]` | `Sonnet 5` | passed through |
docs/internals/lane-calibration.md	`claude-opus-5-5`. The rows above were measured on Opus 5 and have **not** been
docs/internals/lane-calibration.md	context window and no beta header. The Sonnet 5 rows above have **not** been
docs/internals/lane-calibration.md	| `--model claude-opus-5` (plain) | 1000000 |
docs/internals/lane-calibration.md	| `--model claude-sonnet-5` (plain) | 1000000 |
docs/internals/lane-calibration.md	| `--model claude-opus-5 --autocompact 200000` | 1000000 |
docs/internals/lane-calibration.md	A live session launched with a plain `--model claude-opus-5` ninety seconds
docs/internals/lane-calibration.md	Sonnet/Opus/impl lanes. Sonnet 5 carried introductory pricing ($2 per
docs/internals/lane-calibration.md	`anthropic/claude-haiku-4.5`, which logs `unrecognized_model` with
docs/internals/lesson-provenance.md	Bash/PowerShell `command` surface, which as of **round 4** uses an
docs/internals/lesson-provenance.md	redirects, attached `-t` flags, PowerShell built-in aliases — and each
docs/internals/lesson-provenance.md	script/PowerShell readers like `Get-Content`/`Select-String`/...) is
docs/internals/lesson-provenance.md	uniformly instead of to three named cmdlets). PowerShell's free-form
docs/internals/lesson-provenance.md	scan without a PowerShell-specific dispatch, because a value token's own
docs/internals/lesson-provenance.md	`bash`/`sh`/`pwsh`/`bun`/`deno`) are no longer *unconditional* allow-list
docs/internals/lesson-provenance.md	bash/sh `-c`, pwsh `-Command`/`-c`/`-EncodedCommand` — makes the
docs/internals/lesson-provenance.md	- **`parity-guard`** — `parity_guard.py` / `glm-guard.ts` / `phi-egress-guard.ts`
docs/internals/lesson-provenance.md	  (renamed from `glm-guard.ts`; both basenames stay
docs/internals/retask-channel.md	codex/hermes lanes: OpenAI's GPT-6 Astra guide ("Initiative and Follow-Through")
docs/internals/retask-channel.md	completion", while pvncher's *Rethinking skills and prompts for GPT-6 Astra*
docs/internals/retask-channel.md	`scripts/telegram/spawn-glm.ts` implement this template for the GLM lane (dormant, HIMMEL-1967);
docs/internals/script-runtime-practices.md	*traps* (WSL stub resolution, MSYS path mangling, PowerShell footguns) live in
docs/internals/script-runtime-practices.md	| Here-strings / growing content in MSYS bash (historical: Windows is unsupported) | Temp file or case-membership once content can exceed ~64 KiB, never a herestring. | A herestring ≥ 64 KiB wedges MSYS bash forever. |
docs/internals/script-runtime-practices.md	## 2. What it costs — MSYS spawn economics
docs/internals/script-runtime-practices.md	> Historical: measured on the Windows MSYS host, which is no longer supported.
docs/internals/stuck-playbook.md	never-delivering stdin pipe (the arm-resume/schtasks shape). The silent no-op —
docs/internals/testing.md	smoke/PowerShell replay paths before treating those as station-safe. The three
docs/internals/testing.md	confinement fails the run instead of green-skipping coverage. Windows retains a
docs/internals/testing.md	`ubuntu-latest` (the required, gating worker on every push/PR). Windows is
docs/internals/testing.md	nightly and no manual dispatch of `ci.yml` runs a Windows or macOS shard. Running the
docs/internals/testing.md	macOS is verified by the cadence above (Windows is dropped); nothing else
docs/internals/validation-gates.md	implementation lane (a Codex worker, or the dormant GLM lane) earns the right
docs/internals/validation-gates.md	(the automated review stack and the `spawn-glm` worker); this page places
docs/internals/validation-gates.md	## 1. The lane gate (merge review for Codex and GLM branches)
docs/internals/validation-gates.md	branch diff. This is the same seam the spawn-glm worker prompt already names
docs/internals/validation-gates.md	- `glm/*` → `cheap-glm` (spawn-glm PR #843 names `glm/<slug>`; the session meta
docs/internals/validation-gates.md	  under `<BRIDGE_ROOT>/glm-sessions/` corroborates);
docs/internals/validation-gates.md	fails SAFE: a `glm/*` branch with no session meta has no verdict ⇒ no advance.
docs/internals/validation-gates.md	spawn-glm session meta AND the PR body. The trust-tier count (§5) reads that record
docs/internals/validation-gates.md	| Code diff (GLM/Codex lane) | lane gate = full lane + lane rubric, validating session adjudicates | panel fail-open; verdict/marker fail-closed (verdict-presence axis — §3) | merge (operator) |
docs/internals/validation-gates.md	   critics made more trouble than they were worth — gptoss+kimi were
docs/internals/validation-gates.md	Rationale: for GLM/Codex-origin artifacts the adjudicator is already a DIFFERENT
docs/internals/validation-gates.md	blocked (locked) — no GLM critic in any panel until the operator enables
docs/internals/validation-gates.md	- lane fails → the spawn-glm session dir (shipped);
docs/internals/validation-gates.md	not the GLM `d1_verdict` field.
docs/internals/worker-spawn-matrix.md	> **Status (2026-08-19):** the GLM worker, Hermes one-shot, and
docs/internals/worker-spawn-matrix.md	> `scripts/lanes/lanes.json` (`glm`, `hermes-oneshot`, `codex-exec`); `/lanes` and [`lane-calibration.md`](lane-calibration.md) are
docs/internals/worker-spawn-matrix.md	- `scripts/telegram/spawn-glm.ts`
docs/internals/worker-spawn-matrix.md	- `scripts/telegram/phi-egress-guard.ts` (renamed from `glm-guard.ts`)
docs/internals/worker-spawn-matrix.md	launcher: Claude Code, Hermes one-shot, Codex/companion, or GLM-through-Claude.
docs/internals/worker-spawn-matrix.md	`phi-egress-guard` (renamed from `glm-guard`) plus GLM env fences
docs/internals/worker-spawn-matrix.md	for the GLM lane, `parity_guard.py` for Hermes,
docs/internals/worker-spawn-matrix.md	| **Hermes one-shot via `scripts/hermes/invoke.sh` / `dispatch-trusted.sh`** | `invoke.sh` runs in caller's current directory; no worktree creation. Isolation depends on caller creating/choosing a worktree first. | `invoke.sh` uses Hermes with default `todo` toolset unless `--toolsets` opts in. `dispatch-trusted.sh` sets `HERMES_EXTERNAL_WRITES_OK=1` and defaults to `--profile himmel_agent`; `parity_guard.py` remains the fence and fail-closes external writes unless the engine is trusted. | **Yes — LIVE-PROVEN** (2026-07-07 session 11): `invoke.sh --model qwen3-coder-plus` routed to the Alibaba provider (model self-identified) while the unflagged default stayed `gpt-5.5`/openai-codex — two providers from two dispatches on the same surface. Failure mode is loud, not silent: an alias that does not resolve (observed: `qwen-flash`) falls through to the DEFAULT provider, which rejects the unknown model name with HTTP 400. `--profile` selects profile; `--toolsets` selects toolsets. | Optional `--log <path>` tees stdout/stderr. Hermes owns its normal session store; exact one-shot transcript path was not verified in repo files. | `dispatch-trusted.sh` allows trusted-engine external writes through `parity_guard.py`; push/PR still require operator authorization by higher-level policy. GLM/z.ai signals override the opt-in and are refused. | One-shot uses `-z` / yolo-style auto-approval in `invoke.sh`; therefore the default toolset is intentionally `todo` to avoid unattended terminal/browser/fs access unless a caller opts in. | Exit code is Hermes' return code, UNLESS the watchdog fires: `invoke.sh` wall-clock timeboxes (`HERMES_INVOKE_TIMEOUT`, default 1800s) and kills the process tree (rc 124), and separately aborts early (rc 125) on `PARITY_GUARD_DENY_ESCALATE_N` (default 3) identical `parity_guard` denies in a row — a DENY is not terminal to hermes upstream. Optional log file. |
docs/internals/worker-spawn-matrix.md	| **External Claude Code worker (Telegram bounded run via `scripts/telegram/run.ts`)** | Runs in the provided `cwd` / `sessionCwd`; it does not itself create a worktree. Ticket/vault callers choose cwd. | Native Claude Code hooks for the spawned cwd. `run.ts` strips `TELEGRAM_OWN_POLLER`; vault sessions load vault-local hooks. | **Yes.** `run.ts` builds `claude --model <model>`; default `opus`, override via `TELEGRAM_CLAUDE_MODEL`. GLM lane passes a model override via `laneModel('glm')`. | Bus files: inbox/outbox/context paths are embedded in the prompt. The prompt contract appends replies to outbox JSONL and progress to `context.md`. Claude transcripts are under `~/.claude/projects/<escaped-cwd>` by Claude Code convention, but this row's launcher does not print that path. | Prompt permits audited Jira ops but not self-polling. Push/PR authority depends on the brief; no generic push tripwire in `run.ts`. | Bounded run closes stdin, so it cannot answer permission prompts. `run.ts` documents that unapproved tools fall through to prompts and are denied/hang; vault sessions may pass `--permission-mode bypassPermissions` only because the vault hooks still enforce containment. See the permission-window parity GAP below. | `runSession` returns code, pid, capped/blocked/timedOut, and tail; kills process tree on timeout; detects usage caps and content-filter blocks. |
docs/internals/worker-spawn-matrix.md	| **claude-glm / GLM worker via `scripts/telegram/spawn-glm.ts`** | **Yes.** `git worktree add <cwd>/.claude/worktrees/glm+<slug> -b glm/<slug>`; prompt says work only inside that dedicated worktree. | `phi-egress-guard.ts` (renamed from `glm-guard.ts`) checks `.salus`, `phi-roots`, and `egress-denylist` fail-closed before the run. `spawn-glm.ts` leaves the operator's git config untouched — the `remote.origin.pushurl` quarantine it used to apply was removed (it fenced nothing and could lose push configuration). GLM env is built by `glm-env`; Claude Code hooks also apply to the spawned Claude run where present. | **Limited / lane-pinned.** GLM run passes the lane model alias, not the poller default. Per-dispatch context window is selectable by `--context big` or `--context small`; no arbitrary per-call model flag in `spawn-glm.ts` was verified. | `sessionDir=<BRIDGE_ROOT>/glm-sessions/glm-<slug>-<ts>` contains `brief.md`, `meta.json`, `outbox.jsonl`, `context.md`, `run.log`, optional `grants.jsonl`, `respawn-handover.md`. Launcher prints `session-dir`, `transcript-dir`, and exit. | Prompt hard-rules: never push, never open PR; validating session owns git/PR. Push protection is CONTRACT-ONLY and every dispatch report says so; the parent CR gate is the load-bearing control. Jira writes are allowed via audited CLI. | Stdin-closed Claude run inherits the bounded-run permission posture. Guard-blocked steps should append an escalation JSON line to outbox and continue. Grants support read/write shape classification; autonomous mode refuses write-shaped grants and records escalation. See the permission-window parity GAP below. | `meta.json` transitions running -> done/failed/capped/blocked/timeout. Cap guard records `resume_at`, may arm `arm-resume.sh`, and writes respawn handover. `run.log` stores tail; quota gauge records GLM usage signals. |
docs/internals/worker-spawn-matrix.md	| **Codex worker / Codex lane surfaces** | Codex itself uses the caller workspace. Branch provenance convention is `codex/<slug>` per `docs/internals/harness-compat.md`; dedicated worktree creation is outside the codex supervision scripts read here. | Codex direct guard path is `.codex/hooks.json` -> `.codex/run-hook.{sh,cmd}` -> adapter -> native guard scripts per `harness-compat.md` / `lane-parity.md`. `scripts/codex/*` adds observability/supervision, not the primary guard fence. | **UNVERIFIED in repo files read.** Codex model selection surface is not described in the inspected `scripts/codex/*` supervision scripts. | Codex session rollouts live under `$CODEX_HOME/sessions/rollout-*.jsonl`; startup warnings in `$CODEX_HOME/logs_2.sqlite`. Codex companion job state lives under `$CLAUDE_PLUGIN_DATA/state/<slug>-<hash>/state.json` or fallbacks documented in `companion-liveness.sh`. | `lane-parity.md` marks `codex-direct` write-authority / external-write e2e proof as `GAP`; docs say native block hooks are reached through adapter, but codex external-write through-adapter proof remains missing. | `harness-compat.md` says Codex hooks block by stdout JSON `permissionDecision:"deny"`, not Claude exit 2; the adapter translates. Interactive permission-window parity is **UNVERIFIED** here and is a known open item. | `startup-health.sh` reports degraded startup signals: ignored hooks, skill/plugin prompt truncation, oversized `_where-are-we`. `companion-liveness.sh` flags queued/running jobs with no live runner. `reap-mcp-fleet.{sh,ps1}` reports/reaps orphaned Windows MCP fleet processes. |
docs/internals/worker-spawn-matrix.md	- The GLM worker has the clearest worker artifact contract: dedicated worktree,
docs/internals/worker-spawn-matrix.md	  branch, `glm-sessions` directory, outbox/context/meta/log files, and printed
docs/internals/worker-spawn-matrix.md	- **Supervision smoke (hermes parent → external GLM worker):** a
docs/internals/worker-spawn-matrix.md	  `dispatch-trusted.sh` one-shot ran `spawn-glm` end-to-end (worker
docs/internals/worker-spawn-matrix.md	  `glm/749-smoke`, commit `523c3834`, meta `done`/exit 0), then inspected the
docs/internals/worker-spawn-matrix.md	  hermes parent can call to spawn a Claude-lane bounded worker. The GLM
docs/internals/worker-spawn-matrix.md	  worker it did spawn IS a Claude Code process (claude-glm lane), so
docs/internals/worker-spawn-matrix.md	- `UNVERIFIED` - External Claude Code worker push/PR policy outside GLM:
docs/internals/worker-spawn-matrix.md	  `run.ts` does not have the GLM push tripwire. Proof wanted: identify every
docs/internals/worker-spawn-matrix.md	- `GAP` - Permission-window parity: bounded Claude/GLM runs close
docs/internals/worker-spawn-matrix.md	- `GAP` - Startup context parity: Codex has `startup-health.sh`; GLM has prompt
docs/internals/worker-spawn-matrix.md	2. **hermes-spawned Claude Code / GLM workers:** the worker inherits the
docs/internals/worker-spawn-matrix.md	write (`pwsh Set-Content`) went through — the fix for such gaps is structural
docs/jarvis-subsystems.md	The only such lane, GLM (see [tooling-catalog](tooling-catalog.md#claude-glm-scriptsclaude-glm)),
docs/internals/enforcement.md	> **Platform tier:** Windows is dropped (HIMMEL-5729): no Windows host is
docs/internals/enforcement.md	> supported or tested. A Windows, PowerShell or Git Bash note below describes
docs/internals/enforcement.md	preferred; `glm` stays the guard's fallback whenever `ZAI_API_KEY` is set and
docs/internals/enforcement.md	`fedora`, `arch`, `wsl`, `posix`, `gitbash`, `git-bash`, `powershell`,
docs/internals/lane-calibration.md	| `hermes-oneshot` — hermes one-shot dispatch | impl | invoke.sh wall-clock timebox (default 1800s) + Nth-identical-deny abort | 900000 — re-confirmed on ox-alpha (2026-08-22: 300K/600K/900K probes all accepted); previously operator-verified inside hermes v0.20.2 (2026.8.16), upstream commit `bab7be3c` (2026-08-17), superseding 350000 (hermes-agent commit 522997543, 2026-08-16) | none (dashboard-omitted) | calibrated — live-proven spawn path; see [the hermes default](#the-hermes-himmel_agent-default-and-the-ox-alpha-record) |
docs/internals/lane-calibration.md	## The hermes `himmel_agent` default and the ox-alpha record
docs/internals/lane-calibration.md	when the temporary ox-alpha trial ended. Hermes-routed critics do not ride the
docs/internals/lane-calibration.md	From 2026-08-22 the default was `stealth/ox-alpha` (provider `nous`,
docs/internals/lane-calibration.md	it was `gpt-5.6-sol`. Per the lane-adoption rule (profile + tailor per lane; a
docs/internals/lane-calibration.md	codex-tuned 240s budget once starved the GLM lane), it was measured rather than
docs/internals/lane-calibration.md	describe ox-alpha, not `gpt-6.1-sol`.
docs/internals/lane-calibration.md	  900000 stays the declared operating window on that basis, unchanged — it was already an operator ruling/measurement before ox-alpha, and these probes establish ACCEPTANCE at that size, not a verified usable window.
docs/internals/lane-calibration.md	- **Expired.** ox-alpha's trial ended on 2026-10-04 and the profile default
docs/internals/lane-calibration.md	  this repo pins ox-alpha by name, which is deliberate.
docs/README.md	- [launchers.md](launchers.md) — the `claude-codex`, `claude-openrouter` and `claude-deepseek` launchers, their gates and exit codes; the GLM lane is dormant.
docs/README.md	- [jarvis-subsystems.md](jarvis-subsystems.md) — adopter usage map of the optional agentic-OS subsystems (the dormant GLM lane, quota-gauge, escalation channel, statusline, clipper pipeline).
docs/configuration.md	dormant lane's opt-in). The registry also keeps a dropped GLM lane, offered
docs/configuration.md	| GLM launcher (dropped lane), `telegram/glm-env.ts`, graph-map refresh | `ZAI_API_KEY` |
docs/hermes-runbook.md	closed the Codex/GPT-5.5 "should be 1M" report as **not a bug**: live
docs/hermes-runbook.md	`openai-codex` reports and enforces `gpt-5.5` at `272000` tokens, while direct
docs/hermes-runbook.md	OpenAI API `gpt-5.5` can resolve around `1050000`. Pinning Codex to 1M would
docs/hermes-runbook.md	- `himmel_agent` main tier: `openai-codex` + `gpt-5.5` was a **272K Codex
docs/hermes-runbook.md	- GLM / Z.ai lanes (GLM lane dormant, HIMMEL-1967): request the explicit long-context model id
docs/hermes-runbook.md	  `glm-5.2[1m]` on Claude Code-compatible launchers. Bare `glm-5.2` can run
docs/hermes-runbook.md	print(get_model_context_length('glm-5.2[1m]', provider='custom',
docs/launchers.md	| `scripts/claude-glm` | Z.ai GLM | **Removed** from the supported set (see below) |
docs/launchers.md	## `claude-glm` (removed)
docs/launchers.md	The Z.ai GLM lane has been dropped and is **not supported**. The launcher and
docs/launchers.md	`claude-glm` section of [tooling-catalog.md](tooling-catalog.md) describes the
docs/setup/footprint.md	| The personal or medical vault you declare, so local guards keep it away from cloud backends | `~/.config/claude-glm/phi-roots` | user | himmel | Not removed yet: uninstall leaves these lines in place | `phi-roots` |
docs/setup/install.md	> **Windows is not supported** (HIMMEL-5729). himmel runs on Linux and macOS.
docs/setup/install.md	      { "matcher": "Bash|PowerShell|Read|Grep",
docs/setup/new-machine.md	| **Not supported** | Windows, WSL included | Dropped (HIMMEL-5729). |
docs/setup/new-machine.md	- `cygpath` (Windows-only path translation) → `scripts/handover/arm-resume.sh` and `scripts/lib/qmd-bin.sh` (junction creation); falls back to the unconverted path when absent.
docs/setup/new-machine.md	| `ZAI_API_KEY` | Z.ai GLM key for the `claude-glm` launcher of the GLM lane, which is dormant (HIMMEL-1967; the lane registry offers it only when `GLM_LANE_OK` is set) (see [tooling-catalog](../tooling-catalog.md#claude-glm-scriptsclaude-glm)). The launcher takes the live process env first, else reads it from `.env`. It cannot distinguish shell env from `settings.json`-injected env — **don't put this key in `settings.json`** (that hands it to every session); use per-launch shell env or `.env`. | z.ai account → API keys. Optional — only if you use `claude-glm`. |
docs/setup/new-machine.md	| `CLAUDE_LANE_AUTO_RESEED` | Optional opt-out for the lane launchers' config auto-refresh. By default `claude-codex` (and the dormant `claude-glm`) re-seeds its isolated config dir when your `~/.claude` settings or plugin registry changed, so lane workers pick up plugin-profile changes automatically. Set `0` to restore the once-only seed (first launch + explicit `--reseed`) if the auto-refresh ever blocks a launch in your setup. | Leave unset (default on). **Not** bridged from `.env` — set it in the launching shell. Only relevant if you use the offload lanes. |
docs/setup/new-machine.md	### 4d. Optional — PHI vault marker for claude-glm
docs/setup/new-machine.md	The GLM lane is dormant (HIMMEL-1967; the lane registry offers it only when
docs/setup/new-machine.md	`GLM_LANE_OK` is set). If you still use the `claude-glm` launcher (Claude Code on the Z.ai GLM
docs/setup/new-machine.md	flat-rate lane; see [tooling-catalog](../tooling-catalog.md#claude-glm-scriptsclaude-glm)),
docs/setup/new-machine.md	list the absolute PHI roots one-per-line in `~/.config/claude-glm/phi-roots`:
docs/setup/new-machine.md	### 4f. cc-codex / cc-glm offload shims
docs/setup/new-machine.md	`scripts/shell/himmel-offload-shims.sh` provides the `cc-codex` and `cc-glm`
docs/setup/new-machine.md	Bash functions (`cc-glm` launches the dormant GLM lane, HIMMEL-1967). `bash scripts/setup.sh` installs the
docs/setup/new-machine.md	   worktree-and-git-common-dir, Windows-drive-relative, and Windows
docs/setup/operator-profile-tbd-delta.md	| 1 | Armed cadences beyond the pipeline family (graphmap, qmd, drift-fix, ggs) | `schtasks`/cron enumeration matched against 5 known cadence-id task groups (`delta.cadences.taskDetail`) | The wizard's luna-cadence question is binary off/on and only speaks to the pipeline family; it cannot select or report the other four | ticketed: HIMMEL-2302 |
docs/setup/operator-profile-tbd-delta.md	| 10 | Lane readiness gates (`passesRequired` probation counters) and the full dormant-lane roster (opt-in env names) | Direct read of `scripts/lanes/lanes.json`'s `readiness`/`dormant` fields (`delta.lanes.readinessGates`, `dormantLanes`) | The wizard offers only the 4 wizard-askable lane ids (`ollama-local`, `copilot-cli`, `codex-exec`, `hermes-oneshot`); it never surfaces readiness-gate progress or the dormant-lane roster (`glm`, `openrouter-claude`) | ticketed: HIMMEL-2330 |
docs/tool-adoption/lane-adoption-playbook.md	needed. The GLM onboarding (the GLM lane is now dormant, HIMMEL-1967) is the worked
docs/tool-adoption/lane-adoption-playbook.md	example this playbook generalizes: each axis below is a knob GLM's rollout tripped over,
docs/tool-adoption/lane-adoption-playbook.md	*config/code knob* the measurement feeds. Where the axis has GLM evidence
docs/tool-adoption/lane-adoption-playbook.md	**GLM evidence:** `glm-5.2[1m]` measured **~205s / 23KB** response on a real
docs/tool-adoption/lane-adoption-playbook.md	GLM (`CHANGELOG.md`: "raise CRITIC_TIMEOUT_SECS default 150
docs/tool-adoption/lane-adoption-playbook.md	real and grounded (`scripts/cr/critic-panel.sh`), but the GLM
docs/tool-adoption/lane-adoption-playbook.md	- `lanes.json`'s per-lane `context.windowTokens` field (`glm`: 1000000, `claudex`:
docs/tool-adoption/lane-adoption-playbook.md	  from its own env knob: the GLM launcher's `GLM_CONTEXT_WINDOW` and
docs/tool-adoption/lane-adoption-playbook.md	  `spawn-glm --context big|small` preset: `big` =
docs/tool-adoption/lane-adoption-playbook.md	  `glm-5.2[1m]` + `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`; `small` =
docs/tool-adoption/lane-adoption-playbook.md	  `glm-5.2` + 200000; the codex lane's twin, `CODEX_CONTEXT_WINDOW`
docs/tool-adoption/lane-adoption-playbook.md	**GLM evidence:** without an explicit window, Claude Code assumes its ~200k
docs/tool-adoption/lane-adoption-playbook.md	`CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000` for the `[1m]` GLM variant fixed it.
docs/tool-adoption/lane-adoption-playbook.md	auto-compact-window knob explicitly — same pattern as `glm`/`claudex` above.
docs/tool-adoption/lane-adoption-playbook.md	  Codex (GPT-5.5)"* — and the installer's own profile description literally
docs/tool-adoption/lane-adoption-playbook.md	  reads *"himmel's main-tier orchestrator (Codex/GPT-5.5)"*
docs/tool-adoption/lane-adoption-playbook.md	**GLM evidence:** a frontier lane dispatched under `himmel-agent.SOUL.md`
docs/tool-adoption/lane-adoption-playbook.md	**GLM evidence:** `*glm*` falls into the `open` family bucket (alongside
docs/tool-adoption/lane-adoption-playbook.md	qwen/kimi/deepseek/mistral/llama) — rigid format-obedience scaffolding, the
docs/tool-adoption/lane-adoption-playbook.md	GLM worker, Codex worker). Its verdict: "the Hermes one-shot lane has the
docs/tool-adoption/lane-adoption-playbook.md	clearest model/toolset selector... the GLM worker has the clearest worker
docs/tool-adoption/lane-adoption-playbook.md	   `zai-glm`): add nothing to `providers`. Reusing it means the new lane
docs/tool-adoption/lane-adoption-playbook.md	   note — see the `zai-glm` / `openai-codex` rows for the shape), then
docs/tool-adoption/lane-adoption-playbook.md	**GLM evidence — a full ratify-then-reverse cycle.** `zai-glm` was declared
docs/tool-adoption/lane-adoption-playbook.md	`zai-glm` × `extraction` was `allow+log`, ratified 2026-07-17
docs/tool-adoption/lane-adoption-playbook.md	the `why` field, and `handover-state` × `zai-glm` × `inference` was
docs/tool-adoption/lane-adoption-playbook.md	**GLM evidence:** `lanes.json`'s `$readiness-note` records the live operator
docs/tool-adoption/lane-adoption-playbook.md	ruling (2026-08-07): **glm gated at 10 consecutive passes** (down since the
docs/tooling-catalog.md	> shellcheck/pwsh (the image owns them).
docs/tooling-catalog.md	leftover of the dropped Windows support (HIMMEL-5729) and is never read. A cadence copied between stations leaves a dormant,
docs/tooling-catalog.md	dropped Windows support, HIMMEL-5729, never fires on Linux or macOS) and `default_vault` (honors `LUNA_VAULT_PATH` first — the path
docs/tooling-catalog.md	<a id="claude-glm"></a>
docs/tooling-catalog.md	## claude-glm (`scripts/claude-glm`)
docs/tooling-catalog.md	> **Dormant:** the GLM lane was dropped by operator ruling 2026-08-19
docs/tooling-catalog.md	**What:** Thin launcher that runs Claude Code against the Z.ai GLM
docs/tooling-catalog.md	capacity on a flat subscription*, **not** per-token savings: the GLM lane is not
docs/tooling-catalog.md	| `ANTHROPIC_MODEL` | `glm-5.2[1m]` |
docs/tooling-catalog.md	| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `glm-4.7` |
docs/tooling-catalog.md	| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `glm-5.2[1m]` |
docs/tooling-catalog.md	| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `glm-5.2[1m]` |
docs/tooling-catalog.md	| `CLAUDE_CONFIG_DIR` | `$HOME/.claude-glm` |
docs/tooling-catalog.md	**Isolated config dir (`$HOME/.claude-glm`):** seeded from `~/.claude` on first
docs/tooling-catalog.md	  line → **REFUSED, exit 3, no override.** PHI never goes to a cloud GLM backend.
docs/tooling-catalog.md	  content WILL be sent to Z.ai.
docs/tooling-catalog.md	- Config at `~/.config/claude-glm/{phi-roots,egress-denylist}`, one path per
docs/tooling-catalog.md	GLM peak window (14:00–18:00 UTC+8); advisory only, changes no behavior.
docs/tooling-catalog.md	`scripts/test-claude-glm.sh` cover the key gate, the seeder, the
docs/tooling-catalog.md	`spawn-glm` (HIMMEL-1967) shares `~/.claude` directly (no `CLAUDE_CONFIG_DIR`, so himmel hooks load), while
docs/tooling-catalog.md	the interactive (dormant) `claude-glm` launcher runs against a seeded `$HOME/.claude-glm`
docs/tooling-catalog.md	**mirror** of `~/.claude` ([claude-glm](#claude-glm-scriptsclaude-glm) above) — so both would otherwise
docs/tooling-catalog.md	    unattended worker. See the seam note at `spawn-glm.ts:36-41`.
docs/tooling-catalog.md	**Dispatch flags (`spawn-claudex`, and the dormant `spawn-glm`):** both inject the resolved
docs/tooling-catalog.md	worktree side-effect. spawn-glm carries a non-default profile into its
docs/tooling-catalog.md	| `CODEX_CONTEXT_WINDOW` | `272000` by default → `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (twin of `GLM_CONTEXT_WINDOW`). Without it Claude Code assumes its ~200k default for the unrecognized `gpt-6.1-sol` slug and compacts early. The window was measured on gpt-5.6, not yet re-measured for gpt-6.1: gpt-5.6's real window is **~372k** (95% effective ~353k, [openai/codex#32486](https://github.com/openai/codex/issues/32486)); **272k is the 2× pricing cliff, NOT a hard ceiling** — input past 272k bills 2× input / 1.5× output. `272000` is the cost-optimal default (compact at the cliff); raise to `353000` to use the full window at 2× cost past 272k. |
docs/tooling-catalog.md	`claude-sonnet-5` when the proxy serves it (cli-proxy-api's claude provider, OAuth
docs/tooling-catalog.md	classifier and substitutes `claude-sonnet-5`). The main, Haiku, Opus and subagent
docs/tooling-catalog.md	**Seeding:** same lane-seed mechanism as the dormant `claude-glm`: an isolated
docs/tooling-catalog.md	the dormant `claude-glm`.
docs/tooling-catalog.md	choice, not a hard ceiling — the real backend window for gpt-5.6-sol was
docs/tooling-catalog.md	2. **The `[1m]` model-name suffix** — the convention the dormant GLM lane
docs/tooling-catalog.md	   attached returned `HTTP 400 unknown provider for model gpt-5.6-sol[1m]`
docs/tooling-catalog.md	**What:** the codex-lane twin of the dormant `spawn-glm` —
docs/tooling-catalog.md	the dormant GLM lane. `spawn-claudex.ts` dispatches THROUGH `claude-codex` itself
docs/tooling-catalog.md	bun scripts/telegram/spawn-claudex.ts "<prompt>" [--cwd <dir>] [--name <slug>] [--branch <existing>] [--timeout-mins <n>] [--permission-mode <mode>] [--effort low|medium|high|xhigh] [--model gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna] [--force]
docs/tooling-catalog.md	**Model tier:** `--model` is optional and selects the GPT-5.6
docs/tooling-catalog.md	`gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`; anything else is a parse-time
docs/tooling-catalog.md	**Bash convenience shims:** `scripts/shell/himmel-offload-shims.sh` installs idempotent `cc-codex` / `cc-glm` functions into `~/.bashrc` (`cc-glm` launches the dormant GLM lane, HIMMEL-1967).
docs/tooling-catalog.md	## spawn-glm (`scripts/telegram/spawn-glm.ts`)
docs/tooling-catalog.md	**What:** Poller-free CLI that spawns an unattended GLM-lane Claude worker for
docs/tooling-catalog.md	fresh git worktree + `glm/<slug>` branch, resolves the GLM env block
docs/tooling-catalog.md	(`glm-env.ts` — `ZAI_API_KEY` from shell env or the himmel repo `.env`, launcher
docs/tooling-catalog.md	the run through the `runSession(…, lane:"glm")` seam in `run.ts`. GLM runs pin
docs/tooling-catalog.md	`--model opus` (→ `glm-5.2[1m]`) and ignore `TELEGRAM_CLAUDE_MODEL`. Sessions live
docs/tooling-catalog.md	under `<BRIDGE_ROOT>/glm-sessions/` (default `~/.claude/handover/bridge/`) —
docs/tooling-catalog.md	gracefully via the **escalation channel** — `spawn-glm --grant`/`--autonomous`
docs/tooling-catalog.md	bun scripts/telegram/spawn-glm.ts "<prompt>" [--cwd <dir>] [--name <slug>] [--timeout-mins <n>] [--permission-mode <mode>] [--arm-on-cap | --no-arm-on-cap]
docs/tooling-catalog.md	`block-glm-external-writes.sh` and the load-bearing control is the automated review gate (no
docs/tooling-catalog.md	GLM branch merges except by the validating session). The egress guards
docs/tooling-catalog.md	are dormant by construction (himmel-worktree cwd scope). Uses GLM flat-rate
docs/tooling-catalog.md	with argv shape unchanged, GLM model pin ignoring `TELEGRAM_CLAUDE_MODEL`,
docs/tooling-catalog.md	  `--provider deepseek|codex|glm|claude` (default `deepseek`) summary + vocab-constrained tags + locally-computed Related Notes for
docs/tooling-catalog.md	  (permitted: `claude` only, via the `anthropic → allow` rule — `deepseek` was de-listed earlier and `glm`/`zai-glm` since, and `codex` stays default-deny until an adopter ratifies a cell; the entries remain so the gate refuses them legibly), ledgered per run
docs/tooling-catalog.md	  (`GRAPHIFY_LEDGER`); `deepseek`/`codex` use OpenAI chat/completions, `glm` (via z.ai anthropic-compat)/`claude` use the Anthropic Messages API. DeepSeek off-peak advisory. `--dry-run` first.
docs/tooling-catalog.md	  `--backend glm` was a prior lane but zai-glm is de-listed,
docs/tooling-catalog.md	  and `--backend kimi` (moonshot) is retired —
docs/tooling-catalog.md	  operator ruling, there is no kimi backend — so both now fail closed on luna
docs/tooling-catalog.md	  corpora, glm at the egress preflight and kimi as an unclassified provider).
docs/tooling-catalog.md	  overshoots Z.ai's request limit — `--backend glm` 429s (`rate_limit_error`
docs/tooling-catalog.md	  staggered) is now **weekly**, on the **`claude-cli`** backend (kimi/moonshot is retired, operator ruling; claude-cli is the
docs/tooling-catalog.md	  subscription) — the original credential gate (kimi ->
docs/tooling-catalog.md	  `MOONSHOT_API_KEY`) no longer applies now that kimi is retired, though the
docs/tooling-catalog.md	- `scripts/cr/critic-panel.sh` + `scripts/cr/critics.json` — NIM critic panel (roster defined in `critics.json`). **`critics.json` currently holds ONE row — `codex`/`gpt-6.1-sol`, tier `paid` — and NO free critics.** The free lane was **removed deliberately** — it made more trouble than it was worth: gptoss + kimi dropped 2026-07-03 (operator decision, 12%/13% ledger agreed-rate — noise), and the surviving qwen3coder anchor kept erroring rc=1. Paid-by-default is the intended posture, not drift. So `/pr-check` **auto-runs the PAID codex anchor by default** (~2min, bounded by the 240 s per-member timeout): an unset `CR_PROFILE` **AND** unset `CRITIC_PANEL_TIERS` resolve to tier filter `free` (`CRITIC_PANEL_TIERS` is the low-level override, honored ONLY when `CR_PROFILE` is unset), which matches zero rows, so the panel falls back to the paid anchor — **spending the OpenAI subscription usage budget on any default run that actually runs the panel** — skipped, and therefore free, on an empty diff or `CR_PROFILE=none` (operator decision: accepted). Note this fallback also bypasses the triviality gate, which only fires when `paid` is already IN the tier filter. `CR_PROFILE=none` = instant claude-only (skip panel). `CR_PROFILE=thorough` = adds the `thorough` tier (currently EMPTY — kept for future heavier critics). `CR_PROFILE=paid` / `free,paid` = the paid codex critic. Any other value is the tier filter verbatim. **`CR_PROFILE` is authoritative:** `/pr-check` loads it from `.env` and the panel derives its tiers from it directly — it wins over the low-level `CRITIC_PANEL_TIERS` override (honored only when `CR_PROFILE` is unset). This closed a drift where a run hand-scoped the panel to free-only and silently dropped the paid critic. Retired the gemini-only CR lane. Per-member hang protection via `CRITIC_TIMEOUT_SECS` — default **240 s**, which is ALSO the fallback when the supplied value is non-numeric or ≤0 (the panel warns and uses 240 rather than failing). It was raised from 150 s after codex + qwen3coder were seen clipping at 150 s. It needs the `timeout` binary, but does not *require* it: when `timeout` is absent the panel prints "per-member hang protection disabled" and runs each member **unbounded**.
docs/tooling-catalog.md	- `scripts/cr/pr-check-external.sh` — **Claude-free automated review runner**: reviews a branch with NO Claude session so review still runs when the Claude subscription usage budget is maxed. `--branch <b> [--session-dir <dir>] [--base <ref>]`; fetches, diffs `origin/<base>...<branch>`, pipes to `critic-panel.sh` with `CR_PROFILE=free,paid` forced (so the paid codex critic reviews; `CR_PROFILE=none` refused). Fail-CLOSED gate: panel non-zero exit, unparseable Critical/Important counts, an ABSENT codex critic, or any Critical/Important finding all FAIL. A diff touching the automated review/merge **gate infrastructure** is refused outright (the original design wanted a quorum of two responding cross-model reviewers there; the CodeRabbit CLI was the second seat and it was retired, while `critics.json`'s panel is codex-only — so the quorum cannot be met on this path and gate-infra changes go through the interactive `/pr-check`). On clean it writes `external_cr_verdict: pass (sha=…; critics=…)` into the spawn-glm session `meta.json` (distinct from `d1_verdict`) and prints a PR-body snippet; does NOT touch the review-owed marker. Test: `scripts/cr/test-pr-check-external.sh` (hermetic; fake git repo + stubbed panel via `CRITIC_PANEL_CMD`).
docs/tooling-catalog.md	## GLM ship lane (`scripts/glm/`)
docs/tooling-catalog.md	- `scripts/glm/ship-branch.sh` — pushes a reviewed `glm/*` branch FROM the trusted main checkout (the GLM worker still never pushes for itself — the no-push prompt + the deny hook are unchanged; the pushurl poison that used to sit alongside them is gone). `ship-branch.sh <branch> [--session-dir <dir>] [--allow-any-branch]`; refuses to run from a `.claude/worktrees/` path, requires an `origin` remote, and is authorized only by `external_cr_verdict:pass` (written by `pr-check-external.sh`) whose reviewed SHA must equal the current branch tip (closes the post-panel-commit TOCTOU). Runs `git push -u origin <branch>` with the real pre-push gates (NO `--no-verify`), then clears the review-owed marker only when its SHA matches the pushed SHA. Never opens a PR, never merges — prints the exact `gh pr create` for the operator. Test: `scripts/glm/test-ship-branch.sh` (hermetic; temp bare-repo origin).
docs/internals/environment-gotchas.md	$ cd scripts/telegram && bun test spawn-glm.test.ts
docs/internals/environment-gotchas.md	error: ENOENT: no such file or directory, open 'scripts/telegram/spawn-glm.ts'   (x8)
docs/internals/environment-gotchas.md	The two command-text fences in `block-glm-external-writes.sh` (the pin-dir fence
docs/internals/lane-parity.md	> dormancy status for impl lanes (GLM, claudex, hermes-oneshot, codex-exec) lives in `scripts/lanes/lanes.json` /
docs/internals/lane-parity.md	the `glm-spawn` fleet reads live `~/.claude`; the `claude-glm` launcher reads a
docs/internals/lane-parity.md	seeded `~/.claude-glm` copy; Codex / Cursor / Copilot read the generated
docs/internals/lane-parity.md	**GLM is reachable by THREE paths, with THREE different guard mechanisms -- so
docs/internals/lane-parity.md	"GLM is guarded" is proven per-path, not asserted once:**
docs/internals/lane-parity.md	1. `glm-spawn` -- Claude Code with the backend swapped, reads live `~/.claude`;
docs/internals/lane-parity.md	   `block-glm-external-writes.sh` (the classifier substitute for the
docs/internals/lane-parity.md	2. `glm-launcher` -- Claude Code with the backend swapped, reads a seeded
docs/internals/lane-parity.md	   `~/.claude-glm` copy; same guards as (1), plus a config-seed drift dimension.
docs/internals/lane-parity.md	3. GLM-via-hermes -- the hermes runtime drives GLM; himmel's Claude Code
docs/internals/lane-parity.md	Same model, three runtimes, three guard mechanisms. A single "GLM is guarded"
docs/internals/lane-parity.md	three GLM paths are dormant: no work routes to them, and their rows stay so
docs/internals/lane-parity.md	`block-glm-external-writes.sh` is a lane-specific classifier SUBSTITUTE, not
docs/internals/lane-parity.md	| glm-spawn (dormant) | `tested:scripts/hooks/test-block-glm-external-writes.sh` |
docs/internals/lane-parity.md	| glm-launcher (dormant) | `tested:scripts/hooks/test-block-glm-external-writes.sh` |
docs/internals/lane-parity.md	| hermes-main (DEFAULT; engine gpt-6.1-sol; GLM dormant) | `parity_guard` push/PR fence -- `tested:scripts/hermes/test-parity-guard.sh` (write-fence; the CC hook does NOT fire under hermes, parity_guard is the sole fence). The other deny-guards are enforced by parity_guard too (all `present`). |
docs/internals/lane-parity.md	| glm-spawn (dormant) | `native,no-seed` (live `~/.claude`) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
docs/internals/lane-parity.md	| glm-launcher (dormant) | `tested:scripts/hooks/test-claude-glm-seed-check.sh` (seeded `~/.claude-glm`, drift-checked) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
docs/internals/lane-parity.md	| hermes-main (DEFAULT; engine gpt-6.1-sol; GLM dormant) | `AGENTS.md (loaded)` (`tested:scripts/hermes/test-agents-reach.sh`) | `tested:scripts/hermes/test-parity-guard.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
docs/internals/lane-parity.md	Notes on the guardrail-firing cells. GLM IS Claude Code, so on the two CC GLM
docs/internals/lane-parity.md	`test-block-glm-external-writes.sh`, which covers the lane-specific write-fence
docs/internals/lane-parity.md	as in the `claude-glm` lane, so its guard posture is the native column. It has
docs/internals/lane-parity.md	| deny-guard | glm-spawn (dormant) | glm-launcher (dormant) | codex-direct | hermes-main (gpt-6.1-sol; GLM dormant) |
docs/internals/lane-parity.md	| block-edit-on-main | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-edit-on-main.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
docs/internals/lane-parity.md	| block-read-secrets | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-read-secrets.sh` `tested:scripts/hooks/test-codex-adapter-e2e.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
docs/internals/lane-parity.md	| block-backend-tier | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-backend-tier.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
docs/internals/lane-parity.md	| block-docker-privesc | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-docker-privesc.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
docs/internals/lane-parity.md	| block-rogue-claude-schedule | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-rogue-claude-schedule.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
docs/internals/lane-parity.md	| block-merged-pr-commit | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-merged-pr-commit.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
docs/internals/lane-parity.md	| write-authority / external-write-fence (cross-lane dimension, NOT a CC PreToolUse hook) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-terminal-write-fence.sh` `tested:scripts/hooks/test-codex-adapter-e2e.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
docs/internals/lane-parity.md	- **glm-spawn + glm-launcher (dormant).** GLM IS Claude Code, so on these two
docs/internals/lane-parity.md	  CC GLM lanes the native block-* deny-guard hooks fire unchanged; the single
docs/internals/lane-parity.md	  `tested:scripts/hooks/test-block-glm-external-writes.sh` (covers push /
docs/internals/lane-parity.md	  both lanes because the ruleset is live `~/.claude` (glm-spawn) or the seeded
docs/internals/lane-parity.md	  `~/.claude-glm` copy (glm-launcher).
docs/internals/lane-parity.md	- **hermes-main (DEFAULT; engine gpt-6.1-sol; GLM dormant).** himmel's CC
docs/internals/lane-parity.md	engines (gpt-6.1-sol + the dormant GLM) the `himmel_agent` profile is pointed
docs/internals/lane-parity.md	| `block-rogue-claude-schedule` | `TERMINAL_DESTRUCTIVE` blocks `schtasks` (and `taskkill`/`shutdown`/`reg`/`shutdown`), the scheduler-mutation class that arms a rogue `claude` schedule. The claude-CLI-specific System32-cwd anti-trap is a launch-path check with no hermes analog -- hermes does not arm the `claude` CLI. | `present` (scheduler vector fenced; the System32-cwd trap is `n/a-for-runtime`) |
docs/internals/lane-parity.md	| write-authority / external-write-fence (cross-lane dimension) | The engine-gated write-fence landed: `terminal_external_write_reason` refuses `git push` (plain, not just `--force`), git remote-URL / `config ...url` rewrite, `gh` PR-mutations (carve-out: `gh issue *` + `gh pr view/diff/checks/status/list` + `gh run view/list/watch`), and network CLIs (`curl`/`wget`/`iwr`/`irm`). `_external_writes_allowed()` is fail-closed: refused unless `HERMES_EXTERNAL_WRITES_OK=1` AND no `api.z.ai` / `HERMES_ENGINE=glm*` untrusted signal. Proved by `test-parity-guard.sh` (push / remote-url / `gh pr create` / `curl` refused; carve-outs + trust opt-in allowed; z.ai + `HERMES_ENGINE=glm` override the opt-in). | `present` |
docs/internals/lane-parity.md	| `block-backend-tier` | `parity_guard`'s hook matcher (`wire_parity_guard.py MATCHER`, now `.*` -- it previously included `mcp__.*`) delivers every tool to the guard, and `main()` blanket-denies every `mcp__*` tool EXCEPT the read-only `qmd` KB carve-out (`mcp__plugin_qmd_qmd__*`) -- mirroring `block-glm-external-writes.sh`. MCP tool calls now invoke the guard and are fenced. | `present` (MCP fenced, qmd carve-out) |
docs/internals/lane-parity.md	**GLM-engine write-fence vs `scripts/hooks/block-glm-external-writes.sh`.** The
docs/internals/lane-parity.md	`block-glm-external-writes.sh`. So an MCP tool call invokes the guard and is
EOF
)

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok - $*"; }
bad() { fail=$((fail + 1)); echo "not ok - $*"; }

for sample in 'runs on Windows' 'under WSL2' 'pinned gpt-5.5' 'gpt-6-sol' 'claude-haiku-4-5' 'Opus 4.8' 'the GLM lane' 'a Fable 5 parent' 'stealth/ox-alpha' 'under wsl' 'use powershell' 'in git-bash'; do
  grep -q -E "$PATTERN" <<< "$sample" || bad "pattern misses its own sample '$sample'"
done
for sample in 'Fable 5.1' 'Opus 5.5.' 'claude-opus-5-5' 'gpt-6.1-sol' 'a Linux host' 'two usage windows'; do
  if grep -q -E "$PATTERN" <<< "$sample"; then
    bad "pattern flags the current term '$sample'"
  fi
done

in_list() { grep -q -x -F "$1" <<< "$2"; }

tmp=$(mktemp -d -t docs-dropped-terms.XXXXXX) || exit 1
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$ALLOW" | grep -v '^$' > "$tmp/allow"

git -C "$ROOT" ls-files docs README.md site | grep -v '^docs/internals/' | grep -E '\.(md|mdx|html|astro)$' > "$tmp/user"
(cd "$ROOT" && xargs grep -ohE 'internals/[A-Za-z0-9_./-]+\.md' < "$tmp/user") \
  | sed 's#.*internals/#docs/internals/#' | sort -u > "$tmp/linked"
cat "$tmp/user" "$tmp/linked" > "$tmp/scope"
: > "$tmp/hits"
: > "$tmp/pages"
while IFS= read -r page; do
  case $page in docs/release/* | docs/migration/renamed-identifiers.md) continue ;; esac
  [ -f "$ROOT/$page" ] || continue
  echo "$page" >> "$tmp/pages"
  grep -h -E "$PATTERN" "$ROOT/$page" | awk -v f="$page" '{ print f "\t" $0 }' >> "$tmp/hits"
done < "$tmp/scope"

# A hit no ALLOW entry of its page covers goes to found; an entry that covers
# no hit goes to stale.
awk -F '\t' -v found="$tmp/found" -v stale="$tmp/stale" '
  NR == FNR { file[NR] = $1; text[NR] = substr($0, length($1) + 2); n = NR; next }
  {
    line = substr($0, length($1) + 2); covered = 0
    for (i = 1; i <= n; i++)
      if (file[i] == $1 && line == text[i]) { covered = 1; used[i] = 1 }
    if (!covered) print > found
  }
  END { for (i = 1; i <= n; i++) if (!(i in used)) print file[i] "\t" text[i] > stale }
' "$tmp/allow" "$tmp/hits"
touch "$tmp/found" "$tmp/stale"

while IFS= read -r page; do
  found=$(awk -F '\t' -v p="$page" '$1 == p' "$tmp/found")
  if in_list "$page" "$PENDING"; then
    [ -n "$found" ] || bad "$page is clean now: remove it from PENDING"
  elif [ -n "$found" ]; then
    printf '%s\n' "$found"
    bad "$page names a dropped platform or lane, or an old model (listed above)"
  else
    ok "$page"
  fi
done < "$tmp/pages"

if [ -s "$tmp/stale" ]; then
  cat "$tmp/stale"
  bad "ALLOW entries no line carries any more (listed above): drop or update them"
fi
for page in $PENDING; do
  in_list "$page" "$(cat "$tmp/scope")" || bad "PENDING names $page, which is out of scope"
done

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
