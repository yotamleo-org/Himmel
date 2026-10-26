#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-workers.sh — transport wrapper for the shared worker resolver.
# workers.sh holds ZERO worker logic; it locates the himmel checkout and re-execs
# scripts/lib/initiative-workers.sh so the worker `case` lives in exactly one place.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"   # himmel checkout root (4 up from .../himmel-ops/scripts)
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# execute worker active → surfaces in the wrapper output (via HIMMEL_REPO anchor).
out="$(HIMMEL_REPO="$repo" HIMMEL_INITIATIVE='prcheck,execute' bash "$here/workers.sh")"
case " $out " in *" execute "*) echo "ok - execute surfaced";; *) echo "FAIL: execute missing [$out]"; fails=$((fails+1));; esac

# execute worker absent → not in output.
out="$(HIMMEL_REPO="$repo" HIMMEL_INITIATIVE='prcheck' bash "$here/workers.sh")"
case " $out " in *" execute "*) echo "FAIL: execute leaked [$out]"; fails=$((fails+1));; *) echo "ok - execute absent";; esac

# afk profile by its new names → the afk step list surfaces.
out="$(env -u HIMMEL_INITIATIVE -u HIMMEL_OVERNIGHT -u HIMMEL_INITIATIVE_OVERNIGHT HIMMEL_REPO="$repo" HIMMEL_AFK=1 HIMMEL_INITIATIVE_AFK='execute' bash "$here/workers.sh")"
case " $out " in *" execute "*) echo "ok - afk names surface the afk steps";; *) echo "FAIL: afk names ignored [$out]"; fails=$((fails+1));; esac

# no anchor + cwd inside the himmel checkout → resolves via git toplevel of cwd.
out="$(cd "$repo" && env -u HIMMEL_REPO HIMMEL_INITIATIVE='execute' bash "$here/workers.sh")"
case " $out " in *" execute "*) echo "ok - resolves via cwd git-toplevel";; *) echo "FAIL: cwd resolution [$out]"; fails=$((fails+1));; esac

# fail-open: wrapper copied OUTSIDE any himmel checkout + no anchor + no checkout
# at the default install path -> empty, exit 0. HOME="$td" defeats the
# default-path candidate ($HOME/Documents/github/himmel) so it cannot resolve to
# the real machine checkout.
td="$(mktemp -d)" || exit 1; cp "$here/workers.sh" "$td/workers.sh"
out="$(cd "$td" && env -u HIMMEL_REPO HOME="$td" HIMMEL_INITIATIVE='execute' bash "$td/workers.sh")"; rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } && echo "ok - fail-open with no reachable resolver" || { echo "FAIL: not fail-open [$out] rc=$rc"; fails=$((fails+1)); }
rm -rf "$td"

# default-install fallback: no anchor, cwd OUTSIDE any checkout, but
# a himmel checkout exists at $HOME/Documents/github/himmel -> resolves via the
# 4th candidate. Same cwd/BASH_SOURCE setup as the fail-open case above (a non-git
# mktemp dir, so candidates 2+3 fail); only HOME differs, isolating candidate 4.
th="$(mktemp -d)"; mkdir -p "$th/Documents/github/himmel/scripts/lib"
cp "$repo/scripts/lib/initiative-workers.sh" "$th/Documents/github/himmel/scripts/lib/initiative-workers.sh"
td2="$(mktemp -d)" || exit 1; cp "$here/workers.sh" "$td2/workers.sh"
out="$(cd "$td2" && env -u HIMMEL_REPO HOME="$th" HIMMEL_INITIATIVE='execute' bash "$td2/workers.sh")"
case " $out " in *" execute "*) echo "ok - resolves via default install path";; *) echo "FAIL: default-path resolution [$out]"; fails=$((fails+1));; esac
rm -rf "$th" "$td2"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
