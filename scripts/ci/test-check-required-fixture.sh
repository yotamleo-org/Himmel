#!/usr/bin/env bash
# scripts/ci/test-check-required-fixture.sh — check-required-fixture.sh against
# a stub gh serving the live rules/branches answer.
#
# Usage: bash scripts/ci/test-check-required-fixture.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/check-required-fixture.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-check-required-fixture.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
    "api repos/octo/demo/rules/branches/main")
        [ -z "${STUB_FAIL:-}" ] || { echo "gh: boom (HTTP 500)" >&2; exit 1; }
        printf '%s' "$STUB_RULES"; exit 0 ;;
esac
echo "gh-stub: unhandled args: $*" >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"

rules_of() {
    printf '[{"type":"deletion"},{"type":"required_status_checks","parameters":{"required_status_checks":['
    local first=1 n
    for n in "$@"; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"context":"%s","integration_id":15368}' "$n"
    done
    printf ']}}]'
}
rules_of lint build > "$tmp/rules.json"
printf 'build\nlint\n' > "$tmp/contexts.txt"
printf '# comment\n\nsecurity/snyk (yotamleo)\n' > "$tmp/non-gating.txt"

run() {
    out=$(PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/gh.log" \
        REQUIRED_FIXTURE_RULES="$tmp/rules.json" REQUIRED_FIXTURE_CONTEXTS="$tmp/contexts.txt" \
        NON_GATING_CONTEXTS_FILE="$tmp/non-gating.txt" \
        bash "$SCRIPT" --repo octo/demo --branch main 2>&1)
    rc=$?
}
expect() {
    if [ "$rc" -ne "$2" ]; then bad "$1: exit $rc, want $2 (out: $out)"; return; fi
    if [ -n "${3:-}" ] && ! grep -qF -- "$3" <<< "$out"; then bad "$1: output lacks [$3] (out: $out)"; return; fi
    ok "$1"
}

STUB_RULES=$(rules_of build lint) run
expect "fixtures match live protection: exit 0" 0 "required-fixture: OK"

STUB_RULES=$(rules_of build lint git-env-scrub) run
expect "a live required check missing from the rules fixture: exit 1" 1 "missing-from-rules-fixture: git-env-scrub"
if grep -qF -- "missing-from-contexts-fixture: git-env-scrub" <<< "$out"; then ok "the contexts fixture is named too"; else bad "the contexts fixture is named too (out: $out)"; fi

STUB_RULES=$(rules_of build) run
expect "a fixture name live protection no longer requires: exit 1" 1 "stale-in-rules-fixture: lint"

STUB_RULES=$(rules_of build lint "security/snyk (yotamleo)") run
expect "a non-gating context that is required: exit 1" 1 "non-gating-but-required: security/snyk (yotamleo)"

STUB_RULES='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build","integration_id":999},{"context":"lint","integration_id":15368}]}}]' run
expect "a required check pinned to another app than the fixture's: exit 1" 1 "missing-from-rules-fixture: build (app 999)"
if [ "$(grep -cF -- "contexts-fixture" <<< "$out")" = 0 ]; then ok "an app-pin drift leaves the names-only contexts fixture quiet"; else bad "an app-pin drift leaves the names-only contexts fixture quiet (out: $out)"; fi

printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build","integration_id":"15368"},{"context":"lint","integration_id":15368}]}}]' > "$tmp/rules.json"
STUB_RULES=$(rules_of build lint) run
expect "a fixture pin written as a string is drift, never equal to the number: exit 1" 1 'stale-in-rules-fixture: build (app invalid "15368")'
rules_of lint build > "$tmp/rules.json"

STUB_FAIL=1 STUB_RULES=x run
expect "an unreadable live read: exit 2" 2

STUB_RULES='[]' run
expect "no required checks live is unreadable, never a match: exit 2" 2

echo "---"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
