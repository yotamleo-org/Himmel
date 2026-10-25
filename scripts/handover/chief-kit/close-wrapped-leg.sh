#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use close-wrapped-worker.sh.
if (return 0 2>/dev/null); then
  echo "close-wrapped-leg.sh is deprecated: run 'close-wrapped-worker.sh', do not source it" >&2
  return 2
fi
set -uo pipefail
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "close-wrapped-leg.sh was renamed to close-wrapped-worker.sh; legacy names are off" >&2
    exit 127 ;;
esac
case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="${BASH_SOURCE[0]%/*}" ;; *) SCRIPT_DIR=. ;; esac
echo "close-wrapped-leg.sh is deprecated: use 'close-wrapped-worker.sh' instead" >&2
exec bash "$SCRIPT_DIR/close-wrapped-worker.sh" "$@"
