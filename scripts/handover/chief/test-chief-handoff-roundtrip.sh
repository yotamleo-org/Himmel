#!/usr/bin/env bash
# shellcheck disable=SC2015
# scripts/handover/chief/test-chief-handoff-roundtrip.sh — a chief hop
# keeps every `## Live state` field.
#
# A fixture chief doc carries every Live-state field; `chief.sh next` hands
# it over, and each field must reach the successor doc (the carried fields) or
# the HANDOFF (the per-shift fields), equal to what the predecessor held. The
# field list below is checked against the template and chief.sh, so a field
# added to either without a row here fails loudly.
#
# `next --dry-run` renders nothing, so the round trip runs the real `next`
# against a temp handover root and a throwaway fixture repo (same shape as
# test-chief.sh).
#
# Platform guard: POSIX bash 3.2+; same scope as chief.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_REAL="$(cd "$HERE/../../.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/chief-roundtrip.XXXXXX")" || { echo "test-chief-handoff-roundtrip: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY

export HIMMELCTL_CACHE_DIR="$tmp/himmelctl-cache"
export HANDOVER_REGISTRY="$tmp/no-registry-for-this-suite.json"
export BRIDGE_ROOT="$tmp/bridge"
export UNGUARDED_LAUNCH_OK=1
printf '#!/usr/bin/env bash\necho "bank-preflight: worker=unknown five_hour=9.0 seven_day=91.0 extra_usage=n/a"\necho PROCEED\n' > "$tmp/facts-bank.sh"
printf '#!/usr/bin/env bash\necho "#5 [DEMO-1] stub pr (feat/x)"\n' > "$tmp/facts-prs.sh"
export HANDOFF_FACTS_BANK="$tmp/facts-bank.sh" HANDOFF_FACTS_PRS="$tmp/facts-prs.sh"
# `next` refuses on an open PR with no live worker or queue hold: an empty PR list keeps this suite off the real gh
printf '[]\n' > "$tmp/orphan-prs-none.json"
export ORPHAN_PR_CHECK_PRS="$tmp/orphan-prs-none.json"

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
rm
focus-version
focus-plan"
seeded_fields="workers
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
C="$fixture_repo/scripts/handover/chief/chief.sh"
root="$tmp/handovers"
export HIMMEL_RELEASE_STATE_DIR="$tmp/releases"
mkdir -p "$root" "$HIMMEL_RELEASE_STATE_DIR"
today="$(date +%F)"
# chief.sh re-reads `date +%F` per call: pin it so a run crossing UTC midnight keeps one day
datepin="$tmp/datepin"; mkdir -p "$datepin"
printf '#!/bin/sh\nif [ "$*" = "+%%F" ]; then echo %s; else exec %s "$@"; fi\n' "$today" "$(command -v date)" > "$datepin/date"; chmod +x "$datepin/date"
PATH="$datepin:$PATH"; export PATH
chief() { ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CHIEF_WORK_DIR="$tmp/work" bash "$C" "$@" ); }
live_state() { awk '$0 == "## Live state" { f = 1; next } f && /^## / { exit } f' "$1"; }

# --- 1: the field list matches the template and chief.sh ------------------
tpl="$REPO_REAL/docs/handover/chief-template.md"
tpl_fields="$(awk '
    $0 == "## Live state" { f = 1; next }
    f && /^## / { exit }
    f && /^[a-z][A-Za-z0-9_ -]*:/ { sub(/:.*/, ""); print }
' "$tpl")"
sh_fields="$(sed -n 's/^    for field in \(.*\); do$/\1/p' "$REPO_REAL/scripts/handover/chief/chief.sh" | head -n 1 | tr ' ' '\n')"
listed="$carried_fields
$seeded_fields"
missing=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$listed" | grep -Fxq "$f" || missing="$missing [$f]"
done <<EOF
$(printf '%s\n%s\n' "$tpl_fields" "$sh_fields" | sort -u)
EOF
check "1 every template/chief.sh Live-state field is in the test's field list; unlisted:${missing:- none}" "${missing:- none}" " none"
check "1 the carry loop in chief.sh was found" "$([ -n "$sh_fields" ] && echo yes)" "yes"

# --- 2: the round trip ------------------------------------------------------
chief new --bucket rtsrc >/dev/null 2>&1
docA="$root/tester/rtsrc/DEMO-nextleg-${today}A-chief.md"
docB="$root/tester/rtdst/DEMO-nextleg-${today}B-chief.md"
handoff="${docA%.md}-HANDOFF.md"
# shellcheck disable=SC2016  # literal backticks, unexpanded on purpose
fixture_live='workers: `N1:AP-N1-aaaa1111:lock-one:111` `N2:AP-N2-bbbb2222:lock-two:222`
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
focus-version: v1.1.3
focus-plan: /fixture/plan/focus-plan.md
'
# ENVIRON, not `-v`: BSD awk (macOS) refuses a newline in a -v value.
LIVE="$fixture_live" awk '
    $0 == "## Live state" { f = 1; print; next }
    f && /^workers:/ { printf "%s\n", ENVIRON["LIVE"]; skip = 1; next }
    skip && /^## / { skip = 0; f = 0 }
    skip { next }
    { print }' "$docA" > "$docA.new" && mv "$docA.new" "$docA"
check "2 fixture doc carries every field" \
    "$(awk '$0 == "## Live state" { f = 1; next } f && /^## / { exit } f' "$docA" | grep -c '^\(workers\|queue\|last GO\|acked\|board\|tracker\|epics\|decisions\|priority\|versions\|tracker-plan\|release\|rm\|focus-version\|focus-plan\):')" "15"

rc=0
chief next --bucket rtdst --doc "$docA" >/dev/null 2>&1 || rc=$?
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
check "2 HANDOFF carries no copy of a worker nonce" "$(grep -c 'AP-N[12]-' "$handoff" 2>/dev/null)" "0"
check "2 successor doc has no placeholder decisions: none" "$(grep -Fxc 'decisions: none' "$docB" 2>/dev/null)" "0"
check "2 successor doc has no unrendered slot" "$(grep -c '{{[A-Z_]*}}' "$docB" 2>/dev/null)" "0"

# Missing seeding would leave both the first chief and a legacy successor unable to wake the RM.
mkdir -p "$HIMMEL_RELEASE_STATE_DIR/R1"
printf '{}\n' > "$HIMMEL_RELEASE_STATE_DIR/R1/release.json"
chief new --bucket seeded >/dev/null 2>&1
seedA="$root/tester/seeded/DEMO-nextleg-${today}A-chief.md"
check "3 new seeds the unique declaration, not the bucket or version" "$(live_state "$seedA" | grep '^release:')" "release: R1"
# Legacy docs have no line; next must repair them too.
grep -v '^release:' "$seedA" > "$seedA.new" && mv "$seedA.new" "$seedA"
chief next --bucket seeded --doc "$seedA" >/dev/null 2>&1
seedB="$root/tester/seeded/DEMO-nextleg-${today}B-chief.md"
check "3 next seeds a legacy doc's missing release" "$(live_state "$seedB" | grep '^release:')" "release: R1"
# Explicit disable is not an absent line.
awk '{ print; if ($0 == "## Live state") print "release: none" }' "$seedA" > "$seedA.new" && mv "$seedA.new" "$seedA"
chief next --bucket disabled --doc "$seedA" >/dev/null 2>&1
check "3 next preserves explicit none" "$(live_state "$root/tester/disabled/DEMO-nextleg-${today}B-chief.md" | grep '^release:')" "release: none"
mkdir -p "$HIMMEL_RELEASE_STATE_DIR/R2"
printf '{}\n' > "$HIMMEL_RELEASE_STATE_DIR/R2/release.json"
rc=0
chief new --bucket ambiguous >/dev/null 2>&1 || rc=$?
check "3 ambiguous new succeeds" "$rc" "0"
ambiguousA="$root/tester/ambiguous/DEMO-nextleg-${today}A-chief.md"
check "3 ambiguous new writes a nonempty doc" "$([ -s "$ambiguousA" ] && echo yes)" "yes"
check "3 new never chooses among multiple declarations" "$(live_state "$ambiguousA" | grep '^release:')" ""
rm -rf "$HIMMEL_RELEASE_STATE_DIR/R1" "$HIMMEL_RELEASE_STATE_DIR/R2"
# Without an override the canonical repo bucket is repo, even with --bucket foreign.
mkdir -p "$root/tester/repo/release/R3"
printf '{}\n' > "$root/tester/repo/release/R3/release.json"
unset HIMMEL_RELEASE_STATE_DIR
chief new --bucket foreign >/dev/null 2>&1
check "3 new finds the canonical primary repo release, not --bucket" "$(live_state "$root/tester/foreign/DEMO-nextleg-${today}A-chief.md" | grep '^release:')" "release: R3"

mkdir -p "$tmp/foreign-project"
rc=0
chief new --project "$tmp/foreign-project" --bucket foreign-project --prefix DEMO >/dev/null 2>&1 || rc=$?
check "4 foreign new succeeds" "$rc" "0"
foreignA="$root/tester/foreign-project/DEMO-nextleg-${today}A-chief.md"
check "4 foreign new writes a nonempty doc" "$([ -s "$foreignA" ] && echo yes)" "yes"
check "4 foreign new never seeds the primary checkout's release" "$(live_state "$foreignA" | grep '^release:')" ""
grep -v '^release:' "$foreignA" > "$foreignA.new" && mv "$foreignA.new" "$foreignA"
rc=0
chief next --bucket foreign-project --prefix DEMO --doc "$foreignA" >/dev/null 2>&1 || rc=$?
check "4 foreign next succeeds" "$rc" "0"
foreignB="$root/tester/foreign-project/DEMO-nextleg-${today}B-chief.md"
check "4 foreign next writes a nonempty doc" "$([ -s "$foreignB" ] && echo yes)" "yes"
check "4 foreign next never seeds the primary checkout's release" "$(live_state "$foreignB" | grep '^release:')" ""

chief new --bucket owedgate >/dev/null 2>&1
gateA="$root/tester/owedgate/DEMO-nextleg-${today}A-chief.md"
gateB="$root/tester/owedgate/DEMO-nextleg-${today}B-chief.md"
gate_handoff="${gateA%.md}-HANDOFF.md"
OWE="$fixture_repo/scripts/handover/chief-kit/owe.sh"
owe_row() { bash "$OWE" add --bucket "$1" --chief A --kind ticket --text "$2"; }
write_gate_handoff() {
    printf '%s\n' '# A → B handoff state' '' '## Rulings and judgement notes — the only part the chief writes' '' \
        '1. The first ticket merged as #5, closed.' "2. The second ticket owes a live proof: $1." "8. $2" \
        '   (a continuation line of item 8)' "${@:3}" '' '## Open operator items' '' 'none' > "$gate_handoff"
}
gate_id="$(owe_row "$root/tester/owedgate" 'the second ticket live proof')"
gate_ids="$(owe_row "$root/tester/owedgate" 'status page ask a') $(owe_row "$root/tester/owedgate" 'status page ask b')"
write_gate_handoff "$gate_id" 'Operator asks still open: (a) status page "RESUME briefs (1634), newest 8 h old" looks like a bug; (b) "12 started, no one on it": bug or current work?; (c) launch a design leg' \
    '9. Not closed; waiting for proof' '  10. An indented item with no row' '11. A row that is not in the ledger: o99'
rc=0; out="$(chief next --bucket owedgate --doc "$gateA" 2>&1)" || rc=$?
check "5 next refuses a HANDOFF item with no owed id (rc 11)" "$rc" "11"
check "5 the refusal names item 8" "$(printf '%s\n' "$out" | grep -c 'item 8: Operator asks still open')" "1"
check "5 the refusal names the owe.sh add command" "$(printf '%s\n' "$out" | grep -c 'owe.sh add --bucket .*owedgate')" "1"
check "5 items carrying o<N> or closed are not named" "$(printf '%s\n' "$out" | grep -c 'item [12]:')" "0"
check "5 not closed is no closed mark" "$(printf '%s\n' "$out" | grep -c 'item 9: Not closed')" "1"
check "5 an item indented by two spaces is checked" "$(printf '%s\n' "$out" | grep -c 'item 10: An indented item')" "1"
check "5 an o<N> the ledger does not hold is no owed id" "$(printf '%s\n' "$out" | grep -c 'item 11: A row that is not')" "1"
check "5 the refused next writes no successor doc" "$([ -e "$gateB" ] && echo yes || echo no)" "no"
write_gate_handoff "$gate_id" "Operator asks still open, rows $gate_ids: (a) status page; (b) 12 started; (c) a design leg"
chmod 000 "$gate_handoff"
if [ ! -r "$gate_handoff" ]; then
    rc=0; out="$(chief next --bucket owedgate --doc "$gateA" 2>&1)" || rc=$?
    check "5 next refuses a HANDOFF it cannot read (rc 11)" "$rc" "11"
    check "5 the unreadable refusal names the file" "$(printf '%s\n' "$out" | grep -c 'cannot read .*-HANDOFF.md')" "1"
fi
chmod 644 "$gate_handoff"
rc=0; chief next --bucket owedgate --doc "$gateA" >/dev/null 2>&1 || rc=$?
check "5 control: every item carries o<N> or closed, next hands over" "$rc" "0"

wg="$tmp/wrapgate"; mkdir -p "$wg"
printf '#!/usr/bin/env bash\necho live-subagents=0\n' > "$wg/lsa.sh"
printf '#!/usr/bin/env bash\necho "CLOSABLE: no non-harness process"\n' > "$wg/subtree.sh"
chmod +x "$wg/lsa.sh" "$wg/subtree.sh"
QL="$fixture_repo/scripts/handover/queue-lock.sh"
wrap_gate() {
    ( cd "$fixture_repo" && HANDOVER_DIR="$root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO CHIEF_WORK_DIR="$tmp/work" \
        LIVE_SUBAGENTS_BIN="$wg/lsa.sh" WRAP_SUBTREE_CHECK_BIN="$wg/subtree.sh" bash "$C" wrap "$1" "$2" ) 2>&1
}
mk_wrap_doc() {
    wdoc="$wg/$1.md"
    printf '%s\n' '# chief' '## Results' '- 10:00 LIVE — up' > "$wdoc"
    # shellcheck disable=SC2016  # the backticks are literal: they wrap the token in queue-lock's output
    wtok="$(HANDOVER_DIR="$root" bash "$QL" acquire "$wdoc" 2>&1 | sed -n 's/^release-token: `\(.*\)`$/\1/p')"
}
mk_wrap_doc unowed
gate_handoff="${wdoc%.md}-HANDOFF.md"
wrap_id="$(owe_row "$wg" 'the second ticket live proof')"
write_gate_handoff "$wrap_id" 'The build brief owed once worker N35 wraps'
rc=0; out="$(wrap_gate "$wdoc" "$wtok")" || rc=$?
check "5 wrap refuses a HANDOFF item with no owed id (rc 11)" "$rc" "11"
check "5 the wrap refusal names item 8" "$(printf '%s\n' "$out" | grep -c 'item 8: The build brief owed')" "1"
check "5 the refused wrap writes no WRAPPED" "$(grep -c WRAPPED "$wdoc")" "0"
write_gate_handoff "$wrap_id" "The build brief owed once worker N35 wraps: $(owe_row "$wg" 'the build brief')"
rc=0; wrap_gate "$wdoc" "$wtok" >/dev/null || rc=$?
check "5 control: wrap passes once the item carries its owed id" "$rc" "0"
check "5 control: WRAPPED written" "$(grep -c '^- .*WRAPPED' "$wdoc")" "1"
mk_wrap_doc nohandoff
rc=0; wrap_gate "$wdoc" "$wtok" >/dev/null || rc=$?
check "5 control: wrap with no HANDOFF passes" "$rc" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
