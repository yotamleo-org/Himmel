#!/usr/bin/env bash
# scripts/handover/test-move-renamed-dirs.sh — Covers move-renamed-dirs.sh in a
# sandbox git repo: every pair moves with a relative symlink left at the old
# path (mode 120000 in the index), a file reached through either spelling has
# one realpath, keyed data files trade old paths for new ones without touching
# look-alikes, --check reports pending work, and a second run changes nothing.
#
# Platform guard (linux-only): the move leaves symlinks, which a Windows
# checkout without core.symlinks cannot hold.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MOVE="$HERE/move-renamed-dirs.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/move-renamed-dirs.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '    got: %s\n' "$2"; fail=1; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 (want '$2')" "$3"; fi; }

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
OLD='scripts/handover/console-kit scripts/handover/console scripts/console scripts/overnight scripts/eval/leg-digest docs/handover/console-sections docs/handover/leg-sections'
for d in $OLD; do mkdir -p "$repo/$d"; printf 'x\n' > "$repo/$d/f.sh"; done
mkdir -p "$repo/scripts/ci" "$repo/scripts/lint"
printf '%s\n' \
  'scripts/handover/console-kit/test-go.sh	12' \
  'scripts/handover/console/test-console.sh	3' \
  'scripts/console/test-base-status.sh	4' \
  'scripts/overnight/test-self-heal.sh	5' \
  'scripts/eval/leg-digest/test-leg-digest.sh	6' \
  'scripts/overnight-shift.sh	7' \
  'marketplace/plugins/p/scripts/console/test-x.sh	8' \
  > "$repo/scripts/ci/suite-durations.tsv"
printf '%s\n' '"docs/handover/console-sections/waiter.md" "docs/handover/leg-sections/ci-red.md"' > "$repo/scripts/lint/shell-lint-baseline.tsv"
git -C "$repo" add -A
git -C "$repo" commit -q -m base

out=$(cd "$repo" && bash "$MOVE" --check 2>&1); rc=$?
eq "--check before the move exits 1" 1 "$rc"
case "$out" in *'scripts/handover/console-kit'*) pass "--check names a pending pair" ;; *) bad "--check names a pending pair" "$out" ;; esac

out=$(cd "$repo" && bash "$MOVE" 2>&1); rc=$?
eq "apply exits 0" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out"

for pair in 'scripts/handover/console-kit chief-kit' 'scripts/handover/console chief' 'scripts/console chief' \
            'scripts/overnight afk' 'scripts/eval/leg-digest worker-digest' \
            'docs/handover/console-sections chief-sections' 'docs/handover/leg-sections worker-sections'; do
  old=${pair% *}; new="${old%/*}/${pair#* }"
  eq "$old is a symlink to ${pair#* }" "${pair#* }" "$(readlink "$repo/$old" 2>&1)"
  eq "$new is a real directory" yes "$([ -d "$repo/$new" ] && [ ! -L "$repo/$new" ] && echo yes || echo no)"
  eq "$old is staged as a symlink" 120000 "$(git -C "$repo" ls-files -s -- "$old" | cut -d' ' -f1)"
  eq "$old/f.sh and $new/f.sh share a realpath" "$(realpath "$repo/$new/f.sh")" "$(realpath "$repo/$old/f.sh")"
  eq "$new/f.sh is tracked" "$new/f.sh" "$(git -C "$repo" ls-files -- "$new/f.sh")"
done

want='scripts/handover/chief-kit/test-go.sh	12
scripts/handover/chief/test-console.sh	3
scripts/chief/test-base-status.sh	4
scripts/afk/test-self-heal.sh	5
scripts/eval/worker-digest/test-leg-digest.sh	6
scripts/overnight-shift.sh	7
marketplace/plugins/p/scripts/console/test-x.sh	8'
eq "suite-durations.tsv moves real paths and keeps look-alikes" "$want" "$(cat "$repo/scripts/ci/suite-durations.tsv")"
eq "a quoted keyed path is rewritten" '"docs/handover/chief-sections/waiter.md" "docs/handover/worker-sections/ci-red.md"' "$(cat "$repo/scripts/lint/shell-lint-baseline.tsv")"
eq "keyed files are staged" "" "$(git -C "$repo" diff --name-only)"

out=$(cd "$repo" && bash "$MOVE" --check 2>&1); rc=$?
eq "--check after the move exits 0" 0 "$rc"

before=$(git -C "$repo" status --porcelain)
out=$(cd "$repo" && bash "$MOVE" 2>&1); rc=$?
eq "a second run exits 0" 0 "$rc"
eq "a second run changes nothing" "$before" "$(git -C "$repo" status --porcelain)"

# A new path that already exists is refused before anything moves.
repo2="$tmp/repo2"; mkdir -p "$repo2/scripts/overnight" "$repo2/scripts/afk"
git -C "$repo2" init -q
printf 'x\n' > "$repo2/scripts/overnight/f.sh"; printf 'y\n' > "$repo2/scripts/afk/g.sh"
out=$(cd "$repo2" && bash "$MOVE" 2>&1); rc=$?
eq "an existing new path is refused" 2 "$rc"
case "$out" in *'scripts/afk already exists'*) pass "the refusal names the existing path" ;; *) bad "the refusal names the existing path" "$out" ;; esac
eq "the refused tree is untouched" no "$([ -L "$repo2/scripts/overnight" ] && echo yes || echo no)"

[ "$fail" = 0 ] && echo "all passed" || exit 1
