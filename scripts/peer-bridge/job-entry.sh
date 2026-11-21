#!/usr/bin/env bash
# job-entry.sh - the in-guest job contract of the peer bridge runner.
#   bash job-entry.sh <list file> <backstop seconds>
# The work dir is the list file's dir; it holds src.tar (a .git whose FETCH_HEAD
# is the job's commit). Each listed suite runs through the tree's own
# run-shell-tests.sh --only-list; its suite-ledger.sh row gives the outcome:
# rc 0 pass, other rc fail, no row error. .job-result.json is rewritten whole
# after every suite, so a kill keeps the finished ones. Output goes to job.log.
# Bash 3.2-compatible.
set -u

list="${1:-}"
backstop="${2:-}"
case "$backstop" in '' | *[!0-9]*) echo "job-entry: backstop must be whole seconds" >&2; exit 2 ;; esac
[ -f "$list" ] || { echo "job-entry: no list file: $list" >&2; exit 2; }
work="$(cd "$(dirname "$list")" && pwd -P)" || exit 2
start="$(date +%s)"
result="$work/.job-result.json"
exec >> "$work/job.log" 2>&1

suites=()
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && suites+=("$line")
done < "$list"  # read-sink-ok: runs only in the offline job guest, which holds no host file; the runner passes its own /tmp/job/suites.txt
count=${#suites[@]}
outcomes=()

write_result() {
    local i=0 sep='' mins=$(( ($(date +%s) - start + 59) / 60 ))
    {
        printf '{"results":['
        while [ "$i" -lt "$count" ]; do
            if [ -n "${outcomes[$i]:-}" ]; then
                printf '%s{"suite":%d,"outcome":"%s"}' "$sep" "$i" "${outcomes[$i]}"
                sep=','
            fi
            i=$((i + 1))
        done
        printf '],"minutes":%d}\n' "$mins"
    } > "$result.tmp" && mv "$result.tmp" "$result"
}

finish_error() {
    local i="$1"
    while [ "$i" -lt "$count" ]; do
        outcomes[i]=error
        i=$((i + 1))
    done
    write_result
}

tree="$work/tree"
if ! { mkdir "$tree" && tar -xf "$work/src.tar" -C "$tree" && git -C "$tree" checkout -q --detach FETCH_HEAD; }; then
    echo "job-entry: could not check the job's commit out"
    finish_error 0
    exit 1
fi
cd "$tree" || { finish_error 0; exit 1; }

i=0
while [ "$i" -lt "$count" ]; do
    budget=$(( backstop - ($(date +%s) - start) - 600 ))
    [ "$budget" -lt 60 ] && break
    suite="${suites[$i]}"
    printf '%s\n' "$suite" > "$work/only.$i"
    echo "job-entry: suite $i $suite (budget ${budget}s)"
    HIMMEL_SUITE_LEDGER="$work/ledger.$i.jsonl" SUITE_RUN_BUDGET="$budget" \
        bash scripts/ci/run-shell-tests.sh --only-list "$work/only.$i"
    rc="$(jq -rR --arg s "$suite" 'fromjson? | select(.suite == $s) | .rc' "$work/ledger.$i.jsonl" 2>/dev/null | tail -n 1)"
    case "$rc" in
        0) outcomes[i]=pass ;;
        '' | *[!0-9]*) outcomes[i]=error ;;
        *) outcomes[i]=fail ;;
    esac
    write_result
    i=$((i + 1))
done
[ "$i" -lt "$count" ] && echo "job-entry: backstop budget spent before suite $i"
finish_error "$i"
exit 0
