#!/usr/bin/env bash
# test-vm-maintain.sh - hermetic coverage for scripts/vm/vm-maintain.sh.
# Stubs stand in for guest-exec.sh, vmsdk.py, VBoxManage and the operator alert sender, so
# no VM, network or ssh is touched. What is real: the pins (read from installer-pins.sh and
# cli-proxy-lane.sh as shipped), vm-lock.sh, cadence-alert.sh, and the guest-side login probe
# (the stub runs it locally against a fake guest HOME whose credential files have the field
# names of the real ~/.claude/.credentials.json, ~/.codex/auth.json and ~/.cli-proxy-api/codex-*.json).
# Each success check is shown to FAIL on a broken run (the RED controls).
#
# Platform guard (linux-only): a bash test harness for the Linux station's VirtualBox flow.
#
# Usage: bash scripts/vm/test-vm-maintain.sh
# shellcheck disable=SC2016  # the bash -c check bodies are single-quoted on purpose: they read their own $1..$3
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/vm-maintain.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-maintain.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/calls.log"
VM=testvm

FAILED=0
CASES=0
check() { # label, then the condition as a command
    local label="$1"; shift
    CASES=$((CASES + 1))
    if "$@"; then echo "PASS $label"; else echo "FAIL $label"; FAILED=$((FAILED + 1)); fi
}
# control label, then a check command that must FAIL on the broken run
control() {
    local label="$1"; shift
    CASES=$((CASES + 1))
    if "$@"; then echo "FAIL $label (the check passed on a broken run)"; FAILED=$((FAILED + 1)); else echo "PASS $label"; fi
}

[ -f "$SCRIPT" ] || { echo "FAIL $SCRIPT not found"; echo "RESULT: 0 passed, 1 failed"; exit 1; }

# --- the real pins, read the way the script reads them -----------------------------------
CLAUDE_VER=$(sed -n 's/^CLAUDE_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/machine-setup/installer-pins.sh")
CLAUDE_SHA=$(sed -n 's/^CLAUDE_LINUX_X64_SHA256="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/machine-setup/installer-pins.sh")
PROXY_VER=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/setup/cli-proxy-lane.sh" | head -n1)
PROXY_SHA=$(sed -n 's/^ASSET_SHA256="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/setup/cli-proxy-lane.sh" | head -n1)
[ -n "$CLAUDE_VER" ] && [ -n "$CLAUDE_SHA" ] && [ -n "$PROXY_VER" ] && [ -n "$PROXY_SHA" ] \
    || { echo "FAIL could not read the shipped pins"; exit 1; }

# --- stubs -------------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/guest-exec" <<'STUB'
#!/usr/bin/env bash
# args: <vm> [--sudo] [--timeout N] -- <cmd>
echo "guest $*" >> "$LOG"
# the real guest-exec.sh needs a literal -- argument with a command after it
seen=0; after=0
for a in "$@"; do if [ "$seen" -eq 1 ]; then after=$((after + 1)); elif [ "$a" = "--" ]; then seen=1; fi; done
if [ "$seen" -ne 1 ] || [ "$after" -lt 1 ]; then echo "usage: guest-exec.sh <vm> [--sudo] [--timeout N] -- <cmd> [args...]" >&2; exit 2; fi
all="$*"; cmd="${all#*-- }"
case "$cmd" in
    *PROBE-CREDS*) [ -n "${STUB_PROBE_EMPTY:-}" ] && exit 0; HOME="$FAKE_HOME" bash -c "$cmd"; exit $? ;;
esac
if [ -n "${FAIL_STEP:-}" ] && [[ "$cmd" == *"$FAIL_STEP"* ]]; then echo "E: stub failure at $FAIL_STEP"; exit 100; fi
case "$cmd" in
    *'; claude --version') echo "${STUB_CLAUDE_VERSION:-$CLAUDE_VER} (Claude Code)" ;;
    *'; codex --version') echo "codex-cli ${STUB_CODEX_VERSION:-0.99.0}" ;;
    *cli-proxy-api.version*) echo "${STUB_PROXY_VERSION:-$PROXY_VER}" ;;
esac
exit 0
STUB
cat > "$WORK/bin/vmsdk" <<'STUB'
#!/usr/bin/env bash
# args: <vm> <verb> ...
echo "sdk $*" >> "$LOG"
if [ -n "${FAIL_SDK:-}" ] && [ "$2" = "$FAIL_SDK" ]; then echo "stub vmsdk failure: $2" >&2; exit 1; fi
[ "$2" = snapshot ] && echo "SnapshotName-9=\"$3\"" >> "$SNAPS"
exit 0
STUB
cat > "$WORK/bin/vbox" <<'STUB'
#!/usr/bin/env bash
echo "vbox $*" >> "$LOG"
case "$*" in
    "snapshot $VM list --machinereadable") [ -n "${STUB_LIST_FAIL:-}" ] && exit 1; cat "$SNAPS" ;;
    "snapshot $VM delete "*) grep -vF "\"${*##* }\"" "$SNAPS" > "$SNAPS.new"; mv "$SNAPS.new" "$SNAPS" ;;
esac
exit 0
STUB
cat > "$WORK/bin/sender" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$SENT"
exit 0
STUB
chmod +x "$WORK"/bin/*

# --- fixtures ----------------------------------------------------------------------------
reset_snaps() {
    cat > "$SNAPS" <<'EOF'
SnapshotName="suite-ready-v4"
SnapshotName-1="claudex-base"
SnapshotName-1-1="maint-20261101-0000"
SnapshotName-2="maint-20261103-0000"
SnapshotName-3="maint-20261105-0000"
CurrentSnapshotName="maint-20261105-0000"
EOF
}
# mkhome <dir> <claude: live|dead|none> <codex: live|none> <proxy: live|none>
mkhome() {
    local d="$1" now_ms future past
    now_ms=$(( $(date +%s) * 1000 )); future=$(( now_ms + 30 * 86400000 )); past=$(( now_ms - 86400000 ))
    rm -rf "$d"; mkdir -p "$d/.claude" "$d/.codex" "$d/.cli-proxy-api"
    case "$2" in
        live) printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":%s,"refreshTokenExpiresAt":%s,"scopes":[],"subscriptionType":"max"}}' "$past" "$future" > "$d/.claude/.credentials.json" ;;
        dead) printf '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":%s,"refreshTokenExpiresAt":%s,"scopes":[],"subscriptionType":"max"}}' "$past" "$past" > "$d/.claude/.credentials.json" ;;
    esac
    [ "$3" = live ] && printf '{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"i","access_token":"a","refresh_token":"r","account_id":"x"},"last_refresh":"2026-11-06T00:55:18Z"}' > "$d/.codex/auth.json"
    [ "$4" = live ] && printf '{"access_token":"a","disabled":false,"expired":"2026-11-13T14:25:54+01:00","refresh_token":"r","type":"codex"}' > "$d/.cli-proxy-api/codex-1-x.json"
    return 0
}
fresh() { # one clean world: logs, state, snapshots, lock dir, alert files
    rm -rf "$WORK/state" "$WORK/lock" "$WORK/alerts"; mkdir -p "$WORK/state" "$WORK/lock" "$WORK/alerts"
    : > "$LOG"; : > "$WORK/sent"; reset_snaps
    mkhome "$WORK/home" live live live
}
# vm_maintain <args...>: the script under test with every seam pointed at the stubs
vm_maintain() {
    env LOG="$LOG" SNAPS="$SNAPS" VM="$VM" SENT="$WORK/sent" FAKE_HOME="$WORK/home" \
        CLAUDE_VER="$CLAUDE_VER" PROXY_VER="$PROXY_VER" \
        VM_MAINTAIN_GUEST_EXEC="$WORK/bin/guest-exec" VM_MAINTAIN_VMSDK="$WORK/bin/vmsdk" \
        VM_MAINTAIN_VBOX="$WORK/bin/vbox" VM_MAINTAIN_STATE_DIR="$WORK/state" \
        VM_MAINTAIN_NOW="20261107-1432" HIMMEL_VM_LOCK_DIR="$WORK/lock" \
        CADENCE_ALERT_FILE="$WORK/alerts/log" CADENCE_ALERT_DEDUPE_DIR="$WORK/alerts/sent" \
        CADENCE_ALERT_SEND_CMD="$WORK/bin/sender" CADENCE_ALERT_SEND_FAILED_MARK="$WORK/alerts/mark" \
        "$@" bash "$SCRIPT" "${ARGS[@]}"
}
SNAPS="$WORK/snaps"
ARGS=()

# --- checks ------------------------------------------------------------------------------
line_of() { grep -n -m1 -F -e "$1" "$LOG" | cut -d: -f1; }
in_order() { # in_order <fragment>...: each fragment appears in the call log, in this order
    local prev=0 n f
    for f in "$@"; do
        n=$(line_of "$f"); [ -n "$n" ] && [ "$n" -gt "$prev" ] || { echo "  order: '$f' (line ${n:-none}) not after line $prev" >&2; return 1; }
        prev=$n
    done
}
logged() { grep -qF -e "$1" "$LOG"; }
not_logged() { ! grep -qF -e "$1" "$LOG"; }
run_ok_check() { # a full maintenance run: updated, snapshotted, recorded, pruned
    [ "$rc" -eq 0 ] \
      && in_order "sdk $VM up" "apt-get update" "apt-get -y upgrade" "$CLAUDE_VER" "@openai/codex" "$PROXY_VER" "sdk $VM down" "sdk $VM snapshot maint-20261107-1432" \
      && grep -q "^$VM	maint-20261107-1432	" "$WORK/state/newest-good.tsv" 2>/dev/null
}
stopped_check() { # an update failed: named failure, no snapshot, nothing recorded, VM powered off last
    [ "$rc" -ne 0 ] && grep -q "FAILED $1" <<<"$out" && not_logged "sdk $VM snapshot" \
      && [ ! -s "$WORK/state/newest-good.tsv" ] && [ "$(grep '^sdk' "$LOG" | tail -n1)" = "sdk $VM down" ]
}
rc_is() { [ "$rc" -eq "$1" ]; }
out_has() { grep -qF -e "$1" <<<"$out"; }
out_lacks() { ! grep -qF -e "$1" <<<"$out"; }
sent_count() { [ "$(wc -l < "$WORK/sent" | tr -d ' ')" -eq "$1" ]; }

# ---------------------------------------------------------------- run: update + snapshot
echo "== run =="
ARGS=(run "$VM" --no-secret-scan)
fresh; out=$(vm_maintain 2>&1); rc=$?
check "R1 a run updates apt, claude, codex, cli-proxy, powers off, snapshots under a dated name and records it" run_ok_check
check "R2 claude is installed at the shipped pin and its shipped sha256" logged "$CLAUDE_SHA"
check "R3 cli-proxy is installed at the shipped pin and its shipped sha256" logged "$PROXY_SHA"
check "R4 the snapshot is taken powered off, so it names --no-secret-scan" logged "sdk $VM snapshot maint-20261107-1432 --no-secret-scan"
check "R5 the oldest maint-* snapshot beyond the last 3 is deleted" logged "vbox snapshot $VM delete maint-20261101-0000"
check "R6 snapshots that are not maint-* are never deleted" not_logged "delete suite-ready-v4"
check "R7 only one prune happens when four maint-* exist" test "$(grep -c 'vbox snapshot .* delete' "$LOG")" -eq 1
check "R8 the vm-lock is released after the run" test ! -e "$WORK/lock/himmel-vm-lock-$VM"
# RED control: a run whose snapshot fails must make R1's check fail
fresh; out=$(vm_maintain FAIL_SDK=snapshot 2>&1); rc=$?
control "R1-RED the run check fails when the snapshot step fails" run_ok_check

# ---------------------------------------------------------------- run: named failure
echo "== named failure =="
for step in "apt-get update:apt-update" "apt-get -y upgrade:apt-upgrade" "@openai/codex:codex-update"; do
    frag="${step%%:*}"; name="${step##*:}"
    fresh; out=$(vm_maintain FAIL_STEP="$frag" 2>&1); rc=$?
    check "F-$name an update failing stops the run with FAILED $name, no snapshot, VM powered off" stopped_check "$name"
done
fresh; out=$(vm_maintain FAIL_STEP="downloads.claude.ai" 2>&1); rc=$?
check "F-claude-update a failing claude install stops with FAILED claude-update" stopped_check claude-update
fresh; out=$(vm_maintain STUB_CLAUDE_VERSION=0.0.1 2>&1); rc=$?
check "F-claude-version an install that exits 0 but leaves the wrong claude version is FAILED claude-update" stopped_check claude-update
fresh; out=$(vm_maintain STUB_PROXY_VERSION=0.0.1 2>&1); rc=$?
check "F-proxy-version a wrong cli-proxy version stamp is FAILED cli-proxy-update" stopped_check cli-proxy-update
fresh; out=$(vm_maintain FAIL_SDK=up 2>&1); rc=$?
check "F-boot a VM that will not boot stops with FAILED boot and is still powered off" stopped_check boot
fresh; out=$(vm_maintain FAIL_SDK=snapshot 2>&1); rc=$?
check "F-snapshot a failed snapshot is FAILED snapshot and records nothing" bash -c '[ "$1" -ne 0 ] && grep -q "FAILED snapshot" <<<"$2" && [ ! -s "$3/newest-good.tsv" ]' _ "$rc" "$out" "$WORK/state"
fresh; echo "$VM	maint-20261105-0000	2026-11-05T00:00:00Z" > "$WORK/state/newest-good.tsv"; out=$(vm_maintain FAIL_STEP="apt-get -y upgrade" 2>&1); rc=$?
check "F-keeps-old a failed run leaves the previous newest-good record untouched" grep -q "maint-20261105-0000" "$WORK/state/newest-good.tsv"
fresh; out=$(vm_maintain STUB_LIST_FAIL=1 2>&1); rc=$?
check "F-list a failed snapshot listing is reported, not read as an empty set" bash -c '[ "$1" -eq 0 ] && grep -q "could not list" <<<"$2"' _ "$rc" "$out"
if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP F-record-read (root reads a mode-000 file, so the case cannot fail here)"
else
    fresh; printf '%s\t%s\t%s\n' "$VM" maint-20261105-0000 2026-11-05T00:00:00Z > "$WORK/state/newest-good.tsv"; chmod 000 "$WORK/state/newest-good.tsv"
    out=$(vm_maintain 2>&1); rc=$?; chmod 600 "$WORK/state/newest-good.tsv"
    check "F-record-read an unreadable record file is FAILED snapshot and the file is left as it was" bash -c '[ "$1" -ne 0 ] && grep -q "FAILED snapshot" <<<"$2" && grep -q "maint-20261105-0000" "$3"' _ "$rc" "$out" "$WORK/state/newest-good.tsv"
fi
fresh; out=$(vm_maintain 2>&1); ARGS=(run othervm --no-secret-scan); out=$(vm_maintain 2>&1); rc=$?; ARGS=(run "$VM" --no-secret-scan)
check "R9 a run for a second VM keeps the first VM's record" bash -c '[ "$(grep -c . "$1")" -eq 2 ] && grep -q "^testvm	" "$1" && grep -q "^othervm	" "$1"' _ "$WORK/state/newest-good.tsv"
# RED control: the stopped check fails on a run that succeeded
fresh; out=$(vm_maintain 2>&1); rc=$?
control "F-RED the stopped check fails on a run that did not stop" stopped_check apt-upgrade

# ---------------------------------------------------------------- lock: one VM at a time
echo "== lock =="
fresh
out=$(bash -c "export HIMMEL_VM_LOCK_DIR='$WORK/lock'; . '$REPO_ROOT/scripts/vm/vm-lock.sh'; vm_lock_acquire '$VM' >/dev/null 2>&1 || exit 9
  env -u HIMMEL_VM_LOCK_HELD LOG='$LOG' SNAPS='$SNAPS' VM='$VM' VM_MAINTAIN_GUEST_EXEC='$WORK/bin/guest-exec' VM_MAINTAIN_VMSDK='$WORK/bin/vmsdk' \
      VM_MAINTAIN_VBOX='$WORK/bin/vbox' VM_MAINTAIN_STATE_DIR='$WORK/state' HIMMEL_VM_LOCK_DIR='$WORK/lock' \
      bash '$SCRIPT' run '$VM' --no-secret-scan" 2>&1); rc=$?
check "L1 a held vm-lock refuses the run with FAILED lock" bash -c '[ "$1" -ne 0 ] && grep -q "FAILED lock" <<<"$2"' _ "$rc" "$out"
check "L2 a refused run touches nothing: no vmsdk or guest call" test ! -s "$LOG"

# ---------------------------------------------------------------- probe
echo "== probe =="
ARGS=(probe "$VM")
fresh; out=$(vm_maintain 2>&1); rc=$?
check "P1 all logins live: exit 0" rc_is 0
check "P2 all logins live: silent on stdout and stderr" test -z "$out"
check "P3 all logins live: no operator page" sent_count 0
check "P4 the probe makes no model call: only up, probe command, down" bash -c '[ "$(grep -c "^guest" "$1")" -eq 1 ] && ! grep -qE "claude -p|--print" "$1"' _ "$LOG"

fresh; mkhome "$WORK/home" dead live none; out=$(vm_maintain 2>&1); rc=$?
check "P5 an expired claude login exits 1" rc_is 1
check "P6 the report names the CLI and the exact claude login command" bash -c 'grep -q "claude.*EXPIRED" <<<"$1" && grep -qF "claude auth login" <<<"$1"' _ "$out"
check "P7 the report names the cli-proxy login that is missing, with its exact command" bash -c 'grep -q "cli-proxy.*EXPIRED" <<<"$1" && grep -qF -e "-codex-device-login" <<<"$1"' _ "$out"
check "P8 a live codex login is not reported" out_lacks "codex EXPIRED"
check "P9 the operator is paged once per expired CLI (claude and cli-proxy)" sent_count 2
out=$(vm_maintain 2>&1); rc=$?
check "P10 a repeat probe of the same dead logins pages nobody again" sent_count 2
check "P11 a repeat probe still reports on stdout (the page is deduped, the report is not)" out_has "claude auth login"
mkhome "$WORK/home" live live live; out=$(vm_maintain 2>&1); rc=$?
check "P12 once the login is live again the probe is silent and re-arms the page" bash -c '[ "$1" -eq 0 ] && [ -z "$2" ]' _ "$rc" "$out"
mkhome "$WORK/home" dead live live; out=$(vm_maintain 2>&1); rc=$?
check "P13 a login that dies again pages again" sent_count 3
# RED control: P6's report check fails on a live run
mkhome "$WORK/home" live live live; out=$(vm_maintain 2>&1); rc=$?
control "P-RED the expired-report check fails when every login is live" bash -c 'grep -q "claude.*EXPIRED" <<<"$1" && grep -qF "claude auth login" <<<"$1"' _ "$out"

fresh; out=$(vm_maintain STUB_PROBE_EMPTY=1 2>&1); rc=$?
check "P15 a probe command that prints no result is FAILED probe, never read as healthy" bash -c '[ "$1" -ne 0 ] && grep -q "FAILED probe" <<<"$2"' _ "$rc" "$out"
fresh; mkhome "$WORK/home" none none none; out=$(vm_maintain 2>&1); rc=$?
check "P14 a guest with no login files reports all three CLIs" bash -c 'grep -q "claude.*EXPIRED" <<<"$1" && grep -q "codex.*EXPIRED" <<<"$1" && grep -q "cli-proxy.*EXPIRED" <<<"$1"' _ "$out"

# ---------------------------------------------------------------- usage
echo "== usage =="
ARGS=(); fresh; out=$(vm_maintain 2>&1); rc=$?
check "U1 no verb exits 2 with the usage line" bash -c '[ "$1" -eq 2 ] && grep -q "usage: vm-maintain.sh" <<<"$2"' _ "$rc" "$out"
ARGS=(run 'bad;vm'); out=$(vm_maintain 2>&1); rc=$?
check "U2 a vm name with shell metacharacters exits 2 before any call" bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ]' _ "$rc" "$LOG"

echo "RESULT: $((CASES - FAILED)) passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
