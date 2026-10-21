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
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m base || { echo "FAIL: base commit failed"; exit 1; }
base=$(git -C "$repo" rev-parse HEAD) || { echo "FAIL: base HEAD lookup failed"; exit 1; }

# run_case <name> <expected rc> <path> <content>: commit <content> at <path> on a
# fresh branch off base, run the lint from the repo cwd, restore to base.
run_case() {
    local name="$1" want="$2" path="$3" content="$4" rc out head
    git -C "$repo" checkout -q -B case "$base" || { fail "$name: setup checkout failed"; return; }
    mkdir -p "$repo/$(dirname "$path")" || { fail "$name: setup mkdir failed"; return; }
    printf '%s\n' "$content" > "$repo/$path" || { fail "$name: setup write failed"; return; }
    git -C "$repo" add -A || { fail "$name: setup add failed"; return; }
    git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "case $name" || { fail "$name: setup commit failed"; return; }
    head=$(git -C "$repo" rev-parse HEAD) || { fail "$name: setup HEAD lookup failed"; return; }
    [ "$head" != "$base" ] || { fail "$name: setup produced no commit"; return; }
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

echo "== a literal added while renaming a file is refused =="
git -C "$repo" checkout -q -B case "$base"
for i in 1 2 3 4 5 6; do printf 'echo line %s\n' "$i"; done > "$repo/scripts/ren-src.sh"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "rename src" || { echo "FAIL: rename src commit failed"; exit 1; }
rbase=$(git -C "$repo" rev-parse HEAD) || { echo "FAIL: rename base lookup failed"; exit 1; }
git -C "$repo" mv scripts/ren-src.sh scripts/ren-dst.sh || { echo "FAIL: rename mv failed"; exit 1; }
printf '%s\n' "$SLUG_LINE" >> "$repo/scripts/ren-dst.sh"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "rename dst" || { echo "FAIL: rename dst commit failed"; exit 1; }
out=$(cd "$repo" && bash "$LINT" "$rbase" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "rename plus literal (rc=$rc)"; else fail "rename plus literal: want rc=1 got rc=$rc: $out"; fi

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

echo "== an added line whose text starts with ++ is scanned, not read as a file header =="
run_case "added line shaped like a diff file header" 1 scripts/pp.sh "++ b/scripts/pp.sh $SLUG_LINE"

echo "== classes name the value, not the host =="
# Real line from .github/workflows/ci-image.yml with the owner read from the workflow context.
# shellcheck disable=SC2016
GHCR_DERIVED='      IMAGE: ghcr.io/${{ github.repository_owner }}/himmel-ci'
GHCR_LITERAL='      IMAGE: ghcr.io/someone/himmel-ci'
run_case "ghcr path with a literal owner" 1 .github/workflows/ci-image.yml "$GHCR_LITERAL"
case "$LAST_OUT" in *ci-image.yml*ghcr-image*) pass "ghcr finding names file and class" ;; *) fail "ghcr finding names file and class: $LAST_OUT" ;; esac
run_case "ghcr path with the owner derived" 0 .github/workflows/ci-image.yml "$GHCR_DERIVED"
run_case "the CI runner user's home" 0 scripts/ci/gcp-runner-startup.sh 'chown -R runner:runner /home/runner/.bun'
run_case "the CI runner user's home alone" 0 scripts/ci/gcp-runner-startup.sh 'cd /home/runner'
run_case "a user whose name starts with runner (digit)" 1 scripts/ci/gcp-runner-startup.sh 'cp x /ho''me/runner2/.bun'
run_case "a user whose name starts with runner (dash)" 1 scripts/ci/gcp-runner-startup.sh 'cp x /ho''me/runner-admin/.bun'
# shellcheck disable=SC2016
run_case "a path variable ending in home" 0 scripts/probe.sh 'echo z > "$ROOT/home/outside.txt"'
run_case "pages url in first-party site config" 1 site/astro.config.mjs "const u = 'https://someone.github.io/Repo/';"

echo "== base handling =="
git -C "$repo" checkout -q -B case "$base"
printf '%s\n' "$SLUG_LINE" > "$repo/scripts/tip.sh"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "tip case" || { echo "FAIL: tip commit failed"; exit 1; }
tipsha=$(git -C "$repo" rev-parse HEAD) || { echo "FAIL: tip lookup failed"; exit 1; }
git -C "$repo" checkout -q --detach "$base"
out=$(cd "$repo" && bash "$LINT" "$base" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "HEAD at base scans nothing (rc=$rc)"; else fail "HEAD at base scans nothing: want rc=0 got rc=$rc: $out"; fi
out=$(cd "$repo" && PRE_COMMIT_TO_REF="$tipsha" bash "$LINT" "$base" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "PRE_COMMIT_TO_REF is the scanned tip (rc=$rc)"; else fail "PRE_COMMIT_TO_REF is the scanned tip: want rc=1 got rc=$rc: $out"; fi
out=$(cd "$repo" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true PRE_COMMIT_TO_REF="$tipsha" bash "$LINT" "$base" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "diff.noprefix does not hide the file (rc=$rc)"; else fail "diff.noprefix does not hide the file: want rc=1 got rc=$rc: $out"; fi
case "$out" in scripts/tip.sh:1:*|*$'\n'scripts/tip.sh:1:*) pass "diff.noprefix finding names the file" ;; *) fail "diff.noprefix finding names the file: $out" ;; esac
git -C "$repo" checkout -q -B case "$base"
mkdir -p "$repo/scripts/eval/scrape-bench/results"
printf '%s\n' "$SLUG_LINE" > "$repo/scripts/eval/scrape-bench/results/tip.json"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "allowlisted tip case" || { echo "FAIL: allowlisted tip commit failed"; exit 1; }
allowsha=$(git -C "$repo" rev-parse HEAD) || { echo "FAIL: allowlisted tip lookup failed"; exit 1; }
git -C "$repo" checkout -q --detach "$base"
out=$(cd "$repo" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true PRE_COMMIT_TO_REF="$allowsha" bash "$LINT" "$base" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "diff.noprefix keeps a ^-anchored allowlist path matching (rc=$rc)"; else fail "diff.noprefix keeps a ^-anchored allowlist path matching: want rc=0 got rc=$rc: $out"; fi

mainrepo="$tmp/mainrepo"
git init -q -b main "$mainrepo"
git -C "$mainrepo" config user.email t@example.invalid
git -C "$mainrepo" config user.name t
git -C "$mainrepo" config commit.gpgsign false
printf 'echo base\n' > "$mainrepo/base.sh"
git -C "$mainrepo" add -A
git -C "$mainrepo" -c core.hooksPath=/dev/null commit -q -m base || { echo "FAIL: main repo base commit failed"; exit 1; }
git -C "$mainrepo" checkout -q -b feature
printf '%s\n' "$SLUG_LINE" > "$mainrepo/gate.sh"
git -C "$mainrepo" add -A
git -C "$mainrepo" -c core.hooksPath=/dev/null commit -q -m feature || { echo "FAIL: main repo feature commit failed"; exit 1; }
out=$(cd "$mainrepo" && bash "$LINT" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "no argument falls back to main (rc=$rc)"; else fail "no argument falls back to main: want rc=1 got rc=$rc: $out"; fi

norepo="$tmp/norepo"
git init -q -b trunk "$norepo"
git -C "$norepo" config user.email t@example.invalid
git -C "$norepo" config user.name t
git -C "$norepo" config commit.gpgsign false
printf 'echo base\n' > "$norepo/base.sh"
git -C "$norepo" add -A
git -C "$norepo" -c core.hooksPath=/dev/null commit -q -m base || { echo "FAIL: trunk repo commit failed"; exit 1; }
out=$(cd "$norepo" && bash "$LINT" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "no usable base ref is a usage failure (rc=$rc)"; else fail "no usable base ref: want rc=2 got rc=$rc: $out"; fi

echo "== --staged scans the index, nothing else =="
git -C "$repo" checkout -q -B case "$base"
printf '%s\n' "$SLUG_LINE" > "$repo/scripts/staged.sh"
out=$(cd "$repo" && bash "$LINT" --staged 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "an unstaged literal is not scanned (rc=$rc)"; else fail "an unstaged literal is not scanned: want rc=0 got rc=$rc: $out"; fi
git -C "$repo" add scripts/staged.sh
out=$(cd "$repo" && bash "$LINT" --staged 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "a staged literal is refused (rc=$rc)"; else fail "a staged literal is refused: want rc=1 got rc=$rc: $out"; fi
case "$out" in *scripts/staged.sh:1:*repo-slug*) pass "staged finding names file, line and class" ;; *) fail "staged finding names file, line and class: $out" ;; esac
printf '%s # env-literal-ok: identity allowlist\n' "$SLUG_LINE" > "$repo/scripts/staged.sh"
git -C "$repo" add scripts/staged.sh
out=$(cd "$repo" && bash "$LINT" --staged 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "a staged literal with a marker passes (rc=$rc)"; else fail "a staged literal with a marker passes: want rc=0 got rc=$rc: $out"; fi
git -C "$repo" reset -q --hard "$base"

echo "== --tree scans every tracked file for the non-slug classes =="
tree_case() { # <name> <want rc> <path> <content>
    local name="$1" want="$2" path="$3" content="$4" rc out
    git -C "$repo" checkout -q -B case "$base" || { fail "$name: setup checkout failed"; return; }
    mkdir -p "$repo/$(dirname "$path")" || { fail "$name: setup mkdir failed"; return; }
    printf '%s\n' "$content" > "$repo/$path" || { fail "$name: setup write failed"; return; }
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "tree $name" || { fail "$name: setup commit failed"; return; }
    out=$(cd "$repo" && bash "$LINT" --tree 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then pass "$name (rc=$rc)"; else fail "$name: want rc=$want got rc=$rc: $out"; fi
    LAST_OUT="$out"
}
tree_case "a clean tree" 0 scripts/clean.sh 'echo ok'
tree_case "a committed pages url in a runtime file" 1 scripts/site.mjs "const u = 'https://someone.github.io/Repo/';"
case "$LAST_OUT" in *scripts/site.mjs:1:*pages-url*) pass "tree finding names file, line and class" ;; *) fail "tree finding names file, line and class: $LAST_OUT" ;; esac
tree_case "a committed ghcr literal" 1 scripts/img.sh "docker pull ghcr.io/someone/image:latest"
tree_case "a repo slug is left to HIMMEL-6495" 0 scripts/gate.sh "$SLUG_LINE"
tree_case "an allowlisted file" 0 scripts/test-gate.sh "const u = 'https://someone.github.io/Repo/';"
tree_case "a marker with a reason" 0 scripts/site2.mjs "const u = 'https://someone.github.io/Repo/'; // env-literal-ok: public docs link"

echo "== wired into pre-commit and CI =="
root="$(cd "$(dirname "$LINT")/../.." && pwd)"
staged_stage=$(awk '/^ *- id: no-new-hardcoded-env-values-staged$/{f=1; next} f&&/^ *- id:/{exit} f&&/^ *stages:/{print; exit}' "$root/.pre-commit-config.yaml")
case "$staged_stage" in *'[pre-commit]'*) pass "a pre-commit-stage hook runs the lint on the index" ;; *) fail "a pre-commit-stage hook runs the lint on the index: '$staged_stage'" ;; esac
if grep -Eq 'entry: bash scripts/ci/check-hardcoded-env-values\.sh --staged$' "$root/.pre-commit-config.yaml"; then pass "the hook entry passes --staged"; else fail "the hook entry passes --staged"; fi
if grep -Eq '^ +run: bash scripts/ci/check-hardcoded-env-values\.sh --tree$' "$root/.github/workflows/ci.yml"; then pass "ci.yml runs the whole-tree lint"; else fail "ci.yml runs the whole-tree lint"; fi
# shellcheck disable=SC2016
if grep -Eq '^ +bash "\$gate/check-hardcoded-env-values\.sh" "\$BASE_SHA"$' "$root/.github/workflows/ci.yml"; then pass "ci.yml runs the base copy of the lint over the PR range"; else fail "ci.yml runs the base copy of the lint over the PR range"; fi

if [ "$failures" -ne 0 ]; then
    printf '\n%d case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall cases passed\n'
