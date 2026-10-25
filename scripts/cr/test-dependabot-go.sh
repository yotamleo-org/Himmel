#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-cr-disposition.sh
# scripts/cr/test-dependabot-go.sh - suite for dependabot-go.sh: the
# row it appends is the review a Dependabot dependency-only PR can get, so every
# refusal must leave the ledger untouched.
#   1. a real PR 3861 read with a signed judge GO at its head records one row.
#   2. a human author, a non-manifest file, a rename out of one, a moved head, a
#      closed PR, a truncated file list and an unreadable PR are refused.
#   3. a missing, NO-GO, other-head or other-PR verdict is refused.
#   4. the allowlist is the one ready-check.sh uses.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WRITER="$HERE/dependabot-go.sh"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY GH_CMD 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dependabot-go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
export HOME="$tmp/home"; mkdir -p "$HOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"

# gh stub: STUB_PR_JSON is the `gh pr view` body, STUB_FILES the names the files
# endpoint's --jq prints; STUB_PR_FAIL makes the PR read fail.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "pr view"*)
        [ -z "${STUB_PR_FAIL:-}" ] || exit 1
        n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_COUNT"
        # STUB_PR_JSON_LATER is what every read after the first sees (a head that moved)
        if [ "$n" -ge 1 ] && [ -n "${STUB_PR_JSON_LATER:-}" ]; then printf '%s\n' "$STUB_PR_JSON_LATER"; else printf '%s\n' "$STUB_PR_JSON"; fi ;;
    "repo view"*) printf 'o/r\n' ;;
    "api --paginate"*"/files"*previous_filename*) printf '%s\n' "${STUB_PREV:-}" ;;
    "api --paginate"*"/files"*) printf '%s\n' "$STUB_FILES" ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export GH_CMD="$tmp/bin/gh"

REPO="$tmp/repo"
git init -q "$REPO"
cd "$REPO" || { echo "FAIL: cd $REPO" >&2; exit 1; }
LEDGER="$(git rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl"

fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grep -qF -e "$3" <<< "$2" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }

export USER_SLUG=u
VBUCKET="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
VSCOPE="u/$VBUCKET"
HDIR="$tmp/root"; mkdir -p "$HDIR"
export HANDOVER_DIR="$HDIR"
# verdict <qid> <verdict line> <pr> - a signed judge record, as test-cr-disposition.sh builds it.
verdict() {
    local vf="$HDIR/$VSCOPE/verdicts/$1/HIMMEL-7572-judge-$1.md" vmac
    mkdir -p "$HDIR/$VSCOPE/verdicts/$1"
    printf '# VERDICT %s - judge\n\n## Reason (scope asked)\n\nq\n\n## Verdict\n\n%s\n\npr: %s\n\nreason\n\n## Evidence checked\n\ne\n' "$1" "$2" "$3" > "$vf"
    # shellcheck disable=SC2094  # the read finishes before the append below
    vmac="$(bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../lib/go-gate.sh" "$VSCOPE" "$1" "$(basename "$vf" .md)" < "$vf")" || return 1  # read-sink-ok: the test's own verdict fixture under its temp dir
    printf 'mac: %s\n' "$vmac" >> "$vf"
}

# Copied from the real PR 3861 (numpy 2.5.3 to 2.5.4): `gh pr view 3861 --json
# author,headRefName,headRefOid,state,changedFiles` and its one changed file.
PR=3861
SHA=9d87a2790a6b7d12146a113a17ad8a612446fba1
OTHER=1111111111111111111111111111111111111111
BRANCH=dependabot/pip/marketplace/plugins/obsidian-triage/tools/numpy-2.5.4
FILE=marketplace/plugins/obsidian-triage/tools/requirements-whisper.txt
pr_json() { # pr_json <login> <state> <head> <changedFiles>
    printf '{"author":{"is_bot":true,"login":"%s"},"changedFiles":%s,"headRefName":"%s","headRefOid":"%s","state":"%s"}' "$1" "$4" "$BRANCH" "$3" "$2"
}
reset() {
    export STUB_PR_JSON; STUB_PR_JSON="$(pr_json app/dependabot OPEN "$SHA" 1)"
    export STUB_FILES="$FILE" STUB_PREV="" STUB_COUNT="$tmp/pr-view-count"; unset STUB_PR_FAIL STUB_PR_JSON_LATER
    rm -f "$STUB_COUNT"
    : > "$LEDGER"
}
writer() { rc=0; out="$(bash "$WRITER" "$@" 2>&1)" || rc=$?; }
rows() { grep -c . "$LEDGER" 2>/dev/null || true; }

verdict j1 "**GO** for head \`$SHA\`." "$PR"

# --- 1. the real PR with a signed GO at its head --------------------------
reset
writer "$PR" "$SHA" --judge j1
check    "1: dependency-only PR with a judge GO -> exit 0" "$rc" "0"
check    "1: one row appended" "$(rows)" "1"
contains "1: the row is a dependabot-go row" "$(cat "$LEDGER")" '"kind":"dependabot-go"'
contains "1: the row names the PR's branch" "$(cat "$LEDGER")" "\"branch\":\"$BRANCH\""
contains "1: the row names the head" "$(cat "$LEDGER")" "\"head\":\"$SHA\",\"status\":\"ok\",\"source\":\"judge:j1\""
check    "1: the row parses as JSON" "$(jq -r '.pr' "$LEDGER")" "$PR"
writer "$PR" "$SHA" --judge j1
check    "1: a second run is a no-op" "$(rows)" "1"

# a row of another kind or branch at this head must not stand in for the row
reset
printf '{"kind":"judge-go","ts":"t","branch":"%s","head":"%s","status":"ok","source":"judge:j1","pr":%s}\n' "$BRANCH" "$SHA" "$PR" > "$LEDGER"
printf '{"kind":"dependabot-go","ts":"t","branch":"other/branch","head":"%s","status":"ok","source":"judge:j1","pr":%s}\n' "$SHA" "$PR" >> "$LEDGER"
writer "$PR" "$SHA" --judge j1
check    "1: other-kind and other-branch rows do not suppress the row" "$(rows)" "3"
contains "1: the new row is the PR's own" "$(tail -n 1 "$LEDGER")" "\"kind\":\"dependabot-go\",\"ts\""

# --- 2. refused PRs (RED controls: the ledger stays empty) ----------------
reset; STUB_PR_JSON="$(pr_json yotamleo OPEN "$SHA" 1)"
writer "$PR" "$SHA" --judge j1
check    "2: a human author -> exit 2" "$rc" "2"
contains "2: a human author says why" "$out" "not app/dependabot"
check    "2: a human author appends nothing" "$(rows)" "0"

reset; STUB_FILES="$FILE
scripts/x/run.sh"; STUB_PR_JSON="$(pr_json app/dependabot OPEN "$SHA" 2)"
writer "$PR" "$SHA" --judge j1
check    "2: a non-manifest file -> exit 2" "$rc" "2"
contains "2: names the file" "$out" "scripts/x/run.sh"
check    "2: a non-manifest file appends nothing" "$(rows)" "0"

reset; STUB_FILES=".github/workflows/ci.yml"
writer "$PR" "$SHA" --judge j1
check    "2: a workflow file -> exit 2" "$rc" "2"

reset; STUB_PREV="scripts/hooks/guard.sh"
writer "$PR" "$SHA" --judge j1
check    "2: a rename out of a non-manifest (old name listed) -> exit 2" "$rc" "2"
check    "2: a rename out of a non-manifest appends nothing" "$(rows)" "0"

reset; STUB_PREV="old/package.json"; STUB_PR_JSON="$(pr_json app/dependabot OPEN "$SHA" 2)"
writer "$PR" "$SHA" --judge j1
check    "2: an old name does not make up a truncated list -> exit 2" "$rc" "2"
contains "2: says it was truncated (old names uncounted)" "$out" "truncated"

reset; STUB_FILES="package.json.sh"
writer "$PR" "$SHA" --judge j1
check    "2: a name that only starts like a manifest -> exit 2" "$rc" "2"

reset
writer "$PR" "$OTHER" --judge j1
check    "2: a head other than the PR's -> exit 2" "$rc" "2"
check    "2: a moved head appends nothing" "$(rows)" "0"

reset; STUB_PR_JSON="$(pr_json app/dependabot CLOSED "$SHA" 1)"
writer "$PR" "$SHA" --judge j1
check    "2: a closed PR -> exit 2" "$rc" "2"

reset; export STUB_PR_JSON_LATER; STUB_PR_JSON_LATER="$(pr_json app/dependabot OPEN "$OTHER" 1)"
writer "$PR" "$SHA" --judge j1
check    "2: a head that moves while the files are read -> exit 2" "$rc" "2"
contains "2: says the head moved" "$out" "head moved"
check    "2: a moved head appends nothing (late)" "$(rows)" "0"

reset; STUB_PR_JSON="$(pr_json app/dependabot OPEN "$SHA" 3)"
writer "$PR" "$SHA" --judge j1
check    "2: a file list shorter than changedFiles -> exit 2" "$rc" "2"
contains "2: says it was truncated" "$out" "truncated"

reset; STUB_FILES=""
writer "$PR" "$SHA" --judge j1
check    "2: an empty file list -> exit 2" "$rc" "2"

reset; STUB_PR_FAIL=1; export STUB_PR_FAIL
writer "$PR" "$SHA" --judge j1
check    "2: an unreadable PR -> exit 2" "$rc" "2"
check    "2: an unreadable PR appends nothing" "$(rows)" "0"
unset STUB_PR_FAIL

# --- 3. the judge verdict -------------------------------------------------
reset
writer "$PR" "$SHA" --judge nojudge
check    "3: no verdict under the qid -> exit 2" "$rc" "2"
check    "3: no verdict appends nothing" "$(rows)" "0"

verdict j2 "**NO-GO** for head \`$SHA\`." "$PR"
writer "$PR" "$SHA" --judge j2
check    "3: a NO-GO verdict -> exit 2" "$rc" "2"

verdict j3 "**GO** for head \`$OTHER\`." "$PR"
writer "$PR" "$SHA" --judge j3
check    "3: a GO for another head -> exit 2" "$rc" "2"

verdict j4 "**GO** for head \`$SHA\`." 9999
writer "$PR" "$SHA" --judge j4
check    "3: a GO naming another PR -> exit 2" "$rc" "2"
check    "3: no refused verdict appends anything" "$(rows)" "0"

# --- 4. arguments and the shared allowlist --------------------------------
writer "$PR" "$SHA"
check    "4: no --judge -> exit 2" "$rc" "2"
writer abc "$SHA" --judge j1
check    "4: a non-numeric PR -> exit 2" "$rc" "2"
writer "$PR" abc123 --judge j1
check    "4: a short head -> exit 2" "$rc" "2"
ALLOW='(^|/)(package\.json|package-lock\.json|bun\.lock|requirements[A-Za-z0-9._-]*\.txt)$'
check    "4: ready-check.sh holds the same allowlist" "$(grep -cF -e "$ALLOW" "$HERE/../handover/chief-kit/ready-check.sh")" "1"
check    "4: dependabot-go.sh holds the same allowlist" "$(grep -cF -e "$ALLOW" "$WRITER")" "1"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
