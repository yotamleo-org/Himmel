#!/usr/bin/env bash
# red-main-postmortem.sh — one postmortem line per failing suite of each red main run
# not yet reported: every red main CI is checked for why it did not show on the breaking
# PR's own CI.
#
#   red-main-postmortem.sh [--repo DIR]
#
# For each completed non-PR run of ci.yml on main that went red and is not in the seen file:
#   1. its failing suites: the shard-red-suites.txt the run uploads in its selector-miss-ledger
#      artifact;
#   2. its merge range: the previous completed non-PR main run's head sha .. this run's head sha
#      (the range ci.yml's own ledger step uses), one squash commit per PR, the PR number read
#      from the subject's trailing (#N);
#   3. per commit, `impacted-suites.sh --selector-miss <c>^..<c> --red-file <suites>`: a suite it
#      names was not in that PR's impacted list.
# Each failing suite prints
#   red-main run <id> #<pr> <suite> suite in its impacted list: yes|no
# A suite that some PR in the range selected prints its yes lines (those PRs' CI ran it); a suite
# no PR in the range selected prints a no line for every PR of the range. Nothing is guessed:
# a run whose suites, range or commit cannot be read prints one `unknown` line saying why.
# A run is reported once (its id goes in the seen file after its lines print), at most
# RED_MAIN_MAX_RUNS runs (default 3, newest first) and RED_MAIN_MAX_COMMITS commits per run
# (default 10, newest first) per call, so a tick stays inside its deadline.
#
# Env seams: RED_MAIN_GH (default gh-read.sh, else gh), RED_MAIN_IMPACTED (default
# scripts/cr/impacted-suites.sh beside this kit), RED_MAIN_STATE (seen file, default
# ${TICK_STATE_DIR:-$HOME/.himmel/state}/red-main-postmortem.seen), RED_MAIN_REPO (checkout).
# Exit 0 always; an unreadable run list prints nothing.
#
# PLATFORM GUARD: chief kit, Linux-only; Bash 3.2-compatible.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh" && git_env_scrub
# shellcheck source=../../lib/prim.sh
. "$HERE/../../lib/prim.sh"
repo="${RED_MAIN_REPO:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) [ "$#" -ge 2 ] || { echo "usage: red-main-postmortem.sh [--repo DIR]" >&2; exit 2; }; repo="$2"; shift 2 ;;
        *) echo "usage: red-main-postmortem.sh [--repo DIR]" >&2; exit 2 ;;
    esac
done
[ -n "$repo" ] || repo="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || exit 0  # swallow-ok: no checkout, nothing to postmortem
gh_bin="${RED_MAIN_GH:-}"
if [ -z "$gh_bin" ]; then
    gh_bin="$HERE/../../lib/gh-read.sh"
    [ -f "$gh_bin" ] || gh_bin=gh
fi
impacted="${RED_MAIN_IMPACTED:-$HERE/../../cr/impacted-suites.sh}"
state="${RED_MAIN_STATE:-${TICK_STATE_DIR:-$HOME/.himmel/state}/red-main-postmortem.seen}"
max_runs="${RED_MAIN_MAX_RUNS:-3}"
max_commits="${RED_MAIN_MAX_COMMITS:-10}"
case "$max_runs" in '' | *[!0-9]*) max_runs=3 ;; esac
case "$max_commits" in '' | *[!0-9]*) max_commits=10 ;; esac

runs="$(cd "$repo" 2>/dev/null && "$gh_bin" run list --branch main --workflow ci.yml --status completed --limit 30 --json databaseId,headSha,conclusion,event --jq '.[] | select(.event != "pull_request") | [.databaseId, .headSha, .conclusion] | @tsv' 2>/dev/null)" || exit 0  # swallow-ok: an unreadable run list reports nothing this tick
[ -n "$runs" ] || exit 0

work="$(tmpdir)" || exit 0  # swallow-ok: no scratch dir, no postmortem this tick
trap 'rm -rf "$work"' EXIT
printf '%s\n' "$runs" > "$work/runs"
mkdir -p "$(dirname "$state")" 2>/dev/null || exit 0  # swallow-ok: an unwritable state dir would repeat lines every tick, so report nothing
touch "$state" 2>/dev/null || exit 0  # swallow-ok: as above

ids=(); shas=(); concs=()
while IFS=$'\t' read -r id sha conc; do
    [ -n "$id" ] || continue
    ids[${#ids[@]}]="$id"; shas[${#shas[@]}]="$sha"; concs[${#concs[@]}]="$conc"
done < "$work/runs"

done_runs=0
n=${#ids[@]}
i=0
while [ "$i" -lt "$n" ] && [ "$done_runs" -lt "$max_runs" ]; do
    id="${ids[$i]}"; sha="${shas[$i]}"
    if [ "${concs[$i]}" = failure ] && ! grep -Fxq -- "$id" "$state"; then
        done_runs=$((done_runs + 1))
        prev=""
        j=$((i + 1))
        while [ "$j" -lt "$n" ]; do
            case "${concs[$j]}" in success | failure) prev="${shas[$j]}"; break ;; esac
            j=$((j + 1))
        done
        dl="$work/dl-$id"
        mkdir -p "$dl"
        red="$dl/shard-red-suites.txt"
        dlerr="$(cd "$repo" && "$gh_bin" run download "$id" -n selector-miss-ledger -D "$dl" 2>&1 >/dev/null)"; dlrc=$?  # swallow-ok: rc and message decide absent artifact versus a failed read below
        if [ "$dlrc" -ne 0 ] && ! grep -Fq 'no valid artifacts' <<< "$dlerr"; then
            i=$((i + 1))
            continue
        fi
        commits=""
        lrc=0
        if [ -n "$prev" ]; then
            commits="$(git -C "$repo" log --first-parent --format='%H%x09%s' -n "$((max_commits + 1))" "$prev..$sha" 2>/dev/null)"; lrc=$?  # swallow-ok: lrc is the verdict, an unreadable range prints the unknown line
        fi
        if [ ! -s "$red" ]; then
            printf 'red-main run %s unknown: no failing-suite list (selector-miss-ledger artifact absent or empty)\n' "$id"
        elif [ -z "$prev" ]; then
            printf 'red-main run %s unknown: no earlier completed main run, so the merge range is unknown\n' "$id"
        elif [ "$lrc" -ne 0 ]; then
            printf 'red-main run %s unknown: range %s..%s is not in this checkout\n' "$id" "$prev" "$sha"
        elif [ -z "$commits" ]; then
            printf 'red-main run %s unknown: range %s..%s holds no commits\n' "$id" "$prev" "$sha"
        elif [ "$(printf '%s\n' "$commits" | wc -l)" -gt "$max_commits" ]; then
            printf 'red-main run %s unknown: range holds more than %s commits, not checked\n' "$id" "$max_commits"
        else
            : > "$dl/yes"; : > "$dl/no"
            unk=0
            while IFS=$'\t' read -r c subj; do
                [ -n "$c" ] || continue
                pr="$(printf '%s\n' "$subj" | sed -n 's/.*(#\([0-9][0-9]*\))$/\1/p')"
                [ -n "$pr" ] || pr='?'
                out="$(cd "$repo" && bash "$impacted" --selector-miss "$c^..$c" --red-file "$red" 2>/dev/null)"; rc=$?  # swallow-ok: rc is the verdict; any rc but 0 or 1 reads unknown below
                case "$rc" in
                    0) while IFS= read -r s; do [ -z "$s" ] || printf '%s\t%s\n' "$pr" "$s" >> "$dl/yes"; done < "$red" ;;
                    1) printf '%s\n' "$out" | awk '$1 == "selector-miss:" { print $2 }' | sort -u > "$dl/missed"
                       if [ ! -s "$dl/missed" ]; then
                           unk=1
                       else
                           while IFS= read -r s; do
                               [ -n "$s" ] || continue
                               if grep -Fxq -- "$s" "$dl/missed"; then printf '%s\t%s\n' "$pr" "$s" >> "$dl/no"; else printf '%s\t%s\n' "$pr" "$s" >> "$dl/yes"; fi
                           done < "$red"
                       fi ;;
                    *) unk=1 ;;
                esac
            done <<< "$commits"
            printed=0
            while IFS= read -r s; do
                [ -n "$s" ] || continue
                if awk -F'\t' -v s="$s" '$2 == s { f = 1 } END { exit !f }' "$dl/yes"; then
                    awk -F'\t' -v s="$s" -v id="$id" '$2 == s { printf "red-main run %s #%s %s suite in its impacted list: yes\n", id, $1, s }' "$dl/yes"
                elif [ "$unk" -eq 0 ] && awk -F'\t' -v s="$s" '$2 == s { f = 1 } END { exit !f }' "$dl/no"; then
                    awk -F'\t' -v s="$s" -v id="$id" '$2 == s { printf "red-main run %s #%s %s suite in its impacted list: no\n", id, $1, s }' "$dl/no"
                else
                    printf 'red-main run %s %s unknown: impacted-suites could not read the range\n' "$id" "$s"
                fi
                printed=1
            done < "$red"
            [ "$printed" -eq 1 ] || [ "$unk" -eq 0 ] || printf 'red-main run %s unknown: impacted-suites could not read the range\n' "$id"
        fi
        printf '%s\n' "$id" >> "$state"
    fi
    i=$((i + 1))
done
exit 0
