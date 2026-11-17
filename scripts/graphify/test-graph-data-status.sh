#!/usr/bin/env bash
# test-graph-data-status.sh -- graph-data-status.sh over a temp git repo and a
# local bare remote. The graph-data tips are orphan commits built with
# hash-object/mktree/commit-tree and backdated through GIT_COMMITTER_DATE, the
# same shape publish-graph-channel.sh writes. The remote is pointed at a path
# that does not exist after the first fetch: the script must read local refs only.
#
# Rows: no live graph; no tip yet; tip built at the live commit; live newer within
# and past the bound; the age formats; the pause-marker cause; the no-semantic
# cause; both causes joined; a live graph that is not a descendant of the tip; a
# tip whose commit this checkout does not know.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/graph-data-status.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-graph-data-status.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

gw() { git -C "$WORK" -c user.email=t@test.test -c user.name=Test "$@"; }
BARE="$TMP/origin.git"
WORK="$TMP/work"
git init -q --bare "$BARE"
git init -q -b main "$WORK"
for n in 1 2 3; do
    echo "$n" > "$WORK/f"; gw add f; gw commit -q -m "c$n"
    eval "C$n=$(gw rev-parse HEAD)"
done
gw checkout -q -b side "$C1"
echo side > "$WORK/s"; gw add s; gw commit -q -m side
SIDE="$(gw rev-parse HEAD)"
gw checkout -q main
gw remote add origin "$BARE"

# push_tip <built_at_commit> <age-seconds>: one orphan commit on the bare's graph-data, then fetch.
push_tip() {
    local blob tree commit when
    blob="$(printf '%s\n' "$1" | gw hash-object -w --stdin)"
    tree="$(printf '100644 blob %s\tbuilt_at_commit\n' "$blob" | gw mktree)"
    when="$(($(date +%s) - $2))"
    commit="$(GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" gw commit-tree "$tree" -m "graph-data built at $1")"
    gw push -q -f "$BARE" "$commit:refs/heads/graph-data" || return 1
    gw fetch -q "$BARE" "+refs/heads/graph-data:refs/remotes/origin/graph-data"
}

# live <name> <built_at_commit> [semantic]: a graphify-out dir; prints its path.
live() {
    local d="$TMP/live-$1"
    mkdir -p "$d"
    printf '{"built_at_commit": "%s"}\n' "$2" > "$d/graph.json"
    [ "${3:-}" = semantic ] && printf '{"version": 1, "files": {"a.md": "%064d"}}\n' 0 > "$d/semantic-manifest.json"
    printf '%s' "$d"
}

run() { out="$(bash "$SCRIPT" --repo "$WORK" "$@" 2>&1)"; rc=$?; }
# is <name> <want-rc> <glob>: the last run's rc and its one output line
is() {
    # shellcheck disable=SC2053  # $3 is a glob on purpose
    if [ "$rc" -eq "$2" ] && [[ "$out" == $3 ]]; then pass "$1"; else fail "$1 (rc=$rc): $out"; fi
}
H=3600 D=86400

echo "S1: no live graph -> UNKNOWN, rc 2"
mkdir -p "$TMP/empty"
run --out "$TMP/empty"
is S1 2 "graph-data: UNKNOWN no live graph at $TMP/empty"

echo "S2: no graph-data tip yet -> NEWER, rc 4"
L="$(live s2 "$C3" semantic)"
run --out "$L"
is S2 4 "graph-data: NEWER no graph-data tip on origin yet; live graph built at ${C3:0:7}; semantic layer: yes"

push_tip "$C3" $((5 * H)) || fail "setup: push tip"
gw remote set-url origin "$TMP/does-not-exist"

echo "S3: the tip was built at the live commit -> OK, rc 0, age 5h"
run --out "$L"
is S3 0 "graph-data: OK tip built at ${C3:0:7}, 5h old; live graph built at ${C3:0:7}"

echo "S4: live newer than a fresh tip -> NEWER, rc 4"
push_tip "$C1" $((2 * H))
run --out "$L"
is S4 4 "graph-data: NEWER live graph built at ${C3:0:7} is newer than the graph-data tip (built at ${C1:0:7}, 2h old); semantic layer: yes"

echo "S5: live newer, tip past the bound, a semantic live graph -> LAG, rc 1, the default cause"
push_tip "$C1" $((3 * D + 4 * H))
run --out "$L"
is S5 1 "graph-data: LAG the graph-data tip (built at ${C1:0:7}) is 3d 4h old (bound 2d) while the live graph is built at ${C3:0:7} (semantic layer: yes); cause: the cadence has not published it (read the cadence log)"

echo "S6: the bound is an option"
run --out "$L" --max-age-days 4
is "S6 3d 4h is within a 4d bound" 4 "graph-data: NEWER *"

echo "S7: a pause marker names itself as the cause"
: > "$TMP/semantic.paused"
run --out "$L" --pause-marker "$TMP/semantic.paused"
is S7 1 "*cause: the semantic step is paused ($TMP/semantic.paused exists; only the operator removes it)"

echo "S8: a live graph without a semantic layer says so as the cause"
N="$(live s8 "$C3")"
run --out "$N" --pause-marker "$TMP/absent.paused"
is S8 1 "*semantic layer: no); cause: the live graph carries no semantic layer, so there is nothing to publish"
printf '{"version": 1, "files": {}}\n' > "$N/semantic-manifest.json"
run --out "$N"
is "S8 an empty files object is no semantic layer" 1 "*carries no semantic layer*"

echo "S9: both causes are joined"
run --out "$N" --pause-marker "$TMP/semantic.paused"
is S9 1 "*exists; only the operator removes it); the live graph carries no semantic layer*"

echo "S10: a live graph that is not a descendant of the tip's commit is not newer -> OK"
push_tip "$C3" $((9 * D))
SL="$(live s10 "$SIDE" semantic)"
run --out "$SL"
is S10 0 "graph-data: OK tip built at ${C3:0:7}, 9d *"

echo "S11: a tip commit this checkout does not know, with a live commit it does, is behind"
push_tip "0123456789abcdef0123456789abcdef01234567" $((3 * D))
run --out "$L"
is S11 1 "graph-data: LAG the graph-data tip (built at 0123456) is 3d 0h old*"

echo "S12: a live commit this checkout does not know cannot be compared -> UNKNOWN, rc 2"
U="$(live s12 "89abcdef0123456789abcdef0123456789abcdef" semantic)"
run --out "$U"
is S12 2 "graph-data: UNKNOWN live graph built at 89abcde, which is not a commit in *"

echo "S13: a missing --repo is a usage error"
out="$(bash "$SCRIPT" --out "$L" 2>&1)"; rc=$?
is S13 2 "*usage:*"

echo "S14: a leading-zero --max-age-days is decimal, so 08 is 8 days and a 2h tip is within it -> NEWER, rc 4"
push_tip "$C1" $((2 * H))
run --out "$L" --max-age-days 08
is "S14 08 reads as decimal" 4 "graph-data: NEWER*"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$FAILS FAILED"; exit 1; fi
