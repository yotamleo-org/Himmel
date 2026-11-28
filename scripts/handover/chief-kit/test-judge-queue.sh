#!/usr/bin/env bash
# selector: tree-scan
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SUT="$HERE/judge-queue.sh"
FX="$HERE/fixtures/judge-queue"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/judge-queue-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export TZ=UTC HIMMEL_TEST_FIXTURE=1
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333
H4=4444444444444444444444444444444444444444
SINCE=2020-01-01T00:00:00

mkdir -p "$WORK/docs"
cp "$FX"/*.md "$WORK/docs/"
D="$WORK/docs"
manifest() {
    local out="$1"; shift
    python3 -I -c 'import json,sys; json.dump({"schema":1,"workers":[{"doc":a.rsplit(":",1)[0],"label":"N%d"%i,"lane":a.rsplit(":",1)[1]} for i,a in enumerate(sys.argv[2:])]},open(sys.argv[1],"w"))' "$out" "$@"
}
field() {
    python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if str(r.get("pr")) == sys.argv[2]:
        v = r.get(sys.argv[3]); print("null" if v is None else v); break' "$1" "$2" "$3" 2>/dev/null
}
rows() { python3 -I -c 'import os, sys; p = sys.argv[1]; print(sum(1 for _ in open(p)) if os.path.isfile(p) else 0)' "$1"; }

B="$WORK/bucket"; mkdir -p "$B"
manifest "$B/old-chief.fleet.json" "$D/native.md:native" "$D/bus.md:claudex"
manifest "$B/new-chief.fleet.json" "$D/native.md:native" "$D/t3.md:t3"
printf '## Results\n\n- 14:00 LIVE JUDGE-REQUEST 6199 %s\n' "$H1" > "$D/stale.md"
manifest "$B/stale-chief.fleet.json" "$D/stale.md:native"
touch -t 201901010000 "$B/stale-chief.fleet.json"
Q="$B/judge-desk/judge-requests.jsonl"
out="$(JUDGE_QUEUE_NOW=1795789800 bash "$SUT" scan --bucket "$B" --since "$SINCE" 2>"$WORK/scan.err")"; rc=$?
eq "scan: rc 0" "$rc" 0
has "scan: the native request is queued" "$out" "QUEUED 6139 $H1"
has "scan: the bus request is queued" "$out" "QUEUED 6140 $H2"
has "scan: the successor's T3 worker is found and queued" "$out" "QUEUED 6141 $H3"
lacks "scan: a manifest unchanged since --since is not read" "$out" "6199"
eq "scan: three request rows" "$(rows "$Q")" 3
eq "row: schema 1" "$(field "$Q" 6139 schema)" 1
eq "row: kind request" "$(field "$Q" 6139 kind)" request
eq "row: the head" "$(field "$Q" 6139 head)" "$H1"
eq "row: the native lane" "$(field "$Q" 6139 lane)" native
eq "row: the bus lane" "$(field "$Q" 6140 lane)" bus
eq "row: the t3 lane" "$(field "$Q" 6141 lane)" t3
eq "row: the worker document" "$(field "$Q" 6139 worker_doc)" "$D/native.md"
eq "row: the bullet time" "$(field "$Q" 6139 bullet_hhmm)" 14:02
eq "row: requested_at from the stubbed clock" "$(field "$Q" 6139 requested_at)" 2026-11-27T14:02:00+00:00
eq "row: seen_at is the stubbed clock" "$(field "$Q" 6139 seen_at)" 2026-11-27T14:30:00+00:00
eq "row: no base on a live request" "$(field "$Q" 6139 base)" null
SNAP="$B/judge-desk/requests/6139-1111111.md"
eq "row: the snapshot path" "$(field "$Q" 6139 snapshot)" "$SNAP"
snap="$(cat "$SNAP" 2>/dev/null)"
has "snapshot: cut at the request bullet" "$snap" "- 14:02 LIVE — PR 6139 opened; JUDGE-REQUEST 6139 $H1 sent to the chief"
lacks "snapshot: nothing after the request bullet" "$snap" "after the request"
has "snapshot: the document's text before the bullet" "$snap" "- 13:40 LIVE — started"

sum1="$(cksum < "$SNAP" 2>/dev/null)"
nsnap="$(find "$B/judge-desk/requests" -type f 2>/dev/null | wc -l | tr -d ' ')"
out="$(JUDGE_QUEUE_NOW=1795790400 bash "$SUT" scan --bucket "$B" --since "$SINCE" 2>&1)"; rc=$?
eq "rescan: rc 0" "$rc" 0
lacks "rescan: nothing queued" "$out" "QUEUED"
eq "rescan: still three rows" "$(rows "$Q")" 3
eq "rescan: no new snapshot" "$(find "$B/judge-desk/requests" -type f 2>/dev/null | wc -l | tr -d ' ')" "$nsnap"
eq "rescan: the snapshot is untouched" "$(cksum < "$SNAP" 2>/dev/null)" "$sum1"

E="$WORK/edge"; mkdir -p "$E"
manifest "$E/chief.fleet.json" "$D/edge.md:native" "$D/HIMMEL-11268-N1-judge-desk-shadow.md:native" "$D/missing.md:native"
EQ="$E/judge-desk/judge-requests.jsonl"
out="$(JUDGE_QUEUE_NOW=1795824180 bash "$SUT" scan --bucket "$E" --since "$SINCE" 2>&1)"; rc=$?
eq "edge: rc 0" "$rc" 0
lacks "edge: a 7-hex head adds nothing" "$out" "6142"
eq "edge: a bullet with no pr or head adds nothing (one row only)" "$(rows "$EQ")" 1
has "edge: an unreadable document prints QUEUE?" "$out" "QUEUE? $D/missing.md"
lacks "edge: a judge desk document is skipped" "$out" "6144"
has "edge: the 23:58 request is queued" "$out" "QUEUED 6143 $H4"
eq "edge: a bullet at 23:58 seen at 00:03 resolves to the previous day" "$(field "$EQ" 6143 requested_at)" 2026-11-27T23:58:00+00:00

L="$WORK/lockb"; mkdir -p "$L"
mkfifo "$WORK/slow.md"
manifest "$L/chief.fleet.json" "$WORK/slow.md:native"
JUDGE_QUEUE_NOW=1795789800 bash "$SUT" scan --bucket "$L" --since "$SINCE" >/dev/null 2>&1 &
scan_pid=$!
held="$(python3 -I -c '
import fcntl, signal, sys
signal.alarm(30)
w = open(sys.argv[1], "w")
f = open(sys.argv[2], "a")
try:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("free")
except BlockingIOError:
    print("held")
w.write("## Results\n")
w.close()' "$WORK/slow.md" "$L/judge-desk/.lock" 2>&1)"
case "$held" in held|free) ;; *) kill "$scan_pid" 2>/dev/null ;; esac
wait "$scan_pid"; scan_rc=$?
eq "lock: a scan holds judge-desk/.lock while it reads the worker documents" "$held" held
eq "lock: the scan behind the lock probe exits 0" "$scan_rc" 0

R="$WORK/repo"; mkdir -p "$R"
(
    cd "$R" && git -c init.defaultBranch=main init -q && git config user.email t@t && git config user.name t \
        && git config commit.gpgsign false && echo a > a && git add a && git commit -qm base && echo b >> a && git commit -qam head
) || fail "replay fixture repo"
RB="$(git -C "$R" rev-parse HEAD~1)"; RH="$(git -C "$R" rev-parse HEAD)"
P="$WORK/rbucket"; PQ="$P/judge-desk/judge-requests.jsonl"
out="$(cd "$R" && JUDGE_QUEUE_NOW=1795789800 bash "$SUT" replay 6150 "$RH" --base "$RB" --record "$WORK/verdicts/j6150a/x.md" --bucket "$P" 2>&1)"; rc=$?
eq "replay: rc 0" "$rc" 0
has "replay: prints QUEUED" "$out" "QUEUED 6150 $RH"
eq "replay: lane replay" "$(field "$PQ" 6150 lane)" replay
eq "replay: the base" "$(field "$PQ" 6150 base)" "$RB"
eq "replay: the record path" "$(field "$PQ" 6150 record)" "$WORK/verdicts/j6150a/x.md"
eq "replay: no worker document" "$(field "$PQ" 6150 worker_doc)" null
eq "replay: the snapshot holds only pr, head and base" "$(cat "$P/judge-desk/requests/6150-${RH:0:7}.md" 2>/dev/null)" "$(printf 'pr: 6150\nhead: %s\nbase: %s' "$RH" "$RB")"
out="$(cd "$R" && JUDGE_QUEUE_NOW=1795789800 bash "$SUT" replay 6151 "$H2" --base "$RB" --record "$WORK/r.md" --bucket "$P" 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then pass "replay: a head git cat-file -e cannot resolve is refused (rc $rc)"; else fail "replay: unresolvable head rc=$rc: $out"; fi
eq "replay: the refused head adds no row" "$(rows "$PQ")" 1

writers() {
    python3 -I -c '
import re, sys
path = re.compile(r"judge-desk/(judge-requests|requests/)|judge-requests\.jsonl")
write = re.compile(r">>?|\btee\b|open\([^)]*[\x27\x22][aw]b?\+?[\x27\x22]|\bmv\b")
for f in sys.argv[1:]:
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    if any(path.search(l) and write.search(l) for l in lines):
        print(f)' "$@"
}
owners=()
while IFS= read -r f; do
    case "$f" in */test-*|*/fixtures/*) continue ;; esac
    owners+=("$REPO_ROOT/$f")
done < <(git -C "$REPO_ROOT" ls-files scripts)
w="$(writers "${owners[@]}")"
if [ -z "$w" ] || [ "$w" = "$SUT" ]; then pass "grep: no file but judge-queue.sh writes the queue paths"; else fail "grep: other writers: $w"; fi
cp "$SUT" "$WORK/planted.sh"
# shellcheck disable=SC2016  # the planted line is literal text, never run
printf '%s\n' 'printf x >> "$B/judge-desk/judge-requests.jsonl"' >> "$WORK/planted.sh"
eq "grep: red control, a planted append to judge-desk/judge-requests is flagged" "$(writers "$WORK/planted.sh")" "$WORK/planted.sh"

native="$(grep -E '^- native lane:' "$REPO_ROOT/docs/handover/worker-sections/judge-request.md")"
has "judge-request.md: the native-lane bullet carries JUDGE-REQUEST <pr> <head>" "$native" "JUDGE-REQUEST <pr> <head>"
has "judge-request.md: the native lane still messages the chief" "$native" "SendMessage"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
