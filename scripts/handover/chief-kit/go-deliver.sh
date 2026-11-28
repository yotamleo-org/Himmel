#!/usr/bin/env bash
# scripts/handover/chief-kit/go-deliver.sh - SOURCED, never run. The one owner of every fact a GO
# delivery computes: the worker's token, the PR's worker, the worker's live session, the GO
# message's wording, the bus send and when the token-bearing fallback line prints.
# go.sh delivers its GO through it; go-batch.sh, auto-go.sh and relay-batch.sh call it too.
#
#   gd_token_usable <token>                       dash-joined parts, never NONCE-UNKNOWN
#   gd_live_token <chief doc> <label>             the token of the one `## Live state` workers: span
#                                                 for <label> (legs: too while legacy names are on)
#   gd_brief_token <worker doc>                   the first backticked value of the last
#                                                 `> **RETASK:**` line above `## Results`
#   gd_worker_token <chief doc> <label> <worker doc> [<root>]  the record's under <root>, else (exit 1/3) the live one, else the brief's; rc 2 unreadable record
#   gd_worker_map <manifest>                      <pr> TAB <label> TAB <doc> TAB <lane> per manifest
#                                                 row whose doc's newest READY or MERGED bullet names a PR
#   gd_pr_worker <manifest> <pr>                  <label> TAB <doc> TAB <lane> of the last row for <pr>
#   gd_brief_merge_chief <worker doc>             rc 0 when the brief says `Merge: chief`, 1 when not,
#                                                 any other rc when the brief cannot be read
#   gd_census [<census script>]                   the live-session census rows, comment lines dropped,
#                                                 bounded at 10 s
#   gd_session <worker doc> <census rows>         sets GD_SESSION, GD_HITS, GD_CANDS (stem first)
#   gd_message <pr> <sha> <go file|''> <anchor> <contract yes|no|-> <why|-> [<token>]
#   gd_send <session> <message> <bus cli> <token> sets GD_REF (#<n>) or GD_ERR (token redacted);
#                                                 rc 0 only when the record was sent, bounded at 15 s
#   gd_fallback_due <class>                       true for bus-failed and no-session
#   gd_sendmessage_line <target> <message>        SENDMESSAGE to=<target> :: <message on one line>
#   gd_chief_doc <root> <scope>                   <root>/<scope>/$HIMMEL_BUS_NAME.md when readable
#
# The library reads no seam variable: each caller passes its own census script and bus CLI.
# Loading fails (rc 1) when close-facts.sh or legacy-names.sh cannot be sourced.
# Platform guard: bash 3.2+, jq.
# shellcheck disable=SC2034  # GD_SESSION, GD_HITS, GD_CANDS, GD_REF and GD_ERR are read by the callers

_GD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
# shellcheck source=scripts/handover/chief-kit/close-facts.sh
# shellcheck disable=SC1091
. "$_GD_HERE/close-facts.sh" || return 1
# shellcheck source=scripts/lib/legacy-names.sh
# shellcheck disable=SC1091
. "$_GD_HERE/../../lib/legacy-names.sh" || return 1
_GD_TIMEOUT=""
# shellcheck source=scripts/lib/timeout-bin.sh
# shellcheck disable=SC1091
if . "$_GD_HERE/../../lib/timeout-bin.sh" 2>/dev/null; then _GD_TIMEOUT="${_TIMEOUT_BIN:-}"; fi
_GD_CENSUS_LIB="$_GD_HERE/../../lanes/lib/claude-sessions.sh"

gd_token_usable() { [[ ${1:-} =~ ^[A-Za-z0-9]+(-[A-Za-z0-9._]+)+$ ]] && [ "$1" != NONCE-UNKNOWN ]; }

# shellcheck disable=SC2016  # the backticks are the Live state entry's literal markers
_gd_block_token() {
    awk -v k="$2" '
        $0 == "## Live state" { s = 1; next }
        s && /^## / { exit }
        s && index($0, k ":") == 1 { b = 1; print; next }
        b && (/^[[:space:]]*$/ || /^[0-9]+\. / || /^[A-Za-z][A-Za-z ]*:/ || /^[-*+>#]/) { b = 0 }
        b { print }
    ' "$1" 2>/dev/null | grep -oE '`[A-Za-z0-9_.-]+:[^`:[:space:]]+:[^`:[:space:]]+:[^`:[:space:]]+`' | tr -d '`' \
        | awk -F: -v l="$3" '$1 == l { print $2; n++ } END { exit n != 1 }'
}

gd_live_token() {
    local t
    t=$(_gd_block_token "$1" workers "$2") || t=""  # swallow-ok: no workers: span falls to the legs: block below
    if ! gd_token_usable "$t" && legacy_names_on; then
        t=$(_gd_block_token "$1" legs "$2") || t=""  # swallow-ok: no span is rc 1 below
    fi
    [ -n "$t" ] || return 1
    printf '%s\n' "$t"
}

# shellcheck disable=SC2016  # the backticks are the RETASK line's literal markers
gd_brief_token() {
    awk '/^## Results/ { exit } /^> \*\*RETASK:\*\*/ { l = $0 } END { print l }' "$1" 2>/dev/null \
        | grep -oE '`[^`]*`' | head -n 1 | tr -d '`'
}

gd_worker_token() {
    local t rc=0
    if [ -n "${4:-}" ]; then
        t=$(HANDOVER_DIR="$4" bash "$_GD_HERE/worker-token.sh" current "$3" 2>/dev/null) || rc=$?  # swallow-ok: every exit is handled below
    else
        t=$(bash "$_GD_HERE/worker-token.sh" current "$3" 2>/dev/null) || rc=$?  # swallow-ok: every exit is handled below
    fi
    case "$rc" in
        0) printf '%s\n' "$t"; return 0 ;;
        1|3) ;;
        *) return 2 ;;
    esac
    t=$(gd_live_token "$1" "$2") || t=""  # swallow-ok: no live token falls to the brief's below
    gd_token_usable "$t" || t=$(gd_brief_token "$3") || t=""  # swallow-ok: no brief token is rc 1 below
    gd_token_usable "$t" || return 1
    printf '%s\n' "$t"
}

gd_worker_map() {
    local rows label wdoc lane wpr
    rows=$(jq -r '(.workers // .legs // [])[]? | [.label, .doc, (.lane // "unknown")] | @tsv' "$1" 2>/dev/null) || return 1  # swallow-ok: an unreadable manifest is rc 1, which each caller reports
    while IFS=$'\t' read -r label wdoc lane; do
        [ -n "$label" ] && [ -f "$wdoc" ] && [ -r "$wdoc" ] || continue
        wpr=$(doc_pr "$wdoc"); [ -n "$wpr" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$wpr" "$label" "$wdoc" "$lane"
    done <<< "$rows"
}

gd_pr_worker() {
    local map row
    map=$(gd_worker_map "$1") || return 1
    row=$(printf '%s\n' "$map" | awk -F'\t' -v p="$2" '$1 == p { r = $2 "\t" $3 "\t" $4 } END { print r }')
    [ -n "$row" ] || return 1
    printf '%s\n' "$row"
}

gd_brief_merge_chief() { grep -qE '^> \*\*Merge:\*\* chief([^A-Za-z0-9_-]|$)' "$1"; }

gd_census() {
    local out
    if [ -n "${1:-}" ]; then
        out=$(${_GD_TIMEOUT:+"$_GD_TIMEOUT" -k 2 10} bash "$1" 2>/dev/null) || out=""  # swallow-ok: a failed, cut or incomplete census reads as no live session, so a second match is never ruled out on partial rows
    else
        # shellcheck disable=SC2016  # $1 is the child shell's argument
        out=$(${_GD_TIMEOUT:+"$_GD_TIMEOUT" -k 2 10} bash -c '. "$1" 2>/dev/null || exit 1; claude_sessions' _ "$_GD_CENSUS_LIB" 2>/dev/null) || out=""  # swallow-ok: as above
    fi
    printf '%s\n' "$out" | grep -v '^#' || true  # swallow-ok: no rows is an empty census
}

gd_session() {
    local stem names cname _cpid _crest dlabel clabel back
    stem="$(basename "$1" .md)"
    names="$(worker_identity "$1")"; names="${names#*$'\t'}"
    GD_CANDS=",$stem,$names,"
    GD_HITS=0; GD_SESSION=""
    while IFS=$'\t' read -r _cpid cname _crest; do
        [ -n "$cname" ] || continue
        case "$GD_CANDS" in *",$cname,"*) GD_HITS=$((GD_HITS + 1)); GD_SESSION="$cname" ;; esac
    done <<< "$2"
    [ "$GD_HITS" -eq 0 ] || return 0
    dlabel="$(worker_label "$1")"
    [[ $dlabel =~ ^N[0-9]+$ ]] || return 0
    while IFS=$'\t' read -r _cpid cname _crest; do
        [ -n "$cname" ] || continue
        clabel="$(worker_label "$cname")"
        [[ $clabel =~ ^${dlabel}[a-z]+$ ]] || continue
        back="$(printf '%s' "$cname" | sed -E "s/-${clabel}(-|\$)/-${dlabel}\\1/")"
        case "$GD_CANDS" in *",$back,"*) GD_HITS=$((GD_HITS + 1)); GD_SESSION="$cname" ;; esac
    done <<< "$2"
    return 0
}

gd_message() {
    local jt=" --jira-transition" msg
    [ "$5" != no ] || jt=""
    if [ -n "$3" ]; then
        msg=$(printf 'GO %s %s - merge with: bash %q%s --go %q' "$1" "$2" "$4/scripts/handover/merge-on-green.sh" "$jt" "$3")
    else
        msg=$(printf 'GO %s %s - merge with: bash %q%s' "$1" "$2" "$4/scripts/handover/merge-on-green.sh" "$jt")
    fi
    [ "$6" = - ] || msg="$msg"$'\n'"contract no: $6; merge without --jira-transition"
    [ -z "${7:-}" ] || msg="$msg"$'\n'"Your token \`$7\`."
    printf '%s\n' "$msg"
}

_gd_redact() {
    local t="$1"
    [ -z "${2:-}" ] || t="${t//"$2"/<token>}"
    printf '%s' "${t:0:150}"
}

gd_send() {
    local dir rc=0 out first
    GD_REF=""; GD_ERR=""
    dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/go-deliver.XXXXXX") || { GD_ERR="mktemp failed"; return 1; }  # prim-ok: holds one message file and is removed right after the send
    if ! (umask 077 && printf '%s\n' "$2" > "$dir/msg"); then
        rm -rf "$dir"; GD_ERR="cannot write the bus message file"; return 1
    fi
    out=$(${_GD_TIMEOUT:+"$_GD_TIMEOUT" -k 2 15} "$3" send "$1" "$dir/msg" 2>&1 < /dev/null) || rc=$?
    rm -rf "$dir"
    GD_REF=$(printf '%s\n' "$out" | sed -nE 's/^sent (#[0-9]+) to .*/\1/p' | head -n 1)
    first=$(printf '%s\n' "$out" | awk 'NF { print; exit }')
    first=$(_gd_redact "$first" "${4:-}")
    if [ "$rc" -ne 0 ]; then GD_REF=""; GD_ERR="bus send exit $rc: $first"; return 1; fi
    if [ -z "$GD_REF" ]; then GD_ERR="bus send printed no record number: $first"; return 1; fi
    return 0
}

gd_fallback_due() { case "$1" in bus-failed|no-session) return 0 ;; esac; return 1; }

gd_sendmessage_line() { printf 'SENDMESSAGE to=%s :: %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')"; }

gd_chief_doc() {
    local f
    [ -n "${HIMMEL_BUS_NAME:-}" ] || return 1
    f="$1/$2/$HIMMEL_BUS_NAME.md"
    [ -f "$f" ] && [ -r "$f" ] || return 1
    printf '%s\n' "$f"
}
