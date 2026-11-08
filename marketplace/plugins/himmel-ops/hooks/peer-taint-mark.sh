#!/usr/bin/env bash
# peer-taint-mark.sh — PostToolUse and PostToolUseFailure hook (matcher "*") for
# the peer bridge: a tool result that carries a peer fence marker whose mac
# verifies taints the session, so peer-taint-gate.sh restricts it from then on.
#
# Delivered by the himmel-ops PLUGIN lane; scripts/hooks/peer-taint-mark.sh is a
# byte-identical copy for the Codex lane. Self-contained: sources nothing.
#
# Decision order:
#   1. No ~/.himmel/peer-bridge: exit 0.
#   2. No `<<<PEER-UNTRUSTED` in stdin (a fixed-string prefilter): exit 0, node never starts.
#   3. No key file ~/.config/himmel/peer-bridge/hmac.key: exit 0, nothing can verify.
#      A session_id outside ^[A-Za-z0-9-]{1,64}$, or input jq cannot read: exit 2.
#   4. Before the verifier starts, this run creates its own provisional mark
#      taint/<sid>.pending.<pid>-<rand>; the gate restricts on any such file. Then:
#        verifier exit 0 with `verified`: touch taint/<sid>, then remove only this run's file;
#        verifier exit 1 with `unverified`: remove only this run's file (an unverified copy of the
#          marker, such as a send text or a doc, taints nothing; this is no clear);
#        anything else (a crash, the verifier's 5 s timer, node unresolvable, a
#          kill of this hook): the file stays, and the session stays restricted
#          until untaint.sh or /clear ends it.
#
# The verifier is peer-marker.mjs beside this file, else the plugin copy; node runs
# through run-node.sh beside this file, else scripts/lib/run-node.sh.
#
# Bash 3.2-compatible.

S="${HOME:-}/.himmel/peer-bridge"
C="${HOME:-}/.config/himmel/peer-bridge"
[ -d "$S" ] || exit 0

input=$(cat; printf x)
input=${input%x}
case "$input" in *'<<<PEER-UNTRUSTED'*) ;; *) exit 0 ;; esac # guard:prefilter
KEY="$C/hmac.key"
[ -f "$KEY" ] || exit 0

if ! sid=$(jq -r '.session_id // "" | if type == "string" then . else error("type") end' <<<"$input" 2>/dev/null); then # swallow-ok: a failed read exits 2 below
    echo "peer-taint-mark: unreadable hook input" >&2
    exit 2
fi
[ -n "$sid" ] || exit 0
case "$sid" in *[!A-Za-z0-9-]*) echo "peer-taint-mark: invalid session_id" >&2; exit 2 ;; esac
[ "${#sid}" -le 64 ] || { echo "peer-taint-mark: invalid session_id" >&2; exit 2; }

if [ ! -d "$S/taint" ]; then mkdir -m 700 "$S/taint" 2>/dev/null || [ -d "$S/taint" ] || exit 2; fi
own="$S/taint/$sid.pending.$$-$RANDOM$RANDOM" # guard:pername
: > "$own" || exit 2

here=$(cd "$(dirname "$0")" && pwd -P)
marker="$here/peer-marker.mjs"
[ -f "$marker" ] || marker="$here/../../marketplace/plugins/himmel-ops/hooks/peer-marker.mjs"
runner="$here/run-node.sh"
[ -f "$runner" ] || runner="$here/../lib/run-node.sh"
[ -f "$runner" ] || exit 0

rc=0
out=""
out=$(printf '%s' "$input" | command -p sh "$runner" "$marker" verify --key-file "$KEY" 2>/dev/null) || rc=$? # swallow-ok: rc and out both decide; any unknown outcome keeps the mark
case "$rc:$out" in
    0:verified) : > "$S/taint/$sid" && rm -f "$own" ;;
    1:unverified) rm -f "$own" ;; # guard:undo
    *) : ;; # guard:keep
esac
exit 0
