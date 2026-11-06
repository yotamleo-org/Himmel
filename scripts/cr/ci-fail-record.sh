#!/usr/bin/env bash
# scripts/cr/ci-fail-record.sh <owner/repo> <pr> <head> [<run id>...]
# Append the CI failure ledger rows for a red at a PR head: one `fail` row per
# impacted suite whose manifest `ran` line is nonzero in each named run, and a `round`
# row for every earlier failed head of that PR. check-ci.sh calls it the moment a
# red is known (the step every worker passes at final CI); ready-check's item 19
# writes the same rows by the same key, so a row is never doubled.
#
# Ledger: $READY_CHECK_FAIL_LEDGER, else ~/.himmel/state/suite-evidence/ci-failures.jsonl
# (append-only, dir 700, file 600). Row shapes are scripts/cr/suite-fail-ledger.sh's.
# Advisory: any unreadable read leaves its rows out; the exit code is always 0 once
# the arguments parse (2 on a usage error), so a caller's verdict never moves.
# The impacted list comes from impacted-suites.sh in this checkout (origin/main..<head>,
# so <head> must be a local commit); CI_FAIL_RECORD_IMPACTED names a file of suites
# to use instead (a test seam).
set -uo pipefail
usage() { echo "usage: ci-fail-record.sh <owner/repo> <pr> <head> [<run id>...]" >&2; exit 2; }
[ $# -ge 3 ] || usage
nwo="$1"; pr="$2"; head="$3"; shift 3
case "$nwo" in */*) ;; *) usage ;; esac
case "$pr" in ''|*[!0-9]*) usage ;; esac
[ -n "$head" ] || usage
for r in "$@"; do case "$r" in ''|*[!0-9]*) usage ;; esac; done

here="$(cd "$(dirname "$0")" && pwd)"
ledger="${READY_CHECK_FAIL_LEDGER:-${HOME:-/tmp}/.himmel/state/suite-evidence/ci-failures.jsonl}"
_TIMEOUT_BIN=""
# shellcheck source=../lib/timeout-bin.sh
. "$here/../lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""  # swallow-ok: an empty _TIMEOUT_BIN skips the advisory write below
if [ -z "$_TIMEOUT_BIN" ]; then
    echo "ci-fail-record: no timeout binary, so no read here can be bounded; no ledger row written"
    exit 0
fi
d=$(mktemp -d "${TMPDIR:-/tmp}/ci-fail-record.XXXXXX") || exit 0  # swallow-ok: advisory  # prim-ok: this script sources no prim.sh (same as ready-check item 19); a failed mktemp writes no row
trap 'rm -rf "$d"' EXIT
rd() { "$_TIMEOUT_BIN" -k 5 "$1" bash "$here/../lib/gh-read.sh" "${@:2}" < /dev/null; }

add() {  # <json row>
    mkdir -p "$(dirname "$ledger")" 2>/dev/null && chmod 700 "$(dirname "$ledger")" 2>/dev/null  # swallow-ok: an unwritable ledger only loses the advisory row
    ( umask 077; printf '%s\n' "$1" >> "$ledger" ) 2>/dev/null || echo "ci-fail-record: CI failure ledger not written ($ledger)"
}

n=0
if [ $# -gt 0 ]; then
    if [ -n "${CI_FAIL_RECORD_IMPACTED:-}" ]; then
        sort -u "$CI_FAIL_RECORD_IMPACTED" > "$d/imp" 2>/dev/null || : > "$d/imp"  # swallow-ok: an unreadable list records no row
    else
        "$_TIMEOUT_BIN" -k 5 30 bash "$here/impacted-suites.sh" "refs/remotes/origin/main..$head" < /dev/null 2>/dev/null | grep -v '^$' | sort -u > "$d/imp" || : > "$d/imp"  # swallow-ok: an unreadable list records no row
    fi
    for run in "$@"; do
        rd 15 api "repos/$nwo/actions/runs/$run" --jq .head_sha > "$d/hs" 2>/dev/null || continue
        [ "$(tr -d '[:space:]' < "$d/hs")" = "$head" ] || continue
        rm -rf "$d/m"; mkdir "$d/m" || continue
        rd 30 run download "$run" -R "$nwo" -p 'shell-unit-manifest-ubuntu-latest-shard*' -D "$d/m" > /dev/null 2>&1 || continue
        find "$d/m" -type f -name 'manifest-shard*.txt' -exec cat {} + 2>/dev/null | tr -d '\r' \
            | awk '$1 == "ran" && $2 ~ /^[0-9]+$/ && $2 != "0" && NF == 3 { print $2, $3 }' > "$d/red" || continue  # swallow-ok: advisory
        while read -r rc s; do
            grep -Fxq -- "$s" "$d/imp" || continue
            if [ -r "$ledger" ] && jq -R -e --arg r "$nwo" --argjson p "$pr" --arg h "$head" --arg s "$s" --argjson u "$run" '
                fromjson? | select(type == "object" and .kind == "fail" and .repo == $r and .pr == $p and .head == $h and .suite == $s and .run == $u)' "$ledger" > /dev/null 2>&1; then
                continue
            fi
            add "$(jq -nc --arg r "$nwo" --argjson p "$pr" --arg h "$head" --arg s "$s" --argjson u "$run" --argjson c "$rc" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{kind: "fail", ts: $t, repo: $r, pr: $p, head: $h, suite: $s, run: $u, rc: $c}')"
            n=$((n + 1))
        done < "$d/red"
    done
fi

# one `round` row per earlier failed head of this PR (the PR moved on after a failure)
if [ -r "$ledger" ]; then
    jq -n -R -r --arg r "$nwo" --argjson p "$pr" --arg h "$head" '
        [inputs | fromjson? | select(type == "object" and .repo == $r and .pr == $p)] as $rows
        | ($rows | map(select(.kind == "round") | .head)) as $done
        | $rows | map(select(.kind == "fail" and .head != $h) | .head) | unique[]
        | select(. as $x | $done | index($x) | not)' "$ledger" 2>/dev/null | while IFS= read -r old; do  # swallow-ok: an unreadable ledger records no round
        add "$(jq -nc --arg r "$nwo" --argjson p "$pr" --arg h "$old" --arg n "$head" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{kind: "round", ts: $t, repo: $r, pr: $p, head: $h, next: $n}')"
    done
fi
[ "$n" -eq 0 ] || echo "ci-fail-record: CI failure ledger +$n row(s) ($ledger)"
exit 0
