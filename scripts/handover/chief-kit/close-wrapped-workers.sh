#!/usr/bin/env bash
# scripts/handover/chief-kit/close-wrapped-workers.sh - close every finished
# worker window, across fleet manifests, in one command.
#
# Usage: close-wrapped-workers.sh [--check] [<manifest>...]
#
# Runs `close-wrapped-worker.sh [--check] --sweep --fleet <manifest>` once per
# manifest and adds no close logic of its own: the lock-free, tail-WRAPPED,
# one-session, subtree and subagent checks all stay in close-wrapped-worker.sh, so
# a held or unwrapped worker is skipped there and never signalled. With no
# manifest it sweeps every *.fleet.json in this repo's handover bucket
# (<handover root>/<user slug>/<repo>, HIMMEL_BUCKET_DIR overrides) changed in
# the last CLOSE_WRAPPED_WORKERS_MAX_AGE_MIN minutes (default 1440), so a
# predecessor chief's wrapped workers close too. --check passes through: every
# check runs, nothing is signalled.
# ponytail: the age window bounds the no-arg sweep (the whole bucket took over
# 10 min, mostly rc=5 for windows already gone); upgrade path: drop closed workers
# from their manifest so old manifests empty out.
#
# A sweep that fails is reported and the loop goes on to the next manifest.
# Prints each sweep's own lines, except a refusal for a worker with no live session
# (its window is already gone), which is only counted; then
# `sweeps: manifests=<n> failed=<n> gone=<n>`.
#
# Exit: 0 every sweep ran; 1 a sweep failed; 2 usage, no bucket resolved, or
# the bucket's manifests could not be listed.
#
# Platform guard: Linux bash 3.2+, same as close-wrapped-worker.sh (no .ps1 twin).
set -u
# Old names, read only while HIMMEL_LEGACY_NAMES is on.
case "${BASH_SOURCE[0]}" in */*) _ea_dir="${BASH_SOURCE[0]%/*}" ;; *) _ea_dir=. ;; esac
# shellcheck source=scripts/lib/env-alias.sh
# shellcheck disable=SC1091
if { [ -r "$_ea_dir/../../lib/env-alias.sh" ] && . "$_ea_dir/../../lib/env-alias.sh"; } 2>/dev/null; then
    alias_env CLOSE_WRAPPED_WORKERS_MAX_AGE_MIN CLOSE_WRAPPED_LEGS_MAX_AGE_MIN
fi
unset _ea_dir

HERE="$(cd "$(dirname "$0")" && pwd)"

check=""
manifests=()
for a in "$@"; do
    case "$a" in
        --check) check="--check" ;;
        -*) echo "usage: close-wrapped-workers.sh [--check] [<manifest>...]" >&2; exit 2 ;;
        *) manifests+=("$a") ;;
    esac
done
set -- ${manifests[@]+"${manifests[@]}"}

if [ "$#" -eq 0 ]; then
    bucket="${HIMMEL_BUCKET_DIR:-}"
    if [ -z "$bucket" ]; then
        # shellcheck source=../../lib/load-dotenv.sh
        # shellcheck disable=SC1091
        . "$HERE/../../lib/load-dotenv.sh"
        # shellcheck source=../../lib/user-slug.sh
        # shellcheck disable=SC1091
        . "$HERE/../../lib/user-slug.sh"
        # shellcheck source=../../lib/handover-path.sh
        # shellcheck disable=SC1091
        . "$HERE/../../lib/handover-path.sh"
        load_dotenv --root "$(_load_dotenv_primary_for "$HERE/../../..")" HANDOVER_DIR USER_SLUG
        root="$(handover_root)" || { echo "close-wrapped-workers: set HANDOVER_DIR or run /handover-setup" >&2; exit 2; }
        slug="$(cd "$HERE/../../.." && user_slug)" || { echo "close-wrapped-workers: cannot resolve USER_SLUG" >&2; exit 2; }
        # shellcheck source=../../lib/git-clean.sh
        # shellcheck disable=SC1091
        . "$HERE/../../lib/git-clean.sh"
        common="$(cd "$HERE" && git_env_scrub && git rev-parse --path-format=absolute --git-common-dir)" \
            || { echo "close-wrapped-workers: cannot resolve the primary checkout" >&2; exit 2; }
        bucket="$root/$slug/$(basename "$(dirname "$common")")"
    fi
    [ -d "$bucket" ] || { echo "close-wrapped-workers: no bucket dir $bucket" >&2; exit 2; }
    found=$(find "$bucket" -maxdepth 1 -type f -name '*.fleet.json' -mmin "-${CLOSE_WRAPPED_WORKERS_MAX_AGE_MIN:-1440}") || { echo "close-wrapped-workers: cannot list the manifests in $bucket" >&2; exit 2; } # gnu-ok: BSD find has -maxdepth and -mmin too
    while IFS= read -r m; do
        [ -n "$m" ] && set -- "$@" "$m"
    done <<EOF
$(printf '%s\n' "$found" | sort)
EOF
fi

n=0; failed=0; gone=0
for m in "$@"; do
    n=$((n + 1))
    # shellcheck disable=SC2086
    out=$(bash "$HERE/close-wrapped-worker.sh" $check --sweep --fleet "$m" 2>&1); rc=$?
    # a WRAPPED, lock-free worker with no live session now exits 0 (CLOSED-ALREADY), so gone= stays 0 for it.
    # The rc-5 text is still counted and hidden for a sweep that meets a refusing close script; every other line prints as written
    g=$(printf '%s\n' "$out" | grep -c -E '^sweep: refused .* \(rc=5\): .* - 0 live session\(s\) matched')
    gone=$((gone + g))
    printf '%s\n' "$out" | grep -v -E '^sweep: refused .* \(rc=5\): .* - 0 live session\(s\) matched'
    if [ "$rc" -ne 0 ]; then
        failed=$((failed + 1))
        echo "close-wrapped-workers: sweep failed for $m (rc=$rc) - continuing"
    fi
done
echo "sweeps: manifests=$n failed=$failed gone=$gone"
[ "$failed" -eq 0 ]
