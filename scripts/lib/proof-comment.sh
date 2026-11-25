#!/usr/bin/env bash
# scripts/lib/proof-comment.sh - put one live proof result on its ticket as the
# machine-readable line a gate reads by owed row id:
#   PROOF <row-id> PASS|FAIL <YYYY-MM-DD> <artifact>
#
# Usage: proof-comment.sh <KEY> <row-id> PASS|FAIL <YYYY-MM-DD> <artifact>
#
# <row-id> is an owed row id (o1, o2, ...); <artifact> is one word (a path or doc:line, letters,
# digits and . _ / : # @ = + , % ~ -). The comment is read back from the ticket before the call
# succeeds, and a line already there is not posted twice, so a retry never duplicates it.
# OWE_JIRA_CLI replaces the Jira CLI (tests); by default it is the anchor checkout's
# scripts/jira/dist/index.js.
#
# Exit codes: 0 the line is on the ticket, 2 usage or a refused value, 5 the comment could not
# be read, posted or found again.
#
# Platform guard: POSIX bash 3.2+.
set -u

if [ "$#" -ne 5 ]; then
    echo "usage: proof-comment.sh <KEY> <row-id> PASS|FAIL <YYYY-MM-DD> <artifact>" >&2
    exit 2
fi
KEY="$1"; ROW="$2"; RESULT="$3"; DAY="$4"; ART="$5"
[[ $KEY =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || { echo "proof-comment: '$KEY' is not a ticket key" >&2; exit 2; }
[[ $ROW =~ ^o[1-9][0-9]*$ ]] || { echo "proof-comment: '$ROW' is not an owed row id (o1, o2, ...)" >&2; exit 2; }
case "$RESULT" in PASS|FAIL) ;; *) echo "proof-comment: the result is PASS or FAIL, not '$RESULT'" >&2; exit 2 ;; esac
[[ $DAY =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "proof-comment: '$DAY' is not a YYYY-MM-DD date" >&2; exit 2; }
[[ $ART =~ ^[A-Za-z0-9._/:#@=+,%~-]+$ ]] || { echo "proof-comment: the artifact is one word (a path or doc:line), not '$ART'" >&2; exit 2; }
LINE="PROOF $ROW $RESULT $DAY $ART"

cli="${OWE_JIRA_CLI:-}"
if [ -z "$cli" ]; then
    kit="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    common=""
    if . "$kit/git-clean.sh" 2>/dev/null; then
        if ! common="$(git_clean -C "$kit" rev-parse --path-format=absolute --git-common-dir)"; then common=""; fi
    fi
    [ -n "$common" ] && cli="$(dirname "$common")/scripts/jira/dist/index.js"
fi
[ -n "$cli" ] && [ -e "$cli" ] || { echo "proof-comment: no Jira CLI to post $LINE on $KEY" >&2; exit 5; }
jira() {
    case "$cli" in
        *.js) JIRA_PROJECT_KEY="${KEY%%-*}" node "$cli" "$@" ;;
        *) JIRA_PROJECT_KEY="${KEY%%-*}" "$cli" "$@" ;;
    esac
}

pattern="(^|[[:space:]])$(printf '%s' "$LINE" | sed 's/[][\.*^$+?(){}|/]/\\&/g')([[:space:]]|\$)"
present() {
    local seen
    if ! seen="$(jira comments "$KEY")"; then return 2; fi
    grep -Eq -- "$pattern" <<< "$seen"
}

present; rc=$?
[ "$rc" -ne 2 ] || { echo "proof-comment: cannot read the comments of $KEY" >&2; exit 5; }
if [ "$rc" -ne 0 ]; then
    jira comment "$KEY" "$LINE" >/dev/null 2>&1 || { echo "proof-comment: the comment on $KEY was refused: $LINE" >&2; exit 5; }
    present || { echo "proof-comment: $LINE is not on $KEY after the post" >&2; exit 5; }
fi
echo "proof-comment: $KEY carries: $LINE"
