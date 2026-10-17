#!/usr/bin/env bash
# flag-parity.sh — docs name a --flag the script they cite does not have.
#
# For every tracked *.sh named in the docs, briefs and templates, takes the
# `--flag` tokens written AFTER the script name on the same line and checks that
# the script's source carries that exact token (usage header, case arm, or parser).
# A doc flag the script lacks is a FAIL. A flag a script's usage header declares
# that no doc mentions next to it is reported as advisory (--advisory), never a fail.
#
# Usage:
#   bash scripts/lint/flag-parity.sh                    # whole tree
#   bash scripts/lint/flag-parity.sh --staged           # only findings touching a staged file
#   bash scripts/lint/flag-parity.sh --changed A..B     # only findings touching a file changed in the range
#   bash scripts/lint/flag-parity.sh --baseline FILE    # accept the (doc, script, flag) rows in FILE
#   bash scripts/lint/flag-parity.sh --baseline FILE --write-baseline   # (re)write FILE from the findings
#   bash scripts/lint/flag-parity.sh --advisory         # also list undocumented usage-header flags
#   bash scripts/lint/flag-parity.sh --help
#
# Scope: docs/**/*.md, .claude/commands/*.md, marketplace/plugins/*/skills/**/SKILL.md
# (docs/handover/*template*.md sits under docs/). A script is resolved by repo path
# suffix, or by basename when exactly one tracked script has it; an ambiguous
# basename is skipped. The flags of a mention end at `|`, `&&`, `;` or the next
# script name on the line. A change to a script re-checks every doc citing it.
#
# Baseline: rows of `doc<TAB>script<TAB>flag`. Only a row not in it fails, so the
# gate lands green and refuses NEW drift. A stale row is harmless.
# ponytail: a flag counts as present if its token appears anywhere in the script's source, so a flag only a comment mentions passes; upgrade to usage-block parsing if that hides drift.
#
# Exit: 0 = clean, 1 = drift, 2 = usage error.
# bash 3.2-safe; cross-platform (Git Bash / macOS / Linux).

set -uo pipefail

mode=all
range=""
baseline=""
write_baseline=0
advisory=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --staged) mode=staged ;;
    --changed) mode=changed; shift; range="${1:-}"; [ -n "$range" ] || { echo "flag-parity: --changed needs a git range" >&2; exit 2; } ;;
    --baseline) shift; baseline="${1:-}"; [ -n "$baseline" ] || { echo "flag-parity: --baseline needs a file" >&2; exit 2; } ;;
    --write-baseline) write_baseline=1 ;;
    --advisory) advisory=1 ;;
    *) echo "flag-parity: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$write_baseline" = 1 ] && [ -z "$baseline" ]; then
  echo "flag-parity: --write-baseline needs --baseline FILE" >&2; exit 2
fi

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "flag-parity: not a git repository" >&2; exit 2; }
cd "$root" || exit 2

tmp=$(mktemp -d "${TMPDIR:-/tmp}/flag-parity.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

git ls-files -- '*.sh' > "$tmp/scripts"
git ls-files -- 'docs/*.md' '.claude/commands/*.md' 'marketplace/plugins/*/skills/*SKILL.md' > "$tmp/docs"
[ -s "$tmp/docs" ] || { echo "flag-parity: clean (no docs in scope)"; exit 0; }

# 1. doc mentions: doc<TAB>script<TAB>flag
# shellcheck disable=SC2046
awk -v scriptlist="$tmp/scripts" '
  BEGIN {
    while ((getline p < scriptlist) > 0) {
      full[p] = 1
      n = split(p, parts, "/"); b = parts[n]
      cnt[b]++; byb[b] = p
    }
    close(scriptlist)
  }
  function resolve(tok,   b, n, parts) {
    sub(/^\.\//, "", tok)
    if (tok in full) return tok
    n = split(tok, parts, "/"); b = parts[n]
    if (n == 1) return (cnt[b] == 1) ? byb[b] : ""
    if (cnt[b] == 1 && index(byb[b], tok) > 0 && substr(byb[b], length(byb[b]) - length(tok) + 1) == tok) return byb[b]
    return ""
  }
  {
    line = $0
    # collect script tokens with their offsets
    ns = 0; off = 0; rest = line
    while (match(rest, /[A-Za-z0-9_.\/+-]+\.sh/)) {
      tok = substr(rest, RSTART, RLENGTH)
      ns++; spos[ns] = off + RSTART; send[ns] = off + RSTART + RLENGTH; sres[ns] = resolve(tok)
      off += RSTART + RLENGTH - 1; rest = substr(rest, RSTART + RLENGTH)
    }
    for (i = 1; i <= ns; i++) {
      if (sres[i] == "") continue
      seg = substr(line, send[i])
      if (i < ns) seg = substr(line, send[i], spos[i + 1] - send[i])
      if (match(seg, /\|\||&&|;|\|/)) seg = substr(seg, 1, RSTART - 1)
      while (match(seg, /(^|[^A-Za-z0-9_-])--[A-Za-z][A-Za-z0-9-]*/)) {
        f = substr(seg, RSTART, RLENGTH)
        sub(/^[^-]*/, "", f)
        sub(/-+$/, "", f)
        print FILENAME "\t" sres[i] "\t" f
        seg = substr(seg, RSTART + RLENGTH)
      }
    }
  }
' $(cat "$tmp/docs") 2>/dev/null | sort -u > "$tmp/mentions"

# 2. keep the mentions whose flag the script does not carry
cut -f2 "$tmp/mentions" | sort -u > "$tmp/cited"
# one pass over the cited scripts: print script<TAB>flag for every flag token a script carries
# shellcheck disable=SC2046
awk '
  {
    line = $0
    while (match(line, /--[A-Za-z][A-Za-z0-9-]*/)) {
      f = substr(line, RSTART, RLENGTH); sub(/-+$/, "", f)
      if (!((FILENAME SUBSEP f) in have)) { have[FILENAME SUBSEP f] = 1; print FILENAME "\t" f }
      line = substr(line, RSTART + RLENGTH)
    }
  }
' $(cat "$tmp/cited") 2>/dev/null | sort -u > "$tmp/carried"

awk -F'\t' '
  FILENAME == ARGV[1] { have[$1 "\t" $2] = 1; next }
  !(($2 "\t" $3) in have) { print }
' "$tmp/carried" "$tmp/mentions" > "$tmp/drift"

# 3. scope to the files touched
case "$mode" in
  staged)  git diff --cached --name-only --diff-filter=ACMR > "$tmp/touched" ;;
  changed) git diff --name-only --diff-filter=ACMR "$range" > "$tmp/touched" || { echo "flag-parity: cannot diff $range" >&2; exit 2; } ;;
esac
if [ "$mode" != all ]; then
  awk -F'\t' 'FILENAME == ARGV[1] { t[$0] = 1; next } ($1 in t) || ($2 in t)' "$tmp/touched" "$tmp/drift" > "$tmp/scoped"
  mv "$tmp/scoped" "$tmp/drift"
fi

if [ "$write_baseline" = 1 ]; then
  { [ -f "$baseline" ] && grep '^#' "$baseline"; sort -u "$tmp/drift"; } > "$tmp/newbase"
  cp "$tmp/newbase" "$baseline"
  echo "flag-parity: wrote $(grep -vc '^#' "$baseline") baseline rows to $baseline"
  exit 0
fi

if [ -n "$baseline" ] && [ -f "$baseline" ]; then
  awk 'FILENAME == ARGV[1] { ok[$0] = 1; next } !($0 in ok)' "$baseline" "$tmp/drift" > "$tmp/new"
else
  cp "$tmp/drift" "$tmp/new"
fi

if [ "$advisory" = 1 ]; then
  # usage-header flags (leading comment block) that no doc mentions beside the script
  # shellcheck disable=SC2046
  awk '
    FNR == 1 { inhdr = 1 }
    inhdr && /^#/ {
      line = $0
      while (match(line, /--[A-Za-z][A-Za-z0-9-]*/)) {
        f = substr(line, RSTART, RLENGTH); sub(/-+$/, "", f)
        print FILENAME "\t" f
        line = substr(line, RSTART + RLENGTH)
      }
      next
    }
    inhdr && FNR > 1 && !/^#/ { inhdr = 0 }
  ' $(cat "$tmp/cited") 2>/dev/null | sort -u > "$tmp/declared"
  cut -f2,3 "$tmp/mentions" | sort -u > "$tmp/documented"
  comm -23 "$tmp/declared" "$tmp/documented" | sed 's/^/advisory: undocumented in any doc: /' | tr '\t' ' '
fi

if [ -s "$tmp/new" ]; then
  while IFS="$(printf '\t')" read -r doc script flag; do
    echo "$doc: names $flag but $script has no such flag"
  done < "$tmp/new"
  echo "flag-parity: $(wc -l < "$tmp/new" | tr -d ' ') doc flag(s) missing from the script they cite (fix the doc, or add the row to the baseline)" >&2
  exit 1
fi
echo "flag-parity: clean"
exit 0
