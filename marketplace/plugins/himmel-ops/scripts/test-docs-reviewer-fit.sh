#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-docs-reviewer-fit.sh — fit_answer.py holds a docs-reviewer answer to 3,072 bytes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/../skills/docs-reviewer/fit_answer.py"
td="$(mktemp -d "${TMPDIR:-/tmp}/docs-reviewer-fit.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: [$2]!=[$3]"; }
has(){ grep -qF -- "$3" "$2" && ok "$1" || bad "$1: [$3] not in $2"; }
lacks(){ grep -qF -- "$3" "$2" && bad "$1: [$3] still in $2" || ok "$1"; }
pad(){ printf '%s %s\n' "$1" "$(printf '%*s' $(( $2 - ${#1} - 1 )) '' | tr ' ' x)"; }

# answer <file> <should-count> <appendix-count> <line-bytes> [blocking-count]
answer(){
    {
        echo "## Page verdicts"
        echo "- docs/a.md — reference for adopters; form fits: yes; verdict: polish"
        echo
        echo "## Must fix"
        for i in $(seq "${5:-1}"); do pad "- [BLOCKING] docs/a.md:$i — false claim" "$4"; done
        for i in $(seq "$2"); do pad "- [SHOULD] docs/a.md:$((i + 50)) — remark M0$i" "$4"; done
        echo "- docs/a.md: 2 pre-existing (see appendix)"
        echo
        echo "## Code changes implied"
        echo "none — every finding is a docs fix over right code."
        echo
        echo "## Declined to judge"
        echo "none"
        echo
        echo "docs-review: 9 findings (1 blocking, $2 should, 0 nit); 2 pre-existing; code changes implied: 0"
        if [ "$3" -gt 0 ]; then
            echo
            echo "<details><summary>Appendix</summary>"
            echo
            for i in $(seq "$3"); do pad "- pre-existing docs/a.md:$((i + 100)) — breach" "$4"; done
            echo "</details>"
        fi
    } >"$1"
}

run(){ python3 "$tool" "$1" >"$1.out" 2>"$1.err"; echo $?; }

# under the limit: unchanged
answer "$td/small.md" 2 2 100
check "small: exit 0" "$(run "$td/small.md")" 0
cmp -s "$td/small.md" "$td/small.md.out" && ok "small: unchanged" || bad "small: changed"

# over only by the appendix: appendix lines go from the bottom, must-fix stays
answer "$td/app.md" 3 12 200
check "appendix: exit 0" "$(run "$td/app.md")" 0
check "appendix: fits" "$(( $(wc -c <"$td/app.md.out") <= 3072 ))" 1
has "appendix: first appendix line kept" "$td/app.md.out" "docs/a.md:101"
lacks "appendix: last appendix line cut" "$td/app.md.out" "docs/a.md:112"
check "appendix: every SHOULD kept" "$(grep -c '^- \[SHOULD\]' "$td/app.md.out")" 3
has "appendix: summary kept" "$td/app.md.out" "docs-review: 9 findings"
has "appendix: block still closed" "$td/app.md.out" "</details>"

# over above the appendix (the run-6 B shape): appendix gone, last SHOULD cut, BLOCKING kept
answer "$td/must.md" 7 4 400
check "must-fix: exit 0" "$(run "$td/must.md")" 0
check "must-fix: fits" "$(( $(wc -c <"$td/must.md.out") <= 3072 ))" 1
lacks "must-fix: appendix gone" "$td/must.md.out" "<details>"
has "must-fix: BLOCKING kept" "$td/must.md.out" "[BLOCKING] docs/a.md:1"
has "must-fix: first SHOULD kept" "$td/must.md.out" "docs/a.md:51"
lacks "must-fix: last SHOULD cut" "$td/must.md.out" "docs/a.md:57"
has "must-fix: pre-existing line kept" "$td/must.md.out" "2 pre-existing (see appendix)"
has "must-fix: summary kept" "$td/must.md.out" "docs-review: 9 findings"
has "must-fix: stderr counts the cut" "$td/must.md.err" "SHOULD line(s)"

# only BLOCKING left and still over: exit 1, sent back once
answer "$td/block.md" 1 1 600 6
check "blocking: exit 1" "$(run "$td/block.md")" 1
check "blocking: all six kept" "$(grep -c '^- \[BLOCKING\]' "$td/block.md.out")" 6
has "blocking: caller told to send it back" "$td/block.md.err" 'send it back once with "cut to 3 KB"'

check "usage: exit 2" "$(python3 "$tool" 2>/dev/null; echo $?)" 2

[ "$fails" = 0 ] && echo "PASS test-docs-reviewer-fit" || { echo "FAIL test-docs-reviewer-fit ($fails)"; exit 1; }
