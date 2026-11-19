#!/usr/bin/env bash
# test-peer-units.sh - lint the peer bridge units: systemd-analyze verify on
# Linux, plutil -lint on macOS. A check whose tool is absent prints a loud SKIP.
# Bash 3.2-compatible.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/peer-units.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

if grep -q '^RestartPreventExitStatus=78$' "$here/units/himmel-peer-bridge.service"; then
    ok "systemd unit stops restarting on exit 78"
else
    bad "systemd unit lacks RestartPreventExitStatus=78"
fi
if grep -q '<key>SuccessfulExit</key>' "$here/units/com.himmel.peer-bridge.plist"; then
    ok "launchd agent restarts only on a failed exit"
else
    bad "launchd agent lacks KeepAlive SuccessfulExit"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
    sed "s|@HIMMEL_ROOT@|$root|g" "$here/units/himmel-peer-bridge.service" > "$tmp/himmel-peer-bridge.service"
    if out="$(systemd-analyze --user verify "$tmp/himmel-peer-bridge.service" 2>&1)"; then
        ok "systemd-analyze verify"
    else
        bad "systemd-analyze verify: $out"
    fi
else
    echo "SKIP systemd-analyze: not found (Linux check)"
fi

if command -v plutil >/dev/null 2>&1; then
    if out="$(plutil -lint "$here/units/com.himmel.peer-bridge.plist" 2>&1)"; then
        ok "plutil -lint"
    else
        bad "plutil -lint: $out"
    fi
else
    echo "SKIP plutil: not found (macOS check)"
fi

exit "$fail"
