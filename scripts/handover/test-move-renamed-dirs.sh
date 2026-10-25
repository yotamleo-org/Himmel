#!/usr/bin/env bash
# scripts/handover/test-move-renamed-dirs.sh — Covers move-renamed-dirs.sh in a
# sandbox git repo with a fixture registry of made-up pairs: each directory row
# moves with nothing left at the old path, every tracked reference trades the
# old spelling for the new one without touching look-alikes, marked or
# dual-spelled lines, the excluded files or settings (unless --with-settings),
# --check and --dry-run report pending work and change nothing, a second run
# changes nothing, and a bad tree is refused untouched. Handover mode rewrites
# the .md and .sh files under a fixture handover tree and nothing else.
# shellcheck disable=SC2016  # fixture lines carry a literal $ROOT / $R
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

newrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email t@example.invalid
  git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
}
repo="$tmp/repo"
newrepo "$repo"
for d in tools/oldkit tools/oldbox docs/old-notes tools/other; do mkdir -p "$repo/$d"; printf 'x\n' > "$repo/$d/f.sh"; done
chmod +x "$repo/tools/oldkit/f.sh"
mkdir -p "$repo/scripts/lib" "$repo/.claude" "$repo/docs/migration"
printf '%s\n' \
  'bash tools/oldkit/go.sh' \
  'run "$ROOT/tools/oldbox/x.sh"' \
  'see oldkit/README' \
  'keep tools/oldkit-extra/x' \
  'keep tools/oldbox.sh' \
  'the end of tools/oldbox.' \
  'keep my-oldkit' \
  'dual tools/oldkit and tools/newkit' \
  'marked tools/oldkit # old-term-ok: kept on purpose' \
  'two tools/oldkit tools/oldbox' \
  'other slice tools/other' \
  'identifier OLDKIT_X' \
  > "$repo/ref.sh"
printf 'docs/old-notes/a.md\t3\n' > "$repo/durations.tsv"
printf 'tools/oldkit\n' > "$repo/scripts/lib/rename-aliases.tsv"
printf 'tools/oldkit\n' > "$repo/docs/migration/renamed-identifiers.md"
printf 'tools/oldkit\n' > "$repo/CHANGELOG.md"
printf '{"allow": ["Bash(bash tools/oldkit/go.sh)"]}\n' > "$repo/.claude/settings.json"
ln -s tools/oldkit/f.sh "$repo/link"
git -C "$repo" add -A
git -C "$repo" commit -q -m base
run() { (cd "$repo" && bash "$MOVE" --slice Z --registry "$reg" "$@" 2>&1); }

out=$(run --check); rc=$?
eq "--check before the move exits 1" 1 "$rc"
has "--check names a pending move" 'pending move: tools/oldkit to tools/newkit' "$out"

before=$(git -C "$repo" status --porcelain)
out=$(run --dry-run); rc=$?
eq "--dry-run exits 0" 0 "$rc"
has "--dry-run prints a per-file count" "$(printf '6\tref.sh')" "$out"
has "--dry-run names the settings it leaves" 'excluded: .claude/settings.json keeps 1 old spellings' "$out"
eq "--dry-run changes nothing" "$before" "$(git -C "$repo" status --porcelain)"

out=$(run); rc=$?
eq "apply exits 0" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out"
for pair in 'tools/oldkit tools/newkit' 'tools/oldbox tools/newbox' 'docs/old-notes docs/new-notes'; do
  old=${pair% *} new=${pair#* }
  eq "$old is gone, no symlink left" no "$([ -e "$repo/$old" ] || [ -L "$repo/$old" ] && echo yes || echo no)"
  eq "$new is a real directory" yes "$([ -d "$repo/$new" ] && [ ! -L "$repo/$new" ] && echo yes || echo no)"
  eq "$new/f.sh is tracked and $old is not" "$new/f.sh" "$(git -C "$repo" ls-files -- "$new" "$old")"
done
eq "the executable bit moves with the file" 100755 "$(git -C "$repo" ls-files -s -- tools/newkit/f.sh | cut -d' ' -f1)"
eq "a row of another slice is not moved" yes "$([ -d "$repo/tools/other" ] && echo yes || echo no)"
want='bash tools/newkit/go.sh
run "$ROOT/tools/newbox/x.sh"
see newkit/README
keep tools/oldkit-extra/x
keep tools/oldbox.sh
the end of tools/newbox.
keep my-oldkit
dual tools/oldkit and tools/newkit
marked tools/oldkit # old-term-ok: kept on purpose
two tools/newkit tools/newbox
other slice tools/other
identifier OLDKIT_X'
eq "references move and look-alikes, marked and dual lines stay" "$want" "$(cat "$repo/ref.sh")"
eq "a tab-keyed data file is rewritten" "$(printf 'docs/new-notes/a.md\t3')" "$(cat "$repo/durations.tsv")"
for f in scripts/lib/rename-aliases.tsv docs/migration/renamed-identifiers.md CHANGELOG.md; do
  eq "$f keeps the old spelling" tools/oldkit "$(cat "$repo/$f")"
done
eq "settings keep the old spelling by default" '{"allow": ["Bash(bash tools/oldkit/go.sh)"]}' "$(cat "$repo/.claude/settings.json")"
has "apply names the settings it leaves" 'excluded: .claude/settings.json keeps 1 old spellings' "$out"
eq "a tracked symlink is not rewritten" tools/oldkit/f.sh "$(readlink "$repo/link")"
eq "everything is staged" "" "$(git -C "$repo" diff --name-only)"

out=$(run --check); rc=$?
eq "--check after the move exits 0" 0 "$rc"
before=$(git -C "$repo" status --porcelain)
out=$(run); rc=$?
eq "a second run exits 0" 0 "$rc"
eq "a second run changes nothing" "$before" "$(git -C "$repo" status --porcelain)"

out=$(run --with-settings); rc=$?
eq "--with-settings exits 0" 0 "$rc"
eq "--with-settings rewrites the settings" '{"allow": ["Bash(bash tools/newkit/go.sh)"]}' "$(cat "$repo/.claude/settings.json")"

# A tree the move cannot take is refused before anything changes.
refused() { # refused <name> <setup dirs...>: the dirs exist, the refusal names <want>
  local name=$1 want=$2 r="$tmp/$1"; shift 2
  newrepo "$r"
  for d in "$@"; do mkdir -p "$r/$d"; printf 'x\n' > "$r/$d/f.sh"; done
  printf 'tools/oldkit\n' > "$r/ref.sh"
  git -C "$r" add -A; git -C "$r" commit -q -m base
  [ "$name" = symlink ] && { mv "$r/tools/oldbox" "$r/tools/newbox"; ln -s newbox "$r/tools/oldbox"; }
  local st; st=$(git -C "$r" status --porcelain)
  out=$(cd "$r" && bash "$MOVE" --slice Z --registry "$reg" 2>&1); rc=$?
  eq "$name: refused with exit 2" 2 "$rc"
  has "$name: the refusal names the cause" "$want" "$out"
  eq "$name: the tree is untouched" "$st" "$(git -C "$r" status --porcelain)"
  eq "$name: no reference is rewritten" tools/oldkit "$(cat "$r/ref.sh")"
}
refused existing 'tools/newkit already exists' tools/oldkit tools/newkit tools/oldbox docs/old-notes
refused missing 'docs/old-notes is missing' tools/oldkit tools/oldbox
refused symlink 'tools/oldbox or tools/newbox is a symlink' tools/oldkit tools/oldbox docs/old-notes

out=$(cd "$repo" && bash "$MOVE" --registry "$reg" 2>&1); rc=$?
eq "no --slice is a usage error" 2 "$rc"
out=$(cd "$repo" && bash "$MOVE" --slice Q --registry "$reg" 2>&1); rc=$?
eq "a slice with no rows is refused" 2 "$rc"
out=$(cd "$repo/tools" && bash "$MOVE" --slice Z --registry "$reg" 2>&1); rc=$?
eq "a run below the worktree root is refused" 2 "$rc"

# Handover mode: a fixture handover tree.
hroot="$tmp/handovers"
mkdir -p "$hroot/proj/sub" "$hroot/.git"
printf 'run bash tools/oldkit/go.sh\nand tools/oldbox/x.sh\n' > "$hroot/proj/a.md"
printf 'bash "$R/tools/oldkit/go.sh"\n' > "$hroot/proj/sub/b.sh"
printf '{"cmd": "tools/oldkit/go.sh"}\n' > "$hroot/proj/arms.jsonl"
printf 'tools/oldkit\n' > "$hroot/.git/c.md"
printf 'nothing to see\n' > "$hroot/proj/clean.md"
snap() { find "$hroot" -type f -exec cksum {} + | sort; }
hrun() { bash "$MOVE" --slice Z --registry "$reg" --handover-root "$hroot" "$@" 2>&1; }

st=$(snap)
out=$(hrun --check); rc=$?
eq "handover --check before exits 1" 1 "$rc"
out=$(hrun --dry-run); rc=$?
eq "handover --dry-run exits 0" 0 "$rc"
has "handover --dry-run counts a markdown file" "$(printf '2\t%s' "$hroot/proj/a.md")" "$out"
has "handover --dry-run counts a shell file" "$(printf '1\t%s' "$hroot/proj/sub/b.sh")" "$out"
has "handover --dry-run prints a total" 'total: 3 replacements in 2 files' "$out"
eq "handover --dry-run changes nothing" "$st" "$(snap)"
out=$(hrun); rc=$?
eq "handover apply exits 0" 0 "$rc"
eq "handover rewrites markdown" "$(printf 'run bash tools/newkit/go.sh\nand tools/newbox/x.sh')" "$(cat "$hroot/proj/a.md")"
eq "handover rewrites shell" 'bash "$R/tools/newkit/go.sh"' "$(cat "$hroot/proj/sub/b.sh")"
eq "handover leaves a jsonl ledger" '{"cmd": "tools/oldkit/go.sh"}' "$(cat "$hroot/proj/arms.jsonl")"
eq "handover leaves .git" tools/oldkit "$(cat "$hroot/.git/c.md")"
st=$(snap)
out=$(hrun --check); rc=$?
eq "handover --check after exits 0" 0 "$rc"
out=$(hrun); rc=$?
eq "a second handover run exits 0" 0 "$rc"
eq "a second handover run changes nothing" "$st" "$(snap)"
out=$(bash "$MOVE" --slice Z --registry "$reg" --handover-root "$tmp/nope" 2>&1); rc=$?
eq "a missing handover root is refused" 2 "$rc"

[ "$fail" = 0 ] && echo "all passed" || exit 1
