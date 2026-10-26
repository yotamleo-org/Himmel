#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use chief-wait.sh.
if (return 0 2>/dev/null); then
  echo "console-wait.sh is deprecated: run 'chief-wait.sh', do not source it" >&2
  return 2
fi
set -uo pipefail
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "console-wait.sh was renamed to chief-wait.sh; legacy names are off" >&2
    exit 127 ;;
esac

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  link=$(readlink "$src") || { echo "console-wait.sh: cannot resolve its symlink '$src'" >&2; exit 127; }
  case "$link" in
    /*) src="$link" ;;
    *) case "$src" in */*) src="${src%/*}/$link" ;; *) src="$link" ;; esac ;;
  esac
done
case "$src" in */*) dir="${src%/*}" ;; *) dir=. ;; esac
SCRIPT_DIR=$(cd "$dir" 2>/dev/null && pwd) || { echo "console-wait.sh: cannot find its directory '$dir'" >&2; exit 127; } # swallow-ok: a failed cd exits 127 with its own line

echo "console-wait.sh is deprecated: use 'chief-wait.sh' instead" >&2
exec bash "$SCRIPT_DIR/chief-wait.sh" "$@"
