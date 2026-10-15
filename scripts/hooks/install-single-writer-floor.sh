#!/usr/bin/env bash
# Install the client-side force-push floor into a .single-writer repo
# (audit gap G11).
#
# Usage: bash <himmel>/scripts/hooks/install-single-writer-floor.sh <repo-path>
#
# luna and the handover state repos are private on the GitHub Free plan, so
# there is no server-side protection; these hooks are the only floor. Installs:
#   1. .git/hooks/pre-push -- a static shim that runs
#      check-single-writer-push-floor.sh (refuses a non-fast-forward push to
#      main and a delete of main; fast-forwards still go through).
#   2. .git/hooks/reference-transaction -- via install-main-ref-transaction.sh
#      (the existing guard; a no-op in a .single-writer repo by
#      design, installed so the repo carries the same hook set as the himmel
#      checkout and `himmel-doctor` C32 sees it).
#
# Idempotent (re-running rewrites the same bytes atomically). Never overwrites
# a hook it did not write: a foreign pre-push or reference-transaction hook
# makes this refuse (rc 2) BEFORE anything is installed, and say so. Refuses a
# repo without a `.single-writer` marker (a normal himmel checkout gets the
# full guard set from setup-hooks.sh) and one with core.hooksPath set (the
# hooks would land somewhere other than the repo's own hooks dir).
#
# Run it from the PRIMARY himmel checkout: the shims record that checkout's
# script paths, and a pruned worktree path makes every push in the repo refuse
# (fail closed) until the installer is re-run.
#
# Exit: 0 installed, 2 refused or failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_script="$SCRIPT_DIR/check-single-writer-push-floor.sh"
reftx_installer="$SCRIPT_DIR/install-main-ref-transaction.sh"
pp_marker="# himmel-single-writer-floor-v1"
rt_marker="# himmel-main-ref-transaction-v1"

# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/git-clean.sh"
git_env_scrub

die() { echo "install-single-writer-floor: $*" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: install-single-writer-floor.sh <repo-path>"
[ -f "$check_script" ] && [ -f "$reftx_installer" ] || die "cannot find the floor scripts next to $0"
[ -d "$1" ] || die "$1 is not a directory"

root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || die "$1 is not a git repository"
prefix=$(git -C "$1" rev-parse --show-prefix 2>/dev/null)
[ -z "$prefix" ] || die "$1 is inside a repository ($root), not its root -- pass the repo root"
[ -f "$root/.single-writer" ] || die "$root has no .single-writer marker -- refusing (this installer is for single-writer repos; a normal checkout uses scripts/setup-hooks.sh)"
if git -C "$root" config --get core.hooksPath >/dev/null 2>&1; then   # rc 0 even when set to the empty string
    die "core.hooksPath is set in $root -- refusing (hooks would not land in the repo's own hooks dir; unset it and re-run)"
fi

common_dir=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
case "$common_dir" in /*|[A-Za-z]:[/\\]*) ;; *) die "could not resolve an absolute git dir for $root (got '$common_dir'); needs git >= 2.31" ;; esac
hooks_dir="$common_dir/hooks"

# Refuse a foreign hook BEFORE writing anything.
for pair in "pre-push:$pp_marker" "reference-transaction:$rt_marker"; do
    name="${pair%%:*}"; marker="${pair#*:}"
    if [ -e "$hooks_dir/$name" ] && ! grep -Fq "$marker" "$hooks_dir/$name"; then
        die "refusing to overwrite existing non-Himmel $name hook at $hooks_dir/$name -- merge it with $check_script by hand, then re-run"
    fi
done

mkdir -p "$hooks_dir" || die "cannot create $hooks_dir"
git -C "$root" config --local himmel-single-writer-floor.target "$check_script" \
    || die "could not record himmel-single-writer-floor.target in git config"

tmp=$(mktemp "$hooks_dir/.himmel-single-writer-floor.XXXXXX") || die "cannot create a temp file in $hooks_dir"
cat > "$tmp" <<'HOOK' || { rm -f "$tmp"; die "cannot write $tmp"; }
#!/usr/bin/env bash
# himmel-single-writer-floor-v1
# Shim installed by scripts/hooks/install-single-writer-floor.sh.
# Static bytes; the target lives in `git config himmel-single-writer-floor.target`.
# FAIL-CLOSED if the target is gone: this hook is the repo's only force-push
# floor, so a pruned checkout must refuse loudly, never silently stop protecting.
target=$(git config --local --get himmel-single-writer-floor.target 2>/dev/null)
if [ -z "$target" ] || [ ! -f "$target" ] || [ ! -r "$target" ]; then
    echo "pre-push (himmel-single-writer-floor-v1): target '$target' missing -- REFUSING this push (the force-push floor cannot run; re-run install-single-writer-floor.sh from the primary himmel checkout)" >&2
    cat >/dev/null
    exit 1
fi
exec bash "$target" "$@"
HOOK
chmod +x "$tmp" && [ -x "$tmp" ] || { rm -f "$tmp"; die "cannot make the pre-push hook executable"; }
mv -f "$tmp" "$hooks_dir/pre-push" || { rm -f "$tmp"; die "cannot move the hook into place at $hooks_dir/pre-push"; }
echo "install-single-writer-floor: pre-push floor installed at $hooks_dir/pre-push"

# The reference-transaction guard: reuse the existing installer, run from the
# target repo (it resolves the repo from cwd).
( cd "$root" && bash "$reftx_installer" ) || die "install-main-ref-transaction.sh failed in $root (the pre-push floor above IS installed)"

echo "install-single-writer-floor: done for $root"
exit 0
