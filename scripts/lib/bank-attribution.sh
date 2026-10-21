#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use usage-attribution.sh.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "bank-attribution.sh is deprecated: run 'usage-attribution.sh', do not source it" >&2
  return 2
fi
set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="${BASH_SOURCE[0]%/*}" ;; *) SCRIPT_DIR=. ;; esac

echo "bank-attribution.sh is deprecated: use 'usage-attribution.sh' instead" >&2
exec bash "$SCRIPT_DIR/usage-attribution.sh" "$@"
