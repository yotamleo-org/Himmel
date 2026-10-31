#!/usr/bin/env bash
# scripts/ci/check-flags.sh — the feature-flag registry check. Fails on:
#   expired      a scripts/lib/flags.tsv row whose expires date has passed (14 days from birth)
#   unregistered a flag read in code (himmel_flag <n>, himmel_flag("n"), himmelFlag('n'),
#                HIMMEL_FLAG_<N>) that the registry does not list
#   unread       a registered flag that no code reads
#   forbidden    a flag read under scripts/hooks/, in a gate script (scripts/cr/,
#                merge-on-green.sh, go.sh, merge-forward-check.sh) or on a path in ci-trust-paths.txt or
#                ci-trust-paths-core.txt, or in a file one of those sources or execs by a literal
#                path (one level down): a flag never wraps a safety rail
#   malformed / duplicate   a registry row that is not 7 columns, has a default other than
#                on|off, a kind other than feature|content, a bad date, or repeats a name
#
# Usage: check-flags.sh [--root DIR] [--today YYYY-MM-DD]
# Not a read: the readers (scripts/lib/flags.{sh,py,mjs}), the registry, this script, markdown,
# and test files (test-*, *.test.*, fixtures/, tests/): a suite sets a flag to exercise both states.
#
# ponytail: a text match, not data flow: a flag name built at run time is not seen, and a
# comment that names a flag counts as a read, a call split across lines is not seen, and `expires`
# is checked as a date only (no birth column, so the 14-day cap is the author's); upgrade path is an AST rule in the swallowed-error lint family.
#
# A flag with 3 days or fewer left prints `WARN flag <name> expires <date> (in <n> days)` and does not fail.
#
# Exit: 0 clean; 1 findings (one `FAIL <class>: ...` line each); 2 usage or unreadable registry.
# Platform guard: POSIX bash 3.2+, git or find, grep, awk, xargs.
set -uo pipefail

usage() { echo "usage: check-flags.sh [--root DIR] [--today YYYY-MM-DD]" >&2; exit 2; }

ROOT="" TODAY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || usage ;;
    --today) TODAY="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -n "$TODAY" ] || TODAY="$(date +%F)"
case "$TODAY" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) usage ;; esac

REG="$ROOT/scripts/lib/flags.tsv"
[ -r "$REG" ] || { echo "check-flags: cannot read the registry $REG (fail-closed)" >&2; exit 2; }

# shellcheck source=../lib/prim.sh
. "$(dirname "$0")/../lib/prim.sh" || { echo "check-flags: cannot load prim.sh (fail-closed)" >&2; exit 2; }
SCRATCH="$(tmpdir)" || { echo "check-flags: cannot allocate scratch (fail-closed)" >&2; exit 2; }
trap 'rm -rf "$SCRATCH"' EXIT
findings=0
# real_date YYYY-MM-DD: month 01-12 and a day that month has (leap years counted)
real_date() {
  local y="${1%%-*}" m d max
  m=$((10#${1:5:2})); d=$((10#${1:8:2}))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] || return 1
  case "$m" in
    4|6|9|11) max=30 ;;
    2) max=28; y=$((10#$y)); { [ $((y % 400)) = 0 ] || { [ $((y % 4)) = 0 ] && [ $((y % 100)) != 0 ]; }; } && max=29 ;;
    *) max=31 ;;
  esac
  [ "$d" -le "$max" ]
}
finding() { printf 'FAIL %s\n' "$1"; findings=$((findings + 1)); }
# day_num YYYY-MM-DD: a day count (days from civil), so two dates subtract to the days between them
day_num() {
  local y m d
  y=$((10#${1:0:4})); m=$((10#${1:5:2})); d=$((10#${1:8:2}))
  if [ "$m" -le 2 ]; then y=$((y - 1)); m=$((m + 12)); fi
  echo $((365 * y + y / 4 - y / 100 + y / 400 + (153 * (m - 3) + 2) / 5 + d))
}

# --- registry ---
NAMES="$SCRATCH/names"; : > "$NAMES"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  name="$(printf '%s' "$line" | cut -f1)"
  ncols="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  default="$(printf '%s' "$line" | cut -f2)"
  kind="$(printf '%s' "$line" | cut -f3)"
  owner="$(printf '%s' "$line" | cut -f4)"
  removal="$(printf '%s' "$line" | cut -f5)"
  expires="$(printf '%s' "$line" | cut -f6)"
  if [ "$ncols" -ne 7 ] || ! printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9_]*$' \
     || { [ "$default" != on ] && [ "$default" != off ]; } \
     || { [ "$kind" != feature ] && [ "$kind" != content ]; } \
     || [ -z "$owner" ] || [ -z "$removal" ] \
     || ! printf '%s' "$expires" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || ! real_date "$expires"; then
    finding "malformed: ${name:-?} (want 7 tab-separated columns: name, default on|off, kind feature|content, owner, removal, expires YYYY-MM-DD, description)"
    continue
  fi
  if grep -qxF "$name" "$NAMES"; then finding "duplicate: $name"; continue; fi
  printf '%s\n' "$name" >> "$NAMES"
  [ "$expires" \< "$TODAY" ] && finding "expired: $name (expires $expires, today $TODAY; remove the flag or file the flip)"
  left=$(($(day_num "$expires") - $(day_num "$TODAY")))
  if [ "$left" -ge 0 ] && [ "$left" -le 3 ]; then printf 'WARN flag %s expires %s (in %d days)\n' "$name" "$expires" "$left"; fi
done < "$REG"

# --- code reads ---
FILES="$SCRATCH/files"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$ROOT" ls-files -co --exclude-standard
else
  (cd "$ROOT" && find . -type f -not -path './.git/*' | sed 's|^\./||')
fi | grep -Ev '^scripts/lib/flags\.(sh|py|mjs|tsv)$|^scripts/ci/(check-flags|test-check-flags)\.sh$|^scripts/lib/test-flags\.sh$|\.md$|(^|/)test-[^/]*$|\.test\.[a-z]+$|(^|/)(fixtures|tests|test|node_modules)/' > "$FILES"

READS="$SCRATCH/reads"; : > "$READS"   # <name>\t<file>
if [ -s "$FILES" ]; then
  PATS="$SCRATCH/patterns"; RAW="$SCRATCH/raw"
  printf '%s\n' \
    'himmel_flag[[:space:]]+["'"'"']?[a-z][a-z0-9_]*' \
    'himmel_?[fF]lag\([[:space:]]*["'"'"'][a-z][a-z0-9_]*' \
    'HIMMEL_FLAG_[A-Z][A-Z0-9_]*' > "$PATS"
  # grep exits 1 for "no match" (fine) and 2 for an error (unreadable file): only 2 fails the scan
  # shellcheck disable=SC2016  # the sh -c body is literal; $0 and "$@" expand in the child
  tr '\n' '\0' < "$FILES" | (cd "$ROOT" && xargs -0 sh -c 'grep -IHoE -f "$0" -- "$@"; [ "$?" -le 1 ]' "$PATS") > "$RAW" \
    || { echo "check-flags: the source scan failed (an unreadable file?) (fail-closed)" >&2; exit 2; }
  awk -F: '{
      file = $1; m = substr($0, length(file) + 2)
      if (m ~ /^HIMMEL_FLAG_/) { sub(/^HIMMEL_FLAG_/, "", m); n = tolower(m) }
      else { sub(/^himmel_?[fF]lag/, "", m); sub(/^[^a-z]+/, "", m); n = m }
      print n "\t" file
    }' "$RAW" | sort -u > "$READS"
fi

TRUST="$SCRATCH/trust"
{ for f in "$ROOT/scripts/ci/ci-trust-paths.txt" "$ROOT/scripts/ci/ci-trust-paths-core.txt"; do
    [ -r "$f" ] || { echo "check-flags: cannot read $f (fail-closed)" >&2; exit 2; }
    grep -Ev '^[[:space:]]*(#|$)' "$f"
  done; } > "$TRUST"
GATE_RE='^scripts/hooks/|^scripts/cr/|(^|/)merge-on-green\.sh$|(^|/)go\.sh$|(^|/)merge-forward-check\.sh$'
GATES="$SCRATCH/gates"
{ grep -E "$GATE_RE" "$FILES"; [ -s "$TRUST" ] && grep -E -f "$TRUST" "$FILES"; } | sort -u > "$GATES"

while IFS="$(printf '\t')" read -r name file; do
  [ -n "$name" ] || continue
  if ! grep -qxF "$name" "$NAMES"; then
    finding "unregistered: $name read in $file (add a row to scripts/lib/flags.tsv)"
  fi
  if printf '%s\n' "$file" | grep -Eq "$GATE_RE" \
     || { [ -s "$TRUST" ] && printf '%s\n' "$file" | grep -Eq -f "$TRUST"; }; then
    finding "forbidden: $name read in $file (a flag never wraps a hook, a gate or a ci-trust-paths path)"
  fi
done < "$READS"

# one level down: a file a gate sources or execs by a literal path is checked as that gate.
# A settings.json permission row (`"Bash(bash scripts/x.sh:*)"`) names a script without running it, so it is no reach.
# The path is read after `.`, source, bash, sh, exec or python3 (options skipped): a bare relative path
# resolves against the gate's directory, `scripts/...` against the root, and `"$VAR/x"` against both.
# ponytail: one level and literal paths only (a computed path or a helper's own helper is not followed);
# upgrade path is a call graph in the same AST rule as the read scan.
norm_path() {
  local IFS=/ p o=""
  for p in $1; do
    case "$p" in ''|.) ;; ..) case "$o" in */*) o="${o%/*}" ;; *) o="" ;; esac ;; *) o="${o:+$o/}$p" ;; esac
  done
  printf '%s' "$o"
}
# shellcheck disable=SC2094  # $GATES is only read here; the pipeline writes $SCRATCH/reached
while IFS= read -r gate; do
  [ -r "$ROOT/$gate" ] || continue
  gdir="$(dirname "$gate")"
  # a settings.json `"Bash(...)"` permission row (one per line) names a script without running it
  grep -vE '^[[:space:]]*"Bash\(' "$ROOT/$gate" 2>/dev/null \
    | grep -oE '(^|[;&|({[:space:]])((\.|source|bash|sh|exec|python3)([[:space:]]+-[A-Za-z]+)*[[:space:]]+)+"?(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)?[A-Za-z0-9_./-]+' \
    | sed -E 's/.*[[:space:]]"?//' | sort -u | while IFS= read -r ref; do
    case "$ref" in
      '$'*) cands="$(norm_path "$gdir/${ref#*/}") $(norm_path "${ref#*/}")" ;;
      scripts/*) cands="$(norm_path "$ref")" ;;
      *) cands="$(norm_path "$gdir/$ref")" ;;
    esac
    for helper in $cands; do
      [ "$helper" != "$gate" ] || continue
      grep -qxF "$helper" "$GATES" && continue
      awk -F'\t' -v f="$helper" '$2 == f {print $1}' "$READS" | while IFS= read -r name; do
        printf 'forbidden: %s read in %s (reached from %s)\n' "$name" "$helper" "$gate"
      done
    done
  done
done < "$GATES" | sort -u > "$SCRATCH/reached"
while IFS= read -r line; do finding "$line"; done < "$SCRATCH/reached"

while IFS= read -r name; do
  cut -f1 "$READS" | grep -qxF "$name" || finding "unread: $name (registered, but no code reads it; delete the row or add the read)"
done < "$NAMES"

[ "$findings" = 0 ] && { echo "check-flags: OK ($(wc -l < "$NAMES" | tr -d ' ') flag(s) registered)"; exit 0; }
echo "check-flags: $findings finding(s)" >&2
exit 1
