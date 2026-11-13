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
for n in 901 902 903 904 905 906; do printf 'OPERATOR words of ruling %s.\n' "$n" > "$D/verbatim-decision-$n-2026-11-11.txt"; done
for n in 908 909; do printf 'OPERATOR words of ruling %s.\n' "$n" > "$D/verbatim-decision-$n-operator-11-12-ZH.txt"; done
printf '%s\n\n' '# Current direction, full text (part 1 of 1), byte for byte, written by chief.sh next' \
    'OPERATOR 11-11 ZA (BINDING, decision 901): alpha reading of 901, the full text.' \
    'OPERATOR 11-11 ZA (BINDING, decision 902): bravo reading of 902, the full text.' \
    'OPERATOR 11-10 YZ (BINDING, decision 904): charlie reading of 904, the full text.' \
    'OPERATOR 11-10 YZ (BINDING, decision 905): delta reading of 905, no ledger row, the full text.' \
    'OPERATOR 11-09 WG (BINDING): echo, a ruling with no number, the full text.' \
    'OPERATOR 11-09 WF (BINDING, decisions 858 to 860): foxtrot, a range, the full text.' \
    'OPERATOR 11-11 ZB (BINDING): replaces decision 901 with the golf rule, the full text.' \
    'OPERATOR 11-01 AA (BINDING, decisions 1 to 100): a range too wide to expand, the full text.' \
    'OPERATOR 11-01 AA (BINDING, decisions 100 to 1): a reversed range, the full text.' \
    'OPERATOR 11-12 ZD, decision 903 (BINDING; verbatim specs/decisions/verbatim-decision-903-x.txt): hotel, its number before the parenthesis.' \
    'OPERATOR 11-12 ZE (BINDING, decision 907): india same opening words, numbered.' \
    'OPERATOR 11-12 ZE (BINDING): india same opening words, unnumbered, citing decision 907.' \
    'OPERATOR 11-11 ZF (relayed to ZG), decision 906 (BINDING): kilo, relayed, the full text.' > "$D/chief-direction-2026-11-11-p1.md"
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
same "render: the in-force ruling 901 is indexed with its date, line and short verbatim id" \
    "$(printf '%s\n' "$out" | grep -cxF "901 2026-11-11 alpha one line for 901 (verbatim 901-2026-11-11)")" "1"
same "render: the pointer says how a short verbatim id names its file" "$(printf '%s\n' "$out" | grep '^Full original text' | grep -c 'verbatim-decision-<short id>.txt')" "1"
same "render: only 901 is indexed (superseded 902 and done 904 are not)" "$(printf '%s\n' "$out" | grep -cE '^[0-9]+ 2026-')" "1"
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
same "render: the range's in-force number is indexed" "$(render "$blk" | grep -c '^860 2026-11-09 range 860 ')" "1"
wide="$ptr

OPERATOR 11-01 AA, decisions 1 to 100: a range too wide to expand …
OPERATOR 11-01 AA, decisions 100 to 1: a reversed range …"
for n in 1 100; do rec --id "$n" --status "done" --date 2026-11-01 --line "end $n" --path "$(v 905)" >/dev/null; done
same "render: a range over 50 numbers is kept when only its ends are ledgered" "$(render "$wide" | grep -cF 'decisions 1 to 100: a range too wide')" "1"
same "render: a reversed range is kept when only its ends are ledgered" "$(render "$wide" | grep -cF 'decisions 100 to 1: a reversed range')" "1"
BP="$W/partial"; mkdir -p "$BP/specs/decisions"
printf '{"id": 901}\n' > "$BP/specs/decisions/rulings-in-force.jsonl"
out="$(render "$blk" "$BP")"; rc=$?
same "render: a ledger row without its status, line, date or path exits 3" "$rc" "3"
same "render: that render prints nothing, so the ruling is never dropped" "$out" ""
cite="$ptr

OPERATOR 11-11 ZA, decision 901: alpha reading of 901 …
OPERATOR 11-11 ZB, decision 901: replaces decision 901 with the golf rule …
OPERATOR 11-12 ZC, decision 902: an index line with no full text in the companions …
OPERATOR 11-12 ZD, decision 903: hotel, its number before the parenthesis.
OPERATOR 11-12 ZE, decision 907: india same opening words, numbered …
OPERATOR 11-12 ZE, decision 907: india same opening words, unnumbered …
OPERATOR 11-11 ZF, decision 906: kilo, relayed …
OPERATOR 11-12 ZH, decision 908: lima, the full text in the block, verbatim specs/decisions/verbatim-decision-908-operator-11-12-ZH.txt.
CHIEF ZH 11-12, decision 908: mike, a chief rule under 908, verbatim specs/decisions/verbatim-decision-908-operator-11-12-ZH.txt.
OPERATOR 11-12 ZJ, decision 908: november, a later ruling citing verbatim specs/decisions/verbatim-decision-908-operator-11-12-ZH.txt.
OPERATOR 11-12 ZH, decision 908: oscar, the same shift citing 908 with no verbatim path.
OPERATOR 11-12 ZH, decisions 908 and 909: papa, the same shift citing two numbers, verbatim specs/decisions/verbatim-decision-908-operator-11-12-ZH.txt and specs/decisions/verbatim-decision-909-operator-11-12-ZH.txt."
rec --id 903 --status "done" --date 2026-11-12 --line 'hotel' --path "$(v 903)" >/dev/null
rec --id 907 --status "done" --date 2026-11-12 --line 'india' --path "$(v 905)" >/dev/null
rec --id 906 --status "done" --date 2026-11-11 --line 'kilo' --path "$(v 906)" >/dev/null
rec --id 908 --status "done" --date 2026-11-12 --line 'lima' --path specs/decisions/verbatim-decision-908-operator-11-12-ZH.txt >/dev/null
rec --id 909 --status "done" --date 2026-11-12 --line 'papa' --path specs/decisions/verbatim-decision-909-operator-11-12-ZH.txt >/dev/null
out="$(render "$cite")"
same "render: two full texts an index line matches, one unnumbered, keep both lines" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-12 ZE, decision 907: india same opening words')" "2"
same "render: a ruling whose own number precedes its parenthesis leaves once ledgered" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-12 ZD, decision 903:')" "0"
same "render: the ruling numbered 901 leaves once 901 is ledgered" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-11 ZA, decision 901:')" "0"
same "render: an unnumbered ruling that only cites ledgered 901 stays" "$(printf '%s\n' "$out" | grep -cxF 'OPERATOR 11-11 ZB, decision 901: replaces decision 901 with the golf rule …')" "1"
same "render: a ruling whose number follows a numberless parenthesis leaves once ledgered" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-11 ZF, decision 906:')" "0"
same "render: an OPERATOR line with no companion text that names its ledgered verbatim file leaves" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-12 ZH, decision 908: lima')" "0"
same "render: a CHIEF line naming that verbatim file stays" "$(printf '%s\n' "$out" | grep -c '^CHIEF ZH 11-12, decision 908:')" "1"
same "render: a same-shift OPERATOR line citing the number without its verbatim path stays" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-12 ZH, decision 908: oscar')" "1"
same "render: a same-shift OPERATOR line citing two ledgered numbers stays" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-12 ZH, decisions 908 and 909: papa')" "1"
same "render: an OPERATOR line of another shift naming that verbatim file stays" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-12 ZJ, decision 908:')" "1"
same "render: an index line whose full text is in no companion stays" "$(printf '%s\n' "$out" | grep -c '^OPERATOR 11-12 ZC, decision 902:')" "1"
same "render: with those rulings left, the read-all duty stays" "$(printf '%s\n' "$out" | grep '^Full original text' | grep -c 'READ ALL OF those files in your first turn')" "1"
same "record: superseding by a decision with no ledger row warns" "$(bash "$SUT" record --bucket "$B" --id 905 --status 'superseded-by 9999' --date 2026-11-10 --line 'delta' --path "$(v 905)" 2>&1 >/dev/null | grep -c 'decision 9999 has no ledger row yet')" "1"

# --- 40 rulings in force: the index stays under 12 KB and names every id
B40="$W/b40"; mkdir -p "$B40/specs/decisions"
w="$(printf 'word%.0s ' $(seq 1 40))"
printf '# Current direction, full text (part 1 of 1), byte for byte, written by chief.sh next\n' > "$B40/specs/decisions/chief-direction-2026-11-11-p1.md"
for n in $(seq 1001 1040); do printf '\nOPERATOR 11-11 ZA (BINDING, decision %s): reading %s %s\n' "$n" "$n" "$w" >> "$B40/specs/decisions/chief-direction-2026-11-11-p1.md"; done
blk40="$ptr"$'\n'
for n in $(seq 1001 1040); do
    printf 'x\n' > "$B40/specs/decisions/verbatim-decision-$n-2026-11-11.txt"
    bash "$SUT" record --bucket "$B40" --id "$n" --status in-force --date 2026-11-11 --line "ruling $n $w" --path "specs/decisions/verbatim-decision-$n-2026-11-11.txt" >/dev/null
    blk40="$blk40"$'\n'"OPERATOR 11-11 ZA, decision $n: reading $n $w"
done
out40="$(render "$blk40" "$B40")"
same "render: 40 rulings in force fit under 12,000 bytes" "$([ "$(printf '%s' "$out40" | wc -c)" -lt 12000 ] && echo under || echo over)" "under"
named=0; for n in $(seq 1001 1040); do grep -q "^$n 2026-11-11 ruling $n " <<< "$out40" && named=$((named + 1)); done
same "render: every one of the 40 ids is indexed" "$named" "40"
same "render: with every ruling indexed the read-all duty is gone" "$(printf '%s\n' "$out40" | grep '^Full original text' | grep -c 'READ ALL')" "0"

# --- the grouped index: rows under a verbatim-shift head, one shared reading cap, a
# fail-closed self-check, and the check and find verbs.
G="$W/grouped"; GD="$G/specs/decisions"; mkdir -p "$GD"
zulus() { printf ' zulu%.0s' $(seq 1 "$1"); }
L950="x$(zulus 28)"; L959="yy$(zulus 28)"; L955="ab$(zulus 40)"
L953='exactly at the cap, a whole line of ninety-six bytes qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
grec() {
    printf 'OPERATOR words of ruling %s.\n' "$1" > "$GD/$5"
    bash "$SUT" record --bucket "$G" --id "$1" --status "$2" --date "$3" --line "$4" --path "specs/decisions/$5" >/dev/null 2>&1
}
grec 950 in-force 2026-11-12 "$L950" verbatim-decision-950-operator-11-12-ZK.txt
grec 951 in-force 2026-11-12 'a ruling of 21 bytes.' verbatim-decision-951-operator-11-12-ZK.txt
grec 952 in-force 2026-11-12 'copied ruling under a head marked copied' verbatim-decision-952-operator-11-12-ZM-copied.txt
grec 953 in-force 2026-11-11 "$L953" verbatim-decision-953-operator-11-11-ZA.txt
grec 959 in-force 2026-11-11 "$L959" verbatim-decision-959-operator-11-11-ZA.txt
grec 954 in-force 2025-12-30 'another year ruling' verbatim-decision-954-operator-12-30-QQ.txt
grec 955 in-force 2026-11-10 "$L955" verbatim-decision-958-operator-11-10-ZB.txt
grec 956 'superseded-by 950' 2026-11-12 'superseded ruling' verbatim-decision-956-operator-11-12-ZK.txt
grec 957 "done" 2026-11-11 'done ruling' verbatim-decision-957-operator-11-11-ZA.txt
printf '%s\n\n' '# Current direction, full text (part 1 of 1), byte for byte, written by chief.sh next' \
    'OPERATOR 11-11 ZA (BINDING, decision 957): done ruling reading, the full text.' \
    'OPERATOR 11-09 WG (BINDING): echo, an unledgered ruling, the full text.' > "$GD/chief-direction-2026-11-12-p1.md"
gptr='Full original text of every ruling below, byte for byte, is in 1 file under the bucket (specs/decisions/chief-direction-2026-11-12-p1.md). READ ALL OF THEM in your first turn.'
gblk="$gptr

OPERATOR 11-11 ZA, decision 957: done ruling reading …
OPERATOR 11-09 WG: echo, an unledgered ruling …
Chain order: one context line."
para() { sed -n '/^Rulings in force (/,/^$/p' | sed '/^$/d'; }
gwant="Rulings in force (7; left out: 1 done, 1 superseded; year 2026 unless a head shows one):
11-12 ZM copied:
952 copied ruling under a head marked copied
11-12 ZK:
951 a ruling of 21 bytes.
950 x$(zulus 19)
11-11 ZA:
959 yy$(zulus 18)
953 $L953
2025-12-30 QQ:
954 another year ruling
Other verbatim paths:
955 2026-11-10 ab$(zulus 10) (verbatim 958-operator-11-10-ZB)"
gout="$(CHIEF_DIRECTION_BUDGET_BYTES=12000 render "$gblk" "$G")"; rc=$?
same "render: the grouped fixture exits 0" "$rc" "0"
same "render: the fixture's in-force rulings are these exact lines under these exact heads" "$(printf '%s\n' "$gout" | para)" "$gwant"
same "render: a -copied file sits under a head marked copied" "$(printf '%s\n' "$gout" | grep -A1 -xF '11-12 ZM copied:' | tail -n 1)" "952 copied ruling under a head marked copied"
same "render: a file of another shape is a row under Other verbatim paths with its short id" "$(printf '%s\n' "$gout" | grep -A1 -xF 'Other verbatim paths:' | tail -n 1)" "955 2026-11-10 ab$(zulus 10) (verbatim 958-operator-11-10-ZB)"
same "render: a ruling of another year has a full-date head" "$(printf '%s\n' "$gout" | grep -A1 -xF '2025-12-30 QQ:' | tail -n 1)" "954 another year ruling"
same "render: the superseded and the done ruling are no row; the head reads left out: 1 done, 1 superseded" \
    "$(printf '%s\n' "$gout" | grep -cE '^95[67] ')/$(printf '%s\n' "$gout" | grep -c '^Rulings in force (7; left out: 1 done, 1 superseded;')" "0/1"
same "render: a ledger line shorter than the cap is printed whole with no ellipsis" "$(printf '%s\n' "$gout" | grep -cxF '951 a ruling of 21 bytes.')" "1"
same "render: at budget 12000 the cap is 96 and a 96-byte ledger line is printed whole" "$(printf '%s\n' "$gout" | grep -cxF "953 $L953")" "1"
same "render: a cut whose byte at the cap is a space keeps its last whole word" "$(printf '%s\n' "$gout" | grep -cxF "950 x$(zulus 19)")" "1"
same "render: a cut inside a word backs off to the last space" "$(printf '%s\n' "$gout" | grep -cxF "959 yy$(zulus 18)")" "1"
same "render: every reading is cut at the same cap with no ellipsis" "$(printf '%s\n' "$gout" | para | grep -c '…')/$(printf '%s\n' "$gout" | para | LC_ALL=C awk '/^9[0-9][0-9] / && length($0) - 4 > 96' | wc -l | tr -d ' ')" "0/0"
same "render: no index line is over 100 bytes, an other-shape row with a 200-byte line included" "$(printf '%s\n' "$gout" | para | LC_ALL=C awk 'length($0) > 100' | wc -l | tr -d ' ')" "0"
same "render: the pointer says a reading is the start of its ledger line and names find" \
    "$(printf '%s\n' "$gout" | grep '^Full original text' | grep -c 'start of its ledger line')/$(printf '%s\n' "$gout" | grep '^Full original text' | grep -c 'rulings-in-force.sh find --bucket')" "1/1"
same "render: a second render of the grouped output changes nothing" "$(CHIEF_DIRECTION_BUDGET_BYTES=12000 render "$gout" "$G")" "$gout"
same "find: a word lists every ruling whose ledger line holds it, newest id first" "$(bash "$SUT" find --bucket "$G" zulu | cut -d ' ' -f 1 | tr '\n' ' ')" "959 955 950 "
same "find: an id prints its whole ledger line, status and verbatim path" "$(bash "$SUT" find --bucket "$G" 951)" "951 2026-11-12 in-force a ruling of 21 bytes. (verbatim specs/decisions/verbatim-decision-951-operator-11-12-ZK.txt)"

a9="$(CHIEF_DIRECTION_BUDGET_BYTES=1500 render "$gptr

Short context." "$G" 2>/dev/null | para)"
b9="$(CHIEF_DIRECTION_BUDGET_BYTES=1500 render "$gptr

Long context line one, written to move the bytes outside the index by about eighty.
Long context line two, written to move the bytes outside the index by about eighty.
Long context line three, written to move the bytes outside the index by about eighty." "$G" 2>/dev/null | para)"
same "render: two blocks with different lines after the index give the same index paragraph" "$([ -n "$a9" ] && [ "$a9" = "$b9" ] && echo same || echo differs)" "same"

ear="$gptr

Rulings in force (3; left out: 0 done, 0 superseded; year 2026 unless a head shows one):
11-12 ZK:
951 a ruling of
OPERATOR 11-09 WG: echo, an unledgered ruling typed inside the index …
950 x zulu zulu
777 a row whose id the ledger lacks
950 is the count of a context line typed in the index
11-11 ZA:
953 exactly at the cap, a…

Chain order: one context line."
rout="$(render "$ear" "$G")"
same "render: an unledgered OPERATOR line placed inside an earlier grouped index paragraph survives the re-render" \
    "$(printf '%s\n' "$rout" | para | grep -c '^OPERATOR 11-09 WG')/$(printf '%s\n' "$rout" | grep -cxF 'OPERATOR 11-09 WG: echo, an unledgered ruling typed inside the index …')" "0/1"
same "render: the earlier grouped rows after that OPERATOR line are dropped too, none left after the new index" \
    "$(printf '%s\n' "$rout" | grep -cxF '953 exactly at the cap, a…')/$(printf '%s\n' "$rout" | grep -cxF '951 a ruling of')" "0/0"
same "render: an earlier row is dropped only when its reading is a prefix of a ledger line; a context line starting with that id stays" \
    "$(printf '%s\n' "$rout" | grep '^950 ' | tr '\n' '|')" "950 x$(zulus 19)|950 is the count of a context line typed in the index|"
same "render: an earlier grouped row whose id the ledger lacks is kept with its head" "$(printf '%s\n' "$rout" | grep -cxF '11-12 ZK 777 a row whose id the ledger lacks')" "1"
same "render: a second render of the re-rendered block changes nothing" "$(render "$rout" "$G")" "$rout"

runs="$gptr

OPERATOR 11-11 ZA, decision 957: done ruling reading …



Context A.


Context B."
same "render: blank runs after the index collapse to one, and output minus index equals input minus index and dropped rulings" \
    "$(render "$runs" "$G" | sed '1,/^Rulings in force (/d' | sed '1,/^$/d')" "Context A.

Context B."

fault() { out="$(printf '%s\n' "$2" | RULINGS_IN_FORCE_FAULT="$1" bash "$SUT" render --bucket "$G" 2>"$W/fault.err")"; printf '%s/%s' "$?" "$out"; }
same "render: RULINGS_IN_FORCE_FAULT=drop-row:951 exits 4 and prints nothing" "$(fault drop-row:951 "$gblk")" "4/"
same "render: RULINGS_IN_FORCE_FAULT=lose-line:OPERATOR 11-09 WG exits 4, prints nothing and names it LOST" "$(fault 'lose-line:OPERATOR 11-09 WG' "$gblk")/$(grep -c '^LOST OPERATOR 11-09 WG' "$W/fault.err")" "4//1"
same "render: a lose-line fault on a context line exits 4, prints nothing and names it CHANGED" "$(fault 'lose-line:Chain order' "$gblk")/$(grep -c '^CHANGED [0-9]' "$W/fault.err")" "4//1"
same "render: a fault that matches no line still exits 4 and prints nothing" "$(fault 'lose-line:no line starts like this' "$gblk")" "4/"

chk() { printf '%s\n' "$1" | bash "$SUT" check --bucket "${2:-$G}" "${@:3}"; }
same "check: a fresh render prints check: ok and exits 0" "$(chk "$gout" | grep -c '^check: ok in-force=7 named=7 ')/$(chk "$gout" >/dev/null; echo $?)" "1/0"
same "check: a 21-byte whole reading and a cut reading both pass the prefix test, with the pointer present" \
    "$(chk "$gout" | grep -c '^READING ')/$(printf '%s\n' "$gout" | grep -cxF -e '951 a ruling of 21 bytes.' -e "950 x$(zulus 19)")/$(printf '%s\n' "$gout" | grep '^Full original text' | grep -c 'start of its ledger line')" "0/2/1"
same "check: a row deleted prints MISSING <id>, exit 1" "$(chk "$(printf '%s\n' "$gout" | sed '/^951 /d')" | grep -c '^MISSING 951$')/$(chk "$(printf '%s\n' "$gout" | sed '/^951 /d')" >/dev/null; echo $?)" "1/1"
same "check: a done id added prints EXTRA <id>, exit 1" "$(chk "$(printf '%s\n' "$gout" | awk '{ print } $0 == "11-11 ZA:" { print "957 done ruling" }')" | grep -c '^EXTRA 957$')" "1"
same "check: a row's derived path differs from the ledger: PATH <id>" "$(chk "$(printf '%s\n' "$gout" | sed 's/^11-12 ZK:$/11-12 ZJ:/')" | grep -cE '^PATH 95[01] ')" "2"
same "check: a reading that is not a ledger prefix: READING <id>" "$(chk "$(printf '%s\n' "$gout" | sed 's/^951 a ruling of 21 bytes[.]$/951 a ruling of 21 bytes!/')" | grep -c '^READING 951$')" "1"
cp -R "$G" "$W/nofile"; rm -f "$W/nofile/specs/decisions/verbatim-decision-953-operator-11-11-ZA.txt"
same "check: a ledger path removed from disk: NOFILE <id>" "$(chk "$gout" "$W/nofile" | grep -c '^NOFILE 953 specs/decisions/verbatim-decision-953-operator-11-11-ZA.txt$')" "1"
printf '%s\n' "$gblk" > "$W/before.txt"
same "check --before: an unledgered OPERATOR line removed: LOST" "$(chk "$(printf '%s\n' "$gout" | grep -v '^OPERATOR 11-09 WG')" "$G" --before "$W/before.txt" | grep -c '^LOST OPERATOR 11-09 WG: echo')" "1"
printf '%s\n' "$gptr" '' 'OPERATOR 11-09 WG: echo, an unledgered ruling …' 'continuation line under the WG ruling' > "$W/before-unit.txt"
same "check --before: a continuation line of an unledgered ruling removed: LOST" \
    "$(chk "$(render "$(cat "$W/before-unit.txt")" "$G" | grep -v '^continuation line')" "$G" --before "$W/before-unit.txt" | grep -c '^LOST continuation line under the WG ruling')" "1"
same "check: a leading ## Current direction line is accepted" "$(chk "## Current direction
$gout" | grep -c '^check: ok ')" "1"

H="$W/h400"; mkdir -p "$H/specs/decisions"
python3 -I -c '
import json, os, sys
d = os.path.join(sys.argv[1], "specs", "decisions")
with open(os.path.join(d, "rulings-in-force.jsonl"), "w") as f:
    for k in range(400):
        n, day, sh = 1001 + k, 1 + k // 25, "A" + "ABCDE"[k // 5 % 5]
        p = "specs/decisions/verbatim-decision-%d-operator-11-%02d-%s.txt" % (n, day, sh)
        open(os.path.join(sys.argv[1], p), "w").write("x\n")
        f.write(json.dumps({"id": n, "date": "2026-11-%02d" % day, "line": "ruling %d %s" % (n, "word " * 20), "status": "in-force", "path": p}) + "\n")
' "$H"
hblk="$gptr

Context."
h12="$(CHIEF_DIRECTION_BUDGET_BYTES=12000 render "$hblk" "$H" 2>/dev/null)"
same "render: 400 in-force rulings over 80 shifts stay under 12,000 bytes, every id with a reading" \
    "$([ "$(printf '%s' "$h12" | wc -c)" -lt 12000 ] && echo under || echo over)/$(printf '%s\n' "$h12" | grep -cE '^1[0-9]{3} ruling 1[0-9]{3} \S')" "under/400"
h2="$(CHIEF_DIRECTION_BUDGET_BYTES=2000 render "$hblk" "$H" 2>"$W/h2.err")"
same "render: with a 2,000-byte budget all 400 ids keep a 16-byte reading and stderr says over budget" \
    "$(printf '%s\n' "$h2" | LC_ALL=C awk '/^1[0-9][0-9][0-9] / && length($0) - 5 >= 16' | wc -l | tr -d ' ')/$(grep -c 'over its 2000-byte budget' "$W/h2.err")" "400/1"

T="$HERE/../../../docs/handover/chief-template.md"
az="$(awk '/^1\. \*\*One batch/ { f = 1 } /^   Steps 2/ { f = 0 } f' "$T" | tr '\n' ' ' | tr -s ' ')"
cz="$(awk '$0 == "## Compact instructions" { f = 1; next } f && /^## / { exit } f' "$T" | tr '\n' ' ' | tr -s ' ')"
# shellcheck disable=SC2016
same "template: the first batch reads the companions only while a line sits outside the index" "$(grep -c 'line sits outside its `Rulings in force` index' <<< "$az")" "1"
# shellcheck disable=SC2016
same "template: the first batch reads an indexed ruling's verbatim file before acting on it" "$(grep -c 'An indexed ruling: `Read` its verbatim file before acting on it' <<< "$az")" "1"
# shellcheck disable=SC2016
same "template: compaction recovery reads the companions only while a line sits outside the index" "$(grep -c 'line sits outside the `Rulings in force` index, each direction companion file' <<< "$cz")" "1"

printf 'not json\n' >> "$L"
out="$(render "$blk")"; rc=$?
same "render: an unreadable ledger row exits 3" "$rc" "3"
same "render: an unreadable ledger row prints nothing" "$out" ""

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
