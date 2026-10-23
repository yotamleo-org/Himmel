#!/usr/bin/env bash
# Smoke test for scripts/luna/pipeline-cadence.sh (cron path,
# daily harvest+triage leg, no-LLM fetch-health leg).
#
# Four cadence tasks are armed: HIMMEL-Pipeline-FetchHealth (daily 01:30 ->
# direct fetch-health.py), HIMMEL-Pipeline-Harvest (daily 02:00 ->
# /harvest-clips + /triage-clips), HIMMEL-Pipeline-Synthesize (daily 03:00
# -> /synthesize-clips + /archive-clips), and HIMMEL-Pipeline-Health (daily
# 04:00 -> vault-lint / obsidian-triage:vault-lint).
# The three Claude legs launch with explicit --model pins
# (harvest/synth=claude-sonnet-5-5, health=haiku); fetch health is a plain
# Python script. All four legs are exercised throughout the dry-run / arm /
# shape / status / dedup / force / disarm / rollback tests below.
#
# Strategy: replace the scheduler with a fake — crontab via the
# PIPELINE_CRONTAB seam (a state-file crontab that supports -l and -
# install); point PIPELINE_BAT_DIR at a temp dir so the runners (.sh) are
# inspectable; put a fake `claude` first on PATH. The POSIX code path is
# forced with an OSTYPE override.
#
# Cron suite covers (C*):
#   C1.  status with empty crontab ("no crontab for user") -> not armed.
#   C2.  arm --dry-run prints runner bodies + all four entries, touches nothing.
#   C3.  arm installs the marker-tagged entries (all daily: 30 01 and
#        00 02/03/04 * * *) + executable runner .sh files; pre-existing
#        unrelated crontab lines survive.
#   C4.  Runner .sh is interactive-claude shaped: bounded `< /dev/null`,
#        chained synthesize->archive prompt, NO -p/--print/--bg, log
#        rotation + fire stamp.
#   C5.  status after arm -> all four ARMED (+ run-log line).
#   C6.  Re-arm without --force -> exit 3 (dedup), nothing duplicated.
#   C7.  Re-arm --force + flag overrides -> entries replaced, unrelated
#        line still intact, still exactly four markers.
#   C8.  disarm removes entries + runners, keeps unrelated lines;
#        second disarm is a no-op (rc 0).
#   C9.  Fail-closed: crontab -l fails (rc 1 + stderr) -> arm/status
#        exit 2; disarm exits 2 and keeps the runners.
#   C9b. Crashed crontab -l (rc=255, EMPTY stderr) is NOT trusted-empty.
#   C10. crontab install failure on fresh arm -> rc 4; no runner promoted
#        to its final path, no staged .tmp litter.
#   C10b. --force re-arm with failing install -> rc 4; OLD runners + OLD
#        entries fully intact (no new-config half-state).
#   C10c. disarm with failing install -> rc 4; entries + runners kept
#        (install-succeeds-BEFORE-rm ordering invariant).
#   C11. Hostile vault dirname + runner dir (& $ space %) land %q/\%-
#        escaped in runner + entry — no fire-time injection.
#   C15. Armed runner .sh EXECUTES end-to-end (recording claude stub,
#        hostile dirnames): log created with stub output + [fired] stamp,
#        prompt arrives as a SINGLE argv, cwd resolves to the vault,
#        second fire rotates .log -> .log.prev, status shows a real
#        mtime (date -r / stat -f fallback, not '?').
#   C12. Validation rejects bad input on the cron path -> rc 1.
#   C13. Unknown platform (OSTYPE=beos) -> exit 2.
#   C14. Dry-run disarm with armed entries prints DRY tail, touches
#        nothing.
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
SCRIPT="$SCRIPT_DIR/pipeline-cadence.sh"
# resolve_user_home/default_vault live in a shared lib that
# pipeline-cadence.sh sources — extract them from there.
HOME_LIB="$SCRIPT_DIR/../lib/resolve-user-home.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# cleanup() reaps the temp tree. Every fixture — including the hook-readability
# sandboxes — lives under $TMP_ROOT, so a SIGKILL / host
# crash can only ever leave temp litter, never a tracked hook file missing:
# these tests no longer rename a real scripts/hooks/*.sh, so there is nothing
# to restore.
# shellcheck disable=SC2329 # cleanup runs only via the EXIT trap
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

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
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

# build_hook_sandbox <sandbox-root> — materialize a throwaway copy of just the
# script tree a cadence `arm` resolves hooks from: pipeline-cadence.sh (whose
# BASH_SOURCE-derived HIMMEL_ROOT pins where it looks), the lib file it sources
# at load, and the three hooks whose readability arm warns about. Everything
# lands under <sandbox-root> (a temp dir), so hiding one hook for a readability
# mutation never renames a TRACKED file — a crash mid-test can only damage the
# sandbox, never the live checkout. Echoes the sandboxed script path on stdout.
build_hook_sandbox() {
    local sb="$1" real_hooks real_lib
    real_hooks="$(cd "$SCRIPT_DIR/../hooks" && pwd)"
    real_lib="$(cd "$SCRIPT_DIR/../lib" && pwd)"
    mkdir -p "$sb/scripts/hooks" "$sb/scripts/luna" "$sb/scripts/lib"
    cp "$SCRIPT" "$sb/scripts/luna/pipeline-cadence.sh"
    cp "$HOME_LIB" "$sb/scripts/lib/resolve-user-home.sh"
    cp "$real_lib/cadence-format.sh" "$sb/scripts/lib/cadence-format.sh"
    # Sourced at load too (for FLOW_RUN_ATTEMPT_MARKER), and it
    # sources its own path resolver — the sandboxed script cannot load without
    # both.
    cp "$real_lib/flow-run-ledger.sh" "$sb/scripts/lib/flow-run-ledger.sh"
    cp "$real_lib/flow-run-ledger-path.sh" "$sb/scripts/lib/flow-run-ledger-path.sh"
    # Also sourced at load, so the sandbox needs it too.
    cp "$real_lib/macos-fda-warning.sh" "$sb/scripts/lib/macos-fda-warning.sh"
    cp "$real_hooks/auto-approve-safe-bash.sh" "$sb/scripts/hooks/"
    cp "$real_hooks/cadence-deny-background.sh" "$sb/scripts/hooks/"
    cp "$real_hooks/cadence-approve-engines.sh" "$sb/scripts/hooks/"
    cp "$real_hooks/cadence-deny-powershell.sh" "$sb/scripts/hooks/"
    printf '%s' "$sb/scripts/luna/pipeline-cadence.sh"
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi
# Arms record a provenance row; never into the operator's ledger.
export HIMMEL_PROVENANCE_DIR="$TMP_ROOT/provenance"
# The generated claude runners shell usage-preflight.sh before
# launching, and the fire tests below EXECUTE those runners. Left alone, every
# fire would do a live usage-API fetch through usage-cache-producer.sh — slow,
# networked, and dependent on the arming machine's real bank state, which is
# the opposite of hermetic. The helper's own seams neutralise it: no refresh,
# a cache path that does not exist -> BANK-UNKNOWN, which is a FAIL-OPEN
# verdict, so the leg proceeds exactly as it did before the guard existed.
# The ledger is redirected into the temp tree so no test writes ~/.himmel.
export CADENCE_BANK_SKIP_REFRESH=1
export CADENCE_BANK_CACHE="$TMP_ROOT/no-such-usage-cache.json"
export CADENCE_BANK_LEDGER="$TMP_ROOT/cadence-ledger.jsonl"

# Shared fixtures ------------------------------------------------------------

# Fake claude on PATH (arm resolves it via `command -v claude`).
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/bin/claude"
chmod +x "$TMP_ROOT/bin/claude"
export PATH="$TMP_ROOT/bin:$PATH"

# Hermetic shared WSH preflight: both policy values are absent and the fake
# windowless host accepts the zero-exit smoke .vbs.
FAKE_WSCRIPT="$TMP_ROOT/wscript-fake.exe"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_WSCRIPT"
chmod +x "$FAKE_WSCRIPT"
FAKE_WSH_POWERSHELL="$TMP_ROOT/powershell-wsh-fake.sh"
printf '#!/bin/sh\necho ABSENT\n' > "$FAKE_WSH_POWERSHELL"
chmod +x "$FAKE_WSH_POWERSHELL"
export CADENCE_WSCRIPT_BIN="$FAKE_WSCRIPT"
export CADENCE_WSH_POWERSHELL="$FAKE_WSH_POWERSHELL"

# Redirect the workspace-trust pre-seed (cmd_arm / cron_arm now
# pre-trust the vault) at a throwaway config so non-dry-run arm tests never
# mutate the operator's real ~/.claude.json.
export WORKSPACE_TRUST_CONFIG="$TMP_ROOT/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP_ROOT/flow-runs.jsonl"
# A failing fired runner appends to the cadence alert file and
# sends one deduped Telegram DM through cadence-alert.sh. Every seam points into
# the temp tree, and the sender is a recorder, so no fire here ever writes
# ~/.himmel/state or reaches the real bridge.
export CADENCE_ALERT_FILE="$TMP_ROOT/cadence-alerts.log"
export CADENCE_ALERT_DEDUPE_DIR="$TMP_ROOT/cadence-alert-sent"
export CADENCE_ALERT_SEND_FAILED_MARK="$TMP_ROOT/send-failed-mark"
ALERT_SENDS="$TMP_ROOT/alert-sends.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$ALERT_SENDS" > "$TMP_ROOT/alert-send-rec"
chmod +x "$TMP_ROOT/alert-send-rec"
export CADENCE_ALERT_SEND_CMD="$TMP_ROOT/alert-send-rec"

VAULT="$TMP_ROOT/vault"
mkdir -p "$VAULT"

# Word-bounded headless claude invocation (`-p` / `--print` / `--bg`).
HEADLESS_RE='(^|[^A-Za-z0-9_-])claude[[:space:]]+(-p|--print|--bg)($|[^A-Za-z0-9_-])'

# ============================================================================
# xml_escape unit — the one non-trivial new string transform.
# Pure + platform-agnostic, so it runs on EVERY platform: extract the
# function from the script and call it directly. Pins the &-first ordering
# (escaping & last would double-escape the &lt;/&gt; entities) so a
# BAT_DIR path containing & / < / > yields well-formed task XML.
# ============================================================================
echo "TEST: xml_escape escapes & < > with & ordered first"
xesc=$( { sed -n '/^xml_escape()/,/^}/p' "$SCRIPT"; echo "xml_escape 'a & b < c > d'"; } | bash )
assert_contains "xml_escape produces well-formed entities (& first)" "a &amp; b &lt; c &gt; d" "$xesc"
assert_not_contains "xml_escape leaves no bare ampersand" "a & b" "$xesc"

# ============================================================================
# default_vault unit — cross-platform default --vault resolution.
# Pure (reads only env + cygpath), so it runs on EVERY platform: extract the
# function from the script and call it under controlled env. Pins: (1)
# LUNA_VAULT_PATH wins; (2) POSIX shape (USERPROFILE unset) is $HOME-based,
# unchanged; (3) on Windows Git-Bash the Windows profile (USERPROFILE via
# cygpath) wins over the MSYS $HOME — the exact failure the bare $HOME default
# hit (vault resolved to /home/<user>/Documents/luna, not the real profile).
# ============================================================================
echo "TEST: default_vault resolves the cross-platform default vault"
# default_vault delegates the home part to resolve_user_home, so
# extract BOTH functions for the standalone call.
DV_SRC="$(sed -n '/^resolve_user_home()/,/^}/p' "$HOME_LIB"; sed -n '/^default_vault()/,/^}/p' "$HOME_LIB")"
run_dv() { env "$@" bash -c "$DV_SRC"$'\n'"default_vault"; }

# USERPROFILE set too, so this proves LUNA_VAULT_PATH wins even when the
# Windows branch would otherwise fire — platform-independently (on POSIX
# USERPROFILE would otherwise be unset and only the $HOME branch tested).
dv_a=$(run_dv LUNA_VAULT_PATH="/some/explicit/vault" USERPROFILE='C:\Users\x')
assert_contains "default_vault honors LUNA_VAULT_PATH" "/some/explicit/vault" "$dv_a"
assert_not_contains "LUNA_VAULT_PATH used verbatim (no Documents/luna append)" "Documents/luna" "$dv_a"

dv_b=$(run_dv -u LUNA_VAULT_PATH -u USERPROFILE HOME="/posix/home")
assert_contains "default_vault POSIX shape is \$HOME/Documents/luna" "/posix/home/Documents/luna" "$dv_b"

# Last-resort fallback: HOME + USERPROFILE both unset -> /tmp (the documented
# floor). Locks the ${HOME:-${USERPROFILE:-/tmp}} chain against an accidental
# drop of the /tmp guard.
dv_d=$(run_dv -u LUNA_VAULT_PATH -u USERPROFILE -u HOME)
assert_contains "default_vault falls back to /tmp when HOME+USERPROFILE unset" "/tmp/Documents/luna" "$dv_d"

# cygpath present but FAILING on the input -> fall back to the raw USERPROFILE
# (the `cygpath -u … || printf '%s' "$USERPROFILE"` arm). Inject a stub cygpath
# that exits nonzero so this runs platform-independently (the stub IS the only
# cygpath on POSIX, and shadows the real one on Windows).
DV_FAKE_CYGPATH="$TMP_ROOT/fake-cygpath-fail"
mkdir -p "$DV_FAKE_CYGPATH"
printf '#!/usr/bin/env bash\nexit 1\n' > "$DV_FAKE_CYGPATH/cygpath"
chmod +x "$DV_FAKE_CYGPATH/cygpath"
# PATH entries must be POSIX-style for MSYS `command -v` to search them
# ($TMP_ROOT is the cygpath -m mixed C:/ form). On POSIX it's already POSIX.
DV_FAKE_PATH="$DV_FAKE_CYGPATH"
if command -v cygpath >/dev/null 2>&1; then DV_FAKE_PATH="$(cygpath -u "$DV_FAKE_CYGPATH")"; fi
dv_e=$(run_dv -u LUNA_VAULT_PATH -u HOME USERPROFILE='C:\Users\x' PATH="$DV_FAKE_PATH:$PATH")
assert_contains "default_vault falls back to raw USERPROFILE when cygpath -u fails" 'C:\Users\x/Documents/luna' "$dv_e"

if command -v cygpath >/dev/null 2>&1; then
    dv_c=$(run_dv -u LUNA_VAULT_PATH USERPROFILE='C:\Users\testuser' HOME="/home/msysuser")
    assert_contains "default_vault prefers Windows profile over MSYS \$HOME" "$(cygpath -u 'C:\Users\testuser')/Documents/luna" "$dv_c"
    assert_not_contains "default_vault does NOT use the MSYS \$HOME on Windows" "/home/msysuser" "$dv_c"
else
    echo "  SKIP: default_vault Windows-profile case (cygpath absent — POSIX host)"
fi

# ============================================================================
# resolve_user_home unit — the shared home resolver that ALSO
# backs the BAT_DIR default ($(resolve_user_home)/.claude/pipeline-cadence).
# Pins the same cross-platform contract directly on the helper so a BAT_DIR
# regression (runners landing under the MSYS home on Windows) is caught even
# though BAT_DIR itself is computed at script load.
# ============================================================================
echo "TEST: resolve_user_home resolves the cross-platform user home"
RUH_SRC="$(sed -n '/^resolve_user_home()/,/^}/p' "$HOME_LIB")"
run_ruh() { env "$@" bash -c "$RUH_SRC"$'\n'"resolve_user_home"; }

ruh_posix=$(run_ruh -u USERPROFILE HOME="/posix/home")
assert_contains "resolve_user_home POSIX shape is \$HOME" "/posix/home" "$ruh_posix"
assert_not_contains "resolve_user_home returns home only (no Documents append)" "Documents" "$ruh_posix"

ruh_floor=$(run_ruh -u USERPROFILE -u HOME)
assert_contains "resolve_user_home floor is /tmp when HOME+USERPROFILE unset" "/tmp" "$ruh_floor"

if command -v cygpath >/dev/null 2>&1; then
    ruh_win=$(run_ruh USERPROFILE='C:\Users\testuser' HOME="/home/msysuser")
    assert_contains "resolve_user_home prefers Windows profile over MSYS \$HOME" "$(cygpath -u 'C:\Users\testuser')" "$ruh_win"
    assert_not_contains "resolve_user_home does NOT use the MSYS \$HOME on Windows" "/home/msysuser" "$ruh_win"
else
    echo "  SKIP: resolve_user_home Windows-profile case (cygpath absent — POSIX host)"
fi

# ============================================================================
# POSIX (cron) suite. Runs on EVERY platform: the cron code
# path is forced via an OSTYPE override + the PIPELINE_CRONTAB seam.
# ============================================================================

CSTATE="$TMP_ROOT/cron-state"
mkdir -p "$CSTATE"

# Fake crontab: persists the installed tab at $CSTATE/crontab. Mimics
# real crontab signatures: -l with no tab installed prints "no crontab
# for <user>" to stderr + rc=1; `crontab -` installs from stdin.
# Failure-injection seams via marker files (see each test).
FAKE_CRONTAB="$TMP_ROOT/crontab-fake.sh"
cat >"$FAKE_CRONTAB" <<FAKE
#!/usr/bin/env bash
CSTATE="$CSTATE"
FAKE
cat >>"$FAKE_CRONTAB" <<'FAKE'
case "${1:-}" in
    -l)
        # `touch $CSTATE/fail-list`: -l fails like a permission error —
        # rc=1 with stderr that is NOT the no-crontab signature.
        if [ -e "$CSTATE/fail-list" ]; then
            echo "crontab: must be privileged to use -l" >&2
            exit 1
        fi
        # `touch $CSTATE/fail-list-255`: crashed tool — rc=255 with
        # EMPTY stderr. Must NOT be trusted as "empty crontab".
        if [ -e "$CSTATE/fail-list-255" ]; then
            exit 255
        fi
        if [ -f "$CSTATE/crontab" ]; then
            cat "$CSTATE/crontab"
        else
            echo "no crontab for fakeuser" >&2
            exit 1
        fi
        ;;
    -)
        # `touch $CSTATE/fail-write`: install from stdin fails.
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
    env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
        PIPELINE_BAT_DIR="$CRON_DIR" bash "$SCRIPT" "$@"
}

# Test C0: usage errors (subcommand parsing precedes the platform case) --------

echo "TEST: missing / unknown subcommand rejected"
rc=0; out=$(run_cron 2>&1) || rc=$?
assert_rc "no subcommand -> rc 1" 1 "$rc"
rc=0; out=$(run_cron frobnicate 2>&1) || rc=$?
assert_rc "unknown subcommand -> rc 1" 1 "$rc"

# Test C1: status with no crontab installed ----------------------------------

echo "TEST: cron status with no crontab installed"
out=$(run_cron status)
assert_contains "cron fetch-health not armed" "not armed  HIMMEL-Pipeline-FetchHealth" "$out"
assert_contains "cron harvest not armed"    "not armed  HIMMEL-Pipeline-Harvest"    "$out"
assert_contains "cron harvest not-armed summary names the full daily chain" "-> /harvest-clips + /triage-clips + /ig-media-enrich" "$out"
assert_contains "cron synthesize not armed" "not armed  HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "cron health not armed"     "not armed  HIMMEL-Pipeline-Health"     "$out"

# Test C12: shared validation wired into the cron path -----------------------

echo "TEST: cron arm rejects invalid input (shared validation)"
rc=0; out=$(run_cron arm --vault "$VAULT" --fetch-health-time 24:61 2>&1) || rc=$?
assert_rc "cron bad --fetch-health-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --harvest-time 24:61 2>&1) || rc=$?
assert_rc "cron bad --harvest-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --synth-time 25:00 2>&1) || rc=$?
assert_rc "cron bad --synth-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --ig-limit abc 2>&1) || rc=$?
assert_rc "cron bad --ig-limit (abc) -> rc 1" 1 "$rc"
assert_contains "cron bad --ig-limit message names flag" "--ig-limit must be a non-negative integer" "$out"
# --synth-day removed (synthesize is daily). Model pins must be
# non-empty.
rc=0; out=$(run_cron arm --vault "$VAULT" --synth-day mon 2>&1) || rc=$?
assert_rc "cron removed --synth-day -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "cron --synth-day message points at daily" "daily now" "$out"
# --health-day defaults to weekly (cadence audit 2026-08-23): four days of vault-lint moving
# 363 -> 369 findings did not justify a daily health leg, so it is weekly again.
# A lowercase spelling is accepted and canonicalised;
# a non-DOW value is still rejected outright rather than silently ignored.
# --dry-run on the valid case so the rejection block leaves nothing armed --
# an actually-armed cron here would trip the dedup guard in the next test.
rc=0; out=$(run_cron arm --vault "$VAULT" --health-day sun --dry-run 2>&1) || rc=$?
assert_rc "cron --health-day sun accepted" 0 "$rc"
assert_contains "cron --health-day sun -> weekly Sunday entry" "00 04 * * 0" "$out"
rc=0; out=$(run_cron arm --vault "$VAULT" --health-day daily --dry-run 2>&1) || rc=$?
assert_rc "cron --health-day daily accepted" 0 "$rc"
assert_contains "cron --health-day daily -> every-day entry" "00 04 * * *" "$out"
rc=0; out=$(run_cron arm --vault "$VAULT" --health-day=15 2>&1) || rc=$?
assert_rc "cron bad --health-day -> rc 1" 1 "$rc"
assert_contains "cron bad --health-day names the accepted set" "MON TUE WED THU FRI SAT SUN DAILY" "$out"
rc=0; out=$(run_cron arm --vault "$VAULT" --health-model "" 2>&1) || rc=$?
assert_rc "cron empty --health-model -> rc 1 (HIMMEL-506)" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --harvest-model "" 2>&1) || rc=$?
assert_rc "cron empty --harvest-model -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "cron empty --harvest-model message names the flag + grammar" "--harvest-model must match [A-Za-z0-9][A-Za-z0-9._:-]*" "$out"
# A model value carrying " and & must be rejected by the grammar gate; the
# message names the offending flag, the grammar and the value.
rc=0; out=$(run_cron arm --vault "$VAULT" --harvest-model 'a"&b' 2>&1) || rc=$?
assert_rc "cron hostile --harvest-model (\" and &) -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "cron hostile model message names the flag" "--harvest-model" "$out"
assert_contains "cron hostile model message names the grammar" "[A-Za-z0-9][A-Za-z0-9._:-]*" "$out"
assert_contains "cron hostile model message echoes the offending value" "a\"&b" "$out"
# Whitespace-only slips a bare [ -z ] check; the grammar rejects it.
rc=0; out=$(run_cron arm --vault "$VAULT" --harvest-model " " 2>&1) || rc=$?
assert_rc "cron whitespace-only --harvest-model -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "cron whitespace model message names the flag" "--harvest-model" "$out"
rc=0; out=$(run_cron arm --vault "$TMP_ROOT/does-not-exist" 2>&1) || rc=$?
assert_rc "cron missing vault dir -> rc 1" 1 "$rc"

# Test C2: arm --dry-run touches nothing --------------------------------------

echo "TEST: cron arm --dry-run prints plan, installs nothing"
out=$(run_cron arm --vault "$VAULT" --dry-run)
assert_contains "dry-run daily fetch-health entry" "30 01 * * *" "$out"
assert_contains "dry-run fetch-health marker" "# HIMMEL-Pipeline-FetchHealth" "$out"
assert_contains "dry-run fetch-health runner is no-LLM" "fetch-health.py" "$out"
assert_contains "dry-run daily harvest entry" "00 02 * * *" "$out"
assert_contains "dry-run daily synth entry"   "00 03 * * *" "$out"
assert_contains "dry-run weekly health entry"  "00 04 * * 0" "$out"
assert_contains "dry-run harvest marker" "# HIMMEL-Pipeline-Harvest" "$out"
assert_contains "dry-run synth marker"  "# HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "dry-run shows bounded run" "< /dev/null" "$out"
assert_contains "dry-run pre-trusts vault (HIMMEL-386)" "would pre-trust workspace '$VAULT'" "$out"
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
assert_contains "cron arm banner" "PIPELINE CADENCE ARMED" "$out"
# The real (non-dry-run) arm pre-trusts the vault in the (temp) config.
if command -v node >/dev/null 2>&1; then
    trust=$(WT_F="$WORKSPACE_TRUST_CONFIG" WT_K="$VAULT" node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.env.WT_F,"utf8"));process.stdout.write(String(j.projects&&j.projects[process.env.WT_K]&&j.projects[process.env.WT_K].hasTrustDialogAccepted))}catch(e){process.stdout.write("ERR")}')
    assert_contains "cron arm pre-trusts vault in config" "true" "$trust"
fi
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "daily fetch-health entry 01:30" "30 01 * * *" "$tab"
assert_contains "fetch-health entry marker-tagged" "# HIMMEL-Pipeline-FetchHealth" "$tab"
assert_contains "fetch-health entry fires the runner" "pipeline-fetch-health.sh" "$tab"
assert_contains "daily harvest entry 02:00"  "00 02 * * *" "$tab"
assert_contains "daily synth entry 03:00"    "00 03 * * *" "$tab"
assert_contains "weekly health entry SUN 04:00"   "00 04 * * 0" "$tab"
assert_contains "harvest entry marker-tagged" "# HIMMEL-Pipeline-Harvest"     "$tab"
assert_contains "synth entry marker-tagged"  "# HIMMEL-Pipeline-Synthesize" "$tab"
assert_contains "health entry marker-tagged" "# HIMMEL-Pipeline-Health"     "$tab"
# Every armed entry is recorded as a `job register` row.
jobs=$( . "$SCRIPT_DIR/../lib/provenance.sh" && . "$SCRIPT_DIR/../lib/provenance-read.sh" && prov_read_load >/dev/null && prov_read_units --kind job | jq -r '"\(.unit) ours=\(.ours) scheduler=\(.fields.scheduler)"' | LC_ALL=C sort )
assert_contains "arm recorded all four pipeline jobs (ours, cron)" \
    "HIMMEL-Pipeline-FetchHealth ours=true scheduler=cron
HIMMEL-Pipeline-Harvest ours=true scheduler=cron
HIMMEL-Pipeline-Health ours=true scheduler=cron
HIMMEL-Pipeline-Synthesize ours=true scheduler=cron" "$jobs"
assert_contains "harvest entry fires the runner" "pipeline-harvest.sh"    "$tab"
assert_contains "synth entry fires the runner"  "pipeline-synthesize.sh" "$tab"
assert_contains "health entry fires the runner" "pipeline-health.sh"     "$tab"
assert_contains "unrelated entry preserved" "keep-me" "$tab"
if [ -x "$CRON_DIR/pipeline-fetch-health.sh" ] && [ -x "$CRON_DIR/pipeline-harvest.sh" ] && [ -x "$CRON_DIR/pipeline-synthesize.sh" ] && [ -x "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files written + executable"
else
    fail "runner .sh files missing or not executable" "$(ls -l "$CRON_DIR" 2>/dev/null || true)"
fi

# Test C4: runner .sh is interactive-claude shaped -----------------------------

echo "TEST: runner .sh is bounded interactive claude (no headless flags)"
fetch_health_sh=$(cat "$CRON_DIR/pipeline-fetch-health.sh" 2>/dev/null || echo MISSING)
harvest_sh=$(cat "$CRON_DIR/pipeline-harvest.sh" 2>/dev/null || echo MISSING)
synth_sh=$(cat "$CRON_DIR/pipeline-synthesize.sh" 2>/dev/null || echo MISSING)
health_sh=$(cat "$CRON_DIR/pipeline-health.sh" 2>/dev/null || echo MISSING)
# The expected version is SOURCED, never retyped: this suite
# bounced on a hardcoded 14 the moment the constant moved to 15, which is a
# test maintenance cost with no coverage value -- the assertion that matters is
# "the runner stamps the CURRENT format", not "the runner stamps 14".
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/../lib/cadence-format.sh"
FMT="$CADENCE_RUNNER_FORMAT_VERSION"
assert_contains "fetch-health runner stamps the format version" "# himmel-cadence-runner-format: $FMT" "$fetch_health_sh"
assert_contains "fetch-health runner invokes the plain probe script" "fetch-health.py" "$fetch_health_sh"
assert_not_contains "fetch-health runner invokes no claude" "claude --model" "$fetch_health_sh"
assert_contains "fetch-health runner restores arming PATH (HIMMEL-1449 r2)" '; export PATH' "$fetch_health_sh"
assert_contains "fetch-health runner guards the repo .env source (HIMMEL-1449 r2)" '] && . ' "$fetch_health_sh"
assert_contains "fetch-health runner .env source targets the repo env file (HIMMEL-1449 r2)" '/.env' "$fetch_health_sh"
# The leg writes the same flow-run ledger rows as the claude legs,
# so a FetchHealth run that stops firing is detectable as a MISSING row rather
# than being indistinguishable from a cadence that was never armed.
assert_contains "fetch-health runner opens a flow-run ledger row (HIMMEL-1724)" '--append-start pipeline-fetch-health' "$fetch_health_sh"
assert_contains "fetch-health runner closes the flow-run ledger row (HIMMEL-1724)" '--append-end pipeline-fetch-health' "$fetch_health_sh"
assert_contains "fetch-health runner names the leg's task in the start row (HIMMEL-1724)" 'HIMMEL-Pipeline-FetchHealth' "$fetch_health_sh"
# shellcheck disable=SC2016  # the runner's own $_rc, asserted as literal emitted text
assert_contains "fetch-health runner derives the outcome from the probe rc (HIMMEL-1724)" '_flow_outcome=complete; [ "$_rc" = 0 ] || _flow_outcome=error' "$fetch_health_sh"

# Test C4d: fetch-health runner PATH export restores binary resolution under
# cron's empty environment. The real failure mode: cron runs
# with PATH=/usr/bin:/bin and no user env, so the probes' shelled-out CLIs
# (gallery-dl, twitter, gh) vanish and every night is a false exit 1. The
# emitted runner bakes the arming shell's PATH in, so a binary present at arm
# time stays resolvable when the ambient PATH is stripped. Host-gated (needs
# `env -i` + /bin/sh); the emission asserts above run on every host.
echo "TEST: fetch-health runner PATH export resolves a probe binary under env -i (HIMMEL-1449 r2)"
if command -v env >/dev/null 2>&1 && [ -x /bin/sh ]; then
    # Clean POSIX stub dir + a probe-shaped binary on it. cygpath -u (when
    # available) keeps the dir POSIX-form: a C:/ mixed-form PATH entry splits on
    # the drive colon under plain /bin/sh and silently never resolves (the same
    # trap the C15 claude-stub arm avoids). The stub dir leads a clean PATH baked
    # with the emitter's own printf %q pattern, so the fixture exercises the real
    # emit form independent of the host's ambient PATH.
    stub_dir="$TMP_ROOT/c4d-stubbin"
    mkdir -p "$stub_dir"
    if command -v cygpath >/dev/null 2>&1; then stub_dir=$(cygpath -u "$stub_dir"); fi
    probe_stub="$stub_dir/fetch-health-probe-stub"
    printf '#!/bin/sh\nexit 0\n' > "$probe_stub"
    chmod +x "$probe_stub"
    q_clean_path=$(printf '%q' "$stub_dir:/usr/bin:/bin")
    with_export="$TMP_ROOT/env-i-with-path.sh"
    without_export="$TMP_ROOT/env-i-without-path.sh"
    {
        printf '#!/bin/sh\n'
        printf 'PATH=%s; export PATH\n' "$q_clean_path"
        printf 'command -v fetch-health-probe-stub >/dev/null 2>&1\n'
    } > "$with_export"
    printf '#!/bin/sh\ncommand -v fetch-health-probe-stub >/dev/null 2>&1\n' > "$without_export"
    chmod +x "$with_export" "$without_export"
    # Pass ONLY if the export makes the stub resolve AND, without it, it can't —
    # proving resolution rides on the emitted PATH line, not ambient PATH.
    if env -i /bin/sh "$with_export" >/dev/null 2>&1 && ! env -i /bin/sh "$without_export" >/dev/null 2>&1; then
        pass "fetch-health runner PATH export restores binary resolution under env -i (HIMMEL-1449 r2)"
    else
        fail "fetch-health runner PATH export did not gate binary resolution under env -i" "clean_path=$q_clean_path"
    fi
else
    pass "fetch-health runner env -i execution skipped (host lacks env -i / /bin/sh)"
fi
assert_contains "harvest runner stamps the format version (HIMMEL-588)" "# himmel-cadence-runner-format: $FMT" "$harvest_sh"
assert_contains "synth runner stamps the format version (HIMMEL-588)"   "# himmel-cadence-runner-format: $FMT" "$synth_sh"
assert_contains "health runner stamps the format version (HIMMEL-588)"  "# himmel-cadence-runner-format: $FMT" "$health_sh"
# Same PATH-snapshot shape assertion as fetch-health above, but against the
# REAL emit_runner output (not a reconstructed shape):
# the old node-dir-only line was `export PATH=<node_dir>:$PATH` (no leading
# semicolon), so this distinguishes the fix's `PATH=<snapshot>; export PATH`
# shape from a regression back to the old prepend-only line.
assert_contains "harvest runner restores arm-time PATH snapshot (HIMMEL-2840)" '; export PATH' "$harvest_sh"
assert_contains "synth runner restores arm-time PATH snapshot (HIMMEL-2840)"   '; export PATH' "$synth_sh"
assert_contains "health runner restores arm-time PATH snapshot (HIMMEL-2840)"  '; export PATH' "$health_sh"
assert_contains "harvest runner cds into vault" "cd $VAULT || {" "$harvest_sh"
assert_contains "harvest runner runs /harvest-clips" "/harvest-clips" "$harvest_sh"
assert_contains "harvest runner chains /triage-clips" "/triage-clips" "$harvest_sh"
# The sh runner embeds the prompt via printf %q, which backslash-escapes
# spaces - strip the escapes before multi-word prompt assertions.
harvest_sh_plain=${harvest_sh//\\/}
assert_contains "harvest runner chains /ig-media-enrich default limit" "/ig-media-enrich --limit 10" "$harvest_sh_plain"
assert_contains "harvest runner passes --include-evidence to /ig-media-enrich (HIMMEL-3174)" "/ig-media-enrich --limit 10 --include-evidence" "$harvest_sh_plain"
assert_contains "harvest runner names --include-evidence on the step sentence too (HIMMEL-3174)" "step uses --limit 10 --include-evidence" "$harvest_sh_plain"
assert_contains "harvest runner fail-opens ig-media-enrich" "must not abort" "$harvest_sh_plain"
# x-media-enrich runs nightly beside
# ig-media, bounded by the same --ig-limit, and fail-opens the same way.
assert_contains "harvest runner chains /x-media-enrich (HIMMEL-4181)" "/x-media-enrich --limit 10 --include-evidence" "$harvest_sh_plain"
assert_contains "harvest runner fail-opens x-media-enrich (HIMMEL-4181)" "If /x-media-enrich fails" "$harvest_sh_plain"
# A backlog left for later nights is not a failure. The 04:47 run
# withheld the marker over the X backlog and 3 slides-pending-digest IG clips.
assert_contains "harvest DONE: a remaining backlog still completes (HIMMEL-4684)" "A backlog left for later runs is not unfinished work" "$harvest_sh_plain"
assert_contains "harvest DONE: backlog is reported, not withheld (HIMMEL-4684)" "report the remaining counts and still print the marker" "$harvest_sh_plain"
assert_contains "harvest DONE: a real step failure withholds it (HIMMEL-4684)" "Withhold the marker only when a step itself failed or aborted" "$harvest_sh_plain"
assert_contains "harvest runner bounded run"         "< /dev/null"    "$harvest_sh"
assert_contains "synth runner cds into vault" "cd $VAULT || {" "$synth_sh"
assert_contains "synth runner runs /synthesize-clips" "/synthesize-clips" "$synth_sh"
assert_contains "synth runner chains /archive-clips"  "/archive-clips"    "$synth_sh"
assert_contains "synth runner bounded run"            "< /dev/null"       "$synth_sh"
synth_sh_plain=${synth_sh//\\/}
assert_contains "synth DONE: archive-clips (stuck) clips are structural backlog (HIMMEL-6433)" "archive-clips reports clips as (stuck)" "$synth_sh_plain"
assert_contains "synth DONE: stuck clips still print the marker (HIMMEL-6433)" "report the stuck count and still print the marker" "$synth_sh_plain"
assert_contains "synth DONE: a real step failure withholds it (HIMMEL-6433)" "Withhold the marker when a step itself failed or aborted" "$synth_sh_plain"
assert_contains "synth DONE: blocked, parked or early-bailed still withholds it (HIMMEL-6433)" "or the leg was blocked, parked, or bailed early; do not withhold it only because stuck clips remain" "$synth_sh_plain"
assert_not_contains "synth DONE: no clause makes stuck clips withhold the marker (HIMMEL-6433)" "stuck clips remain, do not print" "$synth_sh_plain"
# shellcheck disable=SC2016  # literal $log needles — the runner expands them at fire time
assert_contains "synth runner rotates the log" 'mv -f "$log" "$log.prev"' "$synth_sh"
assert_contains "synth runner stamps every fire" '[fired' "$synth_sh"
# shellcheck disable=SC2016
assert_contains "synth runner captures output to log" '>> "$log" 2>&1' "$synth_sh"
assert_contains "health runner runs vault-lint" "obsidian-triage:vault-lint" "$health_sh"
assert_contains "health runner bounded run"           "< /dev/null"      "$health_sh"
for what in harvest synth health; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    body_plain=${body//\\/}
    assert_contains "$what runner requires foreground execution" "Run every command in the foreground. Never background a command or wait for a notification." "$body_plain"
    assert_contains "$what runner carries the fail-closed bare marker instruction" "Only if this cadence leg genuinely completed all of its work, print exactly PIPELINE-LEG-DONE as the final line of your output, on its own line with no prefix, suffix, or punctuation." "$body_plain"
done
for what in harvest synth health; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    assert_contains "$what runner classifies against the completion marker" '"" PIPELINE-LEG-DONE 2>/dev/null' "$body"
    # shellcheck disable=SC2016  # emitted runner text, asserted literally
    assert_contains "$what runner fails closed when the classifier is silent" 'if [ "$_flow_outcome" = "" ]; then if [ "$_rc" = 0 ]; then _flow_outcome=parked; else _flow_outcome=error; fi; fi' "$body"
    assert_not_contains "$what runner has no complete-by-default fallback" '_flow_outcome=complete' "$body"
    # shellcheck disable=SC2016  # the runner's own $_flow_outcome/$_rc, asserted as literal emitted text
    assert_contains "$what runner raises a no-op leg (rc 0, not complete) to exit 3" 'if [ "$_rc" = 0 ] && [ "$_flow_outcome" != complete ]; then exit 3; fi' "$body"
done
# Every CLAUDE leg (not just harvest) carries the bounded
# retry/resume wrapper — same emitter, so all three or none.
# shellcheck disable=SC2016  # literal $_attempt/$_rc needles — the runner expands them at fire time
for what in harvest synth health; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    assert_contains "$what runner wraps claude in the retry loop" "while :; do" "$body"
    assert_contains "$what runner stamps a per-attempt marker" "cadence-attempt \$_attempt/3" "$body"
    assert_contains "$what runner gates the retry on the transient signature" "--is-transient" "$body"
    assert_contains "$what runner bounds the attempts at 3" '[ "$_attempt" -ge 3 ] && break' "$body"
    assert_contains "$what runner backs off 60s then 180s" '_delay=60; [ "$_attempt" -ge 2 ] && _delay=180' "$body"
    assert_contains "$what runner tags each ledger end row with its attempt" 'attempt=$_attempt/3' "$body"
done
for what in harvest synth health; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    if printf '%s\n' "$body" | grep -E "$HEADLESS_RE" >/dev/null 2>&1; then
        fail "$what runner is headless-shaped" "$body"
    else
        pass "$what runner has no headless claude flags"
    fi
done

# Test C4e: runner_path_snapshot unit — the shared helper both
# emitters call. Pure (string-only), so extract it the way xml_escape/
# default_vault are tested above and call it standalone. Pins: (1) a node_dir
# NOT already in the snapshot gets prepended (keeps #317's guarantee: nvm-
# managed node found under cron's minimal PATH); (2) a node_dir ALREADY in the
# snapshot is not prepended again (no duplicate PATH entry).
# ============================================================================
echo "TEST: runner_path_snapshot prepends node_dir only when missing (HIMMEL-2840)"
RPS_SRC="$(sed -n '/^runner_path_snapshot()/,/^}/p' "$SCRIPT")"
run_rps() { bash -c "$RPS_SRC"$'\n'"runner_path_snapshot \"\$1\" \"\$2\"" _ "$1" "$2"; }

rps_missing=$(run_rps "/usr/bin:/bin" "/opt/nvm/node/bin")
assert_contains "runner_path_snapshot prepends a node_dir absent from the snapshot" "/opt/nvm/node/bin" "$rps_missing"
case "$rps_missing" in
    "/opt/nvm/node/bin:"*) pass "runner_path_snapshot puts the missing node_dir FIRST" ;;
    *) fail "runner_path_snapshot did not prepend the missing node_dir first" "$rps_missing" ;;
esac

rps_present=$(run_rps "/opt/nvm/node/bin:/usr/bin:/bin" "/opt/nvm/node/bin")
occurrences=$(printf '%s' "$rps_present" | grep -o "/opt/nvm/node/bin" | wc -l | tr -d ' ')
if [ "$occurrences" = "1" ]; then
    pass "runner_path_snapshot does not duplicate a node_dir already on the snapshot"
else
    fail "runner_path_snapshot duplicated a node_dir already on the snapshot" "$rps_present"
fi

rps_no_node=$(run_rps "/usr/bin:/bin" "")
assert_contains "runner_path_snapshot with no node_dir echoes the snapshot as-is" "/usr/bin:/bin" "$rps_no_node"

# Test C4f: emitted runner PATH line resolves a stub tool that lives ONLY in
# a fixture ~/.local/bin-shaped dir under env -i. RED control:
# the OLD emit_runner line (`export PATH=<node_dir>:$PATH`, prepending only
# node's directory) must FAIL this — it never puts the fixture dir on PATH at
# all — proving the regression this ticket fixes stays caught. The fixture
# dir is synthetic (never this station's real PATH); node_dir is a synthetic
# path too, so the RED control needs no real node install.
# ============================================================================
echo "TEST: emitted runner PATH line resolves an arm-time-only ~/.local/bin stub under env -i (RED control, HIMMEL-2840)"
if command -v env >/dev/null 2>&1 && [ -x /bin/sh ]; then
    localbin_dir="$TMP_ROOT/c4f-localbin"
    mkdir -p "$localbin_dir"
    if command -v cygpath >/dev/null 2>&1; then localbin_dir=$(cygpath -u "$localbin_dir"); fi
    localbin_stub="$localbin_dir/gallery-dl-stub"
    printf '#!/bin/sh\nexit 0\n' > "$localbin_stub"
    chmod +x "$localbin_stub"
    fake_node_dir="$TMP_ROOT/c4f-fake-node-bin"
    mkdir -p "$fake_node_dir"

    # Snapshot PATH exactly as cron_arm computes it: the fixture ~/.local/bin
    # dir is on the arming PATH (as it would be for a real `uv tool install`),
    # node's dir is not — so the fix must fold node_dir in via
    # runner_path_snapshot while STILL carrying the fixture dir through.
    arm_time_path="$localbin_dir:/usr/bin:/bin"
    q_new_path=$(run_rps "$arm_time_path" "$fake_node_dir")
    new_shape="$TMP_ROOT/c4f-new-shape.sh"
    {
        printf '#!/bin/sh\n'
        printf 'PATH=%s; export PATH\n' "$q_new_path"
        printf 'command -v gallery-dl-stub >/dev/null 2>&1\n'
    } > "$new_shape"
    chmod +x "$new_shape"

    # OLD shape (pre-fix emit_runner): node-dir-only prepend, never touches the
    # fixture dir — this is the exact line the snapshot replaces.
    q_old_node_dir=$(printf '%q' "$fake_node_dir")
    old_shape="$TMP_ROOT/c4f-old-shape.sh"
    {
        printf '#!/bin/sh\n'
        # shellcheck disable=SC2016  # literal $PATH — the OLD runner shape expands it at fire time, not here
        printf 'export PATH=%s:$PATH\n' "$q_old_node_dir"
        printf 'command -v gallery-dl-stub >/dev/null 2>&1\n'
    } > "$old_shape"
    chmod +x "$old_shape"

    if env -i PATH=/usr/bin:/bin /bin/sh "$new_shape" >/dev/null 2>&1; then
        pass "GREEN: new PATH-snapshot shape resolves the arm-time-only stub under env -i"
    else
        fail "GREEN: new PATH-snapshot shape failed to resolve the stub" "path=$arm_time_path node_dir=$fake_node_dir"
    fi
    if env -i PATH=/usr/bin:/bin /bin/sh "$old_shape" >/dev/null 2>&1; then
        fail "RED control: old node-dir-only prepend unexpectedly resolved the stub" "old_shape should never see $localbin_dir"
    else
        pass "RED control: old node-dir-only prepend fails to resolve the stub (the bug this ticket fixes)"
    fi
else
    pass "emitted runner PATH-snapshot env -i execution skipped (host lacks env -i / /bin/sh)"
fi

# Test C4c: per-leg --model pins — every runner carries an
# explicit --model right after the binary so the cadence never inherits the
# operator's saved default tier. Defaults: harvest/synth=claude-sonnet-5-5, health=haiku.
echo "TEST: cron runners carry the per-leg --model pin (HIMMEL-506)"
assert_contains "harvest runner pins --model claude-sonnet-5-5" "--model claude-sonnet-5-5" "$harvest_sh"
assert_contains "synth runner pins --model claude-sonnet-5-5"   "--model claude-sonnet-5-5" "$synth_sh"
assert_contains "health runner pins --model haiku"    "--model haiku"  "$health_sh"

echo "TEST: cron runners omit the print-only bg-wait ceiling override (HIMMEL-951)"
assert_not_contains "harvest runner omits bg-wait ceiling override" "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$harvest_sh"
assert_not_contains "synth runner omits bg-wait ceiling override"   "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$synth_sh"
assert_not_contains "health runner omits bg-wait ceiling override"  "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$health_sh"

# Test C4a2: every claude leg gates before it spends ------
# The audit finding this closes: `grep -c bank-preflight pipeline-cadence.sh`
# was 0 while three claude legs fired nightly. These assertions are the reason
# a future refactor cannot quietly drop the guard again.

echo "TEST: cron claude runners preflight the bank, attribute the leg, pin the mode"
for _leg in harvest:pipeline-harvest synth:pipeline-synthesize health:pipeline-health; do
    _name=${_leg%%:*}; _flow=${_leg#*:}
    _body=$(eval "printf '%s' \"\$${_name}_sh\"")
    assert_contains "$_name runner calls bank-preflight" "usage-preflight.sh" "$_body"
    assert_contains "$_name runner sets CADENCE_USAGE_LEG=$_flow" "CADENCE_USAGE_LEG=$_flow" "$_body"
    assert_contains "$_name runner refuses on SKIPPED-BANK" "SKIPPED-BANK" "$_body"
    assert_contains "$_name runner pins --permission-mode" "--permission-mode" "$_body"
    assert_not_contains "$_name runner never bypasses permissions" "bypassPermissions" "$_body"
done
# Only the synthesize leg is input-gated: harvest drains an inbox that fills
# every day, and health lints the whole vault regardless of clip flow.
assert_contains "synth runner runs the input gate" "synth-input-check.sh" "$synth_sh"
assert_contains "synth runner skips on NONE" "NONE" "$synth_sh"
assert_contains "synth runner logs the skip marker" "PIPELINE-LEG-SKIPPED" "$synth_sh"
assert_contains "synth runner stamps a completed leg" "--stamp" "$synth_sh"
assert_not_contains "harvest runner is not input-gated" "synth-input-check.sh" "$harvest_sh"
assert_not_contains "health runner is not input-gated" "synth-input-check.sh" "$health_sh"

# Test C4b: --settings injection wires the auto-approve hook -------

echo "TEST: cron runners inject --settings + fragment wires auto-approve hook"
assert_contains "harvest runner injects --settings" "--settings" "$harvest_sh"
assert_contains "synth runner injects --settings"   "--settings" "$synth_sh"
assert_contains "health runner injects --settings"  "--settings" "$health_sh"
assert_contains "harvest runner --settings targets the fragment" "cadence-settings.json" "$harvest_sh"
frag="$CRON_DIR/cadence-settings.json"
if [ -f "$frag" ]; then
    pass "settings fragment written to the runner dir"
else
    fail "settings fragment missing at $frag"
fi
frag_body=$(cat "$frag" 2>/dev/null || echo MISSING)
if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$frag_body" | jq -e '.hooks.PreToolUse[0].matcher == "Bash"' >/dev/null 2>&1; then
        pass "fragment is valid JSON wiring a PreToolUse Bash hook"
    else
        fail "fragment JSON does not wire a PreToolUse Bash hook" "$frag_body"
    fi
    # Two cadence-scoped controls are wired AHEAD of
    # auto-approve, so auto-approve is no longer hooks[0]. Take the LAST entry
    # (its documented slot) for the path assertions below, and assert the whole
    # ORDER separately — deny-background must precede the allow, and
    # auto-approve stays last.
    hookcmd=$(printf '%s' "$frag_body" | jq -r '.hooks.PreToolUse[0].hooks[-1].command' 2>/dev/null || echo "")
    hookorder=$(printf '%s' "$frag_body" | jq -r '[.hooks.PreToolUse[0].hooks[].command | gsub("\"";"") | sub("^.*/"; "")] | join(",")' 2>/dev/null || echo "")
    if [ "$hookorder" = "cadence-deny-background.sh,cadence-approve-engines.sh,auto-approve-safe-bash.sh" ]; then
        pass "fragment wires deny-background, then approve-engines, then auto-approve"
    else
        fail "fragment PreToolUse hook order is wrong" "$hookorder"
    fi
    # Every hook above matches Bash only, so the PowerShell tool is
    # an unguarded second shell in a cadence session — the health leg emitted the
    # vault-lint engine through it and parked. A second matcher block denies it.
    pwshorder=$(printf '%s' "$frag_body" | jq -r '[.hooks.PreToolUse[] | select(.matcher == "PowerShell") | .hooks[].command | gsub("\"";"") | sub("^.*/"; "")] | join(",")' 2>/dev/null || echo "")
    if [ "$pwshorder" = "cadence-deny-powershell.sh" ]; then
        pass "fragment wires a PowerShell matcher denying the PowerShell tool"
    else
        fail "fragment PowerShell matcher block is wrong" "$pwshorder"
    fi
else
    hookcmd="$frag_body"
fi
assert_contains "fragment command references auto-approve-safe-bash" "auto-approve-safe-bash.sh" "$hookcmd"
# Every command must invoke an ABSOLUTE, quoted interpreter — a
# bare `bash` resolves to the System32 WSL stub under raw CreateProcess order
# and cannot read a C:/... path. Assert over the whole fragment body so a new
# command added later cannot reintroduce the bare form unnoticed.
case "$frag_body" in
    *'"command": "bash '*) fail "fragment emits a bare 'bash ' interpreter token" "$frag_body" ;;
    *)                     pass "fragment emits no bare 'bash ' interpreter token" ;;
esac
case "$frag_body" in
    *[Ss]ystem32*) fail "fragment resolved the interpreter to the System32 WSL stub" "$frag_body" ;;
    *)             pass "fragment interpreter is not the System32 WSL stub" ;;
esac
# The referenced hook must be an ABSOLUTE path that actually exists on disk.
# Both the interpreter and the hook arg are quoted, so strip the leading
# quoted interpreter AND the quotes around the arg to isolate the path.
hookpath=$(printf '%s' "$hookcmd" | sed -n 's/^"[^"]*" "\(.*\)"$/\1/p')
case "$hookpath" in
    /*|?:/*) pass "fragment references the hook by absolute path" ;;
    *)       fail "fragment hook path is not absolute" "$hookpath" ;;
esac
# Resolve to a checkable path (mixed C:/ form maps back through cygpath on Win).
hookpath_check="$hookpath"
if command -v cygpath >/dev/null 2>&1; then hookpath_check=$(cygpath -u "$hookpath" 2>/dev/null || printf '%s' "$hookpath"); fi
if [ -f "$hookpath_check" ]; then
    pass "fragment hook path resolves to a real file"
else
    fail "fragment hook path does not resolve to a file" "$hookpath_check"
fi

# The fragment force-enables obsidian-triage@himmel so the nightly
# cadence stays live even when the operator disables the plugin interactively.
if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$frag_body" | jq -e '.enabledPlugins["obsidian-triage@himmel"] == true' >/dev/null 2>&1; then
        pass "fragment force-enables obsidian-triage@himmel (HIMMEL-1036)"
    else
        fail "fragment does not force-enable obsidian-triage@himmel" "$frag_body"
    fi
else
    assert_contains "fragment force-enables obsidian-triage (HIMMEL-1036)" "obsidian-triage@himmel" "$frag_body"
fi

# The 2026-10-03 harvest's Skill call came back
# toolDenialKind=user-rejected. A headless cadence session has nobody to answer
# a permission ask, so every obsidian-triage command a leg prompt names needs an
# explicit allow, plus Read of the plugin's command files as the fallback.
for _allow in \
    'Skill(obsidian-triage:harvest-clips)' 'Skill(obsidian-triage:triage-clips)' \
    'Skill(obsidian-triage:ig-media-enrich)' 'Skill(obsidian-triage:x-media-enrich)' \
    'Skill(obsidian-triage:synthesize-clips)' 'Skill(obsidian-triage:archive-clips)' \
    'Skill(obsidian-triage:vault-lint)' \
    'Read(~/.claude/plugins/cache/himmel/obsidian-triage/*/commands/*.md)'
do
    if command -v jq >/dev/null 2>&1; then
        if printf '%s' "$frag_body" | jq -e --arg a "$_allow" '.permissions.allow | index($a)' >/dev/null 2>&1; then
            pass "fragment allows $_allow (HIMMEL-4181)"
        else
            fail "fragment does not allow $_allow (HIMMEL-4181)" "$frag_body"
        fi
    else
        assert_contains "fragment allows $_allow (HIMMEL-4181)" "\"$_allow\"" "$frag_body"
    fi
done

# Test C4d: readability warnings for the two S2a/S2b cadence-scoped hooks ----
# AUTO_APPROVE_HOOK gets a `[ -r ] || echo WARN` in cron_arm, and the two hooks
# emit_settings_fragment wires beside it (cadence-deny-background.sh,
# cadence-approve-engines.sh) need the same check. A missing hook file at
# fire time makes that hook process fail to start; Claude Code treats a
# non-2 exit as NON-BLOCKING, so the cadence session runs with that hook's
# protection silently absent — exactly the permission surface these hooks
# guard.
#
# Arm derives the hooks dir from pipeline-cadence.sh's OWN
# location (HIMMEL_ROOT -> AUTO_APPROVE_HOOK's sibling dir), so the mutation
# runs against a SANDBOX COPY of the script tree (build_hook_sandbox) and the
# SANDBOX hook is hidden — never the tracked file. Moving the
# real hook and leaning on `trap cleanup EXIT` to restore it would fail, since SIGKILL / a
# host crash defeats the trap and leaves live cadence protections missing from
# the working tree. (The shell-suite runner waits for each suite — sequential,
# not concurrent — against one shared tree with no per-suite isolation, so a
# crash-mid-mutation is exposed to every later step, not just this suite.) A
# crash here can damage only the throwaway sandbox under $TMP_ROOT.
SB_CRON="$TMP_ROOT/hook-sb-cron"
SB_CRON_SCRIPT="$(build_hook_sandbox "$SB_CRON")"
SB_CRON_HOOKS="$(cd "$SB_CRON/scripts/hooks" && pwd)"   # POSIX form, as arm emits it
sb_cron() {
    env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
        PIPELINE_BAT_DIR="$CRON_DIR" bash "$SB_CRON_SCRIPT" "$@"
}

echo "TEST: cron arm warns when the deny-background hook is unreadable"
mv "$SB_CRON_HOOKS/cadence-deny-background.sh" "$SB_CRON_HOOKS/cadence-deny-background.sh.hidden"
out=$(sb_cron arm --vault "$VAULT" --force --dry-run 2>&1)
assert_contains "cron arm warns on unreadable deny-background hook" "deny-background hook not readable at $SB_CRON_HOOKS/cadence-deny-background.sh" "$out"
mv "$SB_CRON_HOOKS/cadence-deny-background.sh.hidden" "$SB_CRON_HOOKS/cadence-deny-background.sh"

echo "TEST: cron arm warns when the approve-engines hook is unreadable"
mv "$SB_CRON_HOOKS/cadence-approve-engines.sh" "$SB_CRON_HOOKS/cadence-approve-engines.sh.hidden"
out=$(sb_cron arm --vault "$VAULT" --force --dry-run 2>&1)
assert_contains "cron arm warns on unreadable approve-engines hook" "approve-engines hook not readable at $SB_CRON_HOOKS/cadence-approve-engines.sh" "$out"
mv "$SB_CRON_HOOKS/cadence-approve-engines.sh.hidden" "$SB_CRON_HOOKS/cadence-approve-engines.sh"

echo "TEST: cron arm stays silent when both cadence hooks are readable"
out=$(sb_cron arm --vault "$VAULT" --force --dry-run 2>&1)
assert_not_contains "cron arm silent on deny-background hook when present" "deny-background hook not readable" "$out"
assert_not_contains "cron arm silent on approve-engines hook when present" "approve-engines hook not readable" "$out"

# Test C5: status after arm ----------------------------------------------------

echo "TEST: cron status reflects armed entries"
out=$(run_cron status)
assert_contains "cron fetch-health armed" "ARMED      HIMMEL-Pipeline-FetchHealth" "$out"
assert_contains "cron fetch-health status is no-LLM" "clip-source fetch probes [no LLM]" "$out"
assert_contains "cron harvest armed"    "ARMED      HIMMEL-Pipeline-Harvest"    "$out"
assert_contains "cron synthesize armed" "ARMED      HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "cron health armed"     "ARMED      HIMMEL-Pipeline-Health"     "$out"
assert_contains "cron status daily row mentions ig-media-enrich" "/ig-media-enrich" "$out"
assert_contains "cron status surfaces run log state" "run log" "$out"
# Status parses the --model pin back out of each runner so an
# armed-but-wrong-model cadence is visible. Scope each pin to its OWN status
# line — harvest and synth are both [model: sonnet], so a whole-output check
# would pass even if one leg's pin were wrong or missing.
harvest_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Harvest')
synth_line=$(printf '%s\n' "$out"   | grep 'HIMMEL-Pipeline-Synthesize')
health_line=$(printf '%s\n' "$out"  | grep 'HIMMEL-Pipeline-Health')
assert_contains "cron harvest status line armed"      "ARMED"           "$harvest_line"
assert_contains "cron harvest status shows model pin" "[model: claude-sonnet-5-5]" "$harvest_line"
assert_contains "cron synth status shows model pin"   "[model: claude-sonnet-5-5]" "$synth_line"
assert_contains "cron health status shows model pin"  "[model: haiku]"  "$health_line"

# Test C5b: status_log rotated-log message (#299) ------------------------------
# When .log is absent but .log.prev is present (post-rotation window before
# a fresh fire creates the new .log), the message must reflect rotation —
# NOT "absent — task has not fired yet" which is actively misleading.

echo "TEST: status_log shows 'rotated' when .log absent but .log.prev present"
printf 'prev run output\n' > "$CRON_DIR/pipeline-synthesize.log.prev"
rm -f "$CRON_DIR/pipeline-synthesize.log"
out=$(run_cron status)
assert_contains "cron rotated-log message says rotated" "rotated" "$out"
# The synth log line must say "rotated", not "absent — task has not fired yet".
# (The health log legitimately says "absent" since neither .log nor .log.prev
# exist for it — we only check the synth log line here.)
if grepq "$(printf '%s\n' "$out" | grep -F "pipeline-synthesize.log ")" -F "absent — task has not fired yet"; then
    fail "cron synth rotated-log must not say 'absent'" "$(printf '%s\n' "$out" | grep -F 'pipeline-synthesize.log ')"
else
    pass "cron synth rotated-log does not say 'absent'"
fi
rm -f "$CRON_DIR/pipeline-synthesize.log.prev"

# Test C5c: a deleted runner file surfaces as [runner missing], NOT plain
# ARMED. A scheduler entry whose generated runner file is
# gone fires-and-fails every time — status must distinguish that from the
# intentional pre-pin case (which exists on disk and is silent).
# model_suffix is shared by the cron + schtasks status paths, so this covers
# the fix on EVERY platform (the schtasks 9d mirror is Windows-only).

echo "TEST: cron armed task with runner file deleted shows [runner missing]"
cp "$CRON_DIR/pipeline-synthesize.sh" "$CRON_DIR/pipeline-synthesize.sh.bak"
rm -f "$CRON_DIR/pipeline-synthesize.sh"
rc=0; out=$(run_cron status) || rc=$?
assert_rc "cron runner-missing status does not error" 0 "$rc"
synth_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Synthesize')
assert_contains "cron synth runner-missing shows [runner missing]" "[runner missing]" "$synth_line"
assert_not_contains "cron synth runner-missing has no [model:] suffix" "[model:" "$synth_line"
# Other legs untouched — harvest still shows its pin, proving the pinned /
# runner-missing states are distinguished in one status output.
harvest_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Harvest')
assert_contains "cron harvest still pinned while synth runner missing" "[model: claude-sonnet-5-5]" "$harvest_line"
mv "$CRON_DIR/pipeline-synthesize.sh.bak" "$CRON_DIR/pipeline-synthesize.sh"

# Test C6: re-arm without --force -> dedup block -------------------------------

echo "TEST: cron re-arm without --force blocked (rc 3)"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron dedup block rc 3" 3 "$rc"
assert_contains "cron dedup message names existing entries" "HIMMEL-Pipeline-Synthesize" "$out"
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 4 ]; then
    pass "no duplicate entries after blocked re-arm"
else
    fail "entry count changed on blocked re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C7: re-arm --force with overrides ----------------------------------------

echo "TEST: cron re-arm --force applies flag overrides"
out=$(run_cron arm --vault "$VAULT" --force \
    --fetch-health-time 00:45 --harvest-time 01:15 --ig-limit 25 --synth-time 02:30 --health-time 05:00 --harvest-model opus 2>&1)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
harvest_sh=$(cat "$CRON_DIR/pipeline-harvest.sh" 2>/dev/null || echo MISSING)
assert_contains "cron daily fetch-health override"             "45 00 * * *" "$tab"
assert_contains "cron daily harvest override"                  "15 01 * * *" "$tab"
# %q-escaped prompt: strip backslashes for the multi-word assert.
assert_contains "cron --ig-limit override reaches harvest runner" "/ig-media-enrich --limit 25" "${harvest_sh//\\/}"
assert_contains "cron --harvest-model override reaches runner (HIMMEL-506)" "--model opus" "${harvest_sh//\\/}"
assert_contains "cron daily synth override (time only, daily)" "30 02 * * *" "$tab"
assert_contains "cron health override (time only, still weekly)" "00 05 * * 0" "$tab"
assert_contains "unrelated entry survives --force re-arm" "keep-me" "$tab"
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 4 ]; then
    pass "still exactly four entries after --force re-arm"
else
    fail "duplicate entries after --force re-arm" "$(cat "$CSTATE/crontab")"
fi

out=$(run_cron arm --vault "$VAULT" --force --ig-limit 0 --harvest-model opus 2>&1)
harvest_sh=$(cat "$CRON_DIR/pipeline-harvest.sh" 2>/dev/null || echo MISSING)
assert_contains "cron --ig-limit 0 reaches harvest runner" "/ig-media-enrich --limit 0" "${harvest_sh//\\/}"

# Test C14: dry-run disarm with armed entries prints DRY tail, touches nothing --

echo "TEST: cron dry-run disarm prints DRY tail, touches nothing"
out=$(run_cron disarm --dry-run)
assert_contains "cron dry disarm lists removals" "would remove crontab entry" "$out"
assert_contains "cron dry disarm closing summary" "no changes made" "$out"
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 4 ]; then
    pass "dry-run disarm removed no entries"
else
    fail "dry-run disarm changed crontab state" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/pipeline-fetch-health.sh" ] && [ -f "$CRON_DIR/pipeline-harvest.sh" ] && [ -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "dry-run disarm kept the runner .sh files"
else
    fail "dry-run disarm deleted runner .sh files"
fi

# Test C8: disarm + idempotent second disarm ------------------------------------

echo "TEST: cron disarm removes entries + runners, keeps unrelated lines"
out=$(run_cron disarm)
assert_contains "cron disarm reports" "cadence disarmed" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_not_contains "cadence entries removed" "HIMMEL-Pipeline-" "$tab"
assert_contains "unrelated entry survives disarm" "keep-me" "$tab"
if [ ! -f "$CRON_DIR/pipeline-fetch-health.sh" ] && [ ! -f "$CRON_DIR/pipeline-harvest.sh" ] && [ ! -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ ! -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files removed"
else
    fail "runner .sh files left after disarm"
fi
if [ ! -f "$CRON_DIR/cadence-settings.json" ]; then
    pass "settings fragment removed on disarm (HIMMEL-575)"
else
    fail "settings fragment left after disarm"
fi
rc=0; out=$(run_cron disarm) || rc=$?
assert_rc "cron second disarm rc 0" 0 "$rc"
assert_contains "cron second disarm is a no-op" "no-op" "$out"

# Test C9: failing crontab -l is fail-CLOSED -------------------------------------

echo "TEST: cron arm/status/disarm with failing crontab -l exit 2"
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron fail-closed arm rc 2" 2 "$rc"
assert_contains "cron arm failure surfaces stderr" "must be privileged" "$out"
assert_contains "fail-closed message carries the empty-crontab remediation hint" "crontab - </dev/null" "$out"
rc=0; out=$(run_cron status 2>&1) || rc=$?
assert_rc "cron fail-closed status rc 2" 2 "$rc"
rm -f "$CSTATE/fail-list"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron fail-closed disarm rc 2" 2 "$rc"
assert_not_contains "no false no-op on failing crontab -l" "no-op" "$out"
if [ -f "$CRON_DIR/pipeline-fetch-health.sh" ] && [ -f "$CRON_DIR/pipeline-harvest.sh" ] && [ -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files NOT deleted on crontab -l failure"
else
    fail "runner .sh files deleted despite crontab -l failure"
fi
rm -f "$CSTATE/fail-list"
run_cron disarm >/dev/null

# Test C9b: crashed crontab -l (rc=255, EMPTY stderr) is NOT trusted-empty -------

echo "TEST: cron disarm with crashed crontab -l (rc=255, empty stderr) exits 2"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-list-255"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron crashed-list disarm rc 2" 2 "$rc"
assert_not_contains "no false no-op on crashed crontab -l" "no-op" "$out"
if [ -f "$CRON_DIR/pipeline-fetch-health.sh" ] && [ -f "$CRON_DIR/pipeline-harvest.sh" ] && [ -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files NOT deleted on crashed crontab -l"
else
    fail "runner .sh files deleted despite crashed crontab -l"
fi
rm -f "$CSTATE/fail-list-255"
run_cron disarm >/dev/null

# Test C10: crontab install failure -> rc 4 ---------------------------------------

echo "TEST: cron arm with failing crontab install exits 4"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron install failure rc 4" 4 "$rc"
assert_contains "cron install failure surfaces stderr" "error writing new crontab" "$out"
if ! grep -q 'HIMMEL-Pipeline-' "$CSTATE/crontab" 2>/dev/null; then
    pass "no cadence entries installed on write failure"
else
    fail "cadence entries installed despite write failure" "$(cat "$CSTATE/crontab")"
fi
if [ ! -f "$CRON_DIR/pipeline-fetch-health.sh" ] && [ ! -f "$CRON_DIR/pipeline-harvest.sh" ] && [ ! -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ ! -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "no runner promoted to its final path on write failure"
else
    fail "runner files left despite write failure" "$(ls "$CRON_DIR" 2>/dev/null || true)"
fi
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter on write failure"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
# The settings fragment is staged + promoted on the SAME gate, so a
# failed fresh arm must leave NO orphan cadence-settings.json (and no .tmp).
if [ ! -f "$CRON_DIR/cadence-settings.json" ]; then
    pass "no orphan settings fragment on write failure"
else
    fail "settings fragment orphaned on failed arm" "$(ls "$CRON_DIR")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C10b: --force re-arm with failing install leaves NO half-state ------------
# Pins the stage-then-promote fix: cron_arm must NOT overwrite the live
# runners before cron_install succeeds — otherwise a failed install
# leaves the OLD crontab live pointing at NEW-config runners, silently.

echo "TEST: cron --force re-arm with failing install keeps old runners + entries"
out=$(run_cron arm --vault "$VAULT")
VAULT2="$TMP_ROOT/vault2"
mkdir -p "$VAULT2"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --vault "$VAULT2" --force 2>&1) || rc=$?
assert_rc "cron force re-arm install failure rc 4" 4 "$rc"
synth_sh=$(cat "$CRON_DIR/pipeline-synthesize.sh" 2>/dev/null || echo MISSING)
assert_contains "old runner still points at the old vault" "cd $VAULT || {" "$synth_sh"
assert_not_contains "no new-config runner promoted" "vault2" "$synth_sh"
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter after failed --force re-arm"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 4 ]; then
    pass "old entries still armed after failed --force re-arm"
else
    fail "entry count changed on failed --force re-arm" "$(cat "$CSTATE/crontab")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C10c: disarm with failing install keeps entries + runners -----------------
# Pins the ordering invariant: cron_install must succeed (exit 4
# otherwise) BEFORE the `rm -f` of the runner files — the entries stay
# live in the old crontab and must keep pointing at existing runners.

echo "TEST: cron disarm with failing crontab install exits 4, keeps entries + runners"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron disarm install failure rc 4" 4 "$rc"
assert_contains "disarm install failure surfaces stderr" "error writing new crontab" "$out"
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 4 ]; then
    pass "entries still in crontab after failed disarm install"
else
    fail "entries lost despite failed disarm install" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/pipeline-fetch-health.sh" ] && [ -f "$CRON_DIR/pipeline-harvest.sh" ] && [ -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ -f "$CRON_DIR/pipeline-health.sh" ]; then
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
out=$(env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$EVIL_DIR" bash "$SCRIPT" arm --vault "$EVIL_VAULT")
synth_sh=$(cat "$EVIL_DIR/pipeline-synthesize.sh" 2>/dev/null || echo MISSING)
assert_contains "ampersand %q-escaped in runner" 'va\&ult' "$synth_sh"
# shellcheck disable=SC2016  # literal \$X needle — asserting the %q escape itself
assert_contains "dollar %q-escaped in runner" '\$X' "$synth_sh"
assert_not_contains "raw &ult survives unescaped" 'va&ult ' "$synth_sh"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "percent cron-escaped in entry (\\%)" 'cr\%on' "$tab"
assert_contains "space %q-escaped in entry" 'cr\%on\ rnr' "$tab"
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$EVIL_DIR" bash "$SCRIPT" disarm >/dev/null

# Test C11b: cron_escape rejects control characters (#311) ----------------------
# bash's printf %q emits ANSI-C $'...' quoting for control chars, which
# dash/sh can't parse at cron fire time. Arm with a BAT_DIR containing a
# tab char — cron_escape must reject it with rc=2.

echo "TEST: arm with control char in runner dir is rejected (rc 2)"
CTRL_DIR="$TMP_ROOT/cron-ctrl-$(printf 'a\tb')"
mkdir -p "$CTRL_DIR"
rc=0; out=$(env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$CTRL_DIR" bash "$SCRIPT" arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron_escape rejects control char in runner path (rc 2)" 2 "$rc"
assert_contains "cron_escape error mentions control characters" "control characters" "$out"

# Test C15: the emitted runner .sh actually EXECUTES ------------------------------
# Everything above asserts runner TEXT; this arms with a recording
# `claude` stub first on PATH (so its absolute path gets baked into the
# runner) and fires the runner with plain `sh`, locking the fire-time
# behaviour: log creation + [fired] stamp, the whole prompt as ONE argv,
# cwd resolved to the vault, .log -> .log.prev rotation on the second
# fire. Hostile dirnames (& $ space) lock the %q escaping guarantee
# through a real /bin/sh re-parse, not just through grep.

echo "TEST: armed runner .sh executes end-to-end (recording claude stub)"
FIRE_VAULT="$TMP_ROOT/fire va&ult \$Z dir"
FIRE_DIR="$TMP_ROOT/fire rnr"
mkdir -p "$FIRE_VAULT"
# The synthesize runner asks synth-input-check.sh whether anything
# has been triaged since the last completed leg, and an EMPTY vault correctly
# answers NONE — it would skip before reaching the claude stub these fire tests
# exist to record. One triaged clip is the fixture that keeps the gate open.
seed_triaged_clip() {
    mkdir -p "$1/Clippings"
    printf -- '---
triaged_at: 2026-08-23
processed: true
---
fixture
' > "$1/Clippings/fixture.md"
    # Dated far forward on purpose. The runner STAMPS the vault after a leg
    # that completes, and these blocks fire the same runner several times to
    # exercise retry/parked/classifier paths — a normally-dated fixture would
    # fall behind the first fire's stamp and every later fire would correctly
    # skip, testing nothing. A clip that is always newer than the stamp keeps
    # the gate open for the whole block without weakening the gate itself.
    #
    # POSIX `-t [[CC]YY]MMDDhhmm`, not GNU `-d`: BSD/macOS touch accepts only a
    # full ISO-8601 string for -d, so `-d 2099-01-01` fails there. And the
    # failure is FATAL here, never swallowed: a silently un-dated fixture makes
    # every later fire skip the claude stub, which turns this whole block into
    # a confusing cascade of missing-output failures instead of one clear line.
    touch -t 209901010000 "$1/Clippings/fixture.md" || {
        fail "seed_triaged_clip: touch -t failed for $1/Clippings/fixture.md — the fire tests need a fixture newer than the runner's completion stamp"
        return 1
    }
}
seed_triaged_clip "$FIRE_VAULT"
REC="$TMP_ROOT/claude-record"
mkdir -p "$TMP_ROOT/bin-rec"
cat >"$TMP_ROOT/bin-rec/claude" <<STUB
#!/usr/bin/env bash
REC="$REC"
STUB
cat >>"$TMP_ROOT/bin-rec/claude" <<'STUB'
{
    echo "argc=$#"
    for a in "$@"; do printf 'arg=%s\n' "$a"; done
    printf 'cwd=%s\n' "$(pwd)"
} > "$REC"
echo "claude-stub-ran"
# A completed leg ends with the bare marker; the blocked-leg
# twin below omits it and must surface as exit 3.
echo "PIPELINE-LEG-DONE"
STUB
chmod +x "$TMP_ROOT/bin-rec/claude"
# A python3 stub for the no-LLM FetchHealth leg: arm resolves
# `python3` first, so this is what gets baked into that runner — the fire below
# can then never reach the real fetch-health.py, which makes live network
# probes. Same fail-fast guard as the claude stub before it is executed.
cat >"$TMP_ROOT/bin-rec/python3" <<'STUB'
#!/usr/bin/env bash
echo "fetch-health-stub-ran"
exit "${FETCH_HEALTH_STUB_RC:-0}"
STUB
chmod +x "$TMP_ROOT/bin-rec/python3"
# PATH entries must be POSIX-form: TMP_ROOT is cygpath -m'd (C:/...) on
# Windows, and the drive colon would split the PATH entry — the stub dir
# would silently never resolve and arm would bake the REAL claude binary
# into the runner (live-hang observed: executing it launched a real
# interactive claude session).
BIN_REC_POSIX="$TMP_ROOT/bin-rec"
if command -v cygpath >/dev/null 2>&1; then BIN_REC_POSIX=$(cygpath -u "$BIN_REC_POSIX"); fi
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$FIRE_DIR" PATH="$BIN_REC_POSIX:$PATH" \
    bash "$SCRIPT" arm --vault "$FIRE_VAULT" >/dev/null
# Fail-fast guard: NEVER execute the runner if it baked anything but the
# stub — a wrong resolution here means running the real claude binary.
if ! grep -q "bin-rec" "$FIRE_DIR/pipeline-synthesize.sh"; then
    fail "runner must reference the claude STUB (refusing to execute real claude)" \
        "baked: $(grep -m1 'claude' "$FIRE_DIR/pipeline-synthesize.sh")"
    rc=99
else
    rc=0; sh "$FIRE_DIR/pipeline-synthesize.sh" || rc=$?
fi
assert_rc "runner fires cleanly under plain sh" 0 "$rc"
log=$(cat "$FIRE_DIR/pipeline-synthesize.log" 2>/dev/null || echo MISSING)
assert_contains "fire log captures claude output" "claude-stub-ran" "$log"
assert_contains "fire log carries the [fired stamp" "[fired" "$log"
# The same runner with a claude that exits 0 WITHOUT the bare
# PIPELINE-LEG-DONE line (blocked on a prompt, parked, bailed) must exit 3 --
# a parked leg may never read as a clean pass to the scheduler.
cat >"$TMP_ROOT/bin-rec/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub-ran"
echo "**Cadence leg blocked:** needs permission approval"
STUB
chmod +x "$TMP_ROOT/bin-rec/claude"
if grep -q "bin-rec" "$FIRE_DIR/pipeline-synthesize.sh"; then
    rc=0; sh "$FIRE_DIR/pipeline-synthesize.sh" || rc=$?
    assert_rc "runner raises a parked leg (rc 0, no marker) to exit 3" 3 "$rc"
    log=$(cat "$FIRE_DIR/pipeline-synthesize.log" 2>/dev/null || echo MISSING)
    assert_contains "parked fire log still captures claude output" "claude-stub-ran" "$log"
fi
# With the classifier itself UNAVAILABLE
# (ledger lib path broken), a zero-rc run has no proof of completion -> the
# runner must fail closed (exit 3), never default to complete. Same runner,
# completing stub restored, ledger lib path redirected to a missing file.
cat >"$TMP_ROOT/bin-rec/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub-ran"
echo "PIPELINE-LEG-DONE"
STUB
chmod +x "$TMP_ROOT/bin-rec/claude"
if grep -q "bin-rec" "$FIRE_DIR/pipeline-synthesize.sh"; then
    sed 's#flow-run-ledger\.sh#flow-run-ledger-MISSING.sh#g' "$FIRE_DIR/pipeline-synthesize.sh" > "$FIRE_DIR/pipeline-synthesize-noclassify.sh"
    rc=0; sh "$FIRE_DIR/pipeline-synthesize-noclassify.sh" || rc=$?
    assert_rc "runner with an unavailable classifier fails closed (exit 3, not complete)" 3 "$rc"
fi
recdata=$(cat "$REC" 2>/dev/null || echo MISSING)
# The runner injects `--model <pin>` then `--settings
# <fragment>` before the prompt, so claude sees five argv: --model, the
# pinned model, --settings, the fragment path, the prompt.
assert_contains "claude invoked with --model + --permission-mode + --settings injection" "argc=7" "$recdata"
assert_contains "model flag passed to claude" "arg=--model" "$recdata"
assert_contains "model value (claude-sonnet-5-5) passed to claude" "arg=claude-sonnet-5-5" "$recdata"
assert_contains "settings flag passed to claude" "arg=--settings" "$recdata"
assert_contains "settings fragment path passed to claude" "cadence-settings.json" "$recdata"
assert_contains "chained prompt intact as a SINGLE argv" \
    "arg=Run /synthesize-clips to completion, then run /archive-clips." "$recdata"
expected_cwd=$(cd "$FIRE_VAULT" && pwd)
assert_contains "runner cd'd into the (hostile) vault" "cwd=$expected_cwd" "$recdata"
echo "RUN1-SENTINEL" >> "$FIRE_DIR/pipeline-synthesize.log"
sh "$FIRE_DIR/pipeline-synthesize.sh"
prev=$(cat "$FIRE_DIR/pipeline-synthesize.log.prev" 2>/dev/null || echo MISSING)
cur=$(cat "$FIRE_DIR/pipeline-synthesize.log" 2>/dev/null || echo MISSING)
assert_contains "second fire rotated first log to .log.prev" "RUN1-SENTINEL" "$prev"
assert_not_contains "fresh log after rotation" "RUN1-SENTINEL" "$cur"
assert_contains "fresh log captured the second fire" "claude-stub-ran" "$cur"
# Test C15c: the FetchHealth leg actually LANDS ledger rows -------
# The text assertions above prove the runner CONTAINS the append calls; this
# fires it and reads the ledger, which is the only thing that proves the leg is
# now visible to stall / never-started detection (a leg that writes no row is
# indistinguishable from one that was never armed — the bug this fixes).
echo "TEST: armed fetch-health runner writes flow-run ledger start+end rows (HIMMEL-1724)"
: > "$HIMMEL_FLOW_RUNS_LEDGER"
if ! grep -q "bin-rec" "$FIRE_DIR/pipeline-fetch-health.sh"; then
    fail "fetch-health runner must reference the python STUB (refusing to run the real probe)" \
        "baked: $(grep -m1 'python' "$FIRE_DIR/pipeline-fetch-health.sh")"
else
    rc=0; sh "$FIRE_DIR/pipeline-fetch-health.sh" || rc=$?
    assert_rc "fetch-health runner fires cleanly under plain sh" 0 "$rc"
    fh_ledger=$(cat "$HIMMEL_FLOW_RUNS_LEDGER" 2>/dev/null || echo MISSING)
    assert_contains "fire wrote a fetch-health START row" '"ev":"start","flow":"pipeline-fetch-health"' "$fh_ledger"
    assert_contains "fire wrote a fetch-health END row" '"ev":"end","flow":"pipeline-fetch-health"' "$fh_ledger"
    assert_contains "fetch-health start row carries the leg's task name" '"task_name":"HIMMEL-Pipeline-FetchHealth"' "$fh_ledger"
    assert_contains "a clean probe run closes as outcome=complete" '"outcome":"complete"' "$fh_ledger"
    # The other branch of the rc->outcome mapping: a failing probe must close
    # the row as `error`, never complete (a row that always says complete is
    # the same blindness in a new place).
    : > "$HIMMEL_FLOW_RUNS_LEDGER"
    rc=0; FETCH_HEALTH_STUB_RC=3 sh "$FIRE_DIR/pipeline-fetch-health.sh" || rc=$?
    assert_rc "fetch-health runner propagates the probe's non-zero rc" 3 "$rc"
    fh_ledger=$(cat "$HIMMEL_FLOW_RUNS_LEDGER" 2>/dev/null || echo MISSING)
    assert_contains "a failing probe run closes as outcome=error" '"outcome":"error"' "$fh_ledger"
    assert_contains "the failing end row carries the true exit code" '"exit_code":3' "$fh_ledger"
fi

# Test C15e: a failed leg is never silent ----------------------
# Each pipeline family, forced to fail through stubs, must land exactly one
# `<iso-ts> <leg> <reason> <log>` line in the alert file and exactly one send
# through the recorder; a repeat of the same failure appends again but does not
# re-send; a completed leg clears the dedupe so the next failure sends again.
echo "TEST: failed cadence legs alert once, through seams (HIMMEL-4181)"
reset_alerts() { rm -rf "$CADENCE_ALERT_DEDUPE_DIR"; : > "$CADENCE_ALERT_FILE"; : > "$ALERT_SENDS"; }
count_lines() { grep -c . "$1" 2>/dev/null || true; }
cat >"$TMP_ROOT/bin-rec/claude-parked" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub-ran"
echo "Skill obsidian-triage:harvest-clips errored, nothing harvested"
STUB
cat >"$TMP_ROOT/bin-rec/claude-ok" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub-ran"
echo "PIPELINE-LEG-DONE"
STUB
cat >"$TMP_ROOT/bin-rec/claude-rc5" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub-ran"
exit 5
STUB
chmod +x "$TMP_ROOT/bin-rec/claude-parked" "$TMP_ROOT/bin-rec/claude-ok" "$TMP_ROOT/bin-rec/claude-rc5"
use_claude() { cp "$TMP_ROOT/bin-rec/claude-$1" "$TMP_ROOT/bin-rec/claude"; }
for _leg in harvest synthesize health; do
    _runner="$FIRE_DIR/pipeline-$_leg.sh"
    grep -q "bin-rec" "$_runner" || { fail "$_leg runner must reference the claude STUB"; continue; }
    reset_alerts
    use_claude parked
    rc=0; sh "$_runner" || rc=$?
    assert_rc "$_leg: a zero-rc leg without the marker exits non-zero" 3 "$rc"
    assert_contains "$_leg: log names the no-op" "[PIPELINE-LEG-FAILED no-completion-marker]" "$(cat "$FIRE_DIR/pipeline-$_leg.log")"
    assert_rc "$_leg: exactly one alert line" 1 "$(count_lines "$CADENCE_ALERT_FILE")"
    assert_contains "$_leg: alert line is <ts> <leg> <reason> <log>" "pipeline-$_leg no-completion-marker $FIRE_DIR/pipeline-$_leg.log" "$(cat "$CADENCE_ALERT_FILE")"
    if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' "$CADENCE_ALERT_FILE"; then
        pass "$_leg: alert line starts with a UTC ISO timestamp"
    else
        fail "$_leg: alert line has no ISO timestamp" "$(cat "$CADENCE_ALERT_FILE")"
    fi
    assert_rc "$_leg: exactly one Telegram send" 1 "$(count_lines "$ALERT_SENDS")"
    assert_contains "$_leg: the send names leg and reason" "pipeline-$_leg: no-completion-marker." "$(cat "$ALERT_SENDS")"
done
# Dedupe and clear, on the harvest runner.
reset_alerts
use_claude parked
sh "$FIRE_DIR/pipeline-harvest.sh" || true
sh "$FIRE_DIR/pipeline-harvest.sh" || true
assert_rc "repeat failure appends a second alert line" 2 "$(count_lines "$CADENCE_ALERT_FILE")"
assert_rc "repeat failure does not re-send" 1 "$(count_lines "$ALERT_SENDS")"
use_claude ok
rc=0; sh "$FIRE_DIR/pipeline-harvest.sh" || rc=$?
assert_rc "a completed leg exits 0" 0 "$rc"
assert_rc "a completed leg appends no alert" 2 "$(count_lines "$CADENCE_ALERT_FILE")"
assert_not_contains "a completed leg logs no FAILED line" "PIPELINE-LEG-FAILED" "$(cat "$FIRE_DIR/pipeline-harvest.log")"
use_claude parked
sh "$FIRE_DIR/pipeline-harvest.sh" || true
assert_rc "after a completed leg the next failure sends again" 2 "$(count_lines "$ALERT_SENDS")"
# A non-zero rc (no transient signature, so no retry).
reset_alerts
use_claude rc5
rc=0; sh "$FIRE_DIR/pipeline-harvest.sh" || rc=$?
assert_rc "a non-zero leg keeps its rc" 5 "$rc"
assert_contains "non-zero rc is logged as FAILED" "[PIPELINE-LEG-FAILED rc=5]" "$(cat "$FIRE_DIR/pipeline-harvest.log")"
assert_contains "non-zero rc alerts with reason rc-5" "pipeline-harvest rc-5 " "$(cat "$CADENCE_ALERT_FILE")"
assert_rc "non-zero rc sends once" 1 "$(count_lines "$ALERT_SENDS")"
# The truncated outcome: rc 0 plus the background-task truncation
# signature classifies `truncated`, which is neither complete nor an rc failure.
cat >"$TMP_ROOT/bin-rec/claude-truncated" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub-ran"
echo "Background tasks still running, terminating"
STUB
chmod +x "$TMP_ROOT/bin-rec/claude-truncated"
reset_alerts
use_claude truncated
rc=0; sh "$FIRE_DIR/pipeline-harvest.sh" || rc=$?
assert_rc "a truncated leg (rc 0) exits 3" 3 "$rc"
assert_contains "a truncated leg is logged as FAILED" "[PIPELINE-LEG-FAILED no-completion-marker]" "$(cat "$FIRE_DIR/pipeline-harvest.log")"
assert_contains "a truncated leg alerts with reason no-completion-marker" "pipeline-harvest no-completion-marker " "$(cat "$CADENCE_ALERT_FILE")"
assert_rc "a truncated leg sends once" 1 "$(count_lines "$ALERT_SENDS")"
# A runner that dies at its cd into the vault alerts too, not only one that
# reaches the claude launch.
sed "s#^    cd [^ ]* #    cd $TMP_ROOT/no-such-vault #" "$FIRE_DIR/pipeline-harvest.sh" > "$FIRE_DIR/pipeline-harvest-novault.sh"
reset_alerts
use_claude ok
rc=0; sh "$FIRE_DIR/pipeline-harvest-novault.sh" || rc=$?
assert_rc "a runner that cannot cd into the vault exits 1" 1 "$rc"
assert_contains "a vault cd failure is logged as FAILED" "[PIPELINE-LEG-FAILED cd-vault]" "$(cat "$FIRE_DIR/pipeline-harvest.log")"
assert_contains "a vault cd failure alerts with reason cd-vault" "pipeline-harvest cd-vault " "$(cat "$CADENCE_ALERT_FILE")"
assert_rc "a vault cd failure sends once" 1 "$(count_lines "$ALERT_SENDS")"
# A bank skip alerts only on the SECOND night running: the runner rotates the
# previous night's log to .log.prev, and that is where the first skip lives.
printf '#!/bin/sh\necho SKIPPED-BANK\n' > "$TMP_ROOT/bank-skip-stub.sh"
chmod +x "$TMP_ROOT/bank-skip-stub.sh"
sed "s#[^ ]*bank-preflight\\.sh#$TMP_ROOT/bank-skip-stub.sh#" "$FIRE_DIR/pipeline-harvest.sh" > "$FIRE_DIR/pipeline-harvest-bankskip.sh"
reset_alerts
use_claude ok
sh "$FIRE_DIR/pipeline-harvest.sh" || true
rc=0; sh "$FIRE_DIR/pipeline-harvest-bankskip.sh" || rc=$?
assert_rc "a bank skip still exits 0" 0 "$rc"
assert_rc "one bank skip does not alert" 0 "$(count_lines "$CADENCE_ALERT_FILE")"
sh "$FIRE_DIR/pipeline-harvest-bankskip.sh" || true
assert_rc "two bank skips running alert once" 1 "$(count_lines "$CADENCE_ALERT_FILE")"
assert_contains "the bank alert names its reason" "pipeline-harvest bank-skip-2-nights " "$(cat "$CADENCE_ALERT_FILE")"
assert_rc "two bank skips running send once" 1 "$(count_lines "$ALERT_SENDS")"
# The fetch-health probe going bad.
reset_alerts
rc=0; FETCH_HEALTH_STUB_RC=3 sh "$FIRE_DIR/pipeline-fetch-health.sh" || rc=$?
assert_rc "fetch-health still propagates its rc" 3 "$rc"
assert_rc "fetch-health failure: one alert line" 1 "$(count_lines "$CADENCE_ALERT_FILE")"
assert_contains "fetch-health alert reason is probe-bad" "pipeline-fetch-health probe-bad $FIRE_DIR/pipeline-fetch-health.log" "$(cat "$CADENCE_ALERT_FILE")"
assert_rc "fetch-health failure: one send" 1 "$(count_lines "$ALERT_SENDS")"
sh "$FIRE_DIR/pipeline-fetch-health.sh" || true
FETCH_HEALTH_STUB_RC=3 sh "$FIRE_DIR/pipeline-fetch-health.sh" || true
assert_rc "a clean probe clears the dedupe, so the next bad probe sends" 2 "$(count_lines "$ALERT_SENDS")"
use_claude ok

# Harvest and synthesize refresh the day note's timeline after the
# leg, must-not-abort. `node` is stubbed AFTER arm (the runner's PATH snapshot
# already carries bin-rec), so no fire here touches a real vault note.
echo "TEST: runners run daily-timeline.mjs, must-not-abort (HIMMEL-4182)"
REAL_NODE=$(command -v node || true)
TL_REC="$TMP_ROOT/timeline-record"
cat >"$TMP_ROOT/bin-rec/node" <<STUB
#!/bin/sh
case "\$1" in
    *daily-timeline.mjs) printf '%s\\n' "\$*" >> "$TL_REC"; echo "timeline-stub-ran"; exit "\${TIMELINE_STUB_RC:-0}" ;;
esac
exec "$REAL_NODE" "\$@"
STUB
chmod +x "$TMP_ROOT/bin-rec/node"
for _leg in harvest synthesize; do
    _runner="$FIRE_DIR/pipeline-$_leg.sh"
    assert_contains "$_leg runner calls the daily timeline" "obsidian-triage/tools/daily-timeline.mjs" "$(cat "$_runner")"
    reset_alerts; : > "$TL_REC"; use_claude ok
    rc=0; sh "$_runner" || rc=$?
    assert_rc "$_leg: a completed leg with a good timeline exits 0" 0 "$rc"
    assert_contains "$_leg: timeline gets --vault and today's --date" "--vault $FIRE_VAULT --date $(date +%Y-%m-%d)" "$(cat "$TL_REC")"
    # A failing timeline changes nothing about rc, outcome or alerts.
    reset_alerts; : > "$TL_REC"
    rc=0; TIMELINE_STUB_RC=1 sh "$_runner" || rc=$?
    assert_rc "$_leg: a failing timeline leaves rc 0" 0 "$rc"
    assert_contains "$_leg: the failure is logged" "[daily-timeline failed rc=1 - continuing]" "$(cat "$FIRE_DIR/pipeline-$_leg.log")"
    assert_not_contains "$_leg: a failing timeline is not a LEG-FAILED" "PIPELINE-LEG-FAILED" "$(cat "$FIRE_DIR/pipeline-$_leg.log")"
    assert_rc "$_leg: a failing timeline raises no alert" 0 "$(count_lines "$CADENCE_ALERT_FILE")"
    use_claude parked
    rc=0; TIMELINE_STUB_RC=1 sh "$_runner" || rc=$?
    assert_rc "$_leg: a parked leg still exits 3 beside a failing timeline" 3 "$rc"
    assert_contains "$_leg: a parked leg still logs LEG-FAILED" "[PIPELINE-LEG-FAILED no-completion-marker]" "$(cat "$FIRE_DIR/pipeline-$_leg.log")"
    use_claude rc5
    rc=0; TIMELINE_STUB_RC=1 sh "$_runner" || rc=$?
    assert_rc "$_leg: a failed leg keeps its own rc beside a failing timeline" 5 "$rc"
done
: > "$TL_REC"; use_claude ok
sh "$FIRE_DIR/pipeline-health.sh" || true
assert_rc "the health runner never runs the timeline" 0 "$(count_lines "$TL_REC")"
assert_not_contains "health runner has no timeline call" "daily-timeline.mjs" "$(cat "$FIRE_DIR/pipeline-health.sh")"
rm -f "$TMP_ROOT/bin-rec/node"
use_claude ok

# The helper itself: an unwritable dedupe dir must not swallow the send, and
# the dedupe sentinel is written only after a delivered send, so a send that
# fails or is interrupted leaves nothing behind to suppress the next alert.
reset_alerts
: > "$TMP_ROOT/not-a-dir"
CADENCE_ALERT_DEDUPE_DIR="$TMP_ROOT/not-a-dir/sent" bash "$SCRIPT_DIR/cadence-alert.sh" fail pipeline-harvest rc-1 /x.log
assert_rc "unwritable dedupe dir still sends" 1 "$(count_lines "$ALERT_SENDS")"
reset_alerts
printf '#!/bin/sh\nls "%s" | wc -l | tr -d " " >> "%s"\n' "$CADENCE_ALERT_DEDUPE_DIR" "$ALERT_SENDS" > "$TMP_ROOT/alert-send-peek"
chmod +x "$TMP_ROOT/alert-send-peek"
CADENCE_ALERT_SEND_CMD="$TMP_ROOT/alert-send-peek" bash "$SCRIPT_DIR/cadence-alert.sh" fail pipeline-harvest rc-1 /x.log
assert_rc "no dedupe sentinel exists while the send is in flight" 0 "$(cat "$ALERT_SENDS")"
reset_alerts
CADENCE_ALERT_SEND_CMD=false bash "$SCRIPT_DIR/cadence-alert.sh" fail pipeline-harvest rc-1 /x.log
bash "$SCRIPT_DIR/cadence-alert.sh" fail pipeline-harvest rc-1 /x.log
assert_rc "a failed send leaves no sentinel, so the next failure retries" 1 "$(count_lines "$ALERT_SENDS")"
# a failed send leaves a marker the doctor turns into a WARN; a delivered send clears it.
reset_alerts
rm -f "$CADENCE_ALERT_SEND_FAILED_MARK"
CADENCE_ALERT_SEND_CMD=false bash "$SCRIPT_DIR/cadence-alert.sh" fail pipeline-harvest rc-1 /x.log 2>/dev/null
assert_contains "a failed send writes the doctor marker naming leg and reason" "pipeline-harvest rc-1" "$(cat "$CADENCE_ALERT_SEND_FAILED_MARK" 2>/dev/null)"
bash "$SCRIPT_DIR/cadence-alert.sh" fail pipeline-harvest rc-1 /x.log
assert_rc "a delivered send clears the doctor marker" 0 "$([ -e "$CADENCE_ALERT_SEND_FAILED_MARK" ] && echo 1 || echo 0)"
# Clearing leg `a` must not re-arm leg `a.b`: `.` is the leg/reason delimiter.
reset_alerts
bash "$SCRIPT_DIR/cadence-alert.sh" fail a.b rc-1 /x.log
bash "$SCRIPT_DIR/cadence-alert.sh" clear a
bash "$SCRIPT_DIR/cadence-alert.sh" fail a.b rc-1 /x.log
assert_rc "clearing one leg leaves a dotted sibling's dedupe intact" 1 "$(count_lines "$ALERT_SENDS")"

# Test C15d: bounded retry/resume for a transient upstream API error
# The 2026-07-17 harvest died 48 minutes in on `API Error: Server error
# mid-response.` with 7 clips already recorded, and nothing retried it. Text
# assertions above prove the runner CONTAINS the loop; these fire it against a
# counting claude stub, which is the only thing that proves a transient death
# is retried, a real failure is NOT, and every attempt is visible in the one
# flow-run ledger. The backoff is neutralized through the runner's sleep seam,
# so three attempts cost no wall-clock.
echo "TEST: transient upstream API error is retried, other failures are not (HIMMEL-1152)"
RETRY_COUNT="$TMP_ROOT/retry-attempts"
cat >"$TMP_ROOT/bin-rec/claude" <<STUB
#!/usr/bin/env bash
RETRY_COUNT="$RETRY_COUNT"
STUB
cat >>"$TMP_ROOT/bin-rec/claude" <<'STUB'
echo "x" >> "$RETRY_COUNT"
_n=$(wc -l < "$RETRY_COUNT" | tr -d '[:space:]')
echo "claude-stub-attempt-$_n"
case "${RETRY_STUB_MODE:-}" in
    transient-once)
        # The verbatim line from the incident, then a clean completing run.
        if [ "$_n" = 1 ]; then
            echo "API Error: Server error mid-response. The response above may be incomplete."
            exit 1
        fi
        echo "PIPELINE-LEG-DONE"
        ;;
    transient-always)
        echo "API Error: 529 {\"type\":\"overloaded_error\"}"
        exit 1
        ;;
    *)
        # A real failure: non-zero, no transient signature anywhere in it.
        echo "Error: the vault path does not exist"
        exit 2
        ;;
esac
STUB
chmod +x "$TMP_ROOT/bin-rec/claude"
if ! grep -q "bin-rec" "$FIRE_DIR/pipeline-synthesize.sh"; then
    fail "retry fixture: runner must reference the claude STUB (refusing to execute real claude)" \
        "baked: $(grep -m1 'claude' "$FIRE_DIR/pipeline-synthesize.sh")"
else
    # 1. Transient once -> retried, second attempt completes, leg exits clean.
    : > "$RETRY_COUNT"; : > "$HIMMEL_FLOW_RUNS_LEDGER"
    rc=0
    env RETRY_STUB_MODE=transient-once PIPELINE_CADENCE_SLEEP_CMD=: \
        sh "$FIRE_DIR/pipeline-synthesize.sh" || rc=$?
    attempts=$(wc -l < "$RETRY_COUNT" | tr -d '[:space:]')
    log=$(cat "$FIRE_DIR/pipeline-synthesize.log" 2>/dev/null || echo MISSING)
    ledger=$(cat "$HIMMEL_FLOW_RUNS_LEDGER" 2>/dev/null || echo MISSING)
    assert_rc "transient death then success exits clean" 0 "$rc"
    assert_rc "transient death is re-invoked exactly once" 2 "$attempts"
    assert_contains "the retry is logged with its backoff" "[retry 1/2 after transient upstream API error" "$log"
    assert_contains "attempt 1 lands its own ledger end row" '"note":"attempt=1/3"' "$ledger"
    assert_contains "attempt 2 lands its own ledger end row" '"note":"attempt=2/3"' "$ledger"
    assert_not_contains "a leg that recovered never reaches attempt 3" '"note":"attempt=3/3"' "$ledger"
    assert_contains "the failed attempt is recorded as an error" '"outcome":"error"' "$ledger"
    assert_contains "the recovering attempt is recorded as complete" '"outcome":"complete"' "$ledger"

    # 2. A non-transient failure is NOT retried — exactly one attempt.
    : > "$RETRY_COUNT"; : > "$HIMMEL_FLOW_RUNS_LEDGER"
    rc=0
    env RETRY_STUB_MODE=real-failure PIPELINE_CADENCE_SLEEP_CMD=: \
        sh "$FIRE_DIR/pipeline-synthesize.sh" || rc=$?
    attempts=$(wc -l < "$RETRY_COUNT" | tr -d '[:space:]')
    log=$(cat "$FIRE_DIR/pipeline-synthesize.log" 2>/dev/null || echo MISSING)
    ledger=$(cat "$HIMMEL_FLOW_RUNS_LEDGER" 2>/dev/null || echo MISSING)
    assert_rc "a non-transient failure propagates its own rc" 2 "$rc"
    assert_rc "a non-transient failure is tried exactly once" 1 "$attempts"
    assert_not_contains "a non-transient failure logs no retry" "[retry" "$log"
    assert_not_contains "a non-transient failure lands no second attempt row" '"note":"attempt=2/3"' "$ledger"

    # 3. Transient every time -> the bound holds at 3 attempts, then it fails.
    : > "$RETRY_COUNT"; : > "$HIMMEL_FLOW_RUNS_LEDGER"
    rc=0
    env RETRY_STUB_MODE=transient-always PIPELINE_CADENCE_SLEEP_CMD=: \
        sh "$FIRE_DIR/pipeline-synthesize.sh" || rc=$?
    attempts=$(wc -l < "$RETRY_COUNT" | tr -d '[:space:]')
    ledger=$(cat "$HIMMEL_FLOW_RUNS_LEDGER" 2>/dev/null || echo MISSING)
    assert_rc "an unrecoverable transient run still fails" 1 "$rc"
    assert_rc "the retry bound holds at 3 attempts" 3 "$attempts"
    assert_contains "attempt 1 is in the ledger" '"note":"attempt=1/3"' "$ledger"
    assert_contains "attempt 2 is in the ledger" '"note":"attempt=2/3"' "$ledger"
    assert_contains "attempt 3 is in the ledger" '"note":"attempt=3/3"' "$ledger"
fi

out=$(env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$FIRE_DIR" bash "$SCRIPT" status)
assert_contains "status surfaces the fired log's last line" "last line:" "$out"
assert_not_contains "status resolves a real mtime (no '?' fallback)" "last write: ?" "$out"
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$FIRE_DIR" bash "$SCRIPT" disarm >/dev/null

# Test C15b: rotation regression — fire with .log ABSENT must not clobber .log.prev
# Pins the rotation fix: the old brace-group `{ [ -f "$log" ] && mv; } >> "$log"` form
# opened (created) $log via the redirect BEFORE the [ -f ] test ran, making the
# test always true and clobbering .log.prev with an empty file on the first fire
# of a session whose .log was absent. The fix moves the existence test before any
# redirect that could create $log.

echo "TEST: fire with .log absent does not clobber .log.prev (PR430 CR regression)"
REGR_DIR="$TMP_ROOT/regr-rotation"
mkdir -p "$FIRE_VAULT"
seed_triaged_clip "$FIRE_VAULT"
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$REGR_DIR" PATH="$BIN_REC_POSIX:$PATH" \
    bash "$SCRIPT" arm --vault "$FIRE_VAULT" >/dev/null
# Seed .log.prev with sentinel content; leave .log absent — this is the
# exact state that triggered the bug (e.g. a task that has run at least
# once, then the scheduler fired after a manual rm of the current .log or
# on a machine where .log was never created in the current session).
printf 'SENTINEL-PREV-CONTENT\n' > "$REGR_DIR/pipeline-synthesize.log.prev"
rm -f "$REGR_DIR/pipeline-synthesize.log"
sh "$REGR_DIR/pipeline-synthesize.sh" >/dev/null 2>&1 || true
prev_after=$(cat "$REGR_DIR/pipeline-synthesize.log.prev" 2>/dev/null || echo MISSING)
assert_contains "rotation-absent: .log.prev still holds sentinel (not clobbered)" \
    "SENTINEL-PREV-CONTENT" "$prev_after"
if grepq "$prev_after" '^$'; then
    fail "rotation-absent: .log.prev is empty — clobber bug reproduced" "$prev_after"
fi
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$REGR_DIR" bash "$SCRIPT" disarm >/dev/null

# Test C13: unknown platform exits 2 ----------------------------------------------

echo "TEST: unknown platform (OSTYPE=beos) exits 2"
rc=0; out=$(env OSTYPE=beos bash "$SCRIPT" status 2>&1) || rc=$?
assert_rc "unknown platform rc 2" 2 "$rc"
assert_contains "unknown platform message" "unsupported platform" "$out"

# ============================================================================
# Darwin Full Disk Access arm-time warning, POSIX/
# cron path. cron_arm is IDENTICAL on macos and linux (both take the crontab
# branch of the platform case) except for this warning, so OSTYPE + HOME are
# the only two hermetic seams needed to exercise the real Darwin branch
# without a macOS machine -- this is a real control, not a stand-in for one
# (the ticket's own caveat: TCC's actual grant behavior stays unvalidated
# here regardless; this proves only that the branch fires on the right input).
# ============================================================================

CSTATE_FDA="$TMP_ROOT/cron-state-darwin"
mkdir -p "$CSTATE_FDA"
FAKE_CRONTAB_FDA="$TMP_ROOT/crontab-fake-darwin.sh"
cat >"$FAKE_CRONTAB_FDA" <<FAKE
#!/bin/sh
CSTATE="$CSTATE_FDA"
FAKE
cat >>"$FAKE_CRONTAB_FDA" <<'FAKE'
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
chmod +x "$FAKE_CRONTAB_FDA"
CRON_DIR_FDA="$TMP_ROOT/cron-runners-darwin"
FDA_HOME="$TMP_ROOT/fda-home"
FDA_VAULT="$FDA_HOME/Documents/luna"
mkdir -p "$FDA_VAULT"
FDA_OUTSIDE_VAULT="$TMP_ROOT/fda-outside-vault"
mkdir -p "$FDA_OUTSIDE_VAULT"
run_fda() {
    local ostype="$1"; shift
    env OSTYPE="$ostype" HOME="$FDA_HOME" PIPELINE_CRONTAB="$FAKE_CRONTAB_FDA" \
        PIPELINE_BAT_DIR="$CRON_DIR_FDA" bash "$SCRIPT" "$@"
}

echo "TEST: Darwin arm warns about Full Disk Access when the vault sits under ~/Documents"
out=$(run_fda darwin23 arm --vault "$FDA_VAULT")
assert_contains "Darwin arm names the FDA requirement"        "Full Disk Access required" "$out"
assert_contains "Darwin arm names cron itself as the grantee" "/usr/sbin/cron"             "$out"
assert_contains "Darwin arm names himmel#771"                 "himmel#771"                 "$out"
assert_contains "Darwin arm names the protected vault path"   "$FDA_VAULT"                 "$out"
run_fda darwin23 disarm >/dev/null 2>&1

echo "TEST: Darwin arm stays silent when the vault sits outside every TCC-protected folder"
out=$(run_fda darwin23 arm --vault "$FDA_OUTSIDE_VAULT")
assert_not_contains "Darwin arm on an unprotected vault prints no FDA warning" "Full Disk Access" "$out"
run_fda darwin23 disarm >/dev/null 2>&1

echo "TEST: non-Darwin arm on the IDENTICAL protected vault path never warns (the control)"
out=$(run_fda linux-gnu arm --vault "$FDA_VAULT")
assert_not_contains "Linux arm on the same protected path prints no FDA warning" "Full Disk Access" "$out"
run_fda linux-gnu disarm >/dev/null 2>&1

summary
