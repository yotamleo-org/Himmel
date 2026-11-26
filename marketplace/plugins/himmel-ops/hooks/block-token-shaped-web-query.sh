#!/usr/bin/env bash
# PreToolUse hook (WebSearch, WebFetch): refuse a call whose query or URL holds a GitHub-token-shaped string.
# A web query leaves the station, so a token-shaped string typed into one is out of the machine at once, real
# or invented (a judge once pasted an invented ghr_ string into a search). The shape is the
# gitleaks GitHub rules, read from detect-token-in-output.sh so the two never drift; the copy below is used
# when the checkout has no such file, and ALSO when the file's regex is invalid or fails to match a canary of
# each of the six prefixes (a checkout is not trusted to narrow the guard); a suite row pins the copy to the
# detector. No checksum or entropy test: an invented token is refused too.
# Hook I/O: the tool-call JSON on stdin. Exit 0 allows; exit 2 refuses and stderr is shown to Claude.
# The text is also checked with its %XX escapes decoded (a URL the destination decodes).
# Fence, so it fails CLOSED on its own parse problems: bad JSON scans the raw input; with no jq the raw input
# is scanned and a JSON escape of a printable ASCII character (which could hide a token) is refused outright.
# Bash 3.2-compatible.
set -uo pipefail

[ "${WEB_TOKEN_QUERY_OK:-0}" = "1" ] && exit 0

default_re='(gh[opusr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{82})'
tok_re="$default_re"
detector="${CLAUDE_PROJECT_DIR:-.}/scripts/hooks/detect-token-in-output.sh"
if [ -r "$detector" ]; then
    cand=""
    while IFS= read -r line; do
        case "$line" in "tok_re='"*"'") cand="${line#tok_re=\'}"; cand="${cand%\'}"; break ;; esac
    done <"$detector"
    if [ -n "$cand" ]; then
        a36="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        a82="${a36}${a36}aaaaaaaaaa"
        ok=1
        for l in o p u s r; do
            canary="gh${l}_${a36}"
            [[ $canary =~ $cand ]] || ok=0
        done
        canary="github_pat_${a82}"
        [[ $canary =~ $cand ]] || ok=0
        [ "$ok" = 1 ] && tok_re="$cand"
    fi
fi

deny() {
    printf 'BLOCKED: block-token-shaped-web-query: this %s call %s. A web query leaves the station, so a credential-shaped string never goes into one, real or invented. Describe the shape in words (for example "ghr_ prefix, then 36 alphanumerics") and search again. Bypass (operator only): relaunch from a shell with WEB_TOKEN_QUERY_OK=1.\n' \
        "$(printf '%s' "$input" | jq -r '.tool_name // "web"' 2>/dev/null || printf web)" "$1" >&2
    exit 2
}

input=$(cat 2>/dev/null) || input=""
scan=""
if command -v jq >/dev/null 2>&1; then
    scan=$(printf '%s' "$input" | jq -r '[.tool_input | .. | strings] | join("\n")' 2>/dev/null) || scan=""
else
    esc_re='\\u00[2-7][0-9A-Fa-f]'
    [[ $input =~ $esc_re ]] && deny "holds a JSON escape of a printable character, which cannot be checked for a token without jq"
fi
[ -n "$scan" ] || scan=$input

decoded=$(printf '%b' "${scan//\%/\\x}" 2>/dev/null) || decoded=""
[[ $scan =~ $tok_re ]] || [[ $decoded =~ $tok_re ]] || exit 0

kind="${BASH_REMATCH[1]%%_*}_"
case "${BASH_REMATCH[1]}" in github_pat_*) kind="github_pat_" ;; esac
deny "holds a GitHub-token-shaped string (${kind}…)"
