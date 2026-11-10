#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2317
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAG="$SCRIPT_DIR/keyword-lag.py"
TICK="$SCRIPT_DIR/post-merge-refresh.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN_INDEX="$REPO_ROOT/scripts/lib/fixtures/qmd-collection-golden/index.yml"
FIXTURE="$SCRIPT_DIR/fixtures/merge-times-14d.txt"

PASS=0
FAIL=0
TMP_ROOT=""

cleanup() { if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT" 2>/dev/null || true; fi; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$2', got '$3'"; fi
}
assert_contains() {
    if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1" "missing: $2 in: $(printf '%s' "$3" | head -c 600)"; fi
}

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-keyword-lag (python3 not on PATH)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP test-keyword-lag (git not on PATH)"; exit 0; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kl-test.XXXXXX") || exit 1
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
export XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_HOME="$HOME/.config"
unset HIMMEL_KEYWORD_LAG_LEDGER HIMMEL_FLOW_RUNS_LEDGER PMR_NOW PMR_PRIMARY INDEX_PATH QMD_INDEX_PATH QMD_CONFIG_DIR 2>/dev/null || true

BASE=1800000000
NOW=$BASE
C=""
LAST=""
LAG_OUT=""
LAG_RC=0

g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
sum256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

SQLH="$TMP_ROOT/sqlh.py"
cat > "$SQLH" <<'PY'
import sqlite3, sys
db, op = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.execute("CREATE TABLE IF NOT EXISTS content (hash TEXT PRIMARY KEY, doc TEXT NOT NULL, created_at TEXT NOT NULL)")
con.execute("CREATE TABLE IF NOT EXISTS documents (id INTEGER PRIMARY KEY AUTOINCREMENT, collection TEXT NOT NULL, "
            "path TEXT NOT NULL, title TEXT NOT NULL, hash TEXT NOT NULL, created_at TEXT NOT NULL, "
            "modified_at TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, UNIQUE(collection, path))")
if op == "put":
    path, digest, active = sys.argv[3], sys.argv[4], int(sys.argv[5])
    con.execute("INSERT INTO documents (collection, path, title, hash, created_at, modified_at, active) "
                "VALUES ('himmel', ?, ?, ?, 't', 't', ?) ON CONFLICT(collection, path) DO UPDATE SET "
                "hash = excluded.hash, active = excluded.active", (path, path, digest, active))
elif op == "active":
    con.execute("UPDATE documents SET active = ? WHERE collection = 'himmel' AND path = ?", (int(sys.argv[4]), sys.argv[3]))
elif op != "init":
    sys.exit(2)
con.commit()
con.close()
PY

WIL="$TMP_ROOT/wil.py"
cat > "$WIL" <<'PY'
import math, sys
k, n = int(sys.argv[1]), int(sys.argv[2])
z = 1.959964
p = k / n
den = 1 + z * z / n
mid = (p + z * z / (2 * n)) / den
half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
print("%.4f to %.4f" % (max(0.0, mid - half), min(1.0, mid + half)))
PY
wil() { python3 -I "$WIL" "$1" "$2"; }

cm() {
    local ep="$1" p; shift
    for p in "$@"; do
        mkdir -p "$C/primary/$(dirname "$p")"
        echo "$ep $RANDOM" > "$C/primary/$p"
        git -C "$C/primary" add -- "$p"
    done
    GIT_AUTHOR_DATE="@$ep +0000" GIT_COMMITTER_DATE="@$ep +0000" g -C "$C/primary" commit -q -m "c$ep"
    LAST=$(git -C "$C/primary" rev-parse HEAD)
}

rmc() {
    local ep="$1" p="$2"
    git -C "$C/primary" rm -q -- "$p"
    GIT_AUTHOR_DATE="@$ep +0000" GIT_COMMITTER_DATE="@$ep +0000" g -C "$C/primary" commit -q -m "d$ep"
    LAST=$(git -C "$C/primary" rev-parse HEAD)
}

mkcase() {
    C="$TMP_ROOT/$1"
    mkdir -p "$C/primary" "$C/state" "$C/cfg"
    g init -q "$C/primary" 2>/dev/null
    git -C "$C/primary" symbolic-ref HEAD refs/heads/main
    sed 's/^  golden:/  himmel:/' "$GOLDEN_INDEX" > "$C/cfg/index.yml"
    cm $((BASE-1000)) README.md docs/a.md docs/b.md docs/c.md docs/gone.md
    python3 -I "$SQLH" "$C/index.sqlite" init
    : > "$C/flow.jsonl"
}

idx_put() {
    local path="$1" file="$2" active="${3:-1}"
    python3 -I "$SQLH" "$C/index.sqlite" put "$path" "$(sum256 "$file")" "$active"
}
idx_active() { python3 -I "$SQLH" "$C/index.sqlite" active "$1" "$2"; }
idx_now() { idx_put "$1" "$C/primary/$1"; }

lag_env() {
    env HOME="$HOME" PMR_PRIMARY="$C/primary" PMR_NOW="$NOW" QMD_CONFIG_DIR="$C/cfg" \
        HIMMEL_FLOW_RUNS_LEDGER="$C/flow.jsonl" "$@"
}
lag_tick() {
    LAG_OUT=$(lag_env python3 -I "$LAG" tick --index "$C/index.sqlite" --state "$C/state" 2>&1)
    LAG_RC=$?
}
lag_report() {
    LAG_OUT=$(lag_env python3 -I "$LAG" --report --state "$C/state" "$@" 2>&1)
    LAG_RC=$?
}

LEDGER_NAME="keyword-lag.jsonl"
nrows() { local n; n=$(grep -c '"merge"' "$C/state/$LEDGER_NAME" 2>/dev/null) || n=0; echo "${n:-0}"; }
has_row() { local n; n=$(grep -c "\"merge\":\"$1\"" "$C/state/$LEDGER_NAME" 2>/dev/null) || n=0; echo "${n:-0}"; }
first_in() { sed -n "s/.*\"merge\":\"$1\".*\"first_in_at\":\(null\|\"[^\"]*\"\).*/\1/p" "$C/state/$LEDGER_NAME" 2>/dev/null; }
head_sha() { git -C "$C/primary" rev-parse refs/heads/main; }

plant_row() {
    printf '{"v":1,"ts":"%s","host":"t","source":"keyword-lag","kind":"merge","merge":"%s","merged_at":"%s","first_in_at":%s}\n' \
        "$(iso "$NOW")" "$1" "$(iso "$2")" "$3" >> "$C/state/$LEDGER_NAME"
}
plant_flow() {
    local flow="$1" id="$2" start="$3" end="$4" rc="$5" note="${6:-}"
    printf '{"v":1,"ev":"start","flow":"%s","run_id":"%s","fired_at":"%s","host":"t","lane":null,"model":null,"task_name":null,"log_path":null,"pid":1}\n' \
        "$flow" "$id" "$(iso "$start")" >> "$C/flow.jsonl"
    local nj=null
    [ -z "$note" ] || nj="\"$note\""
    printf '{"v":1,"ev":"end","flow":"%s","run_id":"%s","ended_at":"%s","exit_code":%s,"outcome":"x","items_processed":null,"note":%s}\n' \
        "$flow" "$id" "$(iso "$end")" "$rc" "$nj" >> "$C/flow.jsonl"
}

echo "== keyword-lag.py =="

row_first_call_seeds_cursor_at_main() {
    mkcase seeds
    cm $((BASE+100)) docs/a.md; local before="$LAST"
    NOW=$((BASE+200)); lag_tick
    assert_eq "first_call_seeds_cursor_at_main: exit 0" 0 "$LAG_RC"
    assert_eq "first_call_seeds_cursor_at_main: the cursor is main" "$before" "$(cat "$C/state/lag.cursor" 2>/dev/null)"
    assert_eq "first_call_seeds_cursor_at_main: no row for a merge from before the first call" 0 "$(nrows)"
    assert_contains "first_call_seeds_cursor_at_main: one line says it seeded" "seeded" "$LAG_OUT"
    cm $((BASE+300)) docs/b.md; local after="$LAST"
    idx_now docs/b.md
    NOW=$((BASE+400)); lag_tick
    assert_eq "first_call_seeds_cursor_at_main: the next merge is sampled" 1 "$(has_row "$after")"
    assert_eq "first_call_seeds_cursor_at_main: the earlier merge never is" 0 "$(has_row "$before")"
}

row_burst_of_three_scores_three() {
    mkcase burst
    NOW=$((BASE)); lag_tick
    cm $((BASE+100)) docs/a.md; cm $((BASE+200)) docs/b.md; cm $((BASE+300)) docs/c.md
    NOW=$((BASE+1000)); lag_tick
    assert_eq "burst_of_three_scores_three: nothing in the index yet, no row" 0 "$(nrows)"
    idx_now docs/a.md; idx_now docs/b.md; idx_now docs/c.md
    NOW=$((BASE+1300)); lag_tick
    assert_eq "burst_of_three_scores_three: three merges, three rows" 3 "$(nrows)"
    assert_eq "burst_of_three_scores_three: each row carries the sample time" 3 "$(grep -c "\"first_in_at\":\"$(iso $((BASE+1300)))\"" "$C/state/$LEDGER_NAME")"
    assert_contains "burst_of_three_scores_three: a row carries merged_at as the commit time" "\"merged_at\":\"$(iso $((BASE+200)))\"" "$(cat "$C/state/$LEDGER_NAME")"
    assert_contains "burst_of_three_scores_three: the envelope" '"v":1,' "$(head -1 "$C/state/$LEDGER_NAME")"
    assert_contains "burst_of_three_scores_three: source" '"source":"keyword-lag"' "$(head -1 "$C/state/$LEDGER_NAME")"
    NOW=$((BASE+1600)); lag_tick
    assert_eq "burst_of_three_scores_three: a later tick writes no more" 3 "$(nrows)"
}

row_later_change_does_not_strand_merge() {
    mkcase later
    NOW=$((BASE)); lag_tick
    idx_now docs/a.md
    cm $((BASE+100)) docs/a.md; local m1="$LAST"
    cp "$C/primary/docs/a.md" "$C/a.v1"
    cm $((BASE+200)) docs/a.md; local m2="$LAST"
    NOW=$((BASE+1000)); lag_tick
    assert_eq "later_change_does_not_strand_merge: the index holds neither new version, no row" 0 "$(nrows)"
    idx_now docs/a.md
    NOW=$((BASE+1300)); lag_tick
    assert_eq "later_change_does_not_strand_merge: the earlier merge is in" 1 "$(has_row "$m1")"
    assert_eq "later_change_does_not_strand_merge: the later merge is in" 1 "$(has_row "$m2")"
    mkcase later2
    NOW=$((BASE)); lag_tick
    cm $((BASE+100)) docs/a.md; m1="$LAST"
    cp "$C/primary/docs/a.md" "$C/a.v1"
    cm $((BASE+200)) docs/a.md; m2="$LAST"
    idx_put docs/a.md "$C/a.v1"
    NOW=$((BASE+1000)); lag_tick
    assert_eq "later_change_does_not_strand_merge: an index holding the first version scores the first merge" 1 "$(has_row "$m1")"
    assert_eq "later_change_does_not_strand_merge: and not the second" 0 "$(has_row "$m2")"
}

row_deleted_file_counts_as_in() {
    mkcase deleted
    idx_now docs/gone.md
    NOW=$((BASE)); lag_tick
    rmc $((BASE+100)) docs/gone.md; local m="$LAST"
    NOW=$((BASE+1000)); lag_tick
    assert_eq "deleted_file_counts_as_in: an active row for the deleted path is not yet in" 0 "$(nrows)"
    idx_active docs/gone.md 0
    NOW=$((BASE+1300)); lag_tick
    assert_eq "deleted_file_counts_as_in: once the row is deactivated, the merge is in" 1 "$(has_row "$m")"
    assert_eq "deleted_file_counts_as_in: at the sample time" "\"$(iso $((BASE+1300)))\"" "$(first_in "$m")"
}

row_reads_active_rows_only() {
    mkcase active
    NOW=$((BASE)); lag_tick
    cm $((BASE+100)) docs/a.md; local m="$LAST"
    idx_put docs/a.md "$C/primary/docs/a.md" 0
    NOW=$((BASE+1000)); lag_tick
    assert_eq "reads_active_rows_only: an inactive row holding the right blob does not count" 0 "$(has_row "$m")"
    idx_active docs/a.md 1
    NOW=$((BASE+1300)); lag_tick
    assert_eq "reads_active_rows_only: the same row, active, counts" 1 "$(has_row "$m")"
}

row_unconfirmed_24h_writes_null_row() {
    mkcase unconfirmed
    NOW=$((BASE)); lag_tick
    cm $((BASE+100)) docs/a.md; local m="$LAST"
    NOW=$((BASE+100+86400-1)); lag_tick
    assert_eq "unconfirmed_24h_writes_null_row: 1 s short of 24 h, no row" 0 "$(nrows)"
    NOW=$((BASE+100+86400)); lag_tick
    assert_eq "unconfirmed_24h_writes_null_row: at 24 h one row" 1 "$(has_row "$m")"
    assert_eq "unconfirmed_24h_writes_null_row: its first_in_at is null" null "$(first_in "$m")"
    idx_now docs/a.md
    NOW=$((BASE+100+86400+300)); lag_tick
    assert_eq "unconfirmed_24h_writes_null_row: never sampled again" 1 "$(nrows)"
}

row_ignored_md_never_sampled() {
    mkcase ignoredmd
    NOW=$((BASE)); lag_tick
    cm $((BASE+100)) graphify-out/x.md; cm $((BASE+200)) docs/fixtures/y.md; cm $((BASE+300)) src/a.sh; cm $((BASE+400)) .hidden/z.md
    NOW=$((BASE+1000)); lag_tick
    NOW=$((BASE+86400+1000)); lag_tick
    assert_eq "ignored_md_never_sampled: files the collection ignores never reach a row, not even a null one" 0 "$(nrows)"
}

row_sampler_matches_sha256() {
    mkcase sha
    NOW=$((BASE)); lag_tick
    printf 'caf\xc3\xa9 line one\r\nline two\n' > "$C/primary/docs/a.md"
    git -C "$C/primary" add docs/a.md
    GIT_AUTHOR_DATE="@$((BASE+100)) +0000" GIT_COMMITTER_DATE="@$((BASE+100)) +0000" g -C "$C/primary" commit -q -m utf8
    local m; m=$(git -C "$C/primary" rev-parse HEAD)
    python3 -I "$SQLH" "$C/index.sqlite" put docs/a.md "$(sum256 "$C/primary/docs/a.md" | sed 's/^./0/')" 1
    NOW=$((BASE+1000)); lag_tick
    assert_eq "sampler_matches_sha256: a hash one digit off is not the file" 0 "$(has_row "$m")"
    idx_now docs/a.md
    NOW=$((BASE+1300)); lag_tick
    assert_eq "sampler_matches_sha256: the sha256 the system tool prints is the file" 1 "$(has_row "$m")"
}

row_keyword_lag_trimmed() {
    mkcase trimmed
    NOW=$((BASE)); lag_tick
    plant_row old1 $((BASE-31*86400)) null
    plant_row keep1 $((BASE-29*86400)) "\"$(iso $((BASE-29*86400+60)))\""
    plant_row keep2 $((BASE-86400)) "\"$(iso $((BASE-86400+60)))\""
    cm $((BASE+100)) docs/a.md; local m="$LAST"
    idx_now docs/a.md
    NOW=$((BASE+400)); lag_tick
    assert_eq "keyword_lag_trimmed: a row past 30 days is gone" 0 "$(has_row old1)"
    assert_eq "keyword_lag_trimmed: a row inside 30 days stays" 1 "$(has_row keep1)"
    assert_eq "keyword_lag_trimmed: the day-old row stays" 1 "$(has_row keep2)"
    assert_eq "keyword_lag_trimmed: the new row is written" 1 "$(has_row "$m")"
}

row_report_prints_denominator_two_lines_and_wilson() {
    mkcase report
    NOW=$((BASE+10*86400))
    local w0=$((NOW-2*86400)) k at
    for k in 0 1 2 3 4 5; do at=$((w0+1000+k*3600)); plant_row "r$k" "$at" "\"$(iso $((at+600)))\""; done
    at=$((w0+1000+6*3600)); plant_row r6 "$at" "\"$(iso $((at+3000)))\""
    plant_flow qmd-reindex ri1 $((at+60)) $((at+400)) 0
    at=$((w0+1000+7*3600)); plant_row r7 "$at" null
    plant_flow post-merge-keyword kf1 $((at+90)) $((at+100)) 1 "a..b"
    plant_flow post-merge-keyword kf2 $((at+890)) $((at+900)) 0 "b..c"
    at=$((w0+1000+8*3600)); plant_row r8 "$at" "\"$(iso $((at+2400)))\""
    at=$((w0+1000+9*3600)); plant_row r9 "$at" "\"$(iso $((at+2340)))\""
    lag_report --days 1
    assert_eq "report: exit 0" 0 "$LAG_RC"
    assert_contains "report: the denominator counts a null row as a miss" "denominator: 10" "$LAG_OUT"
    assert_contains "report: headline share with no exclusions and its Wilson interval" "headline: 7/10 = 0.7000 within 39 min (no exclusions); wilson95 $(wil 7 10)" "$LAG_OUT"
    assert_contains "report: second line drops the reindex overlap and the failure streak" "second: 7/8 = 0.8750 within 39 min after drops; wilson95 $(wil 7 8)" "$LAG_OUT"
    assert_contains "report: each rule's drop count" "dropped: reindex=1 failure_streak=1" "$LAG_OUT"
}

row_report_window_ends_24h_back() {
    mkcase window
    NOW=$((BASE+10*86400))
    plant_row in1 $((NOW-30*3600)) "\"$(iso $((NOW-30*3600+60)))\""
    plant_row late $((NOW-23*3600)) "\"$(iso $((NOW-23*3600+60)))\""
    plant_row early $((NOW-49*3600)) "\"$(iso $((NOW-49*3600+60)))\""
    lag_report --days 1
    assert_contains "report_window_ends_24h_back: a merge 23 h old is outside the window" "denominator: 1" "$LAG_OUT"
    assert_contains "report_window_ends_24h_back: one merge, one hit" "headline: 1/1 = 1.0000" "$LAG_OUT"
    lag_report --days 2
    assert_contains "report_window_ends_24h_back: two days back takes the 49 h merge too" "denominator: 2" "$LAG_OUT"
}

row_report_skips_malformed_first_in_at() {
    mkcase malformed
    NOW=$((BASE+10*86400))
    plant_row good $((NOW-30*3600)) "\"$(iso $((NOW-30*3600+60)))\""
    plant_row bad $((NOW-31*3600)) '"not-a-time"'
    lag_report --days 1
    assert_eq "report_skips_malformed_first_in_at: exit 0" 0 "$LAG_RC"
    assert_contains "report_skips_malformed_first_in_at: the malformed row is skipped, the good one counts" "denominator: 1" "$LAG_OUT"
}

row_replayed_finalize_writes_one_row() {
    mkcase replayfinal
    NOW=$((BASE)); lag_tick
    cm $((BASE+100)) docs/a.md; local m="$LAST"
    NOW=$((BASE+1000)); lag_tick
    cp "$C/state/lag.pending" "$C/pending.saved"
    idx_now docs/a.md
    NOW=$((BASE+1300)); lag_tick
    assert_eq "replayed_finalize_writes_one_row: the merge has its row" 1 "$(has_row "$m")"
    cp "$C/pending.saved" "$C/state/lag.pending"
    NOW=$((BASE+1600)); lag_tick
    assert_eq "replayed_finalize_writes_one_row: a tick that died between the append and the pending write adds no second row" 1 "$(has_row "$m")"
    assert_eq "replayed_finalize_writes_one_row: and the pending entry is cleared" "[]" "$(tr -d '\n' < "$C/state/lag.pending")"
}

row_replayed_cursor_write_adds_no_duplicate_pending() {
    mkcase replaycursor
    NOW=$((BASE)); lag_tick
    cp "$C/state/lag.cursor" "$C/cursor.saved"
    cm $((BASE+100)) docs/a.md
    NOW=$((BASE+1000)); lag_tick
    cp "$C/cursor.saved" "$C/state/lag.cursor"
    NOW=$((BASE+1300)); lag_tick
    assert_eq "replayed_cursor_write_adds_no_duplicate_pending: a tick that died after the pending write and before the cursor write keeps one entry" 1 "$(grep -o '"merge"' "$C/state/lag.pending" | wc -l | tr -d ' ')"
}

row_report_counts_pending_as_miss() {
    mkcase pendingmiss
    NOW=$((BASE)); lag_tick
    cm $((BASE+100)) docs/a.md
    NOW=$((BASE+1000)); lag_tick
    NOW=$((BASE+100+86400+1000))
    lag_report --days 1
    assert_contains "report_counts_pending_as_miss: a merge still pending in the window is in the denominator" "denominator: 1" "$LAG_OUT"
    assert_contains "report_counts_pending_as_miss: and counts as a miss" "headline: 0/1 = 0.0000" "$LAG_OUT"
}

row_graph_share_from_flow_rows() {
    mkcase graph
    cm $((BASE-200000)) src/before_window.sh; local c0="$LAST"
    cm $((BASE)) src/g1.sh
    cm $((BASE+300)) src/g2.sh; local g2="$LAST"
    cm $((BASE+10000)) src/g3.sh; local g3="$LAST"
    cm $((BASE+20000)) src/g4.sh; local g4="$LAST"
    cm $((BASE+30000)) src/g5.sh; local g5="$LAST"
    NOW=$((BASE+30000+86400+1000))
    plant_flow post-merge-graph A $((BASE+990)) $((BASE+1000)) 0 "$c0..$g2"
    plant_flow post-merge-graph B $((BASE+10500)) $((BASE+13000)) 0 "$g2..$g3"
    plant_flow post-merge-graph C $((BASE+24990)) $((BASE+25000)) 0 "$g3..$g4"
    plant_flow post-merge-graph D $((BASE+30590)) $((BASE+30600)) 0 "$g4..$g5"
    lag_report --days 1 --half graph
    assert_eq "graph_share_from_flow_rows: exit 0" 0 "$LAG_RC"
    assert_contains "graph_share_from_flow_rows: five merges in the window" "denominator: 5" "$LAG_OUT"
    assert_contains "graph_share_from_flow_rows: headline within 45 min from the runs' from..to" "headline: 3/5 = 0.6000 within 45 min (no exclusions); wilson95 $(wil 3 5)" "$LAG_OUT"
    assert_contains "graph_share_from_flow_rows: second line drops the slow-run floor" "second: 3/4 = 0.7500 within 45 min after drops; wilson95 $(wil 3 4)" "$LAG_OUT"
    assert_contains "graph_share_from_flow_rows: the slow run is the one dropped" "dropped: reindex=0 failure_streak=0 slow_floor=1" "$LAG_OUT"
}

row_usage() {
    mkcase usage
    LAG_OUT=$(python3 -I "$LAG" 2>&1); LAG_RC=$?
    assert_eq "usage: no arguments exits 2" 2 "$LAG_RC"
    LAG_OUT=$(python3 -I "$LAG" tick --state "$C/state" 2>&1); LAG_RC=$?
    assert_eq "usage: tick without --index exits 2" 2 "$LAG_RC"
    LAG_OUT=$(python3 -I "$LAG" --report 2>&1); LAG_RC=$?
    assert_eq "usage: --report without --days exits 2" 2 "$LAG_RC"
}

REPLAY="$TMP_ROOT/replay.py"
cat > "$REPLAY" <<'PY'
import hashlib, importlib.util, json, os, sqlite3, subprocess, sys, time

lag_py, tick_sh, fixture, golden, work, mode = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("keyword_lag", lag_py)
kl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kl)

rows = []
for line in open(fixture):
    if line.strip() and not line.startswith("#"):
        t, n = line.split()
        rows.append((int(t), int(n)))
repo, state, cfg = (os.path.join(work, d) for d in ("repo", "state", "cfg"))
index, flow = os.path.join(work, "index.sqlite"), os.path.join(work, "flow.jsonl")
for d in (repo, state, cfg):
    os.makedirs(d)
open(flow, "w").close()
with open(golden) as src, open(os.path.join(cfg, "index.yml"), "w") as dst:
    dst.write(src.read().replace("  golden:", "  himmel:", 1))
os.environ["QMD_CONFIG_DIR"] = cfg
os.environ["HIMMEL_FLOW_RUNS_LEDGER"] = flow
os.environ["PMR_PRIMARY"] = repo


def git(*args, inp=None):
    return subprocess.run(["git", "-C", repo, *args], input=inp, capture_output=True, check=True).stdout.decode().strip()


def content(i, k):
    return ("merge %d file %d\n" % (i, k)).encode()


git("init", "-q")
git("symbolic-ref", "HEAD", "refs/heads/main")
stream = bytearray()


def add_commit(t, files, msg):
    stream.extend(("commit refs/heads/main\ncommitter t <t@t> %d +0000\ndata %d\n%s\n" % (t, len(msg), msg)).encode())
    for path, body in files:
        stream.extend(("M 644 inline %s\ndata %d\n" % (path, len(body))).encode() + body + b"\n")


add_commit(rows[0][0] - 30 * 86400, [("README.md", b"base\n")], "base")
for i, (t, n) in enumerate(rows):
    if n > 0:
        add_commit(t, [("docs/m%d_%d.md" % (i, k), content(i, k)) for k in range(n)], "m%d" % i)
    else:
        add_commit(t, [("src/s%d.sh" % i, b"echo %d\n" % i)], "m%d" % i)
subprocess.run(["git", "-C", repo, "fast-import", "--quiet"], input=bytes(stream), check=True)
shas = git("rev-list", "--reverse", "--first-parent", "main").split("\n")
assert len(shas) == len(rows) + 1, (len(shas), len(rows))
git("update-ref", "refs/heads/main", shas[0])

db = sqlite3.connect(index)
db.execute("CREATE TABLE content (hash TEXT PRIMARY KEY, doc TEXT NOT NULL, created_at TEXT NOT NULL)")
db.execute("CREATE TABLE documents (id INTEGER PRIMARY KEY AUTOINCREMENT, collection TEXT NOT NULL, path TEXT NOT NULL, "
           "title TEXT NOT NULL, hash TEXT NOT NULL, created_at TEXT NOT NULL, modified_at TEXT NOT NULL, "
           "active INTEGER NOT NULL DEFAULT 1, UNIQUE(collection, path))")
db.commit()


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def index_merges(lo, hi):
    for j in range(lo, hi):
        for k in range(rows[j][1]):
            digest = hashlib.sha256(content(j, k)).hexdigest()
            db.execute("INSERT INTO documents (collection, path, title, hash, created_at, modified_at, active) "
                       "VALUES ('himmel', ?, 't', ?, 't', 't', 1) ON CONFLICT(collection, path) DO UPDATE SET hash = excluded.hash",
                       ("docs/m%d_%d.md" % (j, k), digest))
    db.commit()


calls = 0


def decide(now, times):
    global calls
    calls += 1
    out = subprocess.run(["bash", tick_sh, "--decide", str(now), "600", "1800"], input="\n".join(map(str, times)) + "\n",
                         capture_output=True, text=True, check=True).stdout.strip()
    return out == "fire"


STEP = 300
first_tick = (rows[0][0] // STEP) * STEP - STEP
last_tick = ((rows[-1][0] // STEP) + 1) * STEP + 3 * 3600
idx = kw_wm = g_wm = 0
runs = 0
started = time.time()
T = first_tick
while T <= last_tick:
    moved = False
    while idx < len(rows) and rows[idx][0] <= T:
        idx += 1
        moved = True
    if moved:
        git("update-ref", "refs/heads/main", shas[idx])
    if mode == "healthy":
        times = [rows[j][0] for j in range(kw_wm, idx) if rows[j][1] > 0]
        if not times:
            kw_wm = idx
        elif decide(T, times):
            index_merges(kw_wm, idx)
            kw_wm = idx
            runs += 1
    kl.tick(index, state, repo, T)
    if mode == "hourly" and T % 3600 == 0:
        index_merges(kw_wm, idx)
        kw_wm = idx
        runs += 1
    if mode == "healthy":
        times = [rows[j][0] for j in range(g_wm, idx)]
        if times and decide(T, times):
            note = "%s..%s" % (shas[g_wm], shas[idx])
            rid = "g%d" % T
            with open(flow, "a") as fh:
                fh.write(json.dumps({"v": 1, "ev": "start", "flow": "post-merge-graph", "run_id": rid, "fired_at": iso(T),
                                     "host": "t", "lane": None, "model": None, "task_name": None, "log_path": None, "pid": 1}) + "\n")
                fh.write(json.dumps({"v": 1, "ev": "end", "flow": "post-merge-graph", "run_id": rid, "ended_at": iso(T),
                                     "exit_code": 0, "outcome": "ok", "items_processed": None, "note": note}) + "\n")
            g_wm = idx
    T += STEP
elapsed = time.time() - started

report_env = dict(os.environ, PMR_NOW=str(last_tick + 86400))


def report(*extra):
    out = subprocess.run(["python3", "-I", lag_py, "--report", "--days", "15", "--state", state, *extra],
                         env=report_env, capture_output=True, text=True, check=True).stdout
    headline = [l for l in out.split("\n") if l.startswith("headline:")][0]
    share = headline.split("=")[1].split()[0]
    interval = headline.split("wilson95 ")[1].replace(" to ", "..")
    den = [l for l in out.split("\n") if l.startswith("denominator:")][0].split()[1]
    return share, den, interval


share, den, interval = report()
graph_share = report("--half", "graph")[0] if mode == "healthy" else "n/a"
print("REPLAY mode=%s calls=%d runs=%d ticks=%d secs=%.1f denominator=%s share=%s wilson95=%s graph_share=%s"
      % (mode, calls, runs, (last_tick - first_tick) // STEP + 1, elapsed, den, share, interval, graph_share))
PY

row_replay_healthy_tick_share() {
    local out share secs
    out=$(python3 -I "$REPLAY" "$LAG" "$TICK" "$FIXTURE" "$GOLDEN_INDEX" "$TMP_ROOT/replay-healthy" healthy 2>&1)
    echo "    $out"
    share=$(sed -n 's/.* share=\([0-9.]*\) .*/\1/p' <<<"$out")
    secs=$(sed -n 's/.* secs=\([0-9]*\)\..*/\1/p' <<<"$out")
    assert_contains "replay_healthy_tick_share: the healthy tick replays the 14-day fixture" "REPLAY mode=healthy" "$out"
    if [ -n "$share" ] && awk -v s="$share" 'BEGIN { exit !(s >= 0.95) }'; then pass "replay_healthy_tick_share: healthy share $share is at least 0.95"; else fail "replay_healthy_tick_share: healthy share" "got '$share'"; fi
    if [ -n "$secs" ] && [ "$secs" -lt 60 ]; then pass "replay_healthy_tick_share: the replay took ${secs}s, under 60"; else fail "replay_healthy_tick_share: the replay took '${secs}'s"; fi
    assert_contains "replay_healthy_tick_share: the graph half's share reads from the same flow rows" "graph_share=1.0000" "$out"
    out=$(python3 -I "$REPLAY" "$LAG" "$TICK" "$FIXTURE" "$GOLDEN_INDEX" "$TMP_ROOT/replay-hourly" hourly 2>&1)
    echo "    $out"
    share=$(sed -n 's/.* share=\([0-9.]*\) .*/\1/p' <<<"$out")
    if [ -n "$share" ]; then pass "replay_healthy_tick_share: the instant hourly writer's share $share is printed, and is not a fail condition"; else fail "replay_healthy_tick_share: no hourly share was printed" "$out"; fi
}

for row in first_call_seeds_cursor_at_main burst_of_three_scores_three later_change_does_not_strand_merge \
    deleted_file_counts_as_in reads_active_rows_only unconfirmed_24h_writes_null_row ignored_md_never_sampled \
    sampler_matches_sha256 keyword_lag_trimmed report_prints_denominator_two_lines_and_wilson \
    report_window_ends_24h_back report_skips_malformed_first_in_at replayed_finalize_writes_one_row replayed_cursor_write_adds_no_duplicate_pending report_counts_pending_as_miss \
    graph_share_from_flow_rows usage replay_healthy_tick_share; do
    echo "-- $row"
    "row_$row"
done

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
