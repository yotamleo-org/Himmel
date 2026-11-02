#!/usr/bin/env bash
# scripts/handover/suite-coverage.sh — Read-only: says, per suite,
# whether CI actually runs it, DERIVED from scripts/ci/run-shell-tests.sh's own
# tables (never hand-copied, so it cannot drift from them).
#
#   suite-coverage.sh [--runner <run-shell-tests.sh>] [--root <repo-root>] <suite-path>...
#
# Verdicts (one line per suite):
#   not run in CI (SKIP_LIST) — uncovered      a SKIP_LIST entry; NEVER write "CI verifies"
#   superseded by <wrappers>                   SKIP_LIST entry whose reason names its --only wrappers,
#                                              each existing under --root and not in SKIP_LIST; else
#                                              the monolith is reported uncovered
#   nightly only (extended tier, cap Ns)       SUITE_TIER_DEFAULT "extended"
#   runs in PR CI (cap Ns)                     everything else
# The cap is read from the runner's _suite_timeout_for case table as data (Linux
# caps); the runner's shell is never executed.
# Exit 0 = every suite classified, 2 = usage / unreadable or unintelligible
# runner, 3 = at least one suite is unknown (printed as such).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner="$HERE/../ci/run-shell-tests.sh"
default_runner=1
root="$HERE/../.."
suites=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runner) [ $# -ge 2 ] || break; runner="$2"; default_runner=0; shift 2 ;;
    --root) [ $# -ge 2 ] || break; root="$2"; shift 2 ;;
    *) suites+=("$1"); shift ;;
  esac
done
if [ $# -gt 0 ] || [ ! -r "$runner" ] || [ "${#suites[@]}" -eq 0 ]; then
  echo "usage: suite-coverage.sh [--runner <run-shell-tests.sh>] [--root <repo-root>] <suite-path>..." >&2
  exit 2
fi

# table <VAR> — the body of the runner's `VAR="…"` block, entries one per line.
# Exit 1 when the block opens but never closes: an unterminated table swallows
# the rest of the runner, so it is unparseable, not merely long.
table() { awk -v v="$1" '$0 == v "=\"" {on=1; next} on && $0 == "\"" {closed=1; exit} on; END {exit on && !closed}' "$runner"; }
if ! skip_list="$(table SKIP_LIST)" || ! tier_list="$(table SUITE_TIER_DEFAULT)"; then
  echo "suite-coverage.sh: $runner has an unterminated SKIP_LIST / SUITE_TIER_DEFAULT table — not a run-shell-tests.sh this helper understands" >&2
  exit 2
fi

if [ -z "$skip_list" ] || [ -z "$tier_list" ]; then
  echo "suite-coverage.sh: $runner has no SKIP_LIST / SUITE_TIER_DEFAULT table — not a run-shell-tests.sh this helper understands" >&2
  exit 2
fi

# cap <suite> — the runner's per-suite timeout, READ AS DATA: the
# runner's shell is never sourced or eval'd. cap_arms holds "<glob-list><TAB><N>"
# per arm of the function's Linux `case "${1#./}"`; the `*)` arm is the default.
# A conditional arm with several literal printf values takes the largest (the
# runner's unset-environment branch). An arm with no literal number prints "?"
# and fails visibly rather than guessing a cap.
cap_arms="$(awk '
  /^_suite_timeout_for\(\) \{/ {fn=1}
  fn && /^  case "\$\{1#\.\/\}" in$/ {on=1; next}
  on && /^  esac/ {exit}
  on && /^    [^ #].*\)$/ {pat=$0; sub(/^    /, "", pat); sub(/\)$/, "", pat); n=0; arm=1; next}
  on && arm {l=$0; while (match(l, /printf \047[0-9]+\047/)) {v=substr(l, RSTART+8, RLENGTH-9); if (v+0 > n) n=v+0; l=substr(l, RSTART+RLENGTH)}}
  on && arm && /;;/ {print pat "\t" (n ? n : "?"); arm=0}
' "$runner")"
# shellcheck disable=SC2016 # a literal pattern for the runner's own source line
default_cap="$(grep -m1 -o '^SUITE_TIMEOUT=\$(_suite_num SUITE_TIMEOUT "\${SUITE_TIMEOUT:-[0-9][0-9]*}" [0-9][0-9]*)$' "$runner" | sed 's/.*:-\([0-9]*\)}.*/\1/')"
if [ -z "$cap_arms" ] || [ -z "$default_cap" ]; then
  echo "suite-coverage.sh: $runner has no readable _suite_timeout_for case table or SUITE_TIMEOUT default — not a run-shell-tests.sh this helper understands" >&2
  exit 2
fi
cap() {
  local line pats n pat rest s="${1#./}"
  while IFS= read -r line; do
    pats="${line%%$'\t'*}"; n="${line##*$'\t'}"
    if [ "$pats" = '*' ]; then printf '%s' "$default_cap"; return 0; fi
    rest="$pats|"
    while [ -n "$rest" ]; do
      pat="${rest%%|*}"; rest="${rest#*|}"
      # shellcheck disable=SC2053 # $pat is a glob on purpose; [[ == ]] matches it without evaluating anything
      if [[ "$s" == $pat ]]; then
        case "$n" in ''|*[!0-9]*) return 1 ;; esac
        printf '%s' "$n"; return 0
      fi
    done
  done <<< "$cap_arms"
  return 1
}

# entry_for <table> <suite> — the table line designating the suite (full-path
# match on a "/" boundary, same as the runner's suite_entry_matches).
entry_for() {
  local line path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%#*}"; path="$(printf '%s' "$path" | awk '{print $1}')"
    case "$2" in "$path"|*"/$path") printf '%s\n' "$line"; return 0 ;; esac
  done <<< "$1"
  return 1
}

rc=0
for s in "${suites[@]}"; do
  s="${s#./}"
  if line="$(entry_for "$skip_list" "$s")"; then
    reason="${line#*#}"
    if grep -q 'superseded by' <<< "$reason"; then
      wrappers="$(grep -o 'test-[A-Za-z0-9._-]*\.sh' <<< "$reason" | grep -vxF "$(basename "$s")" | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')"
      # a wrapper carries the coverage only if it exists next to the monolith and is not itself skipped
      lost=""
      for w in $(tr -d ',' <<< "$wrappers"); do
        wp="$(dirname "$s")/$w"
        if [ ! -f "$root/$wp" ]; then lost="${lost:+$lost, }$w (missing)"
        elif entry_for "$skip_list" "$wp" >/dev/null; then lost="${lost:+$lost, }$w (in SKIP_LIST)"; fi
      done
      if [ -z "$wrappers" ]; then
        echo "$s: not run in CI (SKIP_LIST) — uncovered; its reason names no wrapper, so none can be confirmed — never write \"CI verifies\" for it"
      elif [ -n "$lost" ]; then
        echo "$s: not run in CI (SKIP_LIST) — uncovered; superseded by wrappers that do not carry it: $lost — never write \"CI verifies\" for it"
      else
        echo "$s: superseded by $wrappers (monolith in SKIP_LIST; the wrappers carry the coverage)"
      fi
    else
      echo "$s: not run in CI (SKIP_LIST) — uncovered; never write \"CI verifies\" for it —${reason}"
    fi
  elif [ "$default_runner" -eq 1 ] && { [ ! -f "$root/$s" ] || [[ "$(basename "$s")" != test-*.sh ]]; }; then
    echo "$s: unknown — not an existing test-*.sh suite in this repo; coverage cannot be stated"
    rc=3
  else
    c="$(cap "$s")"
    case "$c" in ''|*[!0-9]*) echo "suite-coverage.sh: could not evaluate the runner's cap for $s" >&2; exit 2 ;; esac
    if line="$(entry_for "$tier_list" "$s")" && [ "$(awk '{print $2}' <<< "$line")" = extended ]; then
      echo "$s: nightly only (extended tier, cap ${c}s) — not in per-PR CI"
    else
      echo "$s: runs in PR CI (cap ${c}s)"
    fi
  fi
done
exit "$rc"
