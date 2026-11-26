#!/usr/bin/env bash
# scripts/t3/relay-launch.sh - print the launch block for ONE on-demand slim T3 relay, refusing a second live relay.
#
# Usage: relay-launch.sh [--brief <file>] [--title <title>]
# The chief sends the block through the guarded mcp__t3-code__ launch tool; this script never starts, sends to or
# settles a thread: its only T3 call is the read-only `thread list`.
# The block is `provider:`, `model:`, `title:`, `project:` and `brief:` lines, then `--- first message ---` and the
# brief verbatim (the thread's first message). The provider is claudeAgent_t3-relay, the instance
# provider-instances.sh generates from the `t3-relay` registry profile (docs/internals/t3-relay.md).
# Brief default: the one specs/status/t3-relay-brief.md under $HANDOVER_DIR/<user>/<project>/ (none or several: pass --brief).
# Live relay: a thread with the relay's exact title that is not settled.
# rc 0 block printed; rc 2 usage or unreadable brief; rc 3 a relay is already live (its id is printed, no block);
# rc 4 `thread list` failed, printed no JSON array, or could not be read, so "no live relay" is unproven and nothing is printed.
# Env seams: T3_SEND_BIN (default $HOME/.t3/bin/t3), T3_SEND_PROJECT (default: this repo's root),
# T3_RELAY_MODEL (default claude-sonnet-5-5).
# Platform: POSIX bash 3.2+, jq.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN="${T3_SEND_BIN:-$HOME/.t3/bin/t3}"
PROJECT="${T3_SEND_PROJECT:-$(cd "$HERE/../.." && pwd -P)}"
MODEL="${T3_RELAY_MODEL:-claude-sonnet-5-5}"
PROVIDER="claudeAgent_t3-relay"
TITLE="T3 relay (slim)"
BRIEF=""
die() { echo "relay-launch: $2" >&2; exit "$1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --brief) [ $# -ge 2 ] || die 2 "--brief needs a path"; BRIEF="$2"; shift 2 ;;
        --title) [ $# -ge 2 ] || die 2 "--title needs a value"; TITLE="$2"; shift 2 ;;
        *) die 2 "usage: relay-launch.sh [--brief <file>] [--title <title>] (got '$1')" ;;
    esac
done
[ -n "$TITLE" ] || die 2 "empty title"
command -v jq >/dev/null 2>&1 || die 2 "jq is required"

if [ -z "$BRIEF" ]; then
    n=0
    for f in "${HANDOVER_DIR:-/nonexistent}"/*/*/specs/status/t3-relay-brief.md; do
        [ -f "$f" ] || continue
        n=$((n + 1)); BRIEF="$f"
    done
    [ "$n" -eq 1 ] || die 2 "found $n specs/status/t3-relay-brief.md under HANDOVER_DIR; pass --brief <file>"
fi
{ [ -f "$BRIEF" ] && [ -r "$BRIEF" ]; } || die 2 "brief not readable: $BRIEF"

LIST="$("$BIN" thread list --json --project "$PROJECT" 2>&1)" || die 4 "thread list failed, cannot prove no relay is live: $LIST"
printf '%s' "$LIST" | jq -e 'type == "array"' >/dev/null 2>&1 || die 4 "thread list did not print a JSON array"
LIVE="$(printf '%s' "$LIST" | jq -r --arg t "$TITLE" '.[] | select(((.title // "") | gsub("^\\s+|\\s+$"; "")) == $t and (.settled // false) != true) | "\(.threadId) [\(.status // "?")]"')" \
    || die 4 "could not read the thread list"
if [ -n "$LIVE" ]; then
    echo "relay-launch: a relay is already live, refusing a second:" >&2
    printf '  %s\n' "$LIVE" >&2
    exit 3
fi

printf 'provider: %s\nmodel: %s\ntitle: %s\nproject: %s\nbrief: %s\n--- first message ---\n' "$PROVIDER" "$MODEL" "$TITLE" "$PROJECT" "$BRIEF"
cat "$BRIEF"
