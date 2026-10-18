#!/usr/bin/env bash
# Release notes in the user-facing shape (docs/release/changelog-shape.md).
#
# Usage:
#   gen-release-notes.sh --prs <prs.json> --version <vX.Y.Z> [--date <YYYY-MM-DD>]
#       Render notes from merged PRs. <prs.json> is the output of
#         gh pr list --state merged --limit 2000 --search 'merged:>=<date>' --json number,title,body
#       A PR is user-facing when its body has a `## Release note` block of
#       `- new|changed|update|known: <text>` lines; every other PR is internal
#       and is folded into one count line, never listed.
#   gen-release-notes.sh --check <notes.md>
#       Exit 1 unless the file has the five sections in order, no ticket key or
#       PR number in a user section, and exactly one line under Internal.
set -uo pipefail

H_NEW="What you can now do"
H_CHANGED="What changed that you will notice"
H_UPDATE="What you must do on update"
H_KNOWN="Known issues"
H_INTERNAL="Internal"
LEAK_RE='HIMMEL-[0-9]+|#[0-9]+'

die() { echo "gen-release-notes: $*" >&2; exit 1; }

check_notes() {
    local f="$1" heads want i=0 line sect="" internal=0 hit
    [ -f "$f" ] || die "no such file: $f"
    heads="$(grep -E '^## ' "$f" | sed 's/^## //')" || true
    want="$H_NEW
$H_CHANGED
$H_UPDATE
$H_KNOWN
$H_INTERNAL"
    [ "$heads" = "$want" ] || die "$f: sections must be exactly, in order: $H_NEW, $H_CHANGED, $H_UPDATE, $H_KNOWN, $H_INTERNAL"
    while IFS= read -r line || [ -n "$line" ]; do
        i=$((i + 1))
        case "$line" in
            '## '*) sect="${line#\#\# }"; continue ;;
        esac
        [ -n "${line//[[:space:]]/}" ] || continue
        [ -n "$sect" ] || continue
        if [ "$sect" = "$H_INTERNAL" ]; then
            internal=$((internal + 1))
        elif hit="$(printf '%s\n' "$line" | grep -E -o "$LEAK_RE" | head -1)" && [ -n "$hit" ]; then
            die "$f:$i: '$hit' in section '$sect' - tickets and PR numbers belong in CHANGELOG.md, not the user sections"
        fi
    done < "$f" # read-sink-ok: operator-supplied notes path, read-only validation, release-cut entry point
    [ "$internal" -eq 1 ] || die "$f: section '$H_INTERNAL' must be exactly one line (found $internal)"
    return 0
}

render() {
    local prs="$1" version="$2" date="$3" items kind text n_internal=0 line plural
    local new="" changed="" update="" known=""
    # one `INTERNAL` per PR with no Release note block, else one `- kind: text` per item
    items="$(jq -r '
        .[] | ((.body // "") | gsub("\r"; "") | split("\n")) as $l
        | (reduce $l[] as $x ({in: false, items: []};
            if ($x | test("^## +Release note *$"; "i")) then .in = true
            elif (.in and ($x | test("^#"))) then .in = false
            elif (.in and ($x | test("^- (new|changed|update|known): *.+"))) then .items += [$x]
            else . end)) .items
        | if length == 0 then "INTERNAL" else .[] end' "$prs")" || die "cannot read $prs as a PR list"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$line" = "INTERNAL" ]; then n_internal=$((n_internal + 1)); continue; fi
        kind="${line#- }"; kind="${kind%%:*}"
        text="${line#- "$kind":}"; text="${text# }"
        if printf '%s\n' "$text" | grep -E -q "$LEAK_RE"; then
            die "release note names a ticket or PR number: $text"
        fi
        case "$kind" in
            new)     new="${new}- ${text}"$'\n';;
            changed) changed="${changed}- ${text}"$'\n';;
            update)  update="${update}- ${text}"$'\n';;
            known)   known="${known}- ${text}"$'\n';;
        esac
    done <<< "$items"
    echo "# ${version} release notes"
    echo
    [ -z "$date" ] || { echo "**Release date:** ${date}."; echo; }
    section() { echo "## $1"; echo; if [ -n "$2" ]; then printf '%s' "$2"; else echo "Nothing."; fi; echo; }
    section "$H_NEW" "$new"
    section "$H_CHANGED" "$changed"
    section "$H_UPDATE" "$update"
    section "$H_KNOWN" "$known"
    echo "## $H_INTERNAL"
    echo
    plural="s"; [ "$n_internal" -eq 1 ] && plural=""
    echo "Internal: ${n_internal} further change${plural} (guards, console and CI tooling, tests) are not listed here; \`CHANGELOG.md\` has the per-commit record."
}

case "${1:-}" in
    --check) [ $# -eq 2 ] || die "usage: --check <notes.md>"; check_notes "$2";;
    --prs)
        prs="${2:-}"; shift 2 || die "usage: --prs <prs.json> --version <vX.Y.Z>"
        version=""; date=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --version) version="${2:-}"; shift 2 || die "--version needs a value";;
                --date)    date="${2:-}"; shift 2 || die "--date needs a value";;
                *) die "unknown argument: $1";;
            esac
        done
        [ -f "$prs" ] || die "no such file: $prs"
        printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || die "--version must be vX.Y.Z"
        render "$prs" "$version" "$date";;
    *) die "usage: --prs <prs.json> --version <vX.Y.Z> [--date D] | --check <notes.md>";;
esac
