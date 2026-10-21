#!/usr/bin/env bash
# guard-rm-writes.sh — PreToolUse hook (matcher
# "Bash|Edit|Write|MultiEdit|NotebookEdit|mcp__.*").
#
# Two fences around the release engine's authority files (design §5.1/§11.3).
#
# Mode 1, EVERY session: the authority files of a release state directory
# <any>/release/<R>/ — release.json, lease.json, rulings.jsonl, operator.jsonl,
# requests.jsonl, events.jsonl, baseline-*.json — and everything under
# ~/.config/himmel/release/ (the signing keys) are written only by the Jira
# CLI's `release` op, never by a raw tool write.
#
# Mode 2, the release-manager session: headed-arm-leg.sh --profile
# release-manager exports HIMMEL_RELEASE_MANAGER=1, HIMMEL_RM_DOC and
# HIMMEL_RM_RELEASE; this guard then holds the session to its Jira, file and
# MCP allowlists.
#
# Delivered by the himmel-ops PLUGIN lane so mode 1 fires in every session,
# inside a checkout or not. The plugin copy is byte-identical to this file and
# sources nothing, for the same reason.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Not ported to native PowerShell — the release-manager lane
# (headed-arm-leg.sh) is Linux-only.
#
# TRIP CONDITION, mode 1 (any session; a payload not containing "release" is
# skipped before parsing):
#   Write|Edit|MultiEdit|NotebookEdit — the path, lexically normalised or
#     resolved, is an authority file.
#   Bash — a redirect (>, >>, >|, &>, N>) targets an authority file; or a
#     command segment (split on ; | & ( ) ` and newlines) runs tee, or sed
#     with -i/--in-place, and names an authority file; or runs cp or mv whose
#     destination (the last operand or -t DIR, or that directory joined with
#     a source's name) is one, or mv with an authority file as a source.
#     Exempt: a segment whose command (after VAR=value prefixes and an
#     optional node) is the Jira CLI with `release` as its op. ~/, $HOME/ and
#     ${HOME}/ expand to $HOME.
# TRIP CONDITION, mode 2 (HIMMEL_RELEASE_MANAGER=1, on top of mode 1):
#   Bash — the text names HIMMEL_RELEASE_MANAGER, leg-pr-open, merge-on-green,
#     console-kit/go.sh, inbox-send or leg-jira-status; a mutating git verb; a
#     gh write verb or a gh api method/body flag (the judge guard's set); or a
#     Jira CLI invocation (a word that is `jira`, ends in /jira, or names
#     scripts/jira/) outside the allowlist:
#       get, list, comments, links, mirror, versions, transitions;
#       release state|claim|rule|apply|lease acquire|lease release, each
#         naming $HIMMEL_RM_RELEASE as its release;
#       comment <KEY> --comment-file <path> (nothing else);
#       edit <KEY> with only --add-labels/--remove-labels whose every label is
#         backlog, deferred, needs-placement or scope-*;
#       version-edit <name> --description <text>.
#   mcp__* — a non-qmd tool whose lowercased name contains create, edit,
#     update, transition, delete, add, remove or set.
#   Write|Edit|MultiEdit|NotebookEdit — the path is relative, has a ".."
#     segment, does not resolve, or resolves outside: $HIMMEL_RM_DOC; its
#     sibling <stem>-RM-HANDOFF.md; status-*.md, burndown.md, ready-*.md and
#     proposals/** of release/$HIMMEL_RM_RELEASE beside the doc or at
#     $HANDOVER_DIR/<user>/<repo>/; /tmp/claude-<uid>/ (the session scratchpad).
#
# DEFAULT ACTION: mode 1 fails OPEN on its own infrastructure (no jq, an
# unparseable payload) so it can never brick an ordinary session. Mode 2 is a
# SECURITY FENCE and fails CLOSED: missing jq, an unparseable payload or a
# field of the wrong type all DENY.
#
# RESIDUAL (deliberate): the Bash checks are textual, not a shell parser —
# eval, variables, `cd` then a relative name, a quoted path with spaces, a
# wrapper script, an interpreter -c, or a writer verb outside this list (rm,
# dd, install, truncate) still pass; JSON unicode escapes in a path, or a
# symlink alias whose name lacks "release", skip the mode-1 prefilter. Mode 2
# applies its file allowlist to the file tools only: a Bash write to a path
# that is not an authority file is not screened. The authority files carry
# signed, chained rows (design §5.2), so a raw write is detected by every
# reader even when it passes here.
# ponytail: those shell shapes pass, the leg OS sandbox (HIMMEL-6180) closes them.
# Over-matching is the safe direction: in mode 2 a read that names
# scripts/jira/ (cat, git grep) is checked as a Jira call and denies.
#
# BYPASS: mode 1 has no in-session bypass — the release CLI is the writer, and
# an operator's own terminal is not hooked. Mode 2: launch the session without
# --profile release-manager (the marker is then unset).
#
# Bash 3.2-compatible. Exit codes: 0 allow (no output); 2 deny (JSON
# hookSpecificOutput with permissionDecision "deny" on stdout,
# permissionDecisionReason starting "release write-deny: ").
# git-env-ok: no git invocation; "git" is only a word matched in the screened command text
set -uo pipefail

RM=0
[ "${HIMMEL_RELEASE_MANAGER:-}" = "1" ] && RM=1

deny() {
    # deny <rule> <fragment>
    local reason hint
    hint="authority files are written only by node <repo>/scripts/jira/dist/index.js release <sub>"
    [ "$RM" -eq 1 ] && hint="a release manager rules through the release CLI and writes only its doc, reports and scratch"
    # swallow-ok: a jq failure falls back to a fixed deny reason; the call is still denied.
    reason=$(printf '%s' "release write-deny: $1 ($2) — $hint" | jq -Rs . 2>/dev/null) \
        || reason='"release write-deny: denied"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    exit 2
}

# fail <rule> <fragment> — an infrastructure failure: deny in mode 2, allow otherwise.
fail() {
    [ "$RM" -eq 1 ] && deny "$1" "$2"
    exit 0
}

# swallow-ok: an unreadable stdin reads as empty, and an empty payload fails closed in mode 2 below.
input=$(cat 2>/dev/null || true)
if [ "$RM" -eq 0 ]; then
    case "$input" in
        *release*) ;;
        *) exit 0 ;;
    esac
fi

command -v jq >/dev/null 2>&1 || fail "unparseable-payload" "jq not on PATH"
[ -n "$input" ] || fail "unparseable-payload" "empty stdin"
# swallow-ok: a jq failure takes the fail branch.
if ! tool=$(printf '%s' "$input" | jq -r '.tool_name | select(type == "string") // empty' 2>/dev/null); then
    fail "unparseable-payload" "cannot parse JSON stdin"
fi
[ -n "$tool" ] || fail "unparseable-payload" "no tool_name"

# normalise <path> — lexical: ~/ and $HOME/ expanded, empty and "." segments
# dropped, ".." pops. Relative stays relative.
normalise() {
    local p="$1" out="" seg lead="" IFS=/
    # The literal text $HOME / ${HOME} is matched here, not expanded.
    # shellcheck disable=SC2016
    case "$p" in
        "~"/*) p="$HOME/${p#\~/}" ;;
        '$HOME'/*) p="$HOME/${p#\$HOME/}" ;;
        '${HOME}'/*) p="$HOME/${p#\$\{HOME\}/}" ;;
    esac
    case "$p" in /*) lead=/ ;; esac
    set -f
    for seg in $p; do
        case "$seg" in
            "" | .) ;;
            ..) case "$out" in */*) out="${out%/*}" ;; *) out="" ;; esac ;;
            *) if [ -n "$out" ]; then out="$out/$seg"; else out="$seg"; fi ;;
        esac
    done
    set +f
    printf '%s\n' "$lead$out"
}

# is_authority <path> — true for an authority file or the key directory.
is_authority() {
    local p parent
    p=$(normalise "$1")
    case "$p" in
        "$HOME"/.config/himmel/release/* | */.config/himmel/release/* | .config/himmel/release/*) return 0 ;;
    esac
    case "$p" in */*) ;; *) return 1 ;; esac
    parent="${p%/*}"
    case "${p##*/}" in
        release.json | lease.json | rulings.jsonl | operator.jsonl | requests.jsonl | events.jsonl | baseline-*.json) ;;
        *) return 1 ;;
    esac
    case "$parent" in */*) ;; *) return 1 ;; esac
    [ "${parent%/*}" = "release" ] && return 0
    case "${parent%/*}" in */release) return 0 ;; esac
    return 1
}

# resolve <abs-path> — physical path; a missing final component resolves
# through its existing parent. Returns 1 when neither resolves.
resolve() {
    local p="$1" parent leaf r
    # gnu-ok: prim-ok: swallow-ok: the same resolver as guard-judge-writes.sh; a failure falls through to the parent.
    r=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
    case "$p" in */) return 1 ;; esac
    [ -L "$p" ] && return 1
    leaf="${p##*/}"
    parent="${p%/*}"
    [ -n "$parent" ] || parent="/"
    [ -d "$parent" ] || return 1
    # gnu-ok: prim-ok: swallow-ok: an unresolvable parent returns 1, which the callers deny.
    r=$(readlink -f -- "$parent" 2>/dev/null) && [ -n "$r" ] || return 1
    [ "$r" = "/" ] && r=""
    printf '%s\n' "$r/$leaf"
}

# has_word <word>... — true if any listed word is a whole word of $words,
# bare or as the last component of a path (/usr/bin/git counts as git).
has_word() {
    local w t
    for w in "$@"; do
        for t in $words; do
            [ "$t" = "$w" ] && return 0
            [ "${t##*/}" = "$w" ] && return 0
        done
    done
    return 1
}

is_jira_word() {
    case "$1" in
        jira | */jira | *jira/dist/* | *jira/src/* | */scripts/jira/* | scripts/jira/*) return 0 ;;
    esac
    return 1
}

# label_ok <comma-list> — every label is one the release manager may set.
label_ok() {
    local l IFS=,
    [ -n "$1" ] || return 1
    for l in $1; do
        case "$l" in
            backlog | deferred | needs-placement) ;;
            scope-*) case "${l#scope-}" in "" | *[!A-Za-z0-9._-]*) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# jira_ok <op> <args...> — the release manager's Jira allowlist.
jira_ok() {
    local op="${1:-}" a key="" file=0 labels=0 desc=0
    shift || true
    case "$op" in
        get | list | comments | links | mirror | versions | transitions) return 0 ;;
        release)
            case "${1:-}" in
                state | claim | rule | apply) shift ;;
                lease)
                    shift
                    case "${1:-}" in acquire | release) shift ;; *) return 1 ;; esac ;;
                *) return 1 ;;
            esac
            [ -n "${HIMMEL_RM_RELEASE:-}" ] && [ "${1:-}" = "$HIMMEL_RM_RELEASE" ] ;;
        comment)
            while [ "$#" -gt 0 ]; do
                a="$1"; shift
                case "$a" in
                    --comment-file) [ "$#" -gt 0 ] || return 1; shift; file=1 ;;
                    --comment-file=?*) file=1 ;;
                    -*) return 1 ;;
                    *) [ -z "$key" ] || return 1; key="$a" ;;
                esac
            done
            [ -n "$key" ] && [ "$file" -eq 1 ] ;;
        edit)
            while [ "$#" -gt 0 ]; do
                a="$1"; shift
                case "$a" in
                    --add-labels | --remove-labels)
                        [ "$#" -gt 0 ] || return 1
                        label_ok "$1" || return 1; shift; labels=1 ;;
                    --add-labels=* | --remove-labels=*)
                        label_ok "${a#*=}" || return 1; labels=1 ;;
                    -*) return 1 ;;
                    *) [ -z "$key" ] || return 1; key="$a" ;;
                esac
            done
            [ -n "$key" ] && [ "$labels" -eq 1 ] ;;
        version-edit)
            while [ "$#" -gt 0 ]; do
                a="$1"; shift
                case "$a" in
                    --description | --description=*) desc=1 ;;
                    -*) return 1 ;;
                    *) if [ "$desc" -eq 0 ]; then [ -z "$key" ] || return 1; key="$a"; fi ;;
                esac
            done
            [ -n "$key" ] && [ "$desc" -eq 1 ] ;;
        *) return 1 ;;
    esac
}

case "$tool" in
    Bash)
        # swallow-ok: a jq failure takes the fail branch.
        cmd_type=$(printf '%s' "$input" | jq -r '.tool_input.command | type' 2>/dev/null) \
            || fail "unparseable-payload" "cannot read command"
        [ "$cmd_type" = "string" ] || fail "unparseable-payload" "command not a string"
        # swallow-ok: a jq failure takes the fail branch.
        cmd=$(printf '%s' "$input" | jq -r '.tool_input.command' 2>/dev/null) \
            || fail "unparseable-payload" "cannot read command"
        command -v awk >/dev/null 2>&1 || fail "unparseable-payload" "awk not on PATH"
        # Line continuations joined (an odd run of trailing backslashes), then
        # quotes and backslashes dropped once; every check below reads the
        # unquoted text, so gh uplo\ad and gh up\<newline>load read as gh upload.
        bare=$(printf '%s' "$cmd" \
            | awk '{ if (match($0, /\\+$/) && RLENGTH % 2 == 1) { sub(/\\$/, ""); printf "%s", $0 } else print }' \
            | tr -d "\"'\\\\")

        # Mode 1: redirect targets.
        # swallow-ok: no match means no redirect targets.
        targets=$(printf '%s\n' "$bare" | grep -oE '>[>|]?[[:space:]]*[^[:space:];|&<>()`]+' || true)
        while IFS= read -r t; do
            t="${t#>}"; t="${t#[>|]}"
            t="${t#"${t%%[![:space:]]*}"}"
            [ -n "$t" ] || continue
            is_authority "$t" && deny "authority-write" "redirect to $t"
        done <<EOF
$targets
EOF

        # Mode 1: writer verbs, per command segment; a segment running the
        # Jira CLI's release op is the sanctioned writer.
        # Each separator character becomes a newline.
        # shellcheck disable=SC2020
        segments=$(printf '%s\n' "$bare" | tr ';|&()`' '\n\n\n\n\n\n')
        while IFS= read -r seg; do
            # The segment's command, after VAR=value prefixes and an optional
            # node, must be the Jira CLI with `release` as its op.
            set -f
            # shellcheck disable=SC2046
            set -- $(printf '%s' "$seg" | tr '\t\r' '  ')
            set +f
            while [ "$#" -gt 0 ]; do
                case "$1" in [A-Za-z_]*=*) shift ;; *) break ;; esac
            done
            case "${1:-}" in node | */node) shift ;; esac
            is_jira_word "${1:-}" && [ "${2:-}" = "release" ] && continue
            words=$(printf '%s' "$seg" | tr '<>=\t\r' '     ')
            # cp and mv write their destination: the last operand, or -t DIR.
            # A directory destination writes <dir>/<source name>; mv also
            # removes its sources, cp only reads them.
            # Redirections and their targets are not operands, nor are option
            # arguments: -S/--suffix takes one, -t/--target-directory names
            # the destination, and a short-option cluster ends at either.
            opwords=$(printf '%s' "$seg" \
                | sed -E 's/[0-9]*[<>]+&?[[:space:]]*[^[:space:]]*//g' \
                | tr '\t\r' '  ')
            wverb=""; ops=""; dest=""; next=""; endopts=0
            for t in $opwords; do
                if [ -z "$wverb" ]; then
                    case "${t##*/}" in cp | mv) wverb="${t##*/}" ;; esac
                    continue
                fi
                case "$next" in
                    dest) dest="$t"; next=""; continue ;;
                    skip) next=""; continue ;;
                esac
                [ "$endopts" -eq 1 ] && { ops="$ops $t"; continue; }
                case "$t" in
                    --) endopts=1 ;;
                    --t*=*) dest="${t#*=}" ;;
                    --t*) next=dest ;;
                    --su*=*) ;;
                    --su*) next=skip ;;
                    --*) ;;
                    -?*)
                        body="${t#-}"; pre="${body%%[St]*}"
                        [ "$pre" = "$body" ] && continue
                        rest="${body#"$pre"}"; arg="${rest#?}"
                        case "$rest" in
                            t*) if [ -n "$arg" ]; then dest="$arg"; else next=dest; fi ;;
                            *) [ -n "$arg" ] || next=skip ;;
                        esac
                        ;;
                    *) ops="$ops $t" ;;
                esac
            done
            if [ -n "$wverb" ]; then
                if [ -z "$dest" ]; then
                    dest="${ops##* }"; ops="${ops% *}"
                fi
                is_authority "$dest" && deny "authority-write" "$dest"
                for t in $ops; do
                    [ "$wverb" = "mv" ] && is_authority "$t" && deny "authority-write" "$t"
                    is_authority "${dest%/}/${t##*/}" && deny "authority-write" "${dest%/}/${t##*/}"
                done
            fi
            writer=0
            has_word tee && writer=1
            if [ "$writer" -eq 0 ] && has_word sed; then
                for t in $words; do
                    case "$t" in --in-place* | -i* | -[!-]*i*) writer=1 ;; esac
                done
            fi
            [ "$writer" -eq 1 ] || continue
            for t in $words; do
                is_authority "$t" && deny "authority-write" "$t"
            done
        done <<EOF
$segments
EOF

        [ "$RM" -eq 1 ] || exit 0

        case "$bare" in
            *HIMMEL_RELEASE_MANAGER*) deny "marker-override" "command names HIMMEL_RELEASE_MANAGER" ;;
            *leg-pr-open*) deny "pr-open" "leg-pr-open" ;;
            *merge-on-green*) deny "merge" "merge-on-green" ;;
            *console-kit/go.sh*) deny "go" "console-kit/go.sh" ;;
            *inbox-send*) deny "inbox-send" "inbox-send" ;;
            *leg-jira-status*) deny "jira-write" "leg-jira-status" ;;
        esac

        words=$(printf '%s' "$bare" | tr ';|&()<>`\n\t\r' '          ')
        if has_word git && has_word push commit merge rebase reset cherry-pick revert; then
            deny "git-write" "mutating git verb"
        fi
        if has_word gh; then
            has_word create comment review merge edit close reopen ready delete lock unlock transfer upload \
                && deny "gh-write" "gh write verb"
            if has_word api; then
                for t in $words; do
                    case "$t" in
                        -X* | --method* | -f* | -F* | --field* | --raw-field* | --input*)
                            deny "gh-write" "gh api $t" ;;
                    esac
                done
            fi
        fi

        # Jira: every invocation in every segment is checked against the
        # allowlist, with redirections (2>&1, > out) taken out of the arguments.
        # shellcheck disable=SC2020
        jsegs=$(printf '%s\n' "$bare" | sed -E -e 's/[0-9]*[<>]&[0-9-]+//g' \
            -e 's/[0-9]*&?[<>]+[[:space:]]*[^[:space:];|&<>()`]*//g' | tr ';|&()`' '\n\n\n\n\n\n')
        while IFS= read -r seg; do
            # Word splitting is the point.
            set -f
            # shellcheck disable=SC2086
            set -- $seg
            set +f
            while [ "$#" -gt 0 ]; do
                t="$1"; shift
                is_jira_word "$t" || continue
                jira_ok "$@" || deny "jira-write" "jira ${1:-<no op>} is outside the release-manager allowlist"
            done
        done <<EOF
$jsegs
EOF
        exit 0
        ;;
    mcp__*)
        [ "$RM" -eq 1 ] || exit 0
        case "$tool" in
            mcp__qmd__* | mcp__plugin_qmd_qmd__*) exit 0 ;;
        esac
        lower=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')
        case "$lower" in
            *create* | *edit* | *update* | *transition* | *delete* | *add* | *remove* | *set*)
                deny "mcp" "$tool" ;;
        esac
        exit 0
        ;;
    Write | Edit | MultiEdit | NotebookEdit)
        field=file_path
        [ "$tool" = "NotebookEdit" ] && field=notebook_path
        # swallow-ok: a jq failure takes the fail branch.
        path_type=$(printf '%s' "$input" | jq -r --arg f "$field" '(.tool_input[$f] // .tool_input.file_path) | type' 2>/dev/null) \
            || fail "unparseable-payload" "cannot read path"
        [ "$path_type" = "string" ] || fail "unparseable-payload" "path not a string"
        # swallow-ok: a jq failure takes the fail branch.
        path=$(printf '%s' "$input" | jq -r --arg f "$field" '.tool_input[$f] // .tool_input.file_path' 2>/dev/null) \
            || fail "unparseable-payload" "cannot read path"

        is_authority "$path" && deny "authority-write" "$path"
        resolved=""
        case "$path" in
            /*) resolved=$(resolve "$path") || resolved="" ;;
        esac
        [ -n "$resolved" ] && is_authority "$resolved" && deny "authority-write" "$resolved"

        [ "$RM" -eq 1 ] || exit 0

        case "$path" in
            /*) ;;
            *) deny "write-outside" "relative path" ;;
        esac
        case "/$path/" in
            */../*) deny "write-outside" "'..' segment" ;;
        esac
        [ -n "$resolved" ] || deny "write-outside" "path does not resolve"

        # swallow-ok: no scratch dir means no scratch allowance.
        tmpscratch=$(resolve "/tmp/claude-$(id -u 2>/dev/null)") || tmpscratch=""
        if [ -n "$tmpscratch" ]; then
            case "$resolved" in
                "$tmpscratch"/*) exit 0 ;;
            esac
        fi

        own_doc=""
        case "${HIMMEL_RM_DOC:-}" in
            /*.md) own_doc=$(resolve "$HIMMEL_RM_DOC") || own_doc="" ;;
        esac
        [ -n "$own_doc" ] || deny "write-outside" "HIMMEL_RM_DOC unset or not an absolute .md path"
        [ "$resolved" = "$own_doc" ] && exit 0
        [ "$resolved" = "${own_doc%.md}-RM-HANDOFF.md" ] && exit 0

        rel="${HIMMEL_RM_RELEASE:-}"
        case "$rel" in
            "" | *[!A-Za-z0-9._-]* | . | ..) deny "write-outside" "$resolved" ;;
        esac
        # The state directory: release/<R>/ beside the doc, or
        # $HANDOVER_DIR/<user>/<repo>/release/<R>/ (design §5).
        sub=""
        case "$resolved" in
            "${own_doc%/*}/release/$rel"/*) sub="${resolved#"${own_doc%/*}/release/$rel"/}" ;;
        esac
        if [ -z "$sub" ] && [ -n "${HANDOVER_DIR:-}" ]; then
            root=$(resolve "$HANDOVER_DIR") || root=""
            if [ -n "$root" ]; then
                case "$resolved" in
                    "$root"/*/*/release/"$rel"/*)
                        rest="${resolved#"$root"/}"
                        rest="${rest#*/}"; rest="${rest#*/}"
                        case "$rest" in
                            release/"$rel"/*) sub="${rest#release/"$rel"/}" ;;
                        esac
                        ;;
                esac
            fi
        fi
        case "$sub" in
            */*) case "$sub" in proposals/?*) exit 0 ;; esac ;;
            status-*.md | burndown.md | ready-*.md) exit 0 ;;
        esac
        deny "write-outside" "$resolved"
        ;;
esac
exit 0
