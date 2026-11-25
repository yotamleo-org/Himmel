#!/usr/bin/env bash
# Tests for waiting-ask-drift.sh: temp-bucket fixtures only, never the real owed.jsonl.
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$KIT/waiting-ask-drift.sh"
OWE="$KIT/owe.sh"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$1" "$2" "$3"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-waiting-ask-drift.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fresh() {
    B="$TMP/$1"; mkdir -p "$B"; : > "$B/owed.jsonl"
    DOC="$B/FIX-nextleg-chief.md"; printf '# chief\n\n## Results\n' > "$DOC"
}
add() {
    local actor="$1" kind="$2" text="$3" key="${4:-}" args=()
    [ -z "$key" ] || args+=(--key "$key")
    if [ "$actor" = - ]; then bash "$OWE" add --bucket "$B" --chief A --kind "$kind" --text "$text" ${args[@]+"${args[@]}"}
    else bash "$OWE" add --bucket "$B" --chief A --kind "$kind" --text "$text" ${args[@]+"${args[@]}"} --metadata "{\"actor\":\"$actor\"}"; fi
}
ask()       { printf -- '- 10:00 OWED %s %s\n' "$1" "$2" >> "$DOC"; }
delivered() { printf -- '- 10:01 DELIVERED %s msg=7 chat=1\n' "$1" >> "$DOC"; }
delivered_z() { printf -- '- 10:01Z DELIVERED %s msg=7 chat=1\n' "$1" >> "$DOC"; }
run() { OUT="$(bash "$SCRIPT" --doc "$DOC" 2>"$TMP/err")"; RC=$?; }

echo "D0: the script exists"
check "D0 script present" "$([ -f "$SCRIPT" ] && echo yes || echo no)" "yes"

echo "D1: a waiting row with no open ask is listed"
fresh d1
id="$(add operator ruling "run the station proof" TKT-100)"
run
check "D1 rc 1" "$RC" "1"
check "D1 names the row" "$OUT" "waiting-no-ask	$id	TKT-100	run the station proof"

echo "D2: a matched pair prints nothing and exits 0"
fresh d2
id="$(add operator step "sign the notes")"
ask "$id" "sign the release notes"; delivered "$id"
run
check "D2 rc 0" "$RC" "0"
check "D2 prints nothing" "$OUT" ""
echo "D2b: the ask names the row's ticket key, not its id"
fresh d2b
add operator ruling "pick the day" TKT-200 >/dev/null
ask "TKT-200" "pick the release day"; delivered "TKT-200"
run
check "D2b rc 0" "$RC" "0"
check "D2b prints nothing" "$OUT" ""

echo "D2z: a receipt stamped HH:MMZ (UTC) closes the pair like the bare stamp"
fresh d2z
id="$(add operator step "sign the notes")"
ask "$id" "sign the release notes"; delivered_z "$id"
run
check "D2z rc 0" "$RC" "0"
check "D2z prints nothing" "$OUT" ""

echo "D2c: an ask for a closed row's ticket key does not cover a new open row with that key"
fresh d2c
old="$(add operator ruling "first day" TKT-300)"
ask "TKT-300" "pick the first day"; delivered "TKT-300"
bash "$OWE" close --bucket "$B" --id "$old" --key abc1234 >/dev/null
new="$(add operator ruling "second day" TKT-300)"
run
check "D2c rc 1" "$RC" "1"
check "D2c lists the new row" "$OUT" "waiting-no-ask	$new	TKT-300	second day"

echo "D3: a closed row and a chief-owned row are never listed"
fresh d3
c="$(add operator step "done already")"
bash "$OWE" close --bucket "$B" --id "$c" --key abc1234 >/dev/null
add chief step "the chief's own step" >/dev/null
add - step "a row with no actor" >/dev/null
run
check "D3 rc 0" "$RC" "0"
check "D3 prints nothing" "$OUT" ""

echo "D4: an open ask with no waiting row is listed"
fresh d4
ask "orphan-1" "approve the bypass"; delivered "orphan-1"
run
check "D4 rc 1" "$RC" "1"
check "D4 names the ask" "$OUT" "ask-no-waiting	orphan-1	approve the bypass"

echo "D5: an ask with no DELIVERED receipt is the chief's, not open"
fresh d5
id="$(add operator step "sign the notes")"
ask "$id" "sign the release notes"
run
check "D5 the waiting row is listed (never delivered)" "$OUT" "waiting-no-ask	$id	-	sign the notes"
check "D5 rc 1" "$RC" "1"

echo "D6: an ask whose row is closed is not open"
fresh d6
id="$(add operator step "sign the notes")"
ask "$id" "sign the release notes"; delivered "$id"
bash "$OWE" close --bucket "$B" --id "$id" --key abc1234 >/dev/null
run
check "D6 rc 0" "$RC" "0"
check "D6 prints nothing" "$OUT" ""

echo "D7: usage and unreadable inputs exit 2, never 0 or 1"
bash "$SCRIPT" >/dev/null 2>&1; check "D7 no --doc" "$?" "2"
bash "$SCRIPT" --doc "$TMP/nope.md" >/dev/null 2>&1; check "D7 missing doc" "$?" "2"
fresh d7
printf 'not json\n' > "$B/owed.jsonl"
run
check "D7 unreadable ledger" "$RC" "2"

echo "D7b: input that is not UTF-8 exits 2, never a traceback with rc 1"
fresh d7b
printf -- '- 10:00 OWED k1 \377\376 bad\n' >> "$DOC"
run
check "D7b rc 2" "$RC" "2"

echo "D7c: --bucket names the ledger's directory; a missing one exits 2, never a clean 0"
fresh d7c
id="$(add operator step "sign")"
mkdir -p "$TMP/d7c-doc"; cp "$DOC" "$TMP/d7c-doc/chief.md"
OUT="$(bash "$SCRIPT" --doc "$TMP/d7c-doc/chief.md" --bucket "$B" 2>/dev/null)"; RC=$?
check "D7c valid --bucket reads that ledger" "$OUT" "waiting-no-ask	$id	-	sign"
check "D7c valid --bucket rc 1" "$RC" "1"
bash "$SCRIPT" --doc "$DOC" --bucket "$TMP/no-such-bucket" >/dev/null 2>&1
check "D7c missing --bucket rc 2" "$?" "2"
bash "$SCRIPT" --doc "$DOC" --bucket "$B/owed.jsonl" >/dev/null 2>&1
check "D7c --bucket that is a file rc 2" "$?" "2"

echo "D8: it never writes either input"
fresh d8
id="$(add operator step "sign")"; ask "orphan-9" "x"; delivered "orphan-9"
before="$(cksum "$B/owed.jsonl" "$DOC")"
run
check "D8 inputs unchanged" "$(cksum "$B/owed.jsonl" "$DOC")" "$before"

echo "waiting-ask-drift: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
