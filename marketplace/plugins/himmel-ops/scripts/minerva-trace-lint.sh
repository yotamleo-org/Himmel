#!/usr/bin/env bash
# minerva-trace-lint.sh <spec.md> <plan.md> [<alt-root>] — minerva's terminal
# step runs this before the execute hand-off; a non-zero exit sends the run back
# to the spec or plan stage. Rules:
#   1. A surface-shaped spec (its H1 or any H2 heading names status, report,
#      doctor, health, probe, check or inventory) or any spec that carries a
#      `## Fact ownership` section has that section checked: a table with an owner
#      column. Each row's existing-surfaces cell (column 2) cites backticked
#      repo-relative paths that exist, or reads `none (grep: <pattern>)` — the grep
#      is the mechanical inventory step, which self-answer mode cannot skip. A
#      backticked word that is not path-shaped (no `/`, no extension, no glob
#      character: a flag, an identifier) is not a path and is not looked up.
#   2. Every spec carries `## Invariants`: `none`, or lines opening with I<n>
#      (an indented continuation line may follow one).
#   3. Every I<n> appears in plan.md on a line that names a test (`test-`,
#      `.test.` or `Test:`).
# Paths resolve against the cwd's git top level, or <alt-root> when given (a spec kept
# in another repo, e.g. the state repo, cites paths of either). Every miss is named on stderr.
# Exit 0 ok, 1 refused, 2 usage. bash 3.2-safe.
set -u
set -f  # backticked cells are split into words below; never glob them

spec="${1:-}"; plan="${2:-}"; alt="${3:-}"  # alt: the spec's own repo root, a second place a cited path may exist
if [ ! -f "$spec" ] || [ ! -f "$plan" ]; then
  echo "minerva-trace-lint: usage: minerva-trace-lint.sh <spec.md> <plan.md> (both must exist)" >&2
  exit 2
fi
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

missing=""
add(){ missing="${missing}  - $1
"; }

# section <heading>: the body under that exact H2 (case-insensitive), up to the next H1/H2.
section(){
  awk -v want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    /^##?[[:space:]]/ {
      h = tolower($0); sub(/^#+[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h)
      insec = ($0 ~ /^##[[:space:]]/ && h == want); next
    }
    insec { print }' "$spec"
}

surface_words='status|report|doctor|health|probe|check|inventory'
# the trigger reads headings only, so moving a section never switches the check off
head_text="$(grep -E '^##?[[:space:]]' "$spec")"
if printf '%s\n' "$head_text" | grep -qiwE "$surface_words" \
   || printf '%s\n' "$head_text" | grep -qiE '^##[[:space:]]+fact ownership[[:space:]]*$'; then
  fo="$(section 'Fact ownership')"
  # one "fact<TAB>surfaces" line per data row under a header carrying an owner column
  rows="$(printf '%s\n' "$fo" | awk -F'|' '
    /^[[:space:]]*\|/ {
      if (!hdr) { for (i = 2; i < NF; i++) if (tolower($i) ~ /owner/ && tolower($i) !~ /non-?owner/) { oc = i; break }; if (oc) hdr = 1; next }
      if ($0 ~ /^[[:space:]]*\|[-:| ]+\|[[:space:]]*$/) next
      f = $2; s = $3; o = $oc; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f); gsub(/[[:space:]]/, "", o)
      if (o == "") print "!\t" f; else print f "\t" s
    }')"
  if [ -z "$rows" ]; then
    add "fact ownership: surface-shaped spec has no '## Fact ownership' table with an owner column and a data row"
  else
    while IFS="$(printf '\t')" read -r fact cell; do
      [ "$fact" = "!" ] && { add "fact ownership: row '$cell' names no owner"; continue; }
      # a grep record is complete only with a backticked pattern: none (grep: `pat`)
      # shellcheck disable=SC2016  # the backticks are literal delimiters
      printf '%s\n' "$cell" | grep -qE 'none \(grep: *`[^`]+`' && continue
      # shellcheck disable=SC2016  # the backticks are literal delimiters
      toks="$(printf '%s\n' "$cell" | grep -oE '`[^`]+`' | tr -d '`')"
      if [ -z "$toks" ]; then
        add "fact ownership: row '$fact' cites no backticked existing path and no 'none (grep: <pattern>)' record"
        continue
      fi
      npaths=0
      for t in $toks; do
        case "$t" in /*|..|../*|*/..|*/../*)
          npaths=$((npaths+1)); add "fact ownership: row '$fact' cites $t, which is not a path inside the repo"; continue;;
        esac
        case "$t" in -*) continue;; */*|*.*|*[*?[]*) ;; *) continue;; esac  # a flag or identifier is no path
        npaths=$((npaths+1))
        [ -e "$root/$t" ] || { [ -n "$alt" ] && [ -e "$alt/$t" ]; } \
          || add "fact ownership: row '$fact' cites $t, which does not exist under $root${alt:+ or $alt}"
      done
      [ "$npaths" -gt 0 ] || add "fact ownership: row '$fact' cites no backticked existing path and no 'none (grep: <pattern>)' record"
    done <<EOF
$rows
EOF
  fi
fi

inv="$(section 'Invariants' | grep -E '[^[:space:]]' || true)"
if [ -z "$inv" ]; then
  add "invariants: no '## Invariants' section (write 'none', or one I<n> line per one/never/always/every rule)"
elif printf '%s\n' "$inv" | grep -qvixE '[[:space:]]*none[[:space:].]*'; then  # none only as the sole content
  ids="$(printf '%s\n' "$inv" | sed -nE 's/^[[:space:]]*([-*][[:space:]]+)?(\*\*)?(I[0-9]+)([^0-9].*)?$/\3/p' | sort -u)"
  [ -n "$ids" ] || add "invariants: section lists no I<n> lines"
  # every rule line is an I<n> line; only an indented, unbulleted continuation may sit beside one
  stray="$(printf '%s\n' "$inv" | grep -vE '^[[:space:]]*([-*][[:space:]]+)?(\*\*)?I[0-9]+([^0-9]|$)' | grep -E '^[[:space:]]*[-*][[:space:]]|^[^[:space:]]' || true)"
  [ -z "$stray" ] || add "invariants: a line is not an I<n> line, so no test can trace it: $(printf '%s\n' "$stray" | head -n1)"
  for id in $ids; do
    grep -wE "$id" "$plan" | grep -qE 'test-|\.test\.|[Tt]est:' \
      || add "invariants: $id has no plan line naming its acceptance test (test-*, *.test.*, or Test:)"
  done
fi

if [ -n "$missing" ]; then
  printf 'minerva-trace-lint: REFUSED — fix the spec or plan before hand-off. Missing:\n%s' "$missing" >&2
  exit 1
fi
echo "minerva-trace-lint: ok"
