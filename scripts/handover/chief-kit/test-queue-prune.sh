#!/usr/bin/env bash
# test-queue-prune.sh — Exercises queue-prune.sh on fixture chief docs, a fixture Jira mirror and a fixture
# `gh pr list --state all` file (ORPHAN_PR_CHECK_PRS_ALL): the real orphan-pr-check.sh runs, no gh call is made,
# and no live chief doc or history dir is touched. QUEUE_PRUNE overrides the script under test (the RED control:
# a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-queue-prune.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
QP="${QUEUE_PRUNE:-$HERE/queue-prune.sh}"
OPC="$HERE/orphan-pr-check.sh"

fails=0
check() {
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/queue-prune-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/emptyroot" "$WORK/mirror" "$WORK/scratch"
: > "$WORK/emptyroot/.env"
export GH_READ_ENV_ROOT="$WORK/emptyroot" HIMMEL_SECRETS_KEYRING=off TICKET_STATUS_STATE_DIR="$WORK/state"
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY QUEUE_PRUNE_PRE_APPLY_HOOK
export NEXT_DISPATCH_MIRROR="$WORK/mirror"
mkey() {
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "x"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: []\n---\n\n# HIMMEL-%s: t\n' "$1" "$2" "$1" > "$WORK/mirror/HIMMEL-$1.md"
}
mkey 901 Done; mkey 902 "To Do"; mkey 903 "In Progress"
PRSALL="$WORK/prs-all.json"
printf '[{"number":4401,"state":"MERGED"},{"number":4402,"state":"OPEN"},{"number":4410,"state":"MERGED"},{"number":4411,"state":"MERGED"},{"number":4412,"state":"OPEN"},{"number":4420,"state":"CLOSED"}]\n' > "$PRSALL"
export ORPHAN_PR_CHECK_PRS_ALL="$PRSALL"

LIVEQ='#4402 HELD by F2'
DEADQ='#4401 HELD by F1 (judge owed) '
DEADP='pool-disposition: HIMMEL-901 hold HIMMEL-900'
LIVEP='pool-disposition: HIMMEL-902 hold PR 4410'
FIX="$WORK/fix"
DOC="$FIX/HIMMEL-nextleg-2026-11-01A-chief.md"
STEM="HIMMEL-nextleg-2026-11-01A-chief"
HIST="$FIX/specs/history/chief-live-state-$STEM.md"
mkdoc() {
    local q="$1" l; shift
    rm -rf "$FIX"; mkdir -p "$FIX"
    {
        # shellcheck disable=SC2016  # the backticks are literal markdown
        printf '# chief\n\n## Live state\n\nlegs: `N1:n:t:1`\nqueue: %s\n' "$q"
        for l in "$@"; do printf '%s\n' "$l"; done
        printf 'last GO: none\n\n## Results\n- 08:00 LIVE — one\n'
    } > "$DOC"
}
run() {
    out="$(bash "$QP" --doc "$DOC" "$@" 2>"$WORK/err")"; rc=$?
    err="$(cat "$WORK/err")"
}
qline() { sed -n 's/^queue: //p' "$DOC"; }
tree() { find "$FIX" "$WORK/mirror" "$WORK/scratch" -type f -exec sha256sum {} + 2>/dev/null | sort; }

mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
run --apply
check "10777 P1 --apply exits 0 and prints the counts line with the history path" "0:queue-prune: dead-queue=1 done-pool=1:HIMMEL-901 history=$HIST" "$rc:$err"
check "10777 P1 --apply keeps the live segment and the tail" "$LIVEQ || tail text" "$(qline)"
check "10777 P1 --apply drops the Done pool line and keeps the live one" "0:1" "$(grep -cxF "$DEADP" "$DOC"):$(grep -cxF "$LIVEP" "$DOC")"
check "10777 P1 the history file holds the header, the dead segment and the pool line, byte for byte" "1:1:1" \
    "$(grep -c "^# Live state pruned by queue-prune.sh from $STEM at [0-9T:Z-]*\$" "$HIST"):$(grep -cxF "$DEADQ" "$HIST"):$(grep -cxF "$DEADP" "$HIST")"
check "10777 P1 the live segment and live pool line are not in the history file" "0:0" "$(grep -cF "$LIVEQ" "$HIST"):$(grep -cxF "$LIVEP" "$HIST")"

check "10777 P2 the released pool line survives --apply byte for byte" "1" "$(grep -cxF "$LIVEP" "$DOC")"

mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
mkdir -p "$WORK/scratch"
before="$(tree)"
out="$(cd "$WORK/scratch" && bash "$QP" --doc "$DOC" 2>"$WORK/err")"; rc=$?
err="$(cat "$WORK/err")"
after="$(tree)"
check "10777 P3 print mode prints the pruned queue: line and the dropped pool line" "0:queue: $LIVEQ || tail text
$DEADP" "$rc:$out"
check "10777 P3 print mode reports the counts and no history path" "queue-prune: dead-queue=1 done-pool=1:HIMMEL-901" "$err"
check "10777 P3 print mode writes no file anywhere in the fixture tree" "$before" "$after"

mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
run --apply
h1="$(sha256sum < "$HIST")"; d1="$(sha256sum < "$DOC")"
run --apply
check "10777 P4 a second --apply exits 0 with exactly the zero counts line" "0:queue-prune: dead-queue=0 done-pool=0" "$rc:$err"
check "10777 P4 a second --apply appends nothing and leaves the doc byte-identical" "$h1:$d1" "$(sha256sum < "$HIST"):$(sha256sum < "$DOC")"

mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
mkdir -p "$FIX/specs"; : > "$FIX/specs/history"
d1="$(sha256sum < "$DOC")"
run --apply
check "10777 P5 a history write that fails exits 5" "5" "$rc"
check "10777 P5 the doc is byte-identical after the failed history write" "$d1" "$(sha256sum < "$DOC")"

mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
hook_edit() {
    printf '%s' "sed '$1' \"\$QUEUE_PRUNE_DOC\" > \"\$QUEUE_PRUNE_DOC.hook\" && mv \"\$QUEUE_PRUNE_DOC.hook\" \"\$QUEUE_PRUNE_DOC\""
}
QUEUE_PRUNE_PRE_APPLY_HOOK="$(hook_edit 's/PR 4410/PR 4411/')" run --apply
check "10777 P6 a pool line edited before the re-read exits 4" "4" "$rc"
check "10777 P6 the doc then holds exactly the hook's edit: the dead segment and Done line are still there" "1:1:1" \
    "$(grep -cxF 'pool-disposition: HIMMEL-902 hold PR 4411' "$DOC"):$(grep -cF "$DEADQ" "$DOC"):$(grep -cxF "$DEADP" "$DOC")"
check "10777 P6 exit 4 writes no history file" "no" "$([ -e "$HIST" ] && echo yes || echo no)"
mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
QUEUE_PRUNE_PRE_APPLY_HOOK="$(hook_edit 's/^last GO: none/last GO: edited by the hook/')" run --apply
check "10777 P6 an unrelated edit lets the apply go ahead" "0" "$rc"
check "10777 P6 the unrelated edit survives, the dead segment is gone and its copy is written" "1:0:1" \
    "$(grep -cxF 'last GO: edited by the hook' "$DOC"):$(grep -cF "$DEADQ" "$DOC"):$(grep -cxF "$DEADQ" "$HIST")"

mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
: > "$WORK/prs-empty.json"
d1="$(tree)"
ORPHAN_PR_CHECK_PRS_ALL="$WORK/prs-empty.json" run --apply
check "10777 P7 an empty PR seam exits 3" "3" "$rc"
check "10777 P7 nothing is written" "$d1" "$(tree)"

TAIL='|| #4401 HELD by F1 (judge owed) | MERGED under AV: #4410 | pool-disposition: HIMMEL-901 hold HIMMEL-900'
mkdoc "$DEADQ| $LIVEQ $TAIL" "$DEADP" "$LIVEP"
run --apply
check "10777 P8 the tail after the first || is untouched by --apply" "$LIVEQ $TAIL" "$(qline)"

SEGA='#4325 HELD for the adapter merge wake=pr:4951 resume=/h/r.md '
SEGB=' #4400 HELD wake=pr:4951 resume=/h/s.md '
SEGC=' 4951 merging'
printf '%s\n' "$SEGB" > "$WORK/drop-b.txt"
check "10777 P9 the kept segments are rejoined with | (chief.sh row 10716)" "#4325 HELD for the adapter merge wake=pr:4951 resume=/h/r.md | 4951 merging" \
    "$(printf '%s\n' "$SEGA|$SEGB|$SEGC" | bash "$QP" --drop-segments "$WORK/drop-b.txt" 2>/dev/null)"
printf '%s\n%s\n' "$SEGA" "$SEGB" > "$WORK/drop-ab.txt"
check "10777 P9 every head segment dropped leaves the tail alone as || <tail>" "|| older segments of this line: specs/decisions/h.md" \
    "$(printf '%s\n' "$SEGA|$SEGB|| older segments of this line: specs/decisions/h.md" | bash "$QP" --drop-segments "$WORK/drop-ab.txt" 2>/dev/null)"
check "10777 P9 a kept segment and a tail are joined with one blank" "4951 merging || older segments of this line: specs/decisions/h.md" \
    "$(printf '%s\n' "$SEGA|$SEGB|$SEGC || older segments of this line: specs/decisions/h.md" | bash "$QP" --drop-segments "$WORK/drop-ab.txt" 2>/dev/null)"
check "10777 P9 an empty head and no tail reads none" "none" \
    "$(printf '%s\n' "$SEGA|$SEGB" | bash "$QP" --drop-segments "$WORK/drop-ab.txt" 2>/dev/null)"
mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
bash "$OPC" --stale-report --doc "$DOC" > "$WORK/report.txt" 2>/dev/null
got="$(printf '%s\n' "$DEADQ| $LIVEQ || tail text" | bash "$QP" --drop-segments "$WORK/report.txt" 2>/dev/null)"
check "10777 P9.lines a full --stale-report file drops exactly the DEAD-QUEUE segments" "$LIVEQ || tail text" "$got"
check "10777 P9.lines the output holds no input=, dead-queue= or done-pool= text" "0" "$(printf '%s\n' "$got" | grep -cE 'input=|dead-queue=|done-pool=')"
printf 'DONE-POOL\tHIMMEL-901\t%s\ndead-queue=0\ndone-pool=1:HIMMEL-901\ninput=1-2\n' "$DEADP" > "$WORK/report-nodead.txt"
check "10777 P9.lines a report with no DEAD-QUEUE line drops no segment" "$DEADQ| $LIVEQ" \
    "$(printf '%s\n' "$DEADQ| $LIVEQ" | bash "$QP" --drop-segments "$WORK/report-nodead.txt" 2>/dev/null)"

mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
chmod 640 "$DOC"
run --apply
check "10777 P10 the doc keeps its mode after --apply" "640" "$(stat -c %a "$DOC")"  # gnu-ok: Linux-only kit

fmt="$(sed -n 's/.*printf '"'"'%s\(# Live state trimmed by chief.sh next from %s at %s\)\\n.*/\1/p' "$HERE/../chief/chief.sh" | head -n 1)"
want="$(printf '%s\n' "$fmt" | sed 's/trimmed by chief.sh next/pruned by queue-prune.sh/')"
hdr="$(grep '^# Live state' "$HIST" | head -n 1)"
check "10777 P11 the history header is chief.sh's with the verb and script name swapped" "$(printf '%s' "$want" | sed "s/%s/$STEM/; s/%s/$(printf '%s' "$hdr" | sed 's/.* at //')/")" "$hdr"

Q12='MERGED under AV: #4410 329422b3f |  #4401 HELD by F1  | #4402 HELD by F2 |  MERGED under AZ: #4411 1234567  | #4420 HELD by F3 | #4403 HELD by x'
mkdoc "$Q12"
bash "$OPC" --stale-report --doc "$DOC" > "$WORK/report12.txt" 2>/dev/null
got="$(printf '%s\n' "$Q12" | bash "$QP" --drop-segments "$WORK/report12.txt" 2>/dev/null)"
check "10777 P12 the four flagged segments go and the two live ones stay in order" "4:#4402 HELD by F2 | #4403 HELD by x" "$(grep -c '^DEAD-QUEUE' "$WORK/report12.txt"):$got"

printf '%s\n' ' b) #4401 HELD by F1' > "$WORK/drop-amb.txt"
check "10777 P9.amb a listed text that sits in a split parenthesis is kept by --drop-segments" "x (a | b) #4401 HELD by F1" \
    "$(printf '%s\n' 'x (a | b) #4401 HELD by F1' | bash "$QP" --drop-segments "$WORK/drop-amb.txt" 2>/dev/null)"

mkdoc "$DEADQ| $LIVEQ || tail text" "$DEADP" "$LIVEP"
rm -f "$WORK/held" "$WORK/release"
( . "$HERE/worker-doc-lock.sh"; doc_lock "$DOC" test && { : > "$WORK/held"; while [ ! -e "$WORK/release" ]; do sleep 0.05; done; } ) &
hp=$!
i=0; while [ ! -e "$WORK/held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
check "10777 P13 the test holds the shared doc lock before --apply starts" "yes" "$([ -e "$WORK/held" ] && echo yes || echo no)"
bash "$QP" --doc "$DOC" --apply >/dev/null 2>&1 &
qp=$!
sleep 0.5
check "10777 P13 --apply waits while another writer holds the doc lock" "alive:1" "$(kill -0 "$qp" 2>/dev/null && echo alive):$(grep -cF "$DEADQ" "$DOC")"
: > "$WORK/release"; wait "$hp"
i=0; while kill -0 "$qp" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
check "10777 P13 the --apply run ends once the lock is released" "gone" "$(kill -0 "$qp" 2>/dev/null && echo alive || echo gone)"
kill "$qp" 2>/dev/null
wait "$qp"
check "10777 P13 --apply writes once the lock is released" "0:1" "$(grep -cF "$DEADQ" "$DOC"):$(grep -cxF "$DEADQ" "$HIST")"

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-queue-prune.sh"
    exit 0
fi
echo "FAIL - test-queue-prune.sh ($fails failure(s))"
exit 1
