#!/usr/bin/env bash
# Test for scripts/lib/worker-state.sh and scripts/lib/worker-states.tsv.
#
# The reducer rows pass fixed inputs to ws_reduce. The CLI rows run the real CLI over fixture docs,
# a stub queue lock (WS_QUEUE_LOCK) and a scratch state directory (TICKET_STATUS_STATE_DIR).
# Every expected display, remedy and needs_chief value is read from the table at test time.
#
# Usage: bash scripts/lib/test-worker-state.sh
# Platform guard: POSIX bash 3.2+.
# shellcheck disable=SC1090,SC2030,SC2031  # the lib path is a variable; a WS_NOW export inside a subshell is the point
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/worker-state.sh"
CLI="$HERE/worker-state.sh"
TSV="$HERE/worker-states.tsv"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/worker-state-test.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/docs" "$tmp/state"
fails=0
check() {
    if [ "$2" = "$3" ]; then printf 'ok - %s\n' "$1"; else printf 'FAIL - %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi
}

cat > "$tmp/ql.sh" <<'STUB'
case "$2" in
  *lock-fresh*) echo 'status: FRESH'; exit 11 ;;
  *lock-stale-dead*) echo 'status: STALE-DEAD (age 9000s >= ttl 2700s; owner pid gone)'; exit 12 ;;
  *lock-stale*) echo 'status: STALE (age 5000s >= ttl 2700s)'; exit 12 ;;
  *lock-unver*) echo 'held -- UNVERIFIED lock: x records another path'; exit 11 ;;
  *lock-corrupt*) echo 'held -- CORRUPT lock dir (owner.json missing/unreadable): x'; exit 11 ;;
  *lock-odd*) echo 'something else'; exit 3 ;;
  *) echo free; exit 0 ;;
esac
STUB
chmod +x "$tmp/ql.sh"
export WS_QUEUE_LOCK="$tmp/ql.sh" TICKET_STATUS_STATE_DIR="$tmp/state"
unset WS_STATES_TSV WS_NOW

lib() { ( . "$LIB" >/dev/null 2>&1 || exit 99; "$@" ) 2>/dev/null; }
red() {
    ( . "$LIB" >/dev/null 2>&1 || exit 99
      ws_reduce "$@"; rc=$?
      printf '%s|%s|%s|%s|rc%s' "$WS_STATE" "$WS_TICK" "$WS_ENDED" "$WS_REASON" "$rc" ) 2>/dev/null
}
cli() { bash "$CLI" "$@" 2>/dev/null; }
jget() { printf '%s' "$1" | jq -r ".$2" 2>/dev/null; }
mkdoc() {
    local f="$tmp/docs/$1"; shift
    { printf '# doc\n\n## Results\n\n'; local b; for b in "$@"; do printf '%s\n' "$b"; done; } > "$f"
    printf '%s' "$f"
}
col() {
    local v
    v="$(awk -F'\t' -v s="$1" -v c="$2" '
        /^#/ { next }
        !hdr { hdr = 1; for (i = 1; i <= NF; i++) if ($i == c) k = i; next }
        $1 == s { print $k }' "$TSV" 2>/dev/null)"
    printf '%s' "${v:-NO-TABLE-CELL}"
}
nfiles() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
clear_records() { rm -rf "$tmp/state/worker-lifecycle"; }
sigof() { lib ws_inputs_sig "$@"; }
now() { date +%s; }

set -f
while IFS='|' read -r name es et ee args; do
    [ -n "$name" ] || continue
    # shellcheck disable=SC2086  # the args are single words, split on purpose
    set -- $args
    check "reduce: $name" "$(red "$@" | cut -d'|' -f1-3)" "$es|$et|$ee"
done <<'ROWS'
FRESH lock|FRESH|FRESH|no|1 0 FRESH LIVE 0 0 - - - -
STALE lock|STALE|STALE|no|1 0 STALE LIVE 0 0 - - - -
STALE-DEAD lock|STALE-DEAD|STALE-DEAD|no|1 0 STALE-DEAD LIVE 0 0 - - - -
IDLE-HELD on a fresh lock|IDLE-HELD|IDLE-HELD|no|1 0 FRESH LIVE 0 0 - - 1 -
IDLE-HELD on a stale lock|IDLE-HELD|IDLE-HELD|no|1 0 STALE LIVE 0 0 - - 1 -
CLOSABLE: WRAPPED with a census hit|CLOSABLE|CLOSABLE|yes|1 0 FREE WRAPPED 0 0 - - - hit
WRAPPED: free lock, WRAPPED tail, census miss|WRAPPED|WRAPPED|yes|1 0 FREE WRAPPED 0 0 - - - miss
WRAPPED with no census read stays WRAPPED|WRAPPED|WRAPPED|yes|1 0 FREE WRAPPED 0 0 - - - -
WRAPPED through a BLOCKED hand-off|WRAPPED|WRAPPED|yes|1 0 FREE BLOCKED 1 0 - - - -
BLOCKED without a hand-off is a lost lock|FREE|FREE|no|1 0 FREE BLOCKED 0 0 - - - -
a hand-off with the lock held stays FRESH|FRESH|FRESH|no|1 0 FRESH BLOCKED 1 0 - - - -
FREE: a lock gone behind a LIVE tail|FREE|FREE|no|1 0 FREE LIVE 0 0 - - - -
HALTED-SWEPT prints FREE on the tick|HALTED-SWEPT|FREE|yes|1 0 FREE HALTED 0 1 - - - -
a self-halted worker with a free lock is HALTED-SWEPT|HALTED-SWEPT|FREE|yes|1 0 FREE HALTED 0 0 - - - -
HALTED with the lock held stays FRESH|FRESH|FRESH|no|1 0 FRESH HALTED 0 0 - - - -
PARKED-USAGE prints FREE on the tick|PARKED-USAGE|FREE|no|1 0 FREE PARKED-USAGE 0 0 - - - -
the old PARKED-BANK spelling reads PARKED-USAGE|PARKED-USAGE|FREE|no|1 0 FREE PARKED-BANK 0 0 - - - -
PARKED-USAGE with the lock held keeps its lock state|FRESH|FRESH|no|1 0 FRESH PARKED-USAGE 0 0 - - - -
NOLIVE|NOLIVE|NOLIVE|no|1 0 FREE ? 0 0 0 1 - -
FORKED|FORKED|FORKED|no|1 0 FREE ? 0 0 1 - - -
FORKED beats NOLIVE|FORKED|FORKED|no|1 0 FREE ? 0 0 1 1 - -
NOLIVE and FORKED need an empty tail|FREE|FREE|no|1 0 FREE LIVE 0 0 1 1 - -
an ungathered NOLIVE or FORKED input never fires|FREE|FREE|no|1 0 FREE ? 0 0 - - - -
NOLOCK|NOLOCK|NOLOCK|no|1 1 FREE ? 0 0 - - - -
NOLOCK beats a HALTED tail|NOLOCK|NOLOCK|yes|1 1 FREE HALTED 0 1 - - - -
NOLOCK is never IDLE-HELD|NOLOCK|NOLOCK|no|1 1 FREE LIVE 0 0 - - 1 -
UNVERIFIED|UNVERIFIED|UNVERIFIED|no|1 0 UNVERIFIED LIVE 0 0 - - - -
CORRUPT|CORRUPT|CORRUPT|no|1 0 CORRUPT LIVE 0 0 - - - -
UNKNOWN|UNKNOWN|UNKNOWN|no|1 0 UNKNOWN LIVE 0 0 - - - -
NOTFOUND|NOTFOUND|NOTFOUND|no|0 0 UNKNOWN ? 0 0 - - - -
NOTFOUND beats a lockless flag|NOTFOUND|NOTFOUND|no|0 1 UNKNOWN ? 0 0 - - - -
WRAPPED tail with a held lock is never IDLE-HELD or CLOSABLE|FRESH|FRESH|yes|1 0 FRESH WRAPPED 0 0 - - 1 hit
precedence control: WRAPPED beats a sweep text|WRAPPED|WRAPPED|yes|1 0 FREE WRAPPED 0 1 - - - -
ROWS
set +f
rr="$(red 1 0 FREE HALTED 0 1 - - - -)"
case "$rr" in *swept*) check 'reduce: a sweep halt says swept in its reason' ok ok ;; *) check 'reduce: a sweep halt says swept in its reason' "$rr" 'a reason with swept' ;; esac
rr="$(red 1 0 FREE HALTED 0 0 - - - - | cut -d'|' -f4)"
case "$rr" in *swept*) check 'reduce: a self-halt does not say swept' "$rr" 'no swept' ;; *) check 'reduce: a self-halt does not say swept' "${rr:+reason}" reason ;; esac

check 'reduce: a bad lock class is rc 2 and reads UNKNOWN' \
    "$( ( . "$LIB" >/dev/null 2>&1 || exit 99; ws_reduce 1 0 FRESH LIVE 0 0 - - - -; ws_reduce 1 0 BOGUS LIVE 0 0 - - - -; rc=$?; printf '%s|%s|%s' "$rc" "$WS_STATE" "$WS_TICK" ) 2>/dev/null )" '2|UNKNOWN|UNKNOWN'
check 'reduce: a bad flag value is rc 2' "$(red 1 7 FRESH LIVE 0 0 - - - - | cut -d'|' -f5)" rc2
check 'reduce: a wrong argument count is rc 2' "$(red 1 0 FRESH | cut -d'|' -f5)" rc2
check 'reduce: a bad census value is rc 2' "$(red 1 0 FRESH LIVE 0 0 - - - maybe | cut -d'|' -f5)" rc2

check 'lock class: FRESH' "$(lib ws_lock_class 'status: FRESH')" FRESH
check 'lock class: STALE' "$(lib ws_lock_class 'status: STALE (age 5000s >= ttl 2700s)')" STALE
check 'lock class: STALE-DEAD is matched before STALE' "$(lib ws_lock_class 'status: STALE-DEAD (age 9000s >= ttl 2700s; owner pid gone)')" STALE-DEAD
check 'lock class: UNVERIFIED' "$(lib ws_lock_class 'held -- UNVERIFIED lock: x')" UNVERIFIED
check 'lock class: free' "$(lib ws_lock_class 'free')" FREE
check 'lock class: CORRUPT' "$(lib ws_lock_class 'held -- CORRUPT lock dir (owner.json missing/unreadable): x')" CORRUPT
check 'lock class: anything else is UNKNOWN' "$(lib ws_lock_class 'something else')" UNKNOWN
check 'lock class: empty text is UNKNOWN' "$(lib ws_lock_class '')" UNKNOWN

s0="$(sigof FRESH LIVE 0 0)"
check 'sig: the same inputs give the same signature' "$(sigof FRESH LIVE 0 0)" "${s0:-no-sig-yet}"
check 'sig: a signature is a 40-hex digest' "$(printf '%s' "$s0" | grep -cE '^[0-9a-f]{40}$')" 1
check 'sig: the lock class moves it' "$([ "$(sigof STALE LIVE 0 0)" != "$s0" ] && echo moved)" moved
check 'sig: the tail moves it' "$([ "$(sigof FRESH FINDING 0 0)" != "$s0" ] && echo moved)" moved
check 'sig: handoff moves it' "$([ "$(sigof FRESH LIVE 1 0)" != "$s0" ] && echo moved)" moved
check 'sig: halt_swept moves it' "$([ "$(sigof FRESH LIVE 0 1)" != "$s0" ] && echo moved)" moved

check 'table: the shipped table declares 16 rows' "$(grep -c '^# rows: 16$' "$TSV")" 1
check 'table: the shipped table holds 16 state rows' "$(awk -F'\t' '/^#/ { next } !h { h = 1; next } NF { n++ } END { print n }' "$TSV")" 16
check 'table: every row has six columns' "$(awk -F'\t' '/^#/ { next } NF != 6 { bad++ } END { print bad + 0 }' "$TSV")" 0
doc_ok="$(mkdoc free-ok.md '- 10:00 LIVE — x')"
check 'loader: the shipped table loads' "$(cli --json "$doc_ok" >/dev/null; echo $?)" 0
sed 's/^# rows: 16$/# rows: 15/' "$TSV" > "$tmp/bad-count.tsv"
check 'loader: a wrong # rows exits 3' "$(WS_STATES_TSV="$tmp/bad-count.tsv" cli --json "$doc_ok" >/dev/null; echo $?)" 3
check 'loader: a wrong # rows prints nothing and exits 3' "$(out="$(WS_STATES_TSV="$tmp/bad-count.tsv" cli --json "$doc_ok")"; rc=$?; printf 'rc%s:%s' "$rc" "$out")" 'rc3:'
awk -F'\t' 'BEGIN { OFS = "\t" } /^#/ { print; next } $1 == "FRESH" { print $1, $2, $3, $4, $5; next } { print }' "$TSV" > "$tmp/bad-cols.tsv"
check 'loader: a row with five columns exits 3' "$(WS_STATES_TSV="$tmp/bad-cols.tsv" cli --json "$doc_ok" >/dev/null; echo $?)" 3
grep -v '^FRESH	' "$TSV" > "$tmp/missing-row.tsv"
check 'loader: a missing row against # rows exits 3' "$(WS_STATES_TSV="$tmp/missing-row.tsv" cli --json "$doc_ok" >/dev/null; echo $?)" 3
sed 's/^NOLIVE	/NOLIVEX	/' "$TSV" > "$tmp/renamed-state.tsv"
check 'loader: a table without a state the reducer can emit exits 3' "$(WS_STATES_TSV="$tmp/renamed-state.tsv" cli --json "$doc_ok" >/dev/null; echo $?)" 3
{ sed 's/^# rows: 16$/# rows: 17/' "$TSV"; grep '^FRESH	' "$TSV"; } > "$tmp/dup-state.tsv"
check 'loader: a duplicate state exits 3' "$(WS_STATES_TSV="$tmp/dup-state.tsv" cli --json "$doc_ok" >/dev/null; echo $?)" 3
check 'loader: a missing table exits 3' "$(WS_STATES_TSV="$tmp/none.tsv" cli --json "$doc_ok" >/dev/null; echo $?)" 3
check 'loader: a changed table is the one the CLI reads' \
    "$(sed 's/^FRESH\(	[a-z]*	[a-z]*	FRESH	\)working/FRESH\1doing the work/' "$TSV" > "$tmp/changed.tsv"; jget "$(WS_STATES_TSV="$tmp/changed.tsv" cli --json "$(mkdoc lock-fresh-changed.md '- 10:00 LIVE — x')")" display)" 'doing the work'
check 'cli: no --json is a usage error' "$(cli "$doc_ok" >/dev/null; echo $?)" 2
check 'cli: an unknown flag is a usage error' "$(cli --json --bogus "$doc_ok" >/dev/null; echo $?)" 2

swept="$(mkdoc free-swept.md '- 10:00 LIVE — working' '- 10:30 HALTED — its queue lock (session=s1) was freed by reap with the holder provably dead and no wrap marker written')"
o="$(cli --json "$swept")"
check 'R2: a swept HALTED doc with a free lock reads HALTED-SWEPT' "$(jget "$o" state)" HALTED-SWEPT
check 'R2: ... the tick label is FREE' "$(jget "$o" tick)" FREE
check 'R2: ... it is ended' "$(jget "$o" ended)" yes
check 'R2: ... the reason says swept' "$(jget "$o" reason | grep -c swept)" 1
check 'R2: ... needs_chief is the table row' "$(jget "$o" needs_chief)" "$(col HALTED-SWEPT needs_chief)"
check 'R2: ... display is the table row' "$(jget "$o" display)" "$(col HALTED-SWEPT display)"
rem="$(col HALTED-SWEPT remedy)"
check 'R2: ... remedy is the table row, <doc> filled with the realpath' "$(jget "$o" remedy)" "${rem//<doc>/$swept}"
held="$(mkdoc lock-fresh-swept.md '- 10:00 LIVE — working' '- 10:30 HALTED — its queue lock (session=s1) was freed by reap with the holder provably dead and no wrap marker written')"
o="$(cli --json "$held")"
check 'R2 control: the same doc with a held lock reads FRESH' "$(jget "$o" state)" FRESH
check 'R2 control: ... and is not ended' "$(jget "$o" ended)" no
wrapped="$(mkdoc free-wrapped.md '- 10:00 LIVE — working' '- 10:30 WRAPPED — done')"
check 'precedence control: a WRAPPED doc with a free lock reads WRAPPED' "$(jget "$(cli --json "$wrapped")" state)" WRAPPED
selfh="$(mkdoc free-selfhalt.md '- 10:00 LIVE — working' '- 10:30 HALTED — stopped by the chief')"
o="$(cli --json "$selfh")"
check 'cli: a self-halted doc with a free lock reads HALTED-SWEPT' "$(jget "$o" state)" HALTED-SWEPT
check 'cli: ... and its reason does not say swept' "$(r="$(jget "$o" reason)"; case "$r" in '') echo none ;; *swept*) echo swept ;; *) echo other ;; esac)" other

for cls in stale-dead stale unver corrupt odd; do
    case "$cls" in stale-dead) want=STALE-DEAD ;; stale) want=STALE ;; unver) want=UNVERIFIED ;; corrupt) want=CORRUPT ;; odd) want=UNKNOWN ;; esac
    check "cli: a $cls lock reads $want" "$(jget "$(cli --json "$(mkdoc "lock-$cls-x.md" '- 10:00 LIVE — x')")" state)" "$want"
done
o="$(cli --json "$tmp/docs/nope.md")"
check 'cli: a missing doc reads NOTFOUND' "$(jget "$o" state)" NOTFOUND
check 'cli: ... needs_chief is the NOTFOUND row' "$(jget "$o" needs_chief)" "$(col NOTFOUND needs_chief)"
check 'cli: a never-LIVE doc with a free lock reads FREE on the cheap state' "$(jget "$(cli --json "$(mkdoc free-empty.md)")" state)" FREE

tab="$(printf '\t')"
check 'gather: a free doc with a WRAPPED tail' "$(lib ws_gather "$wrapped" | tr "$tab" ' ')" '1 0 FREE WRAPPED 0 0 - - - -'
check 'gather: a swept HALTED doc sets halt_swept' "$(lib ws_gather "$swept" | tr "$tab" ' ')" '1 0 FREE HALTED 0 1 - - - -'
check 'gather: a self-halt leaves halt_swept 0' "$(lib ws_gather "$selfh" | tr "$tab" ' ')" '1 0 FREE HALTED 0 0 - - - -'
check 'gather: a doc with no marker has the tail ?' "$(lib ws_gather "$tmp/docs/free-empty.md" | tr "$tab" ' ')" '1 0 FREE ? 0 0 - - - -'
check 'gather: a missing doc' "$(lib ws_gather "$tmp/docs/nope.md" | tr "$tab" ' ')" '0 0 UNKNOWN ? 0 0 - - - -'
check 'gather: a NOLOCK label takes no lock reading' "$(lib ws_gather "$tmp/docs/lock-fresh-swept.md" NOLOCK | tr "$tab" ' ')" '1 1 FREE HALTED 0 1 - - - -'
succ="$tmp/docs/HIMMEL-9001-N660b-handoff-2026-11-04-RESUME.md"
printf '%s\n' '# successor' '' '## Results' '' '- 13:05 LIVE — resumed' > "$succ"
ho="$tmp/docs/HIMMEL-9001-N660-handoff-2026-11-04.md"
printf '%s\n' '# worker' '' '## Results' '' '- 12:00 LIVE — working' "- 13:00 BLOCKED — context 80 %, RESUME written: $succ" > "$ho"
check 'gather: a BLOCKED hand-off naming its successor sets handoff' "$(lib ws_gather "$ho" | tr "$tab" ' ')" '1 0 FREE BLOCKED 1 0 - - - -'
check 'cli: a BLOCKED hand-off with a free lock reads WRAPPED' "$(jget "$(cli --json "$ho")" state)" WRAPPED

clear_records
check 'record: a missing doc is refused and nothing is written for it' "$(lib ws_record_put "$tmp/docs/nope.md" NOLIVE r "$s0" 0 >/dev/null; rc=$?; echo "rc$rc/$(nfiles "$tmp/state/worker-lifecycle")")" rc1/0
nolive="$(mkdoc free-nolive.md)"
check 'record: put succeeds for a real doc' "$(lib ws_record_put "$nolive" NOLIVE 'never live' "$(sigof FREE '?' 0 0)" 0 >/dev/null; echo $?)" 0
rp="$(lib ws_record_path "$nolive")"
check 'record: the file sits under worker-lifecycle in the state dir' "$([ "$rp" = "$tmp/state/worker-lifecycle/$(basename "$rp")" ] && [ -f "$rp" ] && echo yes)" yes
check 'record: it carries doc, state, reason, inputs_sig, seen and lockless' \
    "$(jq -r '[.doc, .state, .reason, .inputs_sig, (.seen | type), (.lockless | tostring)] | join("|")' "$rp")" \
    "$nolive|NOLIVE|never live|$(sigof FREE '?' 0 0)|number|false"
check 'record: a lockless put stores lockless true' "$(lib ws_record_put "$nolive" NOLOCK r "$(sigof FREE '?' 0 0)" 1 >/dev/null; jq -r '.lockless | tostring' "$rp")" true
mkdir -p "$tmp/real" && ln -sfn "$tmp/real" "$tmp/link"
printf '# doc\n' > "$tmp/real/via-link.md"
clear_records
lib ws_record_put "$tmp/link/via-link.md" NOLIVE r "$s0" 0 >/dev/null
lib ws_record_put "$tmp/real/via-link.md" NOLIVE r "$s0" 0 >/dev/null
check 'record: a symlinked path and its real path share one file' "$(nfiles "$tmp/state/worker-lifecycle")" 1
clear_records
old="$(mkdoc free-old.md)"; new="$(mkdoc free-new.md)"
( export WS_NOW=$(( $(now) - 400 )); . "$LIB" >/dev/null 2>&1 && ws_record_put "$old" NOLIVE r "$s0" 0 ) >/dev/null 2>&1
lib ws_record_put "$new" NOLIVE r "$s0" 0 >/dev/null
check 'prune: both records exist before the prune' "$([ -e "$(lib ws_record_path "$old")" ] && [ -e "$(lib ws_record_path "$new")" ] && echo yes)" yes
check 'prune: a record past the bound is deleted, a fresh one is kept' "$(lib ws_record_prune >/dev/null; rc=$?; [ ! -e "$(lib ws_record_path "$old")" ] && [ -e "$(lib ws_record_path "$new")" ] && echo "rc$rc")" rc0

clear_records
d="$(mkdoc free-refine.md)"
sig_free_q="$(sigof FREE '?' 0 0)"
lib ws_record_put "$d" NOLIVE 'never live' "$sig_free_q" 0 >/dev/null
o="$(cli --json "$d")"
check 'refine: a fresh record with the live signature gives NOLIVE' "$(jget "$o" state)" NOLIVE
check 'refine: ... the source is record' "$(jget "$o" source)" record
check 'refine: ... the tick label is NOLIVE' "$(jget "$o" tick)" NOLIVE
check 'refine: ... needs_chief is the NOLIVE row' "$(jget "$o" needs_chief)" "$(col NOLIVE needs_chief)"
clear_records
lib ws_record_put "$d" NOLIVE 'never live' "$(sigof FREE LIVE 0 0)" 0 >/dev/null
o="$(cli --json "$d")"
check 'signature mismatch: a fresh record with a different signature reads live' "$(jget "$o" source)" live
check 'signature mismatch: ... the state is the cheap FREE' "$(jget "$o" state)" FREE
clear_records
( export WS_NOW=$(( $(now) - 361 )); . "$LIB" >/dev/null 2>&1 && ws_record_put "$d" NOLIVE 'never live' "$sig_free_q" 0 ) >/dev/null 2>&1
check 'stale record: a record 361 s old reads live' "$(jget "$(cli --json "$d")" source)" live
clear_records
( export WS_NOW=$(( $(now) - 30 )); . "$LIB" >/dev/null 2>&1 && ws_record_put "$d" NOLIVE 'never live' "$sig_free_q" 0 ) >/dev/null 2>&1
check 'stale record control: a record 30 s old is used' "$(jget "$(cli --json "$d")" source)" record
clear_records
o="$(printf '%s\t%s\n' "$d" NOLIVE | cli --json --stdin)"
check 'label: a NOLIVE label on a free doc is used' "$(jget "$o" state)/$(jget "$o" source)" NOLIVE/label
o="$(printf '%s\t%s\n' "$d" FRESH | cli --json --stdin)"
check 'contradicting label: FRESH on a free doc reads live FREE' "$(jget "$o" state)/$(jget "$o" source)" FREE/live
fr="$(mkdoc lock-fresh-live.md '- 10:00 LIVE — working')"
o="$(printf '%s\t%s\n' "$fr" NOLIVE | cli --json --stdin)"
check 'contradicting label: NOLIVE on a held lock reads live FRESH' "$(jget "$o" state)/$(jget "$o" source)" FRESH/live
o="$(printf '%s\t%s\n' "$fr" MISSING | cli --json --stdin)"
check 'label without a row: MISSING never overrides the live state' "$(jget "$o" state)/$(jget "$o" source)" FRESH/live
o="$(printf '%s\t\n' "$fr" | cli --json --stdin)"
check 'stdin: an empty label reads live' "$(jget "$o" source)" live
o="$(printf '%s\t%s\n' "$wrapped" CLOSABLE | cli --json --stdin)"
check 'label: CLOSABLE refines a WRAPPED doc' "$(jget "$o" state)/$(jget "$o" source)" CLOSABLE/label
rem="$(col CLOSABLE remedy)"
check 'fill: <doc> in a remedy is the realpath' "$(jget "$o" remedy)" "${rem//<doc>/$wrapped}"
cl="$(printf '%s\t%s\n' "$tmp/link/via-link.md" CLOSABLE | cli --json --stdin)"
check 'fill: a doc given through a symlink reports its realpath' "$(jget "$cl" doc)" "$tmp/real/via-link.md"
fh="$(mkdoc free-held-check.md '- 10:00 WRAPPED — done')"
check 'fill: the filled remedy has no <doc> left' "$(r="$(printf '%s\t%s\n' "$fh" CLOSABLE | cli --json --stdin | jq -r '.remedy')"; case "$r" in '') echo none ;; *'<doc>'*) echo literal ;; *) echo filled ;; esac)" filled

o="$(printf '%s\t%s\n%s\t%s\n' "$d" NOLIVE "$fr" FRESH | cli --json --stdin)"
l1="$(printf '%s\n' "$o" | sed -n 1p)"; l2="$(printf '%s\n' "$o" | sed -n 2p)"
check 'stdin: line one pairs its doc with its label' "$(jget "$l1" doc)/$(jget "$l1" state)/$(jget "$l1" source)" "$d/NOLIVE/label"
check 'stdin: line two pairs its doc with its label' "$(jget "$l2" doc)/$(jget "$l2" state)/$(jget "$l2" source)" "$fr/FRESH/label"
o="$(printf '%s\t%s\n' "$d" NOLIVE | cli --json --stdin "$fr")"
check 'stdin: doc arguments are read besides the piped pairs' "$(printf '%s\n' "$o" | wc -l | tr -d ' ')" 2

clear_records
nl="$(mkdoc free-nolock.md '- 10:00 LIVE — working')"
o="$(printf '%s\t%s\n' "$nl" NOLOCK | cli --json --stdin)"
check 'NOLOCK: the label NOLOCK on a free lock reads NOLOCK' "$(jget "$o" state)" NOLOCK
check 'NOLOCK: ... needs_chief is the NOLOCK row (no)' "$(jget "$o" needs_chief)" "$(col NOLOCK needs_chief)"
lib ws_record_put "$nl" NOLOCK 'lockless row' "$(sigof FREE LIVE 0 0)" 1 >/dev/null
o="$(cli --json "$nl")"
check 'NOLOCK record: no label, a fresh NOLOCK record reads NOLOCK from the record' "$(jget "$o" state)/$(jget "$o" source)" NOLOCK/record
check 'NOLOCK record: ... needs_chief is no' "$(jget "$o" needs_chief)" "$(col NOLOCK needs_chief)"
printf -- '- 10:40 FINDING — a question\n' >> "$nl"
o="$(cli --json "$nl")"
check 'moved tail: a lockless record signed at LIVE still reads NOLOCK after the tail moves' "$(jget "$o" state)" NOLOCK
check 'moved tail: ... needs_chief stays no' "$(jget "$o" needs_chief)" "$(col NOLOCK needs_chief)"
clear_records
lh="$(mkdoc free-lockless-halted.md '- 10:00 LIVE — working' '- 10:30 HALTED — stopped')"
a="$(printf '%s\t%s\n' "$lh" NOLOCK | cli --json --stdin)"
lib ws_record_put "$lh" NOLOCK 'lockless row' "$(sigof FREE HALTED 0 0)" 1 >/dev/null
b="$(cli --json "$lh")"
check 'lockless HALTED agreement: the label and the unlabelled record both read NOLOCK' "$(jget "$a" state)/$(jget "$b" state)" NOLOCK/NOLOCK

o="$(cli --json "$d" "$fr")"
check 'cli: one JSON object per doc, in argument order' "$(printf '%s\n' "$o" | jq -r '.doc' | tr '\n' ' ')" "$d $fr "
check 'cli: every object carries the same eleven keys' "$(printf '%s\n' "$o" | jq -c 'keys | join(",")' | sort -u)" '"age,display,doc,ended,holds_lock,needs_chief,reason,remedy,source,state,tick"'

if [ "$fails" -eq 0 ]; then
    echo "all rows passed"
    exit 0
fi
echo "$fails row(s) failed"
exit 1
