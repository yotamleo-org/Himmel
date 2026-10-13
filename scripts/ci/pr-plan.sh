#!/usr/bin/env bash
# scripts/ci/pr-plan.sh — HIMMEL-5524: which pull_request jobs the diff can
# affect. Prints `key=value` lines (GITHUB_OUTPUT-compatible):
#   mode=full|impacted
#   reason=<why>
#   run_<group>=true|false     one per group in scripts/ci/pr-job-gates.txt
#
# Usage: pr-plan.sh <base-sha|''> [<head>]      (head defaults HEAD)
#
# BASE-SOURCED like impacted-selection.sh: the workflow runs this copy, which
# reads the input list from the BASE commit and delegates the full-vs-impacted
# decision to impacted-selection.sh (itself base-sourced, trust paths force
# `full`). A PR therefore cannot narrow its own gates except by editing the
# list, which lives under scripts/ci/ — a trust path.
#
# FAIL-CLOSED: no base, an unresolvable base or head, a selector verdict of
# `full`, a missing/empty input list at the base, or a changed path no group
# names prints every gate `true`. Exit 0 whenever a plan was printed; the
# workflow also treats a non-zero exit or empty output as all-true.
#
# Platform guard: bash 3.2+, git + grep; Linux CI is the only caller.
set -uo pipefail

base_arg="${1-}"
head_arg="${2:-HEAD}"
here="$(cd "$(dirname "$0")" && pwd)"
inputs_rel="scripts/ci/pr-job-gates.txt"

# groups_from_text <text> — the distinct non-benign group names, in file order.
groups_from_text() {
  printf '%s\n' "$1" | grep -vE '^[[:space:]]*(#|$)' | awk '{print $1}' | grep -v '^benign$' | awk '!s[$0]++'
}

# emit_all <value> <mode> <reason> <groups...>
emit_all() {
  local v="$1" m="$2" r="$3" g
  shift 3
  printf 'mode=%s\nreason=%s\n' "$m" "$r"
  for g in "$@"; do printf 'run_%s=%s\n' "$g" "$v"; done
}

# Without a readable list we cannot name the gates; fall back to the working
# copy's list so the consumer still gets every run_<group>=true it expects.
fallback_groups() {
  local f="$here/pr-job-gates.txt" t
  [ -f "$f" ] || return 0
  t=$(cat "$f")
  groups_from_text "$t"
}

full_plan() { # full_plan <reason>
  local g gs=()
  while IFS= read -r g; do [ -n "$g" ] && gs+=("$g"); done < <(fallback_groups)
  emit_all true full "$1" "${gs[@]}"
  exit 0
}

[ -n "$base_arg" ] || full_plan "no-base"
git rev-parse --verify --quiet --end-of-options "${base_arg}^{commit}" >/dev/null || full_plan "base-unresolved"
git rev-parse --verify --quiet --end-of-options "${head_arg}^{commit}" >/dev/null || full_plan "head-unresolved"
base_sha=$(git rev-parse --verify --quiet --end-of-options "${base_arg}^{commit}")

inputs=$(git show "${base_sha}:${inputs_rel}" 2>/dev/null) || inputs=""
[ -n "$inputs" ] || full_plan "base-predates-inputs"

verdict=$(bash "$here/impacted-selection.sh" "$base_sha" "$head_arg" 2>/dev/null) || full_plan "selector-failed"
mode=$(printf '%s\n' "$verdict" | sed -n 's/^mode //p' | head -1)

groups=()
while IFS= read -r g; do [ -n "$g" ] && groups+=("$g"); done < <(groups_from_text "$inputs")
[ "${#groups[@]}" -gt 0 ] || full_plan "inputs-empty"

if [ "$mode" != impacted ]; then
  reason=$(printf '%s\n' "$verdict" | sed -n 's/^reason //p' | head -1)
  emit_all true full "${reason:-selector-full}" "${groups[@]}"
  exit 0
fi

changed=$(printf '%s\n' "$verdict" | sed -n 's/^changed //p')
[ -n "$changed" ] || full_plan "no-changed-paths"

# Per-group regex lists, then one pass over the changed paths.
hit_file=$(mktemp "${TMPDIR:-/tmp}/pr-plan.XXXXXX") || full_plan "mktemp-failed"
trap 'rm -f "$hit_file"' EXIT
unknown=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  matched=0
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    grp=${line%%[[:space:]]*}
    re=${line#"$grp"}
    re=${re#"${re%%[![:space:]]*}"}
    [ -n "$re" ] || continue
    if printf '%s\n' "$path" | grep -qE -- "$re"; then  # pipefail-ok: one path line, far under PIPE_BUF
      matched=1
      [ "$grp" = benign ] || printf '%s\n' "$grp" >> "$hit_file"
    fi
  done <<EOF
$inputs
EOF
  if [ "$matched" -eq 0 ]; then unknown="$path"; break; fi
done <<EOF
$changed
EOF

[ -z "$unknown" ] || { emit_all true full "unknown-path: $unknown" "${groups[@]}"; exit 0; }

printf 'mode=impacted\nreason=base-sourced plan\n'
for g in "${groups[@]}"; do
  if grep -qxF -- "$g" "$hit_file"; then printf 'run_%s=true\n' "$g"; else printf 'run_%s=false\n' "$g"; fi
done
exit 0
