# Lane-parity index

This page shows, for each worker lane (a runtime himmel can hand work to),
which of himmel's guardrails reach that lane and which test proves it. It
extends [`harness-compat.md`](harness-compat.md) lane by lane. The guard set
comes from the hooks listed in [`enforcement.md`](enforcement.md). Two suites
read this page: `scripts/parity/test-guard-conformance.sh` parses the
deny-guard x lane table, and `scripts/parity/test-ws5-invariants.sh` checks
that the gemini / copilot / cursor rows stay `deferred`.

> **Note:** this index records compatibility/parity, not current routing —
> dormancy status for impl lanes (claudex is live; hermes-oneshot and codex-exec are dormant; the GLM lane was removed, HIMMEL-7481) lives in `scripts/lanes/lanes.json` /
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
separately: `glm-spawn` and `glm-launcher` (Claude Code with the backend
swapped; the native PreToolUse hooks plus `block-glm-external-writes.sh`, the
classifier substitute for the write-authority dimension) and GLM-via-hermes
(fenced by `parity_guard.py`, since the CC hooks do not load under hermes). Its
dispatcher, launcher and registry row are deleted (HIMMEL-7909, HIMMEL-7481).
The two CC GLM columns stay below while the write-fence hook exists (HIMMEL-7907
retires it), and `parity_guard.py` still refuses a GLM engine as untrusted.

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

**Non-deny hooks -- NOT mapped per-lane** (3 PreToolUse + 1 PostToolUse):

- `auto-approve-safe-bash` -- an auto-APPROVER (a fail-open permission helper),
  not a deny-guard.
- `auto-arm-on-cap` -- a fail-open cap watchdog; no non-native analog.
- `check-cr-marker-on-pr-create` -- a PR-time marker check, not a runtime deny.
- `auto-arm-on-subagent-cap` (PostToolUse) -- a cap detector, not a deny-guard.

### Write-authority / external-write fence (a cross-lane dimension, not a deny-guard hook)

Write-authority is the load-bearing parity dimension, but
`block-glm-external-writes.sh` is a lane-specific classifier SUBSTITUTE, not
one of the six deny-guards above. It is recorded here as its own dimension row
so every write-fence cell sits in a real row (no home-less cell).

| Lane | Write-authority / external-write fence |
|---|---|
| main-claude | auto-mode classifier |
| glm-spawn (removed) | `tested:scripts/hooks/test-block-glm-external-writes.sh` |
| glm-launcher (removed) | `tested:scripts/hooks/test-block-glm-external-writes.sh` |
| codex-direct | `tested:scripts/hooks/test-block-terminal-write-fence.sh` -- the terminal write/push/network fence (codex-lane classifier substitute), e2e-proved through the adapter (`scripts/hooks/test-codex-adapter-e2e.sh`). The Edit/Write patch path is fenced by `block-edit-on-main.sh` via the adapter. |
| hermes-main (DEFAULT; engine gpt-6.1-sol; GLM removed) | `parity_guard` push/PR fence -- `tested:scripts/hermes/test-parity-guard.sh` (write-fence; the CC hook does NOT fire under hermes, parity_guard is the sole fence). The other deny-guards are enforced by parity_guard too (all `present`). |
| gemini / copilot / cursor | `deferred` |

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
| glm-spawn (removed) | `native,no-seed` (live `~/.claude`) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
| glm-launcher (removed) | `asserted-only` (launcher and seed check deleted, HIMMEL-7909) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
| codex-direct | `tested:scripts/agents-md/generate.mjs` (AGENTS.md gen + gated) | `tested:scripts/hooks/test-codex-run-hook.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
| hermes-main (DEFAULT; engine gpt-6.1-sol; GLM removed) | `AGENTS.md (loaded)` (`tested:scripts/hermes/test-agents-reach.sh`) | `tested:scripts/hermes/test-parity-guard.sh` | `asserted-only` | `asserted-only` | `gate-owned` |
| gemini / copilot / cursor | `deferred` | `deferred` | `deferred` | `deferred` | `deferred` |

Notes on the guardrail-firing cells. GLM ran as Claude Code, so on the two removed
CC GLM lanes the native block-* hooks fired unchanged; the proving pointer is
`test-block-glm-external-writes.sh`, which covers the lane-specific write-fence
(push / git-remote-URL / network / `mcp__*` deny, with the Jira-CLI + gh-read
carveout). codex-direct reaches the native block-* hooks THROUGH the
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

| deny-guard | glm-spawn (removed) | glm-launcher (removed) | codex-direct | hermes-main (gpt-6.1-sol; GLM removed) |
|---|---|---|---|---|
| block-edit-on-main | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-edit-on-main.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-read-secrets | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-read-secrets.sh` `tested:scripts/hooks/test-codex-adapter-e2e.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-backend-tier | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-backend-tier.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-docker-privesc | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-docker-privesc.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-rogue-claude-schedule | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-rogue-claude-schedule.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| block-merged-pr-commit | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-codex-run-hook.sh` `tested:scripts/hooks/test-block-merged-pr-commit.sh` | `tested:scripts/hermes/test-parity-guard.sh` |
| write-authority / external-write-fence (cross-lane dimension, NOT a CC PreToolUse hook) | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-glm-external-writes.sh` | `tested:scripts/hooks/test-block-terminal-write-fence.sh` `tested:scripts/hooks/test-codex-adapter-e2e.sh` | `tested:scripts/hermes/test-parity-guard.sh` |

<!-- END guard-lane-conformance -->

Notes on the cells:

- **glm-spawn + glm-launcher (removed).** GLM ran as Claude Code, so on these two
  CC GLM lanes the native block-* deny-guard hooks fired unchanged; the single
  lane-specific proving pointer is
  `tested:scripts/hooks/test-block-glm-external-writes.sh` (covers push /
  git-remote-URL / network / `mcp__*` deny, with the Jira-CLI + `gh`-read
  carveout). The native `test-block-<guard>.sh` fixtures fired unchanged for
  both lanes because the ruleset was live `~/.claude` (glm-spawn) or the seeded
  `~/.claude-glm` copy (glm-launcher).
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
| `block-backend-tier` | `parity_guard`'s hook matcher (`wire_parity_guard.py MATCHER`, now `.*` -- it previously included `mcp__.*`) delivers every tool to the guard, and `main()` blanket-denies every `mcp__*` tool EXCEPT the read-only `qmd` KB carve-out (`mcp__plugin_qmd_qmd__*`) -- mirroring `block-glm-external-writes.sh`. MCP tool calls now invoke the guard and are fenced. | `present` (MCP fenced, qmd carve-out) |
| dispatch coverage (matcher) | hermes `fullmatch`es the `pre_tool_call` matcher against the tool name and that is its ONLY blocking event, so every tool the pattern missed was never judged. The hand-listed pattern left `execute_code`, `delegate_task`, `browser_*`, `skill_manage`, `process_manage`, `cronjob_manage`, `send_message` and the rest of the registry outside every fence above, and carried four dead terms (`delete_file`/`remove_file`/`move_file`/`rename_file` are `skill_manage` action values, not tools). The matcher is now `.*`; `parity_guard.classify_tool` gives every registry tool a class -- `code` tools (`execute_code`, `browser_exec`, `browser_cdp`, `cronjob_manage`, `process_manage`) get the terminal deny-guards run over their command text (literal-text scan; obfuscation is not caught), `skill_manage` an action allow-list plus the write-fence on its (batch) paths, `text_to_speech`/`desktop_project` the write-fence on their path arg, and every other known tool a secret/PHI-path scan of its non-prose args. An unclassified tool is refused fail-closed. No known tool is blanket-denied. The outbound tools (`send_message`, `ha_call_service`, ...) are NOT engine-fenced (operator decision). `test-hook-inventory.sh` statically scans the installed hermes registry and fails when a tool is undelivered or unclassified. | `present` (dispatch coverage proved against the installed registry) |

**GLM-engine write-fence vs `scripts/hooks/block-glm-external-writes.sh`.** The
hermes runtime does not load that CC hook, so `parity_guard` is the sole
external-write fence for every engine on the `himmel_agent` profile. Compared
shape-by-shape against the hook (the behavior spec): `git push` (plain),
`git remote set-url` / `config ...url`, the `gh` carve-out (`issue *` + PR/run
reads only), and the network-CLI set (`curl`/`wget`/`iwr`/`irm`) all match --
the terminal / file external-write shapes are at PARITY (present). The MCP
surface is fenced too: `wire_parity_guard.py`'s matcher is `.*` and
`parity_guard.main()` blanket-denies every `mcp__*` tool except the read-only
`qmd` KB carve-out (`mcp__plugin_qmd_qmd__*`), mirroring
`block-glm-external-writes.sh`. So an MCP tool call invokes the guard and is
fenced on the default lane -- `block-backend-tier` is `present` above.

**Beyond the deny-guard set:** the unconditional PHI / data-egress fence fires
on EVERY engine on this cloud profile -- a `.salus`-marked path or a
configured `phi-roots` / `egress-denylist` root is refused for read / search /
write / delete (symlink/junction-safe via `realpath`, fail-closed on an
unreadable list). It is `present` and proved by `test-parity-guard.sh`; it is
not one of the six deny-guards, so it is not a parity GAP, just an additional
fence hermes carries.
