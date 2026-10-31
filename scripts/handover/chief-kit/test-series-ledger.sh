#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-append-results.sh
# scripts/handover/chief-kit/test-series-ledger.sh - suite for series-ledger.py,
# the one writer of a stacked series' ledger <sid>.json (design section 5.2, invariant I3):
#   1. create + read           -> the 5.2 fields, writer = the creating doc, no items; a second create refuses
#   2. add-item                -> planned row; a duplicate key, an unknown state and an unknown field refuse
#   3. set                     -> item and top-level fields; unknown field, bad state, `writer`, `passes`
#                                 and `items` refuse, and a refusal leaves the file byte-identical
#   4. pass                    -> only the writer can pass; it moves `writer` and appends {from,to,at};
#                                 every other verb leaves `writer` unchanged
#   5. F11 concurrent writers  -> N parallel add-items all land, the JSON is valid, no temp file is left
#   6. lock timeout            -> exit 3 while another process holds the lock; the ledger is untouched
#   7. read errors             -> a missing or corrupt ledger is exit 1; `read` takes no lock
# SERIES_LEDGER overrides the script under test (the RED control). Hermetic: temp dir only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SERIES_LEDGER:-$HERE/series-ledger.py}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/series-ledger-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]: [$2]"; fails=$((fails+1)) ;; esac; }
sl()  { python3 -I "$SCRIPT" "$@"; }
# jq-free JSON probe: jget <file> <python expression over d>
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

L="$tmp/s1.json"

# --- 1. create + read ----------------------------------------------------
rc=0; out="$(sl create --ledger "$L" --sid s1 --completes-ticket no --writer /docs/a.md --grant 'scripts/ui (operator decision 388)' 2>&1)" || rc=$?
check "1: create rc 0" "$rc" 0
check "1: sid" "$(jget "$L" 'd["sid"]')" s1
check "1: completes_ticket" "$(jget "$L" 'd["completes_ticket"]')" no
check "1: writer is the creating doc" "$(jget "$L" 'd["writer"]')" /docs/a.md
check "1: grant" "$(jget "$L" 'd["grant"]')" 'scripts/ui (operator decision 388)'
check "1: no passes" "$(jget "$L" 'd["passes"]')" '[]'
check "1: no items" "$(jget "$L" 'd["items"]')" '[]'
check "1: file ends in a newline" "$(tail -c1 "$L" | od -An -c | tr -d ' ')" '\n'
rc=0; out="$(sl read --ledger "$L" 2>&1)" || rc=$?
check "1: read rc 0" "$rc" 0
contains "1: read prints the writer" "$out" '"writer": "/docs/a.md"'
before="$(cat "$L")"
rc=0; out="$(sl create --ledger "$L" --sid s1 --completes-ticket yes --writer /docs/b.md 2>&1)" || rc=$?
check "1: second create refuses rc 4" "$rc" 4
check "1: second create leaves the file" "$(cat "$L")" "$before"
rc=0; out="$(sl create --ledger "$tmp/bad.json" --sid s2 --completes-ticket maybe --writer /docs/a.md 2>&1)" || rc=$?
check "1: bad completes-ticket refuses rc 2" "$rc" 2
check "1: bad create writes nothing" "$([ -e "$tmp/bad.json" ] && echo yes || echo no)" no

# --- 2. add-item ---------------------------------------------------------
rc=0; sl add-item --ledger "$L" --key HIMMEL-1 --branch series/s1/HIMMEL-1 --writes a.js,b.js >/dev/null 2>&1 || rc=$?
check "2: add-item rc 0" "$rc" 0
check "2: item state defaults to planned" "$(jget "$L" 'd["items"][0]["state"]')" planned
check "2: item writes is a list" "$(jget "$L" 'd["items"][0]["writes"]')" "['a.js', 'b.js']"
check "2: item branch" "$(jget "$L" 'd["items"][0]["branch"]')" series/s1/HIMMEL-1
before="$(cat "$L")"
rc=0; out="$(sl add-item --ledger "$L" --key HIMMEL-1 2>&1)" || rc=$?
check "2: duplicate key refuses rc 4" "$rc" 4
rc=0; out="$(sl add-item --ledger "$L" --key HIMMEL-2 --state bogus 2>&1)" || rc=$?
check "2: unknown state refuses rc 2" "$rc" 2
contains "2: unknown state is named" "$out" bogus
rc=0; out="$(sl add-item --ledger "$L" --key HIMMEL-2 --colour red 2>&1)" || rc=$?
check "2: unknown option refuses rc 2" "$rc" 2
check "2: refusals leave the file byte-identical" "$(cat "$L")" "$before"
for st in authoring committed published abandoned; do
    rc=0; sl add-item --ledger "$L" --key "K-$st" --state "$st" >/dev/null 2>&1 || rc=$?
    check "2: state $st accepted" "$rc" 0
done

# --- 3. set --------------------------------------------------------------
rc=0; sl set --ledger "$L" --key HIMMEL-1 state=authoring worktree=/wt/1 wip=abc123 writes=x.js,y.js >/dev/null 2>&1 || rc=$?
check "3: set item rc 0" "$rc" 0
check "3: set item state" "$(jget "$L" 'd["items"][0]["state"]')" authoring
check "3: set item worktree" "$(jget "$L" 'd["items"][0]["worktree"]')" /wt/1
check "3: set item wip" "$(jget "$L" 'd["items"][0]["wip"]')" abc123
check "3: set item writes" "$(jget "$L" 'd["items"][0]["writes"]')" "['x.js', 'y.js']"
rc=0; sl set --ledger "$L" completes_ticket=yes >/dev/null 2>&1 || rc=$?
check "3: set top-level rc 0" "$rc" 0
check "3: set top-level completes_ticket" "$(jget "$L" 'd["completes_ticket"]')" yes
before="$(cat "$L")"
rc=0; out="$(sl set --ledger "$L" --key HIMMEL-1 colour=red 2>&1)" || rc=$?
check "3: unknown item field refuses rc 2" "$rc" 2
contains "3: unknown field is named" "$out" colour
rc=0; sl set --ledger "$L" --key HIMMEL-1 state=bogus >/dev/null 2>&1 || rc=$?
check "3: unknown state refuses rc 2" "$rc" 2
rc=0; sl set --ledger "$L" colour=red >/dev/null 2>&1 || rc=$?
check "3: unknown top-level field refuses rc 2" "$rc" 2
rc=0; sl set --ledger "$L" writer=/docs/evil.md >/dev/null 2>&1 || rc=$?
check "3: set writer refuses (only pass moves it) rc 2" "$rc" 2
rc=0; sl set --ledger "$L" passes=x >/dev/null 2>&1 || rc=$?
check "3: set passes refuses rc 2" "$rc" 2
rc=0; sl set --ledger "$L" --key HIMMEL-1 key=OTHER >/dev/null 2>&1 || rc=$?
check "3: set item key refuses rc 2" "$rc" 2
rc=0; sl set --ledger "$L" completes_ticket=maybe >/dev/null 2>&1 || rc=$?
check "3: bad completes_ticket refuses rc 2" "$rc" 2
rc=0; sl set --ledger "$L" --key NOPE state=authoring >/dev/null 2>&1 || rc=$?
check "3: unknown item key refuses rc 4" "$rc" 4
check "3: refusals leave the file byte-identical" "$(cat "$L")" "$before"

# --- 4. pass -------------------------------------------------------------
check "4: writer before pass" "$(jget "$L" 'd["writer"]')" /docs/a.md
rc=0; out="$(sl pass --ledger "$L" --from /docs/not-the-writer.md --to /docs/b.md 2>&1)" || rc=$?
check "4: pass from a non-writer refuses rc 4" "$rc" 4
contains "4: refusal names the writer" "$out" /docs/a.md
check "4: writer unchanged after refusal" "$(jget "$L" 'd["writer"]')" /docs/a.md
rc=0; sl pass --ledger "$L" --from /docs/a.md --to /docs/b.md >/dev/null 2>&1 || rc=$?
check "4: pass from the writer rc 0" "$rc" 0
check "4: writer moved" "$(jget "$L" 'd["writer"]')" /docs/b.md
check "4: one pass row" "$(jget "$L" 'len(d["passes"])')" 1
check "4: pass row from" "$(jget "$L" 'd["passes"][0]["from"]')" /docs/a.md
check "4: pass row to" "$(jget "$L" 'd["passes"][0]["to"]')" /docs/b.md
case "$(jget "$L" 'd["passes"][0]["at"]')" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z) echo "ok - 4: pass row at is a UTC timestamp" ;;
    *) echo "FAIL - 4: pass row at is not a UTC timestamp"; fails=$((fails+1)) ;;
esac
sl set --ledger "$L" --key HIMMEL-1 state=committed >/dev/null 2>&1
sl add-item --ledger "$L" --key HIMMEL-9 >/dev/null 2>&1
check "4: set and add-item leave writer unchanged" "$(jget "$L" 'd["writer"]')" /docs/b.md
rc=0; sl pass --ledger "$L" --from /docs/a.md --to /docs/c.md >/dev/null 2>&1 || rc=$?
check "4: the old writer can no longer pass rc 4" "$rc" 4

# --- 5. F11: concurrent writers lose no update ---------------------------
C="$tmp/conc.json"
sl create --ledger "$C" --sid conc --completes-ticket no --writer /docs/a.md >/dev/null 2>&1
n=12
i=0
while [ "$i" -lt "$n" ]; do
    sl add-item --ledger "$C" --key "K-$i" --writes "f$i.js" >/dev/null 2>&1 &
    i=$((i+1))
done
wait
check "5: F11 the ledger is valid JSON" "$(python3 -I -c 'import json,sys; json.load(open(sys.argv[1])); print("valid")' "$C" 2>&1)" valid
check "5: F11 every concurrent add-item landed" "$(jget "$C" 'len(d["items"])')" "$n"
check "5: F11 every key is distinct" "$(jget "$C" 'len({x["key"] for x in d["items"]})')" "$n"
leftover=0
for f in "$tmp"/conc.json.*; do
    [ -e "$f" ] && [ "$f" != "$tmp/conc.json.lock" ] && leftover=$((leftover+1))
done
check "5: F11 no temp file is left behind" "$leftover" 0
# two writers of different verbs at once: an add-item and a set must both apply
D="$tmp/mix.json"
sl create --ledger "$D" --sid mix --completes-ticket no --writer /docs/a.md >/dev/null 2>&1
sl add-item --ledger "$D" --key M-0 >/dev/null 2>&1
i=0
while [ "$i" -lt 6 ]; do
    sl add-item --ledger "$D" --key "M-$((i+1))" >/dev/null 2>&1 &
    sl set --ledger "$D" --key M-0 "branch=b$i" >/dev/null 2>&1 &
    i=$((i+1))
done
wait
check "5: F11 mixed verbs keep every add-item" "$(jget "$D" 'len(d["items"])')" 7
contains "5: F11 mixed verbs applied a set" "$(jget "$D" 'd["items"][0]["branch"]')" b

# --- 6. lock timeout -----------------------------------------------------
T="$tmp/lock.json"
sl create --ledger "$T" --sid lock --completes-ticket no --writer /docs/a.md >/dev/null 2>&1
before="$(cat "$T")"
ready="$tmp/holder.ready"
python3 -I -c '
import fcntl, sys, time
f = open(sys.argv[1] + ".lock", "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(8)
' "$T" "$ready" &
holder=$!
w=0; while [ ! -e "$ready" ] && [ "$w" -lt 100 ]; do sleep 0.1; w=$((w+1)); done
rc=0; out="$(SERIES_LEDGER_LOCK_TIMEOUT=1 sl add-item --ledger "$T" --key LK-1 2>&1)" || rc=$?
check "6: a held lock times out rc 3" "$rc" 3
contains "6: the timeout is named" "$out" lock
check "6: the ledger is untouched by the timeout" "$(cat "$T")" "$before"
rc=0; sl read --ledger "$T" >/dev/null 2>&1 || rc=$?
check "6: read takes no lock and works while it is held" "$rc" 0
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
rc=0; sl add-item --ledger "$T" --key LK-1 >/dev/null 2>&1 || rc=$?
check "6: add-item works once the lock is released" "$rc" 0

# --- 7. read errors ------------------------------------------------------
rc=0; out="$(sl read --ledger "$tmp/missing.json" 2>&1)" || rc=$?
check "7: read of a missing ledger rc 1" "$rc" 1
printf '{not json' > "$tmp/corrupt.json"
rc=0; out="$(sl read --ledger "$tmp/corrupt.json" 2>&1)" || rc=$?
check "7: read of a corrupt ledger rc 1" "$rc" 1
rc=0; out="$(sl add-item --ledger "$tmp/corrupt.json" --key X-1 2>&1)" || rc=$?
check "7: a write to a corrupt ledger rc 1" "$rc" 1
check "7: a corrupt ledger is left as it was" "$(cat "$tmp/corrupt.json")" '{not json'
rc=0; out="$(sl bogus-verb --ledger "$L" 2>&1)" || rc=$?
check "7: unknown verb rc 2" "$rc" 2

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; exit 0; fi
echo "$fails failed"
exit 1
