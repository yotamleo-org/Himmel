#!/usr/bin/env bash
# test-claudex-guest.sh - hermetic coverage for scripts/vm/claudex-guest.sh and the
# himmel-claudex row of scripts/lib/vms.json.
# No real VM, network or session bus: HIMMEL_VMSDK points at a stub that runs each
# guest command locally under a fake guest HOME and logs argv and stdin; VBoxManage,
# the venv python behind vbox_py, uv, claude, curl, node and systemctl are stubs, and
# the fake guest ~/himmel holds stub cli-proxy-lane.sh and claude-codex scripts.
#
# Platform guard (linux-only): flock-based vm-lock + a bash harness.
#
# Usage: bash scripts/vm/test-claudex-guest.sh
# shellcheck disable=SC2016,SC2317,SC2329  # stub bodies are single-quoted on purpose; check() invokes helpers indirectly
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/claudex-guest.sh"
VMS_JSON="$REPO_ROOT/scripts/lib/vms.json"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-claudex-guest.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
check() { # label, then the condition as a command
    local label="$1"; shift
    if "$@"; then echo "PASS $label"; else echo "FAIL $label"; FAILED=$((FAILED + 1)); fi
}

BIN="$WORK/bin"          # station-side stubs
GBIN="$WORK/gbin"        # guest-side stubs
STATE="$WORK/vbox-state"
mkdir -p "$BIN" "$GBIN" "$STATE" "$WORK/locks"
export TMPDIR_FOR_STUBS="$WORK"

# --- station-side stubs ----------------------------------------------------------
# uv: `uv run <sdk> <args>` runs the sdk stub with python3 (guest-exec.sh and the
# provisioner both prefer uv when it is on PATH).
cat > "$BIN/uv" <<'EOS'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
shift
exec python3 -I "$@"
EOS
# VBoxManage: list/showvminfo read the state dir; clonevm registers the new name; snapshot take records it.
cat > "$BIN/VBoxManage" <<'EOS'
#!/usr/bin/env bash
echo "VBoxManage $*" >> "${FAKE_VBOX_LOG:?}"
case "$1" in
    list)
        while read -r n; do [ -n "$n" ] && printf '"%s" {00000000-0000-0000-0000-000000000000}\n' "$n"; done < "$FAKE_VBOX_STATE/vms" ;;
    showvminfo)
        f="$FAKE_VBOX_STATE/fwd-$2"
        [ -f "$f" ] && printf 'name="%s"\nForwarding(0)="ssh,tcp,127.0.0.1,%s,,22"\n' "$2" "$(cat "$f")" ;;
    clonevm)
        name=""
        while [ "$#" -gt 0 ]; do [ "$1" = --name ] && name="$2"; shift; done
        echo "$name" >> "$FAKE_VBOX_STATE/vms" ;;
    snapshot)
        [ "$3" = take ] && echo "$4" >> "$FAKE_VBOX_STATE/snaps-$2" ;;
esac
exit 0
EOS
# vbox_py runs $HIMMEL_VM_PYTHON -c <code> <repo_root> <argv...>: this stub keys on the vbox.<fn> in the code.
cat > "$BIN/vbox-python" <<'EOS'
#!/usr/bin/env bash
code="$2"; shift 3
echo "vbox_py $(grep -o 'vbox\.[a-z_]*' <<< "$code" | tr '\n' ' ')| $*" >> "${FAKE_VBOX_LOG:?}"
case "$code" in
    *list_snapshots*) grep -qxF "$2" "$FAKE_VBOX_STATE/snaps-$1" 2>/dev/null ;;
    *take_snapshot*) echo "$2" >> "$FAKE_VBOX_STATE/snaps-$1" ;;
    *ensure_persistent_forward*) echo "$2" > "$FAKE_VBOX_STATE/fwd-$1" ;;
    *get_forwards*) [ -f "$FAKE_VBOX_STATE/fwd-$1" ] && cat "$FAKE_VBOX_STATE/fwd-$1" ;;
    *) exit 0 ;;
esac
EOS
# vmsdk stub: `exec` runs the command in bash under the fake guest HOME; `clone` only logs.
cat > "$WORK/vmsdk-stub.py" <<'EOS'
import os, subprocess, sys
a = sys.argv[1:]
vm, verb, rest = a[0], a[1], a[2:]
stdin = "" if sys.stdin.isatty() else sys.stdin.read()
with open(os.environ["FAKE_VMSDK_LOG"], "a") as f:
    f.write("VMSDK %s\n" % " ".join(a))
    f.write("STDIN %r\n" % stdin)
if verb == "exec":
    cmd = " ".join(rest[rest.index("--") + 1:])
    home = os.environ["FAKE_GUEST_HOME"]
    env = {"PATH": os.environ["FAKE_GUEST_PATH"], "HOME": home,
           "GUEST_TOOL_LOG": os.environ["GUEST_TOOL_LOG"],
           "GUEST_STATUS_FILE": os.environ["GUEST_STATUS_FILE"],
           "GUEST_PREFLIGHT_RC_FILE": os.environ["GUEST_PREFLIGHT_RC_FILE"]}
    p = subprocess.run(["bash", "-c", cmd], cwd=home, env=env, input=stdin,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    sys.stdout.write(p.stdout)
    sys.exit(p.returncode)
if verb == "clone":
    sys.exit(0)
sys.exit(2)
EOS
chmod +x "$BIN"/*

# --- guest-side stubs (each logs its argv; nothing reaches a network or a session bus) ---
cat > "$GBIN/claude" <<'EOS'
#!/usr/bin/env bash
echo "claude $*" >> "$GUEST_TOOL_LOG"
case "$1" in
    --version) echo "2.1.314 (Claude Code)" ;;
    install) mkdir -p "$HOME/.local/bin"; cp "$0" "$HOME/.local/bin/claude" ;;
esac
exit 0
EOS
for t in curl systemctl; do
    cat > "$GBIN/$t" <<EOS
#!/usr/bin/env bash
echo "$t \$*" >> "\$GUEST_TOOL_LOG"
exit 0
EOS
done
cat > "$GBIN/node" <<'EOS'
#!/usr/bin/env bash
echo "node $*" >> "$GUEST_TOOL_LOG"
echo '{"enabledPlugins":{}}'
EOS
chmod +x "$GBIN"/*

# --- fixtures: the station HOME (canaries at the real readers' paths) and a primary checkout ---
STATION_HOME="$WORK/station-home"
CANARY_ENV="CANARY-ENV-$$-a1f3"; CANARY_CODEX="CANARY-CODEX-$$-b2e4"; CANARY_PROXY="CANARY-PROXY-$$-c3d5"
mkdir -p "$STATION_HOME/.codex" "$STATION_HOME/.cli-proxy-api" "$WORK/primary"
echo "{\"token\":\"$CANARY_CODEX\"}" > "$STATION_HOME/.codex/auth.json"
echo "{\"token\":\"$CANARY_PROXY\"}" > "$STATION_HOME/.cli-proxy-api/codex-x.json"
git -C "$WORK/primary" init -q . && echo "PAT=$CANARY_ENV" > "$WORK/primary/.env"

GH="$WORK/guest-home"
export FAKE_VBOX_LOG="$WORK/vbox.log" FAKE_VBOX_STATE="$STATE" FAKE_VMSDK_LOG="$WORK/vmsdk.log"
export GUEST_TOOL_LOG="$WORK/guest-tools.log" GUEST_STATUS_FILE="$WORK/status.out" GUEST_PREFLIGHT_RC_FILE="$WORK/preflight.rc"

new_world() { # fresh fake guest + station VirtualBox state; claudex-base present unless $1 = nobase
    rm -rf "$GH" "$STATE"; mkdir -p "$GH/himmel/scripts/setup" "$GH/himmel/scripts/lanes" "$STATE"
    : > "$FAKE_VBOX_LOG"; : > "$FAKE_VMSDK_LOG"; : > "$GUEST_TOOL_LOG"
    printf 'ubuntu_new\nhimmel-claudex\n' > "$STATE/vms"
    echo 2222 > "$STATE/fwd-ubuntu_new"; echo 2229 > "$STATE/fwd-himmel-claudex"
    [ "${1:-}" = nobase ] || echo claudex-base > "$STATE/snaps-himmel-claudex"
    # the post-clone repo: stub lane scripts that log argv (never real ones)
    cat > "$GH/himmel/scripts/setup/cli-proxy-lane.sh" <<'EOS'
#!/usr/bin/env bash
echo "cli-proxy-lane $* key-len=${#CLIPROXY_API_KEY}" >> "$GUEST_TOOL_LOG"
[ "$1" = --status ] && [ -e "$GUEST_STATUS_FILE.kill" ] && kill -9 "$PPID"
[ "$1" = --status ] && [ -e "$GUEST_STATUS_FILE.exit2" ] && exit 2
[ "$1" = --status ] && cat "$GUEST_STATUS_FILE"
[ "$1" = --status ] && [ -e "$GUEST_STATUS_FILE.exit1" ] && exit 1
exit 0
EOS
    cat > "$GH/himmel/scripts/claude-codex" <<'EOS'
#!/usr/bin/env bash
echo "claude-codex $*" >> "$GUEST_TOOL_LOG"
[ "$1" = --preflight-only ] && exit "$(cat "$GUEST_PREFLIGHT_RC_FILE")"
exit 0
EOS
    cat > "$GH/himmel/scripts/lanes/plugin-profiles.mjs" <<'EOS'
// stub: the stub node on PATH never reads it
EOS
    # login shells on the guest still find the stubs first
    printf 'PATH="%s:$PATH"; export PATH\n' "$GBIN" > "$GH/.profile"
    printf 'OK    key matches config.yaml\nrunning:     OK   127.0.0.1:8317\n' > "$GUEST_STATUS_FILE"
    echo 20 > "$GUEST_PREFLIGHT_RC_FILE"
}

run_cg() { # <args...>: the provisioner under a cleaned environment; sets out, rc
    out=$(cd "$WORK/primary" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$STATION_HOME" TMPDIR="$WORK" \
        VBOXMANAGE_PATH="$BIN/VBoxManage" HIMMEL_VM_PYTHON="$BIN/vbox-python" HIMMEL_VMSDK="$WORK/vmsdk-stub.py" \
        HIMMEL_VM_LOCK_DIR="$WORK/locks" HIMMEL_VM_AR_RAM_MB=1 HIMMEL_VM_AR_SSH_WAIT=5 \
        FAKE_VBOX_LOG="$FAKE_VBOX_LOG" FAKE_VBOX_STATE="$FAKE_VBOX_STATE" FAKE_VMSDK_LOG="$FAKE_VMSDK_LOG" \
        FAKE_GUEST_HOME="$GH" FAKE_GUEST_PATH="$GBIN:/usr/bin:/bin" GUEST_TOOL_LOG="$GUEST_TOOL_LOG" \
        GUEST_STATUS_FILE="$GUEST_STATUS_FILE" GUEST_PREFLIGHT_RC_FILE="$GUEST_PREFLIGHT_RC_FILE" \
        bash "$SCRIPT" "$@" < /dev/null 2>&1); rc=$?
}
rc_is() { [ "$rc" -eq "$1" ]; }
rc_nonzero() { [ "$rc" -ne 0 ]; }
no_guest_cmd() { ! grep -q '^VMSDK' "$FAKE_VMSDK_LOG"; }
out_has() { grep -qF -- "$1" <<< "$out"; }
guest_log_count() { grep -c -- "$1" "$GUEST_TOOL_LOG"; }

[ -f "$SCRIPT" ] || echo "NOTE $SCRIPT does not exist yet (RED)"

# --- R1: every verb refuses any VM name but himmel-claudex (exit 2), running no guest command ---
new_world
for verb in create provision status; do
    for vm in ubuntu_new himmel-claudex-x; do
        run_cg "$verb" "$vm"
        check "R1 $verb $vm exits 2" rc_is 2
        check "R1 $verb $vm ran no guest command" no_guest_cmd
    done
done
run_cg bogus himmel-claudex
check "R1 an unknown verb exits 2" rc_is 2

# --- R2: the real vms.json row is a test VM on a port nobody else uses ---
r2() {
    python3 -I - "$VMS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
row = d.get("himmel-claudex")
if not row or "kind" in row:
    sys.exit(1)
port = row.get("ssh_port")
others = [v.get("ssh_port") for k, v in d.items() if k != "himmel-claudex"]
sys.exit(0 if port == 2229 and port not in others else 1)
PY
}
check "R2 vms.json: himmel-claudex has no kind and a unique port 2229" r2

# --- R2b: provision before create (no claudex-base) refuses and runs no guest command ---
new_world nobase
run_cg provision himmel-claudex
check "R2b provision without claudex-base exits non-zero" rc_nonzero
check "R2b provision without claudex-base ran no guest command" no_guest_cmd

# --- create: clone at the fixed port, first boot, claudex-base; a second create changes nothing ---
new_world nobase
printf 'ubuntu_new\n' > "$STATE/vms"; rm -f "$STATE/fwd-himmel-claudex"
run_cg create himmel-claudex
check "create exits 0" rc_is 0
check "create clones suite-ready-v4 from ubuntu_new as himmel-claudex" \
    grep -q -- 'clonevm ubuntu_new --snapshot suite-ready-v4 --options link --name himmel-claudex --register' "$FAKE_VBOX_LOG"
check "create forwards fixed port 2229" test "$(cat "$STATE/fwd-himmel-claudex" 2>/dev/null)" = 2229
check "create takes the claudex-base snapshot" grep -qxF claudex-base "$STATE/snaps-himmel-claudex"
clones_before=$(grep -c clonevm "$FAKE_VBOX_LOG")
run_cg create himmel-claudex
check "a second create exits 0 and clones nothing" test "$rc" -eq 0 -a "$(grep -c clonevm "$FAKE_VBOX_LOG")" = "$clones_before"

# --- R3 + R4 + R5: a full provision, then again ---
new_world
run_cg provision himmel-claudex; prc1=$rc; pout1=$out
check "provision exits 0 (out: ${pout1:0:200})" test "$prc1" -eq 0
check "R3 cliproxy.key exists with mode 600" test "$(stat -c %a "$GH/.config/himmel/cliproxy.key" 2>/dev/null)" = 600 # gnu-ok: linux-only suite (see platform guard)
check "R3 no .env anywhere in the guest HOME" test -z "$(find "$GH" \( -name .env -o -name '.env.*' \) ! -name .env.example)"
check "provision installs claude 2.1.314 once" test "$(guest_log_count 'claude install 2.1.314')" = 1
check "provision writes {} settings" test "$(cat "$GH/.claude/settings.json" 2>/dev/null)" = '{}'
check "provision hands --install the key (non-empty)" grep -qE 'cli-proxy-lane --install key-len=[1-9]' "$GUEST_TOOL_LOG"
check "provision registers the lane" grep -q 'cli-proxy-lane --register' "$GUEST_TOOL_LOG"
check "provision writes the worker-impl settings file" grep -q 'enabledPlugins' "$GH/.config/himmel/worker-settings.json"
check "provision links the repo path" test "$(readlink "$GH/Documents/github/himmel")" = "$GH/himmel"
check "provision never touches curl or systemctl" test "$(guest_log_count -e '^curl' -e '^systemctl')" = 0
check "provision runs the clone through vmsdk" grep -q '^VMSDK himmel-claudex clone' "$FAKE_VMSDK_LOG"

has_canary() { # any canary in the given files / trees
    grep -rqF -e "$CANARY_ENV" -e "$CANARY_CODEX" -e "$CANARY_PROXY" "$@"
}
no_canary_leak() { # any logged argv/stdin, any guest file, any station-side log
    ! has_canary "$FAKE_VMSDK_LOG" "$FAKE_VBOX_LOG" "$GUEST_TOOL_LOG" "$GH"
}
echo "$CANARY_PROXY" > "$WORK/control.txt"
check "R4 control: the detector fires on a planted canary" has_canary "$WORK/control.txt"
check "R4 no station credential canary (primary .env, ~/.codex, ~/.cli-proxy-api) reaches the guest, a logged argv or stdin" no_canary_leak

key1=$(cat "$GH/.config/himmel/cliproxy.key")
prof1=$(cat "$GH/.profile")
run_cg provision himmel-claudex; prc2=$rc
check "R5 second provision exits 0" test "$prc2" -eq 0
check "R5 second provision keeps the key" test "$(cat "$GH/.config/himmel/cliproxy.key")" = "$key1"
check "R5 second provision appends no ~/.profile line" test "$(cat "$GH/.profile")" = "$prof1"
check "R5 the DISABLE_AUTOUPDATER line appears once" test "$(grep -c DISABLE_AUTOUPDATER "$GH/.profile")" = 1
check "R5 the key export line appears once" test "$(grep -c cliproxy.key "$GH/.profile")" = 1
check "R5 second provision does not reinstall claude" test "$(guest_log_count 'claude install')" = 1

# --- R5b: a scan hit stops provision before any clone or install ---
new_world
echo "SECRET=1" > "$GH/.env"
run_cg provision himmel-claudex
check "R5b a scan hit fails provision" rc_nonzero
check "R5b a scan hit names the file" out_has "$GH/.env"
check "R5b no clone ran" bash -c '! grep -q "^VMSDK himmel-claudex clone" "$1"' _ "$FAKE_VMSDK_LOG"
check "R5b no install ran" test "$(guest_log_count 'claude install')" = 0

# --- R5c: a 401 line from --status fails provision naming the key mismatch ---
new_world
printf 'running:     OK but UNAUTHENTICATED (HTTP 401) -> CLIPROXY_API_KEY doesn'"'"'t match config.yaml\n' > "$GUEST_STATUS_FILE"
run_cg provision himmel-claudex
check "R5c a 401 status line fails provision" rc_nonzero
check "R5c the failure names the key mismatch" out_has "key mismatch"

# --- a --status that dies before finishing (ssh drop, timeout, crash) is a failure, not "logged out" ---
new_world
touch "$GUEST_STATUS_FILE.kill"
run_cg provision himmel-claudex
check "provision fails when --status does not run to the end" rc_nonzero
check "that failure says --status did not finish" out_has "did not run to a normal end"
rm -f "$GUEST_STATUS_FILE.kill"
new_world
touch "$GUEST_STATUS_FILE.exit2"
run_cg provision himmel-claudex
check "provision fails when --status exits 2 (a crash, not 'not ready')" rc_nonzero
rm -f "$GUEST_STATUS_FILE.exit2"
new_world
touch "$GUEST_STATUS_FILE.exit1"
run_cg provision himmel-claudex
check "provision accepts --status exit 1 (not logged in yet)" rc_is 0

# the same two failures fail the status verb too
new_world
run_cg provision himmel-claudex >/dev/null 2>&1
touch "$GUEST_STATUS_FILE.kill"
run_cg status himmel-claudex
check "status fails when --status does not run to the end" rc_nonzero
rm -f "$GUEST_STATUS_FILE.kill"
touch "$GUEST_STATUS_FILE.exit2"
run_cg status himmel-claudex
check "status fails when --status exits 2" rc_nonzero
rm -f "$GUEST_STATUS_FILE.exit2"

# --- R5d: ~/Documents/github/himmel already a directory is refused and left alone ---
new_world
mkdir -p "$GH/Documents/github/himmel" && echo keep > "$GH/Documents/github/himmel/marker"
run_cg provision himmel-claudex
check "R5d an existing directory fails provision" rc_nonzero
check "R5d the directory is untouched" test "$(cat "$GH/Documents/github/himmel/marker" 2>/dev/null)" = keep -a ! -L "$GH/Documents/github/himmel"

# --- R7: status prints the --status output verbatim, parses no config ---
new_world
printf 'binary:      OK   /x\nUNIQUE-STATUS-LINE-%s\n' "$$" > "$GUEST_STATUS_FILE"
run_cg provision himmel-claudex >/dev/null 2>&1
: > "$FAKE_VMSDK_LOG"
run_cg status himmel-claudex
check "R7 status exits 0 (out: ${out:0:200})" rc_is 0
check "R7 status prints the lane status verbatim" out_has "UNIQUE-STATUS-LINE-$$"
check "R7 status reports claude 2.1.314 at ~/.local/bin/claude" out_has "$GH/.local/bin/claude"
check "R7 status reports the preflight exit code" out_has "preflight-exit: 20"
check "R7 status reads no config" bash -c '! grep -q "config.yaml" "$1"' _ "$FAKE_VMSDK_LOG"

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all passed"; exit 0; fi
echo "RESULT: $FAILED failure(s)"; exit 1
