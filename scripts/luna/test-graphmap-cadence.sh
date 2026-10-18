#!/usr/bin/env bash
# Smoke test for scripts/luna/graphmap-cadence.sh.
#
# Two daily cadence tasks are armed: HIMMEL-GraphMap-Luna (daily 13:00 ->
# refresh-graph-map.sh --name luna ...) and HIMMEL-GraphMap-Himmel (daily
# 13:20 -> refresh-graph-map.sh --name himmel ...). Unlike pipeline-cadence
# these runners fire a DETERMINISTIC script (bash refresh-graph-map.sh ...),
# NOT a claude session — so there is no --settings fragment, no NUL stdin, no
# auto-approve hook to assert.
#
# Strategy (hermetic — mirrors test-pipeline-cadence.sh): replace the
# scheduler with a fake — crontab via the GRAPHMAP_CRONTAB seam (a state-file
# crontab supporting -l and - install); point GRAPHMAP_BAT_DIR at a temp dir
# so the runners (.sh) are inspectable; put a fake `bash` first on PATH so arm
# resolves the stub, never the real interpreter. HOME/USERPROFILE point at the
# temp dir so nothing touches the real user profile. The POSIX path is forced
# with an OSTYPE override.
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/graphmap-cadence.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# validate_arm_inputs refuses to arm when the semantic backend's
# credential is not readable from the .env that survives to fire time (an
# API-key backend like glm/deepseek; claude-cli itself is credential-free). GRAPHMAP_DOTENV_ROOT pins WHICH .env is consulted, so the suite
# asserts both outcomes without depending on the operator's real .env — before
# this seam the negative test only passed on a machine that happened not to
# have the key, i.e. it would have broken the moment someone followed the arm
# instructions. Populated in setup_dotenv_root below (TMP_ROOT is not created
# until later in this file).
DOTENV_ROOT=""
DOTENV_ROOT_EMPTY=""
setup_dotenv_root() {
    DOTENV_ROOT="$TMP_ROOT/dotenv-root"
    DOTENV_ROOT_EMPTY="$TMP_ROOT/dotenv-root-empty"
    mkdir -p "$DOTENV_ROOT" "$DOTENV_ROOT_EMPTY"
    # BACKEND is claude-cli, which validate_backend_credential
    # classifies as credential-free (`return 0` before ever reading a key
    # var), so this .env's content is inert for the default (ambient) path —
    # kept as a placeholder .env only so GRAPHMAP_DOTENV_ROOT points at a real
    # directory; ZAI_API_KEY/DEEPSEEK_API_KEY are the only keys the check can
    # still fail on, and no test exercises that path (BACKEND has no flag).
    printf 'ZAI_API_KEY=test-zai-key-not-a-real-credential
' > "$DOTENV_ROOT/.env"
    export GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT"
    # Announces the hermetic suite; the credential seam refuses to redirect
    # without it, so no production arm can reach the redirect.
    export GRAPHMAP_TEST_MODE=1
}

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
assert_registry() {
    local name="$1" expression="$2"
    if jq -e "$expression" "$HIMMEL_OBSERVABILITY_CONFIG" >/dev/null 2>&1; then pass "$name"; else fail "$name" "registry assertion failed: $expression"; fi
}
# assert_before <name> <first> <second> <haystack> — <first> must occur at a
# LOWER byte offset than <second> in <haystack> (both must be present). Used
# to prove element ORDER in emitted XML, not just presence (e.g. Repetition is a base-type element and must precede the ScheduleByX
# choice in a CalendarTrigger, or schtasks /create /xml can reject it).
assert_before() {
    # Piping grep -bo into head risks the same SIGPIPE/pipefail trap grepq's
    # header comment documents: head -1 can close the pipe while
    # grep is still writing, so under `set -o pipefail` the pipeline's status
    # is grep's SIGPIPE death, not head's success. `|| true` absorbs that (the
    # captured output — the first line head read before closing — is correct
    # either way); a genuine no-match also exits nonzero and is likewise caught.
    local name="$1" first="$2" second="$3" haystack="$4" off_first off_second
    off_first=$(grep -bo -F -- "$first" <<< "$haystack" | head -1) || true
    off_second=$(grep -bo -F -- "$second" <<< "$haystack" | head -1) || true
    off_first="${off_first%%:*}"
    off_second="${off_second%%:*}"
    if [ -z "$off_first" ] || [ -z "$off_second" ]; then
        fail "$name" "missing element(s): '$first' (off=$off_first) '$second' (off=$off_second)"
    elif [ "$off_first" -lt "$off_second" ]; then
        pass "$name"
    else
        fail "$name" "expected offset('$first')=$off_first < offset('$second')=$off_second"
    fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi
# Arms record a provenance row; never into the operator's ledger.
export HIMMEL_PROVENANCE_DIR="$TMP_ROOT/provenance"
setup_dotenv_root

# Shared fixtures ------------------------------------------------------------

# The interpreter that runs the script under test. Resolved BEFORE the fake
# bash below shadows PATH: `env PATH=... bash` would exec the FAKE via the NEW
# PATH, and on Linux the fake's own `#!/usr/bin/env bash` shebang re-resolves
# to itself -> infinite exec loop -> the whole suite hangs to the CI timeout
# (broke public CI on ubuntu; Git Bash dodges it only because the mixed-form
# C:/ PATH entry loses the lookup there).
REAL_BASH="$(command -v bash)"

# Fake bash on PATH (arm resolves it via `command -v bash`). A no-op stub is
# enough — the tests assert runner TEXT, they never fire the runner. Shebang
# is /bin/sh (absolute) so the stub can never shebang-recurse into itself.
# The stub is PLATFORM-NAMED. An EXTENSIONLESS file called
# `bash` makes Windows ShellExecute return SE_ERR_NOASSOC, which pops the
# "Select an app to open 'bash'" picker — a modal that hangs an unattended
# cadence run with nobody there to dismiss it. HERMETIC_EXE_SUFFIX is CONSUMED
# from scripts/lib/hermetic-path.sh (where the reader,
# path_dir_has_scrubbed_tool, lives too) rather than re-derived here, so the
# writer and reader sides cannot drift.
# shellcheck source=../lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/hermetic-path.sh"
mkdir -p "$TMP_ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/bin/bash$HERMETIC_EXE_SUFFIX"
chmod +x "$TMP_ROOT/bin/bash$HERMETIC_EXE_SUFFIX"

# The assertion, ported from scripts/test-adopt.sh: the
# platform-named stub must EXIST, and on Windows no extensionless `bash` may
# be created. The expected suffix comes from an INDEPENDENT platform probe,
# never from HERMETIC_EXE_SUFFIX — reusing the writer's own value makes the
# check tautological (a regression to an empty suffix would move both sides
# together and still match). `find` with a literal -name match is REQUIRED for
# the rejection branch: on MSYS/Git-Bash `test -e` resolves bash -> bash.exe,
# so a plain file test would fire on every healthy Windows run.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT*) WANT_EXE_SUFFIX='.exe' ;;
  *)                                WANT_EXE_SUFFIX='' ;;
esac
if [ -f "$TMP_ROOT/bin/bash$WANT_EXE_SUFFIX" ]; then
    pass "hermetic bash stub is platform-named (bash$WANT_EXE_SUFFIX)"
else
    fail "hermetic bash stub is platform-named (bash$WANT_EXE_SUFFIX)" "missing: $TMP_ROOT/bin/bash$WANT_EXE_SUFFIX"
fi
if [ -n "$WANT_EXE_SUFFIX" ] && [ -n "$(find "$TMP_ROOT/bin" -maxdepth 1 -name bash -print -quit)" ]; then
    fail "no extensionless bash stub on Windows" "SE_ERR_NOASSOC hazard: $TMP_ROOT/bin/bash"
else
    pass "no extensionless bash stub on Windows"
fi

# Hermetic shared WSH preflight: no policy override, and the windowless host's
# zero-exit smoke script succeeds without consulting the live machine.
FAKE_WSCRIPT="$TMP_ROOT/wscript-fake.exe"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_WSCRIPT"
chmod +x "$FAKE_WSCRIPT"
FAKE_WSH_POWERSHELL="$TMP_ROOT/powershell-wsh-fake.sh"
printf '#!/bin/sh\necho ABSENT\n' > "$FAKE_WSH_POWERSHELL"
chmod +x "$FAKE_WSH_POWERSHELL"
export CADENCE_WSCRIPT_BIN="$FAKE_WSCRIPT"
export CADENCE_WSH_POWERSHELL="$FAKE_WSH_POWERSHELL"

# Fake `graphify` on PATH: arm now resolves
# it via `command -v graphify` and FAILS FAST when it is absent, because EVERY
# armed task (semantic via refresh-graph-map.sh, structural directly) shells it
# at fire time under the scheduler's minimal PATH. The semantic pair's
# claude-cli backend ALSO shells the local `claude` CLI internally, so a matching `claude`
# stub is set up right below. Stubs keep the suite deterministic on machines
# with and without the real CLIs installed; like the bash stub they are never
# fired, only resolved + their dirname read.
#
# It lives in its OWN dir, entered on PATH in POSIX form, for two reasons the
# `bin` dir above cannot serve: (1) TMP_ROOT is cygpath -m'd (C:/... mixed form)
# and Git-Bash cannot resolve a PATH entry in that form — a stub in `bin` is
# INVISIBLE on Windows, so the arm would silently resolve the operator's REAL
# installed graphify and the runner assertion below would pin a machine-specific
# path; (2) adding a POSIX entry for `bin` itself would newly expose the fake
# `bash` on Windows, changing what the existing suite bakes into its runners.
GRAPHIFY_BIN_DIR="$TMP_ROOT/graphify-bin"
mkdir -p "$GRAPHIFY_BIN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$GRAPHIFY_BIN_DIR/graphify"
chmod +x "$GRAPHIFY_BIN_DIR/graphify"
GRAPHIFY_BIN_DIR_PATH="$GRAPHIFY_BIN_DIR"
if command -v cygpath >/dev/null 2>&1; then
    GRAPHIFY_BIN_DIR_PATH=$(cygpath -u "$GRAPHIFY_BIN_DIR")
fi
# EVERY invocation that reaches `arm` must carry $GRAPHIFY_BIN_DIR_PATH on PATH
# — arm fail-fasts when `graphify` is absent. Omitting it does NOT
# fail on a dev box that happens to have the real CLI installed: the inherited
# $PATH tail satisfies the probe by ACCIDENT, so the suite goes green locally
# and dies on a clean CI runner with rc=2 (set -euo pipefail aborts the whole
# script on the unguarded `arm` assignment, before any assertion prints). That
# is exactly how this shipped to public CI once. The stub keeps the suite
# hermetic — a test's result must never depend on what the operator has
# installed.

# A PATH with the real system dirs (arm needs dirname/sed/mktemp at load time)
# but with EVERY dir that carries a real `graphify` filtered out — the fail-fast
# probe below must not be satisfied by an installed CLI. Filtering the real PATH
# beats replacing it: a bare stub dir strips coreutils and the script dies rc=127
# on `dirname` before it ever reaches the check under test.
PATH_NOGRAPHIFY=""
_oldifs=$IFS; IFS=:
for _d in $PATH; do
    [ -n "$_d" ] || continue
    if [ -x "$_d/graphify" ] || [ -x "$_d/graphify.exe" ] || [ -x "$_d/graphify.cmd" ]; then continue; fi
    PATH_NOGRAPHIFY="${PATH_NOGRAPHIFY:+$PATH_NOGRAPHIFY:}$_d"
done
IFS=$_oldifs

# Fake `claude` on PATH:
# validate_arm_inputs resolves it via `command -v claude`, semantic pair only
# (--ast-only skips it, same as the backend credential), and FAILS FAST when it
# is absent — graphify's claude-cli backend shells it internally at fire time.
# Same rationale/placement as GRAPHIFY_BIN_DIR above (own dir, POSIX form on
# PATH — TMP_ROOT's cygpath -m form is invisible to Git-Bash PATH lookup).
CLAUDE_BIN_DIR="$TMP_ROOT/claude-bin"
mkdir -p "$CLAUDE_BIN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$CLAUDE_BIN_DIR/claude"
chmod +x "$CLAUDE_BIN_DIR/claude"
CLAUDE_BIN_DIR_PATH="$CLAUDE_BIN_DIR"
if command -v cygpath >/dev/null 2>&1; then
    CLAUDE_BIN_DIR_PATH=$(cygpath -u "$CLAUDE_BIN_DIR")
fi

# A PATH with graphify resolvable (GRAPHIFY_BIN_DIR_PATH) but every dir
# carrying a real `claude` filtered out — same construction as
# PATH_NOGRAPHIFY, mirrored for the claude fail-fast probe below.
PATH_NOCLAUDE=""
_oldifs=$IFS; IFS=:
for _d in $PATH; do
    [ -n "$_d" ] || continue
    if [ -x "$_d/claude" ] || [ -x "$_d/claude.exe" ] || [ -x "$_d/claude.cmd" ]; then continue; fi
    PATH_NOCLAUDE="${PATH_NOCLAUDE:+$PATH_NOCLAUDE:}$_d"
done
IFS=$_oldifs
PATH_NOCLAUDE="$GRAPHIFY_BIN_DIR_PATH:$PATH_NOCLAUDE"

# Hermeticity: point HOME/USERPROFILE at the temp dir so a stray BAT_DIR default
# (should the seam ever be dropped) can't land under the real user profile.
export HOME="$TMP_ROOT/home"
export HIMMEL_OBSERVABILITY_CONFIG="$TMP_ROOT/observability.json"
mkdir -p "$HOME"
# Fired probe runners call cadence-alert + the flow ledger; keep
# both sinks inside the scratch HOME and never reach Telegram.
export CADENCE_ALERT_SEND_CMD=/bin/true
export HIMMEL_FLOW_RUNS_LEDGER="$HOME/flow-runs.jsonl"

VAULT="$TMP_ROOT/vault"
mkdir -p "$VAULT"

# The himmel root the runners cd into is this script's ../.. (same resolution
# graphmap-cadence.sh uses for HIMMEL_ROOT).
HIMMEL_ROOT_EXP="$(cd "$SCRIPT_DIR/../.." && pwd)"
# The promote-lock wrapper the AST pair now fires by absolute path,
# same resolution graphmap-cadence.sh uses for AST_UPDATE_SCRIPT.
AST_UPDATE_SCRIPT_EXP="$HIMMEL_ROOT_EXP/scripts/graphify/ast-update.sh"
# A claude-session runner (the sibling pipeline-cadence) would carry these
# markers; a deterministic refresh-graph-map runner must carry NONE of them.
# (Can't grep the bare word "claude" — the worktree path contains ".claude".)

# ============================================================================
# xml_escape unit — the one non-trivial string transform. Pure + platform-
# agnostic, so it runs on EVERY platform: extract the function and call it.
# ============================================================================
echo "TEST: xml_escape escapes & < > with & ordered first"
xesc=$( { sed -n '/^xml_escape()/,/^}/p' "$SCRIPT"; echo "xml_escape 'a & b < c > d'"; } | bash )
assert_contains "xml_escape produces well-formed entities (& first)" "a &amp; b &lt; c &gt; d" "$xesc"
assert_not_contains "xml_escape leaves no bare ampersand" "a & b" "$xesc"

# ============================================================================
# default_vault / resolve_user_home units — cross-platform default resolution.
# Pure (env + cygpath only), so they run on EVERY platform.
# ============================================================================
echo "TEST: default_vault resolves the cross-platform default vault"
DV_SRC="$(sed -n '/^resolve_user_home()/,/^}/p' "$SCRIPT"; sed -n '/^default_vault()/,/^}/p' "$SCRIPT")"
run_dv() { env "$@" bash -c "$DV_SRC"$'\n'"default_vault"; }

dv_a=$(run_dv LUNA_VAULT_PATH="/some/explicit/vault" USERPROFILE='C:\Users\x')
assert_contains "default_vault honors LUNA_VAULT_PATH" "/some/explicit/vault" "$dv_a"
assert_not_contains "LUNA_VAULT_PATH used verbatim (no Documents/luna append)" "Documents/luna" "$dv_a"

dv_b=$(run_dv -u LUNA_VAULT_PATH -u USERPROFILE HOME="/posix/home")
assert_contains "default_vault POSIX shape is \$HOME/Documents/luna" "/posix/home/Documents/luna" "$dv_b"

# ============================================================================
# POSIX (cron) suite. Runs on EVERY platform: the cron code path is forced via
# an OSTYPE override + the GRAPHMAP_CRONTAB seam.
# ============================================================================

CSTATE="$TMP_ROOT/cron-state"
mkdir -p "$CSTATE"

# Fake crontab: persists the installed tab at $CSTATE/crontab. Mimics real
# crontab signatures: -l with no tab prints "no crontab for <user>" + rc=1;
# `crontab -` installs from stdin. Failure seam: $CSTATE/fail-write.
# Shebang MUST be /bin/sh (absolute, POSIX body): `#!/usr/bin/env bash` would
# resolve the no-op fake `bash` stub via the prepended PATH on Linux, turning
# every crontab call into a silent no-op (rc=0, nothing read or written) — 35
# green-on-Windows assertions failed exactly this way on ubuntu CI.
FAKE_CRONTAB="$TMP_ROOT/crontab-fake.sh"
cat >"$FAKE_CRONTAB" <<FAKE
#!/bin/sh
CSTATE="$CSTATE"
FAKE
cat >>"$FAKE_CRONTAB" <<'FAKE'
case "${1:-}" in
    -l)
        if [ -e "$CSTATE/fail-list" ]; then
            echo "crontab: must be privileged to use -l" >&2
            exit 1
        fi
        if [ -f "$CSTATE/crontab" ]; then
            cat "$CSTATE/crontab"
        else
            echo "no crontab for fakeuser" >&2
            exit 1
        fi
        ;;
    -)
        if [ -e "$CSTATE/fail-write" ]; then
            echo "crontab: error writing new crontab" >&2
            exit 1
        fi
        cat > "$CSTATE/crontab"
        ;;
    *)
        echo "crontab-fake: unsupported argv: $*" >&2
        exit 64
        ;;
esac
FAKE
chmod +x "$FAKE_CRONTAB"

CRON_DIR="$TMP_ROOT/cron-runners"

run_cron() {
    env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
        GRAPHMAP_BAT_DIR="$CRON_DIR" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$CLAUDE_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" "$@"
}

# Test C1: status with no crontab installed ----------------------------------

echo "TEST: cron status with no crontab installed"
out=$(run_cron status)
assert_contains "cron luna not armed"   "not armed  HIMMEL-GraphMap-Luna"   "$out"
assert_contains "cron himmel not armed" "not armed  HIMMEL-GraphMap-Himmel" "$out"
assert_contains "cron ast-luna not armed"   "not armed  HIMMEL-GraphMapAst-Luna"   "$out"
assert_contains "cron ast-himmel not armed" "not armed  HIMMEL-GraphMapAst-Himmel" "$out"

# Test C1b: cron_status must not report an
# unrelated task's cron entry as an owned task being armed. cron_existing/
# list_existing were scoped to exact/end-anchored matches against the four
# owned names in a prior commit; cron_status's own `grep -F "# $name"` was
# missed and still substring-matched -- a `# HIMMEL-GraphMapAst-LunaExtra`
# entry would be reported as HIMMEL-GraphMapAst-Luna being armed.
echo "TEST: cron status ignores an unrelated LunaExtra-suffixed entry"
printf '5 5 * * * /usr/bin/true # HIMMEL-GraphMapAst-LunaExtra\n' > "$CSTATE/crontab"
out=$(run_cron status)
assert_contains "cron ast-luna correctly not armed despite the LunaExtra entry" "not armed  HIMMEL-GraphMapAst-Luna" "$out"
assert_not_contains "cron status never reports LunaExtra's entry as the real task being armed" "ARMED      HIMMEL-GraphMapAst-Luna" "$out"
rm -f "$CSTATE/crontab"

# Test C12: shared validation wired into the cron path -----------------------

echo "TEST: cron arm rejects invalid input (shared validation)"
rc=0; out=$(run_cron arm --vault "$VAULT" --luna-time 24:61 2>&1) || rc=$?
assert_rc "cron bad --luna-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --himmel-time 25:00 2>&1) || rc=$?
assert_rc "cron bad --himmel-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$TMP_ROOT/does-not-exist" 2>&1) || rc=$?
assert_rc "cron missing vault dir -> rc 1" 1 "$rc"

# Test C13: arm fails fast when `graphify` is absent --------------------------------------------------------------
#
# Every armed task shells graphify at fire time under the scheduler's minimal
# PATH (semantic pair via refresh-graph-map.sh, structural pair directly).
# Arming on a machine without it would "succeed" and then die on every
# unattended fire, in a log nobody reads. PATH is REPLACED (not prepended) so
# a really-installed graphify cannot satisfy the probe here.

echo "TEST: cron arm fails fast when graphify is not on PATH"
rc=0; out=$(env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$CRON_DIR" PATH="$PATH_NOGRAPHIFY" \
    "$REAL_BASH" "$SCRIPT" arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron arm without graphify -> rc 2" 2 "$rc"
assert_contains "missing-graphify error names the CLI" "'graphify' not on PATH at arm time" "$out"
if [ ! -f "$CSTATE/crontab" ] && [ ! -d "$CRON_DIR" ]; then
    pass "failed arm installed nothing"
else
    fail "failed arm left state behind" "$(ls -a "$CRON_DIR" 2>/dev/null; cat "$CSTATE/crontab" 2>/dev/null)"
fi

# Test C13b: arm fails fast when `claude` is not on PATH ---------------------------------------
#
# BACKEND is claude-cli again (kimi is retired — operator ruling, there is no
# kimi backend), which needs no credential (validate_backend_credential
# classifies claude|claude-cli as credential-free) but DOES shell the local
# `claude` CLI internally at fire time, via graphify. Mirrors the graphify
# fail-fast test directly above: PATH carries graphify but not claude.

echo "TEST: cron arm fails fast when claude is not on PATH"
rc=0; out=$(env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$CRON_DIR" PATH="$PATH_NOCLAUDE" \
    "$REAL_BASH" "$SCRIPT" arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron arm without claude -> rc 2" 2 "$rc"
assert_contains "missing-claude error names the CLI" "'claude' not on PATH at arm time" "$out"
if [ ! -f "$CSTATE/crontab" ] && [ ! -d "$CRON_DIR" ]; then
    pass "claude-missing arm installed nothing"
else
    fail "claude-missing arm left state behind" "$(ls -a "$CRON_DIR" 2>/dev/null; cat "$CSTATE/crontab" 2>/dev/null)"
fi

# Test C13c: a full (non --ast-only) arm needs no backend credential at all
# ---------------------------------------------------------------
#
# BACKEND is claude-cli, so validate_backend_credential's
# `claude|claude-cli) return 0` arm authenticates via the operator's own
# Claude Code subscription, so arm must succeed with no credential env/.env
# ANYWHERE (claude itself still needs to be on PATH — see C13b above).

echo "TEST: cron arm needs no backend credential (claude-cli authenticates via subscription)"
rc=0; out=$(unset MOONSHOT_API_KEY ZAI_API_KEY DEEPSEEK_API_KEY; GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT_EMPTY" \
    run_cron arm --vault "$VAULT" --dry-run 2>&1) || rc=$?
assert_rc "cron arm --dry-run succeeds with no backend credential anywhere" 0 "$rc"

# Test C2: arm --dry-run touches nothing --------------------------------------

echo "TEST: cron arm --dry-run prints plan, installs nothing"
out=$(run_cron arm --vault "$VAULT" --dry-run)
assert_contains "dry-run weekly luna entry"   "00 13 * * 0" "$out"
assert_contains "dry-run weekly himmel entry" "20 13 * * 0" "$out"
assert_contains "dry-run luna marker"   "# HIMMEL-GraphMap-Luna"   "$out"
assert_contains "dry-run himmel marker" "# HIMMEL-GraphMap-Himmel" "$out"
assert_contains "dry-run fires refresh-graph-map.sh" "refresh-graph-map.sh" "$out"
assert_contains "dry-run luna payload names the corpus" "--name luna" "$out"
assert_contains "dry-run himmel payload names the corpus" "--name himmel" "$out"
# Structural (AST) pair, asymmetric:
# himmel hourly (minute, every hour), luna DAILY at its full HH:MM.
assert_contains "dry-run daily ast-luna entry"    "05 00 * * *"  "$out"
assert_contains "dry-run hourly ast-himmel entry" "15 * * * *" "$out"
assert_contains "dry-run ast-luna marker"   "# HIMMEL-GraphMapAst-Luna"   "$out"
assert_contains "dry-run ast-himmel marker" "# HIMMEL-GraphMapAst-Himmel" "$out"
# The AST payload fires the promote-lock wrapper
# (ast-update.sh), not a bare graphify update -- --force lives inside it.
assert_contains "dry-run ast payload fires the promote-lock wrapper" "ast-update.sh" "$out"
if [ ! -f "$CSTATE/crontab" ]; then
    pass "dry-run installed no crontab"
else
    fail "dry-run installed a crontab" "$(cat "$CSTATE/crontab")"
fi
if [ ! -d "$CRON_DIR" ]; then
    pass "dry-run wrote no runner .sh"
else
    fail "dry-run wrote runners" "$(ls "$CRON_DIR")"
fi

# Test C3: arm installs marker-tagged entries, preserves unrelated lines ------

echo "TEST: cron arm installs entries with defaults, preserves unrelated lines"
printf '5 5 * * * /usr/bin/true # keep-me\n' > "$CSTATE/crontab"
out=$(run_cron arm --vault "$VAULT")
assert_contains "cron arm banner" "GRAPHMAP CADENCE ARMED" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "weekly luna entry (Sunday) 13:00"   "00 13 * * 0" "$tab"
assert_contains "weekly himmel entry (Sunday) 13:20" "20 13 * * 0" "$tab"
assert_contains "luna entry marker-tagged"   "# HIMMEL-GraphMap-Luna"   "$tab"
assert_contains "himmel entry marker-tagged" "# HIMMEL-GraphMap-Himmel" "$tab"
assert_contains "luna entry fires the runner"   "graphmap-luna.sh"   "$tab"
assert_contains "himmel entry fires the runner" "graphmap-himmel.sh" "$tab"
assert_contains "unrelated entry preserved" "keep-me" "$tab"
# Every armed entry is recorded as a `job register` row.
jobs=$( . "$SCRIPT_DIR/../lib/provenance.sh" && . "$SCRIPT_DIR/../lib/provenance-read.sh" && prov_read_load >/dev/null && prov_read_units --kind job | jq -r '"\(.unit) ours=\(.ours) scheduler=\(.fields.scheduler)"' | LC_ALL=C sort )
assert_contains "arm recorded all four graphmap jobs (ours, cron)" \
    "HIMMEL-GraphMap-Himmel ours=true scheduler=cron
HIMMEL-GraphMap-Luna ours=true scheduler=cron
HIMMEL-GraphMapAst-Himmel ours=true scheduler=cron
HIMMEL-GraphMapAst-Luna ours=true scheduler=cron" "$jobs"
assert_registry "cron arm registers both weekly graphmap flows" '[.flows[] | select((.name == "graphmap-luna" or .name == "graphmap-himmel") and .cadence_seconds == 604800)] | length == 2'
assert_registry "cron arm registers both expected task names" '[.expected_tasks[] | select(. == "HIMMEL-GraphMap-Luna" or . == "HIMMEL-GraphMap-Himmel")] | length == 2'
assert_registry "cron arm registers both ast graphmap flows" '[.flows[] | select(.name == "graphmap-ast-luna" or .name == "graphmap-ast-himmel")] | length == 2'
assert_registry "cron arm registers both ast expected task names" '[.expected_tasks[] | select(. == "HIMMEL-GraphMapAst-Luna" or . == "HIMMEL-GraphMapAst-Himmel")] | length == 2'
# The publish leg (HIMMEL-GraphPublish-Himmel) is opt-in via --with-publish
# and is NOT part of this default arm -- its registration
# (under its slug-DERIVED name) is covered in the
# dedicated publish-leg fixture below, both with and without the flag.
# Structural (AST) pair: marker-tagged, own runner files. luna is DAILY and
# himmel HOURLY. The luna assertion is made against THAT
# ENTRY'S OWN LINE, not the whole crontab: himmel's hourly `15 * * * *`
# contains the substring `5 * * * *`, so a whole-file assert_not_contains for
# the hourly form can never distinguish the two legs (it fails even when luna
# is correctly daily).
ast_luna_line=$(grep -F '# HIMMEL-GraphMapAst-Luna' "$CSTATE/crontab" 2>/dev/null || true)
assert_contains "daily ast-luna entry (hour field pinned)" "05 00 * * *" "$ast_luna_line"
assert_not_contains "ast-luna entry is not hourly"         "05 * * * *"  "$ast_luna_line"
assert_contains "hourly ast-himmel entry" "15 * * * *" "$tab"
assert_contains "ast-luna entry marker-tagged"   "# HIMMEL-GraphMapAst-Luna"   "$tab"
assert_contains "ast-himmel entry marker-tagged" "# HIMMEL-GraphMapAst-Himmel" "$tab"
assert_contains "ast-luna entry fires its runner"   "graphmap-ast-luna.sh"   "$tab"
assert_contains "ast-himmel entry fires its runner" "graphmap-ast-himmel.sh" "$tab"
if [ -x "$CRON_DIR/graphmap-luna.sh" ] && [ -x "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ -x "$CRON_DIR/graphmap-ast-luna.sh" ] && [ -x "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "all four runner .sh files written + executable"
else
    fail "runner .sh files missing or not executable" "$(ls -l "$CRON_DIR" 2>/dev/null || true)"
fi
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "exactly four cadence entries installed"
else
    fail "expected four cadence entries" "$(cat "$CSTATE/crontab")"
fi

# Test C4: runner .sh fires refresh-graph-map.sh with the right payload -------

echo "TEST: runner .sh fires bash refresh-graph-map.sh (deterministic, no claude)"
luna_sh=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
himmel_sh=$(cat "$CRON_DIR/graphmap-himmel.sh" 2>/dev/null || echo MISSING)
# The sh runner embeds paths/title via printf %q (backslash-escapes spaces);
# strip the escapes before multi-word asserts.
luna_sh_plain=${luna_sh//\\/}
himmel_sh_plain=${himmel_sh//\\/}
# The expected version is SOURCED, never retyped: a hardcoded
# literal here bounces this suite on every format bump for no coverage gain --
# the assertion that matters is "the runner stamps the CURRENT format".
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/../lib/cadence-format.sh"
FMT="$CADENCE_RUNNER_FORMAT_VERSION"
assert_contains "luna runner stamps the format version (HIMMEL-588)"   "# himmel-cadence-runner-format: $FMT" "$luna_sh"
assert_contains "himmel runner stamps the format version (HIMMEL-588)" "# himmel-cadence-runner-format: $FMT" "$himmel_sh"
assert_contains "luna runner fires refresh-graph-map.sh"   "refresh-graph-map.sh" "$luna_sh_plain"
assert_contains "luna runner names the luna corpus"        "--name luna"          "$luna_sh"
assert_contains "luna runner sets the luna slug"           "--slug graphify-luna-map" "$luna_sh"
assert_contains "luna runner sets the luna corpus-tag"     "--corpus-tag luna"    "$luna_sh"
assert_contains "luna runner uses the claude-cli backend"  "--backend claude-cli --corpus-tag" "$luna_sh"
assert_contains "luna runner sets the luna title"          "Graphify Luna Map"    "$luna_sh_plain"
assert_contains "luna runner publishes into 60-Maps"       "60-Maps"              "$luna_sh_plain"
# Strong corpus-root asserts: the luna map
# extracts the VAULT, the himmel map extracts the HIMMEL REPO — deliberately
# different roots. Match the --corpus-root TOKEN (not a bare $VAULT, which also
# appears in --maps-dir) so a payload arg-swap that makes the himmel map extract
# the vault (or vice-versa) fails here instead of shipping a wrong/empty graph.
assert_contains "luna runner corpus-root is the vault"     "--corpus-root $VAULT"           "$luna_sh_plain"
assert_contains "himmel runner names the himmel corpus"    "--name himmel"        "$himmel_sh"
assert_contains "himmel runner sets the himmel slug"       "--slug graphify-himmel-map" "$himmel_sh"
assert_contains "himmel runner sets the himmel corpus-tag" "--corpus-tag himmel"  "$himmel_sh"
assert_contains "himmel runner uses the claude-cli backend" "--backend claude-cli --corpus-tag" "$himmel_sh"
assert_contains "himmel runner corpus-root is the himmel repo" "--corpus-root $HIMMEL_ROOT_EXP" "$himmel_sh_plain"
assert_contains "himmel runner sets the himmel title"      "Graphify Himmel Map"  "$himmel_sh_plain"
assert_contains "luna runner cds into himmel root" "cd $HIMMEL_ROOT_EXP" "$luna_sh_plain"
# shellcheck disable=SC2016  # literal $log needles — the runner expands them at fire time
assert_contains "luna runner rotates the log" 'mv -f "$log" "$log.prev"' "$luna_sh"
assert_contains "luna runner stamps every fire" '[fired' "$luna_sh"
# shellcheck disable=SC2016
assert_contains "luna runner captures output to log" '>> "$log" 2>&1' "$luna_sh"
for what in luna himmel; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    assert_not_contains "$what runner has no --settings (not a claude session)" "--settings" "$body"
    assert_not_contains "$what runner has no bounded-claude stdin marker" "< /dev/null" "$body"
    # Cron's minimal PATH carries neither node nor graphify,
    # so the runner must pin graphify's dir the same way it already pins
    # node's — without it every fire dies "graphify: command not found". The
    # expected dir is where the stub graphify lives.
    # shellcheck disable=SC2016  # literal $PATH — the runner expands it at fire time
    assert_contains "$what runner prepends the graphify dir to PATH" \
        "export PATH=$GRAPHIFY_BIN_DIR_PATH:\$PATH" "${body//\\/}"
    # The claude-cli
    # backend shells the local `claude` CLI internally, so the semantic
    # runner must ALSO pin its dir onto PATH the same way.
    # shellcheck disable=SC2016  # literal $PATH — the runner expands it at fire time
    assert_contains "$what runner prepends the claude dir to PATH" \
        "export PATH=$CLAUDE_BIN_DIR_PATH:\$PATH" "${body//\\/}"
done

# Test C4b: structural (AST) runner .sh fires the promote-lock wrapper
# --
# free, no bank-preflight, no claude. --force now lives INSIDE ast-update.sh,
# not on this cadence command line (see scripts/graphify/test-ast-update.sh
# for the wrapper's own lock/skip/--force coverage).
# Every graphmap runner kind goes through the shared emitter.
# Fire each generated runner against a stub payload + stub cadence-alert.sh:
# a failed leg pages (`fail`), a good one `clear`s, and the leg's own benign
# skip code (semantic rc 3 = bank skip, structural rc 4 = promote-lock busy)
# does neither. The publish runner is NOT wired: graph-cadence.sh alerts itself.
echo "TEST: graphmap runners alert on failure and clear on success (shared emitter)"
. "$SCRIPT_DIR/../lib/cadence-runner-exec.sh"
for kind in "luna:graphmap-luna:refresh-graph-map.sh:3" "himmel:graphmap-himmel:refresh-graph-map.sh:3" \
            "ast-luna:graphmap-ast-luna:ast-update.sh:4" "ast-himmel:graphmap-ast-himmel:ast-update.sh:4"; do
    k_file=${kind%%:*}; rest=${kind#*:}
    k_flow=${rest%%:*}; rest=${rest#*:}
    k_script=${rest%%:*}; k_skip=${rest#*:}
    for want_rc in 1 0 "$k_skip"; do
        scr="$TMP_ROOT/emit-$k_file-$want_rc"
        mkdir -p "$scr"
        sed "s@$TMP_ROOT/bin/bash@$REAL_BASH@" "$CRON_DIR/graphmap-$k_file.sh" > "$scr/runner-src.sh"
        cadence_exec_runner "$scr/runner-src.sh" "$HIMMEL_ROOT_EXP/scripts/graphify/$k_script" "$want_rc" "$scr" || true
        alerts=$(cat "$scr/alerts" 2>/dev/null || true)
        case "$want_rc" in
            1)  assert_contains "$k_file rc 1 alerts fail for $k_flow" "fail $k_flow rc-1" "$alerts" ;;
            0)  assert_contains "$k_file rc 0 clears $k_flow" "clear $k_flow" "$alerts"
                assert_not_contains "$k_file rc 0 never alerts fail" "fail " "$alerts"
                assert_contains "$k_file rc 0 writes a $k_flow flow-run row" "$k_flow" "$(cat "$scr/flow-runs.jsonl" 2>/dev/null || true)" ;;
            *)  assert_not_contains "$k_file benign skip rc $want_rc does not page" "fail " "$alerts" ;;
        esac
    done
done
echo "TEST: AST runner .sh fires ast-update.sh by absolute path (free, no bank, no claude)"
ast_luna_sh=$(cat "$CRON_DIR/graphmap-ast-luna.sh" 2>/dev/null || echo MISSING)
ast_himmel_sh=$(cat "$CRON_DIR/graphmap-ast-himmel.sh" 2>/dev/null || echo MISSING)
ast_luna_sh_plain=${ast_luna_sh//\\/}
ast_himmel_sh_plain=${ast_himmel_sh//\\/}
assert_contains "ast-luna runner stamps the format version"   "# himmel-cadence-runner-format: $FMT" "$ast_luna_sh"
assert_contains "ast-himmel runner stamps the format version" "# himmel-cadence-runner-format: $FMT" "$ast_himmel_sh"
assert_contains "ast-luna runner fires ast-update.sh by absolute path"   "$AST_UPDATE_SCRIPT_EXP" "$ast_luna_sh_plain"
assert_contains "ast-himmel runner fires ast-update.sh by absolute path" "$AST_UPDATE_SCRIPT_EXP" "$ast_himmel_sh_plain"
assert_not_contains "ast-luna runner has no bare --force on the cadence line (it's inside the wrapper)"   "--force" "$ast_luna_sh_plain"
assert_not_contains "ast-himmel runner has no bare --force on the cadence line (it's inside the wrapper)" "--force" "$ast_himmel_sh_plain"
# Absolute corpus paths: luna = vault, himmel = repo (same asymmetry as the
# semantic pair) -- both $VAULT/$HIMMEL_ROOT_EXP are already absolute here.
assert_contains "ast-luna runner corpus is the absolute vault path"     "$AST_UPDATE_SCRIPT_EXP $VAULT" "$ast_luna_sh_plain"
assert_contains "ast-himmel runner corpus is the absolute himmel path"  "$AST_UPDATE_SCRIPT_EXP $HIMMEL_ROOT_EXP" "$ast_himmel_sh_plain"
# Luna leg declares the fence's required backend (ollama -> local-ollama,
# luna-personal x local-ollama = allow); himmel leg does not need it
# (himmel-code default = ollama already, no declaration required).
assert_contains "ast-luna runner declares GRAPHIFY_DECLARED_BACKEND=ollama" "export GRAPHIFY_DECLARED_BACKEND=ollama" "$ast_luna_sh"
assert_not_contains "ast-himmel runner does not declare a backend" "GRAPHIFY_DECLARED_BACKEND" "$ast_himmel_sh"
for what in ast_luna ast_himmel; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    # The property that keeps the hourly leg free -- assert the ABSENCE
    # explicitly (brief item 6). HIMMEL_ROOT_EXP is stripped before the
    # "claude" check because the fixture's own worktree path legitimately
    # contains the substring (.claude/worktrees/...) via the `cd` target --
    # that is test-environment noise, not a claude invocation.
    # Both substring checks strip HIMMEL_ROOT_EXP first, for the same reason:
    # the fixture's own checkout path is embedded in every runner, and a
    # worktree named after the thing being asserted absent (a
    # `fix/...-bank-preflight` branch, or any path under `.claude/`) would
    # fail an assertion the runner itself never violates.
    assert_not_contains "$what runner has no bank-preflight" "bank-preflight" "${body//$HIMMEL_ROOT_EXP/}"
    # The alert call also pins the arm-time PATH: data, and it may
    # legitimately carry a .claude dir, so strip it before the "claude" check.
    body_nopath=$(printf '%s' "$body" | sed -E 's/PATH=[^ ]+ //g')
    assert_not_contains "$what runner never shells claude"   "claude" "${body_nopath//$HIMMEL_ROOT_EXP/}"
    assert_not_contains "$what runner has no --backend flag (LLM-free update)" "--backend" "$body"
    assert_not_contains "$what runner has no --settings (not a claude session)" "--settings" "$body"
done

# Test C5: status after arm ----------------------------------------------------

echo "TEST: cron status reflects armed entries"
out=$(run_cron status)
assert_contains "cron luna armed"   "ARMED      HIMMEL-GraphMap-Luna"   "$out"
assert_contains "cron himmel armed" "ARMED      HIMMEL-GraphMap-Himmel" "$out"
assert_contains "cron ast-luna armed"   "ARMED      HIMMEL-GraphMapAst-Luna"   "$out"
assert_contains "cron ast-himmel armed" "ARMED      HIMMEL-GraphMapAst-Himmel" "$out"
assert_contains "cron status surfaces run log state" "run log" "$out"

# Test C5b: status summarises a run log --------------------
#
# The 2026-08-17 fire is the fixture: luna died on the reboot 6h44m in, on
# chunk 149/314, with no `tokens:` line ever emitted and the log dominated by
# hollow-response bisect retries. Lines are written CRLF because the real logs
# come from a Windows .bat, and a stray CR would corrupt the parsed fields.

echo "TEST: cron status summarises run logs"
{
    printf '[graphify extract] chunk 148/314 done\r\n'
    for _i in $(seq 1 20); do
        printf '[graphify] claude-cli returned a hollow response; treating as truncation so adaptive retry can bisect the chunk.\r\n'
    done
    printf '[graphify extract] chunk 149/314 done\r\n'
} > "$CRON_DIR/graphmap-luna.log"
# shellcheck disable=SC2016  # the $ is graphify's literal cost prefix, not a variable
printf '[graphify extract] chunk 12/12 done\r\n[graphify extract] tokens: 144,540 in / 10,669 out, est. cost (~claude): $0.1234\r\n' \
    > "$CRON_DIR/graphmap-himmel.log"
printf 'refresh-graph-map: nothing to do\r\n' > "$CRON_DIR/graphmap-ast-luna.log"

out=$(run_cron status)
assert_contains "storm log reports no token summary" \
    "run summary: NO tokens summary (run did not finish)" "$out"
assert_contains "storm log reports last chunk reached" "last chunk 149/314" "$out"
assert_contains "storm log counts hollow responses"     "20 hollow responses" "$out"
assert_contains "storm log flags the storm"           "HOLLOW-BISECT STORM (HIMMEL-1901)" "$out"
assert_contains "healthy log reports token totals" \
    "run summary: 144,540 in / 10,669 out, est. cost (~claude): \$0.1234 | last chunk 12/12 | 0 hollow responses" "$out"
# One line per marker-bearing log, and no storm marker on the healthy one:
# exactly two summaries across the four logs (luna + himmel), never three.
summary_lines=$(grep -c -F 'run summary:' <<< "$out" || true)
if [ "$summary_lines" = "2" ]; then
    pass "unmarked log gets no run summary"
else
    fail "unmarked log gets no run summary" "expected 2 'run summary:' lines, got $summary_lines"
fi
storm_lines=$(grep -c -F 'HOLLOW-BISECT STORM' <<< "$out" || true)
if [ "$storm_lines" = "1" ]; then
    pass "storm marker only on the storm log"
else
    fail "storm marker only on the storm log" "expected 1 storm line, got $storm_lines"
fi
rm -f "$CRON_DIR/graphmap-luna.log" "$CRON_DIR/graphmap-himmel.log" "$CRON_DIR/graphmap-ast-luna.log"

# Test C5c: status
# must report the INSTALLED runner's own --backend, not this script's current
# BACKEND constant -- a runner armed under an older BACKEND still carries
# its --backend baked in until re-armed, so reading BACKEND here would
# assert a migration that has not happened on that station. Isolated
# fixture/state (own fake crontab + a fresh GRAPHMAP_BAT_DIR per case) so
# this never disturbs the sequential arm/disarm chain around it.
FAKE_CRONTAB_BACKEND="$TMP_ROOT/crontab-fake-backend.sh"
cat > "$FAKE_CRONTAB_BACKEND" <<'FAKE'
#!/bin/sh
case "${1:-}" in
    -l) echo "no crontab for fakeuser" >&2; exit 1 ;;
    *)  exit 64 ;;
esac
FAKE
chmod +x "$FAKE_CRONTAB_BACKEND"
run_cron_backend() {
    env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB_BACKEND" \
        GRAPHMAP_BAT_DIR="$1" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$CLAUDE_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" status
}

echo "TEST: status reads the installed runner's own --backend, not BACKEND"
KIMI_BAT_DIR="$TMP_ROOT/backend-kimi"
mkdir -p "$KIMI_BAT_DIR"
cat > "$KIMI_BAT_DIR/graphmap-luna.sh" <<'EOF'
#!/bin/sh
# HIMMEL-GraphMap-Luna runner — generated by graphmap-cadence.sh arm (HIMMEL-829)
# HIMMEL-CADENCE-RUNNER-FORMAT 3
log=/tmp/fake-h3048.log
{
    cd /fake/himmel || exit 1
    _rc=0; /bin/bash /fake/refresh-graph-map.sh --name luna --corpus-root /fake --maps-dir /fake --title X --slug luna --backend kimi --corpus-tag luna || _rc=$?
} >> "$log" 2>&1
EOF
out=$(run_cron_backend "$KIMI_BAT_DIR")
luna_line=$(grep 'HIMMEL-GraphMap-Luna' <<< "$out")
assert_contains "installed runner's kimi backend is reported, not the claude-cli constant" "installed: kimi" "$luna_line"
assert_not_contains "installed kimi backend does not get relabeled as claude-cli" "claude-cli" "$luna_line"

echo "TEST: status falls back to 'configured: <BACKEND>' when no runner is installed"
EMPTY_BAT_DIR="$TMP_ROOT/backend-none"
mkdir -p "$EMPTY_BAT_DIR"
out=$(run_cron_backend "$EMPTY_BAT_DIR")
luna_line=$(grep 'HIMMEL-GraphMap-Luna' <<< "$out")
assert_contains "no runner installed falls back to the configured BACKEND constant" "configured: claude-cli" "$luna_line"

echo "TEST: status names a runner that carries no --backend flag explicitly, not as the fallback"
NOFLAG_BAT_DIR="$TMP_ROOT/backend-noflag"
mkdir -p "$NOFLAG_BAT_DIR"
cat > "$NOFLAG_BAT_DIR/graphmap-luna.sh" <<'EOF'
#!/bin/sh
log=/tmp/fake-h3048-noflag.log
{
    cd /fake/himmel || exit 1
    _rc=0; /bin/bash /fake/refresh-graph-map.sh --name luna || _rc=$?
} >> "$log" 2>&1
EOF
out=$(run_cron_backend "$NOFLAG_BAT_DIR")
luna_line=$(grep 'HIMMEL-GraphMap-Luna' <<< "$out")
assert_contains "runner with no --backend flag gets its own explicit label" "installed: no --backend flag in runner" "$luna_line"
assert_not_contains "runner with no --backend flag is never silently read as the configured fallback" "configured:" "$luna_line"

# Test C6: re-arm without --force -> dedup block -------------------------------

echo "TEST: cron re-arm without --force blocked (rc 3)"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron dedup block rc 3" 3 "$rc"
assert_contains "cron dedup message names existing entries" "HIMMEL-GraphMap-Himmel" "$out"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "no duplicate entries after blocked re-arm"
else
    fail "entry count changed on blocked re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C7: re-arm --force with overrides ----------------------------------------

echo "TEST: cron re-arm --force applies flag overrides"
out=$(run_cron arm --vault "$VAULT" --force --luna-time 01:15 --himmel-time 02:30 2>&1)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "cron weekly luna override"   "15 01 * * 0" "$tab"
assert_contains "cron weekly himmel override" "30 02 * * 0" "$tab"
assert_contains "unrelated entry survives --force re-arm" "keep-me" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "still exactly four entries after --force re-arm"
else
    fail "duplicate entries after --force re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C14: dry-run disarm with armed entries prints DRY tail, touches nothing --

echo "TEST: cron dry-run disarm prints DRY tail, touches nothing"
out=$(run_cron disarm --dry-run)
assert_contains "cron dry disarm lists removals" "would remove crontab entry" "$out"
assert_contains "cron dry disarm closing summary" "no changes made" "$out"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "dry-run disarm removed no entries"
else
    fail "dry-run disarm changed crontab state" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/graphmap-luna.sh" ] && [ -f "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ -f "$CRON_DIR/graphmap-ast-luna.sh" ] && [ -f "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "dry-run disarm kept all four runner .sh files"
else
    fail "dry-run disarm deleted runner .sh files"
fi
assert_registry "dry-run disarm keeps graphmap registered" '[.flows[] | select(.name == "graphmap-luna" or .name == "graphmap-himmel")] | length == 2'

# Test C8: disarm + idempotent second disarm ------------------------------------

echo "TEST: cron disarm removes entries + runners, keeps unrelated lines"
out=$(run_cron disarm)
assert_contains "cron disarm reports" "cadence disarmed" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_not_contains "cadence entries removed" "HIMMEL-GraphMap" "$tab"
assert_contains "unrelated entry survives disarm" "keep-me" "$tab"
if [ ! -f "$CRON_DIR/graphmap-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ ! -f "$CRON_DIR/graphmap-ast-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "all four runner .sh files removed"
else
    fail "runner .sh files left after disarm"
fi
assert_registry "deliberate disarm unregisters both graphmap flows" 'all(.flows[]; .name != "graphmap-luna" and .name != "graphmap-himmel")'
assert_registry "deliberate disarm removes both expected tasks" 'all(.expected_tasks[]; . != "HIMMEL-GraphMap-Luna" and . != "HIMMEL-GraphMap-Himmel")'
rc=0; out=$(run_cron disarm) || rc=$?
assert_rc "cron second disarm rc 0" 0 "$rc"
assert_contains "cron second disarm is a no-op" "no-op" "$out"

# Test C8b: --ast-only -----------------------------------------
#
# arm --ast-only registers ONLY the two free structural tasks, needs no
# semantic-backend credential, and — critically — an --ast-only --force
# re-arm must leave a PRE-EXISTING semantic pair's crontab entries and runner
# files byte-identical, never rewriting or deleting them.
#
# Literal task names (this test SCRIPT's own scope has no $TASK_* vars — those
# live only inside graphmap-cadence.sh, sourced via a separate interpreter by
# run_cron; referencing them here would be an unbound-variable error under
# this file's own `set -euo pipefail`).
T_LUNA="HIMMEL-GraphMap-Luna"
T_HIMMEL="HIMMEL-GraphMap-Himmel"
T_AST_LUNA="HIMMEL-GraphMapAst-Luna"
T_AST_HIMMEL="HIMMEL-GraphMapAst-Himmel"

echo "TEST: cron arm --ast-only --dry-run skips the semantic pair entirely"
out=$(run_cron arm --vault "$VAULT" --ast-only --dry-run)
assert_contains "ast-only dry-run says semantic pair skipped" "semantic pair" "$out"
assert_not_contains "ast-only dry-run has no weekly luna entry"   "00 13 * * 0" "$out"
assert_not_contains "ast-only dry-run has no weekly himmel entry" "20 13 * * 0" "$out"
assert_not_contains "ast-only dry-run never fires refresh-graph-map.sh" "refresh-graph-map.sh" "$out"
assert_contains "ast-only dry-run still has the daily ast-luna entry" "05 00 * * *" "$out"
assert_contains "ast-only dry-run still has the hourly ast-himmel entry" "15 * * * *" "$out"

echo "TEST: cron arm --ast-only needs no semantic-backend credential or claude on PATH"
rc=0; out=$(unset MOONSHOT_API_KEY ZAI_API_KEY DEEPSEEK_API_KEY; GRAPHMAP_DOTENV_ROOT="$DOTENV_ROOT_EMPTY" \
    env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" GRAPHMAP_BAT_DIR="$CRON_DIR" \
    PATH="$PATH_NOCLAUDE" "$REAL_BASH" "$SCRIPT" arm --vault "$VAULT" --ast-only 2>&1) || rc=$?
assert_rc "ast-only arm succeeds with no credential and no claude on PATH" 0 "$rc"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab" 2>/dev/null)" -eq 2 ]; then
    pass "ast-only arm installed exactly two cadence entries"
else
    fail "ast-only arm installed the wrong entry count" "$tab"
fi
assert_contains "ast-only arm's ast-luna entry present"   "# $T_AST_LUNA"   "$tab"
assert_contains "ast-only arm's ast-himmel entry present" "# $T_AST_HIMMEL" "$tab"
assert_contains "ast-only arm from a clean slate correctly banners the semantic pair as NOT armed" "NOT armed (--ast-only)" "$out"
assert_not_contains "ast-only arm installed no semantic luna entry"   "# $T_LUNA"   "$tab"
assert_not_contains "ast-only arm installed no semantic himmel entry" "# $T_HIMMEL" "$tab"
if [ -x "$CRON_DIR/graphmap-ast-luna.sh" ] && [ -x "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "ast-only arm wrote both AST runner .sh files"
else
    fail "ast-only arm did not write both AST runners" "$(ls "$CRON_DIR" 2>/dev/null || true)"
fi
if [ ! -e "$CRON_DIR/graphmap-luna.sh" ] && [ ! -e "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "ast-only arm wrote NO semantic runner .sh files"
else
    fail "ast-only arm wrote a semantic runner it should not have" "$(ls "$CRON_DIR")"
fi

echo "TEST: cron re-arm without --ast-only dedup-blocks on the already-armed AST tasks"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "full re-arm over an ast-only arm dedup-blocks" 3 "$rc"
assert_contains "dedup message names the already-armed AST task" "$T_AST_LUNA" "$out"

echo "TEST: --ast-only --force re-arm ADDS the AST pair without touching a pre-existing semantic pair"
out=$(run_cron arm --vault "$VAULT" --force 2>&1)   # full re-arm: now all four are armed
luna_sh_before=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
himmel_sh_before=$(cat "$CRON_DIR/graphmap-himmel.sh" 2>/dev/null || echo MISSING)
tab_before_luna=$(grep -F "# $T_LUNA" "$CSTATE/crontab" 2>/dev/null || echo MISSING)
tab_before_himmel=$(grep -F "# $T_HIMMEL" "$CSTATE/crontab" 2>/dev/null || echo MISSING)
out=$(run_cron arm --vault "$VAULT" --ast-only --force 2>&1)
assert_contains "ast-only --force re-arm banner" "GRAPHMAP CADENCE ARMED" "$out"
# The banner must report the pre-existing
# semantic pair's REAL state, not a blanket "NOT armed" false negative.
assert_contains "ast-only --force re-arm banner shows the pre-existing luna task as armed"   "$T_LUNA       already armed" "$out"
assert_contains "ast-only --force re-arm banner shows the pre-existing himmel task as armed" "$T_HIMMEL     already armed" "$out"
assert_not_contains "ast-only --force re-arm banner does not claim the pre-existing semantic pair is unarmed" "NOT armed (--ast-only)" "$out"
luna_sh_after=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
himmel_sh_after=$(cat "$CRON_DIR/graphmap-himmel.sh" 2>/dev/null || echo MISSING)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
tab_after_luna=$(grep -F "# $T_LUNA" "$CSTATE/crontab" 2>/dev/null || echo MISSING)
tab_after_himmel=$(grep -F "# $T_HIMMEL" "$CSTATE/crontab" 2>/dev/null || echo MISSING)
if [ "$luna_sh_before" = "$luna_sh_after" ]; then
    pass "ast-only --force re-arm left the pre-existing luna runner byte-identical"
else
    fail "ast-only --force re-arm rewrote the pre-existing luna runner" "before=<$luna_sh_before> after=<$luna_sh_after>"
fi
if [ "$himmel_sh_before" = "$himmel_sh_after" ]; then
    pass "ast-only --force re-arm left the pre-existing himmel runner byte-identical"
else
    fail "ast-only --force re-arm rewrote the pre-existing himmel runner"
fi
if [ "$tab_before_luna" = "$tab_after_luna" ] && [ "$tab_before_himmel" = "$tab_after_himmel" ]; then
    pass "ast-only --force re-arm left the pre-existing semantic crontab entries byte-identical"
else
    fail "ast-only --force re-arm changed the pre-existing semantic crontab entries" "before: $tab_before_luna / $tab_before_himmel; after: $tab_after_luna / $tab_after_himmel"
fi
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "ast-only --force re-arm still leaves exactly four entries total"
else
    fail "unexpected entry count after ast-only --force re-arm over a full arm" "$tab"
fi
run_cron disarm >/dev/null

# Test C9: failing crontab -l is fail-CLOSED -------------------------------------

echo "TEST: cron arm/status/disarm with failing crontab -l exit 2"
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron fail-closed arm rc 2" 2 "$rc"
assert_contains "cron arm failure surfaces stderr" "must be privileged" "$out"
rc=0; out=$(run_cron status 2>&1) || rc=$?
assert_rc "cron fail-closed status rc 2" 2 "$rc"
rm -f "$CSTATE/fail-list"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron fail-closed disarm rc 2" 2 "$rc"
assert_not_contains "no false no-op on failing crontab -l" "no-op" "$out"
if [ -f "$CRON_DIR/graphmap-luna.sh" ] && [ -f "$CRON_DIR/graphmap-himmel.sh" ]; then
    pass "runner .sh files NOT deleted on crontab -l failure"
else
    fail "runner .sh files deleted despite crontab -l failure"
fi
rm -f "$CSTATE/fail-list"
run_cron disarm >/dev/null

# Test C10: crontab install failure -> rc 4 ---------------------------------------

echo "TEST: cron arm with failing crontab install exits 4"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron install failure rc 4" 4 "$rc"
assert_contains "cron install failure surfaces stderr" "error writing new crontab" "$out"
if ! grep -q 'HIMMEL-GraphMap' "$CSTATE/crontab" 2>/dev/null; then
    pass "no cadence entries installed on write failure"
else
    fail "cadence entries installed despite write failure" "$(cat "$CSTATE/crontab")"
fi
if [ ! -f "$CRON_DIR/graphmap-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ ! -f "$CRON_DIR/graphmap-ast-luna.sh" ] && [ ! -f "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "no runner promoted to its final path on write failure"
else
    fail "runner files left despite write failure" "$(ls "$CRON_DIR" 2>/dev/null || true)"
fi
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter on write failure"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C10b: --force re-arm with failing install leaves NO half-state ------------

echo "TEST: cron --force re-arm with failing install keeps old runners + entries"
out=$(run_cron arm --vault "$VAULT")
VAULT2="$TMP_ROOT/vault2"
mkdir -p "$VAULT2"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --vault "$VAULT2" --force 2>&1) || rc=$?
assert_rc "cron force re-arm install failure rc 4" 4 "$rc"
luna_sh=$(cat "$CRON_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
assert_contains "old runner still points at the old vault" "$VAULT" "${luna_sh//\\/}"
assert_not_contains "no new-config runner promoted" "vault2" "$luna_sh"
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter after failed --force re-arm"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "old entries still armed after failed --force re-arm"
else
    fail "entry count changed on failed --force re-arm" "$(cat "$CSTATE/crontab")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C10c: disarm with failing install keeps entries + runners -----------------

echo "TEST: cron disarm with failing crontab install exits 4, keeps entries + runners"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron disarm install failure rc 4" 4 "$rc"
assert_contains "disarm install failure surfaces stderr" "error writing new crontab" "$out"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE/crontab")" -eq 4 ]; then
    pass "entries still in crontab after failed disarm install"
else
    fail "entries lost despite failed disarm install" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/graphmap-luna.sh" ] && [ -f "$CRON_DIR/graphmap-himmel.sh" ] \
   && [ -f "$CRON_DIR/graphmap-ast-luna.sh" ] && [ -f "$CRON_DIR/graphmap-ast-himmel.sh" ]; then
    pass "runner .sh files NOT deleted on failed disarm install"
else
    fail "runner .sh files deleted despite failed disarm install"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C11: hostile-but-legal vault dirname + runner dir can't inject -------------

echo "TEST: cron entries + runner escape hostile vault/runner paths"
EVIL_VAULT="$TMP_ROOT/va&ult \$X y"
EVIL_DIR="$TMP_ROOT/cr%on rnr"
mkdir -p "$EVIL_VAULT"
out=$(env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$EVIL_DIR" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$CLAUDE_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" arm --vault "$EVIL_VAULT")
luna_sh=$(cat "$EVIL_DIR/graphmap-luna.sh" 2>/dev/null || echo MISSING)
assert_contains "ampersand %q-escaped in runner" 'va\&ult' "$luna_sh"
# shellcheck disable=SC2016  # literal \$X needle — asserting the %q escape itself
assert_contains "dollar %q-escaped in runner" '\$X' "$luna_sh"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "percent cron-escaped in entry (\\%)" 'cr\%on' "$tab"
assert_contains "space %q-escaped in entry" 'cr\%on\ rnr' "$tab"
env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB" \
    GRAPHMAP_BAT_DIR="$EVIL_DIR" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$PATH" \
    "$REAL_BASH" "$SCRIPT" disarm >/dev/null

# Test C13: unknown platform exits 2 ----------------------------------------------

echo "TEST: unknown platform (OSTYPE=beos) exits 2"
rc=0; out=$(env OSTYPE=beos bash "$SCRIPT" status 2>&1) || rc=$?
assert_rc "unknown platform rc 2" 2 "$rc"
assert_contains "unknown platform message" "unsupported platform" "$out"

# Test C15: exact-name scoping — a crontab entry whose
# comment merely STARTS WITH the dash-less "HIMMEL-GraphMap" prefix (not one
# of the four owned names) must be treated as neither ours-for-removal nor
# ours-for-dedup. Isolated fixture/state (CSTATE2/FAKE_CRONTAB2) so this never
# disturbs the sequential arm/disarm chain above.
echo "TEST: cron scoping — unrelated HIMMEL-GraphMap*-prefixed entry survives removal, never blocks arm"
CSTATE2="$TMP_ROOT/cron-state2"
mkdir -p "$CSTATE2"
FAKE_CRONTAB2="$TMP_ROOT/crontab-fake2.sh"
cat >"$FAKE_CRONTAB2" <<FAKE
#!/bin/sh
CSTATE="$CSTATE2"
FAKE
cat >>"$FAKE_CRONTAB2" <<'FAKE'
case "${1:-}" in
    -l)
        if [ -e "$CSTATE/fail-list" ]; then
            echo "crontab: must be privileged to use -l" >&2
            exit 1
        fi
        if [ -f "$CSTATE/crontab" ]; then
            cat "$CSTATE/crontab"
        else
            echo "no crontab for fakeuser" >&2
            exit 1
        fi
        ;;
    -)
        if [ -e "$CSTATE/fail-write" ]; then
            echo "crontab: error writing new crontab" >&2
            exit 1
        fi
        cat > "$CSTATE/crontab"
        ;;
    *)
        echo "crontab-fake: unsupported argv: $*" >&2
        exit 64
        ;;
esac
FAKE
chmod +x "$FAKE_CRONTAB2"
CRON_DIR2="$TMP_ROOT/cron-runners2"
run_cron2() {
    env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB2" \
        GRAPHMAP_BAT_DIR="$CRON_DIR2" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$CLAUDE_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" "$@"
}
# "HIMMEL-GraphMapExtra" starts with the old dash-less prefix match
# ("HIMMEL-GraphMap") but is none of the four owned names — an operator's own
# unrelated entry, by construction.
printf '0 0 * * * /usr/bin/true # HIMMEL-GraphMapExtra\n' > "$CSTATE2/crontab"
rc=0; out=$(run_cron2 arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "arm succeeds with only an unrelated prefixed entry present (no false dedup-block)" 0 "$rc"
tab=$(cat "$CSTATE2/crontab" 2>/dev/null || echo MISSING)
assert_contains "unrelated prefixed entry survives arm's own-entry rewrite" "HIMMEL-GraphMapExtra" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE2/crontab")" -eq 5 ]; then
    pass "unrelated entry plus all four real cadence entries present (5 total)"
else
    fail "unexpected entry count after arm" "$(cat "$CSTATE2/crontab")"
fi
rc=0; out=$(run_cron2 arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "re-arm without --force now dedup-blocks on the REAL entries" 3 "$rc"
assert_contains "dedup message names a real owned entry" "HIMMEL-GraphMap-Luna" "$out"
assert_not_contains "dedup message does not name the unrelated entry" "HIMMEL-GraphMapExtra" "$out"
out=$(run_cron2 arm --vault "$VAULT" --force 2>&1)
tab=$(cat "$CSTATE2/crontab" 2>/dev/null || echo MISSING)
assert_contains "unrelated entry still survives a --force re-arm" "HIMMEL-GraphMapExtra" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE2/crontab")" -eq 5 ]; then
    pass "still exactly five entries (4 real + 1 unrelated) after --force re-arm"
else
    fail "unexpected entry count after --force re-arm" "$(cat "$CSTATE2/crontab")"
fi
out=$(run_cron2 disarm)
tab=$(cat "$CSTATE2/crontab" 2>/dev/null || echo MISSING)
assert_contains "unrelated prefixed entry survives disarm" "HIMMEL-GraphMapExtra" "$tab"
if [ "$(grep -c 'HIMMEL-GraphMap' "$CSTATE2/crontab")" -eq 1 ]; then
    pass "disarm removed exactly the four owned entries, left the unrelated one"
else
    fail "disarm removed or left the wrong entries" "$(cat "$CSTATE2/crontab")"
fi

# ============================================================================
# Publish leg: HIMMEL-GraphPublish-Himmel, POSIX/cron path.
# A dedicated fixture (mirrors the run_cron2 "unrelated prefix" fixture
# above) rather than reusing $CSTATE/$CRON_DIR, whose state is cumulative
# across every test above this point -- this block's assertions must not
# depend on exactly what earlier tests left behind.
# ============================================================================

CSTATE3="$TMP_ROOT/cron-state-publish"
mkdir -p "$CSTATE3"
FAKE_CRONTAB3="$TMP_ROOT/crontab-fake-publish.sh"
cat >"$FAKE_CRONTAB3" <<FAKE
#!/bin/sh
CSTATE="$CSTATE3"
FAKE
cat >>"$FAKE_CRONTAB3" <<'FAKE'
case "${1:-}" in
    -l)
        if [ -f "$CSTATE/crontab" ]; then
            cat "$CSTATE/crontab"
        else
            echo "no crontab for fakeuser" >&2
            exit 1
        fi
        ;;
    -) cat > "$CSTATE/crontab" ;;
    *) echo "crontab-fake: unsupported argv: $*" >&2; exit 64 ;;
esac
FAKE
chmod +x "$FAKE_CRONTAB3"
CRON_DIR3="$TMP_ROOT/cron-runners-publish"
run_cron3() {
    env OSTYPE=linux-gnu GRAPHMAP_CRONTAB="$FAKE_CRONTAB3" \
        GRAPHMAP_BAT_DIR="$CRON_DIR3" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" "$@"
}

echo "TEST: cron arm --ast-only omits the publish leg by default (HIMMEL-3075)"
out=$(run_cron3 arm --vault "$VAULT" --ast-only 2>&1)
assert_not_contains "arm banner without --with-publish does not name the publish task" "HIMMEL-GraphPublish-Himmel" "$out"
tab3=$(cat "$CSTATE3/crontab" 2>/dev/null || echo MISSING)
assert_not_contains "no publish crontab entry without --with-publish" "HIMMEL-GraphPublish-Himmel" "$tab3"
if [ ! -e "$CRON_DIR3/graphmap-publish-himmel.sh" ]; then
    pass "no publish runner written without --with-publish"
else
    fail "publish runner written without --with-publish" "$(ls "$CRON_DIR3" 2>/dev/null)"
fi
run_cron3 disarm >/dev/null 2>&1

echo "TEST: cron arm --ast-only --with-publish registers the publish leg (crontab entry + runner)"
out=$(run_cron3 arm --vault "$VAULT" --ast-only --with-publish 2>&1)
assert_contains "arm banner names the publish task" "HIMMEL-GraphPublish-Himmel" "$out"
tab3=$(cat "$CSTATE3/crontab" 2>/dev/null || echo MISSING)
assert_contains "publish crontab entry present" "# HIMMEL-GraphPublish-Himmel" "$tab3"
# Every-6-hours cron shape: fixed minute, hour field "*/6" (vixie-cron step
# syntax) -- NOT a bare "*" (that would be hourly, the AST_HIMMEL leg's own
# cadence, not this leg's documented 6h interval).
assert_contains "publish crontab entry fires every 6h (*/6 hour field)" "35 */6 * * *" "$tab3"
# Here-string, not a pipeline, and a || fallback: this file runs under
# `set -euo pipefail` and defines grepq at line 30 for exactly this reason.
# As a pipeline with no fallback, a MISSING publish entry made
# the assignment fail and killed the whole suite here -- no summary, no FAIL
# line -- so a real regression in publish-entry registration would have looked
# like a truncated run rather than a red test. RED-drilled: with the entry
# removed, this now prints a FAIL and the suite still reaches its summary.
runner_line3=$(grep -F "HIMMEL-GraphPublish-Himmel" <<< "$tab3" || echo MISSING)
assert_contains "publish crontab entry fires its own runner" "graphmap-publish-himmel.sh" "$runner_line3"
if [ -x "$CRON_DIR3/graphmap-publish-himmel.sh" ]; then
    pass "publish runner is present and executable"
else
    fail "publish runner missing or not executable" "$(ls "$CRON_DIR3" 2>/dev/null)"
fi
publish_sh=$(cat "$CRON_DIR3/graphmap-publish-himmel.sh" 2>/dev/null || echo MISSING)
assert_contains "publish runner fires graph-cadence.sh" "graph-cadence.sh" "$publish_sh"
# graph-cadence.sh alerts and writes its own flow rows, so the
# shared emitter block must NOT be added to this runner (it would double both).
assert_not_contains "publish runner has no shared flow-run block" "--append-start" "$publish_sh"
assert_not_contains "publish runner has no shared alert block" "cadence-alert.sh" "$publish_sh"
# --corpus-root, not a bare positional (graph-cadence.sh takes
# an explicit flag, unlike ast-update.sh's bare positional -- publish_bat_
# payload/publish_cron_payload exist specifically because ast_bat_payload's
# shape does NOT fit this script).
assert_contains "publish runner passes --corpus-root explicitly" "--corpus-root" "$publish_sh"
# The registered flow name is handed down, so the runner can never emit ledger
# rows under a different name than the registry entry.
_armed_slug="$(basename "$HIMMEL_ROOT_EXP" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
assert_contains "publish runner passes the armed flow name" "--flow-name graph-publish-$_armed_slug" "$publish_sh"
assert_contains "publish runner format stamp present" "# himmel-cadence-runner-format: $FMT" "$publish_sh"
# The registered flow name must be DERIVED from the
# SAME corpus-slug computation the runner itself uses (basename(HIMMEL_ROOT),
# sanitized) -- not a hardcoded "graph-publish-himmel" literal. This checkout
# is NOT named "himmel" (it's a worktree), so this assertion only passes if
# the derivation is real: a hardcoded literal would register
# "graph-publish-himmel" here, which would never match a flow-run row this
# checkout's own graph-cadence.sh actually emits.
EXPECTED_PUBLISH_SLUG="$(basename "$HIMMEL_ROOT_EXP" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
assert_registry "cron arm --with-publish registers the publish flow under its DERIVED name, not a hardcoded literal" \
    ".flows[] | select(.name == \"graph-publish-${EXPECTED_PUBLISH_SLUG}\" and .cadence_seconds == 21600)"
assert_registry "cron arm --with-publish registers the publish task name" '.expected_tasks[] | select(. == "HIMMEL-GraphPublish-Himmel")'

echo "TEST: cron status reports the publish leg's own schedule + summary"
out=$(run_cron3 status)
assert_contains "status shows publish task armed" "ARMED      HIMMEL-GraphPublish-Himmel (cron: 35 */6 * * *)" "$out"
assert_contains "status summary names graph-cadence" "graph-cadence publish himmel" "$out"

echo "TEST: cron disarm removes the publish leg's entry + runner"
out=$(run_cron3 disarm)
tab3=$(cat "$CSTATE3/crontab" 2>/dev/null || echo MISSING)
assert_not_contains "publish crontab entry removed by disarm" "HIMMEL-GraphPublish-Himmel" "$tab3"
if [ ! -f "$CRON_DIR3/graphmap-publish-himmel.sh" ]; then
    pass "publish runner removed by disarm"
else
    fail "publish runner survived disarm"
fi

echo "TEST: cron arm --ast-only twice without --force dedup-blocks on the publish leg too"
run_cron3 arm --vault "$VAULT" --ast-only --with-publish >/dev/null 2>&1
rc=0; out=$(run_cron3 arm --vault "$VAULT" --ast-only --with-publish 2>&1) || rc=$?
assert_rc "second --ast-only arm without --force blocked" 3 "$rc"
assert_contains "dedup message can name the publish task" "HIMMEL-GraphPublish-Himmel" "$out"
run_cron3 disarm >/dev/null 2>&1

echo "TEST: cron arm --with-publish --publish-every-hours 2 --publish-semantic"
out=$(run_cron3 arm --vault "$VAULT" --ast-only --with-publish --publish-every-hours 2 --publish-semantic 2>&1)
tab3=$(cat "$CSTATE3/crontab" 2>/dev/null || echo MISSING)
assert_contains "publish entry fires every 2h" "35 */2 * * *" "$tab3"
assert_not_contains "publish entry no longer every 6h" "*/6" "$tab3"
assert_not_contains "no luna semantic task is armed" "GraphSemantic" "$tab3"
publish_sh=$(cat "$CRON_DIR3/graphmap-publish-himmel.sh" 2>/dev/null || echo MISSING)
assert_contains "publish runner adds --semantic" "--semantic" "$publish_sh"
assert_contains "publish runner sets the api lane" "HIMMEL_API_LANE=on" "$publish_sh"
assert_contains "publish runner sets the api account" "HIMMEL_API_ACCOUNT=auto" "$publish_sh"
assert_contains "publish runner pins the claude-api backend" "GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api" "$publish_sh"
assert_contains "publish runner reads the pause marker" "semantic.paused" "$publish_sh"
assert_contains "publish runner logs the paused fire" "[semantic paused: marker present]" "$publish_sh"
assert_contains "publish runner logs the active fire" "[semantic active]" "$publish_sh"
# Marker present: the branch that runs must carry neither --semantic nor the api-lane env.
paused_branch=$(printf '%s\n' "$publish_sh" | sed -n 's/.*semantic paused: marker present\]"; \(.*\); else echo.*/\1/p')
assert_contains "paused branch still runs the publish leg" "graph-cadence.sh" "$paused_branch"
assert_not_contains "paused branch passes no --semantic" "--semantic" "$paused_branch"
assert_not_contains "paused branch sets no api lane" "HIMMEL_API_LANE" "$paused_branch"
if [ -e "$CRON_DIR3/semantic.paused" ]; then
    pass "arm --publish-semantic writes the pause marker itself"
else
    fail "arm --publish-semantic left no semantic.paused marker" "$(ls "$CRON_DIR3" 2>/dev/null)"
fi
assert_contains "arm banner says semantic is armed paused" "semantic armed PAUSED" "$out"
# Behavioural: run the generated runner against a stub graph-cadence.sh, marker present then absent.
stub_gc="$TMP_ROOT/stub-graph-cadence.sh"
stub_out="$TMP_ROOT/stub-graph-cadence.out"
# shellcheck disable=SC2016  # the stub body expands at its own run time
printf '#!/bin/sh\necho "ARGV: $*" >> "%s"\necho "LANE: ${HIMMEL_API_LANE:-unset}" >> "%s"\n' "$stub_out" "$stub_out" > "$stub_gc"
sed "s#[^ ]* [^ ]*scripts/graphify/graph-cadence.sh#sh $stub_gc#g" "$CRON_DIR3/graphmap-publish-himmel.sh" > "$TMP_ROOT/publish-stubbed.sh"
rm -f "$stub_out"
sh "$TMP_ROOT/publish-stubbed.sh" >/dev/null 2>&1 || true
stub_paused=$(cat "$stub_out" 2>/dev/null || echo MISSING)
assert_contains "paused fire still runs the publish leg" "ARGV: --corpus-root" "$stub_paused"
assert_not_contains "paused fire passes no --semantic" "--semantic" "$stub_paused"
assert_contains "paused fire sets no api lane" "LANE: unset" "$stub_paused"
rm -f "$CRON_DIR3/semantic.paused" "$stub_out"
sh "$TMP_ROOT/publish-stubbed.sh" >/dev/null 2>&1 || true
stub_active=$(cat "$stub_out" 2>/dev/null || echo MISSING)
assert_contains "active fire passes --semantic" "--semantic" "$stub_active"
assert_contains "active fire sets the api lane" "LANE: on" "$stub_active"
assert_registry "publish flow registers a 2h cadence" \
    ".flows[] | select(.name == \"graph-publish-${EXPECTED_PUBLISH_SLUG}\" and .cadence_seconds == 7200)"
out=$(run_cron3 status)
assert_contains "status shows the 2h publish schedule" "ARMED      HIMMEL-GraphPublish-Himmel (cron: 35 */2 * * *)" "$out"
run_cron3 disarm >/dev/null 2>&1
rm -f "$CRON_DIR3/semantic.paused"
out=$(run_cron3 arm --vault "$VAULT" --ast-only --with-publish --publish-every-hours 2 --publish-semantic --semantic-active 2>&1)
if [ -e "$CRON_DIR3/semantic.paused" ]; then
    fail "--semantic-active still wrote the pause marker" "$(ls "$CRON_DIR3" 2>/dev/null)"
else
    pass "--semantic-active arms without the pause marker"
fi
run_cron3 disarm >/dev/null 2>&1
rc=0; out=$(run_cron3 arm --vault "$VAULT" --ast-only --with-publish --publish-every-hours 5 2>&1) || rc=$?
assert_rc "--publish-every-hours rejects a non-divisor of 24" 1 "$rc"
rc=0; out=$(run_cron3 arm --vault "$VAULT" --ast-only --publish-semantic 2>&1) || rc=$?
assert_rc "--publish-semantic without --with-publish is rejected" 1 "$rc"
run_cron3 disarm >/dev/null 2>&1

# ============================================================================
# Darwin Full Disk Access arm-time warning, POSIX/
# cron path. cron_arm is IDENTICAL on macos and linux (both take the crontab
# branch of the platform case) except for this warning, so OSTYPE + HOME are
# the only two hermetic seams needed to exercise the real Darwin branch
# without a macOS machine -- this is a real control, not a stand-in for one
# (the ticket's own caveat: TCC's actual grant behavior stays unvalidated
# here regardless; this proves only that the branch fires on the right input).
# ============================================================================

CSTATE4="$TMP_ROOT/cron-state-darwin"
mkdir -p "$CSTATE4"
FAKE_CRONTAB4="$TMP_ROOT/crontab-fake-darwin.sh"
cat >"$FAKE_CRONTAB4" <<FAKE
#!/bin/sh
CSTATE="$CSTATE4"
FAKE
cat >>"$FAKE_CRONTAB4" <<'FAKE'
case "${1:-}" in
    -l)
        if [ -f "$CSTATE/crontab" ]; then
            cat "$CSTATE/crontab"
        else
            echo "no crontab for fakeuser" >&2
            exit 1
        fi
        ;;
    -) cat > "$CSTATE/crontab" ;;
    *) echo "crontab-fake: unsupported argv: $*" >&2; exit 64 ;;
esac
FAKE
chmod +x "$FAKE_CRONTAB4"
CRON_DIR4="$TMP_ROOT/cron-runners-darwin"
FDA_HOME="$TMP_ROOT/fda-home"
FDA_VAULT="$FDA_HOME/Documents/luna"
mkdir -p "$FDA_VAULT"
FDA_OUTSIDE_VAULT="$TMP_ROOT/fda-outside-vault"
mkdir -p "$FDA_OUTSIDE_VAULT"
run_fda() {
    local ostype="$1"; shift
    env OSTYPE="$ostype" HOME="$FDA_HOME" GRAPHMAP_CRONTAB="$FAKE_CRONTAB4" \
        GRAPHMAP_BAT_DIR="$CRON_DIR4" PATH="$TMP_ROOT/bin:$GRAPHIFY_BIN_DIR_PATH:$CLAUDE_BIN_DIR_PATH:$PATH" \
        "$REAL_BASH" "$SCRIPT" "$@"
}

echo "TEST: Darwin arm warns about Full Disk Access when the vault sits under ~/Documents"
out=$(run_fda darwin23 arm --vault "$FDA_VAULT" --force)
assert_contains "Darwin arm names the FDA requirement"        "Full Disk Access required" "$out"
assert_contains "Darwin arm names cron itself as the grantee" "/usr/sbin/cron"             "$out"
assert_contains "Darwin arm names himmel#771"                 "himmel#771"                 "$out"
assert_contains "Darwin arm names the protected vault path"   "$FDA_VAULT"                 "$out"
run_fda darwin23 disarm >/dev/null 2>&1

echo "TEST: Darwin arm stays silent when the vault sits outside every TCC-protected folder"
out=$(run_fda darwin23 arm --vault "$FDA_OUTSIDE_VAULT" --force)
assert_not_contains "Darwin arm on an unprotected vault prints no FDA warning" "Full Disk Access" "$out"
run_fda darwin23 disarm >/dev/null 2>&1

echo "TEST: non-Darwin arm on the IDENTICAL protected vault path never warns (the control)"
out=$(run_fda linux-gnu arm --vault "$FDA_VAULT" --force)
assert_not_contains "Linux arm on the same protected path prints no FDA warning" "Full Disk Access" "$out"
run_fda linux-gnu disarm >/dev/null 2>&1

# Test C-outroot: cron_payload / ast_cron_payload accept an
# optional out-root/out-dir arg and emit the flag ONLY when it is non-empty --
# the empty case is already covered above (the luna/himmel runner asserts
# never see --out-root/GRAPHIFY_OUT= today, since no test here sets
# GRAPHIFY_LUNA_OUT_ROOT), so this unit-tests the plumbing directly rather
# than re-running the whole hermetic cron_arm harness a second time.
echo "TEST: cron_payload / ast_cron_payload out-root wiring (HIMMEL-3718)"
CP_SRC="$(sed -n '/^cron_payload()/,/^}/p' "$SCRIPT")"
ACP_SRC="$(sed -n '/^ast_cron_payload()/,/^}/p' "$SCRIPT")"
run_cp() { bash -c "BACKEND=claude-cli"$'\n'"$CP_SRC"$'\n''cron_payload "$@"' _ "$@"; }
run_acp() { bash -c "$ACP_SRC"$'\n''ast_cron_payload "$@"' _ "$@"; }

cp_no_root=$(run_cp bash script.sh luna corpus maps title slug tag)
assert_not_contains "cron_payload omits --out-root when unset" "--out-root" "$cp_no_root"
cp_with_root=$(run_cp bash script.sh luna corpus maps title slug tag /out/root)
assert_contains "cron_payload appends --out-root when set" "--out-root /out/root" "$cp_with_root"

acp_no_dir=$(run_acp bash script.sh corpus)
assert_not_contains "ast_cron_payload omits GRAPHIFY_OUT= when unset" "GRAPHIFY_OUT=" "$acp_no_dir"
acp_with_dir=$(run_acp bash script.sh corpus /out/root/graphify-out)
assert_contains "ast_cron_payload prefixes GRAPHIFY_OUT= when set" "GRAPHIFY_OUT=/out/root/graphify-out " "$acp_with_dir"

# Test C-outroot-2: the himmel
# semantic runner never passes --out-root, but refresh-graph-map.sh now
# honors GRAPHIFY_OUT_ROOT from the environment as a fallback (line ~157) --
# an ambient value (e.g. left over from a luna promote test in the same
# shell) could otherwise redirect himmel's tracked graph out of its corpus.
# cron_payload must unset it explicitly whenever it omits --out-root.
assert_contains "cron_payload unsets GRAPHIFY_OUT_ROOT when --out-root is omitted" "unset GRAPHIFY_OUT_ROOT" "$cp_no_root"
assert_not_contains "cron_payload leaves GRAPHIFY_OUT_ROOT alone when --out-root is set" "unset GRAPHIFY_OUT_ROOT" "$cp_with_root"

# Test C-outroot-3: symmetric gap on
# the structural (AST) leg -- ast-update.sh reads GRAPHIFY_OUT from its
# environment the same way; an ambient value (e.g. from a manual luna AST
# test run in the same shell) could redirect himmel's AST leg the same way.
assert_contains "ast_cron_payload unsets GRAPHIFY_OUT when GRAPHIFY_OUT= is omitted" "unset GRAPHIFY_OUT" "$acp_no_dir"
assert_not_contains "ast_cron_payload leaves GRAPHIFY_OUT alone when it is set" "unset GRAPHIFY_OUT" "$acp_with_dir"

summary
