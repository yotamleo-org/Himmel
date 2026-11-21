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

if grep -q 'EnvironmentFile' "$here/units/himmel-peer-runner.service"; then
    bad "the runner unit reads an env file (it must hold no token)"
else
    ok "the runner unit reads no env file"
fi
if grep -q 'run\.sh' "$here/units/com.himmel.peer-runner.plist"; then
    bad "the runner agent goes through run.sh, which loads the bot token"
else
    ok "the runner agent does not load the bot token"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
    # systemd-analyze --user needs a user runtime dir; a CI runner has no login session, so lend it one
    if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
        mkdir -m 700 "$tmp/run" && export XDG_RUNTIME_DIR="$tmp/run"
    fi
    for unit in himmel-peer-bridge.service himmel-peer-runner.service; do
        sed "s|@HIMMEL_ROOT@|$root|g" "$here/units/$unit" > "$tmp/$unit"
        if out="$(systemd-analyze --user verify "$tmp/$unit" 2>&1)"; then
            ok "systemd-analyze verify $unit"
        else
            bad "systemd-analyze verify $unit: $out"
        fi
    done
else
    echo "SKIP systemd-analyze: not found (Linux check)"
fi

if command -v plutil >/dev/null 2>&1; then
    for agent in com.himmel.peer-bridge.plist com.himmel.peer-runner.plist; do
        if out="$(plutil -lint "$here/units/$agent" 2>&1)"; then
            ok "plutil -lint $agent"
        else
            bad "plutil -lint $agent: $out"
        fi
    done
else
    echo "SKIP plutil: not found (macOS check)"
fi

exit "$fail"
