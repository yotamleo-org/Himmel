#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines
# test-worker-token.sh - the record of each worker's current RETASK token generation
# (worker-token.sh): mint, current, gen, rotate, the confirm step, tokens and set. Every
# path is a fixture under a temp dir, HOME included: no real key, doc or bucket.
# WORKER_TOKEN overrides the script under test (a missing script fails every row that
# needs it). bash 3.2-safe; needs jq, openssl and flock.
#
# Run: bash scripts/handover/chief-kit/test-worker-token.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SUT="${WORKER_TOKEN:-$HERE/worker-token.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
matches() { printf '%s\n' "$2" | grep -qxE "$3" && pass "$1" || fail "$1 (got '$2', want /$3/)"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/worker-token-test.XXXXXX")" || exit 1
trap 'chmod -R u+rw "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export HANDOVER_DIR="$WORK/root"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY
export HIMMEL_BUS_NAME="HIMMEL-test-chief"
mkdir -p "$HOME/.config/himmel" "$HANDOVER_DIR"

KEYF="$HOME/.config/himmel/go-hmac.key"
K1=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)
K1="$K1$K1$K1$K1"
K2=$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)
K2="$K2$K2$K2$K2"
setkey() { printf '%s\n' "$1" > "$KEYF"; }
setkey "$K1"

wt() { bash "$SUT" "$@" 2>"$WORK/err"; }
err() { cat "$WORK/err" 2>/dev/null; }

n=0
bucket() {
    n=$((n + 1))
    B="$HANDOVER_DIR/u/b$n"; mkdir -p "$B"
    D="$B/HIMMEL-1-N1-demo-2026-01-01.md"
    REC="$B/worker-tokens.jsonl"
}
mkdoc() { printf '# worker\n\n## Results (newest at the bottom)\n\n- 09:00 LIVE — started\n' > "$1"; }
bullet() { printf -- '- 10:00 SUCCESSION accepted: %s replaces X\n' "$2" >> "$1"; }
rows() { [ -f "$REC" ] && wc -l < "$REC" | tr -d ' ' || echo 0; }
nev() { [ -f "$REC" ] && jq -R 'fromjson? | select(.event == "'"$1"'")' -c "$REC" 2>/dev/null | wc -l | tr -d ' ' || echo 0; }

bucket
t1="$(wt mint "$D" Y-N1)"; rc=$?
eq "WT1b: mint succeeds before the doc exists (rc 0)" "$rc" 0
matches "WT1b: the token is the dispatch prefix plus 8 hex" "$t1" 'Y-N1-[0-9a-f]{8}'
t1b="$(wt mint "$D" Y-N1)"; rc=$?
eq "WT1b: a second mint with no doc is rc 0" "$rc" 0
eq "WT1b: and prints the same token" "$t1b" "$t1"
eq "WT1b: and writes one row only" "$(rows)" 1
mkdoc "$D"
wt mint "$D" Y-N1 >/dev/null; rc=$?
eq "WT1d: mint once the doc exists is refused (rc 4)" "$rc" 4
eq "WT1d: and writes nothing" "$(rows)" 1

S=HIMMEL-S-chief
t2="$(wt rotate "$D" --to "$S")"; rc=$?
eq "WT1: rotate is rc 0" "$rc" 0
matches "WT1: the rotation keeps the dispatch prefix" "$t2" 'Y-N1-[0-9a-f]{8}'
[ "$t2" != "$t1" ] && pass "WT1: the rotation is a different token" || fail "WT1: the rotation reused gen 1's token"
eq "WT1: current still prints gen 1" "$(wt current "$D")" "$t1"
eq "WT1: and no confirm row is written" "$(nev confirm)" 0
eq "WT5c: gen prints pending to S and never a token" "$(wt gen "$D")" "current=1 pending=2:$S state=ok"
wt mint "$D" Y-N1 >/dev/null; rc=$?
eq "WT1c: mint on a stem with a rotation is refused (rc 4)" "$rc" 4
bullet "$D" HIMMEL-other-chief
eq "WT2c: a bullet naming another chief leaves gen 1 current" "$(wt current "$D")" "$t1"
bullet "$D" "$S"
eq "WT2: the bullet naming S makes gen 2 current" "$(wt current "$D")" "$t2"
eq "WT2: with exactly one confirm row" "$(nev confirm)" 1
wt current "$D" >/dev/null
eq "WT2: a second read appends no second confirm row" "$(nev confirm)" 1

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"; t2="$(wt rotate "$D" --to "$S")"
# shellcheck disable=SC2016
printf '\n## Chief Rulings (newest at the bottom)\n- 10:01 LIVE — SUCCESSION accepted: `%s` replaces `X`\n- 10:05 SUCCESSION accepted: T replaces %s\n' "$S" "$S" >> "$D"
eq "WT2b: a claudex bullet under Chief Rulings confirms gen 2" "$(wt current "$D")" "$t2"

bucket; t1="$(wt mint "$D" Y-N1)"
printf '# worker\n\n- 10:00 SUCCESSION accepted: %s replaces X\n\n## Results (newest at the bottom)\n\n- 09:00 LIVE — started\n' "$S" > "$D"
wt rotate "$D" --to "$S" >/dev/null
eq "WT2d: a bullet above ## Results leaves gen 1 current" "$(wt current "$D")" "$t1"

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"; t2="$(wt rotate "$D" --to "$S")"; bullet "$D" "$S"
bash "$SUT" current "$D" >/dev/null 2>&1 & p1=$!
bash "$SUT" current "$D" >/dev/null 2>&1 & p2=$!
wait "$p1"; wait "$p2"
eq "WT7: two concurrent current calls append exactly one confirm row" "$(nev confirm)" 1

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"; t2="$(wt rotate "$D" --to "$S")"; bullet "$D" "$S"
rm -f "$WORK/held" "$WORK/release"
( exec 7>>"$REC.lock"; flock 7; : > "$WORK/held"; while [ ! -e "$WORK/release" ]; do sleep 0.1; done ) & holder=$!  # prim-ok: the row proves worker-token.sh waits on this lock
i=0; while [ ! -e "$WORK/held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
bash "$SUT" current "$D" > "$WORK/wt7b.out" 2>/dev/null & p1=$!
sleep 1
eq "WT7b: no confirm row while the lock is held elsewhere" "$(nev confirm)" 0
: > "$WORK/release"; wait "$holder"; wait "$p1"
eq "WT7b: exactly one confirm row once released" "$(nev confirm)" 1
eq "WT7b: and the waiting reader printed gen 2" "$(cat "$WORK/wt7b.out")" "$t2"

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"
bash "$SUT" rotate "$D" --to "$S" > "$WORK/r1" 2>/dev/null & p1=$!
bash "$SUT" rotate "$D" --to "$S" > "$WORK/r2" 2>/dev/null & p2=$!
wait "$p1"; wait "$p2"
eq "WT7c: two concurrent rotate --to S append one rotation row" "$(rows)" 2
eq "WT7c: and both print the same token" "$(cat "$WORK/r1")" "$(cat "$WORK/r2")"

S1=HIMMEL-S1-chief; S2=HIMMEL-S2-chief
bucket; wt mint "$D" Y-N1 >/dev/null; mkdoc "$D"; wt rotate "$D" --to "$S1" >/dev/null
t3="$(wt rotate "$D" --to "$S2")"; rc=$?
eq "WT10: rotate to another chief supersedes the pending one (rc 0)" "$rc" 0
eq "WT10: gen 3 is pending to S2" "$(wt gen "$D")" "current=1 pending=3:$S2 state=ok"
bullet "$D" "$S2"
eq "WT10: a bullet naming S2 confirms gen 3" "$(wt current "$D")" "$t3"
wt rotate "$D" --to "$S2" >/dev/null; rc=$?
eq "WT10c: a bullet already naming S: rotate --to S is refused (rc 4)" "$rc" 4

bucket; wt mint "$D" Y-N1 >/dev/null; mkdoc "$D"; t2="$(wt rotate "$D" --to "$S1")"; bullet "$D" "$S1"
wt rotate "$D" --to "$S2" >/dev/null
eq "WT10b: the unread S1 bullet is confirmed before the next rotation" "$(nev confirm)" 1
eq "WT10b: gen 2 is current" "$(wt current "$D")" "$t2"
eq "WT10d: and gen 3 is pending to S2" "$(wt gen "$D")" "current=2 pending=3:$S2 state=ok"

bucket; wt mint "$D" Y-N1 >/dev/null; mkdoc "$D"; t2="$(wt rotate "$D" --to "$S1")"
wt rotate "$D" --to "$S2" >/dev/null; bullet "$D" "$S1"
eq "WT10e: a late S1 bullet makes the superseded gen 2 current" "$(wt current "$D")" "$t2"
eq "WT10e: gen 3 stays pending to S2" "$(wt gen "$D")" "current=2 pending=3:$S2 state=ok"

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"; t2="$(wt rotate "$D" --to "$S")"; bullet "$D" "$S"
eq "WT12 setup: the forged bullet confirmed gen 2" "$(wt current "$D")" "$t2"
wt set "$D" 1 >/dev/null; rc=$?
eq "WT12: set 1 is rc 0" "$rc" 0
eq "WT12: current prints gen 1 with the bullet still in the doc" "$(wt current "$D")" "$t1"
eq "WT12: gen reads gen 1 current and nothing pending" "$(wt gen "$D")" "current=1 pending=-:- state=ok"
eq "WT12: no new confirm row" "$(nev confirm)" 1
eq "WT12: tokens lists gens 1 and 2" "$(wt tokens "$D")" "1 $t1
2 $t2"
eq "WT12: the set row names the chief session" "$(jq -r 'select(.event == "set") | .by' "$REC")" "HIMMEL-test-chief"
wt set "$D" 9 >/dev/null; rc=$?
eq "WT12c: set of a never-minted generation is refused (rc 4)" "$rc" 4
t3="$(wt rotate "$D" --to T)"
eq "WT12b: a rotation after set is gen 3 pending to T" "$(wt gen "$D")" "current=1 pending=3:T state=ok"
eq "WT12b: current is still gen 1" "$(wt current "$D")" "$t1"
bullet "$D" T
eq "WT12d: a bullet naming T confirms gen 3" "$(wt current "$D")" "$t3"

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"; wt rotate "$D" --to "$S" >/dev/null; wt set "$D" 1 >/dev/null
bullet "$D" "$S"
eq "WT12b: a rotation retired by set never becomes current" "$(wt current "$D")" "$t1"

for var in HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY; do
    bucket; printf '{}\n' > "$REC"; chmod 000 "$REC"; mkdoc "$D"; rm -f "$KEYF"
    for sub in mint current gen rotate tokens set; do
        env "$var=1" bash "$SUT" "$sub" "$D" Y-N1 >/dev/null 2>&1; rc=$?
        eq "WT3: $sub under $var is refused (rc 3)" "$rc" 3
    done
    [ ! -e "$KEYF" ] && pass "WT3: no key was minted under $var" || fail "WT3: a key was minted under $var"
    [ ! -e "$REC.lock" ] && pass "WT3: the record was not opened under $var" || fail "WT3: the lock was opened under $var"
    chmod 600 "$REC"; setkey "$K1"
done
bucket; wt mint "$D" Y-N1 >/dev/null; rc=$?
eq "WT3c: with neither variable set mint is rc 0" "$rc" 0

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"
eq "WT8c: the same key reads rc 0" "$(wt current "$D" >/dev/null; echo $?)" 0
setkey "$K2"
out="$(wt current "$D")"; rc=$?
eq "WT8: a replaced key: current exits 1" "$rc" 1
eq "WT8: and prints no token" "$out" ""
has "WT8: gen reads keymismatch" "$(wt gen "$D")" "state=keymismatch"
rm -f "$KEYF"
wt current "$D" >/dev/null; rc=$?
eq "WT8: with no key current exits 1" "$rc" 1
[ ! -e "$KEYF" ] && pass "WT8: current mints no key" || fail "WT8: current minted a key"
setkey "$K1"
mkdir -p "$WORK/broken-bin"; printf '#!/bin/sh\nexit 1\n' > "$WORK/broken-bin/openssl"; chmod +x "$WORK/broken-bin/openssl"
PATH="$WORK/broken-bin:$PATH" wt current "$D" >/dev/null; rc=$?
eq "WT8b: a present key that cannot be used is bad (rc 6), not a fallback" "$rc" 6
bucket; mkdoc "$D"; chmod 000 "$B"
wt current "$D" >/dev/null; rc=$?
eq "WT9d: a record directory that cannot be entered is bad (rc 6), not a fallback" "$rc" 6
chmod 700 "$B"
bucket; mkdir -p "$B/deeper"; chmod 000 "$B"
wt current "$B/deeper/HIMMEL-1-N1-demo-2026-01-01.md" >/dev/null; rc=$?
eq "WT9d: a directory under one that denies traversal is bad (rc 6), not absent" "$rc" 6
chmod 700 "$B"
wt current "$B/never-made/HIMMEL-1-N1-demo-2026-01-01.md" >/dev/null; rc=$?
eq "WT9d: a directory that does not exist is still no record (rc 1)" "$rc" 1
bucket; wt mint "$D" Y-N1 >/dev/null; mkdoc "$D"; chmod 000 "$KEYF"
wt current "$D" >/dev/null; rc=$?
eq "WT8b: an unreadable key is bad (rc 6), not a keymismatch" "$rc" 6
chmod 600 "$KEYF"
chmod 000 "$D"
wt current "$D" >/dev/null; rc=$?
eq "WT9e: an unreadable worker doc is bad (rc 6), never read as no quote-back" "$rc" 6
chmod 600 "$D"
bucket; mkdoc "$D"
out="$(wt gen "$D")"; rc=$?
eq "a stem with no rows reads none" "$out" "current=- pending=-:- state=none"
eq "and exits 1" "$rc" 1

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"
wt current "$D" >/dev/null
eq "WT9c: a clean record prints no note" "$(err)" ""
printf '{"v":1,"stem":"HIMMEL-1-N2-torn' >> "$REC"
eq "WT9: a torn last line is skipped and the other stems read" "$(wt current "$D")" "$t1"
has "WT9: with a note naming its line" "$(err)" "line 2"
D2="$B/HIMMEL-2-N2-other-2026-01-01.md"
u1="$(wt mint "$D2" Y-N2)"; rc=$?
eq "WT9b: mint after a torn line is rc 0" "$rc" 0
has "WT9b: and its row parses and gen reports it" "$(wt gen "$D2")" "current=1 pending=-:- state=ok"
eq "WT9b: and current prints the same token" "$(wt current "$D2")" "$u1"
chmod 000 "$REC"
wt current "$D" >/dev/null; rc=$?
eq "WT9: an unreadable record exits 6" "$rc" 6
has "WT9: gen reads bad" "$(wt gen "$D")" "state=bad"
chmod 600 "$REC"

bucket; a="$(wt mint "$D" Y-N1)"; bucket; b="$(wt mint "$D" Y-N1)"
[ -n "$a" ] && [ "$a" != "$b" ] && pass "WT13: one stem in two buckets gets two different tokens" || fail "WT13: got '$a' and '$b'"
OUT="$WORK/outside"; mkdir -p "$OUT"; OD="$OUT/HIMMEL-3-N3-out-2026-01-01.md"
a="$(wt mint "$OD" Y-N3)"; mkdoc "$OD"
eq "WT13c: a bucket outside the root: mint and a later current agree" "$(wt current "$OD")" "$a"
mkdir -p "$WORK/root2"
eq "WT13c: and the token is keyed on the bucket's absolute path, not the root" "$(HANDOVER_DIR="$WORK/root2" wt current "$OD")" "$a"

bucket; t1="$(wt mint "$D" Y-N1)"; mkdoc "$D"; t2="$(wt rotate "$D" --to "$S")"; bullet "$D" "$S"
wt current "$D" >/dev/null; wt set "$D" 1 >/dev/null
eq "WT5b: the history holds all four row kinds" \
    "$(jq -r '.event + ":" + (.kind // "")' "$REC" 2>/dev/null | tr '\n' ' ')" "mint:dispatch mint:rotate confirm: set: "
bad_keys="$(jq -r '
    (if .event == "mint" then ["at","event","gen","keyid","kind","prefix","stem","to","v"]
     elif .event == "confirm" then ["at","event","gen","keyid","stem","v"]
     else ["at","by","event","gen","keyid","stem","v"] end) as $want
    | select((keys | sort) != $want) | .event' "$REC" 2>&1)"
eq "WT5: every row has exactly its event's keys" "$bad_keys" ""
leak=""
for tok in "$t1" "$t2"; do
    [ -n "$tok" ] || { leak="empty-token"; break; }
    sha="$(printf '%s' "$tok" | sha256sum | awk '{print $1}')"
    hex="${tok##*-}"
    for needle in "$tok" "$sha" "$hex"; do
        grep -qF -- "$needle" "$REC" 2>/dev/null && leak="$leak $needle"
    done
done
[ -f "$REC" ] && eq "WT5: no row holds a token or its sha256" "$leak" "" || fail "WT5: no record to check"

hook() { jq -cn --arg p "$1" '{tool_name:"Read", tool_input:{file_path:$p}}' | bash "$REPO/scripts/hooks/block-read-secrets.sh" >/dev/null 2>&1; }
hook "$KEYF"; rc=$?
eq "WT6: block-read-secrets.sh denies a Read of the GO key" "$rc" 2
hook "$B/worker-tokens.jsonl"; rc=$?
eq "WT6c: a Read of the record is allowed" "$rc" 0

writers() { (cd "$1" && git grep "$2" -l -F 'worker-tokens.jsonl' -- scripts) 2>/dev/null | sort; }
eq "WT4: only worker-token.sh and its suite name the record" "$(writers "$REPO" --untracked)" \
    "scripts/handover/chief-kit/test-worker-token.sh
scripts/handover/chief-kit/worker-token.sh"
TREE="$WORK/tree"; mkdir -p "$TREE/scripts"
printf 'echo x >> worker-tokens.jsonl\n' > "$TREE/scripts/second-writer.sh"
eq "WT4c: the same check names a second writer" "$(writers "$TREE" --no-index)" "scripts/second-writer.sh"

wt >/dev/null; eq "no arguments is a usage error (rc 2)" "$?" 2
wt frob "$D" >/dev/null; eq "an unknown subcommand is a usage error (rc 2)" "$?" 2
wt rotate "$D" >/dev/null; eq "rotate without --to is a usage error (rc 2)" "$?" 2
wt rotate "$D" --to 'a b' >/dev/null; eq "a chief name with a space is a usage error (rc 2)" "$?" 2
wt mint "$D" 'x"y' >/dev/null; eq "a prefix with a quote is a usage error (rc 2)" "$?" 2
wt set "$D" 01 >/dev/null; eq "a malformed generation is a usage error (rc 2)" "$?" 2

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
