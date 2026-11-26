#!/usr/bin/env bash
# PreToolUse hook (WebSearch, WebFetch): refuse a call whose query or URL holds a GitHub-token-shaped string.
# A web query leaves the station, so a token-shaped string typed into one is out of the machine at once, real
# or invented (a judge once pasted an invented ghr_ string into a search). The built-in regex below is the
# gitleaks GitHub rules and always applies; the regex in the checkout's detect-token-in-output.sh is read as
# extra coverage only, so a checkout can widen the guard and never narrow it (a suite row pins the built-in
# regex to the detector). No checksum or entropy test: an invented token is refused too.
# Hook I/O: the tool-call JSON on stdin. Exit 0 allows; exit 2 refuses and stderr is shown to Claude.
# The text is also checked with its %XX escapes decoded (a URL the destination decodes).
# Fence, so it fails CLOSED on its own parse problems: bad JSON scans the raw input; with no jq the raw input
# is scanned and a JSON escape of a printable ASCII character (which could hide a token) is refused outright.
# Bash 3.2-compatible.
set -uo pipefail

[ "${WEB_TOKEN_QUERY_OK:-0}" = "1" ] && exit 0

default_re='(gh[opusr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{82})'
extra_re=""
detector="${CLAUDE_PROJECT_DIR:-.}/scripts/hooks/detect-token-in-output.sh"
if [ -r "$detector" ]; then
    while IFS= read -r line; do
        case "$line" in "tok_re='"*"'") extra_re="${line#tok_re=\'}"; extra_re="${extra_re%\'}"; break ;; esac
    done <"$detector"
fi

deny() {
    printf 'BLOCKED: block-token-shaped-web-query: this %s call %s. A web query leaves the station, so a credential-shaped string never goes into one, real or invented. Describe the shape in words (for example "ghr_ prefix, then 36 alphanumerics") and search again. Bypass (operator only): relaunch from a shell with WEB_TOKEN_QUERY_OK=1.\n' \
        "$(printf '%s' "$input" | jq -r '.tool_name // "web"' 2>/dev/null || printf web)" "$1" >&2
    exit 2
}

percent_decode() {
    local rest="$1" out="" ch pct_re='^([^%]*)%([0-9A-Fa-f]{2})(.*)$'
    while [[ $rest =~ $pct_re ]]; do
        printf -v ch '%b' "\\x${BASH_REMATCH[2]}"
        out="${out}${BASH_REMATCH[1]}${ch}"
        rest="${BASH_REMATCH[3]}"
    done
    printf '%s' "${out}${rest}"
}

input=$(cat 2>/dev/null) || input=""
scan=""
if command -v jq >/dev/null 2>&1; then
    scan=$(printf '%s' "$input" | jq -r '[.tool_input | .. | strings] | join("\n")' 2>/dev/null) || scan=""
else
    esc_re='(^|[^\\])(\\\\)*\\u00[2-7][0-9A-Fa-f]'
    [[ $input =~ $esc_re ]] && deny "holds a JSON escape of a printable character, which cannot be checked for a token without jq"
fi
[ -n "$scan" ] || scan=$input
decoded=$(percent_decode "$scan")

found=""
for text in "$scan" "$decoded"; do
    for re in "$default_re" "$extra_re"; do
        [ -n "$re" ] || continue
        if [[ $text =~ $re ]]; then found="${BASH_REMATCH[1]:-${BASH_REMATCH[0]}}"; break 2; fi
    done
done
[ -n "$found" ] || exit 0

kind="${found%%_*}_"
case "$found" in github_pat_*) kind="github_pat_" ;; esac
deny "holds a GitHub-token-shaped string (${kind}…)"
