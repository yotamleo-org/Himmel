#!/usr/bin/env bash
# guest-exec.sh - the one sanctioned way for a leg to run a command inside a himmel
# test VM. A thin wrapper over `vmsdk.py <vm> exec`, which refuses any target that
# is not a running himmel test VM (registry port + loopback NAT forward readback)
# and logs every command to ~/.himmel/vm/guest-exec.log.
#
# Usage: bash scripts/vm/guest-exec.sh <vm> [--sudo] [--timeout N] -- <cmd> [args...]
set -uo pipefail

usage() { echo "usage: guest-exec.sh <vm> [--sudo] [--timeout N] -- <cmd> [args...]" >&2; exit 2; }

[ "$#" -ge 3 ] || usage
vm="$1"; shift
case "$vm" in
    *[!A-Za-z0-9_-]*|'') echo "guest-exec.sh: invalid vm name '$vm'" >&2; usage ;;
esac

# the command must follow a literal -- with at least one word after it
seen=0
for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; break; fi
done
[ "$seen" -eq 1 ] || usage
[ "${*: -1}" != "--" ] || usage

sdk="${HIMMEL_VMSDK:-$(cd "$(dirname "$0")/../lib" && pwd)/vmsdk.py}"
if command -v uv >/dev/null 2>&1; then
    exec uv run "$sdk" "$vm" exec "$@"
fi
exec python3 "$sdk" "$vm" exec "$@"
