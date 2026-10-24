#!/usr/bin/env bash
# test-console-kit-e2e.sh - The console kit's pieces are unit-tested
# one at a time (test-tick.sh, test-close-wrapped-leg.sh, test-board.sh,
# test-wrap-subtree-check.sh) with the others stubbed; this suite runs the REAL
# tick.sh, queue-lock.sh, append-results.sh, close-wrapped-leg.sh,
# wrap-subtree-check.sh and board.mjs together against one fixture fleet in a
# scratch handover root, and asserts what a console relies on across them:
#   1. a FINDING tail stays visible (tick tails=, board) until a RESOLVED bullet
#   2. a succession (relay, token kept) keeps the leg FRESH, and tick reads
#      nonces= UNCONFIRMED until the leg's SUCCESSION bullet, then RELAYED
#   3. a wrapped leg (WRAPPED + lock released) is CLOSABLE and
#      close-wrapped-leg.sh signals exactly that session
#   4. a leg with a live non-harness child is refused (rc 6), not killed
#   5. a misordered WRAPPED (above a later marker bullet) is refused (rc 4);
#      appending a fresh WRAPPED with append-results.sh makes it closable
# The legs are real processes: a copy of bash named `claude`, parked on a fifo
# read, argv `claude -c <script> <fifo> -n <session>`, so the real
# `pgrep -x claude` + /proc/<pid>/cmdline census sees them. No network and no
# real claude: gh, atq and bun are PATH stubs; the usage cache is a fixture.
# CENSUS CAVEAT: the stubs are visible to a live console's process census on the
# same box for the ~15 s of a run (a leg-shaped name must derive an N<k> label,
# so no prefix hides them); the EXIT trap reaps every one and its children.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only (tick.sh
# reads pgrep, atq, /proc); this suite exits 0 elsewhere.
set -uo pipefail

if [ "$(uname -s)" != Linux ]; then
    echo "skip - console-kit e2e is Linux-only (the kit reads /proc and pgrep)"
    exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CK="$HERE"
QL="$REPO/scripts/handover/queue-lock.sh"
AR="$CK/append-results.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/ck-e2e.XXXXXX")" || { echo "FAIL: mktemp -d" >&2; exit 1; }
PIDS=""
cleanup() {
    local p
    # children first (the with-child leg's sleep), then the fake sessions
    for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    rm -rf "$W"
}
trap cleanup EXIT

fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: [$2] != [$3]"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1: missing [$3] in [$2]" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1: unexpected [$3] in [$2]" ;; *) pass "$1" ;; esac; }

export HANDOVER_DIR="$W/root"
B="$W/root/u/himmel"
mkdir -p "$B" "$W/bin" "$W/fifo" "$W/projects/proj" "$W/sessions" "$W/launch" "$W/state" "$W/digest"

# ---- offline stubs and seams ------------------------------------------------
printf '#!/usr/bin/env bash\ncase "$*" in *"pr list"*) echo "[]" ;; *) exit 1 ;; esac\n' > "$W/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/atq"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/bun"
chmod +x "$W/bin/gh" "$W/bin/atq" "$W/bin/bun"
cp "$(command -v bash)" "$W/bin/claude"
export PATH="$W/bin:$PATH"
printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"
export TICK_BANK_CACHE_FILE="$W/bank.json" CADENCE_BANK_CACHE="$W/bank.json" CADENCE_BANK_SKIP_REFRESH=1
export CADENCE_BANK_LEDGER=/dev/null
export TICK_STATE_DIR="$W/state" TICK_LAUNCH_DIR="$W/launch" TICK_TMPDIR="$W"
# no wt-orphans probe: the real worktree.sh would read this checkout's fleet
export TICK_WORKTREE_ORPHANS_PROBE="$W/no-wt-orphans-probe"
export HIMMEL_FAILURE_ROUTES_LOG="$W/routes.jsonl" SUITE_FLAKE_LEDGER="$W/flake.jsonl" SUITE_FLAKE_REPO_ID=ck-e2e
export HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$W/leg-failures.jsonl" HIMMEL_EVAL_RUNS_LEDGER="$W/eval-runs.jsonl"
# No bus identity, so append-results never adopts on the real himmel-bus store.
unset HIMMEL_BUS_NAME
export WORKER_SESSION_DIGEST_STATE_DIR="$W/digest" WORKER_SESSION_DIGEST_SETTLE_MAX=0 WORKER_SESSION_DIGEST_SETTLE_QUIET=0
export CLOSE_WRAPPED_LEG_PROJECTS_DIR="$W/projects" CLOSE_WRAPPED_LEG_SESSIONS_DIR="$W/sessions"
export CLOSE_WRAPPED_LEG_REAP_WAIT=0 CLOSE_WRAPPED_LEG_DIGEST_TIMEOUT=30
# append-results.sh moves Jira on a LIVE bullet; never from a test
export WORKER_SESSION_JIRA_STATUS=0
# a forked non-harness child counts at once (the default skips a child forked within 10s of its session)
export WRAP_SUBTREE_START_WINDOW=0

# spawn_leg <session-name> [with-child]: sets SPAWNED (no command substitution, so PIDS survives for the trap)
spawn_leg() {
    local name="$1" f="$W/fifo/$1" pid
    mkfifo "$f"
    if [ "${2:-}" = with-child ]; then
        "$W/bin/claude" -c 'sleep 300 & wait' "$f" -n "$name" >/dev/null 2>&1 &
    else
        # shellcheck disable=SC2016  # the script body is deliberately literal for the child shell
        "$W/bin/claude" -c 'exec 3<>"$0"; read -r -t 300 -u 3 _' "$f" -n "$name" >/dev/null 2>&1 &
    fi
    pid=$!
    PIDS="$PIDS $pid"
    SPAWNED="$pid"
}
# gone <pid>: waits up to ~5 s for the process to exit
gone() {
    local i=0
    while [ -d "/proc/$1" ] && [ "$i" -lt 50 ]; do
        # a TERMed bash child of this shell stays a zombie until reaped
        # (only when it is already a zombie: `wait` on a live child would block)
        if ! alive "$1"; then wait "$1" 2>/dev/null; fi
        [ -d "/proc/$1" ] || break
        i=$((i + 1)); sleep 0.1
    done
    [ ! -d "/proc/$1" ] || [ "$(sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "/proc/$1/status" 2>/dev/null)" = Z ]
}
alive() { [ -d "/proc/$1" ] && [ "$(sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "/proc/$1/status" 2>/dev/null)" != Z ]; }

C="$B/HIMMEL-nextleg-2026-10-11DC-e2e-console.md"
L1="$B/HIMMEL-9001-N1-alpha$$-2026-10-11.md"
L2="$B/HIMMEL-9002-N2-beta$$-2026-10-11.md"
L3="$B/HIMMEL-9003-N3-gamma$$-2026-10-11.md"
L4="$B/HIMMEL-9004-N4-delta$$-2026-10-11.md"
L5="$B/HIMMEL-9005-N5-eps$$-2026-10-11.md"
for d in "$L1" "$L2" "$L3" "$L4" "$L5"; do printf '# leg\n\n## Results\n\n' > "$d"; done
for d in "$L1" "$L2" "$L3" "$C"; do bash "$QL" acquire "$d" >/dev/null 2>&1 || fail "queue-lock acquire $d"; done

spawn_leg HIMMEL-9001-N1-alpha$$-2026-10-11; P1="$SPAWNED"
spawn_leg HIMMEL-9002-N2-beta$$-2026-10-11; P2="$SPAWNED"
spawn_leg HIMMEL-9003-N3-gamma$$-2026-10-11; P3="$SPAWNED"
# close-wrapped-leg.sh reads the matched pid's session record, then its transcript
SID=11111111-2222-3333-4444-555555555555
printf '%s\n' '{"type":"user","timestamp":"2026-10-11T10:00:00Z"}' > "$W/projects/proj/$SID.jsonl"
printf '{"sessionId":"%s"}\n' "$SID" > "$W/sessions/$P1.json"

# The console's Live state: N3's nonce carries the PREVIOUS console's letter (DB);
# this console is DC, so tick must ask whether N3 was re-briefed.
cat > "$C" <<EOC
# console

## Live state
legs: \`N1:DC-N1-aa11:tok1:$P1\` \`N2:DC-N2-bb22:tok2:$P2\` \`N3:DB-N3-cc33:tok3:$P3\`

## Results
EOC
for d in "$L1" "$L2" "$L3"; do bash "$AR" "$d" "LIVE — working" >/dev/null; done
bash "$AR" "$L2" "FINDING — need a ruling" >/dev/null

LEGS="$L1 $L2 $L3"
# tick_field <field>: that field's value from one real tick run
tick_field() {
    local out
    local rc
    out="$(bash "$CK/tick.sh" --doc "$C" --token tok --legs "$LEGS" --repo "$REPO" 2>"$W/tick.err")"; rc=$?
    # a failed tick must not satisfy an assertion on whatever it printed first
    if [ "$rc" -ne 0 ]; then printf 'tick-exit-%s\n' "$rc"; return 0; fi
    printf '%s\n' "$out" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
render_board() {
    rm -f "$W/board.html"    # a failed render must not leave a prior page to read
    node "$CK/board.mjs" --doc "$C" --legs "$LEGS" --out "$W/board.html" --repo "$REPO" >/dev/null 2>&1
    cat "$W/board.html" 2>/dev/null
}

# ---- 1. FINDING stays visible until RESOLVED --------------------------------
check "tails: FINDING is N2's status" "$(tick_field tails)" "N1:LIVE,N2:FINDING,N3:LIVE"
check "tails: FINDING persists across a second tick" "$(tick_field tails)" "N1:LIVE,N2:FINDING,N3:LIVE"
check "legs: every held leg is FRESH" "$(tick_field legs)" "N1:FRESH,N2:FRESH,N3:FRESH"
contains "board: FINDING asks for a ruling" "$(render_board)" "FINDING — needs a ruling"
bash "$AR" "$L2" "RESOLVED — ruling received, see console message" >/dev/null
check "tails: RESOLVED retires the FINDING" "$(tick_field tails)" "N1:LIVE,N2:RESOLVED,N3:LIVE"
board_after="$(render_board)"
contains "board: the re-render produced a page" "$board_after" "</html>"
lacks "board: no ruling ask after RESOLVED" "$board_after" "FINDING — needs a ruling"

# ---- 2. succession: relay, token kept ---------------------------------------
check "nonces: a previous console's letter reads UNCONFIRMED" "$(tick_field nonces)" "UNCONFIRMED:N3"
bash "$AR" "$L3" "SUCCESSION accepted: HIMMEL-nextleg-2026-10-11DC-e2e-console replaces HIMMEL-nextleg-2026-10-11DB-old" >/dev/null
check "nonces: the leg's SUCCESSION bullet reads RELAYED" "$(tick_field nonces)" "RELAYED:N3"
check "legs: the relayed leg is still FRESH (lock kept)" "$(tick_field legs)" "N1:FRESH,N2:FRESH,N3:FRESH"
check "tails: a SUCCESSION bullet is not a status marker" "$(tick_field tails)" "N1:LIVE,N2:RESOLVED,N3:LIVE"
# a bullet naming a DIFFERENT console confirms nothing
bash "$AR" "$L3" "SUCCESSION accepted: HIMMEL-nextleg-2026-10-11DZ-other replaces HIMMEL-nextleg-2026-10-11DC-e2e-console" >/dev/null
check "nonces: a succession to another console reads UNCONFIRMED again" "$(tick_field nonces)" "UNCONFIRMED:N3"

# ---- 3. a wrapped leg is closable -------------------------------------------
bash "$AR" "$L1" "WRAPPED — done" >/dev/null
tok1="$(bash "$QL" status "$L1" | sed -n 's/.*"session":"\([^"]*\)".*/\1/p')"
out="$(bash "$CK/close-wrapped-leg.sh" "$L1" 2>&1)"; rc=$?
check "close: a WRAPPED leg with its lock still held is refused (rc 3)" "$rc" 3
if alive "$P1"; then pass "close: refused close left the session alive"; else fail "close: refused close killed pid $P1"; fi
bash "$QL" release "$L1" "$tok1" >/dev/null 2>&1
check "tails: N1 reads WRAPPED" "$(tick_field tails)" "N1:WRAPPED,N2:RESOLVED,N3:LIVE"
contains "legs: a wrapped, subtree-clean leg reads CLOSABLE" "$(tick_field legs)" "N1:CLOSABLE"
out="$(bash "$CK/close-wrapped-leg.sh" "$L1" 2>&1)"; rc=$?
check "close: a wrapped leg closes (rc 0)" "$rc" 0
contains "close: TERM went to the matched pid" "$out" "sent TERM to pid $P1"
if gone "$P1"; then pass "close: the wrapped leg's session is gone"; else fail "close: pid $P1 still running"; fi
if alive "$P2" && alive "$P3"; then pass "close: other legs' sessions untouched"; else fail "close: a sibling session died"; fi

# ---- 4. a live non-harness child withholds the close ------------------------
spawn_leg HIMMEL-9005-N5-eps$$-2026-10-11 with-child; P5="$SPAWNED"
printf '{"sessionId":"%s"}\n' "$SID" > "$W/sessions/$P5.json"
sleep 0.5
K5="$(pgrep -P "$P5" -x sleep | head -n 1)"
bash "$AR" "$L5" "WRAPPED — done" >/dev/null
out="$(bash "$CK/close-wrapped-leg.sh" "$L5" 2>&1)"; rc=$?
check "close: a live leg-spawned child refuses the close (rc 6)" "$rc" 6
contains "close: the subtree check says WITHHELD" "$out" "WITHHELD"
if alive "$P5"; then pass "close: the session with a live child was not killed"; else fail "close: pid $P5 was killed"; fi
if [ -n "$K5" ] && alive "$K5"; then pass "close: the live child was not killed either"; else fail "close: child [$K5] of pid $P5 is gone"; fi

# ---- 5. a misordered WRAPPED is refused -------------------------------------
spawn_leg HIMMEL-9004-N4-delta$$-2026-10-11; P4="$SPAWNED"
printf '{"sessionId":"%s"}\n' "$SID" > "$W/sessions/$P4.json"
printf '%s\n' "- 10:00 WRAPPED — done" "- 10:05 LIVE — CHECKPOINT abc pushed" >> "$L4"
out="$(bash "$CK/close-wrapped-leg.sh" "$L4" 2>&1)"; rc=$?
check "close: a WRAPPED above a later LIVE bullet is refused (rc 4)" "$rc" 4
contains "close: the refusal names the real tail" "$out" "last Results marker-bullet is 'LIVE'"
if alive "$P4"; then pass "close: the misordered leg was not killed"; else fail "close: pid $P4 was killed"; fi
bash "$AR" "$L4" "WRAPPED — done" >/dev/null
out="$(bash "$CK/close-wrapped-leg.sh" "$L4" 2>&1)"; rc=$?
check "close: append-results.sh's EOF WRAPPED makes it closable (rc 0)" "$rc" 0
if gone "$P4"; then pass "close: the corrected leg's session is gone"; else fail "close: pid $P4 still running"; fi

if [ "$fails" -gt 0 ]; then
    printf '%s check(s) failed\n' "$fails"
    exit 1
fi
echo "all console-kit e2e checks passed"
