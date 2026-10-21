#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working.
# TEMPLATE for a renamed script (shape of scripts/clean-garden.sh):
# copy it to the OLD path, replace __OLD__ with the old script's name and
# __NEW__ with the new script's path relative to this file's directory, and
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

case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="${BASH_SOURCE[0]%/*}" ;; *) SCRIPT_DIR=. ;; esac

echo "__OLD__ is deprecated: use '__NEW__' instead" >&2
exec bash "$SCRIPT_DIR/__NEW__" "$@"
