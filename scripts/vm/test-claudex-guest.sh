#!/usr/bin/env bash
# test-claudex-guest.sh - hermetic coverage for scripts/vm/claudex-guest.sh.
# A counting fake VBoxManage and a stub `uv` stand in for VirtualBox and vmsdk, so no VM,
# network or ssh is touched. Pinned: the clone-name allowlist, the usage refusals, the
# VBoxManage opt-in guard, and that `status` runs claude-codex --version through guest-exec.
#
# Platform guard (linux-only): a bash test harness.
#
# Usage: bash scripts/vm/test-claudex-guest.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/claudex-guest.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-claudex-guest.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/VBoxManage" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_VBOX_CALLS:?}"
exit 0
STUB
cat > "$WORK/bin/uv" <<'STUB'
#!/usr/bin/env bash
printf 'ARG:%s\n' "$@"
exit "${STUB_RC:-0}"
STUB
chmod +x "$WORK/bin/VBoxManage" "$WORK/bin/uv"
CALLS="$WORK/vbox-calls"; : > "$CALLS"

FAILED=0
check() { # label, then the condition as a command
    local label="$1"; shift
    if "$@"; then echo "PASS $label"; else echo "FAIL $label"; FAILED=$((FAILED + 1)); fi
}
run() {
    env -u HIMMEL_VM_AR_LIVE PATH="$WORK/bin:$PATH" FAKE_VBOX_CALLS="$CALLS" \
        VBOXMANAGE_PATH="$WORK/bin/VBoxManage" HIMMEL_VM_PYTHON="$(command -v python3)" \
        bash "$SCRIPT" "$@" 2>"$WORK/err"
}
# shellcheck disable=SC2329  # invoked indirectly through check()
rc_is() { [ "$rc" -eq "$1" ]; }
# shellcheck disable=SC2329  # invoked indirectly through check()
no_vbox_calls() { [ ! -s "$CALLS" ]; }

[ -f "$SCRIPT" ] || { echo "FAIL $SCRIPT not found"; exit 1; }

for bad in ubuntu_new himmel-ar-x himmel-ar-0 himmel-ar-2x 'himmel-ar-2;id' himmel-ci-1 himmel-claudex; do
    for verb in up down provision status; do
        out=$(run "$verb" "$bad"); rc=$?
        check "$verb $bad exits 2" rc_is 2
        check "$verb $bad touches no VM" no_vbox_calls
    done
done

out=$(run); rc=$?
check "no arguments exits 2" rc_is 2
out=$(run bogus himmel-ar-2); rc=$?
check "an unknown verb exits 2" rc_is 2
out=$(run snapshot himmel-ar-2); rc=$?
check "snapshot without a name exits 2" rc_is 2
out=$(run up himmel-ar-2 'x;rm -rf /'); rc=$?
check "a snapshot name with shell syntax exits 2" rc_is 2
check "a refused snapshot name touches no VM" no_vbox_calls

out=$(env -u VBOXMANAGE_PATH -u HIMMEL_VM_AR_LIVE PATH="$WORK/bin:$PATH" FAKE_VBOX_CALLS="$CALLS" \
    HIMMEL_VM_PYTHON="$(command -v python3)" bash "$SCRIPT" up himmel-ar-2 2>&1); rc=$?
check "up without VBOXMANAGE_PATH refuses (rc 1)" rc_is 1
check "up without VBOXMANAGE_PATH names the opt-in" grep -q 'refusing to fall through' <<< "$out"
check "up without VBOXMANAGE_PATH never reaches VBoxManage" no_vbox_calls

out=$(run status himmel-ar-2); rc=$?
want=$'ARG:run\nARG:'"$REPO_ROOT"$'/scripts/lib/vmsdk.py\nARG:himmel-ar-2\nARG:exec\nARG:--\nARG:claude-codex\nARG:--version'
check "status exits 0 when the guest command does" rc_is 0
check "status runs claude-codex --version through guest-exec" [ "$out" = "$want" ]
out=$(STUB_RC=127 run status himmel-ar-2); rc=$?
check "status passes the guest exit code through" rc_is 127

out=$(run provision himmel-ar-2); rc=$?
sdk_calls=$(grep -c '^ARG:run$' <<< "$out")
order=$(grep -E '^ARG:(clone|push|exec)$' <<< "$out" | tr '\n' ' ')
check "provision exits 0" rc_is 0
check "provision runs clone, push, then exec through vmsdk" [ "$order" = 'ARG:clone ARG:push ARG:exec ' ]
check "provision runs exactly three vmsdk verbs" [ "$sdk_calls" -eq 3 ]
check "provision pushes the guest-side script" grep -qF "ARG:$REPO_ROOT/scripts/vm/claudex-guest-provision.sh" <<< "$out"
check "provision runs the pushed script on the guest" grep -qxF 'ARG:~/claudex-guest-provision.sh' <<< "$out"
out=$(STUB_RC=3 run provision himmel-ar-2); rc=$?
check "provision stops at a failed clone with its exit code" rc_is 3
check "provision pushes nothing after a failed clone" [ "$(grep -c '^ARG:run$' <<< "$out")" -eq 1 ]

echo "RESULT: $FAILED failure(s)"
[ "$FAILED" -eq 0 ]
