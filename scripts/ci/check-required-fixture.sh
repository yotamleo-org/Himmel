#!/usr/bin/env bash
# scripts/ci/check-required-fixture.sh — do the committed copies of the
# required-check list still match the branch's live protection?
#
# Reads rules/branches/<branch> (rulesets, the layer that carries main's
# required checks) and compares its required_status_checks contexts with:
#   - scripts/ci/check-run-timelines/testdata/rules-main.json (the suites' fixture)
#   - scripts/ci/fixtures/ci-go-gate-required-contexts.txt
# and checks that no line of scripts/lib/non-gating-contexts.txt is required.
#
# Usage: check-required-fixture.sh [--repo <owner/name>] [--branch <b>]
#   --repo defaults to GITHUB_REPOSITORY, --branch to main.
# Exit: 0 every copy matches; 1 drift (one `<kind>: <name>` line each);
#       2 usage, an unreadable live read, an unreadable fixture, or no required
#       check live (never read as a match).
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RULES_FIXTURE="${REQUIRED_FIXTURE_RULES:-$ROOT/scripts/ci/check-run-timelines/testdata/rules-main.json}"
CONTEXTS_FIXTURE="${REQUIRED_FIXTURE_CONTEXTS:-$ROOT/scripts/ci/fixtures/ci-go-gate-required-contexts.txt}"
NON_GATING="${NON_GATING_CONTEXTS_FILE:-$ROOT/scripts/lib/non-gating-contexts.txt}"
repo="${GITHUB_REPOSITORY:-}"
branch=main
usage() { echo "usage: $0 [--repo <owner/name>] [--branch <b>]" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        --branch) [ "$#" -ge 2 ] || usage; branch="$2"; shift 2 ;;
        *) usage ;;
    esac
done
case "$repo" in */*) ;; *) echo "required-fixture: no repo (pass --repo or set GITHUB_REPOSITORY)" >&2; exit 2 ;; esac

ctx_of_rules='.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | .context'
raw=$(gh api "repos/$repo/rules/branches/$branch") || { echo "required-fixture: cannot read rules/branches/$branch of $repo" >&2; exit 2; }
live=$(printf '%s' "$raw" | jq -r "$ctx_of_rules" | sort -u) || { echo "required-fixture: unreadable rules/branches answer" >&2; exit 2; }
[ -n "$live" ] || { echo "required-fixture: $repo $branch requires no status check — refusing to call that a match" >&2; exit 2; }
fix_rules=$(jq -r "$ctx_of_rules" "$RULES_FIXTURE" | sort -u) || { echo "required-fixture: cannot read $RULES_FIXTURE" >&2; exit 2; }
[ -r "$CONTEXTS_FIXTURE" ] || { echo "required-fixture: cannot read $CONTEXTS_FIXTURE" >&2; exit 2; }
fix_contexts=$(sed '/^[[:space:]]*$/d' "$CONTEXTS_FIXTURE" | sort -u) || { echo "required-fixture: cannot read $CONTEXTS_FIXTURE" >&2; exit 2; }
[ -r "$NON_GATING" ] || { echo "required-fixture: cannot read $NON_GATING" >&2; exit 2; }
non_gating=$(sed -e '/^#/d' -e '/^[[:space:]]*$/d' "$NON_GATING" | sort -u) || { echo "required-fixture: cannot read $NON_GATING" >&2; exit 2; }

drift=0
compare() {
    local n
    while IFS= read -r n; do [ -z "$n" ] || { echo "missing-from-$1: $n"; drift=1; }; done < <(comm -23 <(printf '%s\n' "$live") <(printf '%s\n' "$2"))
    while IFS= read -r n; do [ -z "$n" ] || { echo "stale-in-$1: $n"; drift=1; }; done < <(comm -13 <(printf '%s\n' "$live") <(printf '%s\n' "$2"))
}
compare rules-fixture "$fix_rules"
compare contexts-fixture "$fix_contexts"
while IFS= read -r n; do [ -z "$n" ] || { echo "non-gating-but-required: $n"; drift=1; }; done < <(comm -12 <(printf '%s\n' "$live") <(printf '%s\n' "$non_gating"))

if [ "$drift" -ne 0 ]; then
    echo "required-fixture: DRIFT against $repo $branch — refresh the fixture from 'gh api repos/$repo/rules/branches/$branch', or drop the non-gating line" >&2
    exit 1
fi
echo "required-fixture: OK — $(printf '%s\n' "$live" | wc -l | tr -d ' ') required checks on $repo $branch match both fixtures; no non-gating context is required"
