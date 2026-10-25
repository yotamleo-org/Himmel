#!/usr/bin/env bash
# DEPRECATED forwarder, kept so old callers keep working: use headed-arm-worker.sh.
# The old path stays a registered chokepoint, so it runs the seam guard itself.
if (return 0 2>/dev/null); then
  echo "headed-arm-leg.sh is deprecated: run 'headed-arm-worker.sh', do not source it" >&2
  return 2
fi
set -uo pipefail

# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced or run.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "headed-arm-leg.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/chief-kit/headed-arm-leg.sh || exit 96
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "headed-arm-leg.sh was renamed to headed-arm-worker.sh; legacy names are off" >&2
    exit 127 ;;
esac

echo "headed-arm-leg.sh is deprecated: use 'headed-arm-worker.sh' instead" >&2
exec bash "$_csg_dir/headed-arm-worker.sh" "$@"
