#!/usr/bin/env bash
# afk-denied-to-request.sh — PermissionDenied hook: while the operator is away, a Bash call the
# auto-mode classifier refused is filed as ONE run-kind request from the refused call's own
# bytes, so the away operator gets a Telegram code request without the session having to issue
# an `afk-run` call (which the classifier also refuses, as an auto-mode bypass).
#
#   afk-run --no-wait --session S --ticket T --blocked-by classifier --cwd D \
#           --why "classifier refused: <category>" -- ARGV
#
# Filing only queues the request. Root freezes the argv, binds the files, applies the
# never-remote floor and sends the facts and the nonce through its notice bot; it runs the
# command once, as the operator's user, only after the operator's `NONCE CODE`. Nothing runs here.
# Root also caps these requests (2 an hour, never the last free hourly request or pending slot)
# and refuses the same argv from the same session while an earlier one is pending or in its ttl.
#
# The on/off source is the root helper alone: `sudo -n /usr/local/libexec/himmel/afk-sudo mode`
# must answer `enabled=true`, `run_enabled=true` and `classifier_requests=true` (the root config
# flag the operator sets when going away; nothing user-writable turns it on), and
# `grant_enabled=false` (with the grant kind on, approval-grant-request.sh owns the refusal).
# Anything else (helper absent, sudo refused, the station off or locked down, the run kind or the
# flag off): no helper request, no output, exit 0, exactly as before this hook.
#
# What files: only a real refusal, whose reason carries a bracketed classifier category
# (`[Unauthorized Persistence]`); "Classifier unavailable" and no-verdict denials carry none.
# Never toward Telegram before approval: a command that matches a redact() shape
# (scripts/lib/redact.sh) or a credential or exfiltration category files nothing, and the free-text
# reason is never passed, only the category.
#
# The argv rule is afk-prompt-to-request.sh's: a plain command (words of [A-Za-z0-9_./:=@%+,-]
# only, the first an executable on PATH, not an assignment, builtin, keyword, alias or function)
# is its own argv; anything else is `bash -c <the exact command bytes>`. A command any of whose
# words is an `afk-run` path is skipped, so a refused afk-run does not become a request to run
# afk-run as the operator. That skip is best-effort: a word scan, not a parse, so a computed or
# aliased path is not seen (root's checks and the operator's code still apply to it).
#
# PermissionDenied can only return `retry`, and no text reaches the model, so the refused session
# is not told the request id (accepted residual). It never sets `retry`: a retry is only refused
# again. Prints nothing and exits 0 on every path.
#
# Bypass: AFK_DENIED_TO_REQUEST_OFF=1 in the launching shell files nothing.
# Input: PermissionDenied JSON on stdin. Bash 3.2-compatible.
set -uo pipefail
trap 'exit 0' EXIT

[ "${AFK_DENIED_TO_REQUEST_OFF:-}" = 1 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
{ [ -r "$here/../lib/git-clean.sh" ] && . "$here/../lib/git-clean.sh"; } 2>/dev/null || exit 0  # swallow-ok: fail-open hook, no request on error
{ [ -r "$here/../lib/redact.sh" ] && . "$here/../lib/redact.sh"; } 2>/dev/null || exit 0  # swallow-ok: no secret check, no request
input=""
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' ends at EOF with rc 1
[ -n "$input" ] || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0  # swallow-ok: fail-open hook, no request on error
[ "$tool" = "Bash" ] || exit 0
# The exact bytes, trailing newlines too (the x guard keeps $(...) from stripping them).
cmd="$(printf '%s' "$input" | jq -j '.tool_input.command | if type == "string" then . else "" end' 2>/dev/null && printf x)" || exit 0  # swallow-ok: fail-open hook, no request on error
cmd=${cmd%x}
[ -n "$cmd" ] || exit 0

reason="$(printf '%s' "$input" | jq -r '.reason // ""' 2>/dev/null)" || exit 0  # swallow-ok: fail-open hook, no request on error
category="$(printf '%s' "$reason" | grep -oE '\[[A-Za-z][A-Za-z -]*\]' | sed -n '1s/^\[\(.*\)\]$/\1/p')"
[ -n "$category" ] || exit 0
case "$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')" in
    *credential* | *exfiltrat* | *secret* | *token*) exit 0 ;;
esac
[ "$(redact "$cmd")" = "$(printf '%s' "$cmd")" ] || exit 0

set -f  # the words are only compared, never globbed
for w in $(printf '%s' "$cmd" | tr ';&|()<>`"'"'"'' '          '); do
    case "${w##*/}" in afk-run) exit 0 ;; esac
done
set +f

mode="$(sudo -n /usr/local/libexec/himmel/afk-sudo mode 2>/dev/null | sed -n 1p)" || exit 0  # swallow-ok: no helper or sudo refused = off, nothing filed
case " $mode " in *" enabled=true "*) ;; *) exit 0 ;; esac
case " $mode " in *" run_enabled=true "*) ;; *) exit 0 ;; esac
case " $mode " in *" classifier_requests=true "*) ;; *) exit 0 ;; esac  # fail-open-ok: any answer but an exact classifier_requests=true files nothing
case " $mode " in *" grant_enabled=false "*) ;; *) exit 0 ;; esac

session="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0  # swallow-ok: fail-open hook, no request on error
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0  # swallow-ok: fail-open hook, no request on error
[ -n "$session" ] || session=unknown
[ -n "$cwd" ] || cwd=$PWD
ticket="$(git_clean -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null | grep -o '[A-Za-z][A-Za-z0-9]*-[0-9][0-9]*' | sed -n 1p | tr '[:lower:]' '[:upper:]')"  # swallow-ok: no branch or no ticket in it names ticket none
[ -n "$ticket" ] || ticket=none

lib="$(cd "$here/../lib" 2>/dev/null && pwd)" || exit 0  # swallow-ok: fail-open hook, no request on error
first=${cmd%% *}
if [[ $cmd =~ ^[A-Za-z0-9_./:=@%+,-]+(\ [A-Za-z0-9_./:=@%+,-]+)*$ ]] && [[ $first != *=* ]] \
    && [ "$(type -t -- "$first" 2>/dev/null)" = file ]; then  # swallow-ok: an unknown name is not a file, so it files as bash -c
    # shellcheck disable=SC2206 # the regex above admits no glob or quote character
    argv=($cmd)
else
    argv=(bash -c "$cmd")
fi

"$lib/afk-run" --no-wait --session "$session" --ticket "$ticket" --blocked-by classifier \
    --cwd "$cwd" --why "classifier refused: $category" -- "${argv[@]}" </dev/null >/dev/null 2>&1
exit 0
