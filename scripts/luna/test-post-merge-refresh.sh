#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2317
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK="$SCRIPT_DIR/post-merge-refresh.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUSY_FIXTURE="$REPO_ROOT/scripts/lib/fixtures/qmd-update-busy-output.txt"
GOLDEN_INDEX="$REPO_ROOT/scripts/lib/fixtures/qmd-collection-golden/index.yml"

PASS=0
FAIL=0
TMP_ROOT=""

cleanup() {
    local p
    if [ -n "$TMP_ROOT" ] && [ -f "$TMP_ROOT/bg.pids" ]; then
        while read -r p; do kill "$p" 2>/dev/null || true; done < "$TMP_ROOT/bg.pids"
    fi
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then rm -rf "$TMP_ROOT" 2>/dev/null || true; fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$2', got '$3'"; fi
}
assert_contains() {
    if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1" "missing: $2 in: $(printf '%s' "$3" | head -c 400)"; fi
}
assert_not_contains() {
    if grep -qF -- "$2" <<<"$3"; then fail "$1" "unexpected: $2"; else pass "$1"; fi
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pmr-test.XXXXXX") || exit 1
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
export XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_HOME="$HOME/.config"
unset GRAPHIFY_OUT INDEX_PATH QMD_INDEX_PATH QMD_CONFIG_DIR HIMMEL_FLOW_RUNS_LEDGER 2>/dev/null || true

BASE=1800000000
NOW=$BASE
TICK_OUT=""
TICK_RC=0
C=""
W0=""
LAST=""
TICK_BIN="$TICK"

g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

livepid() { sleep 600 >/dev/null 2>&1 & echo $! >> "$TMP_ROOT/bg.pids"; echo $!; }
deadpid() { local p; sh -c 'exit 0' & p=$!; wait "$p" 2>/dev/null; echo "$p"; }

mkcase() {
    C="$TMP_ROOT/$1"
    mkdir -p "$C/primary" "$C/state" "$C/bin" "$C/cfg" "$C/cache"
    g init -q "$C/primary" 2>/dev/null
    git -C "$C/primary" symbolic-ref HEAD refs/heads/main
    TICK_BIN="$TICK"
    cm "$BASE" README.md
    W0="$LAST"
    : > "$C/calls.log"
    sed 's/^  golden:/  himmel:/' "$GOLDEN_INDEX" > "$C/cfg/index.yml"
    : > "$C/cache/index.sqlite"
    printf 'ok' > "$C/qmd.mode"; printf 'ok' > "$C/ast.mode"
    cat > "$C/bin/qmd" <<'STUB'
#!/bin/sh
c="$PMR_CASE"
echo "qmd $* busy=${QMD_SQLITE_BUSY_TIMEOUT:-unset} nice=$(nice)" >> "$c/calls.log"
case "$(cat "$c/qmd.mode" 2>/dev/null)" in
  busy) cat "$PMR_BUSY_FIXTURE"; exit 1 ;;
  fail) echo "qmd: boom"; exit 1 ;;
  timeout) exit 124 ;;
  breakstate) mv "$c/state" "$c/state.gone" && : > "$c/state" ;;
  move)
    mkdir -p "$c/primary/docs"; echo "$$" > "$c/primary/docs/moved.md"
    git -C "$c/primary" add docs/moved.md
    GIT_AUTHOR_DATE="@$(cat "$c/move.epoch")" GIT_COMMITTER_DATE="@$(cat "$c/move.epoch")" \
      git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -C "$c/primary" commit -q -m moved
    ;;
esac
exit 0
STUB
    cat > "$C/bin/ast" <<'STUB'
#!/bin/sh
c="$PMR_CASE"
echo "ast $* nice=$(nice)" >> "$c/calls.log"
case "$(cat "$c/ast.mode" 2>/dev/null)" in
  skip) exit 4 ;;
  fail) exit 5 ;;
  slow) n=$(cat "$c/now"); echo $((n + 400)) > "$c/now" ;;
  move)
    echo "$$" > "$c/primary/moved.sh"
    git -C "$c/primary" add moved.sh
    GIT_AUTHOR_DATE="@$(cat "$c/move.epoch")" GIT_COMMITTER_DATE="@$(cat "$c/move.epoch")" \
      git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -C "$c/primary" commit -q -m moved
    ;;
esac
exit 0
STUB
    cat > "$C/bin/lag.py" <<'STUB'
import os, sys
open(os.environ["PMR_CASE"] + "/calls.log", "a").write("lag " + " ".join(sys.argv[1:]) + "\n")
STUB
    cat > "$C/bin/alert" <<'STUB'
#!/bin/sh
echo "$*" >> "$PMR_CASE/alerts.log"
STUB
    chmod +x "$C/bin/qmd" "$C/bin/ast" "$C/bin/alert"
    : > "$C/alerts.log"
}

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

head_sha() { git -C "$C/primary" rev-parse refs/heads/main; }

seed_both() {
    printf '%s\n' "$W0" > "$C/state/qmd.sha"
    printf '%s\n' "$W0" > "$C/state/graph.sha"
}

tick() {
    local halves="$1"; shift
    TICK_OUT=$(env HOME="$HOME" PMR_CASE="$C" PMR_BUSY_FIXTURE="$BUSY_FIXTURE" \
        PMR_QMD="$C/bin/qmd" PMR_AST="$C/bin/ast" PMR_PRIMARY="$C/primary" PMR_STATE="$C/state" \
        PMR_NOW="$NOW" PMR_LOAD=0 PMR_ALERT="$C/bin/alert" PMR_REINDEX_LOCK="$C/reindex.lock" \
        PMR_LAG="$C/bin/lag.py" QMD_CONFIG_DIR="$C/cfg" INDEX_PATH="$C/cache/index.sqlite" \
        HIMMEL_FLOW_RUNS_LEDGER="$C/flow.jsonl" "$@" bash "$TICK_BIN" --halves "$halves" 2>&1)
    TICK_RC=$?
}

ncalls() { local n; n=$(grep -c -- "^$1" "$C/calls.log" 2>/dev/null) || n=0; [ -n "$n" ] || n=0; echo "$n"; }
nalerts() { local n; n=$(grep -c -- "$1" "$C/alerts.log" 2>/dev/null) || n=0; [ -n "$n" ] || n=0; echo "$n"; }
nrows() { local n; n=$(grep -c -- "$1" "$C/flow.jsonl" 2>/dev/null) || n=0; [ -n "$n" ] || n=0; echo "$n"; }
sha_of() { cat "$C/state/$1.sha" 2>/dev/null || echo none; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "?"; }
sum256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mk_tick_tree() {
    local d="$1" f
    mkdir -p "$d/scripts/luna" "$d/scripts/lib" "$d/scripts/graphify" "$d/bin"
    cp "$TICK" "$d/scripts/luna/post-merge-refresh.sh" 2>/dev/null || true
    for f in "$REPO_ROOT"/scripts/lib/*; do ln -s "$f" "$d/scripts/lib/$(basename "$f")" 2>/dev/null || true; done
    printf '#!/bin/sh\necho "semantic-update.sh $*" >> "%s/sentinel.log"\nexit 99\n' "$d" > "$d/scripts/graphify/semantic-update.sh"
    printf '#!/bin/sh\necho "claude $*" >> "%s/sentinel.log"\nexit 99\n' "$d" > "$d/bin/claude"
    chmod +x "$d/scripts/graphify/semantic-update.sh" "$d/bin/claude"
    : > "$d/sentinel.log"
    if [ "${2:-}" = stub-bounded ]; then
        rm -f "$d/scripts/lib/qmd-bounded.sh"
        cat > "$d/scripts/lib/qmd-bounded.sh" <<'STUB'
qmd_timeout_secs() { printf '3600\n'; }
qmd_bounded() { echo "$1" >> "$PMR_CASE/bounded.log"; shift; "$@"; }
STUB
    fi
}

echo "== post-merge-refresh.sh =="

row_quiet_window_holds() {
    mkcase quiet; seed_both; cm $((BASE+1000)) docs/a.md
    NOW=$((BASE+1300)); tick both
    assert_eq "quiet_window_holds: keyword not run inside the window" 0 "$(ncalls 'qmd update')"
    assert_eq "quiet_window_holds: graph not run inside the window" 0 "$(ncalls ast)"
    assert_contains "quiet_window_holds: keyword hold logged" "keyword hold=" "$TICK_OUT"
    assert_contains "quiet_window_holds: graph hold logged" "graph hold=" "$TICK_OUT"
    assert_eq "quiet_window_holds: keyword watermark stays" "$W0" "$(sha_of qmd)"
    assert_eq "quiet_window_holds: exit 0" 0 "$TICK_RC"
    NOW=$((BASE+1600)); tick both
    assert_eq "quiet_window_holds: keyword fires once the newest is 600 s old" 1 "$(ncalls 'qmd update')"
    assert_eq "quiet_window_holds: graph fires once the newest is 600 s old" 1 "$(ncalls ast)"
}

row_max_wait_fires() {
    mkcase maxwait; seed_both; cm $((BASE+100)) docs/a.md; cm $((BASE+1800)) docs/b.md
    NOW=$((BASE+1900)); tick both
    assert_eq "max_wait_fires: keyword fires at the oldest's 1800 s" 1 "$(ncalls 'qmd update')"
    assert_eq "max_wait_fires: graph fires at the oldest's 1800 s" 1 "$(ncalls ast)"
    mkcase maxwait2; seed_both; cm $((BASE+101)) docs/a.md; cm $((BASE+1800)) docs/b.md
    NOW=$((BASE+1900)); tick both
    assert_eq "max_wait_fires: 1799 s old and a fresh newest holds" 0 "$(ncalls 'qmd update')"
}

row_burst_fires_once() {
    mkcase burst; seed_both; cm $((BASE+100)) docs/a.md; cm $((BASE+200)) docs/b.md; cm $((BASE+300)) docs/c.md
    NOW=$((BASE+1000)); tick both
    assert_eq "burst_fires_once: three merges, one keyword run" 1 "$(ncalls 'qmd update')"
    assert_eq "burst_fires_once: three merges, one graph run" 1 "$(ncalls ast)"
    tick both
    assert_eq "burst_fires_once: a second tick runs no keyword" 1 "$(ncalls 'qmd update')"
    assert_eq "burst_fires_once: a second tick runs no graph" 1 "$(ncalls ast)"
}

row_ignored_merges_count_for_neither() {
    mkcase ignored1; seed_both; cm $((BASE+100)) docs/a.md; cm $((BASE+1700)) graphify-out/x.md
    NOW=$((BASE+1750)); tick both
    assert_eq "ignored_merges_count_for_neither: an ignored newest merge does not hold the keyword run" 1 "$(ncalls 'qmd update')"
    mkcase ignored2; seed_both; cm $((BASE+100)) graphify-out/x.md; cm $((BASE+1700)) docs/a.md
    NOW=$((BASE+1900)); tick both
    assert_eq "ignored_merges_count_for_neither: an ignored oldest merge does not start the max wait" 0 "$(ncalls 'qmd update')"
}

row_delayed_pull_fires_once() {
    mkcase delayed; seed_both; cm $((BASE+10)) docs/a.md
    NOW=$((BASE+7200)); tick both
    assert_eq "delayed_pull_fires_once: a merge seen late fires at once" 1 "$(ncalls 'qmd update')"
    assert_eq "delayed_pull_fires_once: graph too" 1 "$(ncalls ast)"
    NOW=$((BASE+7500)); tick both
    assert_eq "delayed_pull_fires_once: not again" 1 "$(ncalls 'qmd update')"
}

row_failed_refresh_keeps_watermark() {
    mkcase failwm; seed_both; cm $((BASE+100)) docs/a.md
    printf 'fail' > "$C/qmd.mode"; printf 'fail' > "$C/ast.mode"
    NOW=$((BASE+1000)); tick both
    assert_contains "failed_refresh_keeps_watermark: keyword fail logged" "keyword fail rc=1" "$TICK_OUT"
    assert_contains "failed_refresh_keeps_watermark: graph fail logged" "graph fail rc=5" "$TICK_OUT"
    assert_eq "failed_refresh_keeps_watermark: keyword watermark stays" "$W0" "$(sha_of qmd)"
    assert_eq "failed_refresh_keeps_watermark: graph watermark stays" "$W0" "$(sha_of graph)"
    assert_eq "failed_refresh_keeps_watermark: a failed run still exits 0" 0 "$TICK_RC"
}

row_tree_moved_during_run() {
    mkcase moved1; seed_both; cm $((BASE+100)) docs/a.md; local m1="$LAST"
    printf 'move' > "$C/qmd.mode"; echo $((BASE+1010)) > "$C/move.epoch"
    NOW=$((BASE+1000)); tick both
    assert_eq "tree_moved_during_run: keyword watermark is the sha read before the run" "$m1" "$(sha_of qmd)"
    if [ "$(head_sha)" != "$m1" ]; then pass "tree_moved_during_run: main moved during the run"; else fail "tree_moved_during_run: main did not move"; fi
    printf 'ok' > "$C/qmd.mode"
    NOW=$((BASE+3000)); tick both
    assert_eq "tree_moved_during_run: the merge made during the run is seen by the next tick" 2 "$(ncalls 'qmd update')"
    assert_eq "tree_moved_during_run: keyword then settles at the new main" "$(head_sha)" "$(sha_of qmd)"
    mkcase moved2; seed_both; cm $((BASE+100)) src/a.sh; m1="$LAST"
    printf 'move' > "$C/ast.mode"; echo $((BASE+1010)) > "$C/move.epoch"
    NOW=$((BASE+1000)); tick both
    assert_eq "tree_moved_during_run: graph watermark is the sha read before the run" "$m1" "$(sha_of graph)"
    printf 'ok' > "$C/ast.mode"
    NOW=$((BASE+3000)); tick both
    assert_eq "tree_moved_during_run: graph sees the merge made during its run" 2 "$(ncalls ast)"
}

row_unchanged_graph_still_settles() {
    mkcase settle; seed_both; cm $((BASE+100)) src/a.sh
    NOW=$((BASE+1000)); tick both
    assert_eq "unchanged_graph_still_settles: the graph ran once" 1 "$(ncalls ast)"
    assert_eq "unchanged_graph_still_settles: graph watermark is main although graph.json never changed" "$(head_sha)" "$(sha_of graph)"
    NOW=$((BASE+1300)); tick both
    NOW=$((BASE+1600)); tick both
    assert_eq "unchanged_graph_still_settles: no refire on later ticks" 1 "$(ncalls ast)"
}

row_range_with_nothing_moves_watermark() {
    mkcase nothing; seed_both; cm $((BASE+100)) graphify-out/x.md
    NOW=$((BASE+1000)); tick both
    assert_eq "range_with_nothing_moves_watermark: keyword watermark moves to main" "$(head_sha)" "$(sha_of qmd)"
    assert_eq "range_with_nothing_moves_watermark: no keyword run" 0 "$(ncalls 'qmd update')"
    assert_contains "range_with_nothing_moves_watermark: the move is logged" "keyword nothing" "$TICK_OUT"
    assert_not_contains "range_with_nothing_moves_watermark: not a hold" "keyword hold=" "$TICK_OUT"
}

row_seeds_without_running() {
    mkcase seeds; cm $((BASE+100)) docs/a.md
    NOW=$((BASE+5000)); tick both
    assert_eq "seeds_without_running: keyword watermark seeded at main" "$(head_sha)" "$(sha_of qmd)"
    assert_eq "seeds_without_running: graph watermark seeded at main" "$(head_sha)" "$(sha_of graph)"
    assert_eq "seeds_without_running: no keyword run" 0 "$(ncalls 'qmd update')"
    assert_eq "seeds_without_running: no graph run" 0 "$(ncalls ast)"
    assert_contains "seeds_without_running: seeded logged" "keyword seeded" "$TICK_OUT"
}

row_non_ancestor_runs_once() {
    mkcase nonanc; cm $((BASE+100)) docs/a.md
    local orphan tree
    tree=$(git -C "$C/primary" write-tree)
    orphan=$(GIT_AUTHOR_DATE="@$BASE +0000" GIT_COMMITTER_DATE="@$BASE +0000" g -C "$C/primary" commit-tree "$tree" -m orphan)
    printf '%s\n' "$orphan" > "$C/state/qmd.sha"; printf '%s\n' "$orphan" > "$C/state/graph.sha"
    NOW=$((BASE+120)); tick both
    assert_eq "non_ancestor_runs_once: keyword runs at once" 1 "$(ncalls 'qmd update')"
    assert_eq "non_ancestor_runs_once: graph runs at once" 1 "$(ncalls ast)"
    assert_eq "non_ancestor_runs_once: keyword watermark set to main" "$(head_sha)" "$(sha_of qmd)"
    NOW=$((BASE+500)); tick both
    assert_eq "non_ancestor_runs_once: and only once" 1 "$(ncalls 'qmd update')"
}

mk_lock() {
    local prefix="$1" pid="$2" acquired="$3"
    mkdir -p "$C/state/$prefix.lock"
    printf '%s\n' "$pid" > "$C/state/$prefix.lock/pid"
    printf 'other-run\n' > "$C/state/$prefix.lock/owner"
    printf '%s\n' "$acquired" > "$C/state/$prefix.lock/acquired"
}

row_dead_lock_refuses_loud() {
    mkcase deadlock; seed_both; cm $((BASE+100)) docs/a.md
    local dp; dp=$(deadpid)
    mk_lock qmd "$dp" $((BASE+50)); mk_lock graph "$dp" $((BASE+50))
    NOW=$((BASE+1000)); tick both
    assert_eq "dead_lock_refuses_loud: no keyword run" 0 "$(ncalls 'qmd update')"
    assert_eq "dead_lock_refuses_loud: no graph run" 0 "$(ncalls ast)"
    if [ -d "$C/state/qmd.lock" ] && [ -d "$C/state/graph.lock" ]; then pass "dead_lock_refuses_loud: a dead holder's lock is never taken over"; else fail "dead_lock_refuses_loud: the lock directory was removed"; fi
    assert_contains "dead_lock_refuses_loud: the refusal names the lock" "ERR" "$TICK_OUT"
    assert_contains "dead_lock_refuses_loud: keyword alert raised" "post-merge-keyword" "$(cat "$C/alerts.log")"
    assert_contains "dead_lock_refuses_loud: graph alert raised" "post-merge-graph" "$(cat "$C/alerts.log")"
}

row_live_lock_skips() {
    mkcase livelock; seed_both; cm $((BASE+100)) docs/a.md
    local lp; lp=$(livepid)
    mk_lock qmd "$lp" $((BASE+900)); mk_lock graph "$lp" $((BASE+900))
    NOW=$((BASE+1000)); tick both
    assert_eq "live_lock_skips: no keyword run" 0 "$(ncalls 'qmd update')"
    assert_eq "live_lock_skips: no graph run" 0 "$(ncalls ast)"
    assert_contains "live_lock_skips: skip logged" "keyword skip=live-lock" "$TICK_OUT"
    assert_eq "live_lock_skips: a fresh holder raises no alert" 0 "$(nalerts 'fail')"
    if [ -d "$C/state/graph.lock" ]; then pass "live_lock_skips: the lock stays"; else fail "live_lock_skips: the lock was removed"; fi
}

row_lock_past_30_min_alerts_once() {
    mkcase longlock; seed_both; cm $((BASE+100)) src/a.sh
    local lp; lp=$(livepid)
    mk_lock graph "$lp" $((BASE+100))
    NOW=$((BASE+2200)); tick graph
    NOW=$((BASE+2500)); tick graph
    assert_eq "lock_past_30_min_alerts_once: one alert across two ticks" 1 "$(nalerts 'fail post-merge-graph')"
    assert_eq "lock_past_30_min_alerts_once: still no run" 0 "$(ncalls ast)"
}

row_reindex_lock_live_skips_keyword() {
    mkcase reidxlive; seed_both; cm $((BASE+100)) docs/a.md
    local lp; lp=$(livepid)
    mkdir -p "$C/reindex.lock"; printf '%s\n' "$lp" > "$C/reindex.lock/pid"
    NOW=$((BASE+1000)); tick both
    assert_eq "reindex_lock_live_skips_keyword: no keyword run" 0 "$(ncalls 'qmd update')"
    assert_contains "reindex_lock_live_skips_keyword: skip logged" "keyword skip=reindex-lock" "$TICK_OUT"
    assert_eq "reindex_lock_live_skips_keyword: the graph half is unaffected" 1 "$(ncalls ast)"
}

row_reindex_lock_dead_does_not_skip() {
    mkcase reidxdead; seed_both; cm $((BASE+100)) docs/a.md
    local dp; dp=$(deadpid)
    mkdir -p "$C/reindex.lock"; printf '%s\n' "$dp" > "$C/reindex.lock/pid"
    NOW=$((BASE+1000)); tick both
    assert_eq "reindex_lock_dead_does_not_skip: keyword runs" 1 "$(ncalls 'qmd update')"
}

row_no_paid_call() {
    mkcase nopaid; seed_both; cm $((BASE+100)) docs/a.md src/a.sh
    local tree="$TMP_ROOT/nopaid-tree"
    mk_tick_tree "$tree"
    TICK_BIN="$tree/scripts/luna/post-merge-refresh.sh"
    NOW=$((BASE+1000)); tick both PATH="$tree/bin:$PATH"
    assert_eq "no_paid_call: the tick ran both halves" 2 "$(( $(ncalls 'qmd update') + $(ncalls ast) ))"
    local verbs; verbs=$(grep '^qmd ' "$C/calls.log" | sed 's/ busy=.*//' | sort -u)
    assert_eq "no_paid_call: the only qmd verb is update -c himmel" "qmd update -c himmel" "$verbs"
    assert_eq "no_paid_call: semantic-update.sh and claude never ran" "" "$(cat "$tree/sentinel.log")"
    TICK_BIN="$TICK"
}

row_no_paid_call_real_ast() {
    mkcase realast; seed_both; cm $((BASE+100)) src/a.sh
    local sd="$TMP_ROOT/realast-bin" t
    mkdir -p "$sd"
    printf '#!/bin/sh\necho "$*" >> "%s/graphify.log"\nexit 0\n' "$sd" > "$sd/graphify"
    for t in claude curl wget nc ssh; do printf '#!/bin/sh\necho "%s $*" >> "%s/sentinel.log"\nexit 99\n' "$t" "$sd" > "$sd/$t"; done
    chmod +x "$sd"/*; : > "$sd/graphify.log"; : > "$sd/sentinel.log"
    NOW=$((BASE+1000)); tick graph PMR_AST="$REPO_ROOT/scripts/graphify/ast-update.sh" PATH="$sd:$PATH"
    assert_eq "no_paid_call_real_ast: the only graphify call is update <corpus> --force" "update $C/primary --force" "$(cat "$sd/graphify.log")"
    assert_eq "no_paid_call_real_ast: claude and network tools never ran" "" "$(cat "$sd/sentinel.log")"
    assert_eq "no_paid_call_real_ast: the graph watermark moved on the real wrapper's success" "$(head_sha)" "$(sha_of graph)"
}

row_stamp_untouched() {
    mkcase stamps; seed_both; cm $((BASE+100)) docs/a.md src/a.sh
    printf 'stamp-bytes\n' > "$C/cache/refresh-stamp"; printf 'rc=0\nsummary=x\n' > "$C/cache/reindex-state"
    touch -t 202001010000 "$C/cache/refresh-stamp" "$C/cache/reindex-state"
    local before; before="$(cksum < "$C/cache/refresh-stamp") $(mtime_of "$C/cache/refresh-stamp") $(cksum < "$C/cache/reindex-state") $(mtime_of "$C/cache/reindex-state")"
    NOW=$((BASE+1000)); tick both
    local after; after="$(cksum < "$C/cache/refresh-stamp") $(mtime_of "$C/cache/refresh-stamp") $(cksum < "$C/cache/reindex-state") $(mtime_of "$C/cache/reindex-state")"
    assert_eq "stamp_untouched: both halves ran" 2 "$(( $(ncalls 'qmd update') + $(ncalls ast) ))"
    assert_eq "stamp_untouched: refresh stamp and reindex-state keep their bytes and mtime" "$before" "$after"
}

row_no_merge_path_caller() {
    local allow='^(scripts/luna/(post-merge-refresh\.sh|test-post-merge-refresh\.sh|graphmap-cadence\.sh|test-graphmap-cadence\.sh|keyword-lag\.py|test-keyword-lag\.sh)|scripts/lib/(observability-registry|test-observability-registry)\.sh|scripts/observability/ledgers\.json|docs/)'
    local hits
    hits=$(git -C "$REPO_ROOT" grep -l -e 'post-merge-refresh' -e 'PostMergeRefresh' 2>/dev/null | grep -Ev "$allow" || true)
    assert_eq "no_merge_path_caller: only the tick, its verb, its tests and its docs name it" "" "$hits"
}

row_third_failure_alerts() {
    mkcase third; seed_both; cm $((BASE+100)) docs/a.md
    printf 'fail' > "$C/qmd.mode"
    NOW=$((BASE+1000)); tick both
    NOW=$((BASE+1300)); tick both
    assert_eq "third_failure_alerts: no alert after two failures" 0 "$(nalerts 'fail post-merge-keyword')"
    NOW=$((BASE+1900)); tick both
    assert_eq "third_failure_alerts: the third failure alerts" 1 "$(nalerts 'fail post-merge-keyword')"
}

row_success_clears() {
    mkcase succ; seed_both; cm $((BASE+100)) docs/a.md
    printf 'fail' > "$C/qmd.mode"
    NOW=$((BASE+1000)); tick both
    NOW=$((BASE+1300)); tick both
    NOW=$((BASE+1900)); tick both
    printf 'ok' > "$C/qmd.mode"
    NOW=$((BASE+4000)); tick both
    assert_contains "success_clears: an ok run clears the alert" "clear post-merge-keyword" "$(cat "$C/alerts.log")"
    cm $((BASE+4100)) docs/b.md; printf 'fail' > "$C/qmd.mode"
    NOW=$((BASE+5000)); tick both
    assert_eq "success_clears: the streak restarted, one failure does not alert again" 1 "$(nalerts 'fail post-merge-keyword')"
}

row_hold_neither_alerts_nor_clears() {
    mkcase holdnc; seed_both; cm $((BASE+100)) docs/a.md
    printf 'fail' > "$C/qmd.mode"
    NOW=$((BASE+1000)); tick both
    NOW=$((BASE+1300)); tick both
    NOW=$((BASE+1400)); tick both
    assert_contains "hold_neither_alerts_nor_clears: a backoff tick is a hold" "keyword hold=backoff" "$TICK_OUT"
    assert_eq "hold_neither_alerts_nor_clears: no alert from a hold" 0 "$(nalerts 'fail post-merge-keyword')"
    assert_eq "hold_neither_alerts_nor_clears: no clear from a hold" 0 "$(nalerts 'clear post-merge-keyword')"
    NOW=$((BASE+1900)); tick both
    assert_eq "hold_neither_alerts_nor_clears: the hold kept the streak, so the third failure alerts" 1 "$(nalerts 'fail post-merge-keyword')"
}

row_twelve_skips_alert() {
    mkcase twelve; seed_both; cm $((BASE+100)) src/a.sh
    printf 'skip' > "$C/ast.mode"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11; do NOW=$((BASE+1000+300*i)); tick graph; done
    assert_eq "twelve_skips_alert: no alert after eleven skips" 0 "$(nalerts 'fail post-merge-graph')"
    NOW=$((BASE+1000+300*12)); tick graph
    assert_eq "twelve_skips_alert: the twelfth skip alerts" 1 "$(nalerts 'fail post-merge-graph')"
    assert_contains "twelve_skips_alert: the alert names the reason" "promote-lock" "$(cat "$C/alerts.log")"
}

tick_real_alert() {
    tick "$1" PMR_ALERT="$REPO_ROOT/scripts/luna/cadence-alert.sh" CADENCE_ALERT_SEND_CMD="$C/bin/send" \
        CADENCE_ALERT_FILE="$C/alert-file" CADENCE_ALERT_DEDUPE_DIR="$C/dedupe"
}

mk_send_stub() {
    cat > "$C/bin/send" <<'STUB'
#!/bin/sh
echo "$1" >> "$PMR_CASE/sends.log"
STUB
    chmod +x "$C/bin/send"
    : > "$C/sends.log"
}

row_alert_once_per_streak() {
    local i sends
    mkcase onesend; seed_both; cm $((BASE+100)) src/a.sh
    mk_send_stub
    printf 'skip' > "$C/ast.mode"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do NOW=$((BASE+1000+300*i)); tick_real_alert graph; done
    sends=$(grep -c . "$C/sends.log" || true)
    assert_eq "alert_once_per_streak: 13 skips in a row send one message" 1 "$sends"
    mkcase onesend2; seed_both; cm $((BASE+100)) src/a.sh
    mk_send_stub
    printf 'fail' > "$C/ast.mode"
    for i in 1000 1300 1900 3100; do NOW=$((BASE+i)); tick_real_alert graph; done
    sends=$(grep -c . "$C/sends.log" || true)
    assert_eq "alert_once_per_streak: 4 failures in a row send one message" 1 "$sends"
}

row_unwritable_state_dies() {
    mkcase nostate; seed_both; cm $((BASE+100)) docs/a.md
    printf 'breakstate' > "$C/qmd.mode"
    NOW=$((BASE+1000)); tick both
    assert_eq "unwritable_state_dies: a state write that fails stops the tick" 1 "$TICK_RC"
    assert_contains "unwritable_state_dies: and says what it could not write" "ERR cannot write" "$TICK_OUT"
    assert_not_contains "unwritable_state_dies: no ok is logged for the run" "keyword ok" "$TICK_OUT"
}

row_clean_exit_clears_tick_alert() {
    mkcase tickalert; seed_both
    NOW=$((BASE+1000)); tick both
    assert_eq "clean_exit_clears_tick_alert: exit 0" 0 "$TICK_RC"
    assert_contains "clean_exit_clears_tick_alert: the tick alert is cleared" "clear post-merge-tick" "$(cat "$C/alerts.log")"
}

row_graph_only_arm_never_runs_qmd() {
    mkcase graphonly; seed_both; cm $((BASE+100)) docs/a.md
    NOW=$((BASE+1000)); tick graph
    assert_eq "graph_only_arm_never_runs_qmd: no qmd call" 0 "$(ncalls qmd)"
    assert_eq "graph_only_arm_never_runs_qmd: the graph half ran" 1 "$(ncalls ast)"
    assert_eq "graph_only_arm_never_runs_qmd: the keyword watermark is untouched" "$W0" "$(sha_of qmd)"
}

row_sampler_runs_with_keyword_off() {
    mkcase samplegraph; seed_both
    NOW=$((BASE+1000)); tick graph
    assert_eq "sampler_runs_with_keyword_off: the sampler ran armed graph" "lag tick --index $C/cache/index.sqlite --state $C/state" "$(grep '^lag ' "$C/calls.log")"
}

row_no_index_no_sample() {
    mkcase noindex; seed_both; rm -f "$C/cache/index.sqlite"
    NOW=$((BASE+1000)); tick both
    assert_eq "no_index_no_sample: no sampler call" 0 "$(ncalls lag)"
    assert_eq "no_index_no_sample: one log line" 1 "$(grep -c 'no index' <<<"$TICK_OUT")"
}

row_sampler_after_keyword_before_graph() {
    mkcase order; seed_both; cm $((BASE+100)) docs/a.md src/a.sh
    NOW=$((BASE+1000)); tick both
    assert_eq "sampler_after_keyword_before_graph: keyword, then the sampler, then graph" "qmd lag ast" "$(cut -d' ' -f1 "$C/calls.log" | tr '\n' ' ' | sed 's/ $//')"
}

row_missing_lag_script_is_error() {
    mkcase nolag; seed_both; cm $((BASE+100)) docs/a.md
    NOW=$((BASE+1000)); tick both PMR_LAG="$C/bin/absent.py"
    assert_eq "missing_lag_script_is_error: the tick exits 3" 3 "$TICK_RC"
    assert_eq "missing_lag_script_is_error: one error line" 1 "$(grep -c 'ERR keyword-lag.py absent' <<<"$TICK_OUT")"
    assert_eq "missing_lag_script_is_error: the graph step still ran" 1 "$(ncalls ast)"
    assert_eq "missing_lag_script_is_error: the graph watermark moved" "$(head_sha)" "$(sha_of graph)"
    assert_eq "missing_lag_script_is_error: the tick alert is not cleared, so the runner's non-zero exit raises it" 0 "$(nalerts 'clear post-merge-tick')"
}

row_sampler_real_call_line() {
    mkcase realcall; seed_both
    NOW=$((BASE+100)); tick both PMR_LAG="$SCRIPT_DIR/keyword-lag.py"
    assert_eq "sampler_real_call_line: the first real call seeds its cursor and exits 0" 0 "$TICK_RC"
    cm $((BASE+200)) docs/a.md; local m="$LAST"
    python3 -I - "$C/cache/index.sqlite" "$(sum256 "$C/primary/docs/a.md")" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE documents (id INTEGER PRIMARY KEY AUTOINCREMENT, collection TEXT NOT NULL, path TEXT NOT NULL, "
            "title TEXT NOT NULL, hash TEXT NOT NULL, created_at TEXT NOT NULL, modified_at TEXT NOT NULL, "
            "active INTEGER NOT NULL DEFAULT 1, UNIQUE(collection, path))")
con.execute("INSERT INTO documents (collection, path, title, hash, created_at, modified_at, active) "
            "VALUES ('himmel', 'docs/a.md', 't', ?, 't', 't', 1)", (sys.argv[2],))
con.commit()
PY
    NOW=$((BASE+300)); tick both PMR_LAG="$SCRIPT_DIR/keyword-lag.py"
    assert_eq "sampler_real_call_line: exit 0" 0 "$TICK_RC"
    assert_contains "sampler_real_call_line: the real script's own line is in the tick's output" "keyword-lag: tick cursor=" "$TICK_OUT"
    assert_eq "sampler_real_call_line: the real script wrote the merge's row" 1 "$(grep -c "\"merge\":\"$m\"" "$C/state/keyword-lag.jsonl" 2>/dev/null)"
}

row_only_real_run_writes_row() {
    mkcase rows; seed_both; cm $((BASE+100)) docs/a.md; local m="$LAST"
    NOW=$((BASE+300)); tick both
    assert_eq "only_real_run_writes_row: a hold writes no row" 0 "$(nrows flow)"
    printf 'skip' > "$C/ast.mode"; printf 'busy' > "$C/qmd.mode"
    NOW=$((BASE+1000)); tick both
    assert_eq "only_real_run_writes_row: a skip writes no row" 0 "$(nrows flow)"
    printf 'ok' > "$C/ast.mode"; printf 'ok' > "$C/qmd.mode"
    NOW=$((BASE+1300)); tick both
    assert_eq "only_real_run_writes_row: a real run writes a start and an end per half" 4 "$(nrows flow)"
    assert_eq "only_real_run_writes_row: the graph end row carries from..to in its note" 1 "$(grep -c "\"flow\":\"post-merge-graph\".*\"ev\":\"end\".*$W0\.\.$m\|\"ev\":\"end\".*\"flow\":\"post-merge-graph\".*$W0\.\.$m" "$C/flow.jsonl")"
    assert_contains "only_real_run_writes_row: the keyword flow is named" '"flow":"post-merge-keyword"' "$(cat "$C/flow.jsonl")"
}

row_db_busy_is_skip() {
    mkcase busy; seed_both; cm $((BASE+100)) docs/a.md
    printf 'busy' > "$C/qmd.mode"
    NOW=$((BASE+1000)); tick both
    assert_contains "db_busy_is_skip: the real busy output reads as a skip" "keyword skip=db-busy" "$TICK_OUT"
    assert_not_contains "db_busy_is_skip: not a failure" "keyword fail" "$TICK_OUT"
    assert_eq "db_busy_is_skip: the watermark holds" "$W0" "$(sha_of qmd)"
    NOW=$((BASE+1300)); tick both
    assert_eq "db_busy_is_skip: no backoff, the next tick tries again" 2 "$(ncalls 'qmd update')"
}

row_promote_lock_is_skip() {
    mkcase promote; seed_both; cm $((BASE+100)) src/a.sh
    printf 'skip' > "$C/ast.mode"
    NOW=$((BASE+1000)); tick graph
    assert_contains "promote_lock_is_skip: exit 4 reads as a skip" "graph skip=promote-lock" "$TICK_OUT"
    assert_eq "promote_lock_is_skip: the watermark holds" "$W0" "$(sha_of graph)"
    NOW=$((BASE+1300)); tick graph
    assert_eq "promote_lock_is_skip: no backoff, the next tick tries again" 2 "$(ncalls ast)"
}

row_deadline_without_signature_is_fail() {
    mkcase deadline; seed_both; cm $((BASE+100)) docs/a.md
    printf 'timeout' > "$C/qmd.mode"
    NOW=$((BASE+1000)); tick both
    assert_contains "deadline_without_signature_is_fail: rc 124 with no busy signature fails" "keyword fail rc=124" "$TICK_OUT"
    assert_eq "deadline_without_signature_is_fail: the watermark holds" "$W0" "$(sha_of qmd)"
}

row_busy_timeout_and_deadline_passed() {
    mkcase deadl2; seed_both; cm $((BASE+100)) docs/a.md
    local tree="$TMP_ROOT/deadl2-tree"
    mk_tick_tree "$tree" stub-bounded
    TICK_BIN="$tree/scripts/luna/post-merge-refresh.sh"
    NOW=$((BASE+1000)); tick both
    assert_eq "busy_timeout_and_deadline_passed: the update ran under a 120 s deadline" "120" "$(cat "$C/bounded.log" 2>/dev/null)"
    assert_contains "busy_timeout_and_deadline_passed: the busy timeout is 30000" "busy=30000" "$(grep '^qmd ' "$C/calls.log")"
    TICK_BIN="$TICK"
}

row_backoff_after_failure() {
    mkcase backoff; seed_both; cm $((BASE+100)) docs/a.md
    printf 'fail' > "$C/qmd.mode"
    NOW=$((BASE+1000)); tick both
    NOW=$((BASE+1060)); tick both
    assert_eq "backoff_after_failure: no retry inside the 5 minute backoff" 1 "$(ncalls 'qmd update')"
    assert_contains "backoff_after_failure: the hold names the backoff" "keyword hold=backoff" "$TICK_OUT"
    NOW=$((BASE+1300)); tick both
    assert_eq "backoff_after_failure: retry once it passes" 2 "$(ncalls 'qmd update')"
    NOW=$((BASE+1300+599)); tick both
    assert_eq "backoff_after_failure: the second failure waits 10 minutes" 2 "$(ncalls 'qmd update')"
}

row_backoff_caps_at_an_hour() {
    mkcase backcap; seed_both; cm $((BASE+100)) docs/a.md
    printf 'fail' > "$C/qmd.mode"; printf '55\n' > "$C/state/keyword.fails"
    NOW=$((BASE+1000)); tick both
    assert_eq "backoff_caps_at_an_hour: a long streak waits an hour, not a negative time" "$((BASE+1000+3600))" "$(cat "$C/state/keyword.retry" 2>/dev/null)"
}

row_watermark_moved_before_lock_skips() {
    mkcase raced; seed_both; cm $((BASE+100)) src/a.sh
    mkdir -p "$C/fakebin"
    printf '#!/bin/sh\nprintf "%%s\\n" "%s" > "%s/state/graph.sha"\necho 4\n' "$LAST" "$C" > "$C/fakebin/nproc"
    chmod +x "$C/fakebin/nproc"
    NOW=$((BASE+1000)); tick graph PATH="$C/fakebin:$PATH"
    assert_eq "watermark_moved_before_lock_skips: a watermark another tick moved is not run on stale state" 0 "$(ncalls ast)"
    assert_contains "watermark_moved_before_lock_skips: the race is logged" "graph hold=raced" "$TICK_OUT"
    mkcase raced2; seed_both; cm $((BASE+100)) src/a.sh
    mkdir -p "$C/fakebin"
    printf '#!/bin/sh\nprintf "%%s\\n" "%s" > "%s/state/graph.retry"\necho 4\n' "$((BASE+9000))" "$C" > "$C/fakebin/nproc"
    chmod +x "$C/fakebin/nproc"
    NOW=$((BASE+1000)); tick graph PATH="$C/fakebin:$PATH"
    assert_eq "watermark_moved_before_lock_skips: a backoff another tick set meanwhile holds the run" 0 "$(ncalls ast)"
    assert_contains "watermark_moved_before_lock_skips: and is logged as a backoff" "graph hold=backoff" "$TICK_OUT"
}

row_slow_graph_floors_hourly() {
    mkcase slow; seed_both; cm $((BASE+100)) src/a.sh
    printf 'slow' > "$C/ast.mode"; echo $((BASE+1000)) > "$C/now"
    NOW="$C/now"; tick graph
    assert_eq "slow_graph_floors_hourly: the slow run happened" 1 "$(ncalls ast)"
    cm $((BASE+1500)) src/b.sh
    printf 'ok' > "$C/ast.mode"; echo $((BASE+2200)) > "$C/now"
    tick graph
    assert_eq "slow_graph_floors_hourly: inside the hour the graph does not run" 1 "$(ncalls ast)"
    assert_contains "slow_graph_floors_hourly: the floor is logged" "graph hold=slow-floor" "$TICK_OUT"
    echo $((BASE+1000+3600)) > "$C/now"; tick graph
    assert_eq "slow_graph_floors_hourly: it runs again an hour on" 2 "$(ncalls ast)"
    cm $((BASE+4700)) src/c.sh
    echo $((BASE+5400)) > "$C/now"; tick graph
    assert_eq "slow_graph_floors_hourly: a fast run lifts the floor" 3 "$(ncalls ast)"
}

row_load_defers_then_runs() {
    mkcase load; seed_both; cm $((BASE+100)) docs/a.md src/a.sh
    NOW=$((BASE+1000)); tick both PMR_LOAD=999
    assert_eq "load_defers_then_runs: load at or above the cores defers keyword" 0 "$(ncalls 'qmd update')"
    assert_contains "load_defers_then_runs: the defer is a skip" "keyword skip=load" "$TICK_OUT"
    NOW=$((BASE+1000+1799)); tick both PMR_LOAD=999
    assert_eq "load_defers_then_runs: still deferred before 1800 s" 0 "$(ncalls 'qmd update')"
    NOW=$((BASE+1000+1800)); tick both PMR_LOAD=999
    assert_eq "load_defers_then_runs: runs anyway after 1800 s" 1 "$(ncalls 'qmd update')"
    assert_eq "load_defers_then_runs: graph too" 1 "$(ncalls ast)"
}

row_primary_off_main_skips() {
    mkcase offmain; seed_both; cm $((BASE+100)) docs/a.md
    g -C "$C/primary" checkout -q -b topic
    NOW=$((BASE+1000)); tick both
    assert_contains "primary_off_main_skips: keyword skip" "keyword skip=primary-off-main" "$TICK_OUT"
    assert_contains "primary_off_main_skips: graph skip" "graph skip=primary-off-main" "$TICK_OUT"
    assert_eq "primary_off_main_skips: nothing ran" 0 "$(( $(ncalls 'qmd update') + $(ncalls ast) ))"
    assert_eq "primary_off_main_skips: watermarks hold" "$W0 $W0" "$(sha_of qmd) $(sha_of graph)"
}

row_runs_at_low_priority() {
    mkcase nicety; seed_both; cm $((BASE+100)) docs/a.md src/a.sh
    local want; want=$(nice -n 15 nice)
    NOW=$((BASE+1000)); tick both
    assert_eq "runs_at_low_priority: qmd ran niced" "1" "$(grep -c "^qmd .* nice=$want\$" "$C/calls.log")"
    assert_eq "runs_at_low_priority: ast ran niced" "1" "$(grep -c "^ast .* nice=$want\$" "$C/calls.log")"
}

row_code_only_skips_keyword() {
    mkcase codeonly; seed_both; cm $((BASE+100)) src/a.sh lib/b.py
    NOW=$((BASE+1000)); tick both
    assert_eq "code_only_skips_keyword: no keyword run" 0 "$(ncalls 'qmd update')"
    assert_eq "code_only_skips_keyword: watermark moves to main" "$(head_sha)" "$(sha_of qmd)"
    assert_eq "code_only_skips_keyword: the graph half runs" 1 "$(ncalls ast)"
}

row_dot_dir_md_skips_keyword() {
    mkcase dotdir; seed_both; cm $((BASE+100)) .claude/notes.md
    NOW=$((BASE+1000)); tick both
    assert_eq "dot_dir_md_skips_keyword: a dot-directory .md is not indexed" 0 "$(ncalls 'qmd update')"
    assert_eq "dot_dir_md_skips_keyword: watermark moves to main" "$(head_sha)" "$(sha_of qmd)"
}

row_usage() {
    mkcase usage
    TICK_OUT=$(bash "$TICK" 2>&1); TICK_RC=$?
    assert_eq "usage: no arguments exits 2" 2 "$TICK_RC"
    TICK_OUT=$(bash "$TICK" --halves keyword 2>&1); TICK_RC=$?
    assert_eq "usage: an unknown arm exits 2" 2 "$TICK_RC"
}

row_decide() {
    mkcase decide
    local o
    o=$(printf '%s\n' $((BASE-100)) | bash "$TICK" --decide "$BASE" 600 1800 2>&1)
    assert_eq "decide: a merge inside the quiet window holds" hold "$o"
    o=$(printf '%s\n' $((BASE-600)) | bash "$TICK" --decide "$BASE" 600 1800 2>&1)
    assert_eq "decide: a newest merge 600 s old fires" fire "$o"
    o=$(printf '%s\n' $((BASE-1800)) $((BASE-10)) | bash "$TICK" --decide "$BASE" 600 1800 2>&1)
    assert_eq "decide: an oldest merge 1800 s old fires" fire "$o"
    o=$(printf '' | bash "$TICK" --decide "$BASE" 600 1800 2>&1)
    assert_eq "decide: no merges holds" hold "$o"
    bash "$TICK" --decide notanumber 600 1800 </dev/null >/dev/null 2>&1; TICK_RC=$?
    assert_eq "decide: a bad number exits 2" 2 "$TICK_RC"
}

for row in quiet_window_holds max_wait_fires burst_fires_once ignored_merges_count_for_neither \
    delayed_pull_fires_once failed_refresh_keeps_watermark tree_moved_during_run \
    unchanged_graph_still_settles range_with_nothing_moves_watermark seeds_without_running \
    non_ancestor_runs_once dead_lock_refuses_loud live_lock_skips lock_past_30_min_alerts_once \
    reindex_lock_live_skips_keyword reindex_lock_dead_does_not_skip no_paid_call \
    no_paid_call_real_ast stamp_untouched no_merge_path_caller third_failure_alerts success_clears \
    hold_neither_alerts_nor_clears twelve_skips_alert alert_once_per_streak unwritable_state_dies clean_exit_clears_tick_alert \
    graph_only_arm_never_runs_qmd sampler_runs_with_keyword_off no_index_no_sample \
    sampler_after_keyword_before_graph missing_lag_script_is_error sampler_real_call_line only_real_run_writes_row db_busy_is_skip \
    promote_lock_is_skip deadline_without_signature_is_fail busy_timeout_and_deadline_passed \
    backoff_after_failure backoff_caps_at_an_hour watermark_moved_before_lock_skips slow_graph_floors_hourly load_defers_then_runs primary_off_main_skips \
    runs_at_low_priority code_only_skips_keyword dot_dir_md_skips_keyword usage decide; do
    echo "-- $row"
    "row_$row"
done

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
