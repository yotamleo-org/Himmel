#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use chief.sh.
if (return 0 2>/dev/null); then
  echo "console.sh is deprecated: run 'chief.sh', do not source it" >&2
  return 2
fi
set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="${BASH_SOURCE[0]%/*}" ;; *) SCRIPT_DIR=. ;; esac

echo "console.sh is deprecated: use 'chief.sh' instead" >&2
exec bash "$SCRIPT_DIR/chief.sh" "$@"
