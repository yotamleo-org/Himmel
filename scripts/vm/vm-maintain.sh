#!/usr/bin/env bash
# vm-maintain.sh - keep one himmel test VM current, snapshot it, and report a dead login.
#
# WHY: test VMs rot between uses. On 2026-11-07 a VM proof leg failed because every snapshot's
# Claude login had expired and the VM had no Codex or CLI proxy; nobody knew until a worker was
# launched. A pure-code run (no model turn, no paid call) fixes the packages and a probe names the
# login that needs the operator before a worker needs it.
#
#   vm-maintain.sh run   <vm> [--no-secret-scan]   one maintenance pass
#   vm-maintain.sh probe <vm>                      report a dead login, silent when all are live
#
# run: take the vm-lock, boot the VM from its CURRENT state (no restore), apt update + upgrade, bring
# claude to the pin in scripts/machine-setup/installer-pins.sh, codex to npm latest (himmel-update.sh's
# rule, there is no codex pin), the CLIProxyAPI binary to the pin in scripts/setup/cli-proxy-lane.sh,
# power off, snapshot IN PLACE as maint-YYYYMMDD-HHMM (never a clone: a snapshot may hold a login),
# record it, prune maint-* beyond the last $KEEP_DATED. Any failed step stops the run with
# "FAILED <step>", takes no snapshot, records nothing, and the VM is powered off on every exit path.
# Steps: lock boot apt-update apt-upgrade claude-update codex-update cli-proxy-update power-off snapshot.
#
# --no-secret-scan: vmsdk refuses to snapshot a powered-off VM it cannot scan for host .env files, so
# the DEFAULT run refuses at the snapshot step. The flag exists for the one run an operator makes
# after checking the VM holds no host copy (maintenance copies nothing from the host); it is a
# per-run choice, never a standing command and never in a schedule. The scan before power off
# (a vmsdk verb) is owed, so do not arm this on a cron without it.
#
# probe: boot, read the login files in the guest (a free check, no model turn), power off. Claude is
# expired when its refresh token is past refreshTokenExpiresAt (or absent with the access token past
# expiresAt); codex when ~/.codex/auth.json has no refresh token; cli-proxy when no enabled
# ~/.cli-proxy-api/codex-*.json carries one. "live" means "not provably expired": a token revoked
# server-side is only found by a real turn, which this probe never spends. The probe reads the VM's
# CURRENT state only; probing each saved snapshot is not done here. An expired login prints
# the exact command to run on the guest and pages the operator ONCE per CLI through
# scripts/luna/cadence-alert.sh (its dedupe sentinel); a live login clears that page, so a later
# death pages again. Probes the VM's current state (it is the newest snapshot right after a run).
#
# The newest good snapshot per VM lives in ONE file: $STATE_DIR/newest-good.tsv
# (default ~/.himmel/state/vm-maintain/newest-good.tsv), lines "<vm><TAB><snapshot><TAB><utc iso>".
#
# Waits behind other legs: export HIMMEL_VM_LOCK_WAIT=<seconds> (vm-lock.sh default 0 = refuse).
# Exit: 0 ok / all live; 1 FAILED step or an expired login; 2 usage or lock refused.
#
# Seams (tests): VM_MAINTAIN_GUEST_EXEC, VM_MAINTAIN_VMSDK, VM_MAINTAIN_VBOX, VM_MAINTAIN_ALERT,
# VM_MAINTAIN_STATE_DIR, VM_MAINTAIN_NOW (YYYYMMDD-HHMM), HIMMEL_VM_LOCK_DIR.
#
# Platform guard (linux-only): VirtualBox on the Linux station.
# shellcheck disable=SC2016  # the guest commands are single-quoted on purpose: $HOME expands in the guest
set -uo pipefail

KEEP_DATED=3         # maint-* snapshots kept per VM
SNAP_PREFIX="maint-"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GUEST_EXEC="${VM_MAINTAIN_GUEST_EXEC:-$HERE/guest-exec.sh}"
VBOX="${VM_MAINTAIN_VBOX:-${VBOXMANAGE_PATH:-VBoxManage}}"
ALERT="${VM_MAINTAIN_ALERT:-$ROOT/scripts/luna/cadence-alert.sh}"
STATE_DIR="${VM_MAINTAIN_STATE_DIR:-${HOME:-}/.himmel/state/vm-maintain}"
NEWEST="$STATE_DIR/newest-good.tsv"
GUEST_PATH='export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"'

usage() { echo "usage: vm-maintain.sh run <vm> [--no-secret-scan] | probe <vm>" >&2; exit 2; }
say() { echo "vm-maintain: $*"; }

sdk() {
    if [ -n "${VM_MAINTAIN_VMSDK:-}" ]; then "$VM_MAINTAIN_VMSDK" "$@"
    elif command -v uv >/dev/null 2>&1; then uv run "$ROOT/scripts/lib/vmsdk.py" "$@"
    else python3 "$ROOT/scripts/lib/vmsdk.py" "$@"; fi
}
guest() { bash "$GUEST_EXEC" "$VM" "$@"; }

[ "$#" -ge 2 ] || usage
MODE="$1"; VM="$2"; shift 2
case "$VM" in *[!A-Za-z0-9_-]*|'') echo "vm-maintain.sh: invalid vm name '$VM'" >&2; usage ;; esac
NO_SCAN=0
case "$MODE" in
    run) while [ $# -gt 0 ]; do
            case "$1" in --no-secret-scan) NO_SCAN=1 ;; *) usage ;; esac
            shift
         done ;;
    probe) [ $# -eq 0 ] || usage ;;
    *) usage ;;
esac

# --- the pins, read from the files that own them ---------------------------------------------
pin() { sed -n "s/^$2=\"\\(.*\\)\"\$/\\1/p" "$1" | head -n1; }
CLAUDE_VER="$(pin "$ROOT/scripts/machine-setup/installer-pins.sh" CLAUDE_VERSION)"
CLAUDE_SHA="$(pin "$ROOT/scripts/machine-setup/installer-pins.sh" CLAUDE_LINUX_X64_SHA256)"
PROXY_VER="$(pin "$ROOT/scripts/setup/cli-proxy-lane.sh" VERSION)"
PROXY_SHA="$(pin "$ROOT/scripts/setup/cli-proxy-lane.sh" ASSET_SHA256)"

# shellcheck source=../lib/prim.sh
. "$ROOT/scripts/lib/prim.sh" || { echo "vm-maintain.sh: cannot source prim.sh" >&2; exit 2; }

# --- lock + power-off on every exit path ------------------------------------------------------
# shellcheck source=vm-lock.sh
. "$HERE/vm-lock.sh" || { echo "vm-maintain.sh: cannot source vm-lock.sh" >&2; exit 2; }
HAVE_LOCK=0
BOOTED=0
OUT=
cleanup() {
    if [ "$BOOTED" -eq 1 ]; then sdk "$VM" down >/dev/null 2>&1 || say "WARNING: could not power $VM off in cleanup"; fi
    if [ "$HAVE_LOCK" -eq 1 ]; then vm_lock_release "$VM"; fi
}
trap cleanup EXIT

fail() { # fail <step> <detail>
    say "FAILED $1 ($VM) - $2"
    exit 1
}
acquire() {
    vm_lock_acquire_waiting "$VM"
    case $? in
        0) HAVE_LOCK=1 ;;
        5) say "FAILED lock ($VM) - timed out waiting for the vm-lock (HIMMEL_VM_LOCK_WAIT=${HIMMEL_VM_LOCK_WAIT:-0}s)"; exit 2 ;;
        *) say "FAILED lock ($VM) - the vm-lock was refused, see the line above"; exit 2 ;;
    esac
}
boot() {
    BOOTED=1   # set first: a boot that half-worked is still powered off in cleanup
    sdk "$VM" up >/dev/null || fail boot "vmsdk up failed"
}
# guest_step <step> [--sudo] [--timeout N] -- <cmd>: run in the guest, FAILED <step> with the output tail on rc != 0
guest_step() {
    local step="$1" out rc; shift
    out="$(guest "$@" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || fail "$step" "guest command rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
}
# guest_out <step> <cmd>: the guest output lands in $OUT (no subshell, so a failure exits the run)
guest_out() {
    local step="$1" rc; shift
    OUT="$(guest -- "$@" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || fail "$step" "guest command rc=$rc: $(printf '%s' "$OUT" | tail -n 3 | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------------------------
cmd_run() {
    local snap ver now
    [ -n "$CLAUDE_VER" ] && [ -n "$CLAUDE_SHA" ] && [ -n "$PROXY_VER" ] && [ -n "$PROXY_SHA" ] \
        || fail pins "could not read the claude or cli-proxy pin from the repo"
    now="${VM_MAINTAIN_NOW:-$(date -u +%Y%m%d-%H%M)}"
    snap="${SNAP_PREFIX}${now}"
    acquire
    boot
    guest_step apt-update --sudo --timeout 900 -- 'DEBIAN_FRONTEND=noninteractive apt-get update'
    guest_step apt-upgrade --sudo --timeout 1800 -- 'DEBIAN_FRONTEND=noninteractive apt-get -y upgrade'

    guest_step claude-update --timeout 600 -- "$GUEST_PATH; cur=\$(claude --version 2>/dev/null | cut -d' ' -f1); if [ \"\$cur\" = '$CLAUDE_VER' ]; then echo current; exit 0; fi; set -e; t=\"\$HOME/.cache/vm-maintain.\$\$\"; mkdir -p \"\$t\"; curl -fsSL --proto '=https' --tlsv1.2 -o \"\$t/claude\" 'https://downloads.claude.ai/claude-code-releases/$CLAUDE_VER/linux-x64/claude'; echo '$CLAUDE_SHA  '\"\$t/claude\" | sha256sum -c -; chmod +x \"\$t/claude\"; \"\$t/claude\" install '$CLAUDE_VER'; rm -rf \"\$t\""
    guest_out claude-update "$GUEST_PATH; claude --version"; ver="$(printf '%s\n' "$OUT" | head -n1 | cut -d' ' -f1)"
    [ "$ver" = "$CLAUDE_VER" ] || fail claude-update "claude reports '${ver:-nothing}', the pin is $CLAUDE_VER"

    guest_step codex-update --timeout 600 -- "$GUEST_PATH; npm install -g --prefix \"\$HOME/.local\" @openai/codex@latest"
    guest_out codex-update "$GUEST_PATH; codex --version"
    [ -n "$OUT" ] || fail codex-update "codex --version printed nothing"

    guest_step cli-proxy-update --timeout 600 -- "d=\"\$HOME/.cli-proxy-api\"; if [ -x \"\$d/cli-proxy-api\" ] && [ \"\$(head -n1 \"\$d/cli-proxy-api.version\" 2>/dev/null)\" = '$PROXY_VER' ]; then echo current; exit 0; fi; set -e; mkdir -p \"\$d\"; t=\"\$HOME/.cache/vm-maintain.\$\$\"; mkdir -p \"\$t\"; a='CLIProxyAPI_${PROXY_VER}_linux_amd64.tar.gz'; curl -fsSL --proto '=https' --tlsv1.2 -o \"\$t/\$a\" 'https://github.com/router-for-me/CLIProxyAPI/releases/download/v$PROXY_VER/CLIProxyAPI_${PROXY_VER}_linux_amd64.tar.gz'; echo '$PROXY_SHA  '\"\$t/\$a\" | sha256sum -c -; tar -xzf \"\$t/\$a\" -C \"\$t\"; install -m 755 \"\$t/cli-proxy-api\" \"\$d/cli-proxy-api\"; printf '%s\\n' '$PROXY_VER' > \"\$d/cli-proxy-api.version\"; rm -rf \"\$t\""
    guest_out cli-proxy-update '[ -x "$HOME/.cli-proxy-api/cli-proxy-api" ] && head -n1 "$HOME/.cli-proxy-api/cli-proxy-api.version"'; ver="$(printf '%s\n' "$OUT" | head -n1)"
    [ "$ver" = "$PROXY_VER" ] || fail cli-proxy-update "the version stamp reads '${ver:-nothing}', the pin is $PROXY_VER"

    sdk "$VM" down >/dev/null || fail power-off "vmsdk down failed"
    BOOTED=0
    if [ "$NO_SCAN" -eq 1 ]; then sdk "$VM" snapshot "$snap" --no-secret-scan >/dev/null || fail snapshot "vmsdk snapshot $snap failed"
    else sdk "$VM" snapshot "$snap" >/dev/null || fail snapshot "vmsdk snapshot $snap failed (see the vmsdk line above)"; fi
    record "$snap"
    prune
    say "OK $VM updated (claude $CLAUDE_VER, cli-proxy $PROXY_VER) and snapshotted as $snap; newest good recorded in $NEWEST"
}

# record <snapshot>: one line per VM, replaced atomically. The read-modify-write runs under a file lock,
# because the vm-lock is per VM and two VMs can finish together; a failed read or write leaves the old file.
record_locked() {
    local keep="" rc
    if [ -e "$NEWEST" ]; then
        keep="$(grep -v "^$VM	" "$NEWEST")"; rc=$?
        [ "$rc" -le 1 ] || { say "FAILED snapshot ($VM) - cannot read $NEWEST"; return 1; }
    fi
    { [ -z "$keep" ] || printf '%s\n' "$keep"; printf '%s\t%s\t%s\n' "$VM" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } | atomic_write "$NEWEST" \
        || { say "FAILED snapshot ($VM) - cannot write $NEWEST"; return 1; }
}
record() {
    mkdir -p "$STATE_DIR" || fail snapshot "cannot create $STATE_DIR"
    with_lock "$NEWEST.lock" record_locked "$1" || exit 1
}

# prune: delete maint-* beyond the last KEEP_DATED. Never any other name. A refused delete (VirtualBox
# refuses some snapshots that linked clones hang off) is a warning, not a failed update.
prune() {
    local listing names n drop
    listing="$("$VBOX" snapshot "$VM" list --machinereadable 2>/dev/null)" \
        || { say "WARNING: could not list the snapshots of $VM, nothing pruned"; return 0; }
    names="$(printf '%s\n' "$listing" | sed -n 's/^SnapshotName[-0-9]*="\(.*\)"$/\1/p' \
        | grep -E "^${SNAP_PREFIX}[0-9]{8}-[0-9]{4}\$" | sort -u)"
    n="$(printf '%s\n' "$names" | grep -c .)"
    [ "$n" -gt "$KEEP_DATED" ] || return 0
    for drop in $(printf '%s\n' "$names" | head -n "$((n - KEEP_DATED))"); do
        "$VBOX" snapshot "$VM" delete "$drop" >/dev/null 2>&1 || say "WARNING: could not delete old snapshot $drop (kept)"
    done
}

# ---------------------------------------------------------------------------------------------
# The guest-side check. Prints "PROBE <cli> live|expired <reason>". Standard library only.
PROBE_PY='
import glob, json, os, time
now = time.time()
def load(p):
    try:
        with open(os.path.expanduser(p)) as f:
            return json.load(f)
    except Exception:
        return None
def claude():
    o = (load("~/.claude/.credentials.json") or {}).get("claudeAiOauth")
    if not o:
        return "expired", "no Claude login file"
    rexp = o.get("refreshTokenExpiresAt")
    if rexp and rexp / 1000 < now:
        return "expired", "refresh token past its expiry"
    if not o.get("refreshToken") and o.get("expiresAt", 0) / 1000 < now:
        return "expired", "access token expired and no refresh token"
    return "live", ""
def codex():
    t = (load("~/.codex/auth.json") or {}).get("tokens") or {}
    return ("live", "") if t.get("refresh_token") else ("expired", "no Codex login")
def proxy():
    for p in glob.glob(os.path.expanduser("~/.cli-proxy-api/codex-*.json")):
        d = load(p) or {}
        if d.get("refresh_token") and not d.get("disabled"):
            return "live", ""
    return "expired", "no enabled codex login for the proxy"
for name, fn in (("claude", claude), ("codex", codex), ("cli-proxy", proxy)):
    s, why = fn()
    print("PROBE", name, s, why)
'

login_cmd() {
    case "$1" in
        claude) echo "claude auth login" ;;
        codex) echo "codex login --device-auth" ;;
        cli-proxy) echo "\$HOME/.cli-proxy-api/cli-proxy-api -config \$HOME/.cli-proxy-api/config.yaml -codex-device-login" ;;
    esac
}

cmd_probe() {
    local b64 out rc n line cli state why bad=0 worker logf
    acquire
    boot
    b64="$(printf '%s' "$PROBE_PY" | base64 -w0)"
    out="$(guest --timeout 60 -- "echo $b64 | base64 -d | python3 -I - # PROBE-CREDS" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || fail probe "guest command rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    mkdir -p "$STATE_DIR"; logf="$STATE_DIR/probe-$VM.log"
    printf '%s\n' "$out" > "$logf"
    n="$(printf '%s\n' "$out" | grep -cE '^PROBE (claude|codex|cli-proxy) (live|expired)')"
    [ "$n" -eq 3 ] || fail probe "expected one result for each of claude, codex and cli-proxy, got $n: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    while read -r line; do
        case "$line" in "PROBE "*) ;; *) continue ;; esac
        read -r _ cli state why <<<"$line"
        worker="vm-maintain-login-$VM-$cli"
        if [ "$state" = live ]; then bash "$ALERT" clear "$worker"; continue; fi
        bad=1
        say "$VM $cli login EXPIRED ($why) - operator: on $VM run: $(login_cmd "$cli")  (then re-run vm-maintain.sh run $VM)"
        bash "$ALERT" fail "$worker" "$cli login on $VM expired" "$logf" "$why" "on $VM run: $(login_cmd "$cli")"
    done <<<"$out"
    [ "$bad" -eq 0 ]
}

case "$MODE" in
    run) cmd_run ;;
    probe) cmd_probe ;;
esac
