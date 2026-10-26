#!/usr/bin/env bash
# scripts/handover/test-move-renamed-dirs.sh — Covers move-renamed-dirs.sh on a
# fixture handover tree with a fixture registry of made-up pairs: the .md and
# .sh files under the root trade each old spelling for the new one without
# touching look-alikes, dual-spelled lines, other slices, other file types or
# .git; --check and --dry-run report pending work and change nothing; a second
# run changes nothing; bad arguments are refused.
# shellcheck disable=SC2016  # fixture lines carry a literal $R
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MOVE="$HERE/move-renamed-dirs.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/move-renamed-dirs.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '    got: %s\n' "$2"; fail=1; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 (want '$2')" "$3"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) bad "$1 (want '$2' in it)" "$3" ;; esac; }

reg="$tmp/registry.tsv"
{
  printf '# fixture registry\nold\tnew\tkind\tdirection\tslice\tremove-at\n'
  printf '%s\t%s\t%s\tfail\tZ\tnever\n' tools/oldkit tools/newkit directory tools/oldbox tools/newbox directory \
    docs/old-notes docs/new-notes directory oldkit newkit path
  printf 'tools/other\ttools/elsewhere\tdirectory\tfail\tY\tnever\n'
  printf 'OLDKIT_X\tNEWKIT_X\tidentifier\told-to-new\tZ\tX\n'
} > "$reg"

hroot="$tmp/handovers"
mkdir -p "$hroot/proj/sub" "$hroot/.git"
printf 'run bash tools/oldkit/go.sh\nand tools/oldbox/x.sh\n' > "$hroot/proj/a.md"
printf 'bash "$R/tools/oldkit/go.sh"\n' > "$hroot/proj/sub/b.sh"
printf '%s\n' \
  'see oldkit/README' \
  'keep tools/oldkit-extra/x' \
  'keep tools/oldbox.sh' \
  'the end of tools/oldbox.' \
  'keep my-oldkit' \
  'dual tools/oldkit and tools/newkit' \
  'two tools/oldkit tools/oldbox' \
  'other slice tools/other' \
  'identifier OLDKIT_X' \
  > "$hroot/proj/rules.md"
printf '{"cmd": "tools/oldkit/go.sh"}\n' > "$hroot/proj/arms.jsonl"
printf 'tools/oldkit\n' > "$hroot/.git/c.md"
printf 'nothing to see\n' > "$hroot/proj/clean.md"
snap() { find "$hroot" -type f -exec cksum {} + | sort; }
hrun() { bash "$MOVE" --slice Z --registry "$reg" --handover-root "$hroot" "$@" 2>&1; }

st=$(snap)
out=$(hrun --check); rc=$?
eq "--check before exits 1" 1 "$rc"
out=$(hrun --dry-run); rc=$?
eq "--dry-run exits 0" 0 "$rc"
has "--dry-run counts a markdown file" "$(printf '2\t%s' "$hroot/proj/a.md")" "$out"
has "--dry-run counts a shell file" "$(printf '1\t%s' "$hroot/proj/sub/b.sh")" "$out"
has "--dry-run prints a total" 'total: 7 replacements in 3 files' "$out"
eq "--dry-run changes nothing" "$st" "$(snap)"
out=$(hrun); rc=$?
eq "apply exits 0" 0 "$rc"
eq "rewrites markdown" "$(printf 'run bash tools/newkit/go.sh\nand tools/newbox/x.sh')" "$(cat "$hroot/proj/a.md")"
eq "rewrites shell" 'bash "$R/tools/newkit/go.sh"' "$(cat "$hroot/proj/sub/b.sh")"
want='see newkit/README
keep tools/oldkit-extra/x
keep tools/oldbox.sh
the end of tools/newbox.
keep my-oldkit
dual tools/oldkit and tools/newkit
two tools/newkit tools/newbox
other slice tools/other
identifier OLDKIT_X'
eq "whole path runs move; look-alikes, dual lines, other slices and identifiers stay" "$want" "$(cat "$hroot/proj/rules.md")"
eq "leaves a jsonl ledger" '{"cmd": "tools/oldkit/go.sh"}' "$(cat "$hroot/proj/arms.jsonl")"
eq "leaves .git" tools/oldkit "$(cat "$hroot/.git/c.md")"
st=$(snap)
out=$(hrun --check); rc=$?
eq "--check after exits 0" 0 "$rc"
out=$(hrun); rc=$?
eq "a second run exits 0" 0 "$rc"
eq "a second run changes nothing" "$st" "$(snap)"

out=$(bash "$MOVE" --slice Z --registry "$reg" --handover-root "$tmp/nope" 2>&1); rc=$?
eq "a missing handover root is refused" 2 "$rc"
out=$(bash "$MOVE" --registry "$reg" --handover-root "$hroot" 2>&1); rc=$?
eq "no --slice is a usage error" 2 "$rc"
out=$(bash "$MOVE" --slice Z --registry "$reg" 2>&1); rc=$?
eq "no --handover-root is a usage error" 2 "$rc"
out=$(bash "$MOVE" --slice Q --registry "$reg" --handover-root "$hroot" 2>&1); rc=$?
eq "a slice with no rows is refused" 2 "$rc"

[ "$fail" = 0 ] && echo "all passed" || exit 1
