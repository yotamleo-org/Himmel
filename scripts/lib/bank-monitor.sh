#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use usage-monitor.sh.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "bank-monitor.sh is deprecated: run 'usage-monitor.sh', do not source it" >&2
  return 2
fi
set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="${BASH_SOURCE[0]%/*}" ;; *) SCRIPT_DIR=. ;; esac

echo "bank-monitor.sh is deprecated: use 'usage-monitor.sh' instead" >&2
exec bash "$SCRIPT_DIR/usage-monitor.sh" "$@"
