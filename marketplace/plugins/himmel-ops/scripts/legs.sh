#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use workers.sh.
if (return 0 2>/dev/null); then
  echo "legs.sh is deprecated: run 'workers.sh', do not source it" >&2
  return 2
fi
set -uo pipefail
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "legs.sh was renamed to workers.sh; legacy names are off" >&2
    exit 127 ;;
esac

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  link=$(readlink "$src") || { echo "legs.sh: cannot resolve its symlink '$src'" >&2; exit 127; }
  case "$link" in
    /*) src="$link" ;;
    *) case "$src" in */*) src="${src%/*}/$link" ;; *) src="$link" ;; esac ;;
  esac
done
case "$src" in */*) dir="${src%/*}" ;; *) dir=. ;; esac
SCRIPT_DIR=$(cd "$dir" 2>/dev/null && pwd) || { echo "legs.sh: cannot find its directory '$dir'" >&2; exit 127; }

echo "legs.sh is deprecated: use 'workers.sh' instead" >&2
exec bash "$SCRIPT_DIR/workers.sh" "$@"
