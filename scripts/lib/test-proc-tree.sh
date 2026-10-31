#!/usr/bin/env bash
# Unit tests for the tri-state contract of proc_tree_process_alive and
# proc_tree_process_identity_matches in scripts/lib/proc-tree.sh.
#
# THE BUG: proc_tree_process_alive used a bare `kill -0 2>/dev/null`, which
# collapses "confirmed gone" and "the probe was refused/unavailable" into the
# same nonzero rc, which proc_tree_process_identity_matches then laundered into a
# CONFIRMED mismatch/exit (rc 1) even when the probe had told it nothing.
# proc_tree_terminate trusts that rc 1 to send a KILL signal, so a refused
# probe could be misread as green light. The existing suite passed while this
# bug was live -- it stubs proc_tree_process_identity_matches wholesale, never
# reaching proc_tree_process_alive -- so every case below calls the REAL
# proc_tree_process_alive and the REAL proc_tree_process_identity_matches.
#
# T7 gets a genuine ESRCH from the real `kill` builtin against a pid that
# cannot exist. A genuine EPERM needs a foreign-owned live process, so T8
# instead shadows `kill` with a function, which bash resolves before the
# builtin for a bare `kill` call -- exactly how proc_tree_process_alive
# invokes it -- so the call still goes through the real
# proc_tree_process_alive, only the OS-level kill(2) underneath is faked.
# shellcheck disable=SC2218  # T11 below re-defines proc_tree_process_identity_matches
# (already sourced from proc-tree.sh, real at T4-T6b) as a stub to confirm
# delegation; shellcheck's whole-file scan misreads the earlier REAL calls as
# forward references to that later local redefinition.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

# shellcheck source=proc-tree.sh
# shellcheck disable=SC1091
. "$HERE/proc-tree.sh"

# --- proc_tree_process_alive (kill -0) ------------------------------------------

# T7: genuine ESRCH via the real kill builtin against a pid that cannot exist.
rc=0; proc_tree_process_alive 2147483647 || rc=$?
check "T7 posix arm: genuine ESRCH -> confirmed absent (1)" "$rc" "1"

# T8: EPERM simulated by shadowing `kill` with a function -- bash resolves a
# bare `kill` call to a function before the builtin, which is exactly how
# proc_tree_process_alive invokes it, so this still reaches the real
# proc_tree_process_alive and only fakes what kill(2) reports underneath.
# shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_process_alive's bare `kill -0` call.
kill() {
    echo "kill: ($1) - Operation not permitted" >&2
    return 1
}
rc=0; proc_tree_process_alive 4242 || rc=$?
check "T8 posix arm: simulated EPERM -> probe unavailable (2), NOT confirmed" "$rc" "2"

# T5: THE core regression case. proc_tree_process_identity_matches must NOT
# report T8's probe-unavailable state as a confirmed mismatch/exit -- the
# defect class this suite closes one layer down. Same shadowed `kill`.
rc=0; proc_tree_process_identity_matches 4242 "some-identity" || rc=$?
check "T5 identity_matches: probe unavailable -> rc 2, NEVER confirmed (1)" "$rc" "2"
unset -f kill

# T4: proc_tree_process_identity_matches must propagate T7's confirmed absence
# as its own confirmed-mismatch/exit contract (rc 1), through the real
# proc_tree_process_alive.
rc=0; proc_tree_process_identity_matches 2147483647 "some-identity" || rc=$?
check "T4 identity_matches: confirmed absence -> rc 1" "$rc" "1"

# T6: alive ($$) + identity check runs through to proc_tree_process_identity --
# stub only that leaf fetch (not identity_matches itself) to pin the 0/1 split
# once alive_rc=0.
# shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_process_identity_matches below.
proc_tree_process_identity() { printf 'stub-identity\n'; }
rc=0; proc_tree_process_identity_matches $$ "stub-identity" || rc=$?
check "T6 identity_matches: alive + identity match -> rc 0" "$rc" "0"
rc=0; proc_tree_process_identity_matches $$ "other-identity" || rc=$?
check "T6b identity_matches: alive + identity mismatch -> rc 1" "$rc" "1"
unset -f proc_tree_process_identity

# --- proc_tree_liveness_matches ---------------------
# An empty expected identity means the identity probe FAILED AT RECORD TIME
# (e.g. `ps` unavailable when the owner was branded), not that the pid is
# unprobeable now -- so liveness_matches must fall back to the identity-free
# proc_tree_process_alive rather than returning identity_matches' unconditional
# 2 for an empty expected (line 147 above). Still the POSIX (kill -0) arm.

# T9: empty identity + a pid confirmed gone via the real kill builtin -> falls
# back to proc_tree_process_alive's confirmed-absent contract (rc 1), not the
# "probe unavailable" rc 2 that proc_tree_process_identity_matches alone would
# give an empty expected.
rc=0; proc_tree_liveness_matches 2147483647 "" || rc=$?
check "T9 liveness_matches: empty identity + confirmed-gone pid -> rc 1" "$rc" "1"

# T10: empty identity + this test's own live pid ($$) -> rc 0. A dead holder's
# empty-identity slot must not block reclaim, but a genuinely live one -- e.g.
# a holder's own child probing its ancestor -- must not be refused either.
rc=0; proc_tree_liveness_matches $$ "" || rc=$?
check "T10 liveness_matches: empty identity + live pid -> rc 0 (own-process not refused)" "$rc" "0"

# T11: a NON-empty expected identity must delegate to
# proc_tree_process_identity_matches rather than reimplementing its logic --
# stub it to a distinguishable rc and confirm liveness_matches propagates that
# exact rc unchanged, proving delegation rather than a second code path.
# shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_liveness_matches below.
proc_tree_process_identity_matches() { return 1; }
rc=0; proc_tree_liveness_matches 4242 "some-identity" || rc=$?
check "T11 liveness_matches: non-empty identity delegates to identity_matches (rc 1 propagated)" "$rc" "1"
unset -f proc_tree_process_identity_matches

# --- proc_tree_process_identity: TZ/COLUMNS independence. The identity is `ps -o lstart= -o command=`; lstart is
# printed in the caller's TZ and command is truncated to the caller's COLUMNS,
# so a live holder recorded in one environment looked "dead" to a contender
# reading it in another -- a false-positive double-acquire. Real background
# process, real ps, no stubs.
#
# T6/T11 above stub proc_tree_process_identity /
# proc_tree_process_identity_matches then `unset -f` them -- unset -f removes
# a function outright, it does not restore whatever definition preceded the
# stub, so the REAL implementations sourced at the top of this file are gone
# from here on unless re-sourced.
# shellcheck source=proc-tree.sh
# shellcheck disable=SC1091
. "$HERE/proc-tree.sh"

sleep 60 & livepid=$!

# T12: identity recorded under TZ=Asia/Jerusalem, judged under TZ=UTC, must
# still match -- before the fix this diverged and liveness_matches judged a
# live process dead (rc 1).
recorded=$(TZ=Asia/Jerusalem proc_tree_process_identity "$livepid")
check "T12 identity: ps probe recorded a nonempty identity (not a vacuous pass)" "$([ -n "$recorded" ] && echo 1 || echo 0)" "1"
rc=0; TZ=UTC proc_tree_liveness_matches "$livepid" "$recorded" || rc=$?
check "T12 identity: TZ mismatch (recorded JLM, judged UTC) still matches live pid -> rc 0" "$rc" "0"
kill "$livepid" 2>/dev/null

# T13: identity recorded under a narrow COLUMNS, judged under a wide one, must
# still match -- before the fix, ps truncated `command` to the narrower width
# and the two strings diverged. A short argv (e.g. bare `sleep 60`) is already
# shorter than a narrow COLUMNS and never triggers ps's truncation, so this
# needs a long argv to actually exercise the width cut.
long_arg=$(printf 'A%.0s' $(seq 1 200))
bash -c 'while :; do sleep 5; done' "$long_arg" & livepid=$!
recorded=$(COLUMNS=20 proc_tree_process_identity "$livepid")
check "T13 identity: ps probe recorded a nonempty identity (not a vacuous pass)" "$([ -n "$recorded" ] && echo 1 || echo 0)" "1"
rc=0; COLUMNS=200 proc_tree_liveness_matches "$livepid" "$recorded" || rc=$?
check "T13 identity: COLUMNS mismatch (recorded 20, judged 200) still matches live pid -> rc 0" "$rc" "0"

kill "$livepid" 2>/dev/null

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
