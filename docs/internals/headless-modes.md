# Headless modes: `claude -p` vs `claude --bg` vs headed

Two headless invocation shapes exist in this repo, plus the headed (konsole
+ TTY) shape workers still default to. They are not interchangeable — each
suits a different failure mode, and collapsing everything onto one of them
either burns subscription usage budget on a session nobody watches or blocks a script waiting on
a TTY that never attaches. This doc picks the mode per job; the billing
facts themselves (same subscription usage budget, no separate bucket) live in
[`enforcement.md` "Claude invocation billing"](enforcement.md#claude-invocation-billing)
and are not restated here.

## Decision table

| Job shape | Mode | Why |
|---|---|---|
| One-shot scripted call, output parsed as JSON, a cron/pipeline step, a CI-adjacent check | `claude -p` | Exits when the turn budget or the prompt is exhausted; nothing is left running to confirm, track or clean up later. |
| A long-lived worker that needs cross-session `SendMessage`, survives operator idle time, or must show up in `claude agents --json` / the fleet UI | `claude --bg` | `-p` has no inbox and no idle-survival story — it is a single invocation, not a session. |
| Anything that genuinely needs a live TTY (an interactive prompt, a chief an operator is watching) | headed (konsole) | A session launched without a TTY exits at the first idle cross-session message ([`headed-arm-leg.sh` docstring](../../scripts/handover/console-kit/headed-arm-leg.sh) — see the `--headless` comment block); headed is the only shape where that isn't a problem because a human is attached. |

## `claude -p`

**Sanctioned script:** every scripted `-p` dispatch in this repo is meant to go
through `scripts/lib/claude-headless.sh` ("the P1 chokepoint wrapper for
`claude -p` dispatch") rather than shelling out to `claude -p`
directly — one invocation site to audit instead of many
(`scripts/lib/claude-headless.sh:1-20`).

- **Env inheritance:** runs as a normal child process of the calling shell —
  it inherits that shell's environment the ordinary way. No daemon, no
  per-session settings-file merge.
- **Permission mode:** `--permission-mode` is a required flag on the wrapper
  (`claude-headless.sh:100`) and `bypassPermissions` is refused outright
  (`claude-headless.sh:100`, `die "--permission-mode bypassPermissions is
  refused"`); a direct (non-wrapper) `-p` call site declares it explicitly
  the same way, per the CLAUDE.md "Claude invocation billing" rule.
- **Billing:** same 5-hour/weekly subscription usage budget as interactive use — see
  [enforcement.md](enforcement.md#claude-invocation-billing).
  `claude-headless.sh` calls `scripts/lib/bank-preflight.sh` before
  dispatching and refuses on a non-`PROCEED` verdict
  (`claude-headless.sh:299-300`).
- **Confirm / dedup:** the wrapper never trusts `rc` — a denied tool call can
  still exit 0 (`claude-headless.sh:11-13`), so the verdict comes from the
  caller-declared `--artifact` path checked for a *fresh* mtime after exit
  (`claude-headless.sh:311-340`, the `artifact_mtime` staleness comparison).
  Concurrency is capped by `HIMMEL_DISPATCH_MAX_CONCURRENT` (default 3) and
  every dispatch is recorded as a row in a file-per-session registry at
  `$HOME/.himmel/registry/live/<id>.json` (`claude-headless.sh:346-364`,
  header comment "Registry:" at line ~19).
- **Fleet UI:** `fleet.mjs` models one row per *worker* — a handover doc, a
  queue lock, a session name (`console-kit/fleet.mjs:1-5, 427-444`). A `-p`
  dispatch has none of those; it is a short-lived subprocess the wrapper
  itself tracks via the registry above, not a fleet row. **Unverified**:
  this is inferred from fleet.mjs's field model, not from an explicit
  "`-p` dispatches are excluded" statement in the source.

## `claude --bg`

Added as `headed-arm-leg.sh --headless` (or `LEG_HEADLESS=1`
in the launching shell; the flag wins) — same profile injection, model and
`--autocompact 200000` pin as a headed worker, but no konsole
(`headed-arm-leg.sh:40-45` docstring).

- **Env inheritance:** the background session runs under the `claude`
  daemon and inherits *the daemon's* environment, not the launching shell's
  (`headed-arm-leg.sh:388-390`). `headed-arm.sh`'s `headless_launch` compensates
  by writing every worker env var into the per-worker-session `settings.json`
  `.env` block before launch (`headed-arm.sh:1008-1062`), forcing
  `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` (`headed-arm.sh:1017`), and
  refusing to launch blind if it can't read the daemon's own `/proc/<pid>/environ`
  (`headed-arm.sh:1037-1049`). `--headless` therefore requires a profile —
  `--no-profile` is refused (`headed-arm-leg.sh:396`) — and is native-lane
  only (`headed-arm-leg.sh:401`).
- **Sanctioned scripts refuse seams:** the seam guard
  (`scripts/lib/chokepoint-seam-guard.sh`) takes its baseline from the
  outermost claude ancestor, which for a `--bg` session is the
  `claude daemon run` service. It deliberately ignores the per-leg settings
  file, because a session can write to that file. Any registered seam that
  differs from the daemon's env therefore exits 96 with "headless (--bg) legs <!-- old-term-ok: quotes the guard message text until V5 -->
  cannot pass seams to chokepoints". This includes `ARMAUTOMERGE` for
  `merge-on-green.sh`. Ship from a headed worker. The design for a headless
  equivalent is a planned follow-up.
- **Permission mode:** declared explicitly as `--permission-mode auto`
  (`headed-arm.sh:574`), matching what a headed worker runs under by default
  (comment at `headed-arm.sh:570-573`), never `bypassPermissions`.
- **Billing:** same subscription usage budget as `-p` and headed —
  [enforcement.md](enforcement.md#claude-invocation-billing)
  agrees there is no separate bucket. `headed-arm-leg.sh` runs the subscription usage budget/fleet
  preflight before this launch.
- **Confirm / dedup:** after launch, `headed-arm.sh` polls
  `$CLAUDE_CLI agents --json` for up to 20s (100 × 0.2s) waiting for the new
  session name to appear, and fails closed with `UNCONFIRMED` (exit 7) if it
  never does (`headed-arm.sh:1071-1079`) — exit 0 from the launch call alone
  is not treated as proof the session exists. On success it writes a launch
  log line `headless=1 pid=... session-id=... short-id=... settings=... argv=...`
  (`headed-arm.sh:1084-1091`) that both the chief and the fleet UI read.
  Ending one: `kill <pid>` (the `pid=` in that log line, or from
  `claude agents --json`), then `claude rm <short-id>`
  (`headed-arm-leg.sh:44-45`).
- **Fleet UI:** `fleet.mjs` derives `mode = 'headless'` from any of: the
  agents census showing the session running, the launch log's `headless=1`,
  or the process argv containing `--bg`/`--background`
  (`console-kit/fleet.mjs:437-444`), and renders it in the per-worker-session row
  (`console-kit/fleet.mjs:605`). Built specifically because headless workers have no konsole window for an operator
  to see (`fleet.mjs:3-5`).

## Headed (konsole)

The default worker shape today: `headed-arm-leg.sh` (no `--headless`) opens a
konsole and runs `claude` interactively inside it, same profile/model/
autocompact pin, same subscription usage budget/fleet preflight. It is the only mode where a
missing TTY is not a failure mode, because a human (or an attached terminal)
is what the session waits on. Billing and permission-mode requirements are
identical to `--bg` — see the citations above; the difference is entirely in
how the process is launched (konsole vs `--bg`), not in what it costs or
what it's allowed to do.

## Lane seam: `HIMMEL_CLAUDE_LANE`

Headless `claude -p` spawn sites pick their launcher through
`scripts/lib/claude-lane.sh` (`claude_lane_resolve`). Unset, empty or `native`
runs the plain `claude` binary with byte-identical argv; `openrouter` runs
`scripts/claude-openrouter` and `claudex` runs `scripts/claude-codex` (both
`exec claude "$@"`, so a site keeps its permission mode and `--output-format
json` parsing). Any other value refuses with rc 2 — never a silent fallback to
native. The launchers are not egress gates at these sites (both run `claude`
from a scratch cwd, so their cwd-based guards never see the reviewed repo), so
each site calls `claude_lane_egress <reviewed-repo>` first. It
classifies the REVIEWED repo (`.salus`/`.salus-profile`/phi-roots, the luna
vault, the handover root) and refuses a non-native lane (rc 3, before any
launcher runs) unless `scripts/guardrails/egress-matrix.json` says `allow` for
that lane's provider (`openrouter`; `openai-codex` for claudex) at purpose
inference for that corpus; `conditional` counts as refused. For openrouter it
exports `CLAUDE_OPENROUTER_CWD=<reviewed repo>`, so a himmel checkout classifies
as himmel-code instead of corpus=unknown. A repo in no other corpus is himmel-code
only when its git common dir equals this checkout's (a worktree under
`.claude/worktrees` passes; a foreign repo nested inside the checkout does not);
any other repo is unclassified and refused (the matrix default for an
unclassified corpus is deny). A `HANDOVER_DIR`, `LUNA_VAULT` or `LUNA_VAULT_PATH`
set from any source that does not resolve also refuses. Native is
untouched. Vault content stays native. Wired today: the `claude-headless.sh` chokepoint (used by the automated review
floor reviewer; `HIMMEL_CLAUDE_BIN` still wins, for tests) and the
`hermes-critic.sh --route claude` pass. Other sites are follow-up.

## Audit: headless call sites (HIMMEL-3410)

Taken from the `# headless-claude-ok:` marker inventory of the time (the
marker and its gate were retired in HIMMEL-5424; line numbers are as of the
audit). Documentation notes and test fixtures (no actual invocation) are
not call sites and are omitted. No call site was changed by the audit —
misfits are flagged only.

### Real invocation sites

| Site | Mode | Job shape | Fit |
|---|---|---|---|
| `scripts/lib/claude-headless.sh:372` (the chokepoint's own `CMD=(... -p ...)`) | `-p` | The one shared dispatch primitive every other `-p` call site below routes through | Fits |
| `scripts/cr/claude-floor-review.sh:189` (via `claude-headless.sh`) | `-p`, `--permission-mode acceptEdits` | Automated review floor reviewer — one scoped worker call, opt-in fallback when every non-Claude critic is exhausted | Fits |
| `scripts/cr/hermes-critic.sh:333` | `-p`, `--permission-mode plan --max-turns 1` | Automated review critic pass — one scoped review call | Fits |
| `.claude/commands/plugin-eval.md:63` | `-p` | On-demand `claude plugin eval` run, preflighted against the subscription usage budget | Fits |
| `scripts/codex/hook-smoke-demo.sh:428` | `-p` | Hook-chain smoke demo, gated on the subscription usage budget, one read-only turn | Fits |
| `scripts/lanes/profile-context-probe.mjs:292` | `-p --max-turns 1 --permission-mode dontAsk` | One-shot profile measurement probe, plus a `/context` call per profile for the post-cap skill listing | Fits |
| `scripts/probes/claude-p/*.sh` (~20 sites) | `-p` | Probes exercising specific `-p` behaviors, named for the mode they test | Fits (probes for `-p` are `-p` calls by construction) |
| `docs/internals/token-economy-bench.md:94` | `-p` (bench recipe) | Operator-run bench recipe in a quiet window | Fits |
| `scripts/graphify/refresh-graph-map.sh:63,393,2106` | Not controlled by these scripts — they configure graphify's `claude-cli` backend, which is graphify's own upstream dispatch code, not a `claude -p`/`--bg` flag visible in this repo | Graphify's intentional CLI dispatch (documented, not this repo's call site) | Out of scope — external tool |
| `scripts/handover/headed-arm.sh:573` | `--bg --permission-mode auto` | Chief-armed worker | Fits |

No misfits found: every direct `-p` site in this repo is a one-shot,
preflighted against the subscription usage budget, artifact-checked scripted/CI-shaped call, and the one
`--bg` site is the long-lived, fleet-visible worker launcher — exactly the
split this doc's decision table describes.
