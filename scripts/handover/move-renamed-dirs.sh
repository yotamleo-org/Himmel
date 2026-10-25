#!/usr/bin/env bash
# scripts/handover/move-renamed-dirs.sh — apply one rename slice's directory
# moves. The pairs come from the registry (scripts/lib/rename-aliases.tsv): a
# row of kind directory is git mv'd from old to new, and every row of kind
# directory or path for the slice has its old spelling rewritten to the new one
# in every tracked text file. No symlink stays at an old path.
#
# A spelling matches as a whole path run: not preceded by a name character or
# a dot (a slash is fine, so an absolute path matches), and not followed by a
# name character or by a dot and a name character (so console-kit-x and
# scripts/console.sh stay). A line carrying `old-term-ok: <reason>` is left as
# is, and so, for one pair, is a line already naming that pair's new spelling
# (a guard that keeps both spellings for old-layout trees).
#
# Idempotent: a pair already moved is skipped and a rewrite only replaces old
# spellings, so a second run changes nothing.
#
# Usage:
#   move-renamed-dirs.sh --slice <S> [--registry <file>] [--check | --dry-run] [--with-settings]
#       at a himmel worktree root: move, rewrite and stage. The registry itself,
#       docs/migration/renamed-identifiers.md, CHANGELOG files and the vault
#       template templates/luna-second-brain (its kit names are archive names in
#       a vault, not this tree's directories) keep the old spellings;
#       .claude/settings.json does too unless --with-settings, and
#       its pending count is printed.
#   move-renamed-dirs.sh --slice <S> --handover-root <dir> [--check | --dry-run]
#       rewrite the old spellings in the .md and .sh files under <dir> (.git
#       pruned, nothing staged).
#   --dry-run prints each pending move and a "<count><TAB><file>" line per file
#   that would change, then changes nothing. --check prints the same and exits
#   1 when anything is pending.
# Exit: 0 done (or nothing pending), 1 --check found pending work, 2 refused
# (nothing changed).
#
# Merge-forward: revert the move commit, merge main, run this again, commit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../lib/git-clean.sh" || exit 2
git_env_scrub   # not a git hook - safe to scrub GIT_INDEX_FILE too

usage() {
  echo "usage: move-renamed-dirs.sh --slice <S> [--registry <file>] [--handover-root <dir>] [--check | --dry-run] [--with-settings]" >&2
  exit 2
}
registry="$HERE/../lib/rename-aliases.tsv" slice='' root='' mode=apply with_settings=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slice) [ $# -ge 2 ] || usage; slice=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || usage; registry=$2; shift 2 ;;
    --handover-root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    --check) [ "$mode" = apply ] || usage; mode=check; shift ;;
    --dry-run) [ "$mode" = apply ] || usage; mode=dry; shift ;;
    --with-settings) with_settings=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$slice" ] || usage
[ -f "$registry" ] || { echo "move-renamed-dirs: registry missing: $registry" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/move-renamed-dirs.XXXXXX")" || exit 2 # prim-ok: the script sources no lib so it runs on either tree layout
trap 'rm -rf "$tmp"' EXIT
awk -F'\t' -v s="$slice" '!/^[[:space:]]*#/ && $5 == s && ($3 == "directory" || $3 == "path") && $1 != "" && $2 != "" { print $1 "\t" $2 "\t" $3 }' \
  "$registry" > "$tmp/rows" || exit 2
[ -s "$tmp/rows" ] || { echo "move-renamed-dirs: no directory or path rows for slice $slice in $registry" >&2; exit 2; }

# rewrite <apply|count>: read NUL-separated file names on stdin, print
# "<count><TAB><file>" for each file with old spellings, rewrite it when apply.
# shellcheck disable=SC2016  # perl source: $ must not expand here
REWRITE='
use strict; use warnings;
my ($mode, $rows) = @ARGV;
open my $rf, "<", $rows or die "rows: $!\n";
my @r;
while (<$rf>) { chomp; my ($o, $n) = split /\t/; push @r, [$o, $n] }
close $rf;
@r = sort { length($b->[0]) <=> length($a->[0]) } @r;
my @re = map { my $q = quotemeta $_->[0]; qr/(?<![A-Za-z0-9_.-])$q(?![A-Za-z0-9_-])(?!\.[A-Za-z0-9_])/ } @r;
local $/ = "\0";
while (my $f = <STDIN>) {
  chomp $f;
  next if -l $f || ! -f $f;
  open my $in, "<:raw", $f or die "$f: $!\n";
  my @lines = do { local $/ = "\n"; <$in> };
  close $in;
  my $n = 0;
  for my $l (@lines) {
    next if $l =~ /old-term-ok:\s*\S/;
    my $orig = $l;
    for my $i (0 .. $#r) {
      next if index($orig, $r[$i][1]) >= 0;
      my $c = ($l =~ s/$re[$i]/$r[$i][1]/g);
      $n += $c || 0;
    }
  }
  next unless $n;
  print "$n\t$f\n";
  next unless $mode eq "apply";
  open my $out, ">:raw", $f or die "$f: $!\n";
  print {$out} @lines or die "$f: $!\n";
  close $out or die "$f: $!\n";
}
'
rewrite() { perl -e "$REWRITE" "$1" "$tmp/rows"; }

report() { # report <rewrite output file> - print it and a total, return 1 when it is not empty
  [ -s "$1" ] || return 0
  cat "$1" # read-sink-ok: callers pass only this script's own rewrite output under $tmp
  awk -F'\t' '{ n += $1 } END { printf "total: %d replacements in %d files\n", n, NR }' "$1"
  return 1
}

if [ -n "$root" ]; then
  [ -d "$root" ] || { echo "move-renamed-dirs: not a directory: $root" >&2; exit 2; }
  find "$root" -name .git -prune -o -type f \( -name '*.md' -o -name '*.sh' \) -print0 > "$tmp/files" || exit 2
  case "$mode" in apply) how=apply ;; *) how=count ;; esac
  rewrite "$how" < "$tmp/files" > "$tmp/out" || { echo "move-renamed-dirs: rewrite under $root failed" >&2; exit 2; }
  if report "$tmp/out"; then exit 0; fi
  [ "$mode" = check ] && exit 1
  exit 0
fi

top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "move-renamed-dirs: not in a git worktree" >&2; exit 2; } # swallow-ok: a failed rev-parse exits 2 with its own message
[ "$top" = "$(pwd -P)" ] || { echo "move-renamed-dirs: run it at the worktree root ($top)" >&2; exit 2; }

errors=() moves=()
while IFS=$'\t' read -r old new kind; do
  [ "$kind" = directory ] || continue
  if [ -L "$old" ] || [ -L "$new" ]; then errors+=("$old or $new is a symlink"); continue; fi
  if [ -d "$old" ]; then
    if [ -e "$new" ]; then errors+=("$new already exists"); else moves+=("$old"$'\t'"$new"); fi
  elif [ ! -d "$new" ]; then
    errors+=("$old is missing")
  fi
done < "$tmp/rows"
if [ "${#errors[@]}" -gt 0 ]; then
  printf 'move-renamed-dirs: refused, nothing changed: %s\n' "${errors[@]}" >&2
  exit 2
fi

files() { # NUL-separated tracked text files naming an old spelling
  local pat=() old new kind rc
  while IFS=$'\t' read -r old new kind; do pat+=(-e "$old"); done < "$tmp/rows"
  git grep -lIzF "${pat[@]}" -- . ':!scripts/lib/rename-aliases.tsv' ':!docs/migration/renamed-identifiers.md' \
    ':!CHANGELOG*' ':!**/CHANGELOG*' ':!templates/luna-second-brain' ':!.claude/settings.json'
  rc=$?
  [ "$rc" -le 1 ] || return 2
  [ "$with_settings" = 1 ] && [ -f .claude/settings.json ] && printf '.claude/settings.json\0'
  return 0
}
settings_note() {
  [ "$with_settings" = 0 ] && [ -f .claude/settings.json ] || return 0
  printf '.claude/settings.json\0' | rewrite count > "$tmp/settings" || return 0 # swallow-ok: the note is advisory
  [ -s "$tmp/settings" ] && echo "excluded: .claude/settings.json keeps $(cut -f1 "$tmp/settings") old spellings (pass --with-settings)"
  return 0
}

if [ "$mode" != apply ]; then
  for m in ${moves[@]+"${moves[@]}"}; do echo "pending move: ${m%%$'\t'*} to ${m#*$'\t'}"; done
  files > "$tmp/files" || { echo "move-renamed-dirs: git grep failed" >&2; exit 2; }
  rewrite count < "$tmp/files" > "$tmp/out" || { echo "move-renamed-dirs: rewrite count failed" >&2; exit 2; }
  pending=0
  report "$tmp/out" || pending=1
  [ "${#moves[@]}" -gt 0 ] && pending=1
  settings_note
  [ "$mode" = check ] && exit "$pending"
  exit 0
fi

for m in ${moves[@]+"${moves[@]}"}; do
  old=${m%%$'\t'*} new=${m#*$'\t'}
  if ! { mkdir -p "$(dirname "$new")" && git mv -- "$old" "$new"; }; then
    echo "move-renamed-dirs: git mv $old failed" >&2; exit 1
  fi
  echo "moved $old to $new"
done
files > "$tmp/files" || { echo "move-renamed-dirs: git grep failed" >&2; exit 1; }
rewrite apply < "$tmp/files" > "$tmp/out" || { echo "move-renamed-dirs: rewrite failed" >&2; exit 1; }
if [ -s "$tmp/out" ]; then
  cut -f2- "$tmp/out" | tr '\n' '\0' | xargs -0 git add -- || { echo "move-renamed-dirs: git add failed" >&2; exit 1; }
fi
report "$tmp/out" || true
settings_note
exit 0
