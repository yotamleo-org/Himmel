#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use worker-burn.sh.
if (return 0 2>/dev/null); then
  echo "leg-burn.sh is deprecated: run 'worker-burn.sh', do not source it" >&2
  return 2
fi
set -uo pipefail
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "leg-burn.sh was renamed to worker-burn.sh; legacy names are off" >&2
    exit 127 ;;
esac

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  link=$(readlink "$src") || { echo "leg-burn.sh: cannot resolve its symlink '$src'" >&2; exit 127; }
  case "$link" in
    /*) src="$link" ;;
    *) case "$src" in */*) src="${src%/*}/$link" ;; *) src="$link" ;; esac ;;
  esac
done
case "$src" in */*) dir="${src%/*}" ;; *) dir=. ;; esac
SCRIPT_DIR=$(cd "$dir" 2>/dev/null && pwd) || { echo "leg-burn.sh: cannot find its directory '$dir'" >&2; exit 127; }

echo "leg-burn.sh is deprecated: use 'worker-burn.sh' instead" >&2
exec bash "$SCRIPT_DIR/worker-burn.sh" "$@"
