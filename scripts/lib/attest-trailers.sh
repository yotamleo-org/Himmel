#!/usr/bin/env bash
# scripts/lib/attest-trailers.sh - the one reader of the attestation-trailer rule.
# Sourceable and runnable. bash 3.2-safe: no
# mapfile, no associative arrays.
#
# The rule: a branch that changes shell/script files needs a `Platforms tested:`
# trailer, a branch that changes non-docs code needs a `Security reviewed:`
# trailer, and either may sit in ANY non-merge commit of the branch. A merge
# commit never attests, and neither does the PR body.
#
# Usage:
#   attest-trailers.sh range   <base> <head> [--only platforms|security]
#   attest-trailers.sh pr-json <commits.json> <files.txt> [--only platforms|security]
#   attest-trailers.sh needs   < files        # prints the kinds the file list needs
#
# Output (stdout): per kind `ATTEST <kind> needed found: <line>`,
# `ATTEST <kind> needed missing` or `ATTEST <kind> not-needed`, then
# `ATTEST PASS` or `ATTEST FAIL missing=<kinds>`; on exit 2 one `ATTEST ERROR <reason>`.
# Exit: 0 pass, 1 a needed trailer is missing, 2 cannot evaluate.
#
# The regexes hold no backslash escape: BSD grep (macOS) reads `\b` as a literal `b`.

ATTEST_PLATFORM_RE='(linux|windows|macos|ubuntu|debian|fedora|arch|mac|darwin|wsl|posix|gitbash|git-bash|powershell|pwsh)'
ATTEST_PLATFORMS_RE="^[[:space:]]*Platforms tested:[[:space:]]*${ATTEST_PLATFORM_RE}([^[:alnum:]]|$)"
ATTEST_SEC_TOKEN_RE='(manual|claude-code-security-review|pr-review-toolkit|ad-hoc)([[:space:]]|$|[.,;])'
ATTEST_SECURITY_RE="^[[:space:]]*Security reviewed:[[:space:]]*${ATTEST_SEC_TOKEN_RE}"
# shellcheck disable=SC2034  # read by the sourcing hook (check-security-reviewed.sh), not here
ATTEST_SEC_TRAILER_RE='^[[:space:]]*Security reviewed:'

# attest_files <kind>: a newline-separated file list on stdin, the files of that
# class on stdout. platforms = shell/script files (Markdown and text under
# scripts/ are never scripts); security = anything outside docs.
attest_files() {
    local list step
    list=$(cat)
    case "${1:-}" in
        platforms)
            step=$(printf '%s\n' "$list" | _attest_grep -Ev '\.(md|txt)$') || return 2
            printf '%s\n' "$step" | _attest_grep -E '(\.(sh|bash|zsh|ps1|psm1|psd1|cmd|bat)$|^scripts/|(^|/)bin/[^/]+$)' ;;
        security) printf '%s\n' "$list" | _attest_grep -Ev '\.(md|txt)$|^docs/|^handovers/' ;;
        *) return 2 ;;
    esac
}

_attest_grep() {
    local out rc=0
    out=$(grep "$@") || rc=$?
    if [ "$rc" -gt 1 ]; then
        return 2
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
    fi
    return 0
}

# attest_needs: a file list on stdin, the needed kinds (one per line) on stdout; rc 2 when the
# list cannot be classified.
attest_needs() {
    local list k out
    list=$(cat)
    for k in platforms security; do
        out=$(attest_files "$k" <<<"$list") || return 2
        if [ -n "$out" ]; then
            printf '%s\n' "$k"
        fi
    done
}

attest_re() {
    case "${1:-}" in
        platforms) printf '%s' "$ATTEST_PLATFORMS_RE" ;;
        security) printf '%s' "$ATTEST_SECURITY_RE" ;;
        *) return 2 ;;
    esac
}

# attest_found <kind>: commit messages on stdin; rc 0 when a conforming trailer line
# of that kind is present. A here-string, never a pipe into `grep -q` (the early exit of
# grep -q SIGPIPEs the writer past the pipe buffer).
attest_found() {
    local re msgs
    re=$(attest_re "${1:-}") || return 2
    msgs=$(cat)
    grep -qiE "$re" <<<"$msgs"
}

attest_found_line() {
    local re msgs
    re=$(attest_re "${1:-}") || return 2
    msgs=$(cat)
    grep -m1 -iE "$re" <<<"$msgs" | sed 's/^[[:space:]]*//'
}

# attest_sec_near_miss <value>: rc 0 when the lower-cased trailer value starts with an
# accepted token but fails the token-end anchor (`manually` is not `manual`).
attest_sec_near_miss() {
    case "${1:-}" in
        manual*|claude-code-security-review*|pr-review-toolkit*|ad-hoc*) return 0 ;;
    esac
    return 1
}

_attest_error() {
    printf 'ATTEST ERROR %s\n' "$1"
}

_attest_verdict() {
    local only="$1" files="$2" msgs="$3" k needs missing="" line is_needed nl
    nl=$'\n'
    needs=$(attest_needs <<<"$files") || { _attest_error "cannot classify the changed files"; return 2; }
    for k in platforms security; do
        if [ -n "$only" ] && [ "$only" != "$k" ]; then
            continue
        fi
        case "${nl}${needs}${nl}" in *"${nl}${k}${nl}"*) is_needed=1 ;; *) is_needed=0 ;; esac
        if [ "$is_needed" -eq 0 ]; then
            printf 'ATTEST %s not-needed\n' "$k"
        elif attest_found "$k" <<<"$msgs"; then
            line=$(attest_found_line "$k" <<<"$msgs")
            printf 'ATTEST %s needed found: %s\n' "$k" "$line"
        else
            printf 'ATTEST %s needed missing\n' "$k"
            missing="${missing:+$missing,}$k"
        fi
    done
    if [ -z "$missing" ]; then
        echo "ATTEST PASS"
        return 0
    fi
    echo "ATTEST FAIL missing=$missing"
    return 1
}

_attest_range() {
    local base="$1" head="$2" only="$3" files msgs
    files=$(git diff --name-only "${base}...${head}" 2>/dev/null) || { _attest_error "cannot compute the diff ${base}...${head} (no merge base or a git error)"; return 2; }
    msgs=$(git log --no-merges --format=%B "${base}..${head}" 2>/dev/null) || { _attest_error "cannot read the commits ${base}..${head}"; return 2; }
    _attest_verdict "$only" "$files" "$msgs"
}

_attest_pr_json() {
    local commits_file="$1" files_file="$2" only="$3" files msgs
    [ -r "$commits_file" ] || { _attest_error "cannot read the commits file $commits_file"; return 2; }
    [ -r "$files_file" ] || { _attest_error "cannot read the files file $files_file"; return 2; }
    jq -e 'type == "array"' "$commits_file" >/dev/null 2>&1 || { _attest_error "the commits file is not a JSON array"; return 2; }
    jq -e 'all(.[]; (.parents.totalCount | type) == "number")' "$commits_file" >/dev/null 2>&1 || { _attest_error "a commit in the commits file has no numeric parents.totalCount"; return 2; }
    files=$(cat "$files_file")
    [ -n "$files" ] || { _attest_error "the PR file list is empty"; return 2; }
    msgs=$(jq -r '.[] | select(.parents.totalCount <= 1) | (.messageHeadline // "") + "\n\n" + (.messageBody // "") + "\n"' "$commits_file" 2>/dev/null) || { _attest_error "cannot read the commit messages from the commits file"; return 2; }
    _attest_verdict "$only" "$files" "$msgs"
}

_attest_only() {
    case $# in
        0) return 0 ;;
        2) [ "$1" = "--only" ] || return 2
           case "$2" in platforms|security) printf '%s' "$2" ;; *) return 2 ;; esac ;;
        *) return 2 ;;
    esac
}

_attest_main() {
    local cmd="${1:-}" only rc=0
    case "$cmd" in
        range)
            [ $# -ge 3 ] || { _attest_error "usage: range <base> <head> [--only platforms|security]"; return 2; }
            only=$(_attest_only "${@:4}") || { _attest_error "usage: range <base> <head> [--only platforms|security]"; return 2; }
            _attest_range "$2" "$3" "$only" || rc=$?
            return "$rc" ;;
        pr-json)
            [ $# -ge 3 ] || { _attest_error "usage: pr-json <commits.json> <files.txt> [--only platforms|security]"; return 2; }
            only=$(_attest_only "${@:4}") || { _attest_error "usage: pr-json <commits.json> <files.txt> [--only platforms|security]"; return 2; }
            _attest_pr_json "$2" "$3" "$only" || rc=$?
            return "$rc" ;;
        needs)
            attest_needs || return 2
            return 0 ;;
        *)
            _attest_error "usage: attest-trailers.sh range|pr-json|needs ..."
            return 2 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _attest_main "$@"
    exit $?
fi
