#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working.
# TEMPLATE for a renamed script (shape of scripts/clean-garden.sh):
# copy it to the OLD path, replace __OLD__ with the old script's name and
# __NEW__ with the new script's path relative to this file's directory (a
# symlinked old path is followed first, an unresolvable one exits 127), and
# drop this banner for a one-line note naming the replacement. It prints one
# stderr line, then runs the new script with the same argv, stdin and stdout;
# its exit code is the new script's. The target always runs under bash, whatever
# its shebang says, so copy this only for a bash target. Sourced, it refuses
# with status 2 before the exec, so the caller's shell survives.
# scripts/lib/test-deprecated-forwarder.sh proves the pass-through.
if (return 0 2>/dev/null); then
  echo "__OLD__ is deprecated: run '__NEW__', do not source it" >&2
  return 2
fi
set -uo pipefail

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  link=$(readlink "$src") || { echo "__OLD__: cannot resolve its symlink '$src'" >&2; exit 127; }
  case "$link" in
    /*) src="$link" ;;
    *) case "$src" in */*) src="${src%/*}/$link" ;; *) src="$link" ;; esac ;;
  esac
done
case "$src" in */*) dir="${src%/*}" ;; *) dir=. ;; esac
SCRIPT_DIR=$(cd "$dir" 2>/dev/null && pwd) || { echo "__OLD__: cannot find its directory '$dir'" >&2; exit 127; }

echo "__OLD__ is deprecated: use '__NEW__' instead" >&2
exec bash "$SCRIPT_DIR/__NEW__" "$@"
