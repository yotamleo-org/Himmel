#!/usr/bin/env bash
# test-rulings-in-force.sh — rulings-in-force.sh records rulings in a ledger and renders
# only the rulings in force into a Current direction block, never dropping a ruling the
# ledger does not hold. Fixtures are synthetic text in the live block's shapes, in a temp
# bucket.
#
# Platform guard: bash 3.2+ and python3; same scope as chief.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/rulings-in-force.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/rulings-in-force-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

B="$W/bucket"
D="$B/specs/decisions"
L="$D/rulings-in-force.jsonl"
mkdir -p "$D"
for n in 901 902 903 904 905; do printf 'OPERATOR words of ruling %s.\n' "$n" > "$D/verbatim-decision-$n-2026-11-11.txt"; done
printf '# Current direction, full text (part 1 of 1), byte for byte, written by chief.sh next\n\nOPERATOR 11-11 ZA (BINDING, decision 901): the full text.\n' > "$D/chief-direction-2026-11-11-p1.md"
rec() { bash "$SUT" record --bucket "$B" "$@" >/dev/null 2>&1; echo $?; }
v() { printf 'specs/decisions/verbatim-decision-%s-2026-11-11.txt' "$1"; }

# --- record
same "record: a first row without --line is refused" "$(rec --id 901 --status in-force --date 2026-11-11 --path "$(v 901)")" "1"
same "record: a non-numeric id is refused" "$(rec --id x1 --status in-force --date 2026-11-11 --line l --path "$(v 901)")" "1"
same "record: an unknown status is refused" "$(rec --id 901 --status gone --date 2026-11-11 --line l --path "$(v 901)")" "1"
same "record: superseded by itself is refused" "$(rec --id 901 --status 'superseded-by 901' --date 2026-11-11 --line l --path "$(v 901)")" "1"
same "record: a two-line --line is refused" "$(rec --id 901 --status in-force --date 2026-11-11 --line "$(printf 'a\nb')" --path "$(v 901)")" "1"
same "record: a missing verbatim file is refused" "$(rec --id 901 --status in-force --date 2026-11-11 --line l --path specs/decisions/verbatim-decision-999-x.txt)" "1"
same "record: a path outside specs/decisions is refused" "$(rec --id 901 --status in-force --date 2026-11-11 --line l --path ../../etc/hostname)" "1"
same "record: nothing was written by a refusal" "$([ -e "$L" ] && echo written || echo none)" "none"
same "record: the in-force ruling 901" "$(rec --id 901 --status in-force --date 2026-11-11 --line 'alpha one line for 901' --path "$(v 901)")" "0"
same "record: ruling 902" "$(rec --id 902 --status in-force --date 2026-11-11 --line 'bravo one line for 902' --path "$(v 902)")" "0"
same "record: 902 superseded by 903, the other fields carried" "$(rec --id 902 --status 'superseded-by 903')" "0"
same "record: ruling 904 recorded done" "$(rec --id 904 --status "done" --date 2026-11-10 --line 'charlie one line for 904' --path "$(v 904)")" "0"
same "record: the ledger holds one JSON row per record" "$(wc -l < "$L" | tr -d ' ')" "4"
same "record: the superseding row keeps the id's line and path" \
    "$(python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][2]; print(r["id"], r["status"], r["line"], r["path"])' "$L")" \
    "902 superseded-by 903 bravo one line for 902 $(v 902)"

# --- render
ptr='Full original text of every ruling below, byte for byte, is in 1 file under the bucket (specs/decisions/chief-direction-2026-11-11-p1.md). READ ALL OF THEM in your first turn.'
blk="$ptr

OPERATOR 11-11 ZA, decision 901: alpha reading of 901 …
OPERATOR 11-11 ZA, decision 902: bravo reading of 902 …
OPERATOR 11-10 YZ, decision 904: charlie reading of 904 …
OPERATOR 11-10 YZ, decision 905: delta reading of 905, no ledger row …
OPERATOR 11-09 WG: echo, a ruling with no number …
OPERATOR 11-09 WF, decisions 858 to 860: foxtrot, a range …
Chain order: one context line."
render() { printf '%s\n' "$1" | bash "$SUT" render --bucket "${2:-$B}"; }
out="$(render "$blk")"; rc=$?
same "render: exits 0" "$rc" "0"
same "render: the in-force ruling 901 is indexed with its date, line and verbatim path" \
    "$(printf '%s\n' "$out" | grep -cxF "IN FORCE 901, 2026-11-11: alpha one line for 901 (verbatim: $(v 901))")" "1"
same "render: only 901 is indexed (superseded 902 and done 904 are not)" "$(printf '%s\n' "$out" | grep -c '^IN FORCE ')" "1"
same "render: the ledgered lines of 901, 902 and 904 leave the block" "$(printf '%s\n' "$out" | grep -cE 'decision (901|902|904):')" "0"
same "render: a ruling with no ledger row (905) is kept as it was" "$(printf '%s\n' "$out" | grep -cxF 'OPERATOR 11-10 YZ, decision 905: delta reading of 905, no ledger row …')" "1"
same "render: a ruling with no number is kept as it was" "$(printf '%s\n' "$out" | grep -cxF 'OPERATOR 11-09 WG: echo, a ruling with no number …')" "1"
same "render: a range whose numbers the ledger lacks is kept" "$(printf '%s\n' "$out" | grep -cF 'decisions 858 to 860: foxtrot')" "1"
same "render: a context line is kept" "$(printf '%s\n' "$out" | grep -cxF 'Chain order: one context line.')" "1"
same "render: the pointer line still names the companion file" "$(printf '%s\n' "$out" | grep '^Full original text' | grep -c 'specs/decisions/chief-direction-2026-11-11-p1.md')" "1"
same "render: rulings left unindexed keep the read-all duty" "$(printf '%s\n' "$out" | grep '^Full original text' | grep -c 'READ ALL OF those files in your first turn')" "1"
same "render: the pointer keeps the read-the-verbatim-file duty" "$(printf '%s\n' "$out" | grep '^Full original text' | grep -c 'before you act on one, read its verbatim file')" "1"
same "render: a second render of its own output changes nothing" "$(render "$out")" "$out"
same "render: the companion and verbatim files stay" "$(find "$D" -name 'verbatim-decision-90[1-5]-*' -o -name 'chief-direction-*' | wc -l | tr -d ' ')" "6"

old="$ptr

IN FORCE 777, 2026-11-01: a row rendered earlier whose ledger row is gone (verbatim: specs/decisions/x.txt)
IN FORCE 904, 2026-11-10: a row rendered earlier, now done (verbatim: $(v 904))"
out="$(render "$old")"
same "render: an earlier index row the ledger lacks is kept" "$(printf '%s\n' "$out" | grep -c '^IN FORCE 777, ')" "1"
same "render: an earlier index row now done leaves" "$(printf '%s\n' "$out" | grep -c '^IN FORCE 904, ')" "0"

mkdir -p "$W/empty"
same "render: with no ledger the block is unchanged" "$(render "$blk" "$W/empty")" "$blk"
same "render: with no pointer line the block is unchanged" "$(render "${blk#"$ptr"}")" "${blk#"$ptr"}"

for n in 858 859; do rec --id "$n" --status "done" --date 2026-11-09 --line "range $n" --path "$(v 905)" >/dev/null; done
same "render: a range with one number unledgered is kept" "$(render "$blk" | grep -cF 'decisions 858 to 860')" "1"
rec --id 860 --status in-force --date 2026-11-09 --line 'range 860' --path "$(v 905)" >/dev/null
same "render: a range with every number ledgered leaves" "$(render "$blk" | grep -cF 'decisions 858 to 860')" "0"
same "render: the range's in-force number is indexed" "$(render "$blk" | grep -c '^IN FORCE 860, ')" "1"

# --- 40 rulings in force: the index stays under 12 KB and names every id
B40="$W/b40"; mkdir -p "$B40/specs/decisions"
cp "$D/chief-direction-2026-11-11-p1.md" "$B40/specs/decisions/"
w="$(printf 'word%.0s ' $(seq 1 40))"
blk40="$ptr"$'\n'
for n in $(seq 1001 1040); do
    printf 'x\n' > "$B40/specs/decisions/verbatim-decision-$n-2026-11-11.txt"
    bash "$SUT" record --bucket "$B40" --id "$n" --status in-force --date 2026-11-11 --line "ruling $n $w" --path "specs/decisions/verbatim-decision-$n-2026-11-11.txt" >/dev/null
    blk40="$blk40"$'\n'"OPERATOR 11-11 ZA, decision $n: reading $n $w"
done
out40="$(render "$blk40" "$B40")"
same "render: 40 rulings in force fit under 12,000 bytes" "$([ "$(printf '%s' "$out40" | wc -c)" -lt 12000 ] && echo under || echo over)" "under"
named=0; for n in $(seq 1001 1040); do grep -q "^IN FORCE $n, 2026-11-11: ruling $n " <<< "$out40" && named=$((named + 1)); done
same "render: every one of the 40 ids is indexed" "$named" "40"
same "render: with every ruling indexed the read-all duty is gone" "$(printf '%s\n' "$out40" | grep '^Full original text' | grep -c 'READ ALL')" "0"

printf 'not json\n' >> "$L"
out="$(render "$blk")"; rc=$?
same "render: an unreadable ledger row exits 3" "$rc" "3"
same "render: an unreadable ledger row prints nothing" "$out" ""

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
