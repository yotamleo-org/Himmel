# shellcheck shell=bash
# sourced-lib: only ever sourced by the test-himmel-doctor parts; the parts run in the environment their caller gives them
# shellcheck disable=SC2034

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# anchored to THIS SCRIPT's own location, not `git rev-parse
# --show-toplevel` (which resolves against the CALLER's cwd instead). That
# distinction was invisible as long as every check this suite exercises
# existed identically in every checkout -- but check_c32 is
# new and, until this branch merges, lives ONLY in this worktree's copy of
# scripts/himmel-doctor.sh. Invoked via an absolute path from a cwd outside
# this worktree (e.g. the primary checkout), `--show-toplevel` silently
# resolved to that OTHER repo's himmel-doctor.sh -- missing check_c32
# entirely -- and every C32 assertion failed with an EMPTY actual value
# (grep found nothing to report), while every pre-existing check still
# passed because those are identical in both copies. Same fix shape as the
# sibling test files in this directory (test-check-plugin-drift.sh,
# test-plugin-test.sh: `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$REPO_ROOT/scripts/himmel-doctor.sh"
[ -f "$DOC" ] || { echo "FAIL: $DOC not found"; exit 1; }
CADENCE_VER="$(sed -n 's/^CADENCE_RUNNER_FORMAT_VERSION=//p' "$REPO_ROOT/scripts/lib/cadence-format.sh" | head -1)"
STALE_CADENCE_VER=$((CADENCE_VER - 1))

# Hermeticity: never let an inherited LUNA_VAULT_PATH point C3 at the operator's
# real vault (HOME is redirected per-case, but C3 probes $LUNA_VAULT_PATH first).
export LUNA_VAULT_PATH=""

# Hermeticity: same reasoning for C26 and SALUS_VAULT_PATH — HOME is redirected
# per-case, but C26 probes $SALUS_VAULT_PATH first and would otherwise pick up
# an inherited value pointing at the operator's real salus vault.
export SALUS_VAULT_PATH=""

# Hermeticity: same reasoning for C27 and CLAUDE_GLM_CONFIG_DIR — HOME is
# redirected per-case so the default ~/.config/claude-glm already resolves
# under the per-case temp HOME, but an inherited CLAUDE_GLM_CONFIG_DIR from the
# launching shell would otherwise point C27 at the operator's real config dir.
export CLAUDE_GLM_CONFIG_DIR=""

# Hermeticity: C28 reads himmelctl's own state.json (recorded
# guardrail-block-global consent) at ${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}
# — HOME is redirected per-case so the default already resolves under the
# per-case temp HOME, but an inherited HIMMELCTL_CACHE_DIR from the launching
# shell would otherwise point C28 at the operator's real himmelctl state.
export HIMMELCTL_CACHE_DIR=""

# Hermeticity: C31 resolves the codex config through
# $CODEX_HOME (default $HOME/.codex) — HOME is redirected per-case so the
# default already lands in the temp HOME, but an inherited CODEX_HOME from
# the launching shell would otherwise point C31 at the operator's real codex
# config, and whatever that config happens to wire would flip every
# unrelated case unpredictably. Dedicated C31 cases set it per-case.
export CODEX_HOME=""

# Hermeticity: C33 resolves the graph-cadence ledger via
# handover_root(), which honors $HANDOVER_DIR first, else falls back to
# <repo-root>/handovers (git-toplevel-relative, NOT HOME-relative — the
# per-case HOME redirection every other check's hermeticity leans on does
# NOT reach this fallback). Left unset, C33 would read the REAL repo's
# tracked handovers/ stub in every default case. Point it at a fixed, empty
# scratch dir instead so C33 always reports "ledger absent" unless a
# dedicated C33 case overrides it.
HIMMEL_DOCTOR_NOOP_HANDOVER="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-tests-handover.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
export HANDOVER_DIR="$HIMMEL_DOCTOR_NOOP_HANDOVER"
# Never inspect the operator's bank policy in unrelated doctor fixtures.
export USAGE_LIFT_FILE="$HIMMEL_DOCTOR_NOOP_HANDOVER/no-lift.json"

# Hermeticity: C14 reads OLLAMA_NO_CLOUD from the live env — never let an
# inherited value from the launching shell leak into the default test runs.
unset OLLAMA_NO_CLOUD

# C19 performs local HTTP probes and reads the installed observability tree.
# Keep every unrelated case hermetic; dedicated C19 cases opt back in.
export DOCTOR_OBSERVABILITY_SKIP=1

# Hermeticity: C20 now FAILS on node-major drift, and it reads the
# REAL node/.nvmrc in every case that does not seam them — so on a drifted host
# it would flip the exit code of every unrelated case here. Bypass it globally;
# the C20 cases set NODE_MAJOR_DRIFT_OK=0 (and CI/GITHUB_ACTIONS empty) per-case.
export NODE_MAJOR_DRIFT_OK=1

# C65 reads the REAL checkout's git hooks and branch protection; a CI checkout has no dev hooks,
# so cases that blank CI would FAIL there. Skip it globally; the C65 cases opt back in.
export DOCTOR_C65_SKIP=1

# Hermeticity: C21 reads the operator's REAL hermes install
# (LOCALAPPDATA/hermes) unless seamed — point it at a nonexistent dir globally
# (check_c21's `[ ! -d ]` guard) so unrelated cases get a deterministic
# "no hermes install found" INFO instead of leaking this machine's actual
# active profile. Dedicated C21 cases seam it per-case with their own fixture.
DOCTOR_HERMES_HOME_EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-nohermes.XXXXXX")/no-hermes" || { echo "FAIL: mktemp -d failed"; exit 1; }
export DOCTOR_HERMES_HOME="$DOCTOR_HERMES_HOME_EMPTY"

# C25 performs a live platform process scan (PowerShell CIM on
# Windows, ps on POSIX). Keep every unrelated case hermetic and
# host-independent -- what real processes run must never flip a test verdict;
# dedicated C25 cases opt back in via the shim seam.
export DOCTOR_ORPHAN_SCAN_SKIP=1

# Hermeticity: C29 scans the REAL /proc tree for claude
# child-session launchers unless seamed -- this dev box routinely has several
# such workers running right now, and every
# unrelated case would otherwise pick up a WARN C29-child-session it is not
# testing. Point at a nonexistent dir globally (check_c29's `[ ! -d ]` guard
# reads that as a clean procfs-absent skip, never a false WARN); dedicated
# C29 cases seam it per-case with their own stub tree.
HIMMEL_DOCTOR_PROC_BASE="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-noproc.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
export HIMMEL_DOCTOR_PROC="$HIMMEL_DOCTOR_PROC_BASE/no-proc"

# Hermeticity: C24's systemd probe and C30 both resolve through
# systemctl via this seam -- and on THIS station it is not just present but
# ENABLED and ACTIVE (a real, operator-depended-on telegram-bridge.service).
# tool_dirs()'s PATH scrub does not save us here the way it does for gh/node:
# systemctl lives in /usr/bin on this Arch/CachyOS box, the SAME dir every
# other whitelisted tool (git, jq, sed, ...) resolves through, so TOOLS_PATH
# would still find the real binary. Point the seam at a nonexistent absolute
# path globally (`command -v` on an absolute path never falls through to
# PATH, so this is a clean "systemctl absent" regardless of what tool_dirs()
# picks up); dedicated C24/C30 cases override it per-case with their own fake
# systemctl. Never invoke the REAL systemctl against telegram-bridge.service
# from this suite -- read-only verification of it happens by hand, at most
# once, outside the test run.
#
# Templated + guarded mktemp: matches the C29 seam directly
# above, not DOCTOR_HERMES_HOME_EMPTY's untemplated form near the top of this
# file -- C29's is the more recent convention (this seam's own dedicated test
# rows already use it), and it also drops the one shell-lint mktemp advisory
# an untemplated `mktemp -d` draws here instead of leaving it for a reviewer
# to raise.
HIMMEL_DOCTOR_SYSTEMCTL_BASE="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-nosystemctl.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
export HIMMEL_DOCTOR_SYSTEMCTL="$HIMMEL_DOCTOR_SYSTEMCTL_BASE/no-systemctl"

# Hermeticity: C24 reads the user's crontab to walk every # HIMMEL-... row's runner and script. A real
# crontab is read by uid, so a dead row on the dev box would turn every unrelated case red and print a
# path into the log. Put an empty crontab first on PATH for the whole suite; dedicated C24 cases put their
# own stub in front of it.
DOCTOR_CRON_STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-nocrontab.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
printf '#!/bin/sh\nexit 0\n' > "$DOCTOR_CRON_STUB_DIR/crontab"
chmod +x "$DOCTOR_CRON_STUB_DIR/crontab"
export PATH="$DOCTOR_CRON_STUB_DIR:$PATH"

# Hermeticity: C8's runner-home defaults resolve via
# cadence_user_home (USERPROFILE via cygpath on Windows) — per-case HOME
# redirection does NOT cover that, so pin all four seams to empty dirs
# globally; C8 cases override them per-case. EVERY seam in C8's table must be
# pinned here: an unpinned one falls through to the operator's REAL
# ~/.claude/<cadence> dir, so an armed cadence on the dev box would leak into
# the "no armed cadence runners" and "no false nudges" cases (added
# the qmd seam).
C8_EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c8.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
export PIPELINE_BAT_DIR="$C8_EMPTY/pipeline" GRAPHMAP_BAT_DIR="$C8_EMPTY/graphmap" QMD_CADENCE_BAT_DIR="$C8_EMPTY/qmd" GRAPH_CHOICES_BAT_DIR="$C8_EMPTY/graph-choices"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# PATH that has every tool the doctor/scripts need EXCEPT node and gh (so the
# no-node and gh-absent branches are exercisable). node lives in its own dir.
tool_dirs() {
    local t d; for t in git jq sort sed cat date mktemp dirname uname wc tr head cp rm mv chmod; do
        d="$(command -v "$t" 2>/dev/null)" && dirname "$d"
    done | sort -u | tr '\n' ':'
}
TOOLS_PATH="$DOCTOR_CRON_STUB_DIR:$(tool_dirs)"

# fake uname=Linux (to exercise the non-Windows --fix path on this MINGW box)
FAKEROOT="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-fakeroot.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }; FAKEBIN="$FAKEROOT/bin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho Linux\n' > "$FAKEBIN/uname"; chmod +x "$FAKEBIN/uname"

# Keep unrelated cases from probing the operator's real qmd daemon on
# localhost:8181 for C40: an absent curl seam makes C40 an INFO
# skip. Dedicated C40 cases override this seam per invocation with a stub curl.
export HIMMEL_DOCTOR_QMD_CURL="$FAKEROOT/no-such-curl"
# Same for C45-qmd-daemon: never read the operator's real qmd
# pidfile; dedicated cases point this seam at a fixture.
export HIMMEL_DOCTOR_QMD_PIDFILE="$FAKEROOT/no-such-pidfile"
# Same for C47-runaway-procs: never scan the operator's real
# process table; an absent ps seam makes C47 silent, dedicated cases stub it.
export HIMMEL_DOCTOR_RUNAWAY_PS="$FAKEROOT/no-such-ps"
# Same for C54-hook-copy-reaper: never run the real reaper over
# the operator's process table; an absent script makes C54 silent, dedicated
# cases stub it.
export HIMMEL_DOCTOR_HOOK_REAPER="$FAKEROOT/no-such-reaper"
# Same for C48-tmp-usage: never read the operator's real /tmp
# fill level; an absent df seam makes C48 silent, dedicated cases stub it.
export HIMMEL_DOCTOR_TMP_DF="$FAKEROOT/no-such-df"
# Same for C71-verdict-scratch: never size the operator's real judge cache;
# an absent dir is an OK skip, dedicated cases point at a fixture.
export HIMMEL_DOCTOR_VERDICT_CACHE="$FAKEROOT/no-such-verdict-cache"
# Same for C73-bun-compiled: never scan the operator's real ~/.local/bin; an
# absent dir is an OK skip, dedicated cases point at a fixture.
export HIMMEL_DOCTOR_BUN_SCAN_DIRS="$FAKEROOT/no-such-bin"
# Same for C74-config-split: never list the operator's real .env key names; an
# absent file is an OK skip, dedicated cases plant a fixture .env.
export HIMMEL_DOCTOR_ENV_FILE="$FAKEROOT/no-such-env"
# Same for C75-keyring: never look up the operator's real keyring; dedicated
# cases turn it back on against a stub secret-tool and busctl.
export HIMMEL_SECRETS_KEYRING=off
# Same for C49-qmd-embed-model: never read the operator's real
# qmd index; an absent index makes C48 silent, dedicated cases point at a fixture.
export HIMMEL_DOCTOR_QMD_INDEX="$FAKEROOT/no-such-index.sqlite"
# Same for C50-qmd-fork-stamp: never read the operator's real qmd
# fork clone or QMD_FORK_REF; an unset dir resolves to a nonexistent fixture path.
export QMD_FORK_DIR="$FAKEROOT/no-such-qmd-fork"
unset QMD_FORK_REF
# Same for C51-firecrawl-parked: never read the operator's real
# parked-items state; an absent file is OK, dedicated cases point at a fixture.
export HIMMEL_FIRECRAWL_PARKED="$FAKEROOT/no-such-parked.jsonl"
# Same for C52-graphify-ollama: never run the operator's real uv
# graphifyy venv python; an absent venv is OK, dedicated cases point at a fixture.
export HIMMEL_DOCTOR_GRAPHIFY_VENV="$FAKEROOT/no-such-graphify-venv"
# Same for C53-vm-mode: never probe the operator's real VM; an
# absent probe seam makes C53 report the mode only, dedicated cases stub it.
export HIMMEL_DOCTOR_VM_PROBE="$FAKEROOT/no-such-vm-probe"
# Same for C59-codex-bank-cache: never read the operator's real
# codex bank cache; an absent file is INFO, dedicated cases point at a fixture.
export CODEX_USAGE_CACHE="$FAKEROOT/no-such-codex-bank.json"
export HIMMEL_DOCTOR_LIVE_TEST_PROBE="$FAKEROOT/no-such-live-test-probe"

# Same for C60/C61: never read the operator's real hermes checkout
# or run the real codex CLI / npm registry; absent seams are an INFO skip,
# dedicated cases point them at fixtures.
export DOCTOR_HERMES_CHECKOUT="$FAKEROOT/no-such-hermes-checkout"
export DOCTOR_CODEX_BIN="$FAKEROOT/no-such-codex"
unset DOCTOR_CODEX_LATEST
# Same for C64-vm-runner: never run the real vm-runner.sh doctor
# (it would probe the operator's VirtualBox and GitHub); absent seam = INFO skip.
export DOCTOR_VM_RUNNER="$FAKEROOT/no-such-vm-runner.sh"
# C63: never run the operator's real claude; absent seam = INFO.
export DOCTOR_CLAUDE_BIN="$FAKEROOT/no-such-claude"

# Keep unrelated cases from probing the operator's real qmd 'skills'
# collection for C44: most invocations below never override
# PATH, so an inherited bun/qmd install would otherwise make check_c44 run a
# LIVE `qmd collection list` and leak this machine's real collection state
# (missing here) into every unrelated "clean -> rc0" assertion. Point the
# seam at a nonexistent path so unrelated cases get a deterministic INFO
# skip; dedicated C44 cases override it per invocation with their own stub.
export HIMMEL_DOCTOR_SKILL_INDEX_QMD="$FAKEROOT/no-such-skill-qmd"

# Same for C46: never run the operator's real `claude plugin list`;
# an absent seam is an INFO skip, dedicated C46 cases point it at a stub.
export HIMMEL_DOCTOR_CLAUDE_BIN="$FAKEROOT/no-such-claude"

# Keep unrelated cases from scanning this checkout's own .mcp.json files (and the
# operator's generated mcp-profiles) for C41: point the scan root at
# an empty dir. HOME is redirected per case, so ~/.claude.json is already hermetic.
# Dedicated C41 cases override this seam per invocation.
mkdir -p "$FAKEROOT/no-mcp-root"
export HIMMEL_DOCTOR_MCP_ROOT="$FAKEROOT/no-mcp-root"

# Keep unrelated cases from scanning the operator's real worktree garden (and
# making live forge calls). Dedicated C7 cases override this seam per invocation.
DOCTOR_WT_EMPTY="$FAKEROOT/doctor-wt-empty"; mkdir -p "$DOCTOR_WT_EMPTY"
export DOCTOR_WORKTREE_ROOT="$DOCTOR_WT_EMPTY"

# Keep unrelated cases from scanning this checkout's own local branches for
# C23 (and making live gh calls). Dedicated C23 cases override this seam.
DOCTOR_UNLANDED_EMPTY="$FAKEROOT/doctor-unlanded-empty"; mkdir -p "$DOCTOR_UNLANDED_EMPTY"
export DOCTOR_UNLANDED_DIR="$DOCTOR_UNLANDED_EMPTY"

# Keep unrelated cases from running the real sweep-health check for C42
#  (it makes live gh calls and reads the operator's real branches): a
# stub that prints nothing and exits 0. Dedicated C42 cases override this seam.
DOCTOR_SWEEP_HEALTH_STUB="$FAKEROOT/sweep-health-clean.sh"
printf '#!/bin/sh\nexit 0\n' > "$DOCTOR_SWEEP_HEALTH_STUB"
export DOCTOR_SWEEP_HEALTH_SCRIPT="$DOCTOR_SWEEP_HEALTH_STUB"

# A fake node so "node resolvable" cases are deterministic regardless of whether
# the host actually has node (a node-less Linux box would otherwise FAIL them).
FAKENODE="$FAKEROOT/nodebin"; mkdir -p "$FAKENODE"
printf '#!/bin/sh\necho v20\n' > "$FAKENODE/node"; chmod +x "$FAKENODE/node"

# A curated PATH with the tools the doctor needs but WITHOUT gh — for the
# gh-absent case. On Linux gh shares /usr/bin with coreutils, so excluding a dir
# won't drop it; symlink only the needed tools instead.
NOGH="$FAKEROOT/nogh"; mkdir -p "$NOGH"
for _tool in bash sh git jq sort tail sed cat date mktemp mkdir dirname uname wc tr head cp rm mv chmod grep basename; do
    _p="$(command -v "$_tool" 2>/dev/null)" && ln -sf "$_p" "$NOGH/$_tool" 2>/dev/null
done

# $1=claude dir, $2=JSON-encoded SessionStart hook command
write_settings() {
    mkdir -p "$1"
    cat > "$1/settings.json" <<EOF
{ "hooks": {
  "SessionStart": [ { "hooks": [ { "type": "command", "command": $2 } ] } ],
  "UserPromptSubmit": [] } }
EOF
}
WRAPPER='"bash \"/x/scripts/lib/run-node.sh\" \"/y/hooks/session-start.js\""'

# write_guardrail_settings <claude-dir> <node-path> — writes a settings.json
# whose hooks.PreToolUse carries the 3 user-level guardrail entries in the
# EXACT shape guardrail-block.mjs generates for --guardrail-mode global
# pointed at <node-path>; SessionStart/UserPromptSubmit stay empty.
write_guardrail_settings() {
    local claude_dir="$1" node_path="$2" bash_path wrapper
    mkdir -p "$claude_dir"
    bash_path="$(command -v bash)"
    if command -v cygpath >/dev/null 2>&1; then bash_path="$(cygpath -m "$bash_path")"; fi
    wrapper="$REPO_ROOT/scripts/hooks/guardrail-skip-in-himmel.js"
    # MSYS_NO_PATHCONV: jq is a native exe; Git Bash would rewrite the C:/... node path inside --arg into a C;C:\... path list.
    MSYS_NO_PATHCONV=1 jq -n \
        --arg c1 "GUARDRAIL_BASH=\"$bash_path\" \"$node_path\" \"$wrapper\" \"$REPO_ROOT/scripts/hooks/auto-approve-safe-bash.sh\"" \
        --arg c2 "GUARDRAIL_BASH=\"$bash_path\" \"$node_path\" \"$wrapper\" \"$REPO_ROOT/scripts/hooks/block-edit-on-main.sh\"" \
        --arg c3 "GUARDRAIL_BASH=\"$bash_path\" \"$node_path\" \"$wrapper\" \"$REPO_ROOT/scripts/hooks/block-read-secrets.sh\"" \
        '{ hooks: {
            SessionStart: [],
            UserPromptSubmit: [],
            PreToolUse: [
                { matcher: "Bash", hooks: [ { type: "command", command: $c1 } ] },
                { matcher: "Edit|Write|MultiEdit|NotebookEdit", hooks: [ { type: "command", command: $c2 } ] },
                { matcher: "Bash|PowerShell|Read|Grep", hooks: [ { type: "command", command: $c3 } ] }
            ]
        } }' > "$claude_dir/settings.json"
}

make_gh() { # $1=dir, $2=create|exists
    mkdir -p "$1"
    if [ "$2" = exists ]; then LIST='echo "[{\"title\":\"[himmel-doctor] old\",\"url\":\"http://x/1\"}]"'; else LIST='echo "[]"'; fi
    cat > "$1/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "issue list") $LIST ;;
  "issue create") echo "CREATE \$4" ;;
esac
EOF
    chmod +x "$1/gh"
}

# fake_systemctl <dir> <state> [mainpid] [nrestarts] — a stub `systemctl`
# used by both C24's HimmelTelegramBridge probe and C30. Never
# touches anything real; only answers `--user is-enabled <unit>` and
# `--user show <unit> -p <MainPID|NRestarts> --value`, the exact two shapes
# check_c24/check_c30 invoke. <state> (every literal is-enabled text below
# was VERIFIED against this box's real systemd 261 -- `man systemctl` Table 3
# plus live is-enabled queries against real units in each state, none of
# them telegram-bridge.service -- not assumed; E1, which
# caught an earlier "could not be found" guess that real systemd never
# actually prints for a missing unit):
#   enabled         — is-enabled prints "enabled", rc 0
#   enabledruntime  — is-enabled prints "enabled-runtime", rc 0 (E1: also
#                     counts as armed, same as "enabled" -- a runtime-only
#                     enablement symlink, not a permanent one)
#   disabled        — is-enabled prints "disabled", rc 1 (installed, not armed)
#   notfound        — is-enabled prints "not-found" (verified literal, rc 4)
#                     -- the unit file does not exist on this host at all
#   busfail         — is-enabled prints THIS STATION's own real bus-failure
#                     wording, rc 1 (transient/environment failure -- must
#                     NOT read as absence). Captured from a
#                     genuine forced failure, not guessed --
#                     `XDG_RUNTIME_DIR=/nonexistent DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
#                     systemctl --user is-enabled telegram-bridge.service`
#                     on this box (systemd 261) prints exactly:
#                       "Failed to connect to user scope bus via local transport: No such file or directory"
#                     An earlier version of this stub emitted the OLDER
#                     systemd wording below instead, which the production
#                     pattern at the time only matched by coincidence of
#                     testing itself against its own guess -- the stub and
#                     the code agreed with each other and both disagreed
#                     with the real machine; this row would have passed
#                     while proving nothing about the "unknown" branch
#                     actually firing. Re-capture with the same reproduction
#                     if this station's systemd version ever changes the
#                     wording again.
#   busfailold      — the OLDER systemd wording ("Failed to connect to bus:
#                     ..."), covered by its own row so both forms are
#                     verified by a test row, not just asserted in a comment.
#   permdenied — an unrecognized/failed is-enabled
#                     answer that is NEITHER a named enablement state NOR the
#                     bus-unreachable wording above -- the shape that used to
#                     fall through _systemd_user_unit_state's `*)` wildcard
#                     into "disabled" (asserting the unit IS installed on no
#                     evidence) before this ticket's fix made that bucket
#                     "unknown" instead. This literal wording is INVENTED,
#                     not captured from a real permission-denied is-enabled
#                     invocation -- two attempts to force a genuine one on
#                     this box (chmod 000 on a fixture unit file under
#                     ~/.config/systemd/user, and chmod 000 on that directory
#                     itself, each followed by daemon-reload) both had this
#                     station's systemd fall back to "not-found" rather than
#                     surfacing any permission string, so a real repro was not
#                     obtained. The wording below follows systemd's
#                     documented "Failed to X: %m" error-message shape (%m
#                     expanding to the errno string), which is plausible but
#                     UNVERIFIED -- treat it as a stand-in for "some
#                     unrecognized failed answer", not as a verified literal.
#
# <mainpid>/<nrestarts> normally carry the literal `show -p ...` value to
# print (any literal text works here already, e.g. "abc" -- so a
# non-numeric-but-non-empty success case needs no sentinel at all), but
# either may instead be one of two sentinels:
#   FAIL: makes the corresponding `--user show
#         <unit> -p <MainPID|NRestarts> --value` query FAIL (rc 1, nothing
#         on stdout) while `is-enabled` still answers per <state> as normal
#         -- is-enabled and show are two separate invocations in
#         check_c30/_c24_cron_has_task's caller, and this is what lets a
#         test row fail ONLY the show query without touching the
#         is-enabled gate above it.
#   EMPTY: makes the query SUCCEED (rc 0) but print
#         nothing -- distinct from FAIL, and from a literal "0", because
#         `${3:-0}`/`${4:-0}` cannot represent a genuinely empty value
#         through normal argument defaulting (bash treats an empty arg the
#         same as an unset one). Needed to prove a successful-but-unreadable
#         query is read as UNDETERMINED, never as a live "MainPID=0".
# shellcheck disable=SC2016  # $state/$mainpid/$nrestarts are meant to reach the fake binary's own /bin/sh unexpanded
fake_systemctl() {
    local dir="$1" state="$2" mainpid="${3:-0}" nrestarts="${4:-0}" enter_ts="${5:-}"
    mkdir -p "$dir"
    {
        printf '#!/bin/sh\n'
        printf 'enter_ts=%s\n' "'$enter_ts'"
        printf 'state=%s\n' "$state"
        printf 'mainpid=%s\n' "$mainpid"
        printf 'nrestarts=%s\n' "$nrestarts"
        cat <<'SCRIPT'
if [ "$1" = "--user" ] && [ "$2" = "is-enabled" ]; then
    case "$state" in
        enabled) echo enabled; exit 0 ;;
        enabledruntime) echo enabled-runtime; exit 0 ;;
        disabled) echo disabled; exit 1 ;;
        notfound) echo not-found; exit 4 ;;
        busfail) echo "Failed to connect to user scope bus via local transport: No such file or directory" >&2; exit 1 ;;
        busfailold) echo "Failed to connect to bus: No such file or directory" >&2; exit 1 ;;
        permdenied) echo "Failed to get unit file state for telegram-bridge.service: Permission denied" >&2; exit 1 ;;
        unrecognised) printf 'invented future state\nsecond diagnostic line\n'; exit 1 ;;
    esac
elif [ "$1" = "--user" ] && [ "$2" = "show" ]; then
    shift 2; shift # drop --user show <unit>
    prop="" prev=""
    for a in "$@"; do
        [ "$prev" = "-p" ] && prop="$a"
        prev="$a"
    done
    case "$prop" in
        MainPID)
            if [ "$mainpid" = "FAIL" ]; then
                echo "Failed to get properties: Transport endpoint is not connected" >&2
                exit 1
            fi
            if [ "$mainpid" = "EMPTY" ]; then
                printf '\n'
            else
                printf '%s\n' "$mainpid"
            fi ;;
        ActiveEnterTimestamp) printf '%s\n' "$enter_ts" ;;
        NRestarts)
            if [ "$nrestarts" = "FAIL" ]; then
                echo "Failed to get properties: Transport endpoint is not connected" >&2
                exit 1
            fi
            if [ "$nrestarts" = "EMPTY" ]; then
                printf '\n'
            else
                printf '%s\n' "$nrestarts"
            fi ;;
    esac
    exit 0
fi
exit 1
SCRIPT
    } > "$dir/systemctl"
    chmod +x "$dir/systemctl"
}
