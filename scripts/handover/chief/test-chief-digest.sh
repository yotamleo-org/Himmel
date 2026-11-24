#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_REAL="$(cd "$HERE/../../.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/chief-digest.XXXXXX")" || { echo "test-chief-digest: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

export HIMMELCTL_CACHE_DIR="$tmp/himmelctl-cache"
export HANDOVER_REGISTRY="$tmp/no-registry-for-this-suite.json"
export BRIDGE_ROOT="$tmp/bridge"
export UNGUARDED_LAUNCH_OK=1
printf '#!/usr/bin/env bash\necho "bank-preflight: worker=unknown five_hour=9.0 seven_day=91.0 extra_usage=n/a"\necho PROCEED\n' > "$tmp/facts-bank.sh"
{
    printf '#!/usr/bin/env bash\n'
    i=1
    while [ "$i" -le 60 ]; do
        printf 'echo "#%s [DEMO-%s] a deliberately long stub pull request title that pads this line out to well past a hundred bytes (feat/branch-%s)"\n' "$i" "$i" "$i"
        i=$((i + 1))
    done
} > "$tmp/facts-prs.sh"
export HANDOFF_FACTS_BANK="$tmp/facts-bank.sh" HANDOFF_FACTS_PRS="$tmp/facts-prs.sh"
printf '[]\n' > "$tmp/orphan-prs-none.json"
export ORPHAN_PR_CHECK_PRS="$tmp/orphan-prs-none.json"

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

BOUND=6000

fixture_repo="$tmp/repo"
mkdir -p "$fixture_repo/scripts" "$fixture_repo/docs"
git init -q "$fixture_repo"
for _e in "$REPO_REAL"/scripts/* "$REPO_REAL"/docs/*; do
    case "$_e" in
        "$REPO_REAL/scripts/handover"|"$REPO_REAL/scripts/lib") cp -R "$_e" "$fixture_repo/scripts/" ;;
        "$REPO_REAL/docs/handover") cp -R "$_e" "$fixture_repo/docs/" ;;
        "$REPO_REAL"/scripts/*) ln -s "$_e" "$fixture_repo/scripts/${_e##*/}" ;;
        *) ln -s "$_e" "$fixture_repo/docs/${_e##*/}" ;;
    esac
done
C="$fixture_repo/scripts/handover/chief/chief.sh"
root="$tmp/handovers"
export HIMMEL_RELEASE_STATE_DIR="$tmp/releases"
mkdir -p "$root" "$HIMMEL_RELEASE_STATE_DIR"
today="$(date +%F)"
datepin="$tmp/datepin"; mkdir -p "$datepin"
printf '#!/bin/sh\nif [ "$*" = "+%%F" ]; then echo %s; else exec %s "$@"; fi\n' "$today" "$(command -v date)" > "$datepin/date"; chmod +x "$datepin/date"
PATH="$datepin:$PATH"; export PATH
chief() { ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CHIEF_WORK_DIR="$tmp/work" bash "$C" "$@" ); }

chief new --bucket dgsrc >/dev/null 2>&1
docA="$root/tester/dgsrc/DEMO-nextleg-${today}A-chief.md"
docB="$root/tester/dgdst/DEMO-nextleg-${today}B-chief.md"
handoff="${docA%.md}-HANDOFF.md"
digest="${docA%.md}-DIGEST.md"
rc=0
out="$(chief next --bucket dgdst --doc "$docA" 2>&1)" || rc=$?
check "0 next succeeds on the fixture" "$rc" "0"

named="$(sed -n 's/^> predecessor.s learnings in \*\*\([^*]*\)\*\*.*$/\1/p' "$docB" | head -n 1)"
named_path="$root/tester/dgsrc/${named##*/}"
check "1 the preface names a file that exists" "$([ -f "$named_path" ] && echo yes)" "yes"
named_bytes="$(wc -c < "$named_path" 2>/dev/null | tr -d ' ')"
check "1 the fixture HANDOFF is itself over the bound (the old injection)" "$([ "$(wc -c < "$handoff" | tr -d ' ')" -gt "$BOUND" ] && echo yes)" "yes"
check "1 the preface names the DIGEST, not the HANDOFF" "${named##*-}" "DIGEST.md"
check "1 the file the successor reads first is under $BOUND bytes" "$([ "${named_bytes:-999999}" -le "$BOUND" ] && echo yes)" "yes"
check "1 next prints the digest path" "$(printf '%s\n' "$out" | grep -c '^digest: ')" "1"
check "1 the HANDOFF skeleton is still written" "$([ -s "$handoff" ] && echo yes)" "yes"
check "1 the open-PR list is capped with a +N more pointer" "$(grep -c '^… +[0-9]* more' "$digest" 2>/dev/null)" "$(grep -c '^… +[0-9]* more — ' "$digest" 2>/dev/null)"
check "1 a +N more pointer exists in the digest" "$([ "$(grep -c '^… +[0-9]* more — ' "$digest" 2>/dev/null)" -ge 1 ] && echo yes)" "yes"
chief new --bucket dgsrc2 >/dev/null 2>&1
docA2="$root/tester/dgsrc2/DEMO-nextleg-${today}A-chief.md"
DIGEST_BUDGET_BYTES=1500 chief next --bucket dgdst3 --doc "$docA2" >/dev/null 2>&1
check "1 over a tight budget every list falls back to a pointer" "$(grep -c 'over the digest budget' "${docA2%.md}-DIGEST.md" 2>/dev/null | awk '{ print ($1 >= 3) ? "yes" : "no" }')" "yes"
check "1 over a tight budget the queue line points at the queue, not last GO" "$(grep -c 'Held queue:\*\* over the digest budget — read .queue:. in the Live' "${docA2%.md}-DIGEST.md" 2>/dev/null)" "1"

tpl="$REPO_REAL/docs/handover/chief-handoff-template.md"
labels="$(awk '/^<!-- digest-template:/ { exit } /^\*\*[^*]+:\*\*/ { s = $0; sub(/^\*\*/, "", s); sub(/:\*\*.*/, "", s); print s }' "$tpl")"
missing=""
while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in Operator) continue ;; esac
    base="${l%% (*}"
    base="${base%% at write}"
    grep -qF -- "**$base" "$digest" 2>/dev/null || missing="$missing [$l]"
done <<EOF
$labels
EOF
check "2 every mechanical HANDOFF field is in the digest; missing:${missing:- none}" "${missing:- none}" " none"
check "2 the template lists fields to check" "$([ -n "$labels" ] && echo yes)" "yes"
check "2 the digest names the successor doc to start from" "$([ "$(grep -cF -- "$(basename "$docB")" "$digest")" -ge 1 ] && echo yes)" "yes"
check "2 the digest carries the head line" "$(grep -c '^\*\*Head:\*\* .' "$digest")" "1"
check "2 the digest has no unrendered slot" "$(grep -c '{{[A-Z_]*}}' "$digest")" "0"
check "2 the digest carries no worker nonce" "$(grep -c 'AP-N[0-9]*-' "$digest")" "0"

check "3 next arms exactly one relay-on-live marker" "$(printf '%s\n' "$out" | grep -c '^relay-on-live: ')" "1"
marker="$(printf '%s\n' "$out" | sed -n 's/^relay-on-live: //p' | head -n 1)"
check "3 the marker names the successor session and doc, two lines" "$(wc -l < "$marker" 2>/dev/null | tr -d ' ')" "2"
ss="$REPO_REAL/docs/handover/chief-sections/successor-start.md"
check "3 successor-start.md states the single relay once" "$(grep -c 'sends exactly one relay at hand-over' "$ss")" "1"
check "3 successor-start.md has the successor read the digest" "$(grep -c 'DIGEST' "$ss" | awk '{ print ($1 >= 1) ? "yes" : "no" }')" "yes"
check "3 the digest says the predecessor relays once" "$(grep -c 'relays once' "$digest")" "1"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
