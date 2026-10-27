# Environment & tool-delivery gotchas

> **Platform tier:** Linux and macOS are the **Supported** tier, see the
> [README support matrix](../../README.md#support-matrix).

Platform and harness-tool traps that bite when running himmel or when
authoring himmel shell scripts. These are generic (no machine-specific
config); they reproduce on any bash-5.1+ environment or any Claude Code
session. The Codex-specific hook
wiring trap lives in [`harness-compat.md`](harness-compat.md); guardrail-recovery
escape hatches live in [`stuck-playbook.md`](stuck-playbook.md).

## Claude Code Bash tool strips one backslash level vs a `.sh` file

Verifying backslash-sensitive code (sed replacements, regex normalization) by
running a one-liner **through the Bash tool** is unreliable: the tool's command
delivery strips one backslash level that the same code in a written `.sh` **file**
keeps. A form that is correct in a file can look broken when poked via a Bash-tool
one-liner, and vice-versa — this has produced false-positive "Critical" review
findings where the original file form was actually correct.

Rule: never trust a Bash-tool one-liner to validate backslash counts. Write the
snippet to a real `.sh` file and run that, or rely on the script's test suite, and
add a regression test that pins the emitted pattern plus a match so the correct
form can't later be "fixed" wrong. A reviewer's shell reproduction of a backslash
bug is suspect — re-verify in-file.

## bash 5.1+ treats a literal `&` in `${var//pat/repl}` as the matched text

In a parameter-expansion replacement, bash 5.1+ expands a literal `&` to the
matched text:

```bash
s="${s//</&lt;}"   # yields "<lt;", NOT "&lt;" — the & became the matched "<"
```

So a naive `${//}`-based XML/HTML escaper is silently broken on bash 5.1+, and the
`&`→`&amp;` step only looks right by accident (its match *is* `&`). Pre-5.1 bash
(including the macOS 3.2 baseline) treats `&` literally, so the bug is
version-dependent — it passes on one platform and corrupts on another.

Escape with `sed`, where `\&` is an unambiguous literal ampersand on every
version, and run the `&` rule first so the entities it introduces aren't
re-escaped:

```bash
printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
```

Pin it with a unit test (e.g. `'a & b < c > d'` → `'a &amp; b &lt; c &gt; d'`).

## macOS: qmd's `ggml_metal_library_init_from_source` error is benign noise

On macOS (Apple Silicon), every `qmd embed` / `qmd vsearch` prints
`[node-llama-cpp] ggml_metal_library_init_from_source: error compiling source`
even though GPU embedding **succeeds** (verified on an M5: 423 chunks / 144
docs embedded in 28s right after that line). It reads like a hard failure to
a fresh adopter; it is not — treat it as benign unless the embed itself
errors or hangs. For genuine Metal problems, the underlying
node-llama-cpp/ggml backend exposes a `GGML_METAL_NO_RESIDENCY` residency
knob (per the issue-#276 report; macOS-native layer). Reported on the
fresh-machine adopt run in public issue #276 (G6); the message
is emitted by qmd's upstream node-llama-cpp, so himmel documents it rather
than suppressing stderr (a blanket filter would hide real errors).

## The bun test cwd is per-suite — `scripts/telegram` runs from the repo root

`cd <suite-dir> && bun test` is correct for `scripts/luna-vitals` (172 pass, 0
fail from its own directory) and **wrong** for the `scripts/telegram` suites.
Those pin their fixtures repo-root-relative through `_rf(...)`, so running them
from their own directory fails every wired case:

```chief
$ cd scripts/telegram && bun test spawn-glm.test.ts
error: ENOENT: no such file or directory, open 'scripts/telegram/spawn-glm.ts'   (x8)
```

From the repo root the same suite runs normally.

Why it costs time rather than just failing: the errors name the *source* file the
wiring points at, not the cwd, so it reads as a broken import or a missing build
artifact. The instinct is to go looking for a wiring bug that does not exist.
CLAUDE.md's Tests section carries the one-line rule; this is the reproduction.

Found by the wave-1 orchestration-MVP session, which recorded it as
a trap after the generalisation bit it.

## Anthropic output content-filter trips on policy text and minified blobs

The 400 "Output blocked by content filtering policy" error scans the model's
**generated** output. Two things trip it during OSS / community-health work:

1. **Generating Code-of-Conduct / anti-harassment policy text.** Documents like
   the Contributor Covenant enumerate prohibited behaviors (harassment, abuse,
   sexualized language) — a dense cluster of exactly the flagged-category
   vocabulary the filter watches, so writing the policy reads like the content it
   blocks.
2. **Large minified / obfuscated blobs in context** (e.g. a vendored plugin
   `main.js`) — high-entropy payloads read as possible malware.

Workarounds:

- For standard policy docs, **download instead of generate**:
  `curl -fsSL <canonical-url> -o CODE_OF_CONDUCT.md`, then `sed` any placeholder.
  The content lands on disk, never through model output. Don't `cat` it back —
  keep the trigger text out of context for later turns (verify with `grep`/`wc`).
- For code review over vendored bundles, feed reviewers a scoped diff that
  excludes minified js/css and any downloaded policy file.
- It's intermittent (a per-turn classifier threshold) — in an interactive
  terminal a blocked turn is usually transient and re-sending succeeds.

## Claude Code: the safeguards refusal-fallback swaps to the bare fallback model — dropping the `[1m]` suffix

Distinct from the output content-filter above: when a safeguards refusal fires
(`model_refusal_fallback` in the transcript, e.g. an `apiRefusalCategory` of
`cyber` false-positiving on routine agent-harness code), Claude Code switches
the session to a fallback model — and the fallback map picks the **bare** model
id, never the `[1m]` long-context variant. A session running a `[1m]` model
drops to the fallback's plain 200k window; a context already past 200k then
overflows the new window → `<synthetic>` API errors → an unattended/armed
session stalls mid-queue, with no unattended automatic recovery path if
auto-compact is off.

Mitigations:

- **Keep `autoCompactEnabled: true`** for any session worker that runs a `[1m]`
  model unattended — auto-compact is the only automatic recovery path after
  the drop.
- **Delegate drop-risk reads to a subagent.** Content that routinely trips
  safeguards — CI/build failure logs (`gh run view --log-failed`),
  security-scan output, flagged or adversarial code — should be read by a
  subagent whose distilled summary the parent consumes. A model drop then
  costs a disposable child, never the parent loop's accumulated context.
- After any unattended-session stall, grep the transcript for
  `model_refusal_fallback` before blaming the arm environment — refusal flags
  on routine harness code are typically false positives.

Preserved-thinking cost (read matrix reported by the ticket from
the Anthropic preserved-thinking docs, not independently verified): the
fallback continues the **same** session on another model, and a model can only
read some other models' thinking blocks — Opus 5.5 can't read Fable blocks,
Sonnet 5.5 can't read Opus 5.5 or Fable blocks, and nothing reads Sonnet 5.5
blocks (Sonnet 5.5 thinking is also account-bound). After a cross-model
fallback the earlier thinking is **silently dropped** and may be re-thought,
costing tokens; auto-compact does not restore it. Nothing breaks — Claude Code
handles the drop internally — so this is a cost, not an error.

## `claude --bare` never reads OAuth/keychain — use `--safe-mode` for a hookless run

`claude -p --bare` on subscription (Max/Pro) auth reports "Not logged in"
(`apiKeySource:"none"`). This is documented behavior, not a bug — `--bare`
restricts auth strictly to `ANTHROPIC_API_KEY` / `apiKeyHelper`, so it is
unusable on subscription auth full stop. Reaching for `--bare` to get a
minimal/hookless run for a headless invocation is the common wrong turn.

**`--safe-mode` is the subscription-safe twin** for "skip hooks/plugins":
`CLAUDE_CODE_SAFE_MODE=1` (or `--safe-mode`) disables CLAUDE.md, skills,
plugins, hooks, MCP, custom commands, agents, and output styles, while
auth, model selection, built-in tools, and permissions all work normally.
Use it whenever a script needs Claude Code to run without any of the
project's own guardrails/skills in the loop but must still authenticate
via the ambient subscription session.

## Claude Code: `unrecognized_model` errors from an alternate-backend proxy can masquerade as a context-window failure

Pointing Claude Code at a non-Anthropic backend (an `ANTHROPIC_BASE_URL`
proxy, or any bridge that issues its own `set_model` call) risks the SDK
rejecting an unrecognized model slug. The rejection leaves the session on
Claude Code's own built-in default model, which the proxy then 400s on
*every* subsequent request — including the summarization call context
compaction depends on. The visible symptom is misleading: a log can show
"Prompt is too long · automatic compaction failed" printed **before** the
underlying `unrecognized_model` rejection for the real slug, so the order
of messages points at the context window when the actual cause is the
rejected model slug upstream of it. Raising a context-size env var does not
fix this class of failure — only making the slug recognized (or fixing
whatever issues the bad `set_model` call) does. When a proxied session dies
with a context/compaction-shaped error, check for an `unrecognized_model` /
failed `set_model` earlier in the same log before treating it as a real
context overflow.

## Three consecutive blocked actions can park a session behind an invisible modal

Claude Code surfaces a warning modal after three consecutive tool calls are
blocked (by a permission denial or a guardrail hook) in the same session.
The modal blocks further progress but is invisible to anything watching
the session from outside — a heartbeat/lock file can stay fresh and a
process-liveness check can still report the session as running or busy
while it is actually parked waiting on the modal. Treat two refusals of the
same shape as the signal to stop and change approach rather than retrying
a third time — by the time the modal fires, the session cannot self-recover
without an operator dismissing it.

## rtk token-proxy rewrites top-level Bash-tool commands

If you run [rtk](../setup/rtk-md.md) as a Claude Code PreToolUse rewrite hook, be
aware it rewrites **top-level** Bash-tool commands (not commands inside a script
file). Notably `git diff` becomes a compressed stat summary rather than a unified
diff, and `grep`/`cat`/`tail` with a file redirection can write rtk's summary text
into the target file. Get a real unified diff with `rtk proxy git diff …`; never
redirect an rtk-intercepted command into a file that matters (use the Read/Write/
Edit tools or run the pipeline inside a script file); and verify any file produced
by a top-level pipeline before trusting it. The benign `[rtk] /!\ No hook installed`
banner under himmel's guard wrapper is covered in
[`enforcement.md`](enforcement.md).

## A pruned git worktree directory silently falls through to the PRIMARY repo

When a worktree's admin data is pruned (the `.git` link file and
`.git/worktrees/<name>` removed) but the directory itself survives with files,
any `git -C <dir>` / `cd <dir> && git …` walks UP, finds the primary repo's
`.git`, and runs against the PRIMARY repo — with no error. Red flags:
`status --short` paths prefixed `../../`, the primary's commits in `log`,
`stash push` reporting "No local changes", `merge --ff-only` reporting
"Already up to date". Detect with `git rev-parse --show-toplevel` (must equal
the worktree dir). Habit: before multi-step git surgery in a worktree, capture
`git diff --cached > <scratchpad>/patch` first — if a concurrent prune hits,
the patch is the only thing that survives. (A prune guard is a known gap.)

## git: a fixture `git config` run from the primary checkout poisons every worktree

Every worktree inherits the primary checkout's `.git/config`. A review or probe
subagent told only "read-only, fixtures under the scratchpad" still starts with
its cwd in the primary, and one `git config` without `-C` writes there. One
such run set `diff.external=/bin/true`, `core.bigfilethreshold=1`,
`core.attributesfile` and a textconv driver, so every session's `git diff`
(review gates, impacted-suite listing, commit gates) silently printed nothing
until the keys were removed. A prose "read-only" is not a sandbox.

**What to do:** a brief that builds git fixtures carries a hard sandbox: one
script per experiment that exports `HOME=<scratch>/home`,
`GIT_CONFIG_GLOBAL=<scratch file>` and `GIT_CONFIG_NOSYSTEM=1`, runs `git init`
on a scratch repo, and uses `git -C <scratch repo>` for EVERY git call,
`config` included. After each script, check the primary with
`git -C <primary> status --short` and
`git -C <primary> config --local --get-regexp '^(diff|core\.attributesfile|core\.bigfilethreshold)'`
and stop on any output. To recover: stop the agent, save
`git config --local --list`, unset the injected keys, restore the index and
files, then tell every session that diffed in the window to redo it.

## `sed '/<!--/,/-->/d'` swallows the file body on single-line comments

A one-line `<!-- … -->` opens the range but sed only tests the closing
address on LATER lines, so the range runs to the next `-->` or EOF — deleting
real content and making downstream guards vacuously pass. Strip inline spans
first (`sed 's/<!--.*-->//g'`), then range-delete; pair any such guard with a
red-path test plus a non-vacuousness assertion.

## pre-commit shellcheck crashes when a finding must print a non-ASCII line

Under a non-UTF-8 locale, shellcheck exits 2 with `commitBuffer: invalid
argument` whenever it must PRINT a line containing an em-dash/emoji as part of
any finding — even info-level. Keep lines that carry non-ASCII characters
finding-free (no backticks-in-quotes etc.), or add a targeted
`# shellcheck disable=SCxxxx`. Local verify with `shellcheck -f gcc <file>`
(one-line output format dodges the crash).

## Claude Code: a background Bash task snapshots the FOREGROUND cwd at launch

`run_in_background` Bash commands inherit the foreground shell's cwd as of
launch time. In a multi-worktree session the foreground cwd drifts with every
`cd <worktree> && git …`, so a background job touching more than one repo must
`cd` explicitly before EVERY step — never rely on the launch cwd. Sanity-check
that any background review/analysis output cites paths from the intended diff
before acting on it; a silent wrong-branch review is the failure mode.

## Claude Code: a read outside the working directory hangs an unattended session

A Read/Grep/Glob whose target resolves outside the session's cwd and
`permissions.additionalDirectories` always prompts interactively — even in
`auto` mode, since the classifier doesn't cover this tool-call class (public
docs confirm: no `auto`-mode carve-out is documented for it). An armed/
overnight session has nobody to answer that prompt (a worker once hung
on `Allow reads outside the working directories?` until the operator
happened to be at the terminal). Fix: pre-list the known-safe outside paths
(state repo, `~/.himmel`, the primary checkout, the interpreter's
site-packages) in `permissions.additionalDirectories` so those specific
reads stop prompting at all. **Operator recovery for anything still
outside that list:** answer the prompt in that session's own terminal —
option 2 ("No, block... from now on") is the choice that doesn't
re-prompt for the rest of that run. `queue-lock.sh status` flags a FRESH
lock whose heartbeat exceeds `QUEUE_LOCK_IDLE_WARN_SECONDS` (default 45m,
well short of the hours-scale TTL/aging thresholds) as "possibly stuck on
a prompt" when `ListAgents` still shows the session — that's the signal an
operator or chief is watching for. As of main `f258800f`,
`permissions.additionalDirectories` pins `~/Documents/github/himmel`,
`~/.himmel`, `~/Documents/luna`, and `~/AppData/Local/Python` — outside-cwd
reads under those four stop prompting on this deployment (workspace trust
already accepted for the primary checkout, and `~` resolves here in
practice — Claude Code's own docs do not guarantee tilde expansion for this
setting, so a fresh/untrusted checkout may still need absolute paths);
anything else still prompts, and the fix is the same: extend the list via a
PR.

## A gitignored config overlay does not exist in a fresh worktree

A gitignored, locally-overlaid config file (a tool
config tuned in the primary checkout) does not exist in a fresh worktree —
the tool silently falls back to the tracked default, resurrecting items the
overlay deliberately disabled. Run such tools from the primary checkout, or
copy the overlay into the worktree first.

## git: a branch with no upstream tracking — `git pull` errors, automation reads it as "no update"

A checkout whose branch has no upstream configured (common after a tool-made
clone or history surgery) fails `git pull` with "There is no tracking
information for the current branch" — loud in a terminal, but a wrapper or
cadence job that swallows stderr surfaces it as the repo silently "not
updating". When a repo that should track a remote stays mysteriously stale,
check `git branch -vv` first; fix with
`git branch --set-upstream-to=<remote>/<branch>` using the branch's
configured remote (e.g. `origin/main`).

## qmd: the bun-shim PATH illusion, expired-session embeds, index sharing

- **"qmd MISSING" is usually a PATH illusion.** qmd runs via a bun-global
  shim, not a `qmd` binary on PATH; the real gap is often `bun` itself.
  Check with `qmd_fork_served` from `scripts/lib/qmd-bin.sh` before
  reinstalling anything. In non-interactive `bash -lc`, `.bashrc` returns
  early BEFORE its bun PATH line — export `BUN_INSTALL="$HOME/.bun"` and
  prepend `$BUN_INSTALL/bin` to `PATH` manually.
- **`qmd embed` "⚠ Session expired — skipping N chunks" is resumable.** It
  leaves `Pending: N`; re-running resumes. Loop `qmd embed` until no
  `Pending:` line remains, capped at ~10 passes (real backlogs have cleared
  in ~8) — if `Pending:` persists at the cap, stop and investigate the
  session-expiry root cause instead of looping further.
- **Share an index instead of re-embedding on a weak machine.** The index
  lives at `~/.cache/qmd/index.sqlite` (+ `-wal`), collection config at
  `~/.config/qmd/index.yml`. Prefer `VACUUM INTO '<out>.sqlite'` over
  copying files: it snapshots a LIVE WAL database coherently (no need to
  stop the daemon, no `-wal`/`-shm` to carry, freed pages reclaimed in the
  same step). Make sure the target's `index.yml` already lists the
  collections BEFORE you open the copy with qmd — opening an index whose
  config does not match empties `store_collections` (next bullet), so
  verifying can itself mutate what you just shipped. Then `qmd pull` on the
  target (model download only), and verify with `PRAGMA integrity_check`
  plus a real search; do the sqlite-only checks first if the config is not
  in place yet. Never copy an
  index containing sensitive collections (e.g. medical PHI) to another
  machine — share only indexes built from clean collections.
- **Portability is one row.** `documents.path` is RELATIVE to its
  collection root; the only absolute paths live in `store_collections.path`.
  Retargeting an index at a machine with different roots is an UPDATE of
  those rows, not a rewrite. (`index.yml` and `store_collections` are
  reconciled by qmd — running `qmd --index <name> …` against a named index
  with no config entry will empty `store_collections`.)
- **The DB, not the config, is the authority on what an index contains.**
  `qmd status` and `index.yml` enumerate *configured* collections; a
  collection dropped from the config keeps its rows. A live index carried a
  stale `salus` (1138 docs) invisible to both. Always audit with
  `SELECT DISTINCT collection FROM documents` before sharing — the config
  is not a PHI clearance.
- **A shared index carries document TEXT, not just vectors.** `content.doc`
  holds full bodies, so an index stays fully searchable on a machine that
  lacks the source vault — sensitive rows are not inert there. This is why
  the "clean collections only" rule above is load-bearing.
- **Stripping a collection out of an index is surgery.** If you must (a
  full re-embed being the alternative):
  - `vectors_vec` is a `vec0` virtual table. Any external client
    (`sqlite3`, bun:sqlite) fails `no such module: vec0` on reads AND
    deletes until you load qmd's bundled extension
    (`<bun-global>/node_modules/sqlite-vec-<platform>/vec0`). It throws
    rather than half-deleting, so the enclosing transaction rolls back
    intact — a failed strip is not a corrupted index.
  - `content` is hash-deduped and SHARED: byte-identical files across
    collections point at ONE row. Delete only
    `hashes(target) − hashes(keep)` or you punch holes in the collections
    you kept (11 of 1096 hashes were shared in a real run).
  - `documents_fts` is keyed `<collection>/<path>`, and its rowid is NOT
    `documents.id` (FTS covers only `active=1`). Delete by ANCHORED
    filepath (`LIKE 'salus/%'`) — an unanchored `%salus%` also matches
    legitimate `himmel/templates/.../_profiles/salus/*` files. Same
    anchoring lesson as the gitleaks-allowlist bullet below.
  - Verify STRUCTURALLY, not with a text scan: SQL `LIKE '%term%'` is
    substring + case-insensitive, so it false-positives against longer
    clean strings. Assert instead: expected `DISTINCT collection` set only;
    zero content rows unreferenced by any doc; zero content referenced by
    an unexpected collection; zero FTS rows outside expected collections;
    zero `content_vectors`/`vectors_vec_rowids` without a content row;
    `PRAGMA integrity_check` ok; `PRAGMA foreign_key_check` empty
    (`integrity_check` does NOT cover FK violations, and `documents.hash`
    → `content.hash` is a declared FK); SHA256 match across machines.
- **`~/.cache/qmd/mcp.pid` goes stale — it is not proof qmd is idle.** It
  named a dead PID while the real daemon holding the DB ran elsewhere; find
  the holder by command line (`ps -ax -o pid,command | grep '[q]md'`, which
  works on Linux and macOS) rather than trusting the PID file.

## Claude Code: a background-task notification's "exit code 0" is the LAST command in the chain

The completion notification for a background Bash task reports the exit
code of the final command in the chain — a trailing `echo`/`tail` masks a
failing gate earlier in the same chain (observed: a merge-gate script
exiting 3 under an "exit code 0" notification because the chain ended in
an echo). Read the task's actual output for the verdict; never trust the
notification's exit code for anything but the last command.

## gitleaks: anchor allowlist regexes — and the pre-push scan covers the staged INDEX

- **Allowlist regexes for a known-benign literal must be anchored**
  (`'''^the-literal$'''`), never a bare substring: an unanchored regex also
  suppresses any REAL secret that merely *contains* the literal — a
  scanner-bypass hole. Verified behaviour: anchored keeps a
  prefixed/suffixed variant flagged; unanchored suppresses both.
- **A correct anchor will still fire on nested contexts** — the same
  benign literal embedded inside other text (e.g. a `printf` line captured
  into a shipped `.patch` file) extracts as a longer candidate secret that
  `^…$` rightly does not match. That firing is correct, not a bug: do NOT
  un-anchor to silence it (that reopens the substring hole). Fix at the
  source (keep the literal out of the shipped text) or add a
  path-scoped allowlist entry.
- **The pre-push hook scans the STAGED INDEX, not just your push range.**
  In a repo shared by concurrent sessions, one session's staged secret
  blocks *every* session's push — and `git log --all -- <file>` finds
  nothing because the file was never committed. Diagnose with
  `git status --short -- <file>` — an `A` in the first column followed by
  a space means staged-new — and let the owning session fix its own
  staged file.

## A real `sleep` reachable from test config is a hang waiting to happen

A shell suite that sleeps for real cannot be told apart from a suite that is
stuck: both just sit there. `scripts/test-check-ci.sh` pinned
`CR_ESCALATE_POLL=0`, which `check-ci.sh` validates as invalid and replaces
with its 120-second default — so a case with a wait budget above 120s slept two
real minutes between re-reads, looking identical to a wedged run. One case did,
and nothing stopped the next one from doing the same.

The fix is an injected sleep, not a smaller number. Every wall-clock wait in a
script the suites drive goes through one command word the caller can replace:

- `CHECK_CI_SLEEP_CMD` (`scripts/check-ci.sh`, default `sleep`) — covers the
  grace-window probe and the `--settle` pause, including
  the validated 120s fallback.
- `MERGE_ON_GREEN_SLEEP_CMD` (`scripts/handover/merge-on-green.sh`, default
  `sleep`) — the post-merge confirmation poll.

Both are a single command word: hermetic suites set them to `:`, and neither
widens a trust boundary (a caller who can set them can already set `PATH`).

The trap when you inject one: a no-op sleep does not just skip a wait, it turns
a wall-clock-budgeted loop into a spin. Where the loop exits on data that is a
pure win (two real minutes become none); where it exits on the BUDGET the wall
clock is unchanged and only the fork count explodes — and any assertion counting
iterations-per-interval becomes a measure of how fast the host forks. Keep those
few cases on a real sleep (`SLEEP_CMD_OVERRIDE` in `test-check-ci.sh`) and shrink
their budget instead.

Bounds are the backstop for everything the seam does not cover:

- `CHECK_CI_CASE_TIMEOUT` (default 600s) wraps each `run()` in
  `scripts/test-check-ci.sh`, so a stuck case FAILS with its case number
  instead of stalling the suite. Hosts without coreutils `timeout` (macOS)
  fall back to an unbounded `env` wrapper and say so loudly. Size such a bound
  generously: it exists to turn an infinite hang into a verdict, not to police
  slowness, and one that fires on a legitimate case teaches everyone to ignore
  it. A 120s bound looked like 12x headroom and still killed a real case on a
  box whose `/tmp` had accumulated ~150k entries — enough to make
  every `mktemp` a fixture takes measurably slower. Check `ls /tmp | wc -l`
  before believing a suite "got slower".
- `SUITE_TIMEOUT` (default 600s, plus a per-suite table for
  measured slow suites) and `SUITE_RUN_BUDGET` (default 7200s) in
  `scripts/ci/run-shell-tests.sh` already cap each suite and the whole run; an
  expired suite is reported `rc=124` and counted under `TIMED OUT`.
- The whole-run budget does **not** fit a full corpus on this workstation, and
  saying so is the point: 397 suites are discovered, 381 run, and
  the 2026-08-29 reference run spent all 7200s on real work while reaching 174
  of them. A truncated run exits 1 rather than reporting green,
  and `SUITE_ROTATE` (default on) leaves a cursor so the NEXT run resumes at the
  suite the budget cut off and wraps — otherwise the sorted walk order drops the
  identical 207-suite tail every time. Set `SUITE_ROTATE=0` to always start at
  the top; `SUITE_ROTATE_STATE` overrides the cursor path.

Note GNU `timeout 0` DISABLES the limit rather than expiring instantly, so
every **duration** knob above (`SUITE_TIMEOUT`, `SUITE_RUN_BUDGET`,
`SUITE_LOCK_TTL`) treats `0` or a malformed value as "use the default", never
as "no bound". That rule is about durations only — it does not extend to the
plain on/off switches, where `0` means exactly what it says: `SUITE_LOCK=0`
disables the machine lock and `SUITE_ROTATE=0` disables rotation. The
distinction is deliberate: a `0` duration would silently disable the guard it
configures, whereas an explicit switch is the sanctioned way to turn one off.

`SUITE_LOCK_WAIT` is the one duration where `0` is honoured
verbatim, and it does not break that rule — it is a **budget**, not a guard.
It says how long a run may queue for a held machine lock before refusing, so
`0` means "do not queue", which is the historical behaviour and the default;
there is no guard for it to silently disable. It therefore does NOT go through
the runner's shared `_suite_num` helper, which rejects a `0` by design. A
malformed value still falls back to `0` (with a `WARN`), never to an unbounded
wait — the failure direction matters: a typo must not convert a refusal into
an hours-long block. Its companion `SUITE_LOCK_WAIT_INTERVAL` (default 60s,
the heartbeat spacing) is an ordinary duration and does use `_suite_num`,
because a `0` there would busy-spin the box the lock exists to protect.

## Hermes quarantines project skills by scanner verdict — and `/worktree` collides

Hermes sessions (not Claude Code / Codex) scan `.agents/skills/` at gateway
start and quarantine anything its threat-pattern scanner scores "dangerous";
the skill is then unavailable via `/skill <name>` for that session. himmel
skills have been hit this way (`source-command-claude-md-audit`) — the
findings are pattern-level, so treat a
quarantine as a signal to inspect the skill's scripts/prose, then reword.
**Hermes has no per-project allowlist for project skills** — rewording the
flagged pattern is the only local lever; do not blanket-disable the scanner.

Accepted policy (operator ruling 2026-08-22): the scanner stays
ON; a quarantine is a signal to inspect, never a reason to disable the guard.
False positives are tracked upstream: hermes-agent issue
[#92021](https://github.com/NousResearch/hermes-agent/issues/92021) is the
canonical dup (our [#92446](https://github.com/NousResearch/hermes-agent/issues/92446)
closed as a dup of it; [#92478](https://github.com/NousResearch/hermes-agent/issues/92478)
tracks the denylist-literal FP), and PR
[#92249](https://github.com/NousResearch/hermes-agent/pull/92249) (tiered-v2
scanner) is the fix to watch.

Separately, himmel's `worktree` skill does NOT auto-register as `/worktree` in
Hermes: core Hermes owns that command and skips colliding registrations. In a
Hermes session invoke it as `/skill worktree`. Claude Code keeps `/worktree`
unchanged.

## Linux: a stock Ubuntu user has TWO PATH layers, and non-interactive shells see only one

A tool can be installed, on PATH, and working in your terminal while every
scripted probe reports it missing. On a stock Ubuntu account the user's PATH is
assembled by two different files with different visibility:

- **`~/.profile`** exports `~/.local/bin` and does not early-return. A login
  shell — including a non-interactive `bash -lc` — sources it, so that layer IS
  visible to scripts.
- **`~/.bashrc`** owns whatever the third-party installers append to it (bun's
  `BUN_INSTALL` / `~/.bun/bin` block is the common one). Ubuntu's stock
  `~/.bashrc` begins with `case $- in *i*) ;; *) return;; esac`, so it
  early-returns for every non-interactive shell and that layer is NOT visible
  to scripts.

So `bash -lc 'command -v bun'` reports nothing on a machine where
`~/.bun/bin/bun --version` prints `1.4.0`, while `command -v pre-commit`
resolves fine from the same shell — the difference is only which file exported
the directory. A plain SSH `exec_command` is worse again: no login shell at
all, so `~/.local/bin` disappears too and `claude` reads missing as well.

Consequences:

- **A presence probe must state which shell layer it used.** A bare "MISSING"
  is not evidence a tool is absent; it is evidence that one PATH layer did not
  contain it. Two false negatives (`claude` and `bun`) came out of exactly this
  during a clean-install run.
- **Installer verification that re-checks PATH in-process will fail** even
  though the install succeeded — `himmelctl deps ensure` reports bun as
  "installed but still not found on PATH" for this reason. Resolve a
  freshly-installed tool by its known path, not by PATH lookup.
- **Re-running an installer can duplicate its rc block.** bun's installer
  appended a second identical `BUN_INSTALL` block to `~/.bashrc` on re-run.
- **A git hook is on the invisible layer by default.** A hook inherits the
  environment of the git process that invoked it — it does not build a fresh
  PATH — so `git commit` from your own terminal sees `~/.bun/bin` and the same
  commit driven by SSH, a script, CI or an agent does not. That is himmel's
  normal case, not the exotic one, and it blocked every commit on the guest
  until `scripts/hooks/check-lockfile-integrity.sh` learned to resolve bun by
  `PATH` → `$BUN_INSTALL/bin` → `$HOME/.bun/bin`. Any new
  gate that reaches for a third-party tool needs the same chokepoint; do not
  assume the operator's PATH.
- **Offboarding degrades exactly the way onboarding does.**
  `scripts/uninstall.sh` gated its plugin ([4/7]) and git-hook ([5/7]) teardown
  on a bare `command -v claude` / `command -v pre-commit`, printed a "skipping"
  line when either failed, and still ended with `Uninstall complete.` at rc=0 —
  so an uninstall driven by `ssh host 'cmd'`, cron, CI or an agent left every
  plugin wired at user scope and every git gate still firing while the tool
  reported success. Both
  scripts now resolve each tool by known path and, if a step that had to run
  could not, name it with the list of places searched and exit **2** without
  printing a completion line. An explicit `--skip-plugins` / `--skip-hooks` is
  an operator decision and still exits 0. **A "skipped" step is not a
  completed teardown — say so in the exit code, not only in a log line
  nobody reads.**

To see the layer a script will actually get, ask for it the same way the script
does:

```bash
bash -lc 'echo "$PATH"'          # what a login shell sees (~/.local/bin present)
ssh host 'echo "$PATH"'          # what a bare remote command sees (neither layer)
```

## Linux: a kernel upgrade without a reboot breaks docker networking

A package update (e.g. `pacman -Syu` on Arch/CachyOS, or the distro
equivalent) can install a new kernel while the old one keeps running until the
next reboot. The old kernel's modules directory under `/usr/lib/modules` gets
replaced by the update, so `modprobe` can no longer load the netfilter modules
docker needs. Symptom: docker fails to create a network, with errors mentioning
`iptables` or `nat` — e.g. `nf_nat` failing to load. This looks like a
docker/iptables bug — confirm the diagnosis below before debugging either.

Diagnosis: compare `uname -r` (the running kernel) against `ls
/usr/lib/modules` (the installed kernels). If the running kernel has no
matching modules directory, that is the cause; otherwise keep troubleshooting
docker/iptables normally.

Fix: reboot into the new kernel.

## `graphify install` re-adds an absolute `graphify` path to the tracked settings

`graphify install` owns its own hook block and rewrites it on every run, with
the command spelled as the absolute path to the binary on the machine that ran
it — `/home/<you>/.local/bin/graphify hook-guard search` in
`.claude/settings.json`, and the same absolute-path shape re-added to
`.codex/hooks.json`. Both files are tracked, so every adopter inherits a hook
that cannot resolve off that one box, and the first also leaks the
maintainer's username into the public mirror.

This is not a one-off to clean up — the next `graphify install` (including the
one inside `himmel-update`) puts it straight back. The tracked shape is now
asymmetric: ONE entry in `.claude/settings.json` (matcher `Grep|Glob`,
timeout 3) and NONE in `.codex/hooks.json` — the Codex hook was removed
outright because it was spawning a hook process on every single call and
starving the chain. So the
correct action after a `graphify install` is to restore that shape: re-apply
the portable, fail-open command in `.claude/settings.json`, and DELETE the
entry `graphify install` re-adds to `.codex/hooks.json` rather than rewriting
it to a portable form.

```json
"command": "command -v graphify >/dev/null 2>&1 && exec graphify hook-guard search; exit 0",
"timeout": 3
```

With graphify present the hook runs exactly as before and a non-zero exit still
blocks the call; with graphify absent the command exits 0 and the adopter is
unaffected. The timeout is a deliberate cost cap and must survive the restore.
The thing that actually holds the line is the gate, not the memory:
`settings-portability` (`scripts/hooks/check-settings-portability.sh`) refuses
the commit that re-introduces the absolute form.

## A script that finds its inputs by scanning `$HOME` can upgrade from the wrong checkout

`scripts/luna-upgrade-all.sh` resolved its template from a hardcoded
`$HOME`-relative candidate list (`$HOME/github/himmel`,
`$HOME/Documents/github/himmel`, …). On the v1 acceptance-matrix guest the
install ran from `~/Documents/github/himmel-main` — the private RC — while the
upgrade sourced its template from `~/Documents/github/himmel`, a stale PUBLIC
mirror, and wrote 22 files into a real vault from it without ever saying which
checkout they came from.

Resolution order is now `--template-dir` → the invoking script's own checkout →
`$HIMMEL_DIR` → `$HIMMEL_REPO` → the `$HOME` scan, and the resolved checkout and
its commit are printed before anything is written. The ordering rule generalises:
**an ambient pointer must not outrank the checkout you are running from** — a
stale env var or a lucky scan hit is exactly the failure mode — while an
explicit per-invocation flag still wins over both.

## Editing `scripts/hooks/*.sh` needs the integrity bypass in the launching shell

The hook-integrity guard (`scripts/hooks/record-hook-integrity.sh` pins HEAD
blob hashes at session start; `scripts/hooks/hook-integrity.js`, run via
`run-hook-with-bash.js`, compares on-disk hashes against them) treats any
`scripts/hooks/*.sh` file that differs from `HEAD` as
tampering and blocks every subsequent Bash/Edit call in the session until the
file is committed — including the very edit you are mid-way through. Set
`HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1` in the shell that LAUNCHES the session
(`HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 claude`) before touching any hook script; a
per-call prefix does not reach the guard. Recovery once locked out: plain-copy
the affected file(s) back to `HEAD`, relaunch with the bypass set, then
re-apply the intended edit and commit it in the same step.

**Scope.** The bypass is anchored to `CLAUDE_PROJECT_DIR`, never
to a directory discovered from cwd (`git rev-parse` follows the `.git` pointer
*file* a worker can rewrite). The launcher honours it only when all of these
hold, and otherwise the normal deny stands:

- the session's cwd is inside `CLAUDE_PROJECT_DIR`;
- the session's **recorded repo** (`git_dir` in the hook-integrity record, asked
  with `git --git-dir=<git_dir> worktree list`) lists `CLAUDE_PROJECT_DIR` as a
  linked, non-primary worktree, and that worktree's `.git` pointer still
  resolves back into the recorded repo's `worktrees/`. A record with no
  `git_dir` — the pins-only shape written for a repo with no `origin` anchor —
  refuses the bypass;
- the hook script's real path (symlinks resolved) is inside that worktree.

So the primary checkout, a sibling worktree, and a hook symlinked in from
elsewhere are all refused. Each honoured hook appends one JSON line — `ts`,
`session`, `session_id`, `cwd`, `worktree`, `hook_paths` — to
`<git_dir>/hook-integrity-bypass.jsonl`, in a single `O_APPEND|O_NOFOLLOW`
write. A hook chain runs the launcher once per member, so a tool call that
overrides several tampered hooks writes one line per hook. A symlink or
non-regular file in that spot, and any failed or short write, refuse the bypass.
The two command-text fences in `block-glm-external-writes.sh` (the pin-dir fence
and the anchor fence) apply the same predicate and write to the same audit file,
re-stated in bash as `bypass_honoured`, with one difference: they
append one line per tool call the bypass is consulted for, and a symlink or
non-regular audit file refuses it by an lstat check before a plain append (not an
`O_NOFOLLOW` open). Its git calls are bounded by `timeout` at the launcher's
`HIMMEL_HOOK_INTEGRITY_GIT_TIMEOUT_MS` budget, and a missing `timeout` or a timed-out
git refuses the bypass (the hook entry itself fails open on a hang). The worker spawners (`glmChildEnv`, `sessionEnv`,
`claudexChildEnv`) also strip the variable from every worker child env, so a
worker never inherits it. So do the hook edit in a worktree, with the session's
cwd inside it.

## pre-commit: `run --commit-msg-filename` reports Passed for a message the hook rejects

Verifying a commit-msg gate without making a commit looks like this:

```bash
pre-commit run conventional-commit-msg --hook-stage commit-msg \
  --commit-msg-filename /tmp/msg.txt
```

It is not a valid instrument. pre-commit filters the file list against the
repository, and a path outside the repo is filtered out — so the hook runs with
no input and reports `Passed`. A message that the hook demonstrably rejects
still comes back green:

```text
$ pre-commit run conventional-commit-msg --hook-stage commit-msg --commit-msg-filename /tmp/mC.txt
Conventional commit message + ticket ID (strict when TICKET_ID_REQUIRED=1)...Passed

$ bash scripts/hooks/check-commit-msg.sh /tmp/mC.txt ; echo $?
COMMIT REJECTED: message does not match conventional commit format.
1
```

Call the hook script directly with the message file, and check `$?`. Same rule
as everywhere else in this repo: a green verdict is only evidence once the same
instrument has been shown to go red on a case that must fail. Here the
must-fail arm is a non-conventional message; if that comes back Passed, the
instrument is measuring nothing.

## `load-dotenv.sh` strips a trailing comment — but only when whitespace precedes the `#`

`scripts/lib/load-dotenv.sh` strips an unquoted trailing `#comment` from a
`.env` value, but ONLY when whitespace precedes the `#`. That whitespace is
half the marker, so `URL=http://x/#frag` keeps
its `#frag` — no space precedes that `#` — and a `#` inside quotes is left
alone too; quotes themselves are NOT stripped (a known
limitation). Before this, `.env.example`'s
`JIRA_PROJECT_KEY=HIMMEL   # default project for jira ops` fed the commit-msg
gate the impossible pattern `HIMMEL   # default project for jira ops-[0-9]+`
the moment pre-commit stopped from starving `check-commit-msg.sh`
of its message — every machine that had installed from that example `.env`
rejected every commit, correct ones included.

## `.env`: the FIRST occurrence of a key wins, and an exported empty value is not a value

Two loaders read the primary checkout's `.env` — `scripts/lib/load-dotenv.sh`
(shell) and `load_repo_env()` in `scripts/luna/fetch-health.py` (Python).
The Python side was brought into line, so ONE policy now describes
both:

1. **First occurrence in the file wins.** The shell loader stops at the first
   match (`key in seen` in its awk pass); the Python reader keeps a `seen` set
   for the same reason. So appending `FIRECRAWL_API_KEY=real-value` to a file
   that already carries an empty `FIRECRAWL_API_KEY=` placeholder higher up
   means **neither loader ever sees your value** — the placeholder is the first
   occurrence, and an empty string is what gets loaded. Edit the existing line
   instead of appending; `grep -n '^FIRECRAWL_API_KEY=' <repo>/.env` before you
   append tells you which case you are in. (Appending also needs a leading
   newline — see the `.env` append gotcha: a blind `>>` glues the new key onto
   whatever the last line was.)
2. **A set-but-EMPTY existing value counts as ABSENT** — the file fills it in.
   "Empty" means ZERO-LENGTH, exactly `[ -z "${KEY-}" ]` — the shell rule
   (every caller guards with it, so a zero-length value is
   not usable). A **whitespace-only** value (`KEY="   "`) makes `[ -z ]`
   false, so it counts as PRESENT and wins over the file in BOTH loaders
   (`load_repo_env()` briefly used `.strip()` here,
   which disagreed with the shell side on exactly this case and broke the
   parity this section documents). `load_repo_env()` also used to use a
   plain `setdefault`, under which an exported `KEY=` DID win: with
   `FIRECRAWL_API_KEY=` in the environment, every fetch-health probe reported
   the credential "missing" while `.env` held the real one. A live NON-empty
   (i.e. non-zero-length) process value still wins over the file, in both
   loaders.

The corollary bites in worker launchers: `arm-resume` re-exports `.env` into
every worker, so an operator who sets `CR_FLOOR_FALLBACK=` (empty) to decline a
fallback declines nothing — the file value wins over the empty process value.
Decline with a non-empty sentinel the reader treats as "off".

**`load_dotenv` takes the KEY NAMES as arguments.** A bare `load_dotenv` loads
only its defaults (`HANDOVER_DIR USER_SLUG`) and returns 0, so a presence check
written as

```bash
. scripts/lib/load-dotenv.sh; load_dotenv; [ -n "${FIRECRAWL_API_KEY-}" ] || echo EMPTY
```

prints `EMPTY` against a `.env` that holds the value — and reads as a loader
defect when it is a call-shape defect. Name the keys:

```bash
. scripts/lib/load-dotenv.sh
load_dotenv FIRECRAWL_API_KEY BITBUCKET_API_TOKEN
```

**And some callers source nothing at all.** The cadence wrapper
`~/.claude/pipeline-cadence/pipeline-fetch-health.sh` runs
`python3 .../fetch-health.py` directly, so a key that lives only in `.env` — the
documented place — was invisible to it. That is why `fetch-health.py` reads
`.env` itself, once, in `build_probe_registry()`: the single boundary where the
process environment and the resolved repo root meet, so no probe can be left
behind again (previously only `probe_bitbucket` called the loader, and
`firecrawl` and the since-removed X cookie probe were red on every scheduled run).

## Two Bash-tool calls in one message race the persisted cwd

The Bash tool persists its working directory between calls by writing `pwd -P`
to a per-session file. Two calls issued in the **same message** each write
that file, so the cwd a later call inherits is whichever one won the race —
not necessarily the one you last `cd`'d in. A subshell that changes directory
(`( cd "$t" && ... )`, `mktemp -d` + `git init`) can also leave the saved cwd
pointing somewhere unintended. The failure is silent and the output stays
plausible: a suite run in the wrong checkout still passes or fails for real
reasons, so nothing signals that the tree under test is not the tree you
think.

It is not only the parallel race, either: the tool persists cwd **by
design**, so any deliberate `cd <other-checkout>` (to read another repo's
`.git`, to run a script from its root) silently persists into every later
call in the session — a subsequent `git commit` or a gate check then runs
against the wrong repo.

**How to apply:** for anything where the checkout matters — suites, `git`,
launching a detached runner — pass the path explicitly (`git -C <path>`,
absolute script paths) rather than relying on the persisted cwd. Never `cd`
into a second checkout at all; re-read the intended repo/branch right before
every gate. Don't pair a cwd-sensitive call with an unrelated one in the same
message.

## A blind `>>` onto `.env` glues onto the last key if there is no trailing newline

Appending a config key with a bare `printf 'KEY=val\n' >> .env` is unsafe
when the file has **no trailing newline**: the write concatenates onto the
last existing line — e.g. `CR_PROFILE=paidKEY=val` — which corrupts that
key's value and leaves the new key unparseable. Dotenv loaders are typically
first-match-wins and split on the first `=`, so the damage is silent until a
downstream tool breaks.

**How to apply:** to set a key, ensure it lands on its own line — prefer a
leading newline: `printf '\nKEY=val\n' >> .env` (harmless blank line if one
already ends the file; guarantees separation if not). To verify without
grepping the file raw, use the sanctioned loader so it echoes only the one
key: `. scripts/lib/load-dotenv.sh && load_dotenv KEY && echo "${KEY:-<unset>}"`
— an `<unset>` after an append means the line didn't land cleanly.

A second shape of the same bug: a loader using `setdefault` treats an
**empty placeholder line** (`KEY=`) higher in the file as the winning
occurrence, so a value appended lower down is silently shadowed. Before
appending, check for and remove an existing empty line for that key
(`grep -nE '^KEY=$'`) rather than assuming append-only is safe; check
duplicates by NAME only, never print values.

## `claude-headless.sh`'s EXIT trap can kill the launching session (open)

Running a full headless test suite that shells out through
`claude-headless.sh` **from inside an interactive Claude Code session** can
kill that session. Mechanism: an interactive session exports
`CLAUDE_PID=<its own pid>`. The wrapper's EXIT trap runs `kill_tree
"$CLAUDE_PID"`, but the wrapper only assigns its OWN `CLAUDE_PID=$!` at
launch — a pre-launch refusal path (concurrency cap, a preflight SKIP, a
permission-mode refusal) can exit before that assignment, so the trap reads
the INHERITED session PID and kills the launching session's whole process
tree.

**Guard (until the underlying bug lands):** always run such a suite as
`env -u CLAUDE_PID <cmd>` — the wrapper then can't inherit the PID, so no
refusal path can target the session. Prefer running it detached/backgrounded
so a stray kill can't take the launching session with it. After any
unexpected session restart, check for an orphaned runner still holding a
suite's lock before re-arming.

## `git branch -d` DOES delete a squash-merged branch

The common assumption that `-d` refuses a squash-merged branch (because it
is not an ancestor of `origin/main` after the squash) is wrong. `-d` also
accepts a branch merged into its configured **upstream**, which a pushed
feature branch satisfies. Consequence both ways: you do not need `-D` to
clean up a squash-merged branch, and `-d` is not the safety net you may be
counting on to stop an unwanted delete. Recovery is cheap regardless — the
tip commit stays a reachable object, so `git branch <name> <tip-sha>`
restores it; keep the tip SHA around before removing anything you might
want back.

## The `obsidian-vault` MCP times out at a hardcoded 6s even when the server is healthy

`mcp-obsidian`'s Python client hardcodes its request timeout to `(connect=3,
read=6)` seconds, with no environment override. Cold-start latency or one
slow fuzzy query over a large vault trips the 6s read limit even though the
endpoint itself answers in well under a second once warm — so a `Read timed
out` from the MCP tool is not evidence the vault server is unreachable or
the API key is stale.

**Validate before falling back:** curl the REST root directly (key/host/port
live in the MCP server's own config) —

```bash
curl -sk -m 10 https://127.0.0.1:27124/ -H "Authorization: Bearer <API_KEY>"
```

`{"authenticated": true, "status": "OK"}` means the key and server are fine
and the failure was purely the wrapper's read timeout. Fall back to raw REST
(`POST /search/simple/?query=<q>`, `GET /vault/<path>`) or a qmd search over
the vault's indexed content — never to a stale on-disk grep, which reads a
copy the live vault may have since changed.

## Obsidian hangs on bulk file churn inside the vault

Obsidian watches every file under the vault root, including gitignored paths
and paths in its own "Excluded files" list. Each create or delete is a vault
event, and the renderer pins at 100 % CPU replaying them against its cached
index. Hundreds of thousands of generated files (judge scratch, a
`graphify-out/` of about 21k files) froze it. So did moving 22k files OUT of
the vault while it ran, after which the restart stuck on "loading cache"
because the IndexedDB cache was stale.

**Close Obsidian before any bulk move or delete of more than about 1k files in
the vault**, and keep bulk generators out of the vault tree. Recovery: close it,
move `~/.config/obsidian/IndexedDB` aside (do not delete it), then start
Obsidian again. The cache rebuild took about 45 s for 46k files. Measure its
CPU with `top -b -n 2`, not `ps -o pcpu`, which reports a lifetime average.

## Patching a shell script through a python heredoc silently corrupts bytes

Editing a `.sh` file via `python3 - <<'PY' ... PY` instead of a text-editing
tool has two traps that a passing test suite will not catch:

1. **Backslash escapes meant for the shell get interpreted by python
   first.** A `'\r'` in the python source becomes a literal CR byte in the
   output file — e.g. `tr -d '\r'` silently becomes `tr -d '<CR-byte>'`,
   which is *behaviourally identical* (it still deletes that byte) so tests
   and even `shellcheck` stay clean; only `cat -A` or `grep -nP '\r'` shows
   the invisible control character. The same class of edit can also collapse
   `\` + newline continuations into one long line.
2. Double any escape meant for the shell in the python source (`'\\r'`), and
   verify the written bytes (`grep -nP '\r' <file>`, `sed -n '<range>p' |
   cat -A`) before committing.

Prefer a proper text-editing tool for multi-line shell edits; reach for a
heredoc only when the edit is genuinely programmatic, and verify the bytes
either way.

## `pre-commit run` stashes ALL unstaged files repo-wide, not just the linted ones

Running any `pre-commit run <hook>` stashes **every unstaged file in the
repo** (not only the files being linted), logging a `Stashing unstaged
files to ...` line, then restores them when it finishes. It also lints the
**staged index**, not the worktree.

With several people or agents editing disjoint files in one shared checkout,
each gate run briefly removes and re-adds every *other* worker's in-flight
edits; two concurrent gate runs can interleave stash/restore in a way that
would be difficult to diagnose after the fact — it looks like someone
"forgot" to save their work.

**How to apply:** with parallel editors in one worktree, serialize the gate
— run it once before the combined commit, or run it only after `git add`-ing
your own paths and confirm siblings' files still show as modified
afterwards. Always `git add` again after any edit before re-running the
gate — it reads the index, so an un-re-staged fix re-tests the stale blob
and reads as a real failure. Before committing a fan-out's combined work,
`git status --short` and confirm every expected file is still present and
modified.

## shellcheck's SC2317 (0.10.x) and SC2329 (0.11.x) are the same finding renamed

A local shellcheck binary at 0.11.0 does not have `SC2317` at all — it was
renamed to `SC2329` ("this function is never invoked") in that release. The
pre-commit gate pins shellcheck-py 0.11.0.1, while a distro package can still
be 0.10.x or older (the CI image's apt shellcheck is 0.9.0, shadowed on PATH
by the pinned one), so a bare local run can disagree with the gate. This is
version skew, not a severity difference — both codes report at the same
(info) severity in their respective versions.

**How to apply:** a disable directive on an intentionally-indirect stub
(e.g. a test double invoked only by name, never called directly) must list
**both codes** — `# shellcheck disable=SC2317,SC2329` — so an editor whose
local binary emits only one is not tempted to prune the other; leave a
comment saying why. Prefer one function-scope directive on the enclosing
stub over scattered line-level ones. Never begin a comment line with the
linter's own name — shellcheck parses it as a directive and raises SC1073
(an error, worse than the info it was meant to silence).

## Verify shellcheck with a bare invocation, never `-S warning`

The pre-commit gate runs `shellcheck` at its **default** severity (which
includes `info`), with no `-S`/`--severity` flag — see the shellcheck hook in
`.pre-commit-config.yaml`. Verifying a script locally with `shellcheck -S
warning <file>` raises the severity floor above what the real gate enforces,
so it can report `rc=0` clean on a file the actual commit gate then rejects
(e.g. SC2317/SC2329, which report at `info`). Verify with a bare `shellcheck
<file>` to match the gate exactly.

## Detecting and repairing NUL-page file corruption after a shadow-copy restore

A restore from a Volume Shadow Copy (or similar snapshot mechanism) can come
back with files **NUL-filled by 4096-byte page** — some entirely NUL, some
intact then NUL to the original size, some NUL at the head with real content
after. Sizes and mtimes look normal, so this is a silent time bomb: a
NUL-page file is the right size, parses as empty or garbage, and `git
status` stays clean because git's stat cache trusts size+mtime rather than
content.

**How to apply:**
- Detect in a git tree with `git update-index --really-refresh` then `git
  status` (or compare `git hash-object <f>` against `git rev-parse
  HEAD:<f>`); repair with `git show HEAD:<f> > <f>` (`git restore` /
  `checkout-index` no-op against a stat cache that is lying).
- Detect outside git by scanning: a real text file never contains a full
  4096-byte NUL page. Scan **every** 4096-aligned page, not just the
  trailing run — a trailing-run-only heuristic misses head-NUL corruption.
- Tools that self-repair by moving a corrupt file aside (`*.corrupt*`,
  `.bak`) and continuing may then run on an empty config silently — check
  for those siblings and splice the backup's head onto the surviving tail.
- Disposable trees (plugin caches, temp checkouts, build caches) → delete
  and reinstall; corrupted git packs/indexes → re-clone rather than repair.

## A fresh worktree has no `node_modules` outside `scripts/jira`

`scripts/worktree.sh` (and `_new-worktree.sh`) installs only the Jira
CLI's deps into a new worktree. Every other node package a suite depends on
(`scripts/bitbucket`, `scripts/ci-orchestrator`,
`marketplace/plugins/obsidian-triage/tools`, vitest under `scripts/jira`)
starts empty, so its suites SKIP, or FAIL with a verdict that looks
pre-existing. It happened three times in one shift (a structural fix is
planned).

**What to do:** before calling a SKIP or FAIL pre-existing, check that the
suite's test runner is installed in the owning package (e.g.
`node_modules/.bin/vitest`), not just that `node_modules` exists:
`scripts/jira` has a `node_modules` from the `--omit=dev` install, but no
vitest. If the runner is missing, run `npm ci` in that package
(`--ignore-scripts` where a postinstall downloads browsers) and re-run the
suite.

## Claude Code: "SessionEnd hook … failed: Hook cancelled" at exit

Claude Code gives SessionEnd hooks one shared **1.5 s** budget on exit, `/clear`
and interactive `/resume`, and cancels whatever has not returned (docs:
<https://code.claude.com/docs/en/hooks>, SessionEnd section). A per-hook
`timeout` raises the budget (up to 60 s) only when it is set in your own
settings files; timeouts declared by a **plugin** hook do not raise it, and
`CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` (set in the launching shell) overrides
it explicitly. Hooks for one event run in parallel.

So the himmel-ops `SessionEnd` entries (declared `timeout: 3`) really run under
1.5 s. Their parents full-body detach (`__himmel_detached` + `lib/detach.sh`) and
return in about 50 ms each (measured 40–70 ms over 5 runs per hook, on a host at
load ~24 from other sessions; `test-session-end-timeout-budget.sh` pins the
detach with an injected 10 s child delay). A cancel means the hook did not
return before the shared budget; under severe load that can include failing to
start or return from the detached parent. The lost work is classified:

| hook | class | a cancel costs |
|---|---|---|
| `refresh-where-are-we-on-end.sh` | next-start catch-up | stale digest; `inject-where-are-we.sh` re-spawns the refresh at the next SessionStart when the ledger is older than `HIMMEL_WHERE_ARE_WE_STALE_HOURS` |
| `jira-nudge-on-end.sh` | best-effort | one advisory Jira line |
| `telegram-session-end.sh` | best-effort | one Telegram end message |
| `session-lifecycle-hook.mjs` (openai-codex plugin, not ours) | best-effort | the Codex broker and job state are not torn down; nothing himmel reads (no ledger, no HUD, no `HimmelSessionDead` input). `bump-codex-sessionend-timeout.sh` cannot raise it, because plugin timeouts do not raise the budget |

Guaranteed regardless of a cancel: the armed-resume launcher's own end path
(flow-run ledger `--classify` / `--append-end`, `scripts/handover/arm-resume.sh`)
runs from the launcher, not a hook, so the flow ledger is intact. Not guaranteed:
the session-runs end row (`session-run-hook.ts`, enqueued through
`stop-queue.mjs` from `.claude/settings.json`). A cancel there leaves a ghost
session that `session_dead_total` / `HimmelSessionDead` (severity `warn`) counts
as dead; `stop-queue.mjs` writes its `attempt` row first, so the cancel is
visible in `queue.jsonl`.
