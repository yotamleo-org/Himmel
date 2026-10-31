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
# read -d '' not $(cat <<EOF): bash 3.2 (macOS) scans a heredoc inside $( ) for
# balanced backticks and parens and dies on this page text.
IFS= read -r -d '' ALLOW <<'EOF' || true
README.md	  run. Windows is not supported. Details in the
README.md	himmel is developed on Linux and macOS. **Windows (Git Bash, WSL) is not
README.md	supported.** Windows support was dropped; nothing about Windows is claimed as
README.md	| **Dropped** | Windows (Git Bash), WSL | Support was dropped: no CI gate, no guarantee. |
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
docs/glossary.md	| Secrets never read | `block-read-secrets` (Bash, PowerShell, Read, Grep) | — | `block-read-secrets` (Bash, Read, Grep) | — | — | — |
docs/glossary.md	| No rogue scheduler job launches `claude` | `block-rogue-claude-schedule` (Bash, PowerShell) | — | `block-rogue-claude-schedule` (Bash) | — | — | — |
docs/glossary.md	| No `git stash` | `block-git-stash` (Bash, PowerShell) | — | `block-git-stash` (Bash) | — | — | — |
docs/glossary.md	| Live settings not writable | `block-edit-live-settings` (Bash, PowerShell, Edit) | — | `block-edit-live-settings` (Bash; not `apply_patch`, HIMMEL-5430 open) | — | — | — |
docs/guide/installer-journey.html	<span class="d">  [ ] 2. add the vault's absolute path as a line in ~/.config/claude-glm/phi-roots</span>
docs/guide/installer-journey.html	<span class="d">  [ ] 3. add the relevant path(s)/pattern(s) to ~/.config/claude-glm/egress-denylist</span>
docs/guide/installer-journey.html	      term: function () { return [['d', '── PHI checklist — READ ONLY, himmelctl creates none of this ──────────────'], ['d', '  [ ] 1. drop a `.salus` marker file at the vault root (or an ancestor dir)'], ['d', '  [ ] 2. add the vault\'s absolute path as a line in ~/.config/claude-glm/phi-roots'], ['d', '  [ ] 3. add the relevant path(s)/pattern(s) to ~/.config/claude-glm/egress-denylist'], ['q', '? does this vault handle Protected Health Information (PHI)? [yes|no] (default: no)'], ['in', '> no']]; },
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
docs/internals/egress-matrix.md	| `phi-egress-guard.ts` (renamed from `glm-guard.ts`) | same `salus`/denylist row |
docs/internals/egress-matrix.md	  an unreadable claude-glm config dir, a base URL carrying credentials, and a
docs/internals/egress-matrix.md	  Windows launchers are out of scope (Windows is dropped).
docs/internals/enforcement.md	leftover Codex copy, which was costing a `pwsh`→`cmd`→`bash` spawn on every
docs/internals/enforcement.md	Fires on `Bash|PowerShell|mcp__.*`. Keyed on `HIMMEL_WORKER=1`, the
docs/internals/enforcement.md	- **Pin-dir class (HIMMEL-2085):** a Bash/PowerShell command whose text names
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
docs/internals/enforcement.md	Fires on `Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell`, but only when
docs/internals/enforcement.md	exhaustive — the exact path is always in hand) plus the Bash/PowerShell
docs/internals/enforcement.md	(glued redirects, attached `-t`, PowerShell aliases) with no sign of
docs/internals/enforcement.md	interpreters/PowerShell readers like `Get-Content`/`Select-String`/...) is
docs/internals/enforcement.md	any PowerShell writer or its built-in alias, or a tool this fence has never
docs/internals/enforcement.md	flag (node/bun/deno `-e`/`--eval`, python `-c`, bash/sh `-c`, pwsh
docs/internals/enforcement.md	Claude subagents while the claudex/GLM entry points were available, consuming
docs/internals/enforcement.md	instructions. Read-only agent types and the claudex/GLM/Codex lane-wrapper
docs/internals/enforcement.md	> arm (settings-chain entries are `Bash`/`PowerShell`-only), and a `--chain`
docs/internals/enforcement.md	  The hang armor (the Windows Store python stub was observed wedging
docs/internals/enforcement.md	rather than an unbounded call. The GNU part is load-bearing on Windows:
docs/internals/enforcement.md	`command -v timeout` also matches `C:\Windows\System32\timeout.exe`, which is a
docs/internals/enforcement.md	first — so a Windows-style spelling such as `scripts\hooks\x.sh` is still caught — and
docs/internals/enforcement.md	   locale set, `TZ`, the `XDG_*` base dirs), `BUN_INSTALL`, the `MSYS*` names and
docs/internals/enforcement.md	   list still carries the Windows set (`SYSTEMROOT`, `WINDIR`, `COMSPEC`,
docs/internals/enforcement.md	   enumerated empirically on Windows Git-Bash — every interpreter and every
docs/internals/enforcement.md	the gate-off path previously cost ~1.7s of process spawns on Windows Git Bash.
docs/internals/enforcement.md	cross-platform-sensitive path (`*.sh`, `*.bash`, `*.zsh`, PowerShell files,
docs/internals/enforcement.md	`pwsh`. Empty (`Platforms tested:`) and unrecognised
docs/internals/enforcement.md	**Bash-only.** There is no PowerShell execution path for
docs/internals/enforcement.md	(`'VAR': 1`, `VAR: '1'`) and PowerShell `$env:VAR = 1`, and only exactly `1` (not
docs/internals/enforcement.md	| A `Bash`/`PowerShell` command matching either (i) a keyword/substring hit — `refs/remotes/`, `remotes/origin/`, `symbolic-ref`, `remote set-head`, `remote set-url`, `remote add`, `remote remove`, `remote rm`, `remote rename`, `update-ref`, `insteadOf`, `remote.origin.url` — anywhere in the (lowercased) command text, or (ii) a command-position `git [global-flags] (fetch\|push\|pull)` shape carrying an explicit refspec whose **destination** writes remote-tracking space — `refs/remotes/…`, or an `<a>/<b>` shorthand whose `<a>` is a real remote/tracking namespace in this repo — regardless of which remote is named, and including via `git -C <dir>` | A native dispatched worker session (`HIMMEL_WORKER=1`); a headed operator session never reaches `worker_lane` and is unaffected | Deny, rc=2 | `HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1` set in the **launching** shell (same bypass var as the HIMMEL-2085 pin-dir class — one escape hatch covers both hook-integrity fences; since HIMMEL-3396 it is honoured only inside a linked worktree of the session's recorded repo and audited, so the primary checkout keeps both fences on) |
docs/internals/enforcement.md	**Both fences in the file are fixed, by ONE shared joiner.** The GLM-lane
docs/internals/enforcement.md	The GLM lane is currently **dropped**; that is recorded as a fact, and it is
docs/internals/enforcement.md	   and the GLM-lane shape matchers (round 5).
docs/internals/harness-compat.md	> **Platform tier:** Windows is dropped (HIMMEL-5729) and its PowerShell twins are
docs/internals/harness-compat.md	> target bash (still bash 3.2-safe, for macOS). Windows
docs/internals/harness-compat.md	| `codex-replay` | **unavailable**: it needs the hook-replay probe, which was Windows-only and is removed with Windows. It was the positive control that every project hook **executes** (separating "clean" from "never fired") |
docs/internals/harness-compat.md	`codex-exec` exits 2 where `pwsh` or `jq` is missing (it is skipped), 1 otherwise.
docs/internals/harness-compat.md	stubbed `claude`/`codex`/`pwsh` — it never spends a token.
docs/internals/harness-compat.md	- **execution:** Codex source falls back to `cmd.exe /C` (Windows) / `$SHELL -lc`
docs/internals/harness-compat.md	  (Unix) when no shell is configured, but **live on Windows (0.149.0, 2026-08-21)
docs/internals/harness-compat.md	  every hook ran as `pwsh.exe -NoProfile -Command "<command>"`** — see the
docs/internals/harness-compat.md	  Windows-runner subsection below for the two traps that follow. A hook entry may
docs/internals/harness-compat.md	  carry `commandWindows` (alias `command_windows`) as a per-platform override.
docs/internals/harness-compat.md	which fails on Windows under Codex because (1) `$CLAUDE_PROJECT_DIR` is **unset**
docs/internals/harness-compat.md	`cmd.exe` hits the **WSL `System32\bash.exe` stub trap** (can't read `C:/`, exit
docs/internals/harness-compat.md	**Setup options / live-verification caveats (codex-cli 0.141.0, Windows):**
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
docs/internals/harness-compat.md	**Tooling (this ticket):** a Windows-only probe (removed with Windows)
docs/internals/harness-compat.md	**Empirical event / tool-name matrix (codex-cli 0.149.0, Windows, `codex exec`
docs/internals/harness-compat.md	command text is **PowerShell** (`Get-Content`, `Remove-Item`, …), so reader/
docs/internals/harness-compat.md	is itself a Codex compat alias (Claude-engine), which is why the `PowerShell`
docs/internals/harness-compat.md	runs hooks through Git Bash (`bash -c`) with `CLAUDE_PROJECT_DIR`/`CLAUDE_PLUGIN_ROOT`
docs/internals/harness-compat.md	himmel-ops / codex / qmd) on this Windows box: 51 replayed, **every one ≤1.0s**,
docs/internals/harness-compat.md	| `end-session-wiki.sh` | NA by choice | self-guards off on Windows and its config path is Claude-scoped (see the Codex caveats above) |
docs/internals/harness-compat.md	  stderr is forwarded, the chain always exits 0. It also resolves Git Bash
docs/internals/harness-compat.md	  itself, which a bare `bash` spawned by hermes on Windows would not (the
docs/internals/harness-compat.md	  `System32\bash.exe` WSL-stub trap).
docs/internals/harness-compat.md	  a pwsh→cmd→bash chain for a guaranteed `exit 0`. Now removed, and
docs/internals/harness-compat.md	  `bash -c "exit 0"` startup smoke test before the adapter — pwsh → cmd →
docs/internals/harness-compat.md	`pwsh → cmd.exe → Git Bash → adapter` stack **per hook entry**, so the nine
docs/internals/harness-compat.md	diagnostic batches peaked at 119–120 Git Bash processes). A `.codex/run-hook.sh`
docs/internals/harness-compat.md	over-declaration is both noise AND a hook killed mid-flight: on Windows the
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
docs/internals/script-runtime-practices.md	| Here-strings / growing content in MSYS bash (historical: Windows is unsupported) | Temp file or case-membership once content can exceed ~64 KiB, never a herestring. | A herestring ≥ 64 KiB wedges MSYS bash forever. |
docs/internals/script-runtime-practices.md	## 2. What it costs — MSYS spawn economics
docs/internals/script-runtime-practices.md	> Historical: measured on the Windows MSYS host, which is no longer supported.
docs/internals/stuck-playbook.md	never-delivering stdin pipe (the arm-resume/schtasks shape). The silent no-op —
docs/internals/testing.md	`ubuntu-latest` (the required, gating worker on every push/PR). Windows is
docs/internals/testing.md	nightly and no manual dispatch of `ci.yml` runs a Windows or macOS shard. Running the
docs/internals/testing.md	macOS is verified by the cadence above (Windows is dropped); nothing else
docs/internals/validation-gates.md	   critics made more trouble than they were worth — gptoss+kimi were
docs/internals/worker-spawn-matrix.md	- `scripts/telegram/phi-egress-guard.ts` (renamed from `glm-guard.ts`)
docs/internals/worker-spawn-matrix.md	| **Hermes one-shot via `scripts/hermes/invoke.sh` / `dispatch-trusted.sh`** | `invoke.sh` runs in caller's current directory; no worktree creation. Isolation depends on caller creating/choosing a worktree first. | `invoke.sh` uses Hermes with default `todo` toolset unless `--toolsets` opts in. `dispatch-trusted.sh` sets `HERMES_EXTERNAL_WRITES_OK=1` and defaults to `--profile himmel_agent`; `parity_guard.py` remains the fence and fail-closes external writes unless the engine is trusted. | **Yes — LIVE-PROVEN** (2026-07-07 session 11): `invoke.sh --model qwen3-coder-plus` routed to the Alibaba provider (model self-identified) while the unflagged default stayed `gpt-5.5`/openai-codex — two providers from two dispatches on the same surface. Failure mode is loud, not silent: an alias that does not resolve (observed: `qwen-flash`) falls through to the DEFAULT provider, which rejects the unknown model name with HTTP 400. `--profile` selects profile; `--toolsets` selects toolsets. | Optional `--log <path>` tees stdout/stderr. Hermes owns its normal session store; exact one-shot transcript path was not verified in repo files. | `dispatch-trusted.sh` allows trusted-engine external writes through `parity_guard.py`; push/PR still require operator authorization by higher-level policy. GLM/z.ai signals override the opt-in and are refused. | One-shot uses `-z` / yolo-style auto-approval in `invoke.sh`; therefore the default toolset is intentionally `todo` to avoid unattended terminal/browser/fs access unless a caller opts in. | Exit code is Hermes' return code, UNLESS the watchdog fires: `invoke.sh` wall-clock timeboxes (`HERMES_INVOKE_TIMEOUT`, default 1800s) and kills the process tree (rc 124), and separately aborts early (rc 125) on `PARITY_GUARD_DENY_ESCALATE_N` (default 3) identical `parity_guard` denies in a row — a DENY is not terminal to hermes upstream. Optional log file. |
docs/internals/worker-spawn-matrix.md	| **Codex worker / Codex lane surfaces** | Codex itself uses the caller workspace. Branch provenance convention is `codex/<slug>` per `docs/internals/harness-compat.md`; dedicated worktree creation is outside the codex supervision scripts read here. | Codex direct guard path is `.codex/hooks.json` -> `.codex/run-hook.{sh,cmd}` -> adapter -> native guard scripts per `harness-compat.md` / `lane-parity.md`. `scripts/codex/*` adds observability/supervision, not the primary guard fence. | **UNVERIFIED in repo files read.** Codex model selection surface is not described in the inspected `scripts/codex/*` supervision scripts. | Codex session rollouts live under `$CODEX_HOME/sessions/rollout-*.jsonl`; startup warnings in `$CODEX_HOME/logs_2.sqlite`. Codex companion job state lives under `$CLAUDE_PLUGIN_DATA/state/<slug>-<hash>/state.json` or fallbacks documented in `companion-liveness.sh`. | `lane-parity.md` marks `codex-direct` write-authority / external-write e2e proof as `GAP`; docs say native block hooks are reached through adapter, but codex external-write through-adapter proof remains missing. | `harness-compat.md` says Codex hooks block by stdout JSON `permissionDecision:"deny"`, not Claude exit 2; the adapter translates. Interactive permission-window parity is **UNVERIFIED** here and is a known open item. | `startup-health.sh` reports degraded startup signals: ignored hooks, skill/plugin prompt truncation, oversized `_where-are-we`. `companion-liveness.sh` flags queued/running jobs with no live runner. `reap-mcp-fleet.{sh,ps1}` reports/reaps orphaned Windows MCP fleet processes. |
docs/internals/worker-spawn-matrix.md	write (`pwsh Set-Content`) went through — the fix for such gaps is structural
docs/internals/enforcement.md	> **Platform tier:** Windows is dropped (HIMMEL-5729): no Windows host is
docs/internals/enforcement.md	> supported or tested. A Windows, PowerShell or Git Bash note below describes
docs/internals/enforcement.md	`fedora`, `arch`, `wsl`, `posix`, `gitbash`, `git-bash`, `powershell`,
docs/internals/enforcement.md	external lane (the GLM fallback was removed, HIMMEL-7481). No suitable lane, an unrunnable
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
docs/internals/lane-calibration.md	| `glm` — GLM lane | impl | — | — | — | removed: dropped (HIMMEL-1967), registry row and dispatcher deleted (HIMMEL-7909, HIMMEL-7481) |
docs/hermes-runbook.md	closed the Codex/GPT-5.5 "should be 1M" report as **not a bug**: live
docs/hermes-runbook.md	`openai-codex` reports and enforces `gpt-5.5` at `272000` tokens, while direct
docs/hermes-runbook.md	OpenAI API `gpt-5.5` can resolve around `1050000`. Pinning Codex to 1M would
docs/hermes-runbook.md	- `himmel_agent` main tier: `openai-codex` + `gpt-5.5` was a **272K Codex
docs/hermes-runbook.md	print(get_model_context_length('glm-5.2[1m]', provider='custom',
docs/setup/footprint.md	| The personal or medical vault you declare, so local guards keep it away from cloud backends | `~/.config/claude-glm/phi-roots` | user | himmel | Not removed yet: uninstall leaves these lines in place | `phi-roots` |
docs/setup/install.md	> **Windows is not supported** (HIMMEL-5729). himmel runs on Linux and macOS.
docs/setup/install.md	      { "matcher": "Bash|PowerShell|Read|Grep",
docs/setup/new-machine.md	| **Not supported** | Windows, WSL included | Dropped (HIMMEL-5729). |
docs/setup/new-machine.md	- `cygpath` (Windows-only path translation) → `scripts/handover/arm-resume.sh` and `scripts/lib/qmd-bin.sh` (junction creation); falls back to the unconverted path when absent.
docs/setup/new-machine.md	   worktree-and-git-common-dir, Windows-drive-relative, and Windows
docs/setup/new-machine.md	in `~/.config/claude-glm/phi-roots` (the harness-wide PHI config directory; the
docs/setup/new-machine.md	name outlived the GLM lane, HIMMEL-7898) or `~/.config/claude-codex/phi-roots`;
docs/setup/operator-profile-tbd-delta.md	| 10 | Lane readiness gates (`passesRequired` probation counters) and the full dormant-lane roster (opt-in env names) | Direct read of `scripts/lanes/lanes.json`'s `readiness`/`dormant` fields (`delta.lanes.readinessGates`, `dormantLanes`) | The wizard offers only the 4 wizard-askable lane ids (`ollama-local`, `copilot-cli`, `codex-exec`, `hermes-oneshot`); it never surfaces readiness-gate progress or the dormant-lane roster (`glm`, `openrouter-claude`) | ticketed: HIMMEL-2330 |
docs/tool-adoption/lane-adoption-playbook.md	example this playbook generalizes: each axis below is a knob GLM's rollout tripped over,
docs/tool-adoption/lane-adoption-playbook.md	*config/code knob* the measurement feeds. Where the axis has GLM evidence
docs/tool-adoption/lane-adoption-playbook.md	**GLM evidence:** `glm-5.2[1m]` measured **~205s / 23KB** response on a real
docs/tool-adoption/lane-adoption-playbook.md	GLM (`CHANGELOG.md`: "raise CRITIC_TIMEOUT_SECS default 150
docs/tool-adoption/lane-adoption-playbook.md	real and grounded (`scripts/cr/critic-panel.sh`), but the GLM
docs/tool-adoption/lane-adoption-playbook.md	**GLM evidence:** without an explicit window, Claude Code assumes its ~200k
docs/tool-adoption/lane-adoption-playbook.md	`CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000` for the `[1m]` GLM variant fixed it.
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
docs/tool-adoption/lane-adoption-playbook.md	needed. The GLM onboarding (the GLM lane was later removed, HIMMEL-1967, HIMMEL-7481) is the worked
docs/tool-adoption/lane-adoption-playbook.md	  (`docs/tooling-catalog.md` `claude-codex` section). The removed GLM lane
docs/tool-adoption/lane-adoption-playbook.md	  (`glm-5.2[1m]` + 1000000, or `glm-5.2` + 200000).
docs/tool-adoption/lane-adoption-playbook.md	ruling (2026-08-07): **glm gated at 10 consecutive passes** (the lane has since been removed; down since the
docs/tooling-catalog.md	leftover of the dropped Windows support (HIMMEL-5729) and is never read. A cadence copied between stations leaves a dormant,
docs/tooling-catalog.md	dropped Windows support, HIMMEL-5729, never fires on Linux or macOS) and `default_vault` (honors `LUNA_VAULT_PATH` first — the path
docs/tooling-catalog.md	<a id="claude-glm"></a>
docs/tooling-catalog.md	`claude-sonnet-5` when the proxy serves it (cli-proxy-api's claude provider, OAuth
docs/tooling-catalog.md	classifier and substitutes `claude-sonnet-5`). The main, Haiku, Opus and subagent
docs/tooling-catalog.md	choice, not a hard ceiling — the real backend window for gpt-5.6-sol was
docs/tooling-catalog.md	   attached returned `HTTP 400 unknown provider for model gpt-5.6-sol[1m]`
docs/tooling-catalog.md	bun scripts/telegram/spawn-claudex.ts "<prompt>" [--cwd <dir>] [--name <slug>] [--branch <existing>] [--timeout-mins <n>] [--permission-mode <mode>] [--effort low|medium|high|xhigh] [--model gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna] [--force]
docs/tooling-catalog.md	**Model tier:** `--model` is optional and selects the GPT-5.6
docs/tooling-catalog.md	`gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`; anything else is a parse-time
docs/tooling-catalog.md	  `--backend kimi` (moonshot) is retired — operator ruling, there is no kimi backend — so it fails closed on luna corpora as an unclassified provider).
docs/tooling-catalog.md	  staggered) is now **weekly**, on the **`claude-cli`** backend (kimi/moonshot is retired, operator ruling; claude-cli is the
docs/tooling-catalog.md	  subscription) — the original credential gate (kimi ->
docs/tooling-catalog.md	  `MOONSHOT_API_KEY`) no longer applies now that kimi is retired, though the
docs/tooling-catalog.md	- `scripts/cr/critic-panel.sh` + `scripts/cr/critics.json` — NIM critic panel (roster defined in `critics.json`). **`critics.json` currently holds ONE row — `codex`/`gpt-6.1-sol`, tier `paid` — and NO free critics.** The free lane was **removed deliberately** — it made more trouble than it was worth: gptoss + kimi dropped 2026-07-03 (operator decision, 12%/13% ledger agreed-rate — noise), and the surviving qwen3coder anchor kept erroring rc=1. Paid-by-default is the intended posture, not drift. So `/pr-check` **auto-runs the PAID codex anchor by default** (~2min, bounded by the 240 s per-member timeout): an unset `CR_PROFILE` **AND** unset `CRITIC_PANEL_TIERS` resolve to tier filter `free` (`CRITIC_PANEL_TIERS` is the low-level override, honored ONLY when `CR_PROFILE` is unset), which matches zero rows, so the panel falls back to the paid anchor — **spending the OpenAI subscription usage budget on any default run that actually runs the panel** — skipped, and therefore free, on an empty diff or `CR_PROFILE=none` (operator decision: accepted). Note this fallback also bypasses the triviality gate, which only fires when `paid` is already IN the tier filter. `CR_PROFILE=none` = instant claude-only (skip panel). `CR_PROFILE=thorough` = adds the `thorough` tier (currently EMPTY — kept for future heavier critics). `CR_PROFILE=paid` / `free,paid` = the paid codex critic. Any other value is the tier filter verbatim. **`CR_PROFILE` is authoritative:** `/pr-check` loads it from `.env` and the panel derives its tiers from it directly — it wins over the low-level `CRITIC_PANEL_TIERS` override (honored only when `CR_PROFILE` is unset). This closed a drift where a run hand-scoped the panel to free-only and silently dropped the paid critic. Retired the gemini-only CR lane. Per-member hang protection via `CRITIC_TIMEOUT_SECS` — default **240 s**, which is ALSO the fallback when the supplied value is non-numeric or ≤0 (the panel warns and uses 240 rather than failing). It was raised from 150 s after codex + qwen3coder were seen clipping at 150 s. It needs the `timeout` binary, but does not *require* it: when `timeout` is absent the panel prints "per-member hang protection disabled" and runs each member **unbounded**.
docs/tooling-catalog.md	<a id="claude-glm-scriptsclaude-glm"></a>
docs/tooling-catalog.md	| `CODEX_CONTEXT_WINDOW` | `272000` by default → `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. Without it Claude Code assumes its ~200k default for the unrecognized `gpt-6.1-sol` slug and compacts early. The window was measured on gpt-5.6, not yet re-measured for gpt-6.1: gpt-5.6's real window is **~372k** (95% effective ~353k, [openai/codex#32486](https://github.com/openai/codex/issues/32486)); **272k is the 2× pricing cliff, NOT a hard ceiling** — input past 272k bills 2× input / 1.5× output. `272000` is the cost-optimal default (compact at the cliff); raise to `353000` to use the full window at 2× cost past 272k. |
docs/tooling-catalog.md	2. **The `[1m]` model-name suffix** — the convention the removed GLM lane
docs/tooling-catalog.md	<a id="spawn-glm"></a>
docs/tooling-catalog.md	<a id="spawn-glm-scriptstelegramspawn-glmts"></a>
docs/internals/lane-parity.md	`block-worker-write-fence.sh` is not one of the six deny-guards above. Its GLM
docs/internals/lane-parity.md	**GLM-engine write-fence vs the retired GLM tail of `scripts/hooks/block-worker-write-fence.sh`.**
docs/internals/lane-parity.md	the retired GLM tail of `block-worker-write-fence.sh`. So an MCP tool call invokes the guard and is
docs/internals/lane-parity.md	| `block-rogue-claude-schedule` | `TERMINAL_DESTRUCTIVE` blocks `schtasks` (and `taskkill`/`shutdown`/`reg`/`shutdown`), the scheduler-mutation class that arms a rogue `claude` schedule. The claude-CLI-specific System32-cwd anti-trap is a launch-path check with no hermes analog -- hermes does not arm the `claude` CLI. | `present` (scheduler vector fenced; the System32-cwd trap is `n/a-for-runtime`) |
docs/internals/lane-parity.md	| write-authority / external-write-fence (cross-lane dimension) | The engine-gated write-fence landed: `terminal_external_write_reason` refuses `git push` (plain, not just `--force`), git remote-URL / `config ...url` rewrite, `gh` PR-mutations (carve-out: `gh issue *` + `gh pr view/diff/checks/status/list` + `gh run view/list/watch`), and network CLIs (`curl`/`wget`/`iwr`/`irm`). `_external_writes_allowed()` is fail-closed: refused unless `HERMES_EXTERNAL_WRITES_OK=1` AND no `api.z.ai` / `HERMES_ENGINE=glm*` untrusted signal. Proved by `test-parity-guard.sh` (push / remote-url / `gh pr create` / `curl` refused; carve-outs + trust opt-in allowed; z.ai + `HERMES_ENGINE=glm` override the opt-in). | `present` |
docs/internals/lane-parity.md	> dormancy status for impl lanes (claudex is live; hermes-oneshot and codex-exec are dormant; the GLM lane was removed, HIMMEL-7481) lives in `scripts/lanes/lanes.json` /
docs/internals/lane-parity.md	**GLM (removed).** The GLM lane was reachable by three paths, each proven
docs/internals/lane-parity.md	| hermes-main (DEFAULT; engine gpt-6.1-sol; GLM removed) | `parity_guard` push/PR fence -- `tested:scripts/hermes/test-parity-guard.sh` (write-fence; the CC hook does NOT fire under hermes, parity_guard is the sole fence). The other deny-guards are enforced by parity_guard too (all `present`). |
docs/internals/lane-parity.md	| hermes-main (DEFAULT; engine gpt-6.1-sol; GLM removed) | `AGENTS.md (loaded)` (`tested:scripts/hermes/test-agents-reach.sh`) | `tested:scripts/hermes/test-parity-guard.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
docs/internals/lane-parity.md	- **hermes-main (DEFAULT; engine gpt-6.1-sol; GLM removed).** himmel's CC
docs/internals/lane-parity.md	engines (gpt-6.1-sol + GLM, removed as a lane but still fenced) the `himmel_agent` profile is pointed
docs/configuration.md	dormant lane's opt-in). The GLM lane was removed, registry row included
EOF
ALLOW="${ALLOW%$'\n'}"

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

# No tracked shell or JS launcher calls pwsh or powershell. A
# non-comment line counts when it runs the binary with a PowerShell flag or
# passes its name to a spawn/exec call. PWSH_ALLOW lists the files that keep
# such a line on purpose: negative fixtures that feed the string to a guard
# and this file's own samples. An entry whose
# file no longer carries a call fails, so the list only shrinks.
PWSH_CALL=$'(^|[^A-Za-z0-9_.-])["\']?(pwsh|powershell)(\\.exe)?["\']?[[:space:]]+(-[A-Za-z]+([[:space:]]|$)|[^[:space:]]*\\.ps1)|(spawn|spawnSync|exec|execSync|execFile|execFileSync)\\([[:space:]]*.(pwsh|powershell)(\\.exe)?.[,)]'
# The last two entries are Windows-only test branches kept until the win32
# branch sweep removes them.
PWSH_ALLOW='scripts/cr/test-cr-guarded-closure.sh
scripts/docs/test-docs-dropped-terms.sh
scripts/hermes/test-parity-guard.sh
scripts/hooks/test-block-bare-qmd-query.sh
scripts/hooks/test-block-destructive-commands-a.sh
scripts/hooks/test-block-edit-live-settings.sh
scripts/handover/test-merge-on-green.sh
scripts/test-clean-garden-accounting.sh'

# pwsh_calls ROOT: reads relative paths on stdin, prints path:line:text per call;
# a file grep cannot read is printed as path:0 so it fails the check, not passes it.
pwsh_calls() {
  while IFS= read -r f; do
    hits=$(grep -n -i -E "$PWSH_CALL" "$1/$f" 2> /dev/null)
    [ $? -le 1 ] || echo "$f:0:unreadable or matcher error"
    [ -z "$hits" ] || printf '%s\n' "$hits" | grep -v -E '^[0-9]+:[[:space:]]*(#|//)' | sed "s#^#$f:#"
  done
}

mkdir "$tmp/fx"
printf '#!/usr/bin/env bash\npwsh -File ./install.ps1\n/usr/bin/pwsh -File x\n"pwsh" -File x\npwsh install.ps1\npwsh -NoLogo -File x.ps1\n' > "$tmp/fx/launch.sh"
printf "spawn('powershell.exe', ['-File', 'x.ps1']);\n" > "$tmp/fx/launch.mjs"
printf '# pwsh -File old.ps1\nPowerShell is dropped.\n' > "$tmp/fx/clean.sh"
fx_hits=$(printf '%s\n' launch.sh launch.mjs clean.sh missing.sh | pwsh_calls "$tmp/fx")
case $fx_hits in *launch.sh:2:*) ok "no-pwsh-invocation flags a launcher running pwsh -File" ;; *) bad "no-pwsh-invocation misses pwsh -File in a launcher" ;; esac
case $fx_hits in *launch.sh:3:*launch.sh:4:*launch.sh:5:*launch.sh:6:*) ok "no-pwsh-invocation flags a pathed, a quoted, a script-argument and a flag-first pwsh call" ;; *) bad "no-pwsh-invocation misses a pathed, quoted, script-argument or flag-first pwsh call" ;; esac
case $fx_hits in *missing.sh:0:*) ok "no-pwsh-invocation fails on a file it cannot read" ;; *) bad "no-pwsh-invocation passes a file it cannot read" ;; esac
case $fx_hits in *launch.mjs:1:*) ok "no-pwsh-invocation flags a spawn of powershell" ;; *) bad "no-pwsh-invocation misses a spawn of powershell" ;; esac
case $fx_hits in *clean.sh*) bad "no-pwsh-invocation flags a comment or prose mention" ;; *) ok "no-pwsh-invocation ignores comments and prose" ;; esac

git -C "$ROOT" ls-files '*.sh' '*.js' '*.mjs' '*.cjs' '*.ts' > "$tmp/tracked" || : > "$tmp/tracked"
grep -v -x -F "$PWSH_ALLOW" "$tmp/tracked" > "$tmp/launchers"
pwsh_found=$(pwsh_calls "$ROOT" < "$tmp/launchers")
if [ ! -s "$tmp/launchers" ]; then
  bad "no tracked launcher list: git ls-files failed or found nothing"
elif [ -n "$pwsh_found" ]; then
  printf '%s\n' "$pwsh_found"
  bad "a tracked launcher calls pwsh or powershell (listed above)"
else
  ok "no tracked launcher calls pwsh or powershell"
fi
while IFS= read -r f; do
  [ -n "$(printf '%s\n' "$f" | pwsh_calls "$ROOT")" ] || bad "PWSH_ALLOW names $f, which carries no pwsh call: remove it"
done <<< "$PWSH_ALLOW"

echo "# pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
