#!/usr/bin/env bash
# peer-taint-resume.sh — SessionStart hook for the peer bridge: a session resumed
# (or forked) from a transcript that holds a verified peer fence marker starts
# tainted, so peer-taint-gate.sh restricts it from its first call.
#
# Delivered by the himmel-ops PLUGIN lane; scripts/hooks/peer-taint-resume.sh is a
# byte-identical copy for the Codex lane. Self-contained: sources nothing.
#
# Only `source: resume` is checked. The decision is peer-taint-mark.sh's, over
# the transcript at transcript_path instead of the tool output: no bridge dir,
# no key file, or a transcript grep reads with no marker text in it (a
# fixed-string prefilter) exits 0; an invalid session_id or unreadable input
# exits 2; a transcript it cannot inspect keeps a provisional mark; otherwise this run
# creates its own taint/<sid>.pending.<pid>-<rand>, then verifier exit 0 with `verified`
# touches taint/<sid> and removes it, exit 1 with `unverified` removes it, and any other outcome keeps it.
#
# Fail direction: toward taint; it never blocks a session start. Bypass: none, it
# only marks; a human clears a mark with scripts/peer-bridge/untaint.sh <session_id>.
#
# Bash 3.2-compatible.

S="${HOME:-}/.himmel/peer-bridge"
C="${HOME:-}/.config/himmel/peer-bridge"
[ -d "$S" ] || exit 0

input=$(cat) || { echo "peer-taint-resume: unreadable hook input" >&2; exit 2; }
if ! fields=$(jq -r '[.session_id // "", .source // "", .transcript_path // ""] | map(if type == "string" then . else error("type") end) | @sh "sid=\(.[0]) src=\(.[1]) tp=\(.[2])"' <<<"$input" 2>/dev/null); then # swallow-ok: a failed read exits 2 below
    echo "peer-taint-resume: unreadable hook input" >&2
    exit 2
fi
sid="" src="" tp=""
eval "$fields"
[ "$src" = resume ] || exit 0
KEY="$C/hmac.key"
[ -f "$KEY" ] || exit 0
[ -n "$sid" ] || exit 0
case "$sid" in *[!A-Za-z0-9-]*) echo "peer-taint-resume: invalid session_id" >&2; exit 2 ;; esac
[ "${#sid}" -le 64 ] || { echo "peer-taint-resume: invalid session_id" >&2; exit 2; }

# A transcript it cannot inspect (no path, missing, unreadable, a grep error) is
# not a clean one: only grep's own "no match" lets the session start unmarked.
scan=2
if [ -n "$tp" ] && [ -f "$tp" ] && [ -r "$tp" ]; then
    scan=0
    grep -qF '<<<PEER-UNTRUSTED' "$tp" || scan=$?
fi
if [ "$scan" = 1 ]; then exit 0; fi # guard:scan

if [ ! -d "$S/taint" ]; then mkdir -m 700 "$S/taint" 2>/dev/null || [ -d "$S/taint" ] || exit 2; fi
own="$S/taint/$sid.pending.$$-$RANDOM$RANDOM"
: > "$own" || exit 2
[ "$scan" = 0 ] || exit 0

here=$(cd "$(dirname "$0")" && pwd -P)
marker="$here/peer-marker.mjs"
[ -f "$marker" ] || marker="$here/../../marketplace/plugins/himmel-ops/hooks/peer-marker.mjs"
runner="$here/run-node.sh"
[ -f "$runner" ] || runner="$here/../lib/run-node.sh"
[ -f "$runner" ] || exit 0

rc=0
out=""
out=$(command -p sh "$runner" "$marker" verify --key-file "$KEY" < "$tp" 2>/dev/null) || rc=$? # swallow-ok: rc and out both decide; any unknown outcome keeps the mark
case "$rc:$out" in
    0:verified) : > "$S/taint/$sid" && rm -f "$own" ;;
    1:unverified) rm -f "$own" ;;
    *) : ;;
esac
exit 0
