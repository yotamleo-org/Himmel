#!/usr/bin/env bash
# test-guest-exec.sh - hermetic coverage for scripts/vm/guest-exec.sh.
# A stub `uv` first on PATH stands in for vmsdk.py, so no VM, network or ssh is
# touched; what is pinned is the argument contract and the refusals before vmsdk.
#
# Platform guard (linux-only): a bash test harness, no .ps1 twin.
#
# Usage: bash scripts/vm/test-guest-exec.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/guest-exec.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-guest-exec.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# the stub prints each argument on its own line and exits with $STUB_RC
cat > "$WORK/bin/uv" <<'STUB'
#!/usr/bin/env bash
printf 'ARG:%s\n' "$@"
exit "${STUB_RC:-0}"
STUB
chmod +x "$WORK/bin/uv"

FAILED=0
CASES=0
check() { # label, then the condition as a command
    local label="$1"; shift
    CASES=$((CASES + 1))
    if "$@"; then echo "PASS $label"; else echo "FAIL $label"; FAILED=$((FAILED + 1)); fi
}
run() { PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$@" 2>"$WORK/err"; }
# shellcheck disable=SC2329  # invoked indirectly through check()
rc_is() { [ "$rc" -eq "$1" ]; }
# shellcheck disable=SC2329  # invoked indirectly through check()
quiet() { [ -z "$out" ]; }

[ -f "$SCRIPT" ] || { echo "FAIL $SCRIPT not found"; exit 1; }

out=$(run); rc=$?
check "no arguments exits 2" rc_is 2
check "no arguments prints the usage line" grep -q 'usage: guest-exec.sh' "$WORK/err"

out=$(run 'ubuntu_new;id' -- ls); rc=$?
check "a vm name with shell metacharacters exits 2" rc_is 2
check "a bad vm name never reaches vmsdk" quiet

out=$(run ubuntu_new ls); rc=$?
check "missing -- exits 2" rc_is 2

out=$(run ubuntu_new --); rc=$?
check "no command after -- exits 2" rc_is 2
check "no command after -- never reaches vmsdk" quiet

out=$(run ubuntu_new --sudo --timeout 900 -- apt-get install -y git); rc=$?
want=$'ARG:run\nARG:'"$REPO_ROOT"$'/scripts/lib/vmsdk.py\nARG:ubuntu_new\nARG:exec\nARG:--sudo\nARG:--timeout\nARG:900\nARG:--\nARG:apt-get\nARG:install\nARG:-y\nARG:git'
check "a valid call exits 0" rc_is 0
check "passes vm, exec, flags and command to vmsdk verbatim" [ "$out" = "$want" ]

out=$(run ubuntu_new -- 'echo a | cat; echo b'); rc=$?
check "a payload with shell syntax stays one argument" [ "$(printf '%s\n' "$out" | tail -1)" = 'ARG:echo a | cat; echo b' ]

out=$(run ubuntu_new -- echo --); rc=$?
check "a payload ending in -- is still a command" rc_is 0
check "a payload ending in -- reaches vmsdk intact" [ "$(printf '%s\n' "$out" | tail -2 | tr '\n' ' ')" = 'ARG:echo ARG:-- ' ]

out=$(STUB_RC=7 run ubuntu_new -- false); rc=$?
check "propagates the guest rc" rc_is 7

echo ""
echo "guest-exec: $CASES cases"
if [ "$FAILED" -eq 0 ]; then echo "All cases passed."; exit 0; fi
echo "$FAILED case(s) failed."
exit 1
