#!/usr/bin/env bash
# scripts/handover/move-renamed-dirs.sh — rewrite one rename slice's old
# directory and path spellings in a handover tree. The pairs come from the
# registry (scripts/lib/rename-aliases.tsv): every row of kind directory or
# path for the slice has its old spelling rewritten to the new one in the .md
# and .sh files under the handover root.
#
# A spelling matches as a whole path run: not preceded by a name character or
# a dot (a slash is fine, so an absolute path matches), and not followed by a
# name character or by a dot and a name character (so console-kit-x and
# scripts/console.sh stay). A line already naming a pair's new spelling is
# left as is for that pair (a guard that keeps both spellings for old-layout
# trees).
#
# Idempotent: a rewrite only replaces old spellings, so a second run changes
# nothing.
#
# Usage:
#   move-renamed-dirs.sh --slice <S> --handover-root <dir> [--registry <file>] [--check | --dry-run]
#       rewrite the old spellings in the .md and .sh files under <dir> (.git
#       pruned, nothing staged).
#   --dry-run prints a "<count><TAB><file>" line per file that would change,
#   then changes nothing. --check prints the same and exits 1 when anything is
#   pending.
# Exit: 0 done (or nothing pending), 1 --check found pending work, 2 refused
# (nothing changed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: move-renamed-dirs.sh --slice <S> --handover-root <dir> [--registry <file>] [--check | --dry-run]" >&2
  exit 2
}
registry="$HERE/../lib/rename-aliases.tsv" slice='' root='' mode=apply
while [ $# -gt 0 ]; do
  case "$1" in
    --slice) [ $# -ge 2 ] || usage; slice=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || usage; registry=$2; shift 2 ;;
    --handover-root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    --check) [ "$mode" = apply ] || usage; mode=check; shift ;;
    --dry-run) [ "$mode" = apply ] || usage; mode=dry; shift ;;
    *) usage ;;
  esac
done
[ -n "$slice" ] && [ -n "$root" ] || usage
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

[ -d "$root" ] || { echo "move-renamed-dirs: not a directory: $root" >&2; exit 2; }
find "$root" -name .git -prune -o -type f \( -name '*.md' -o -name '*.sh' \) -print0 > "$tmp/files" || exit 2
case "$mode" in apply) how=apply ;; *) how=count ;; esac
rewrite "$how" < "$tmp/files" > "$tmp/out" || { echo "move-renamed-dirs: rewrite under $root failed" >&2; exit 2; }
if report "$tmp/out"; then exit 0; fi
[ "$mode" = check ] && exit 1
exit 0
