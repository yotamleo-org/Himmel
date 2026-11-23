#!/usr/bin/env bash
# scope-approve.sh — the chief's one call for a batch of proposed Writes lines.
#
#   scope-approve.sh [--dry-run | --verify] --chief <session> <batch-file>
#
# <batch-file> is JSON lines: one object per no-scope ticket, `next-dispatchable.sh --scope-batch` writes the first five
# fields and the helper (docs/handover/chief-sections/scope-helper.md) adds `writes`, `new`, `core`, `why`, `approve`.
# For each row with approve "yes" and a non-empty writes, in order, the first failing check prints its word and skips the row:
#   shape (REFUSED), posted before (SKIPPED), still no-scope by next-dispatchable.sh (SKIPPED scoped, REFUSED unknown),
#   paths (REFUSED path), `release core-check` answering NOT-CORE (REFUSED core).
# A row that passes gets one Jira comment, `readiness: scope-batch <id> approved by <chief>` then one `Writes: <path>` line
# each, posted as ADF (one plain paragraph per line: the markdown route would join lines and eat underscores). The post is
# recorded in <batch-file>.posted. After the last post one incremental `jira mirror` runs, and next-dispatchable.sh judges
# every posted key again: CLEARED, STAYS or UNKNOWN. Every scope verdict is ND's; this script reads no ticket text for scope.
#
# One line per key: <WORD> <KEY> [reason]; words CLEARED STAYS UNKNOWN SKIPPED REFUSED FAILED. Last line:
#   scope-approve: batch <id> cleared=<a> stays=<b> unknown=<c> skipped=<d> refused=<e> failed=<f>
# --dry-run prints each comment body it would post and posts, records and refreshes nothing.
# --verify runs only the refresh and the per-key check for the keys in <batch-file>.posted, posting nothing.
# Exit: 0 every posted key cleared; 1 any STAYS, UNKNOWN or FAILED; 2 usage, an unreadable batch file, or a sidecar that cannot be written (nothing is posted).
#
# Test seams, honoured only with SCOPE_APPROVE_TEST=1: SCOPE_APPROVE_JIRA_CLI, SCOPE_APPROVE_ND, SCOPE_APPROVE_MIRROR,
# SCOPE_APPROVE_REPO, SCOPE_APPROVE_POST_TIMEOUT. Otherwise the primary checkout's built Jira CLI and ND, the project's
# mirror directory and the primary checkout's origin/main are used.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
# shellcheck source=../../lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh"
common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"  # swallow-ok: an unreadable common dir falls back to the checkout this script sits in
PRIMARY="${common%/.git}"
[ -n "$PRIMARY" ] && [ "$PRIMARY" != "$common" ] || PRIMARY="$(cd "$HERE/../../.." && pwd -P)"
CLI="$PRIMARY/scripts/jira/dist/index.js"
ND="$PRIMARY/scripts/handover/chief-kit/next-dispatchable.sh"
REPO="$PRIMARY"
MIRROR=""
POST_TIMEOUT=60
if [ "${SCOPE_APPROVE_TEST:-}" = 1 ]; then
    CLI="${SCOPE_APPROVE_JIRA_CLI:-$CLI}"; ND="${SCOPE_APPROVE_ND:-$ND}"; REPO="${SCOPE_APPROVE_REPO:-$REPO}"
    MIRROR="${SCOPE_APPROVE_MIRROR:-}"; POST_TIMEOUT="${SCOPE_APPROVE_POST_TIMEOUT:-60}"
    export JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}"
else
    # shellcheck source=../../lib/jira-project.sh
    . "$HERE/../../lib/jira-project.sh"
    JIRA_PROJECT_KEY="$(jira_project_key)"; export JIRA_PROJECT_KEY
fi
if [ -z "$MIRROR" ]; then
    [ "${SCOPE_APPROVE_TEST:-}" = 1 ] || MIRROR="$(jira_mirror_dir)"
fi

usage() {
    {
        echo "usage: scope-approve.sh [--dry-run | --verify] --chief <session> <batch-file>"
        echo "  jira CLI: $CLI"
    } >&2
    exit 2
}

mode=post; chief=""; chief_seen=0; bf=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) [ "$mode" = post ] || usage; mode=dry; shift ;;
        --verify) [ "$mode" = post ] || usage; mode=verify; shift ;;
        --chief) [ "$#" -ge 2 ] || usage; chief="$2"; chief_seen=1; shift 2 ;;
        -*) usage ;;
        *) [ -z "$bf" ] || usage; bf="$1"; shift ;;
    esac
done
[ "$chief_seen" = 1 ] && [ -n "$chief" ] && [ -n "$bf" ] || usage
case "$chief" in *[!A-Za-z0-9._:@+-]*) echo "scope-approve: --chief must be a session name (letters, digits and ._:@+-)" >&2; exit 2 ;; esac
[ -r "$bf" ] || { echo "scope-approve: cannot read the batch file $bf" >&2; exit 2; }
jq -e . "$bf" > /dev/null 2>&1 || { echo "scope-approve: the batch file $bf is not JSON lines" >&2; exit 2; }
nrows="$(jq -s 'length' "$bf")"
[ "$nrows" -ge 1 ] || { echo "scope-approve: the batch file $bf has no rows" >&2; exit 2; }
[ -d "$MIRROR" ] || { echo "scope-approve: the mirror directory $MIRROR does not exist" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/scope-approve.XXXXXX")" || exit 2  # prim-ok: this script's own scratch directory, removed by its EXIT trap
trap 'rm -rf "$T"' EXIT
bd="$(cd "$(dirname "$bf")" && pwd -P)"
sidecar="$bf.posted"
if [ "$mode" = post ]; then
    if [ -e "$sidecar" ]; then sidecar_dir_ok=0; [ -w "$sidecar" ] && sidecar_dir_ok=1; else sidecar_dir_ok=0; [ -w "$bd" ] && sidecar_dir_ok=1; fi
    [ "$sidecar_dir_ok" = 1 ] || { echo "scope-approve: cannot write $sidecar, so a post could not be recorded: refusing before any post" >&2; exit 2; }
fi
first_batch="$(jq -sr '.[0] | try .batch catch ""' "$bf")"
dup_keys="$(jq -sr '[.[] | try .key catch null] | map(select(. != null)) | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$bf")"
ID_RE='^[0-9]{8}T[0-9]{4}-[A-Z][A-Z0-9_]*-[0-9]+$'
PATH_RE='^((scripts|docs|marketplace|plugins|templates|tools|\.claude|\.github|\.codex)/[A-Za-z0-9_.+@-]+(/[A-Za-z0-9_.+@-]+)*|CLAUDE\.md|AGENTS\.md|README\.md|package\.json|package-lock\.json|bun\.lock|uv\.lock|pyproject\.toml|\.gitignore|\.pre-commit-config\.yaml)$'
n_cleared=0; n_stays=0; n_unknown=0; n_skipped=0; n_refused=0; n_failed=0; n_wouldpost=0
: > "$T/posted.keys"

say() { printf '%s\n' "$*"; }
count() { case "$1" in
    CLEARED) n_cleared=$((n_cleared + 1)) ;; STAYS) n_stays=$((n_stays + 1)) ;; UNKNOWN) n_unknown=$((n_unknown + 1)) ;;
    SKIPPED) n_skipped=$((n_skipped + 1)) ;; REFUSED) n_refused=$((n_refused + 1)) ;; FAILED) n_failed=$((n_failed + 1)) ;;
esac; }
word() {
    count "$1"; say "$1 $2${3:+ $3}"
}

nd_run() {
    ND_OUT="$(bash "$ND" --no-classify --mirror "$MIRROR" --why-ticket "$1" 2>/dev/null)"; ND_RC=$?  # swallow-ok: the exit code is read next: only 0 or 1 is ever read as an answer
}
scope_line_of() { printf '%s\n' "$ND_OUT" | grep -m1 -- "^# scope $1 " || true; }  # swallow-ok: no scope line is the empty answer
has_gate() { grep -q -- "^GATE $1 no-scope:" <<< "$ND_OUT"; }
sorted_set() { tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u | tr '\n' ','; }

row_json() { jq -sc ".[$1]" "$bf"; }
shape_ok() {
    printf '%s' "$1" | jq -e --arg first "$first_batch" --arg re "$ID_RE" '
        (type == "object")
        and (.key | type == "string" and test("^[A-Z][A-Z0-9_]*-[0-9]+$"))
        and (.batch | type == "string" and . == $first and test($re))
        and (.writes | type == "array" and all(.[]; type == "string" and (test("[[:cntrl:]]") | not)))
        and ((.new // []) | type == "array" and all(.[]; type == "string" and (test("[[:cntrl:]]") | not)))' > /dev/null 2>&1
}

path_ok() {
    local p="$1" newl="$2" t parent
    [[ "$p" =~ $PATH_RE ]] || return 1
    case "$p" in *..*) return 1 ;; esac
    t="$(git -C "$REPO" cat-file -t "origin/main:$p" 2>/dev/null || true)"  # swallow-ok: a missing object is the empty type, which path_ok reads as absent
    [ "$t" != blob ] || return 0
    [ -z "$t" ] || return 1
    grep -qxF -- "$p" <<< "$newl" || return 1
    parent="$(dirname "$p")"
    if [ "$parent" = . ]; then t="$(git -C "$REPO" cat-file -t "origin/main^{tree}" 2>/dev/null || true)"  # swallow-ok: a failed read leaves the type empty, which is not tree: the path is refused
    else t="$(git -C "$REPO" cat-file -t "origin/main:$parent" 2>/dev/null || true)"; fi  # swallow-ok: a failed read leaves the type empty, which is not tree: the path is refused
    [ "$t" = tree ]
}

sidecar_has() { grep -qs -- "^$1 " "$bd"/*.posted; }
marker_in_mirror() { grep -q -- "^readiness: scope-batch $2 approved by" "$MIRROR/$1.md" 2>/dev/null; }

post_check() {
    local key="$1" id="$2" want="$3" sl files
    if ! marker_in_mirror "$key" "$id"; then word UNKNOWN "$key" "(not in mirror yet)"; return; fi
    nd_run "$key"
    case "$ND_RC" in 0|1) ;; *) word UNKNOWN "$key" "(next-dispatchable.sh exit $ND_RC)"; return ;; esac
    sl="$(scope_line_of "$key")"
    files="$(printf '%s\n' "$sl" | sed -nE "s/^# scope $key readiness comment [^ ]+: (.*) reads=.*$/\\1/p")"
    if has_gate "$key"; then word STAYS "$key" "(next-dispatchable.sh still gates it on no-scope)"; return; fi
    if [ -n "$files" ] && [ "$(printf '%s' "$files" | sorted_set)" = "$(printf '%s\n' "$want" | tr '\n' ',' | sorted_set)" ]; then
        word CLEARED "$key"
    else
        word STAYS "$key" "(next-dispatchable.sh reads: ${sl:-no scope line})"
    fi
}

writes_of_row() { printf '%s' "$1" | jq -r '.writes[]'; }

if [ "$mode" = verify ]; then
    [ -s "$sidecar" ] || { echo "scope-approve: no $sidecar, nothing to verify" >&2; exit 2; }
    id="$first_batch"
    if ! ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 300} node "$CLI" mirror --root "$MIRROR" > "$T/mirror.out" 2>&1; then refresh_failed=1; else refresh_failed=0; fi
    while IFS= read -r skey; do
        [ -n "$skey" ] || continue
        i=0; found=""
        while [ "$i" -lt "$nrows" ]; do
            rj="$(row_json "$i")"
            if [ "$(printf '%s' "$rj" | jq -r 'try .key catch ""')" = "$skey" ] && shape_ok "$rj"; then found="$rj"; break; fi
            i=$((i + 1))
        done
        if [ -z "$found" ]; then word UNKNOWN "$skey" "(no valid row in this batch file)"; continue; fi
        if [ "$refresh_failed" = 1 ]; then word UNKNOWN "$skey" "(mirror refresh failed)"; continue; fi
        post_check "$skey" "$id" "$(writes_of_row "$found")"
    done < <(awk '{print $1}' "$sidecar" | LC_ALL=C sort -u)
else
    i=0
    while [ "$i" -lt "$nrows" ]; do
        rj="$(row_json "$i")"; i=$((i + 1))
        key="$(printf '%s' "$rj" | jq -r 'try (.key | tostring) catch "?"')"
        dup=0
        if grep -qxF -- "$key" <<< "$dup_keys"; then dup=1; fi
        if [ "$dup" = 1 ] || ! shape_ok "$rj"; then word REFUSED "$key" shape; continue; fi
        id="$(printf '%s' "$rj" | jq -r '.batch')"
        approve="$(printf '%s' "$rj" | jq -r '(.approve // "") | tostring')"
        writes="$(writes_of_row "$rj")"
        newl="$(printf '%s' "$rj" | jq -r '(.new // [])[]')"
        [ "$approve" = yes ] || { word SKIPPED "$key" approve; continue; }
        [ -n "$writes" ] || { word SKIPPED "$key" empty; continue; }
        if sidecar_has "$key" || marker_in_mirror "$key" "$id"; then word SKIPPED "$key" posted; continue; fi
        nd_run "$key"
        case "$ND_RC" in 0|1) ;; *) word REFUSED "$key" unknown; continue ;; esac
        sl="$(scope_line_of "$key")"
        if [ "$ND_RC" != 1 ] || ! has_gate "$key" || [ "$sl" != "# scope $key description: - reads=-" ]; then
            word SKIPPED "$key" "scoped (${sl#"# scope $key "})"; continue
        fi
        bad=0
        while IFS= read -r p; do path_ok "$p" "$newl" || { bad=1; break; }; done <<< "$writes"
        [ "$bad" = 0 ] || { word REFUSED "$key" path; continue; }
        csv="$(printf '%s\n' "$writes" | paste -sd, -)"
        core_out="$(node "$CLI" release core-check --paths "$csv" --key "$key" --mirror "$MIRROR" 2>/dev/null)"; core_rc=$?  # swallow-ok: the exit code is read on the next line and anything but exit 0 with one NOT-CORE line refuses the row
        if [ "$core_rc" != 0 ] || [ "$core_out" != "NOT-CORE $key" ]; then word REFUSED "$key" "core (rc=$core_rc: $(printf '%s' "$core_out" | head -n 1 | cut -c1-120))"; continue; fi
        { printf 'readiness: scope-batch %s approved by %s\n' "$id" "$chief"; while IFS= read -r p; do printf 'Writes: %s\n' "$p"; done <<< "$writes"; } > "$T/lines.$key"
        if [ "$mode" = dry ]; then
            say "WOULD-POST $key"; sed 's/^/  | /' "$T/lines.$key"; n_wouldpost=$((n_wouldpost + 1)); continue
        fi
        jq -Rn '{type: "doc", version: 1, content: [inputs | {type: "paragraph", content: [{type: "text", text: .}]}]}' < "$T/lines.$key" > "$T/adf.$key.json"
        post_out="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 2 "$POST_TIMEOUT"} node "$CLI" comment "$key" --adf-file "$T/adf.$key.json" --print-id 2> "$T/post.err")"; post_rc=$?
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [ "$post_rc" = 0 ] && [ -n "${post_out//[[:space:]]/}" ]; then
            printf '%s %s\n' "$key" "$now" >> "$sidecar"
        elif [ "$post_rc" != 0 ] && grep -qE '^(HTTP 4[0-9][0-9]|jira: cannot read --adf-file)' "$T/post.err"; then
            word FAILED "$key" "post: $(grep -m1 -E '^(HTTP 4[0-9][0-9]|jira: cannot read --adf-file)' "$T/post.err" | cut -c1-200)"; continue
        else
            printf '%s %s unconfirmed\n' "$key" "$now" >> "$sidecar"
        fi
        printf '%s\n' "$key" >> "$T/posted.keys"
        printf '%s\n' "$writes" > "$T/writes.$key"
        printf '%s\n' "$id" > "$T/id.$key"
    done
    if [ "$mode" = dry ]; then
        say "scope-approve: dry run, batch $first_batch would-post=$n_wouldpost skipped=$n_skipped refused=$n_refused"
        exit 0
    fi
    if [ -s "$T/posted.keys" ]; then
        if ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 300} node "$CLI" mirror --root "$MIRROR" > "$T/mirror.out" 2>&1; then refresh_failed=0; else refresh_failed=1; fi
        while IFS= read -r pkey; do
            if [ "$refresh_failed" = 1 ]; then word UNKNOWN "$pkey" "(mirror refresh failed)"; continue; fi
            post_check "$pkey" "$(cat "$T/id.$pkey")" "$(cat "$T/writes.$pkey")"
        done < "$T/posted.keys"
    fi
fi

say "scope-approve: batch $first_batch cleared=$n_cleared stays=$n_stays unknown=$n_unknown skipped=$n_skipped refused=$n_refused failed=$n_failed"
[ $((n_stays + n_unknown + n_failed)) -eq 0 ] || exit 1
exit 0
