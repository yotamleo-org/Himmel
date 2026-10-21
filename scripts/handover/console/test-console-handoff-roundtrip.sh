#!/usr/bin/env bash
# shellcheck disable=SC2015
# scripts/handover/console/test-console-handoff-roundtrip.sh — a console hop
# keeps every `## Live state` field.
#
# A fixture console doc carries every Live-state field; `console.sh next` hands
# it over, and each field must reach the successor doc (the carried fields) or
# the HANDOFF (the per-shift fields), equal to what the predecessor held. The
# field list below is checked against the template and console.sh, so a field
# added to either without a row here fails loudly.
#
# `next --dry-run` renders nothing, so the round trip runs the real `next`
# against a temp handover root and a throwaway fixture repo (same shape as
# test-console.sh).
#
# Platform guard (gitbash-only): POSIX bash 3.2+; no .ps1 twin, same scope as
# console.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_REAL="$(cd "$HERE/../../.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/console-roundtrip.XXXXXX")" || { echo "test-console-handoff-roundtrip: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

export HIMMELCTL_CACHE_DIR="$tmp/himmelctl-cache"
export HANDOVER_REGISTRY="$tmp/no-registry-for-this-suite.json"
export BRIDGE_ROOT="$tmp/bridge"
printf '#!/usr/bin/env bash\necho "bank-preflight: leg=unknown five_hour=9.0 seven_day=91.0 extra_usage=n/a"\necho PROCEED\n' > "$tmp/facts-bank.sh"
printf '#!/usr/bin/env bash\necho "#5 [DEMO-1] stub pr (feat/x)"\n' > "$tmp/facts-prs.sh"
export HANDOFF_FACTS_BANK="$tmp/facts-bank.sh" HANDOFF_FACTS_PRS="$tmp/facts-prs.sh"

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# Every Live-state field and where `next` puts it. CARRIED fields span shifts;
# SEEDED fields are per-shift. Both land verbatim in the successor doc's own
# Live state; the HANDOFF only points at it. Add a new field here first.
carried_fields="board
tracker
epics
decisions
priority
versions
tracker-plan
release
rm"
seeded_fields="legs
queue
last GO
acked"

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
C="$fixture_repo/scripts/handover/console/chief.sh"
root="$tmp/handovers"
mkdir -p "$root"
today="$(date +%F)"
console() { ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CONSOLE_WORK_DIR="$tmp/work" bash "$C" "$@" ); }
live_state() { awk '$0 == "## Live state" { f = 1; next } f && /^## / { exit } f' "$1"; }

# --- 1: the field list matches the template and console.sh ------------------
tpl="$REPO_REAL/docs/handover/console-template.md"
tpl_fields="$(awk '
    $0 == "## Live state" { f = 1; next }
    f && /^## / { exit }
    f && /^[a-z][A-Za-z0-9_ -]*:/ { sub(/:.*/, ""); print }
' "$tpl")"
sh_fields="$(sed -n 's/^    for field in \(.*\); do$/\1/p' "$REPO_REAL/scripts/handover/console/chief.sh" | head -n 1 | tr ' ' '\n')"
listed="$carried_fields
$seeded_fields"
missing=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$listed" | grep -Fxq "$f" || missing="$missing [$f]"
done <<EOF
$(printf '%s\n%s\n' "$tpl_fields" "$sh_fields" | sort -u)
EOF
check "1 every template/console.sh Live-state field is in the test's field list; unlisted:${missing:- none}" "${missing:- none}" " none"
check "1 the carry loop in console.sh was found" "$([ -n "$sh_fields" ] && echo yes)" "yes"

# --- 2: the round trip ------------------------------------------------------
console new --bucket rtsrc >/dev/null 2>&1
docA="$root/tester/rtsrc/DEMO-nextleg-${today}A-console.md"
docB="$root/tester/rtdst/DEMO-nextleg-${today}B-console.md"
handoff="${docA%.md}-HANDOFF.md"
# shellcheck disable=SC2016  # literal backticks, unexpanded on purpose
fixture_live='legs: `N1:AP-N1-aaaa1111:lock-one:111` `N2:AP-N2-bbbb2222:lock-two:222`
queue: /fixture/q/one.md /fixture/q/two.md
last GO: 3101:0123456789abcdef0123456789abcdef01234567
acked: esc-17, esc-18
board: https://claude.ai/artifact/fixture-6591-board
tracker: https://claude.ai/artifact/fixture-6591-tracker
epics: HIMMEL-5654=21, HIMMEL-6579=9
decisions: OPERATOR 10-20 (BINDING): drain owner-less In Progress first; FOCUS v1.1.3 second
priority: 6591 6592 | 6593(K2) | 6594
versions: v1.1.3, v1.1.4
tracker-plan: /fixture/plan/HIMMEL-3882
release: v1.1.3-4
rm: HIMMEL-rm-fixture /fixture/rm/doc.md epoch=2
'
awk -v live="$fixture_live" '
    $0 == "## Live state" { f = 1; print; next }
    f && /^legs:/ { printf "%s\n", live; skip = 1; next }
    skip && /^## / { skip = 0; f = 0 }
    skip { next }
    { print }' "$docA" > "$docA.new" && mv "$docA.new" "$docA"
check "2 fixture doc carries every field" \
    "$(awk '$0 == "## Live state" { f = 1; next } f && /^## / { exit } f' "$docA" | grep -c '^\(legs\|queue\|last GO\|acked\|board\|tracker\|epics\|decisions\|priority\|versions\|tracker-plan\|release\|rm\):')" "13"

rc=0
console next --bucket rtdst --doc "$docA" >/dev/null 2>&1 || rc=$?
check "2 next succeeds against the full fixture" "$rc" "0"

while IFS= read -r f; do
    want="$(printf '%s\n' "$fixture_live" | grep -m 1 "^$f:")"
    check "2 successor Live state carries '$f:' verbatim" "$(live_state "$docB" 2>/dev/null | grep -Fxc "$want")" "1"
done <<EOF
$carried_fields
EOF
while IFS= read -r f; do
    want="$(printf '%s\n' "$fixture_live" | grep -m 1 "^$f:")"
    check "2 successor Live state seeds '$f:' verbatim" "$(live_state "$docB" 2>/dev/null | grep -Fxc "$want")" "1"
done <<EOF
$seeded_fields
EOF
check "2 HANDOFF carries no copy of a leg nonce" "$(grep -c 'AP-N[12]-' "$handoff" 2>/dev/null)" "0"
check "2 successor doc has no placeholder decisions: none" "$(grep -Fxc 'decisions: none' "$docB" 2>/dev/null)" "0"
check "2 successor doc has no unrendered slot" "$(grep -c '{{[A-Z_]*}}' "$docB" 2>/dev/null)" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
