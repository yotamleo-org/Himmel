#!/usr/bin/env bash
# Usage: bash scripts/ci/test-check-no-absent-search-tools.sh
# shellcheck disable=SC2016  # the planted hook lines are literal text, not expansions
set -uo pipefail

CHECK="$(cd "$(dirname "$0")" && pwd)/check-no-absent-search-tools.sh"
FAILED=0
T="$(mktemp -d "${TMPDIR:-/tmp}/no-absent-search.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

expect() {
    local label=$1 want=$2 got=$3
    if [ "$got" = "$want" ]; then
        echo "PASS $label (rc=$got)"
    else
        echo "FAIL $label - expected rc=$want, got rc=$got"
        FAILED=$((FAILED + 1))
    fi
}

run() { bash "$CHECK" "$@" >/dev/null 2>&1; echo $?; }

expect "the repo agent files and hook refusals pass" 0 "$(run)"

printf -- '---\nname: x\ntools: Read, Grep, Glob, Bash\n---\nbody\n' >"$T/a-grep-glob.md"
printf -- '---\nname: x\ntools: Read, Bash, Glob\n---\nbody\n' >"$T/a-glob.md"
printf -- '---\nname: x\ntools: Read, Bash, WebFetch\n---\nbody\n' >"$T/a-clean.md"
printf -- '---\nname: x\ntools: Read, Bash\n---\nRead nearby code with Grep and Glob.\n' >"$T/a-body-only.md"
printf -- 'no frontmatter\ntools: Read, Grep\n' >"$T/a-no-fm.md"
expect "agent tools line with Grep and Glob is refused" 1 "$(run "$T/a-grep-glob.md")"
expect "agent tools line with Glob alone is refused" 1 "$(run "$T/a-glob.md")"
expect "agent tools line with Bash only passes" 0 "$(run "$T/a-clean.md")"
expect "a body that mentions Grep is not a tools line" 0 "$(run "$T/a-body-only.md")"
expect "a tools line outside frontmatter is not read" 0 "$(run "$T/a-no-fm.md")"

printf '%s\n' 'emit_deny "walks the disk. Use the Glob tool, or scope it."' >"$T/h-glob.sh"
printf '%s\n' 'deny "to search for the phrase, use the Grep tool."' >"$T/h-grep.sh"
printf '%s\n' 'emit_deny "Use find with -maxdepth N or git ls-files."' >"$T/h-clean.sh"
printf '%s\n' '# the Grep tool is not wired to this hook; use the Grep tool here is a comment' >"$T/h-comment.sh"
printf '%s\n' '[ "$TOOL" = Grep ] && exit 0' >"$T/h-match.sh"
expect "hook refusal saying Use the Glob tool is refused" 1 "$(run "$T/h-glob.sh")"
expect "hook refusal saying use the Grep tool is refused" 1 "$(run "$T/h-grep.sh")"
expect "hook refusal naming find and git ls-files passes" 0 "$(run "$T/h-clean.sh")"
expect "a comment that mentions the tool passes" 0 "$(run "$T/h-comment.sh")"
expect "a hook that matches on the tool name passes" 0 "$(run "$T/h-match.sh")"

expect "a missing file is rc 2" 2 "$(run "$T/none.md")"

if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED failed"
    exit 1
fi
echo "all passed"
