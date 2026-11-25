#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2031
# scripts/handover/chief-kit/test-go-batch.sh - suite for go-batch.sh, the chief's one-step GO for
# every green judged PR. gh, go.sh, the bus and the process census are stubs; verdict files and the
# chief doc are fixtures.
#
# Platform guard: POSIX bash 3.2+, jq, git.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/go-batch.sh"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-batch-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
export HOME="$tmp/home"; mkdir -p "$HOME"

PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"; else FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "  got:  $2"; echo "  want: $3"; fi
}
contains() {
    case "$2" in *"$3"*) PASS=$((PASS + 1)); echo "ok   $1" ;; *) FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "  missing: $3"; echo "  in: $2" ;; esac
}

if [ ! -f "$SCRIPT" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL go-batch.sh does not exist at $SCRIPT"
    echo "passed=$PASS failed=$FAIL"; exit 1
fi

H101=1111111111111111111111111111111111111111
H102=2222222222222222222222222222222222222222
H103=3333333333333333333333333333333333333333
H104=4444444444444444444444444444444444444444
H104OLD=4444444444444444444444444444444444444440
H105=5555555555555555555555555555555555555555

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/anchor" 2>/dev/null
git -C "$tmp/anchor" -c user.name=t -c user.email=t@t checkout -q -b main
git -C "$tmp/anchor" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
git -C "$tmp/anchor" push -q origin main 2>/dev/null
git -C "$tmp/anchor" branch -q --set-upstream-to=origin/main main
git clone -q "$tmp/origin.git" "$tmp/other" 2>/dev/null
git -C "$tmp/other" checkout -q -B main origin/main
ANCHOR="$tmp/anchor"

export HANDOVER_DIR="$tmp/root"; mkdir -p "$HANDOVER_DIR/.locks/go"
export USER_SLUG=tester
# shellcheck source=scripts/lib/go-gate.sh
. "$HERE/../../lib/go-gate.sh"
# shellcheck source=scripts/lib/handover-path.sh
. "$HERE/../../lib/handover-path.sh"
SCOPE=$(go_verdict_scope "$ANCHOR") || { echo "FAIL: cannot resolve the verdict scope of the fixture anchor" >&2; exit 1; }
VERD="$HANDOVER_DIR/$SCOPE/verdicts"

mkdir -p "$tmp/docs"
worker() {
    {
        printf '# %s\n\n' "$2"
        [ -z "$3" ] || printf '> **Completes ticket:** %s\n\n' "$3"
        [ -z "$4" ] || printf '> %s\n\n' "$4"
        printf '## Results\n- 09:00 LIVE — started\n- 10:00 READY %s %s GREEN\n' "$5" "$6"
    } > "$tmp/docs/$2.md"
}
JUDGE_LINE='the chief runs an opus judge before GO'
worker N1 wk-9001-N1-ordinary-2026-11-25 yes "" 101 "$H101"
worker N2 wk-9002-N2-trust-2026-11-25 yes "" 102 "$H102"
worker N3 wk-9003-N3-noverdict-2026-11-25 yes "This touches a guard, so $JUDGE_LINE." 103 "$H103"
worker N4 wk-9004-N4-stale-2026-11-25 yes "" 104 "$H104OLD"
worker N5 wk-9005-N5-contract-2026-11-25 no "" 105 "$H105"
{
    printf '{"workers":['
    sep=""
    for n in 1 2 3 4 5; do
        d=$(ls "$tmp/docs/wk-900$n-N$n-"*.md)
        printf '%s{"label":"N%s","doc":"%s","lane":"native"}' "$sep" "$n" "$d"; sep=","
    done
    printf ']}\n'
} > "$tmp/fleet.json"

mkchief() {
    {
        printf '# chief\n\n## Live state\n\nworkers:'
        for l in $2; do printf ' `%s:CN-%s-tok:lock-%s:1`' "$l" "$l" "$l"; done
        printf '\nqueue: none\nlast GO: none\n\n## Results\n'
    } > "$1"
}
mkchief "$tmp/chief.md" "N1 N2 N3 N4 N5"

mkdir -p "$VERD/J102"
printf '# VERDICT J102 - judge\n\nwriter-session: x\nwritten-at: 2026-11-25T10:00:00Z\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 102\n\nevidence\nmac: 00\n' "$H102" > "$VERD/J102/judge.md"

FIX="$tmp/fix"; mkdir -p "$FIX/bus" "$FIX/running"
cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "pr list" ] && { cat "$GB_FIX/prs.json"; exit 0; }
exit 91
STUB
cat > "$tmp/go" <<'STUB'
#!/usr/bin/env bash
args="$*"; q=""; c=""
while [ $# -gt 2 ]; do case "$1" in --contract) c="$2"; shift 2 ;; --trust-reviewed) q="$2"; shift 2 ;; *) shift 2 ;; esac; done
pr="$1"; head="$2"
printf 'pr=%s contract=%s trust=%s anchor=%s\n' "$pr" "$c" "$q" "$(git -C "$GB_ANCHOR" rev-parse HEAD)" >> "$GB_FIX/go.log"
touch "$GB_FIX/running/$$"
n=$(find "$GB_FIX/running" -type f | wc -l | tr -d ' ')
printf '%s\n' "$n" >> "$GB_FIX/concurrency.log"
sleep 0.3
rm -f "$GB_FIX/running/$$"
[ "$pr" = 102 ] && [ -z "$q" ] && { echo "go: refusing the plain GO for PR #102 - TRUST-PATH: yes" >&2; exit 8; }
case "$pr" in
    113) echo "go: refusing - ready-check.sh did not PASS" >&2; exit 4 ;;
    117) echo "go: refusing the trust-reviewed GO - no GO verdict" >&2; exit 5 ;;
    116) echo "go: refusing - a NO-GO sits after the head" >&2; exit 10 ;;
esac
[ -n "$c" ] || { echo "go: no contract" >&2; exit 4; }
f="$HANDOVER_DIR/.locks/go/$pr.$head"; : > "$f"
printf '%s\n' "$f"
STUB
cat > "$tmp/bus" <<'STUB'
#!/usr/bin/env bash
[ "$1" = send ] || exit 2
cp "$3" "$GB_FIX/bus/$2.msg"; echo "sent #7 to $2"
STUB
cat > "$tmp/census" <<'STUB'
#!/usr/bin/env bash
for d in "$GB_DOCS"/*.md; do printf '1\t%s\t-\n' "$(basename "$d" .md)"; done
STUB
chmod +x "$tmp/gh" "$tmp/go" "$tmp/bus" "$tmp/census"
export GB_FIX="$FIX" GB_ANCHOR="$ANCHOR" GB_DOCS="$tmp/docs"
export GO_BATCH_GH="$tmp/gh" GO_BATCH_GO="$tmp/go" GO_BATCH_BUS="$tmp/bus" GO_BATCH_CENSUS="$tmp/census" GO_BATCH_ANCHOR="$ANCHOR"

prs() {
    jq -n \
        --arg h101 "$H101" --arg h102 "$H102" --arg h103 "$H103" --arg h104 "$H104" --arg h105 "$H105" '[
        {number:101, headRefOid:$h101, baseRefName:"main", isDraft:false, body:"completes-ticket: yes", files:[{path:"scripts/a.sh"}]},
        {number:102, headRefOid:$h102, baseRefName:"main", isDraft:false, body:"completes-ticket: yes", files:[{path:"scripts/ci/x.sh"}]},
        {number:103, headRefOid:$h103, baseRefName:"main", isDraft:false, body:"completes-ticket: yes", files:[{path:"scripts/b.sh"}]},
        {number:104, headRefOid:$h104, baseRefName:"main", isDraft:false, body:"completes-ticket: yes", files:[{path:"scripts/c.sh"}]},
        {number:105, headRefOid:$h105, baseRefName:"main", isDraft:false, body:"## Ticket coverage\n\ncompletes-ticket: yes\n", files:[{path:"scripts/d.sh"}]}]' > "$FIX/prs.json"
}
reset() { rm -f "$FIX/go.log" "$FIX/concurrency.log" "$HANDOVER_DIR"/.locks/go/* "$FIX/bus"/*; : > "$FIX/go.log"; : > "$FIX/concurrency.log"; }
prs

reset
OUT=$(bash "$SCRIPT" --doc "$tmp/chief.md" --fleet "$tmp/fleet.json" 2>&1); RC=$?
check "1 five PRs: exit 0" "$RC" "0"
GOS=$(find "$HANDOVER_DIR/.locks/go" -type f | sed 's#.*/##' | sort | tr '\n' ' ')
check "1 five PRs: exactly the two GOs are written" "$GOS" "101.$H101 102.$H102 "
contains "1 ordinary PR is sent" "$OUT" "GO-SENT 101 ${H101:0:8} to N1"
contains "1 trust PR is sent with the judge qid" "$OUT" "GO-SENT 102 ${H102:0:8} to N2"
contains "1 trust PR names its qid" "$OUT" "qid=J102"
contains "1 no verdict is held and named" "$OUT" "HOLD 103 ${H103:0:8} no judge verdict at head"
contains "1 stale head is held and named" "$OUT" "HOLD 104 ${H104:0:8} stale head: the worker's READY names ${H104OLD:0:8}"
contains "1 contract disagreement is held and named" "$OUT" "HOLD 105 ${H105:0:8} contract: the brief says no, the PR body says yes"
contains "1 summary" "$OUT" "go-batch: 2 GO, 3 held"
check "2 go.sh got the brief's contract for 101" "$(grep '^pr=101 ' "$FIX/go.log" | sed 's/ anchor=.*//')" "pr=101 contract=yes trust="
check "2 go.sh got the trust qid for 102 on the retry" "$(grep '^pr=102 ' "$FIX/go.log" | sed 's/ anchor=.*//' | tr '\n' '|')" "pr=102 contract=yes trust=|pr=102 contract=yes trust=J102|"
check "2 no go.sh call for a held PR" "$(grep -cE '^pr=10[345] ' "$FIX/go.log")" "0"
MSG1=$(cat "$FIX/bus/wk-9001-N1-ordinary-2026-11-25.msg" 2>/dev/null)
contains "2 worker message carries the GO and merge line" "$MSG1" "GO 101 $H101 - merge with: bash "
contains "2 worker message names the GO file" "$MSG1" "--go $HANDOVER_DIR/.locks/go/101.$H101"
contains "2 worker message carries that worker's token" "$MSG1" 'Your token `CN-N1-tok`'
MSG2=$(cat "$FIX/bus/wk-9002-N2-trust-2026-11-25.msg" 2>/dev/null)
contains "2 the other worker gets its own token" "$MSG2" 'Your token `CN-N2-tok`'
case "$MSG2" in *CN-N1-tok*) FAIL=$((FAIL + 1)); echo "FAIL 2 a worker message quotes another worker's token" ;; *) PASS=$((PASS + 1)); echo "ok   2 no cross-worker token" ;; esac

MUT="$tmp/m/scripts/handover/chief-kit"
mkdir -p "$tmp/m/scripts/handover" "$MUT"
ln -s "$HERE/../../lib" "$tmp/m/scripts/lib"
ln -s "$HERE/../../cr" "$tmp/m/scripts/cr"
for f in "$HERE"/*.sh; do ln -s "$f" "$MUT/$(basename "$f")"; done
rm -f "$MUT/go-batch.sh"
sed '/the brief says \$CONTRACT, the PR body says/d' "$SCRIPT" > "$MUT/go-batch.sh"
if cmp -s "$SCRIPT" "$MUT/go-batch.sh"; then
    FAIL=$((FAIL + 1)); echo "FAIL 1 mutant: go-batch.sh has no line marked '# contract-check'"
else
    reset
    MUT_RC=0
    MUT_OUT=$(bash "$MUT/go-batch.sh" --doc "$tmp/chief.md" --fleet "$tmp/fleet.json" 2>&1) || MUT_RC=$?
    MUT_GOS=$(find "$HANDOVER_DIR/.locks/go" -type f | wc -l | tr -d ' ')
    [ "$MUT_RC" = 0 ] && [ "$MUT_GOS" = 3 ] && { PASS=$((PASS + 1)); echo "ok   1 mutant ignoring the contract line runs and writes the third GO (105)"; } \
        || { FAIL=$((FAIL + 1)); echo "FAIL 1 mutant: want exit 0 and three GOs, got exit $MUT_RC and $MUT_GOS"; echo "$MUT_OUT"; }
fi

reset
mkchief "$tmp/chief-notok.md" "N2 N3 N4 N5"
OUT=$(bash "$SCRIPT" --doc "$tmp/chief-notok.md" --fleet "$tmp/fleet.json" 2>&1); RC=$?
contains "3 NO-TOKEN is printed for the worker" "$OUT" "NO-TOKEN 101 N1"
check "3 no GO file for the worker with no token" "$(find "$HANDOVER_DIR/.locks/go" -name "101.*" | wc -l | tr -d ' ')" "0"
check "3 nothing is sent to it" "$(find "$FIX/bus" -name '*N1*' | wc -l | tr -d ' ')" "0"
check "3 the other GO still goes" "$(find "$HANDOVER_DIR/.locks/go" -name "102.*" | wc -l | tr -d ' ')" "1"

reset
git -C "$tmp/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m second
git -C "$tmp/other" push -q origin HEAD:main 2>/dev/null
NEWTIP=$(git -C "$tmp/other" rev-parse HEAD)
check "4 fixture: the anchor is behind origin" "$([ "$(git -C "$ANCHOR" rev-parse HEAD)" != "$NEWTIP" ] && echo behind)" "behind"
OUT=$(bash "$SCRIPT" --doc "$tmp/chief.md" --fleet "$tmp/fleet.json" 2>&1); RC=$?
check "4 the anchor holds origin's tip afterwards" "$(git -C "$ANCHOR" rev-parse HEAD)" "$NEWTIP"
check "4 every go.sh call saw the fast-forwarded anchor" "$(sed -n 's/.* anchor=//p' "$FIX/go.log" | sort -u | tr '\n' ' ')" "$NEWTIP "

reset
git -C "$ANCHOR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m local-only
git -C "$tmp/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m third
git -C "$tmp/other" push -q origin HEAD:main 2>/dev/null
OUT=$(bash "$SCRIPT" --doc "$tmp/chief.md" --fleet "$tmp/fleet.json" 2>&1); RC=$?
check "5 a diverged primary checkout exits 1" "$RC" "1"
contains "5 it says why and that no GO was written" "$OUT" "did not fast-forward"
check "5 no go.sh call" "$(wc -l < "$FIX/go.log" | tr -d ' ')" "0"
git -C "$ANCHOR" reset -q --hard origin/main 2>/dev/null; git -C "$ANCHOR" fetch -q origin; git -C "$ANCHOR" reset -q --hard origin/main

reset
for n in 6 7 8 9; do
    d="$tmp/docs/wk-90$n-N$n-par-2026-11-25.md"
    printf '# p\n\n> **Completes ticket:** yes\n\n## Results\n- 10:00 READY 10%s %s GREEN\n' "$n" "$(printf "%040d" "$n")" > "$d"
done
PJSON=$(jq -n '[range(6;10) as $n | {number:(100+$n), headRefOid:("0" * 39 + ($n|tostring)), baseRefName:"main", isDraft:false, body:"completes-ticket: yes", files:[{path:"scripts/p.sh"}]}]')
printf '%s\n' "$PJSON" > "$FIX/prs.json"
{ printf '{"workers":['; sep=""; for n in 6 7 8 9; do printf '%s{"label":"N%s","doc":"%s","lane":"native"}' "$sep" "$n" "$(ls "$tmp/docs/wk-90$n-N$n-"*.md)"; sep=","; done; printf ']}\n'; } > "$tmp/fleet-par.json"
mkchief "$tmp/chief-par.md" "N6 N7 N8 N9"
OUT=$(bash "$SCRIPT" --jobs 2 --doc "$tmp/chief-par.md" --fleet "$tmp/fleet-par.json" 2>&1); RC=$?
check "6 four GO-able PRs: four GOs" "$(grep -c '^GO-SENT' <<< "$OUT")" "4"
check "6 --jobs 2 never runs more than two go.sh at once" "$(sort -n "$FIX/concurrency.log" | tail -n 1)" "2"
reset
bash "$SCRIPT" --jobs 4 --doc "$tmp/chief-par.md" --fleet "$tmp/fleet-par.json" >/dev/null 2>&1
check "6 --jobs 4 runs all four at once" "$(sort -n "$FIX/concurrency.log" | tail -n 1)" "4"

prs; reset
OUT=$(bash "$SCRIPT" --dry-run --doc "$tmp/chief.md" --fleet "$tmp/fleet.json" 2>&1); RC=$?
check "7 dry run exits 0" "$RC" "0"
contains "7 dry run names the GO-able rows" "$OUT" "WOULD-GO 101 ${H101:0:8} to N1"
check "7 dry run writes no GO" "$(find "$HANDOVER_DIR/.locks/go" -type f | wc -l | tr -d ' ')" "0"
check "7 dry run calls no go.sh" "$(wc -l < "$FIX/go.log" | tr -d ' ')" "0"
check "7 dry run sends nothing" "$(find "$FIX/bus" -type f | wc -l | tr -d ' ')" "0"

reset
OUT=$(HIMMEL_CONSOLE_LEG=1 bash "$SCRIPT" --doc "$tmp/chief.md" --fleet "$tmp/fleet.json" 2>&1); RC=$?
check "8 a chief-spawned worker is refused" "$RC" "3"
check "8 and nothing ran" "$(wc -l < "$FIX/go.log" | tr -d ' ')" "0"

reset
jq -n '[range(0;200) | {number:(1000+.), headRefOid:"1111111111111111111111111111111111111111", baseRefName:"main", isDraft:true, body:"", files:[]}]' > "$FIX/prs.json"
OUT=$(bash "$SCRIPT" --doc "$tmp/chief.md" --fleet "$tmp/fleet.json" 2>&1); RC=$?
check "9 a PR list that reached the 200 limit exits 1" "$RC" "1"
contains "9 it says the list was cut" "$OUT" "reached the 200 limit"
check "9 and nothing ran" "$(wc -l < "$FIX/go.log" | tr -d ' ')" "0"

mkdir -p "$VERD/J112"
printf '# VERDICT J112 - judge\n\nwriter-session: x\nwritten-at: 2026-11-25T10:00:00Z\n\n## Verdict\n\n**NO-GO** for head `%s`.\n\npr: 112\n\nevidence\nmac: 00\n' "$(printf '%040d' 112)" > "$VERD/J112/judge.md"
worker N11 wk-9111-N11-draft-2026-11-25 yes "" 111 "$(printf '%040d' 111)"
worker N12 wk-9112-N12-nogo-2026-11-25 yes "" 112 "$(printf '%040d' 112)"
worker N13 wk-9113-N13-exit4-2026-11-25 yes "" 113 "$(printf '%040d' 113)"
worker N14 wk-9114-N14-mergehold-2026-11-25 yes "" 114 "$(printf '%040d' 114)"
worker N15 wk-9115-N15-nocontract-2026-11-25 "" "" 115 "$(printf '%040d' 115)"
worker N16 wk-9116-N16-exit10-2026-11-25 yes "" 116 "$(printf '%040d' 116)"
worker N17 wk-9117-N17-exit5-2026-11-25 yes "" 117 "$(printf '%040d' 117)"
worker N18 wk-9118-N18-ordinary-2026-11-25 yes "" 118 "$(printf '%040d' 118)"
{
    printf '{"workers":['; sep=""
    for n in 11 12 13 14 15 16 17 18; do
        printf '%s{"label":"N%s","doc":"%s","lane":"native"}' "$sep" "$n" "$(ls "$tmp/docs/wk-91$n-N$n-"*.md)"; sep=","
    done
    printf ']}\n'
} > "$tmp/fleet-holds.json"
{
    printf '# chief\n\n## Live state\n\nworkers:'
    for l in N11 N12 N13 N14 N15 N16 N17 N18; do printf ' `%s:CN-%s-tok:lock-%s:1`' "$l" "$l" "$l"; done
    printf '\nqueue: none\nmerge-hold: 114\nlast GO: none\n\n## Results\n'
} > "$tmp/chief-holds.md"
jq -n '[range(111;119) as $n | {number:$n, headRefOid:("0" * 37 + ($n|tostring)), baseRefName:"main", isDraft:($n == 111), body:(if $n == 115 then "completes-ticket: yes" else "" end), files:[{path:"scripts/h.sh"}]}]' > "$FIX/prs.json"
reset
OUT=$(bash "$SCRIPT" --doc "$tmp/chief-holds.md" --fleet "$tmp/fleet-holds.json" 2>&1); RC=$?
check "10 holds: exit 0" "$RC" "0"
check "10 holds: only the ordinary PR gets a GO" "$(find "$HANDOVER_DIR/.locks/go" -type f | sed 's#.*/##' | cut -d. -f1 | tr '\n' ' ')" "118 "
contains "10 a draft is held" "$OUT" "HOLD 111 00000000 a draft"
contains "10 a standing judge NO-GO is held and named" "$OUT" "HOLD 112 00000000 no judge verdict at head (a judge NO-GO is on record: J112@00000000)"
contains "10 go.sh exit 4 is a hold" "$OUT" "HOLD 113 00000000 go.sh exit 4: go: refusing - ready-check.sh did not PASS"
contains "10 a merge-hold line is held" "$OUT" "HOLD 114 00000000 the chief doc's Live state says merge-hold: 114"
contains "10 a brief with no contract line reads no and a PR body saying yes is held" "$OUT" "HOLD 115 00000000 contract: the brief says no, the PR body says yes"
contains "10 go.sh exit 10 is a hold" "$OUT" "HOLD 116 00000000 go.sh exit 10:"
contains "10 go.sh exit 5 is a hold" "$OUT" "HOLD 117 00000000 go.sh exit 5:"
contains "10 summary" "$OUT" "go-batch: 1 GO, 7 held"
sed '/a judge NO-GO is on record/d' "$SCRIPT" > "$MUT/go-batch-nogo.sh"
reset
MUT_RC=0
MUT_OUT=$(bash "$MUT/go-batch-nogo.sh" --doc "$tmp/chief-holds.md" --fleet "$tmp/fleet-holds.json" 2>&1) || MUT_RC=$?
[ "$MUT_RC" = 0 ] && [ -f "$HANDOVER_DIR/.locks/go/112.$(printf '%040d' 112)" ] && { PASS=$((PASS + 1)); echo "ok   10 mutant without the NO-GO hold writes the GO for 112"; } \
    || { FAIL=$((FAIL + 1)); echo "FAIL 10 mutant without the NO-GO hold: want exit 0 and a GO for 112, got exit $MUT_RC"; echo "$MUT_OUT"; }

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
