#!/usr/bin/env bash
# test-arm-resume-source-key.sh -- arm-resume --source-key dedups a
# re-arm for the SAME source even when the handover path differs (an edited
# source gets a new content-digest path from vmsdk.trigger_claude), so two
# guest sessions can never queue for one source.
#
# Hermetic: stub scheduler only. The fixture header (everything down to
# new_db) is copied from test-arm-resume-identity.sh so it carries the same
# shields (fleet cap, HANDOVER_DIR, XDG_RUNTIME_DIR, telemetry, ledger).
#
# Usage: bash scripts/handover/test-arm-resume-source-key.sh
# Exit:  0 = all pass, 1 = one or more failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# arm-resume.sh now calls scripts/lib/bank-preflight.sh's
# fleet-size cap before every real (non-dry-run) arm. Without this, every
# case here that reaches that far would call the REAL fleet count against
# THIS machine's own ambient process table and could spuriously refuse
# (rc=22) on a host that genuinely has >= HIMMEL_FLEET_CAP `-n HIMMEL-*`
# sessions running - unrelated to what these cases actually test. Only the
# fleet count matters here (arm-resume.sh's gate ignores every other
# bank-preflight verdict), so no bank-cache stub is needed.
FLEET_PS_STUB="$TMP/no-fleet-ps.sh"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FLEET_PS_STUB"
chmod +x "$FLEET_PS_STUB"
export FLEET_PS_CMD="$FLEET_PS_STUB"

# bank-preflight.sh now RESERVES a fleet slot per declared launch
# (CADENCE_BANK_LAUNCH=1, set unconditionally by arm-resume.sh for every
# non-dry-run arm), not just census live processes -- so the FLEET_PS_CMD
# stub above (which zeroes the live count) no longer zeroes the fleet count
# by itself. This suite performs far more than HIMMEL_FLEET_CAP real arms,
# each under a distinct handover path/name, so each leaves its own unconsumed
# reservation (no real session ever appears to consume it) sitting under the
# suite's own XDG_RUNTIME_DIR (pinned above) until its TTL expires -- default
# 1800s, far longer than this suite's runtime. Left alone, the 5th+ real arm
# in any single run would refuse (rc=22) for a reason unrelated to what this
# suite tests. FLEET_CAP_OK=1 is the design's own documented bypass (every
# caller's refusal message names it), so this test suite qualifies exactly
# like a real operator override, not a new escape hatch.
export FLEET_CAP_OK=1

# Hermetic: fresh handover root, no real scheduler, no real telemetry/trust
# writes (same shields test-arm-resume.sh / test-arm-resume-queue-lock.sh use).
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR

# `acquire` persists the release token under XDG_RUNTIME_DIR,
# so this suite must pin that at a temp dir too -- otherwise every acquire
# below writes into the operator's real /run/user/<uid>/ runtime dir. Same
# hermeticity rule as HANDOVER_DIR above.
XDG_RUNTIME_DIR="$TMP/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR
# pin the slot dir explicitly and fail the suite if it could leak
# into the production dir the live fleet counts.
. "$SCRIPT_DIR/../lib/fleet-slots-shield.sh"
fleet_slots_shield "$TMP" || exit 1

export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export WORKER_BRIDGE_ROOT="$TMP/bridge"
# Temp-target shield: every fixture here lives under $TMP,
# exactly the shape arm-resume now refuses (exit 12). This suite means it —
# its scheduler is stubbed, so no real task is ever created. Same declared
# opt-out as test-arm-resume.sh; missing it cost 30 failures first caught by
# the public wave-2k CI (the private repo runs no Actions by design).
export ARM_TEMP_CWD_OK=1
# keep the real bank-preflight's usage-cache refresh off the live cache.
export CADENCE_BANK_CACHE="$TMP/bank-cache.json" CLAUDE_USAGE_CACHE="$TMP/bank-cache.json"
# Shipped-work shield: the preflight derives a ticket
# ID from the handover (fixtures here name) and probes LIVE Jira —
# the day went Done, every fixture arm refused rc=11 (21/36 FAIL).
# This suite exercises arm identity/slots; test-arm-resume.sh owns the
# shipped-work gate (1331/1331b cases, Jira stubbed) and sets this per-case.
export ARM_SHIPPED_OK=1
mkdir -p "$WORKER_BRIDGE_ROOT/glm-sessions" "$WORKER_BRIDGE_ROOT/claudex-sessions"
unset QUEUE_LOCK_TAKEOVER QUEUE_LOCK_TTL_SECONDS ARM_DUP_OK SCHED_CREATE_FAIL 2>/dev/null || true

# A real git repo to pin resume_cwd against (so RESUME_CWD is deterministic
# regardless of the test process cwd, and schedule_arm's cygpath/.bat path
# resolves to a real directory).
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

# FUTURE_TIME is captured ONCE (every alias/dedup pair in Groups 1-2
# must share ONE target time, else two arms for the same handover park at
# different minutes and the aliasing assertions lose their meaning). But this
# suite runs 40+ min, so by Group 3 the wall clock has passed FUTURE_TIME,
# arm-resume.sh resolves it to ~tomorrow (>60 min out), and the
# long-gap guard refuses rc=9 before the injected condition is ever reached.
# So EVERY arm below carries --long-gap: this suite's subject is identity,
# dedup and transactionality, NOT the long-gap guard, and --long-gap is a no-op
# for an arm already inside the 60-min window (so it cannot regress a fast run).
# The guard itself stays covered by the dedicated Group 4 case.
#
# the offset is 8h, not the original 30m. A 30-minute target lapses
# somewhere inside this 40+ minute run, and for ~one minute either side of that
# crossing an arm's target could go PAST between derivation and /create --
# observed live as G5.1 rc=2 ("lead=-30s; the arm itself took 60s"). That is the
# post-arm verify working exactly as designed (a scheduler entry registered at or
# after its own fire time never fires, so the honest answer is a refusal, not a
# RESUME ARMED banner) -- the fixture, not the guard, was wrong. 8h clears the
# whole run with no crossing, so the identity/dedup/transactionality assertions
# stay about identity instead of racing the clock. Every arm here already carries
# --long-gap, which now genuinely sanctions the distance rather than being a
# no-op. Group 4 computes its own FAR_TIME and is unaffected.
FUTURE_TIME=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(hours=8)).strftime("%H:%M"))')
FAILED=0

# --- assertions -------------------------------------------------------------
# assert_rc <label> <expected> <actual> [captured-output]
# On a mismatch the captured arm output is dumped -- a bare "expected rc=0,
# got rc=2" hides the cause (learned the hard way by the sibling suites).
assert_rc() {
    local label="$1" expected="$2" actual="$3" cap="${4:-}"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label -- expected rc=$expected, got rc=$actual"
        [ -n "$cap" ] && { echo "----- captured arm output -----"; printf '%s\n' "$cap"; echo "-------------------------------"; }
        FAILED=$((FAILED + 1))
    fi
}
assert_ne_rc() {  # <label> <not-this-rc> <actual> [captured]
    local label="$1" bad="$2" actual="$3" cap="${4:-}"
    if [ "$actual" != "$bad" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label -- must NOT exit rc=$bad (got exactly that)"
        [ -n "$cap" ] && { echo "----- captured arm output -----"; printf '%s\n' "$cap"; echo "-------------------------------"; }
        FAILED=$((FAILED + 1))
    fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label -- output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

# Count armed slots in the platform's state location.
#   $1 = SCHED_DB file (windows); $2 = SCHED_DB_DIR dir (posix)
count_slots() {
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        msys*|cygwin*|win32*|MINGW*)
            if [ -f "$1" ]; then local c; c=$(grep -c . "$1" 2>/dev/null); echo "${c:-0}"; else echo 0; fi ;;
        darwin*)
            # macOS uses crontab ONLY (arm-resume.sh PLATFORM=macos), whose stub
            # store is $dir/crontab.fixture -- NOT $db (schtasks) or job-*
            # (at). Counting either of those here would always read 0 on Darwin
            # and make every slot-survival assertion vacuously pass.
            if [ -f "$2/crontab.fixture" ]; then local c; c=$(grep -c . "$2/crontab.fixture" 2>/dev/null); echo "${c:-0}"; else echo 0; fi ;;
        *)
            find "$2" -maxdepth 1 -name 'job-*' 2>/dev/null | wc -l | tr -d ' ' ;;
    esac
}
# assert_slots <label> <expected> <db> <dir> [captured]
assert_slots() {
    local label="$1" expected="$2" db="$3" dir="$4" cap="${5:-}"
    local got; got=$(count_slots "$db" "$dir")
    if [ "$got" = "$expected" ]; then
        echo "PASS $label (slots=$got)"
    else
        echo "FAIL $label -- expected $expected slot(s), got $got"
        [ -n "$cap" ] && { echo "----- captured arm output -----"; printf '%s\n' "$cap"; echo "-------------------------------"; }
        FAILED=$((FAILED + 1))
    fi
}

# Write a minimal handover at the given path (resume_cwd pinned for determinism).
mk_ho() {
    local p="$1" d
    d=$(dirname "$p"); mkdir -p "$d"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        printf 'resume_cwd: %s\n' "$WORK_REPO"
        printf -- '---\n'
        printf '# HIMMEL-1304 test handover\n'
    } > "$p"
}

# ---------------------------------------------------------------------------
# Scheduler stub. Same hermetic conventions as test-arm-resume.sh's
# make_stateful_sched, with TWO additions the identity/transactional suite
# needs:
#   (1) a STATEFUL schtasks: /create records the task name, /query lists what
#       was recorded, /delete removes one -- so ONE-vs-TWO slot assertions are
#       real (an empty stub can't model a growing job set).
#   (2) SCHED_CREATE_FAIL=1 makes /create exit nonzero while /query + /delete
#       keep working -- the failure-injection seam for defect B's "fails inside
#       schedule_arm" case.
# Plus the two stubs test-arm-resume.sh does NOT carry but this suite MUST:
#   * powershell -> exit 1 (probe "unavailable" => arm-resume's
#     post-arm verify fail-OPENS, WARN + arm stands).
#   * reg -> emit a parseable US short-date pattern (M/d/yyyy) so locale
#     detection is HEALTHY. Without it, a degraded locale + the dead powershell
#     probe is the deliberate DUAL-failure refuse (rc 2 + delete-the-task) and
#     every non-dry-run arm dies, cascading every downstream assertion.
#   * claude -> exit 0 (schedule_arm requires `command -v claude`).
# ---------------------------------------------------------------------------
make_stub() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/schtasks" <<'EOF'
#!/usr/bin/env bash
# Stateful schtasks stub. State = $SCHED_DB (flat file, one task name/line).
db="${SCHED_DB:?SCHED_DB unset}"
cmd="${1:-}"; shift || true
tn=""
while [ $# -gt 0 ]; do
    case "$1" in
        /tn)   tn="${2:-}"; shift 2 ;;
        /tn=*) tn="${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "$cmd" in
    /query)
        [ -f "$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "$t" ] && printf '"\\%s","2026-01-01","Ready"\n' "$t"
        done < "$db"
        exit 0 ;;
    /create)
        # Failure injection: when SCHED_CREATE_FAIL=1,
        # /create exits nonzero so schedule_arm fails AFTER --force already
        # deleted the prior slot -- the non-transactional delete this suite
        # must catch.
        if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then
            echo "stub: schtasks /create deliberately failing (SCHED_CREATE_FAIL=1)" >&2
            exit 9
        fi
        printf '%s\n' "$tn" >> "$db"; exit 0 ;;
    /delete)
        if [ -f "$db" ]; then
            grep -vFx "$tn" "$db" > "$db.tmp" 2>/dev/null || : > "$db.tmp"
            mv "$db.tmp" "$db"
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$dir/at" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
case "${1:-}" in
    -c) cat "$d/job-${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=$(cat "$d/.counter" 2>/dev/null || echo 0); n=$((n + 1))
        printf '%s' "$n" > "$d/.counter"
        if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then exit 9; fi
        cat > "$d/job-$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
    cat > "$dir/atq" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; [ -d "$d" ] || exit 0
for f in "$d"/job-*; do
    [ -f "$f" ] || continue
    printf '%s\tThu Jun 11 09:00:00 2026 a user\n' "${f##*/job-}"
done
exit 0
EOF
    cat > "$dir/atrm" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; rm -f "$d/job-${1:-}" 2>/dev/null || true
exit 0
EOF
    cat > "$dir/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$dir/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe "unavailable" -> arm-resume's post-arm verify fail-opens
# (WARN, arm stands). Faking a NextRunTime would need the TARGET_EPOCH this
# stub can't know; the fail-open path is the honest fake for tests that
# exercise identity/dedup/transactionality, not the verify feature itself.
exit 1
EOF
    cat > "$dir/reg" <<'EOF'
#!/usr/bin/env bash
# Locale probe stub: emit a parseable US short-date pattern so arm-resume's
# _win_short_date_pattern SUCCEEDS (locale HEALTHY -> _locale_degraded=0) and
# the dead powershell probe above fail-OPENS instead of tripping the rc-2 +
# delete-the-task dual-failure refuse. Args are ignored.
echo 'HKEY_CURRENT_USER\Control Panel\International'
echo '    sShortDate    REG_SZ    M/d/yyyy'
exit 0
EOF
    cat > "$dir/crontab" <<'EOF'
#!/usr/bin/env bash
# Stateful crontab stub. arm-resume.sh routes macOS (Darwin)
# through crontab ONLY -- list_existing()'s macos arm calls _crontab_list, which
# is `crontab -l | grep`, and _crontab_schedule/_crontab_delete rewrite via
# `| crontab -` (arm-resume.sh ~:1415-1629). Without a stub here, a local
# Darwin run resolves the REAL crontab binary and reads -- and via
# _crontab_delete's rewrite, WRITES -- the operator's machine-wide crontab
# outside this suite's fixture. That is a fixture escape; this stub closes it.
# State lives in a fixture file inside $SCHED_DB_DIR -- `:?` so an unset var is
# a LOUD failure, never a silent fall-through to the real binary (mirrors the
# at/atq/atrm guard). PATH="$STUB:$PATH" puts this ahead of any real crontab,
# and the `:?` is the belt-and-suspenders: there is no code path where an unset
# var degrades into touching $HOME's crontab.
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
db="$d/crontab.fixture"
case "${1:-}" in
    -l)
        # Real `crontab -l` exits 1 ("no crontab for user"), no output, when the
        # crontab is empty. _crontab_list/_crontab_delete/_crontab_schedule all
        # guard that (`2>/dev/null || true` / `if ! crontab -l; then : > snap`),
        # so model it honestly rather than always exiting 0.
        if [ -s "$db" ]; then cat "$db"; exit 0; else exit 1; fi ;;
    -)
        # Install from stdin (REPLACE the whole fixture) -- the verb both
        # _crontab_schedule (append entry) and _crontab_delete (drop one line)
        # rewrite through. SCHED_CREATE_FAIL=1 makes the install path exit
        # nonzero so G3.3/G3.4's "fails inside schedule_arm" failure injection
        # works on Darwin exactly as schtasks /create and `at -t` do on the
        # other two platforms. Fail BEFORE writing so the fixture is untouched.
        if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then
            echo "stub: crontab install deliberately failing (SCHED_CREATE_FAIL=1)" >&2
            exit 9
        fi
        cat > "$db"; exit 0 ;;
    -r)
        : > "$db"; exit 0 ;;
    "")
        # Piped stdin with no flag = replace (some call sites `printf ... | crontab`).
        if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then exit 9; fi
        cat > "$db"; exit 0 ;;
    -*)
        # Unknown flag (-e editor, -u user): NEVER touch real state. Drain any
        # piped stdin so a writer does not see a spurious SIGPIPE, exit 0 so a
        # probe-by-existence sees a present binary.
        cat > /dev/null 2>&1 || true; exit 0 ;;
    *)
        # A bare file arg = install from that file (real `crontab <file>`).
        if [ -f "$1" ]; then
            if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then exit 9; fi
            cat "$1" > "$db"; exit 0
        fi
        cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
    chmod +x "$dir/schtasks" "$dir/at" "$dir/atq" "$dir/atrm" "$dir/claude" "$dir/powershell" "$dir/reg" "$dir/crontab"
}

STUB="$TMP/stub-bin"
make_stub "$STUB"

# Per-test fresh scheduler state. $1 -> SCHED_DB; SCHED_DB_DIR alongside.
new_db() {
    local db="$1" dir
    dir="${db}.atdir"; mkdir -p "$dir"; : > "$db"
    printf '%s' "$db"
}


# arm_key <db> <handover> <key> [extra arm-resume args...]
arm_key() {
    local db="$1" ho="$2" key="$3"; shift 3
    SCHED_DB="$db" SCHED_DB_DIR="${db}.atdir" PATH="$STUB:$PATH" \
        bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$ho" --source-key "$key" "$@" 2>&1
}

echo "== --source-key: a re-arm for the same source dedups across handover paths =="

# SK1: two DIFFERENT handover paths (the edited-content digest case), same key.
# Without the key these are distinct identities and both arm (the defect).
mk_ho "$HANDOVER_DIR/sk/in/aaaa1111-d1-next.md"
mk_ho "$HANDOVER_DIR/sk/in/aaaa1111-d2-next.md"
DBK1=$(new_db "$TMP/dbk1.tasks")
out=$(arm_key "$DBK1" "$HANDOVER_DIR/sk/in/aaaa1111-d1-next.md" src1); rc=$?
assert_rc "SK1a first arm with --source-key succeeds" 0 "$rc" "$out"
out=$(arm_key "$DBK1" "$HANDOVER_DIR/sk/in/aaaa1111-d2-next.md" src1); rc=$?
assert_rc "SK1b edited path, SAME source key is refused (rc 3)" 3 "$rc" "$out"
assert_slots "SK1c ONE slot for one source key" 1 "$DBK1" "${DBK1}.atdir" "$out"

# SK2: --force replaces the old slot with the new one (still ONE slot).
out=$(arm_key "$DBK1" "$HANDOVER_DIR/sk/in/aaaa1111-d2-next.md" src1 --force); rc=$?
assert_rc "SK2a --force re-arm for the same source key succeeds" 0 "$rc" "$out"
assert_slots "SK2b --force leaves exactly ONE slot" 1 "$DBK1" "${DBK1}.atdir" "$out"

# SK3: a DIFFERENT key still coexists (no over-dedup).
mk_ho "$HANDOVER_DIR/sk/in/bbbb2222-d1-next.md"
out=$(ARM_COLLISION_CANDIDATES='' arm_key "$DBK1" "$HANDOVER_DIR/sk/in/bbbb2222-d1-next.md" src2); rc=$?
assert_rc "SK3a a different source key arms" 0 "$rc" "$out"
assert_slots "SK3b two sources, TWO slots" 2 "$DBK1" "${DBK1}.atdir" "$out"

# SK4: the key is validated (no shell/regex metacharacters reach the marker).
out=$(arm_key "$(new_db "$TMP/dbk4.tasks")" "$HANDOVER_DIR/sk/in/aaaa1111-d1-next.md" 'bad key;x'); rc=$?
assert_ne_rc "SK4 invalid --source-key is refused" 0 "$rc" "$out"
assert_contains "SK4 names the flag" "--source-key" "$out"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$FAILED FAILED"; exit 1
