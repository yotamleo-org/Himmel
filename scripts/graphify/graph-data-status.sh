#!/usr/bin/env bash
# graph-data-status.sh -- is the graph-data branch behind the live graph? One
# definition, used by graph-cadence.sh (publish decision and lag alert) and
# himmel-doctor.sh (C70-graph-data).
#
# Reads only local refs: the remote-tracking ref refs/remotes/<remote>/graph-data
# (no fetch) and the live <out>/graph.json built_at_commit. The tip's
# built_at_commit is the first line of the tip commit's built_at_commit file.
#
# Usage:
#   graph-data-status.sh --repo <git checkout> --out <graphify-out dir>
#                        [--remote <name>] [--max-age-days N] [--pause-marker <path>]
#   --remote defaults to origin, --max-age-days to 2. --pause-marker names the
#   operator's semantic-pause file; it is only tested for existence.
#
# Prints one line, "graph-data: <STATE> ...", and exits:
#   0 OK      the tip was built at the live graph's commit, or the live graph is
#             not a descendant of it (nothing newer to publish)
#   1 LAG     the live graph is newer and the tip is older than the bound; the
#             line ends "; cause: <why>"
#   2 UNKNOWN no live graph, or its build commit cannot be compared; also a
#             usage error (no stdout line then)
#   4 NEWER   the live graph is newer than the tip (or there is no tip yet) and
#             the tip is within the bound
# Every NEWER and LAG line says whether the live graph carries a semantic layer
# (a semantic-manifest.json with at least one stamped file): only such a graph
# can be published to graph-data.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="" OUT="" REMOTE="origin" MAX_AGE_DAYS=2 MARKER=""
usage() { echo "usage: graph-data-status.sh --repo <git checkout> --out <graphify-out dir> [--remote <name>] [--max-age-days N] [--pause-marker <path>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
        --out) [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
        --remote) [ $# -ge 2 ] || usage; REMOTE="$2"; shift 2 ;;
        --max-age-days) [ $# -ge 2 ] || usage; MAX_AGE_DAYS="$2"; shift 2 ;;
        --pause-marker) [ $# -ge 2 ] || usage; MARKER="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "graph-data-status: unknown argument '$1'" >&2; usage ;;
    esac
done
[ -n "$REPO" ] && [ -n "$OUT" ] || usage
case "$MAX_AGE_DAYS" in ''|*[!0-9]*) echo "graph-data-status: --max-age-days must be a non-negative integer" >&2; usage ;; esac

g() { git -C "$REPO" "$@"; }
resolves() { [ -n "$1" ] && g cat-file -e "$1^{commit}" 2>/dev/null; }

fmt_age() {
    local s="$1" d h
    [ "$s" -ge 0 ] 2>/dev/null || s=0
    d=$((s / 86400)); h=$(((s % 86400) / 3600))
    if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"; else printf '%dh' "$h"; fi
}

LIVE_BAC="$(bash "$HERE/check-graph-freshness.sh" --out "$OUT" --print-built-at 2>/dev/null)" || LIVE_BAC=""
if [ -z "$LIVE_BAC" ]; then
    echo "graph-data: UNKNOWN no live graph at $OUT"
    exit 2
fi
LIVE7="${LIVE_BAC:0:7}"

SEM=no
if python3 -c 'import json,sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if isinstance(m, dict) and isinstance(m.get("files"), dict) and m["files"] else 1)' "$OUT/semantic-manifest.json" 2>/dev/null; then
    SEM=yes
fi

TIP="$(g rev-parse --verify -q "refs/remotes/$REMOTE/graph-data" 2>/dev/null)" || TIP=""
if [ -z "$TIP" ]; then
    echo "graph-data: NEWER no graph-data tip on $REMOTE yet; live graph built at $LIVE7; semantic layer: $SEM"
    exit 4
fi
TIP_BAC="$(g show "$TIP:built_at_commit" 2>/dev/null | head -n 1 | tr -d '[:space:]')" || TIP_BAC=""
TIP7="${TIP_BAC:0:7}"
TIP_CT="$(g show -s --format=%ct "$TIP" 2>/dev/null)" || TIP_CT=""
AGE_S=0
[ -z "$TIP_CT" ] || AGE_S=$(($(date +%s) - TIP_CT))
AGE="$(fmt_age "$AGE_S")"

if ! resolves "$LIVE_BAC"; then
    echo "graph-data: UNKNOWN live graph built at $LIVE7, which is not a commit in $REPO"
    exit 2
fi

NEWER=0
if [ "$LIVE_BAC" = "$TIP_BAC" ]; then
    NEWER=0
elif ! resolves "$TIP_BAC"; then
    NEWER=1
elif g merge-base --is-ancestor "$TIP_BAC" "$LIVE_BAC" 2>/dev/null; then
    [ "$(g rev-parse "$TIP_BAC^{commit}")" = "$(g rev-parse "$LIVE_BAC^{commit}")" ] || NEWER=1
fi

if [ "$NEWER" -eq 0 ]; then
    echo "graph-data: OK tip built at $TIP7, $AGE old; live graph built at $LIVE7"
    exit 0
fi

if [ "$AGE_S" -le $((10#$MAX_AGE_DAYS * 86400)) ]; then
    echo "graph-data: NEWER live graph built at $LIVE7 is newer than the graph-data tip (built at $TIP7, $AGE old); semantic layer: $SEM"
    exit 4
fi

CAUSE=""
if [ -n "$MARKER" ] && [ -e "$MARKER" ]; then
    CAUSE="the semantic step is paused ($MARKER exists; only the operator removes it)"
fi
if [ "$SEM" = no ]; then
    CAUSE="${CAUSE:+$CAUSE; }the live graph carries no semantic layer, so there is nothing to publish"
fi
[ -n "$CAUSE" ] || CAUSE="the cadence has not published it (read the cadence log)"
echo "graph-data: LAG the graph-data tip (built at $TIP7) is $AGE old (bound ${MAX_AGE_DAYS}d) while the live graph is built at $LIVE7 (semantic layer: $SEM); cause: $CAUSE"
exit 1
