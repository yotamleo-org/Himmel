# Lane-parity index

This page shows, for each worker lane (a runtime himmel can hand work to),
which of himmel's guardrails reach that lane and which test proves it. It
extends [`harness-compat.md`](harness-compat.md) lane by lane. The guard set
comes from the hooks listed in [`enforcement.md`](enforcement.md). Two suites
read this page: `scripts/parity/test-guard-conformance.sh` parses the
deny-guard x lane table, and `scripts/parity/test-ws5-invariants.sh` checks
that the copilot / cursor rows stay `deferred`.

> **Note:** this index records compatibility/parity, not current routing —
> dormancy status for impl lanes (claudex is live; hermes-oneshot and codex-exec are dormant; the GLM lane was removed) lives in `scripts/lanes/lanes.json` /
> [`lane-calibration.md`](lane-calibration.md), not here.

## Doctrine

**Compatibility doctrine.** Every worker lane runs under the FULL himmel setup
-- the same deny-guard guardrails, the same vault/memory substrate, the same
ship-flow -- so workers are interchangeable and their outputs land in
compatible shapes. "Workers run the full setup" is asserted in prose today;
this index makes it drift loudly instead of silently.

**One ruleset, N adapted projections.** Root `CLAUDE.md` is the single source.
Each runtime reads an ADAPTED projection: Claude Code reads `CLAUDE.md` native;
Codex / Cursor / Copilot read the generated
`AGENTS.md` (freshness-gated by `agents-md-fresh`); hermes reads `SOUL.md`
(identity) plus a per-context `AGENTS.md` / `CLAUDE.md`. The projections are
not all kept in lockstep today; the two tested columns (rule-projection
freshness, guard-firing pointers) are where the drift becomes visible.

**The index shows the merge-trust verdict; it is NOT the trust gate.** The
merge-trust column is a view of the verdict the lane gate in
[`validation-gates.md`](validation-gates.md) gives. This index only checks
that the column exists for every non-native lane. "Row green" is a composite,
not a trust ruling.

**GLM (removed).** The GLM lane was reachable by three paths, each proven
separately: the two Claude Code paths (the backend swapped; the native
PreToolUse hooks) and a hermes path (fenced by `parity_guard.py`, since the CC
hooks do not load under hermes). Its dispatcher, launcher and registry row are
deleted, as is its classifier tail in the worker write
fence, so the two Claude Code paths have no row or column below.
`parity_guard.py` still refuses that engine as untrusted.

## Invariant guard set

The load-bearing distinction: of the PreToolUse and PostToolUse hooks, only
the DENY-guards are parity-relevant: they are the hard blocks a non-native lane must replicate.
The non-deny hooks are EXCLUDED from the per-lane map, because enumerating them
per lane produces spurious `GAP`s (e.g. "codex lacks `auto-arm-on-cap`") that
swamp the real gaps.

**Deny-guards a non-native lane must replicate** (6 PreToolUse hooks + the
git-hook gates):

- `block-edit-on-main`
- `block-read-secrets`
- `block-backend-tier`
- `block-docker-privesc`
- `block-rogue-claude-schedule`
- `block-merged-pr-commit`
- the pre-commit / pre-push git gates (harness-independent -- git runs them on
  every lane that commits): `agents-md-fresh`, `check-platforms-tested`,
  `check-security-reviewed`, `doc-guard`, `gitleaks`, and the rest of the
  `.pre-commit-config.yaml` gate set.

**Non-deny hooks -- NOT mapped per-lane.** The four below are the ones most
often mistaken for deny-guards:

- `auto-approve-safe-bash` -- an auto-APPROVER (a fail-open permission helper),
  not a deny-guard.
- `auto-arm-on-cap` -- a fail-open cap watchdog; no non-native analog.
- `check-cr-marker-on-pr-create` -- a PR-time marker check, not a runtime deny.
- `auto-arm-on-subagent-cap` (PostToolUse) -- a cap detector, not a deny-guard.

### Write-authority / external-write fence (a cross-lane dimension, not a deny-guard hook)

Write-authority is the load-bearing parity dimension, but
`block-worker-write-fence.sh` is not one of the six deny-guards above. Its GLM
push / network / `mcp__*` classifier tail was deleted; it now
holds only the pin-dir and anchor-tamper fences. It is recorded here as its own
dimension row so every write-fence cell sits in a real row (no home-less cell).

| Lane | Write-authority / external-write fence |
|---|---|
| main-claude | auto-mode classifier |
| codex-direct | `tested:scripts/hooks/test-block-terminal-write-fence.sh` -- the terminal write/push/network fence (codex-lane classifier substitute), e2e-proved through the adapter (`scripts/hooks/test-codex-adapter-e2e.sh`). The Edit/Write patch path is fenced by `block-edit-on-main.sh` via the adapter. |
| antigravity-t3 | `tested:scripts/hooks/test-block-terminal-write-fence.sh` `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` -- terminal write/push/network fence enforced with all `*_OK` overrides stripped; `edit_file`/`write_file` fenced by `block-edit-on-main.sh` plus both-home and `.agents/**` self-protect through `scripts/hooks/antigravity-hook-adapter.sh`. T3 MCP: the same tool policy as the Claude and Codex lanes (decision 1306): the shared chain (`mcp-policy.sh`, `block-backend-tier.sh`, `guard-t3-thread-tools.sh`, `peer-taint-gate.sh`) decides each tool, with no lane-only allowlist; `tested:scripts/t3/test-t3-guard-conformance.sh` asserts one verdict per tool across the three lanes. |
| hermes-main (DEFAULT; engine gpt-6.1-sol; GLM removed) | `parity_guard` push/PR fence -- `tested:scripts/hermes/test-parity-guard.sh` (write-fence; the CC hook does NOT fire under hermes, parity_guard is the sole fence). The other deny-guards are enforced by parity_guard too (all `present`). |
| copilot / cursor | `deferred` |

## Token vocabulary (machine-readable; defined once)

Every index cell carries a token from this FIXED vocabulary.
`test-guard-conformance.sh` parses these literals -- do not introduce synonyms.

- `tested:<relative/path>` -- a real proving test/script path (the two tested
  columns: rule projection, guardrail firing).
- `GAP` -- no proving test exists for this cell.
- `pending:<TaskN>` -- the verdict waits on a numbered follow-up task and is
  not yet resolved. No cell carries it today.
- `asserted-only` -- a doc-asserted column (skills/cmds, vault/memory), not
  tested.
- `gate-owned` -- the merge-trust column, filled by the lane gate in
  [`validation-gates.md`](validation-gates.md), not by this index.
- `native` -- the lane runs the native Claude Code ruleset/hooks directly (the
  baseline).
- `native,no-seed` -- the native ruleset is read from LIVE config (no seeded
  copy, no drift dimension).
- `deferred` -- the lane is soft-deferred (no free usage tier); the row is
  present, not active.

Column status: **rule projection** + **guardrail firing** are the two TESTED
columns (cells carry `tested:<path>` / `GAP` / `pending:`); **skills/cmds** +
**vault/memory** = `asserted-only`; **merge-trust** = `gate-owned`. A row is
`tested`-green only when every deny-guard cell in its row of the guard x lane
sub-table below is `tested:<path>` -- no `GAP`, no `pending:`.

## Lane-parity index

| Lane | Rule projection | Guardrail firing | Skills/cmds | Vault/memory | Merge-trust |
|---|---|---|---|---|---|
| main-claude | `native` (CLAUDE.md) | `native` (hooks + classifier) | `native` | `native` | `native` (baseline) |
| codex-direct | `tested:scripts/agents-md/generate.mjs` (AGENTS.md gen + gated) | `tested:scripts/hooks/test-codex-run-hook.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
| antigravity-t3 | `tested:scripts/agents-md/generate.mjs` (AGENTS.md gen + gated) | `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
| hermes-main (DEFAULT; engine gpt-6.1-sol; GLM removed) | `AGENTS.md (loaded)` (`tested:scripts/hermes/test-agents-reach.sh`) | `tested:scripts/hermes/test-parity-guard.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
| copilot / cursor | `deferred` | `deferred` | `deferred` | `deferred` | `deferred` |

Notes on the guardrail-firing cells. codex-direct reaches the native block-* hooks THROUGH the
`.codex/hooks.json` adapter (the exit-2 to deny translation proved by
`test-codex-run-hook.sh`); the per-guard codex resolution is enumerated in the
guard x lane sub-table below. hermes-main's `parity_guard` fences both
engines; its write-fence is in the write-authority row above
(`tested:scripts/hermes/test-parity-guard.sh`), and the other deny-guards are
in the hermes table at the end of this page.

**claudex (`scripts/claude-codex`).** Claude Code with its backend swapped to
the Codex subscription through a self-hosted CLIProxyAPI that serves an
Anthropic-compatible endpoint. Every PreToolUse hook fires natively, so its guard posture is the native column. It has
no row of its own in this index yet.

## Guard-firing conformance sub-table (deny-guard x lane)

The top-level index carries ONE guardrail-firing cell per lane; this
sub-table expands each non-native lane's proof per invariant deny-guard (the
six PreToolUse deny-hooks plus the cross-lane write-authority dimension) into
a real proving test or `GAP`. `scripts/parity/test-guard-conformance.sh`
parses this table by its HTML-comment anchor, not its heading text, so the
anchor is the stable parse key.

Cells use the token vocabulary above (`tested:<path>` / `GAP` /
`pending:<TaskN>`). A lane column is **`tested`-green** iff EVERY cell in it --
across all six deny-guards AND the write-authority / external-write-fence
dimension row -- is `tested:<path>` (no `GAP`, no `pending:`). The write-fence
row counts toward `tested`-green because write-authority is the load-bearing
parity dimension: a lane is fully guard-tested only once its write-fence is
also tested. All six deny-guards plus the write-fence are PRESENT under
hermes, so the hermes-main column is `tested`-green.

<!-- BEGIN guard-lane-conformance -->

| deny-guard | codex-direct | antigravity-t3 | hermes-main (gpt-6.1-sol) |
|---|---|---|---|
| block-edit-on-main | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-edit-on-main.sh` | `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` `tested:scripts/hooks/test-block-edit-on-main.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-read-secrets | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-read-secrets.sh` `tested:scripts/hooks/test-codex-adapter-e2e.sh` | `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` `tested:scripts/hooks/test-block-read-secrets.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-backend-tier | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-backend-tier.sh` | `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` `tested:scripts/hooks/test-block-backend-tier.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-docker-privesc | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-docker-privesc.sh` | `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` `tested:scripts/hooks/test-block-docker-privesc.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-rogue-claude-schedule | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-rogue-claude-schedule.sh` | `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` `tested:scripts/hooks/test-block-rogue-claude-schedule.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-merged-pr-commit | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-merged-pr-commit.sh` | `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` `tested:scripts/hooks/test-block-merged-pr-commit.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| write-authority / external-write-fence (cross-lane dimension, NOT a CC PreToolUse hook) | `tested:scripts/hooks/test-block-terminal-write-fence.sh` `tested:scripts/hooks/test-codex-adapter-e2e.sh` | `tested:scripts/hooks/test-block-terminal-write-fence.sh` `tested:scripts/hooks/test-antigravity-adapter-e2e.sh` | `tested:scripts/hermes/test-parity-guard.sh` |

<!-- END guard-lane-conformance -->

Notes on the cells:

- **codex-direct.** Each deny-guard is proved by the codex proving PAIR --
  `tested:scripts/hooks/test-codex-run-hook.sh` (the `.codex/hooks.json`
  adapter's exit-2 to `deny` translation) PLUS the NATIVE
  `tested:scripts/hooks/test-block-<guard>.sh` the adapter reaches (all six
  native fixtures exist). `scripts/hooks/test-codex-adapter-e2e.sh` is the
  through-adapter END-TO-END fixture: it drives
  `.codex/codex-hook-adapter.sh` against the REAL guardrails
  (`CLAUDE_PROJECT_DIR` = the checkout) and asserts the JSON `deny` lands for a
  secret-read (through `block-read-secrets.sh`) AND an external-write (through
  `block-terminal-write-fence.sh`). `.codex/hooks.json` wires
  `block-edit-on-main.sh` on the Edit|Write matcher, which covers the PATCH
  path; the TERMINAL path (a shell command that writes a file, pushes, or hits
  the network) is covered by `block-terminal-write-fence.sh`, because codex has
  NO auto-mode classifier (deterministic-guards-only). That hook is the
  codex-lane classifier substitute (external-write class fail-closed behind
  `CODEX_EXTERNAL_WRITES_OK`; a write-on-main class honouring
  `.single-writer`), unit-tested by
  `scripts/hooks/test-block-terminal-write-fence.sh` and e2e-proved through the
  adapter. The codex-direct column is `tested`-green.
- **hermes-main (DEFAULT; engine gpt-6.1-sol; GLM removed).** himmel's CC
  PreToolUse hooks do NOT load under hermes, so `parity_guard.py` is the sole
  fence; both engines are exercised by
  `tested:scripts/hermes/test-parity-guard.sh`. The write-fence in
  `parity_guard.py` refuses plain push / remote-URL rewrite / gh PR-mutation /
  network CLIs, fail-closed on an untrusted or unknown engine. The other
  deny-guards (edit-on-main, docker-privesc, merged-PR-commit, MCP-fence) are
  enforced there too, so the hermes-main column is `tested`-green.
- Any deny-guard with no lane proving test is `GAP` by construction.

## Web read per lane

Whether a lane can read a live page, and the fence on it. The walled-host
redirect and the peer-taint gate stay in force wherever a himmel hook runs.

| Lane | Web read today | Note |
|---|---|---|
| main-claude (workers, chiefs, repo agents) | WebFetch and WebSearch; every repo agent file names both on its `tools:` line | the project allow rule and the `Agent(web-fetch)` deny are owed to B15 (settings.json) |
| codex-direct | hosted `web_search`, cached, on by default | himmel sets nothing; live mode is the operator's `~/.codex/config.toml` choice |
| antigravity-t3 | `search_web` only | the `read_url_content` adapter arm is OPEN: its URL argument key is unread without a live thread; the adapter denies an unlisted tool |
| hermes-main | `web_search` and `web_extract` via the parity_guard allowlist | unchanged |
| copilot / cursor | `deferred`: none by design (`--deny-url "*"`) | a guarded bulk lane |

## T3 preview browser: the `previewBrowser` profile option

A session can drive T3's preview browser to check its own change when its
profile turns the option on. **Default: off** -- no shipped profile sets it.

- **No lane guard denies a preview tool.** The Claude, Codex and Antigravity
  guard chains (`guard-t3-thread-tools.sh`, `mcp-policy.sh`, the Antigravity
  adapter) all allow the `mcp__t3-code__preview_*` tools. All 14 are proved
  allowed on all three lanes by
  `tested:scripts/t3/test-t3-guard-conformance.sh` (the list is read from the
  registry, so a tool added there is checked on every lane) and the adapter
  path by `tested:scripts/hooks/test-antigravity-adapter-e2e.sh`. The option
  therefore tightens or relaxes nothing in a guard.
- **What the option does.** In `scripts/lanes/plugin-profiles.json`, a
  worker-shaped profile with `"previewBrowser": true` resolves with an
  `mcp__t3-code__<tool>` allow rule for each name in the registry's
  `previewBrowserTools`, so Claude does not prompt for them. A profile without
  it (every profile today) gets no such rule. `bare`, `readiness` and the
  chief and console profiles refuse it; the registry lint fails a non-boolean
  value, a profile that is not worker-shaped, or a registry with no tool list.
  Proved by `tested:scripts/lanes/tests/plugin-profiles.test.mjs`.
- **Tool list.** `preview_act`, `preview_close`, `preview_dialog`,
  `preview_evaluate`, `preview_list`, `preview_navigate`, `preview_open`,
  `preview_recording_start`, `preview_recording_stop`, `preview_resize`,
  `preview_set_appearance`, `preview_snapshot`, `preview_status`,
  `preview_wait_for`. They were read from the T3 server's own tool listing in
  its provider event log, not from a registration file, so a T3 release that
  adds or renames a preview tool needs this list updated.
- **Example: an e2e check through the preview.** Set `"previewBrowser": true`
  on the worker profile the e2e session launches under (for example
  `worker-e2e`), start it from a T3 thread, and have it call `preview_open`
  on the dev server URL, `preview_wait_for` the page, then `preview_snapshot`
  and quote the page read in its result.

## What `parity_guard.py` enforces under hermes (both engines)

The contract side of the index: for each invariant DENY-guard (the six
PreToolUse deny-hooks PLUS the cross-lane write-authority dimension), what
`scripts/hermes/assets/parity_guard.py` -- the SOLE fence under hermes, since
himmel's Claude Code PreToolUse hooks do NOT load there -- enforces, for BOTH
engines (gpt-6.1-sol + GLM, removed as a lane but still fenced) the `himmel_agent` profile is pointed
at. Tags: `present` (parity_guard enforces it), `n/a-for-runtime`
(Claude-Code-specific mechanics with no hermes analog), `GAP` (not enforced).

| Invariant deny-guard | parity_guard.py status (both engines) | Verdict |
|---|---|---|
| `block-read-secrets` | `SECRET_READ` regex on `read_file` / `search_files` (any arg key): `.env` / `.envrc` / `.ssh` / `id_rsa` / `.pem` / `.key` / `secrets.yaml` / channel tokens / `.git-credentials` / `hosts.yml` / `credentials.json`. PHI egress fence refuses reads under a `.salus` / `phi-roots` / `egress-denylist` root. | `present` |
| `block-rogue-claude-schedule` | `TERMINAL_DESTRUCTIVE` blocks `schtasks` (and `taskkill`/`shutdown`/`reg`/`shutdown`), the scheduler-mutation class that arms a rogue `claude` schedule. The claude-CLI-specific System32-cwd anti-trap is a launch-path check with no hermes analog -- hermes does not arm the `claude` CLI. | `present` (scheduler vector fenced; the System32-cwd trap is `n/a-for-runtime`) |
| write-authority / external-write-fence (cross-lane dimension) | The engine-gated write-fence landed: `terminal_external_write_reason` refuses `git push` (plain, not just `--force`), git remote-URL / `config ...url` rewrite, `gh` PR-mutations (carve-out: `gh issue *` + `gh pr view/diff/checks/status/list` + `gh run view/list/watch`), and network CLIs (`curl`/`wget`/`iwr`/`irm`). `_external_writes_allowed()` is fail-closed: refused unless `HERMES_EXTERNAL_WRITES_OK=1` AND no `api.z.ai` / `HERMES_ENGINE=glm*` untrusted signal. Proved by `test-parity-guard.sh` (push / remote-url / `gh pr create` / `curl` refused; carve-outs + trust opt-in allowed; z.ai + `HERMES_ENGINE=glm` override the opt-in). | `present` |
| `block-edit-on-main` | `_edit_on_main_reason` refuses a `write_file` / `patch` / `delete_file` into a repo whose checked-out branch is the default branch (main/master), and a terminal `git commit` there. Branch read cheaply from `.git/HEAD` (worktree/submodule `gitdir:` indirection). Honors the `.single-writer` opt-out; a worker's own `type/slug` branch commits freely (carve-out). `check_write_path` still blocks the guard / profile `config.yaml` / `SOUL.md` / Claude's home. | `present` (main-branch edit/commit lock ported) |
| `block-merged-pr-commit` | `_merged_pr_reason` queries the branch's merged-PR count via `gh` (GH_CMD-overridable) before a terminal `git commit` and refuses on >0. HYGIENE guard: fail-open on gh absent/errored/non-numeric; a fresh no-PR branch is allowed. | `present` (merged-PR-branch detection ported) |
| `block-docker-privesc` | `TERMINAL_DESTRUCTIVE` covers recursive delete / disk / scheduler / process / registry / force-push / `curl\|sh`; the `DOCKER_PRIVESC` regex adds `docker`/`podman` privesc shapes -- `--privileged`, `--pid host`, `--volumes-from`, root-equivalent `--cap-add`, the docker socket, root `--user`, and secret-bearing host-root bind mounts (`/` `/etc` `/root`). | `present` (container privesc block ported; ro/rw + system-dir nuance not modelled -- over-block is fail-safe) |
| `block-backend-tier` | `parity_guard`'s hook matcher (`wire_parity_guard.py MATCHER`, now `.*` -- it previously included `mcp__.*`) delivers every tool to the guard, and `main()` blanket-denies every `mcp__*` tool EXCEPT the read-only `qmd` KB carve-out (`mcp__plugin_qmd_qmd__*`) -- mirroring the deleted write-fence classifier tail of `block-worker-write-fence.sh`. MCP tool calls now invoke the guard and are fenced. | `present` (MCP fenced, qmd carve-out) |
| dispatch coverage (matcher) | hermes `fullmatch`es the `pre_tool_call` matcher against the tool name and that is its ONLY blocking event, so every tool the pattern missed was never judged. The hand-listed pattern left `execute_code`, `delegate_task`, `browser_*`, `skill_manage`, `process_manage`, `cronjob_manage`, `send_message` and the rest of the registry outside every fence above, and carried four dead terms (`delete_file`/`remove_file`/`move_file`/`rename_file` are `skill_manage` action values, not tools). The matcher is now `.*`; `parity_guard.classify_tool` gives every registry tool a class -- `code` tools (`execute_code`, `browser_exec`, `browser_cdp`, `cronjob_manage`, `process_manage`) get the terminal deny-guards run over their command text (literal-text scan; obfuscation is not caught), `skill_manage` an action allow-list plus the write-fence on its (batch) paths, `text_to_speech`/`desktop_project` the write-fence on their path arg, and every other known tool a secret/PHI-path scan of its non-prose args. An unclassified tool is refused fail-closed. No known tool is blanket-denied. The outbound tools (`send_message`, `ha_call_service`, ...) are NOT engine-fenced (operator decision). `test-hook-inventory.sh` statically scans the installed hermes registry and fails when a tool is undelivered or unclassified. | `present` (dispatch coverage proved against the installed registry) |

**GLM-engine write-fence vs the retired GLM tail of `scripts/hooks/block-worker-write-fence.sh`.**
The hermes runtime does not load that CC hook, so `parity_guard` is the sole
external-write fence for every engine on the `himmel_agent` profile. Compared
shape-by-shape against the deleted hook tail (the behavior spec): `git push` (plain),
`git remote set-url` / `config ...url`, the `gh` carve-out (`issue *` + PR/run
reads only), and the network-CLI set (`curl`/`wget`/`iwr`/`irm`) all match --
the terminal / file external-write shapes are at PARITY (present). The MCP
surface is fenced too: `wire_parity_guard.py`'s matcher is `.*` and
`parity_guard.main()` blanket-denies every `mcp__*` tool except the read-only
`qmd` KB carve-out (`mcp__plugin_qmd_qmd__*`), mirroring
the retired GLM tail of `block-worker-write-fence.sh`. So an MCP tool call invokes the guard and is
fenced on the default lane -- `block-backend-tier` is `present` above.

**Beyond the deny-guard set:** the unconditional PHI / data-egress fence fires
on EVERY engine on this cloud profile -- a `.salus`-marked path or a
configured `phi-roots` / `egress-denylist` root is refused for read / search /
write / delete (symlink/junction-safe via `realpath`, fail-closed on an
unreadable list). It is `present` and proved by `test-parity-guard.sh`; it is
not one of the six deny-guards, so it is not a parity GAP, just an additional
fence hermes carries.

## CLI lane parity: Claude Code, Codex CLI and Antigravity

The three command-line lanes are equals (operator, 2026-11-24; decision 1306, one
trust model). A session on any of them should allow or refuse the same call. This
table lists every capability once, with one cell per lane, so a difference is a
row that says why. `scripts/lanes/lane-parity-check.sh` reads it and fails when a
lane lacks a guard another lane has and the table records no reason; its suite is
`scripts/lanes/test-lane-parity-check.sh`.

Each lane cell is one of:

- `has` (a note may follow): the lane carries the capability.
- `structural: <reason>`: the lane cannot have it, because the CLI has no such tool
  or the session role never runs there.
- `gap-ticketed: <reason>`: the lane should have it, and the fix is a launcher, hook
  or adapter edit that rides its own ticket. The reason names the file and the
  change.

A `guard:<hook>.sh` row is also checked against the real wiring: the PreToolUse
entries of `.claude/settings.json` and the himmel-ops plugin `hooks.json` (Claude),
`.codex/hooks.json` (Codex), and the tool arms of
`scripts/hooks/antigravity-hook-adapter.sh` (Antigravity). `has` must be wired; a
recorded reason must not be wired; a hook wired on any lane must have a row. A
guard counts as wired on a lane when any hook entry or tool arm of that lane names
it in code (a comment does not count); the check does not tell which tool arms
carry it. The other rows are read by people.

<!-- BEGIN cli-lane-parity -->

| capability | claude | codex | antigravity |
|---|---|---|---|
| launcher | has: scripts/lanes/worker-claude-launcher.sh under headed-arm | has: the codex CLI with the himmel plugin set from scripts/codex/install-himmel-codex.sh; headless through scripts/codex/dispatch-codex-exec.sh | has: agy in a guarded T3 thread (lane antigravity-t3 in scripts/lanes/lanes.json); a headless agy call needs a headless-gemini-ok reason |
| role profile | has: scripts/lanes/plugin-profiles.json resolved to --settings and an MCP allowlist | gap-ticketed: no Codex consumer reads scripts/lanes/plugin-profiles.json: a launcher edit under scripts/codex/ owes a role profile | gap-ticketed: no Antigravity consumer reads scripts/lanes/plugin-profiles.json: one always-on rule in .agents/rules/himmel-lane.md serves every role |
| instruction projection | has: CLAUDE.md read natively | has: generated AGENTS.md, freshness-gated by agents-md-fresh | has: generated AGENTS.md plus .agents/rules/himmel-lane.md |
| hook wiring | has: .claude/settings.json and the himmel-ops plugin hooks.json | has: .codex/hooks.json through .codex/run-hook.sh | has: .agents/hooks.json through scripts/hooks/antigravity-hook-adapter.sh |
| deny bridge | has: a guard exits 2 to block | has: codex-hook-adapter.sh turns exit 2 into a JSON deny | has: the adapter emits a JSON deny and fails closed on error, timeout or a missing tool name |
| tool: shell | has: Bash | has: Bash matcher | has: run_command, with a self-protect check over .agents, the gemini config and the T3 provider home |
| tool: file read | has: Read and Grep | has: Read and Grep matcher | has: read_file |
| tool: file write | has: Edit, Write, MultiEdit, NotebookEdit | has: Edit, Write, MultiEdit, NotebookEdit, apply_patch | has: edit_file and write_file, with a self-protect check on the path |
| tool: subagent | has: the Agent tool behind the dispatch guards | has: an Agent PostToolUse hook (auto-arm-on-subagent-cap) | has: invoke_subagent behind peer-taint-gate; swarm, run_workflow, define_subagent, manage_subagents and manage_task are denied |
| mcp: allowlist | has: a per-profile mcpAllow, strict MCP config | has: servers in the user config behind the mcp__.* guard chain | has: the adapter admits graphify and t3-code only, every other server is denied |
| mcp: qmd | has: the qmd MCP server | has: the shared qmd daemon, added by the codex installer | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: the MCP allowlist (graphify, t3-code) refuses qmd; the run_command route scripts/lib/qmd-bounded.sh still works |
| web: search | has: WebSearch | has: hosted web_search, cached by default | has: search_web |
| web: fetch a URL | has: WebFetch | structural: the Codex CLI reads the web through hosted web_search only | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: the read_url_content arm is open, its URL argument key is unread without a live thread |
| skills | has: .claude/skills and the himmel-ops plugin skills | has: the himmel-ops plugin skills | has: the .agents/skills subset |
| `guard:allow-thread-resolve.sh` | has | structural: allow-only helper for Claude's permission prompt, it denies nothing | structural: allow-only helper for Claude's permission prompt, it denies nothing |
| `guard:approval-grant-check.sh` | has | structural: allow-only helper for Claude's permission prompt, it denies nothing | structural: allow-only helper for Claude's permission prompt, it denies nothing |
| `guard:auto-approve-safe-bash.sh` | has | has | structural: fail-open approver, not a deny-guard; the adapter allows a clean pass by default |
| `guard:auto-arm-on-cap.sh` | has | has | structural: watchdog on the Claude subscription cap, fail-open by design, no Antigravity analog |
| `guard:block-agent-native-egress.sh` | has | gap-ticketed: .codex/hooks.json: add block-agent-native-egress.sh to the mcp__.* chain | structural: MCP server agent-native is not on the adapter allowlist, which admits graphify and t3-code only |
| `guard:block-antigravity-read-fence.sh` | structural: fences the Antigravity home and oauth token, a path Claude Code does not have | structural: fences the Antigravity home and oauth token, a path Codex does not have | has |
| `guard:block-backend-tier.sh` | has | has | has |
| `guard:block-bank-lift-writes.sh` | has | has | has |
| `guard:block-bare-qmd-query.sh` | has | has | has |
| `guard:block-busy-loop.sh` | has | gap-ticketed: .codex/hooks.json: add block-busy-loop.sh to the Bash chain | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add block-busy-loop.sh to the run_command chain |
| `guard:block-chokepoint-env-prefix.sh` | has | gap-ticketed: .codex/hooks.json: add block-chokepoint-env-prefix.sh to the Bash chain | has |
| `guard:block-destructive-commands.sh` | has | has | has |
| `guard:block-docker-privesc.sh` | has | has | has |
| `guard:block-edit-live-settings.sh` | has | has | has |
| `guard:block-edit-on-main.sh` | has | has | has |
| `guard:block-fork-sync-pr.sh` | has | has | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add block-fork-sync-pr.sh to the run_command chain |
| `guard:block-git-stash.sh` | has | has | has |
| `guard:block-graphify-egress.sh` | has | gap-ticketed: .codex/hooks.json: add block-graphify-egress.sh to the Bash chain | has |
| `guard:block-himmel-config-writes.sh` | has | has | has |
| `guard:block-infra-destroy.sh` | has | has | has |
| `guard:block-jira-compound-write.sh` | has | gap-ticketed: .codex/hooks.json: add block-jira-compound-write.sh to the Bash chain | has |
| `guard:block-lesson-enforcement-writes.sh` | has | has | has |
| `guard:block-merged-pr-commit.sh` | has | has | has |
| `guard:block-read-secrets.sh` | has | has | has |
| `guard:block-rogue-claude-schedule.sh` | has | has | has |
| `guard:block-rogue-codex-exec.sh` | has | gap-ticketed: .codex/hooks.json: add block-rogue-codex-exec.sh to the Bash chain | has |
| `guard:block-station-load-test.sh` | has | gap-ticketed: .codex/hooks.json: add block-station-load-test.sh to the Bash chain | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add block-station-load-test.sh to the run_command chain |
| `guard:block-subagent-park.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:block-subagent-release-operator.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:block-t3code-unwatch-open-pr.sh` | has | has | has |
| `guard:block-tail-pipe-on-gates.sh` | has | gap-ticketed: .codex/hooks.json: add block-tail-pipe-on-gates.sh to the Bash chain | has |
| `guard:block-terminal-write-fence.sh` | structural: the auto-mode classifier fences external writes on the Claude lane | has | has |
| `guard:block-token-shaped-web-query.sh` | has | structural: no WebSearch or WebFetch tool call to match: Codex reads the web through hosted web_search only | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: the read_url_content arm is open, add the token-shape refusal when it lands |
| `guard:block-unresolved-cr-merge.sh` | has | gap-ticketed: .codex/hooks.json: add block-unresolved-cr-merge.sh to the Bash chain | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add block-unresolved-cr-merge.sh to the run_command chain |
| `guard:block-vault-sweep.sh` | has | structural: POC, off by default, measured on the Claude lane before another lane gets it | structural: POC, off by default, measured on the Claude lane before another lane gets it |
| `guard:block-worker-askuserquestion.sh` | has | structural: AskUserQuestion is a Claude tool the other lanes do not have | structural: AskUserQuestion is a Claude tool; the adapter denies an unlisted tool |
| `guard:block-worker-write-fence.sh` | has | gap-ticketed: .codex/hooks.json: add block-worker-write-fence.sh to the Bash chain | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add block-worker-write-fence.sh to the run_command chain |
| `guard:block-write-into-main-checkout.sh` | has | gap-ticketed: .codex/hooks.json: add block-write-into-main-checkout.sh to the Bash chain | has |
| `guard:check-cr-marker-on-pr-create.sh` | has | has | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add check-cr-marker-on-pr-create.sh to the run_command chain |
| `guard:check-write-hold.sh` | has | gap-ticketed: .codex/hooks.json: add check-write-hold.sh to the Bash chain | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add check-write-hold.sh to the run_command chain |
| `guard:guard-agent-model.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-bus-store.sh` | has | gap-ticketed: .codex/hooks.json: add guard-bus-store.sh to the Bash chain | has |
| `guard:guard-chief-dispatch.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-chief-foreground.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-identical-denied-retry.sh` | has | has | has |
| `guard:guard-implementor-dispatch.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-judge-write-scope.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-judge-writes.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-memory-capture.sh` | has | structural: guards the Claude auto-memory store, which the other lanes do not have | structural: guards the Claude auto-memory store, which the other lanes do not have |
| `guard:guard-merge-compound.sh` | has | gap-ticketed: .codex/hooks.json: add guard-merge-compound.sh to the Bash chain | has |
| `guard:guard-pr-check-literal.sh` | has | has | has |
| `guard:guard-readiness-tools.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-relay-writes.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-rm-writes.sh` | has | gap-ticketed: .codex/hooks.json: add guard-rm-writes.sh to the Bash chain | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add guard-rm-writes.sh to the run_command chain |
| `guard:guard-subagent-model.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:guard-t3-thread-tools.sh` | has | has | has |
| `guard:guard-worker-context-handoff.sh` | has | has | structural: keys on the headed-arm --autocompact ceiling, which an Antigravity T3 thread does not carry |
| `guard:guard-worker-wakeup.sh` | has | structural: ScheduleWakeup is a Claude tool the other lanes do not have | structural: ScheduleWakeup is a Claude tool; the adapter denies an unlisted tool |
| `guard:inject-minerva-critic.sh` | has | structural: fires on the Claude Skill tool, which the other lanes do not have | structural: fires on the Claude Skill tool, which the other lanes do not have |
| `guard:mcp-policy.sh` | has | has | has |
| `guard:orchestrator-inline-guard.sh` | has | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs | structural: a Claude-session role (chief, judge, readiness, orchestrator or in-process subagent) that no CLI lane other than Claude Code runs |
| `guard:peer-taint-gate.sh` | has | has | has |
| `guard:read-clamp.sh` | has | has | has |
| `guard:redirect-webfetch-walled-hosts.sh` | has | structural: no URL-fetch tool: Codex reads the web through hosted web_search only | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: the read_url_content arm is open, add the walled-host redirect when it lands |
| `guard:require-quiet-run.sh` | has | has | has |
| `guard:steer-t3-tool-calls.sh` | has | gap-ticketed: .codex/hooks.json: add steer-t3-tool-calls.sh to the t3-code MCP chain for the thread-status steer check (the background-id check is Claude Code's own task ids and does not apply) | gap-ticketed: scripts/hooks/antigravity-hook-adapter.sh: add steer-t3-tool-calls.sh to the t3-code MCP chain for the thread-status steer check (the background-id check is Claude Code's own task ids and does not apply) |

<!-- END cli-lane-parity -->

Reading the gaps:

- **Codex** lacks eight Bash-command guards that Claude Code and Antigravity both
  carry (`block-chokepoint-env-prefix`, `block-graphify-egress`,
  `block-jira-compound-write`, `block-rogue-codex-exec`, `block-tail-pipe-on-gates`,
  `block-write-into-main-checkout`, `guard-bus-store`, `guard-merge-compound`), and
  six that only Claude Code carries. The fix is one edit to the Bash chain in
  `.codex/hooks.json`.
- **Antigravity** lacks `block-fork-sync-pr` and `check-cr-marker-on-pr-create`,
  which Claude Code and Codex both carry. The fix is one edit to the `run_command`
  chain in `scripts/hooks/antigravity-hook-adapter.sh`.
- **Both** lack `block-busy-loop`, `block-unresolved-cr-merge`,
  `block-worker-write-fence`, `check-write-hold` and `guard-rm-writes`, which only
  Claude Code wires today.
- The Claude-session role guards (chief, judge, readiness, orchestrator, in-process
  subagent) are `structural`: those roles do not run on the other lanes. A role
  that later runs on Codex or Antigravity turns its row into a `gap-ticketed` one.
