#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()
# scripts/vm/test-launch-guest.sh - suite for launch-guest.sh, the one sanctioned
# way a leg starts a claude session on a himmel test VM.
# Asserts: bad shape / unregistered VM / station VM refuse before any ssh; the
# dry-run guest command carries an explicit --permission-mode acceptEdits and an
# --allowedTools list, and never a skip-permissions flag.
# Platform: POSIX bash 3.2+.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/launch-guest.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/launch-guest-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2] != [$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: missing [$3] in [$2]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: found [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

printf 'do the thing\n' > "$tmp/prompt.txt"
cat > "$tmp/vms.json" <<'J'
{
  "ubuntu_new": { "os": "ubuntu", "ssh_port": 2222, "user": "himmel" },
  "win11_base_himmel": { "os": "windows", "ssh_port": 2223 },
  "win2": { "os": "windows", "kind": "station", "host": "win2" }
}
J
run() { LAUNCH_GUEST_VMS_JSON="$tmp/vms.json" bash "$SCRIPT" "$@" 2>&1; }

rc=0; out="$(run)" || rc=$?
check "no args: exit 2" "$rc" "2"
rc=0; out="$(run ubuntu_new)" || rc=$?
check "one arg: exit 2" "$rc" "2"
rc=0; out="$(run nosuchvm "$tmp/prompt.txt")" || rc=$?
check "unregistered vm: exit 2" "$rc" "2"
contains "unregistered vm: says so" "$out" "not a registered test VM"
rc=0; out="$(run win2 "$tmp/prompt.txt")" || rc=$?
check "station vm: exit 2" "$rc" "2"
rc=0; out="$(run win11_base_himmel "$tmp/prompt.txt")" || rc=$?
check "windows vm: exit 2 (ubuntu guests only)" "$rc" "2"
rc=0; out="$(run ubuntu_new "$tmp/missing.txt")" || rc=$?
check "missing prompt file: exit 2" "$rc" "2"
rc=0; out="$(run 'ubuntu_new;id' "$tmp/prompt.txt")" || rc=$?
check "metacharacter vm name: exit 2" "$rc" "2"

rc=0; out="$(run --dry-run ubuntu_new "$tmp/prompt.txt")" || rc=$?
check "dry-run: exit 0" "$rc" "0"
contains "dry-run: ssh to the registered port" "$out" "-p 2222"
contains "dry-run: ssh user from the registry" "$out" "himmel@127.0.0.1"
contains "dry-run: explicit permission mode" "$out" "--permission-mode acceptEdits"
contains "dry-run: allowedTools list" "$out" "--allowedTools"
contains "dry-run: json output" "$out" "--output-format json"
lacks "dry-run: no skip-permissions" "$out" "skip-permissions"
lacks "dry-run: no bypassPermissions" "$out" "bypassPermissions"

rc=0; out="$(LAUNCH_GUEST_TIMEOUT=0 run --dry-run ubuntu_new "$tmp/prompt.txt")" || rc=$?
check "zero timeout: exit 2" "$rc" "2"

mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho STUB-SSH "$@"\n' > "$tmp/bin/ssh"; chmod +x "$tmp/bin/ssh"
printf '#!/bin/sh\necho SKIPPED-BANK\n' > "$tmp/pre-skip.sh"
printf '#!/bin/sh\necho PROCEED\n' > "$tmp/pre-ok.sh"
rc=0; out="$(PATH="$tmp/bin:$PATH" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-skip.sh" run ubuntu_new "$tmp/prompt.txt")" || rc=$?
check "exhausted bank: exit 2" "$rc" "2"
lacks "exhausted bank: no ssh" "$out" "STUB-SSH"
rc=0; out="$(PATH="$tmp/bin:$PATH" LAUNCH_GUEST_PREFLIGHT="$tmp/pre-ok.sh" run ubuntu_new "$tmp/prompt.txt")" || rc=$?
check "bank ok: exit 0" "$rc" "0"
contains "bank ok: ssh runs" "$out" "STUB-SSH -p 2222"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-launch-guest.sh"; exit 0; fi
echo "FAIL - test-launch-guest.sh ($fails failure(s))"; exit 1
