#!/usr/bin/env bash
# Smoke test for scripts/lib/flow-run-ledger-path.sh.
# Usage: bash scripts/lib/test-flow-run-ledger-path.sh
# Exit 0 if all cases pass, 1 otherwise. Hermetic — HOME is redirected to a
# scratch dir for every case, so the real ~/.himmel/flow-runs.jsonl is never
# touched even when a case exercises the unset-override default path.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LEDGER_SH="$REPO_ROOT/scripts/lib/flow-run-ledger.sh"

[ -f "$LEDGER_SH" ] || { echo "FAIL: $LEDGER_SH not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/flow-ledger-path-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
# $out sits OUTSIDE /tmp: the net accepts ${TMPDIR:-/tmp} and literal /tmp only.
out="$(mktemp -d -p /var/tmp flow-ledger-out.XXXXXX)" || { echo "FAIL: mktemp /var/tmp"; exit 1; }
z_dir="$(mktemp -d /tmp/flow-ledger-z.XXXXXX)" || { echo "FAIL: mktemp /tmp"; exit 1; }
trap 'rm -rf "$tmp" "$out" "$z_dir"' EXIT

echo "== HIMMEL_FLOW_RUNS_LEDGER override: --append-start writes there, not the default =="
scratch_home="$tmp/home"
override_ledger="$tmp/scratch-flow-runs.jsonl"
default_ledger="$scratch_home/.himmel/flow-runs.jsonl"
mkdir -p "$scratch_home"

HOME="$scratch_home" HIMMEL_FLOW_RUNS_LEDGER="$override_ledger" \
    bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null

if [ -f "$override_ledger" ]; then
    pass "override path got the row"
else
    fail "override path missing: $override_ledger"
fi

if [ -f "$default_ledger" ]; then
    fail "default path was written despite override: $default_ledger"
else
    pass "default path untouched"
fi

echo
echo "== HIMMEL-2241 suite-marker quarantine =="
# The guard in flow_run_append: inside a shell-suite run (run-shell-tests.sh
# exports HIMMEL_SUITE_LOCK_HELD) a write with NO explicit override is a
# fixture that fell back to the production ledger -- quarantine it loudly.
q_home="$out/q-home"
q_tmp="$tmp/q-tmp"
mkdir -p "$q_home" "$q_tmp"
q_default="$q_home/.himmel/flow-runs.jsonl"
q_file="$q_tmp/flow-runs-unredirected.jsonl"

# POSITIVE control: marker set, no override -> quarantined, default untouched.
q_err="$tmp/q-err.txt"
env -u HIMMEL_FLOW_RUNS_LEDGER HOME="$q_home" TMPDIR="$q_tmp"     HIMMEL_SUITE_LOCK_HELD="$q_tmp/fake-suite-lock"     bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247     >/dev/null 2>"$q_err"

if [ -f "$q_file" ]; then
    pass "marker set + no override: row quarantined in TMPDIR"
else
    fail "marker set + no override: quarantine file missing: $q_file"
fi
if [ -f "$q_default" ]; then
    fail "marker set + no override: the default ledger was written anyway"
else
    pass "marker set + no override: default ledger untouched"
fi
if grep -q 'HIMMEL-2241 WARN' "$q_err"; then
    pass "quarantine warned on stderr"
else
    fail "quarantine was silent; stderr: $(cat "$q_err")"
fi

# NEGATIVE control: NO marker, no override -> the default path still wins.
# This is the "a genuine flow outside any suite is untouched" proof.
n_tmp="$tmp/n-tmp"
n_home="$n_tmp/n-home"
mkdir -p "$n_home" "$n_tmp"
n_default="$n_home/.himmel/flow-runs.jsonl"
env -u HIMMEL_FLOW_RUNS_LEDGER -u HIMMEL_SUITE_LOCK_HELD     HOME="$n_home" TMPDIR="$n_tmp"     bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null

if [ -f "$n_default" ]; then
    pass "no marker + no override: default ledger still gets the row"
else
    fail "no marker + no override: default ledger missing: $n_default"
fi
if [ -f "$n_tmp/flow-runs-unredirected.jsonl" ]; then
    fail "no marker: quarantined a genuine non-suite write"
else
    pass "no marker: nothing quarantined"
fi

# An explicit override inside a suite still wins over the quarantine path.
o_tmp="$tmp/o-tmp"
mkdir -p "$o_tmp"
o_ledger="$o_tmp/o-ledger.jsonl"
env HOME="$q_home" TMPDIR="$o_tmp" HIMMEL_SUITE_LOCK_HELD="$o_tmp/fake-suite-lock"     HIMMEL_FLOW_RUNS_LEDGER="$o_ledger"     bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null

if [ -f "$o_ledger" ]; then
    pass "marker set + override: the override still wins"
else
    fail "marker set + override: override path missing: $o_ledger"
fi
if [ -f "$o_tmp/flow-runs-unredirected.jsonl" ]; then
    fail "marker set + override: quarantined despite an explicit redirect"
else
    pass "marker set + override: nothing quarantined"
fi

echo
echo "== HIMMEL-2687 quarantine net: ledger outside the suite temp root =="
# Hole (a): the marker is set and an override IS set, but it points outside the
# suite temp root (an exported operator ledger) -- must not reach it.
a_tmp="$tmp/a-tmp"; a_home="$tmp/a-home"; a_out="$out/a-operator/flow-runs.jsonl"
mkdir -p "$a_tmp" "$a_home"
a_err="$tmp/a-err.txt"
env HOME="$a_home" TMPDIR="$a_tmp" HIMMEL_SUITE_LOCK_HELD="$a_tmp/fake-suite-lock" \
    HIMMEL_FLOW_RUNS_LEDGER="$a_out" \
    bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null 2>"$a_err"
if [ -e "$a_out" ]; then
    fail "marker set + override outside the temp root: the outside ledger was written"
else
    pass "marker set + override outside the temp root: outside ledger untouched"
fi
if [ -f "$a_tmp/flow-runs-unredirected.jsonl" ] && grep -q 'HIMMEL-2241 WARN' "$a_err"; then
    pass "marker set + override outside the temp root: quarantined with the WARN"
else
    fail "marker set + override outside the temp root: no quarantine/WARN; stderr: $(cat "$a_err")"
fi

# A '..' hop must not smuggle an outside path past the prefix test.
d_tmp="$tmp/d-tmp"; mkdir -p "$d_tmp"
d_out="$tmp/d-escaped.jsonl"
env HOME="$a_home" TMPDIR="$d_tmp" HIMMEL_SUITE_LOCK_HELD="$d_tmp/fake-suite-lock" \
    HIMMEL_FLOW_RUNS_LEDGER="$d_tmp/../d-escaped.jsonl" \
    bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null 2>&1
if [ -e "$d_out" ]; then
    fail "override with a '..' hop escaped the temp root"
else
    pass "override with a '..' hop is treated as outside the temp root"
fi

# Hole (b): NO marker -- this suite is itself a directly-invoked test-*.sh, so
# the wrapper's ancestry names a suite. No override, HOME outside the temp root.
b_tmp="$tmp/b-tmp"; b_home="$out/b-home"; mkdir -p "$b_tmp" "$b_home"
env -u HIMMEL_FLOW_RUNS_LEDGER -u HIMMEL_SUITE_LOCK_HELD HOME="$b_home" TMPDIR="$b_tmp" \
    bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null 2>&1
if [ -e "$b_home/.himmel/flow-runs.jsonl" ]; then
    fail "direct suite, no marker: the HOME default ledger was written"
else
    pass "direct suite, no marker: HOME default ledger absent"
fi
if [ -f "$b_tmp/flow-runs-unredirected.jsonl" ]; then
    pass "direct suite, no marker: row quarantined in TMPDIR"
else
    fail "direct suite, no marker: quarantine file missing"
fi

# Ledger under /tmp but outside TMPDIR (the dispatch-codex-exec section 19
# shape): allowed, not quarantined.
z_tmp="$z_dir/narrow-tmp"; mkdir -p "$z_tmp"
env HOME="$a_home" TMPDIR="$z_tmp" HIMMEL_SUITE_LOCK_HELD="$z_tmp/fake-suite-lock" \
    HIMMEL_FLOW_RUNS_LEDGER="$z_dir/z-ledger.jsonl" \
    bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null 2>&1
if [ -f "$z_dir/z-ledger.jsonl" ] && [ ! -e "$z_tmp/flow-runs-unredirected.jsonl" ]; then
    pass "ledger under /tmp but outside TMPDIR is allowed"
else
    fail "ledger under /tmp but outside TMPDIR was quarantined or missing"
fi

# Root predicate directly: the HOME default is not under /tmp, a /tmpfoo
# lookalike is not /tmp, a '..' hop never counts.
# shellcheck disable=SC1090
root_check() { ( . "$LEDGER_SH"; _fr_under_tmp_root "$1" ); }
# shellcheck disable=SC2016
h_default=$(env -u HIMMEL_FLOW_RUNS_LEDGER HOME="$out/h" bash -c '. "$1"; flow_run_ledger_path' _ "$LEDGER_SH")
if TMPDIR="$z_tmp" root_check "$h_default"; then
    fail "default HOME ledger path counted as under a legit root: $h_default"
else
    pass "default (unset override) ledger path is not under TMPDIR or /tmp"
fi
if TMPDIR="$z_tmp" root_check "/tmpfoo/flow-runs.jsonl"; then
    fail "/tmpfoo lookalike counted as /tmp"
else
    pass "/tmpfoo lookalike is outside /tmp"
fi
if TMPDIR="$z_tmp" root_check "$z_dir/sub/../../x.jsonl"; then
    fail "'..' path counted as inside"
else
    pass "'..' path is outside"
fi
if TMPDIR="$z_tmp" root_check "$z_dir/new-sub/x.jsonl"; then
    pass "not-yet-existing path under /tmp resolves as inside"
else
    fail "not-yet-existing path under /tmp counted as outside"
fi

# A ledger under /tmp that is a symlink to a path outside both roots is outside.
mkdir -p "$out/link-target"
ln -s "$out/link-target/prod.jsonl" "$z_dir/linked-ledger.jsonl"
if TMPDIR="$z_tmp" root_check "$z_dir/linked-ledger.jsonl"; then
    fail "symlinked ledger under /tmp pointing outside both roots counted as inside"
else
    pass "symlinked ledger pointing outside both roots is outside"
fi

# Control: a default ledger inside the temp root is the suite's own scratch
# HOME and is not quarantined.
i_tmp="$tmp/i-tmp"; mkdir -p "$i_tmp/home"
env -u HIMMEL_FLOW_RUNS_LEDGER HOME="$i_tmp/home" TMPDIR="$i_tmp" \
    bash "$LEDGER_SH" --append-start "test-flow" "" "testhost" "" "" "" "" 4247 >/dev/null 2>&1
if [ -f "$i_tmp/home/.himmel/flow-runs.jsonl" ] && [ ! -e "$i_tmp/flow-runs-unredirected.jsonl" ]; then
    pass "HOME default inside the temp root is not quarantined"
else
    fail "HOME default inside the temp root was quarantined or missing"
fi

# Control: a genuine non-suite run. setsid -f reparents the wrapper to init, so
# no test-*.sh sits in its ancestry; no marker, no override -> HOME default.
g_tmp="$tmp/g-tmp"; g_home="$out/g-home"; mkdir -p "$g_tmp" "$g_home"
if command -v setsid >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    env -u HIMMEL_FLOW_RUNS_LEDGER -u HIMMEL_SUITE_LOCK_HELD HOME="$g_home" TMPDIR="$g_tmp" \
        setsid -f bash -c 'bash "$1" --append-start test-flow "" testhost "" "" "" "" 4247 >/dev/null 2>&1; : > "$2"' _ "$LEDGER_SH" "$g_tmp/done"
    for _ in $(seq 1 50); do [ -e "$g_tmp/done" ] && break; sleep 0.1; done
    if [ -f "$g_home/.himmel/flow-runs.jsonl" ] && [ ! -e "$g_tmp/flow-runs-unredirected.jsonl" ]; then
        pass "genuine non-suite run: HOME default still gets the row"
    else
        fail "genuine non-suite run: default missing or quarantined (done=$([ -e "$g_tmp/done" ] && echo y || echo n))"
    fi
else
    pass "setsid absent: genuine non-suite control skipped"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
