#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# Test for scripts/ci/check-hardcoded-env-values.sh.
#
# Fixture lines are copied from the real tree: the jira-host line is
# scripts/handover/pr-open.sh as it stood before the migration, the slug line
# is merge-on-green.sh's HIMMEL_PUBLIC_ORIGIN_NWO.
#
# Usage: bash scripts/ci/test-check-hardcoded-env-values.sh
set -uo pipefail

LINT="$(cd "$(dirname "$0")" && pwd)/check-hardcoded-env-values.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h6508.XXXXXX") || { echo "setup: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC2016  # literal fixture text, nothing should expand
JIRA_LINE='    ticket_block="- ${ticket}: https://${project_key_lc}.atlassian.net/browse/${ticket}"'
SLUG_LINE='HIMMEL_PUBLIC_ORIGIN_NWO="yotamleo-org/Himmel"'

repo="$tmp/repo"
mkdir -p "$repo/scripts"
git init -q "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
printf '#!/usr/bin/env bash\necho base\n' > "$repo/scripts/base.sh"
git -C "$repo" add -A
git -C "$repo" commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)

# run_case <name> <expected rc> <path> <content>: commit <content> at <path> on a
# fresh branch off base, run the lint from the repo cwd, restore to base.
run_case() {
    local name="$1" want="$2" path="$3" content="$4" rc out
    git -C "$repo" checkout -q -B case "$base"
    mkdir -p "$repo/$(dirname "$path")"
    printf '%s\n' "$content" > "$repo/$path"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "case $name"
    out=$(cd "$repo" && bash "$LINT" "$base" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then pass "$name (rc=$rc)"; else fail "$name: want rc=$want got rc=$rc: $out"; fi
    LAST_OUT="$out"
}

echo "== planted runtime literals are refused =="
run_case "jira host literal in a runtime script" 1 scripts/pr-open.sh "$JIRA_LINE"
case "$LAST_OUT" in *scripts/pr-open.sh*jira-host*) pass "finding names file and class" ;; *) fail "finding names file and class: $LAST_OUT" ;; esac
run_case "repo slug literal in a runtime script" 1 scripts/gate.sh "$SLUG_LINE"
run_case "pages url literal" 1 scripts/site.mjs "const u = 'https://someone.github.io/Repo/';"
run_case "ghcr image literal" 1 scripts/img.sh "docker pull ghcr.io/someone/image:latest"
run_case "home path literal" 1 scripts/hp.sh "cd /ho""me/alice/work"

echo "== allowlisted shapes pass =="
run_case "same literal in a test file" 0 scripts/test-gate.sh "$SLUG_LINE"
run_case "same literal under a fixtures dir" 0 scripts/fixtures/x.json "$SLUG_LINE"
run_case "same literal in a markdown doc" 0 docs/page.md "$SLUG_LINE"
run_case "marker with a reason" 0 scripts/gate2.sh "$SLUG_LINE # env-literal-ok: identity allowlist"
run_case "comment-only line" 0 scripts/note.sh "# measured on someone.github.io in 2026"
# shellcheck disable=SC2016
run_case "no literal at all" 0 scripts/clean.sh 'echo "${JIRA_BASE_URL%/}/browse/X"'

echo "== marker without a reason is refused =="
run_case "bare marker" 1 scripts/gate3.sh "$SLUG_LINE # env-literal-ok:"

if [ "$failures" -ne 0 ]; then
    printf '\n%d case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall cases passed\n'
