#!/usr/bin/env bash
# scripts/handover/chief-kit/test-close-sweep.sh - suite: close-sweep.sh, the one
# batched sweep that digests, reaps and prunes closed workers with at most one
# PR list call per repo.
#
# Fixture repos are real git repos with a github-form origin (no network: a `git`
# wrapper on PATH answers fetch and ls-remote), real worktrees under
# <repo>/.claude/worktrees, and the real scripts/clean.sh and worktree.sh
# (prune --only --pr-cache). The sweep's helpers (capture, cost, digest, reap)
# and the `worktree.sh pr-cache` list verb are stubbed to log. No live GitHub
# call: `gh` fails and logs, and every row that proves a merge locally asserts
# the log is empty.
#
# Platform guard: Linux bash 3.2+ (flock, /proc; git 2.38+ for merge-tree --write-tree).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/close-sweep.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
REAL_GIT="$(command -v git)"

W="$(mktemp -d "${TMPDIR:-/tmp}/close-sweep-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
PIDS=""
LOCK_DOCS=""
# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    local p d
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    for d in $LOCK_DOCS; do bash "$ROOT/scripts/handover/queue-lock.sh" release "$d" >/dev/null 2>&1; done
    rm -rf "$W"
}
trap cleanup EXIT
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=file

pass=0; fails=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; [ $# -lt 2 ] || printf '    %s\n' "$2"; fails=$((fails+1)); }
check()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "[$2] != [$3]"; fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then ok "$1"; else bad "$1" "output does not contain [$3]: $2"; fi; }
lacks()    { if grep -q -F -e "$3" <<< "$2"; then bad "$1" "output contains [$3]: $2"; else ok "$1"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1" "$2 is missing"; fi; }
absent()   { if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "$2 still exists"; fi; }
njson()    { local f n=0; for f in "$1"/*.json; do [ -f "$f" ] && n=$((n + 1)); done; echo "$n"; }
lines()    { if [ -s "$1" ]; then grep -c . "$1"; else echo 0; fi; }

now() { date +%s; }
g() { local d="$1"; shift; "$REAL_GIT" -C "$d" "$@"; }

export HOME="$W/home"; mkdir -p "$HOME"
export HANDOVER_DIR="$W/handovers"; mkdir -p "$HANDOVER_DIR/u/p"
PROJECTS="$W/projects"; mkdir -p "$PROJECTS/-x"

# ---- stubs --------------------------------------------------------------
mkdir -p "$W/bin" "$W/stubs" "$W/prcache"
GH_LOG="$W/gh.log"; GIT_LOG="$W/git.log"; ORDER_LOG="$W/order.log"; DIGEST_LOG="$W/digest.log"
REAP_LOG="$W/reap.log"; CAPTURE_LOG="$W/capture.log"; PRCACHE_LOG="$W/prcache.log"; CLEAN_LOG="$W/clean.log"
FAKE_REMOTE_HEADS="$W/remote-heads"
export GH_LOG GIT_LOG ORDER_LOG DIGEST_LOG REAP_LOG CAPTURE_LOG PRCACHE_LOG CLEAN_LOG FAKE_REMOTE_HEADS W
export PRCACHE_DIR="$W/prcache"

cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
exit 1
STUB
cat > "$W/bin/git" <<STUB
#!/usr/bin/env bash
echo "\$PWD|\$*" >> "\$GIT_LOG"
all=" \$* "
if [ -n "\${GIT_REFUSE:-}" ]; then
    case "\$all" in *" worktree remove "*|*" branch -D "*|*" branch -d "*) echo "wrapper: refused" >&2; exit 97 ;; esac
fi
case "\$all" in
    *" fetch "*)
        echo "ORDER fetch" >> "\$ORDER_LOG"
        if [ -n "\${FETCH_HOOK:-}" ] && [ -f "\$FETCH_HOOK" ]; then bash "\$FETCH_HOOK"; fi
        if [ -n "\${REAL_FETCH:-}" ]; then exec "$REAL_GIT" "\$@"; fi
        [ -z "\${FETCH_FAIL:-}" ] || exit 1
        exit 0 ;;
    *" ls-remote "*)
        for last in "\$@"; do :; done
        b="\${last#refs/heads/}"
        if [ -f "\$FAKE_REMOTE_HEADS" ]; then
            while read -r hb hsha; do
                if [ "\$hb" = "\$b" ]; then printf '%s\trefs/heads/%s\n' "\$hsha" "\$hb"; fi
            done < "\$FAKE_REMOTE_HEADS"
        fi
        exit 0 ;;
esac
exec "$REAL_GIT" "\$@"
STUB
cat > "$W/stubs/digest.sh" <<'STUB'
#!/usr/bin/env bash
n=$(grep -c . "$DIGEST_LOG" 2>/dev/null || true)
if [ -n "${DIGEST_KILL_AT:-}" ] && [ "$((${n:-0} + 1))" -eq "$DIGEST_KILL_AT" ]; then
    targets=""; p=$$
    while [ "${p:-0}" -gt 1 ]; do
        if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'close-sweep.sh --drain'; then targets="$targets $p"; fi
        p=$(ps -o ppid= -p "$p" | tr -d ' ')
    done
    # only this sweep's own ancestors (the drain and its command-substitution subshells), never another drain
    for p in $targets; do kill -9 "$p"; done
    sleep 5
fi
echo "ORDER digest" >> "$ORDER_LOG"
for a in "$@"; do printf '[%s]' "$a"; done >> "$DIGEST_LOG"
echo >> "$DIGEST_LOG"
[ -z "${DIGEST_SLEEP:-}" ] || sleep "$DIGEST_SLEEP"
echo "digest=ok fails=0 classes=0"
STUB
cat > "$W/stubs/reap.sh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf '[%s]' "$a"; done >> "$REAP_LOG"
echo >> "$REAP_LOG"
exit 0
STUB
cat > "$W/stubs/capture.sh" <<'STUB'
#!/usr/bin/env bash
echo "ORDER capture" >> "$ORDER_LOG"
{ cat; echo; } >> "$CAPTURE_LOG"
exit 0
STUB
cat > "$W/stubs/burn.sh" <<'STUB'
#!/usr/bin/env bash
echo "ORDER cost" >> "$ORDER_LOG"
echo "worker-burn x calls=3 compactions=0 out=10 cache-read=5 cache-create=2 input=7 cost-eq=1.5 unknown-model-calls=0 end"
STUB
cat > "$W/stubs/wt.sh" <<'STUB'
#!/usr/bin/env bash
echo "ORDER prcache" >> "$ORDER_LOG"
nwo=$(git remote get-url origin | sed -E 's#^https://github.com/##; s#\.git$##')
echo "$PWD|$nwo|$*" >> "$PRCACHE_LOG"
[ -z "${PRCACHE_FAIL:-}" ] || exit 1
rows="$PRCACHE_DIR/$(printf '%s' "$nwo" | tr '/' '_').rows"
printf '# nwo=%s\n# scope=all\n' "${PRCACHE_NWO:-$nwo}"
n=0
if [ -f "$rows" ]; then cat "$rows"; n=$(grep -c . "$rows"); fi
printf '# complete rows=%s\n' "$n"
STUB
cat > "$W/stubs/clean.sh" <<'STUB'
#!/usr/bin/env bash
echo "$PWD|$*" >> "$CLEAN_LOG"
last="${!#}"
[ -f "$last" ] && echo "clean-stub: cache file exists" >> "$CLEAN_LOG"
exit 0
STUB
chmod +x "$W/bin/gh" "$W/bin/git" "$W"/stubs/*.sh
export PATH="$W/bin:$PATH"
export WORKER_SESSION_DIGEST_STEP_BIN="$W/stubs/digest.sh" TMP_REAP_BIN="$W/stubs/reap.sh" END_SESSION_WIKI_BIN="$W/stubs/capture.sh"
export WORKER_SESSION_BURN_BIN="$W/stubs/burn.sh" WORKER_SESSION_COST_LEDGER="$W/cost.jsonl" WORKTREE_SH_BIN="$W/stubs/wt.sh"
export CLOSE_SWEEP_PID_WAIT=0

( : ) & GONE_PID=$!; wait "$GONE_PID" 2>/dev/null

# ---- fixtures -----------------------------------------------------------
reset_logs() { rm -f "$GH_LOG" "$GIT_LOG" "$ORDER_LOG" "$DIGEST_LOG" "$REAP_LOG" "$CAPTURE_LOG" "$PRCACHE_LOG" "$CLEAN_LOG" "$FAKE_REMOTE_HEADS" "$W"/prcache/*.rows; unset DIGEST_KILL_AT DIGEST_SLEEP FETCH_HOOK FETCH_FAIL REAL_FETCH PRCACHE_FAIL PRCACHE_NWO GIT_REFUSE CLEAN_SH_BIN; }

mk_repo() { # mk_repo <dir> <nwo>
    "$REAL_GIT" init -q -b main "$1"
    g "$1" config user.email t@test.com
    g "$1" config user.name t
    g "$1" config commit.gpgsign false
    g "$1" config core.hooksPath /dev/null
    g "$1" config maintenance.auto false
    g "$1" remote add origin "https://github.com/$2.git"
    seq 1 30 | sed 's/^/l/' > "$1/a.txt"
    echo b > "$1/b.txt"
    g "$1" add -A
    g "$1" commit -q -m base
    BASE=$(g "$1" rev-parse HEAD)
    g "$1" update-ref refs/remotes/origin/main "$BASE"
    mkdir -p "$1/.claude/worktrees"
    echo ".claude/" >> "$1/.git/info/exclude"
}
mk_wt() { # mk_wt <repo> <name> <branch>: prints the worktree path
    g "$1" worktree add -q "$1/.claude/worktrees/$2" -b "$3" "$BASE" >/dev/null 2>&1
    printf '%s\n' "$1/.claude/worktrees/$2"
}
wt_commit() { # wt_commit <wt> <file> <text>: prints the new tip
    printf '%s\n' "$3" > "$1/$2"
    g "$1" add -A
    g "$1" commit -q -m "wip $2"
    g "$1" rev-parse HEAD
}
squash_main() { # squash_main <repo> <branch> <subject>
    g "$1" merge --squash -q "$2" >/dev/null 2>&1
    g "$1" commit -q -m "$3"
    g "$1" update-ref refs/remotes/origin/main "$(g "$1" rev-parse HEAD)"
}
push_ref() { # push_ref <repo> <branch> <sha>: the branch is on origin
    g "$1" update-ref "refs/remotes/origin/$2" "$3"
    echo "$2 $3" >> "$FAKE_REMOTE_HEADS"
}
list_row() { printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$PRCACHE_DIR/$(printf '%s' "$1" | tr '/' '_').rows"; } # <nwo> <repo-col> <branch> <state> <sha>
mk_doc() { # mk_doc <doc> <wt-lines> [<pr> <head>]
    mkdir -p "$(dirname "$1")"
    {
        printf -- '---\nresume_cwd: %s\n---\n# worker\n' "$(printf '%s\n' "$2" | head -n 1)"
        printf '%s\n' "$2" | while IFS= read -r p; do [ -z "$p" ] || printf 'worktree %s\n' "\`$p\`"; done
        printf '## Results (newest at the bottom)\n- 10:00 LIVE - go\n'
        if [ -n "${3:-}" ]; then printf -- '- 10:30 READY %s %s GREEN\n' "$3" "$4"; fi
    } > "$1"
}
mk_rec() { # mk_rec <state> <k> <doc> <wt-text> <repo> [pid] [proc_start] [closed_at] [sid]
    local state="$1" k="$2" doc="$3" wt="$4" repo="$5" pid="${6:-$GONE_PID}" ps="${7:-}" closed="${8:-$(now)}" sid
    sid="${9:-$(printf '4670c3a0-0000-4000-8000-%012d' "$k")}"
    mkdir -p "$state/pending"
    jq -n --arg doc "$doc" --arg label "N$k" --argjson pid "$pid" --arg ps "$ps" --arg sid "$sid" --arg wt "$wt" \
        --arg repo "$repo" --argjson closed "$closed" --arg pd "$PROJECTS" \
        '{doc:$doc,label:$label,pid:$pid,proc_start:$ps,sid:$sid,transcript:"",names:"",config_dir:"",projects_dir:$pd,worktrees:$wt,repo:$repo,predecessor:0,named_successor:"",closed_at:$closed,sweeps_seen:0}' \
        > "$state/pending/$(printf '%010d' "$closed")-N$k.json"
}
proc_start_of() { sed -E 's/^.*\) //' "/proc/$1/stat" | awk '{print $20}'; }
rec_file() { local f; for f in "$1"/done/*-"$2".json "$1"/failed/*-"$2".json "$1"/pending/*-"$2".json; do [ -f "$f" ] && { printf '%s\n' "$f"; return; }; done; }
rec_field() { jq -r --arg f "$3" '.[$f] // ""' "$(rec_file "$1" "$2")" 2>/dev/null; }
rec_where() { local f; f=$(rec_file "$1" "$2"); if [ -n "$f" ]; then basename "$(dirname "$f")"; else echo none; fi; }
run_sweep() { CLOSE_SWEEP_STATE_DIR="$1" bash "$SWEEP" --drain > "$W/sweep.out" 2>&1; }
sweep_out() { cat "$W/sweep.out" 2>/dev/null; }

# a world: repo R (owner/repo), merged-local workers 1..$2 (PR 100+k), no-work workers after them
build_world() { # build_world <tag> <merged> <nowork>: sets R, S, DD, MERGED_WTS, NOWORK_WTS
    local tag="$1" nm="$2" nn="$3" k br wt tip
    R="$W/repo-$tag"; S="$W/state-$tag"; DD="$W/docs-$tag"; mk_repo "$R" owner/repo
    MERGED_WTS=""; NOWORK_WTS=""
    for k in $(seq 1 "$nm"); do
        wt=$(mk_wt "$R" "wm$k" "feat$k"); tip=$(wt_commit "$wt" "f$k.txt" "feature $k")
        eval "TIP_$k=$tip"; MERGED_WTS="$MERGED_WTS $wt"
    done
    for k in $(seq 1 "$nm"); do squash_main "$R" "feat$k" "feat: $k (#$((100 + k)))"; done
    for k in $(seq 1 "$nm"); do
        wt="$R/.claude/worktrees/wm$k"; eval "tip=\$TIP_$k"
        mk_doc "$DD/HIMMEL-9-N$k-sweep-2026-11-10.md" "$wt" "$((100 + k))" "$tip"
        mk_rec "$S" "$k" "$DD/HIMMEL-9-N$k-sweep-2026-11-10.md" "$wt" "$R"
    done
    for k in $(seq 1 "$nn"); do
        br="nw$k"; wt=$(mk_wt "$R" "wn$k" "$br"); NOWORK_WTS="$NOWORK_WTS $wt"
        mk_doc "$DD/HIMMEL-9-N$((nm + k))-sweep-2026-11-10.md" "$wt"
        mk_rec "$S" "$((nm + k))" "$DD/HIMMEL-9-N$((nm + k))-sweep-2026-11-10.md" "$wt" "$R"
    done
}

# ======================================================================
echo "ROW: 10 records, 2 residue: 1 list call"
reset_logs
build_world a 6 2
wt=$(mk_wt "$R" wr9 push9); tip=$(wt_commit "$wt" g9.txt "pushed, no PR"); push_ref "$R" push9 "$tip"
mk_doc "$DD/HIMMEL-9-N9-sweep-2026-11-10.md" "$wt"; mk_rec "$S" 9 "$DD/HIMMEL-9-N9-sweep-2026-11-10.md" "$wt" "$R"
wt10=$(mk_wt "$R" wr10 open10); tip10=$(wt_commit "$wt10" h10.txt "open PR"); push_ref "$R" open10 "$tip10"
mk_doc "$DD/HIMMEL-9-N10-sweep-2026-11-10.md" "$wt10" 900 "$tip10"; mk_rec "$S" 10 "$DD/HIMMEL-9-N10-sweep-2026-11-10.md" "$wt10" "$R"
list_row owner/repo owner/repo open10 open "$tip10"
rc=0; run_sweep "$S" || rc=$?
check "10 records: the drain returns 0" "$rc" "0"
check "10 records, 2 residue: exactly 1 list call" "$(lines "$PRCACHE_LOG")" "1"
check "10 records: the list call ran from the repo" "$(cut -d'|' -f1 "$PRCACHE_LOG" 2>/dev/null | head -n 1)" "$R"
for k in 1 2 3 4 5 6; do absent "10 records: merged-local worktree $k pruned" "$R/.claude/worktrees/wm$k"; done
for k in 1 2; do absent "10 records: no-work worktree $k pruned" "$R/.claude/worktrees/wn$k"; done
absent "10 records: residue pushed-no-PR worktree pruned (R6)" "$R/.claude/worktrees/wr9"
exists "10 records: residue open-PR worktree kept (R1)" "$R/.claude/worktrees/wr10"
check "10 records: all ten leave pending/" "$(njson "$S/done")/$(njson "$S/pending")" "10/0"
nd=0; for k in 1 2 3 4 5 6 7 8 9 10; do case "$(rec_field "$S" "N$k" digest)" in digest=*) nd=$((nd + 1)) ;; esac; done
check "every record of the 10 carries a digest= result in done/" "$nd" "10"
check "the 10 records were digested once each" "$(lines "$DIGEST_LOG")" "10"
check "10 records: the gh log is empty" "$(lines "$GH_LOG")" "0"
check "10 records: the open-PR record is kept, not failed" "$(rec_where "$S" N10)/$(rec_field "$S" N10 prune)" "done/kept"

echo "ROW: 10 records, no residue: 0 list calls"
reset_logs
build_world b 6 4
run_sweep "$S"
check "10 records, no residue: 0 list calls" "$(lines "$PRCACHE_LOG")" "0"
left=0; for k in 1 2 3 4 5 6; do [ -d "$R/.claude/worktrees/wm$k" ] && left=$((left + 1)); done
for k in 1 2 3 4; do [ -d "$R/.claude/worktrees/wn$k" ] && left=$((left + 1)); done
check "10 records, no residue: every worktree pruned" "$left" "0"
check "10 records, no residue: the gh log is empty" "$(lines "$GH_LOG")" "0"

echo "ROW: two repos, each with residue: 1 list call per repo (R16 adopter)"
reset_logs
RA="$W/repo-ta"; RB="$W/repo-tb"; S="$W/state-two"; DD="$W/docs-two"
mk_repo "$RA" owner/repo; wta=$(mk_wt "$RA" wa pusha); tipa=$(wt_commit "$wta" a1.txt "A"); push_ref "$RA" pusha "$tipa"
mk_repo "$RB" adopt/other; wtb=$(mk_wt "$RB" wb openb); tipb=$(wt_commit "$wtb" b1.txt "B"); push_ref "$RB" openb "$tipb"
mk_doc "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$wta"; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$wta" "$RA"
mk_doc "$DD/HIMMEL-9-N2-sweep-2026-11-10.md" "$wtb" 77 "$tipb"; mk_rec "$S" 2 "$DD/HIMMEL-9-N2-sweep-2026-11-10.md" "$wtb" "$RB"
list_row adopt/other adopt/other openb open "$tipb"
run_sweep "$S"
check "two repos, each with residue: 2 list calls" "$(lines "$PRCACHE_LOG")" "2"
check "two repos: one call ran from each repo" "$(cut -d'|' -f1 "$PRCACHE_LOG" 2>/dev/null | sort | tr '\n' ' ')" "$(printf '%s\n%s\n' "$RA" "$RB" | sort | tr '\n' ' ')"
contains "two repos: the adopter's list was read with its own nwo" "$(cat "$PRCACHE_LOG" 2>/dev/null)" "|adopt/other|"
absent "two repos: the himmel-side pushed worktree pruned" "$wta"
exists "adopter repo: the adopter's open-PR worktree is kept" "$wtb"

echo "ROW: every prune is worktree.sh prune --only <wt> --only-allow-unmerged --pr-cache <file> from the record's repo (I3)"
reset_logs
export CLEAN_SH_BIN="$W/stubs/clean.sh" GIT_REFUSE=1
build_world c 1 1
wt=$(mk_wt "$R" wr3 push3); tip=$(wt_commit "$wt" g3.txt "p"); push_ref "$R" push3 "$tip"
mk_doc "$DD/HIMMEL-9-N3-sweep-2026-11-10.md" "$wt"; mk_rec "$S" 3 "$DD/HIMMEL-9-N3-sweep-2026-11-10.md" "$wt" "$R"
RC2="$W/repo-c2"; mk_repo "$RC2" adopt/two; wt2=$(mk_wt "$RC2" w2 nw9)
mk_doc "$DD/HIMMEL-9-N4-sweep-2026-11-10.md" "$wt2"; mk_rec "$S" 4 "$DD/HIMMEL-9-N4-sweep-2026-11-10.md" "$wt2" "$RC2"
run_sweep "$S"
check "I3: one clean.sh call per record" "$(grep -c '^/' "$CLEAN_LOG" 2>/dev/null)" "4"
for k in 1 2 3; do
    case $k in 1) w="$R/.claude/worktrees/wm1"; rp="$R" ;; 2) w="$R/.claude/worktrees/wn1"; rp="$R" ;; 3) w="$wt"; rp="$R" ;; esac
    contains "I3: the call for $w is from its repo with the exact argv" "$(cat "$CLEAN_LOG")" "$rp|--only $w --only-allow-unmerged --pr-cache $S/"
done
contains "I3: the adopter record is pruned from the adopter repo" "$(cat "$CLEAN_LOG")" "$RC2|--only $wt2 --only-allow-unmerged --pr-cache $S/"
contains "I3: the cache file existed when clean.sh ran" "$(cat "$CLEAN_LOG")" "clean-stub: cache file exists"
check "I3: the sweep ran no git worktree remove and no git branch -D" "$(grep -cE ' worktree remove | branch -D | branch -d ' "$GIT_LOG" 2>/dev/null)" "0"
reset_logs

echo "ROW: delete rules, merged proof with gh stubbed to fail (R1 R2 R5 R6 R7 R8 R15 R17)"
reset_logs
R="$W/repo-d"; S="$W/state-d"; DD="$W/docs-d"; mk_repo "$R" owner/repo
w_m=$(mk_wt "$R" m m-br); t_m=$(wt_commit "$w_m" fm.txt "m")
w_r2=$(mk_wt "$R" r2 r2-br); h_r2=$(wt_commit "$w_r2" f2.txt "r2")
w_r7=$(mk_wt "$R" r7 r7-br); t_r7=$(wt_commit "$w_r7" f7.txt "r7")
w_r8=$(mk_wt "$R" r8 r8-br); t_r8=$(wt_commit "$w_r8" f8.txt "r8")
w_r17=$(mk_wt "$R" r17 r17-br)
setline() { sed "${2}s/.*/$3/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
setline "$w_r17/a.txt" 2 "H-two"; echo c > "$w_r17/c17.txt"; g "$w_r17" add -A; g "$w_r17" commit -q -m "r17 head"; t_r17=$(g "$w_r17" rev-parse HEAD)
g "$R" checkout -q -b h2 "$BASE"; setline "$R/a.txt" 2 "H2-two"; echo c > "$R/c17.txt"; g "$R" add -A; g "$R" commit -q -m "rewritten head"; h2_tip=$(g "$R" rev-parse HEAD)
g "$R" checkout -q main
squash_main "$R" m-br "feat: m (#301)"; squash_main "$R" r2-br "feat: r2 (#302)"; squash_main "$R" r7-br "feat: r7 (#307)"
squash_main "$R" r8-br "feat: r8 (#308)"; squash_main "$R" h2 "feat: r17 (#317)"
wt_commit "$w_r2" after.txt "one commit past the READY head" >/dev/null
echo staged >> "$w_r7/f7.txt"; g "$w_r7" add f7.txt
echo notes > "$w_r8/notes-forgotten.txt"
w_r1=$(mk_wt "$R" r1 r1-br); t_r1=$(wt_commit "$w_r1" f1.txt "r1"); push_ref "$R" r1-br "$t_r1"
w_r5=$(mk_wt "$R" r5 r5-br); wt_commit "$w_r5" f5a.txt "5a" >/dev/null; wt_commit "$w_r5" f5b.txt "5b" >/dev/null
w_r6=$(mk_wt "$R" r6 r6-br); t_r6a=$(wt_commit "$w_r6" f6.txt "6a"); push_ref "$R" r6-br "$t_r6a"; wt_commit "$w_r6" f6b.txt "6b" >/dev/null
w_15a=$(mk_wt "$R" r15a r15a-br); w_15b=$(mk_wt "$R" r15b r15b-br)
mk_doc "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$w_m" 301 "$t_m"
mk_doc "$DD/HIMMEL-9-N2-sweep-2026-11-10.md" "$w_r2" 302 "$h_r2"
mk_doc "$DD/HIMMEL-9-N3-sweep-2026-11-10.md" "$w_r7" 307 "$t_r7"
mk_doc "$DD/HIMMEL-9-N4-sweep-2026-11-10.md" "$w_r8" 308 "$t_r8"
mk_doc "$DD/HIMMEL-9-N5-sweep-2026-11-10.md" "$w_r17" 317 "$t_r17"
mk_doc "$DD/HIMMEL-9-N6-sweep-2026-11-10.md" "$w_r1" 906 "$t_r1"
mk_doc "$DD/HIMMEL-9-N7-sweep-2026-11-10.md" "$w_r5"
mk_doc "$DD/HIMMEL-9-N8-sweep-2026-11-10.md" "$w_r6"
mk_doc "$DD/HIMMEL-9-N9-sweep-2026-11-10.md" "$(printf '%s\n%s' "$w_15a" "$w_15b")"
n=1; for w in "$w_m" "$w_r2" "$w_r7" "$w_r8" "$w_r17" "$w_r1" "$w_r5" "$w_r6"; do mk_rec "$S" "$n" "$DD/HIMMEL-9-N$n-sweep-2026-11-10.md" "$w" "$R"; n=$((n + 1)); done
mk_rec "$S" 9 "$DD/HIMMEL-9-N9-sweep-2026-11-10.md" "$(printf '%s\n%s' "$w_15a" "$w_15b")" "$R"
list_row owner/repo owner/repo r1-br open "$t_r1"
list_row owner/repo owner/repo r2-br merged "$h_r2"
list_row owner/repo owner/repo r17-br merged "$h2_tip"
run_sweep "$S"
absent "merged proof with gh stubbed to fail: the merged-local worktree is pruned" "$w_m"
exists "R1 open PR: kept" "$w_r1"
exists "R2 commit past the merged head: kept" "$w_r2"
exists "R5 no PR, two unpushed commits: kept" "$w_r5"
exists "R6 one unpushed commit past the pushed head: kept" "$w_r6"
exists "R7 merged proof holds, staged edit: kept" "$w_r7"
exists "R8 merged proof holds, untracked notes file: kept" "$w_r8"
exists "R15 two worktrees in the doc: first kept" "$w_15a"
exists "R15 two worktrees in the doc: second kept" "$w_15b"
exists "R17 merge at a rewritten head: kept" "$w_r17"
check "R15 the skip is recorded" "$(rec_field "$S" N9 prune | cut -d: -f1)" "skipped"
check "delete rules: only the open, R2 and R17 and R5/R6 residue went to the list (one call)" "$(lines "$PRCACHE_LOG")" "1"
check "merged proof with gh stubbed to fail: the gh log is empty" "$(lines "$GH_LOG")" "0"
check "delete rules: none of the kept records is in failed/" "$(njson "$S/failed")" "0"

echo "ROW: R10 a successor holds its lock before the sweep: no reap, no prune, digest still runs"
reset_logs
build_world e 1 0
rm -f "$S"/pending/*.json
RES="$HANDOVER_DIR/u/e/HIMMEL-9-N1b-sweep-2026-11-10-RESUME.md"
DOC1="$HANDOVER_DIR/u/e/HIMMEL-9-N1-sweep-2026-11-10.md"
mk_doc "$DOC1" "$R/.claude/worktrees/wm1" 101 "$TIP_1"
mk_doc "$RES" "/nowhere/else"; printf -- '- 10:40 LIVE - resumed\n' >> "$RES"
mk_rec "$S" 1 "$DOC1" "$R/.claude/worktrees/wm1" "$R" >/dev/null
bash "$ROOT/scripts/handover/queue-lock.sh" acquire "$RES" >/dev/null 2>&1; LOCK_DOCS="$LOCK_DOCS $RES"
run_sweep "$S"
exists "R10: the worktree is kept" "$R/.claude/worktrees/wm1"
check "R10: prune and reap are kept-successor" "$(rec_field "$S" N1 prune)/$(rec_field "$S" N1 reap)" "kept-successor/kept-successor"
check "R10: no reap ran" "$(lines "$REAP_LOG")" "0"
check "R10: the digest still ran" "$(lines "$DIGEST_LOG")" "1"
bash "$ROOT/scripts/handover/queue-lock.sh" release "$RES" >/dev/null 2>&1

echo "ROW: successor takes its lock between phase A and phase B"
reset_logs
build_world f 1 0
rm -f "$S"/pending/*.json
RES="$HANDOVER_DIR/u/f/HIMMEL-9-N1b-between-2026-11-10-RESUME.md"
DOC1="$HANDOVER_DIR/u/f/HIMMEL-9-N1-between-2026-11-10.md"
mk_doc "$DOC1" "$R/.claude/worktrees/wm1" 101 "$TIP_1"
mk_doc "$RES" "/nowhere/else"; printf -- '- 10:40 LIVE - resumed\n' >> "$RES"
mk_rec "$S" 1 "$DOC1" "$R/.claude/worktrees/wm1" "$R" >/dev/null
printf '#!/usr/bin/env bash\nbash "%s/scripts/handover/queue-lock.sh" acquire "%s" > "%s/hook.out" 2>&1\n' "$ROOT" "$RES" "$W" > "$W/fetch-hook.sh"
export FETCH_HOOK="$W/fetch-hook.sh"
run_sweep "$S"; LOCK_DOCS="$LOCK_DOCS $RES"
exists "successor between the phases: the worktree is kept" "$R/.claude/worktrees/wm1"
check "successor between the phases: prune=kept-successor" "$(rec_field "$S" N1 prune)" "kept-successor"
check "successor between the phases: the reap ran in phase A (dry run, then apply)" "$(lines "$REAP_LOG")" "2"
bash "$ROOT/scripts/handover/queue-lock.sh" release "$RES" >/dev/null 2>&1
unset FETCH_HOOK

echo "ROW: empty repo field"
reset_logs
build_world g 2 0
wt1="$R/.claude/worktrees/wm1"
first_rec=$(find "$S/pending" -name '*.json' | sort | head -n 1)
jq '.repo = ""' "$first_rec" > "$W/rec.tmp" && mv "$W/rec.tmp" "$first_rec"
run_sweep "$S"
check "empty repo field: prune=skipped-no-repo" "$(rec_field "$S" N1 prune)" "skipped-no-repo"
exists "empty repo field: the worktree is untouched" "$wt1"
absent "empty repo field: the other record is pruned" "$R/.claude/worktrees/wm2"
check "empty repo field: one fetch (the other record's repo)" "$(grep -c -- '--no-write-fetch-head' "$GIT_LOG")" "1"
check "empty repo field: the record still carries its digest" "$(rec_field "$S" N1 digest | cut -c1-7)" "digest="

echo "ROW: pr-cache failure keeps (R12) and a refused cache is kept, not PRUNE-FAILED"
reset_logs
R="$W/repo-h"; S="$W/state-h"; DD="$W/docs-h"; mk_repo "$R" owner/repo
w1=$(mk_wt "$R" h1 hpush); t1=$(wt_commit "$w1" h1.txt "h1"); push_ref "$R" hpush "$t1"
mk_doc "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$w1"; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$w1" "$R"
export PRCACHE_FAIL=1
run_sweep "$S"
exists "R12: the worktree is kept" "$w1"
check "R12: prune=kept-unknown" "$(rec_field "$S" N1 prune)" "kept-unknown"
unset PRCACHE_FAIL
rm -rf "$S"; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$w1" "$R"
export PRCACHE_NWO=yotamleo-org/Himmel
run_sweep "$S"
exists "refused cache (rc 2): the worktree is kept" "$w1"
check "refused cache: logged as kept, in done/" "$(rec_where "$S" N1)/$(rec_field "$S" N1 prune | cut -d: -f1)" "done/kept"
lacks "refused cache: not logged as PRUNE-FAILED" "$(sweep_out)" "PRUNE-FAILED"
unset PRCACHE_NWO

echo "ROW: cache files are per run"
reset_logs
export CLEAN_SH_BIN="$W/stubs/clean.sh"
build_world i 1 1
wt=$(mk_wt "$R" wi3 pushi); tip=$(wt_commit "$wt" gi.txt "p"); push_ref "$R" pushi "$tip"
mk_doc "$DD/HIMMEL-9-N3-sweep-2026-11-10.md" "$wt"; mk_rec "$S" 3 "$DD/HIMMEL-9-N3-sweep-2026-11-10.md" "$wt" "$R"
printf '# nwo=owner/repo\n# scope=all\n# complete rows=0\n' > "$S/stale.all"
run_sweep "$S"
check "cache files: the planted stale file is never passed to clean.sh" "$(grep -c 'stale.all' "$CLEAN_LOG")" "0"
check "cache files: nothing but the records, the lock and the stamp remains under the state dir" \
    "$(cd "$S" && find . -type f ! -name '*.json' ! -name sweep.lock ! -name last ! -name stale.all | grep -c .)" "0"
reset_logs

echo "ROW: lock held"
reset_logs
build_world j 1 0
mkdir -p "$S"
flock "$S/sweep.lock" sleep 6 & HOLDER=$!; PIDS="$PIDS $HOLDER"
sleep 1
t0=$(now); run_sweep "$S"; rc=$?; t1=$(now)
check "lock held: the second drain exits 0" "$rc" "0"
check "lock held: it returns at once" "$([ $((t1 - t0)) -le 3 ] && echo fast || echo slow)" "fast"
check "lock held: it processes nothing" "$(rec_where "$S" N1)/$(lines "$DIGEST_LOG")" "pending/0"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo "ROW: two phases"
reset_logs
export CLEAN_SH_BIN="$W/stubs/clean.sh"
build_world k 3 0
wt=$(mk_wt "$R" wk4 pushk); tip=$(wt_commit "$wt" gk.txt "p"); push_ref "$R" pushk "$tip"
mk_doc "$DD/HIMMEL-9-N4-sweep-2026-11-10.md" "$wt"; mk_rec "$S" 4 "$DD/HIMMEL-9-N4-sweep-2026-11-10.md" "$wt" "$R"
run_sweep "$S"
last_a=$(grep -n '^ORDER \(digest\|cost\|capture\)$' "$ORDER_LOG" | tail -n 1 | cut -d: -f1)
first_b=$(grep -n '^ORDER \(fetch\|prcache\)$' "$ORDER_LOG" | head -n 1 | cut -d: -f1)
check "two phases: there are phase A and phase B calls" "$([ -n "$last_a" ] && [ -n "$first_b" ] && echo yes)" "yes"
check "two phases: every digest and cost call is logged before the first fetch or list call" "$([ "${last_a:-99}" -lt "${first_b:-0}" ] && echo yes)" "yes"
reset_logs

echo "ROW: fetch form"
reset_logs
R="$W/repo-m"; S="$W/state-m"; DD="$W/docs-m"; mk_repo "$R" owner/repo
"$REAL_GIT" init -q --bare -b main "$W/m-origin.git"
g "$R" push -q "$W/m-origin.git" main 2>/dev/null
g "$R" config remote.origin.url "$W/m-origin.git"
: > "$R/.git/FETCH_HEAD"; touch -d '2020-01-01 00:00:00' "$R/.git/FETCH_HEAD" # gnu-ok: Linux-only suite
w1=$(mk_wt "$R" m1 mfeat); w2=$(mk_wt "$R" m2 mfeat2)
mk_doc "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$w1"; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$w1" "$R"
mk_doc "$DD/HIMMEL-9-N2-sweep-2026-11-10.md" "$w2"; mk_rec "$S" 2 "$DD/HIMMEL-9-N2-sweep-2026-11-10.md" "$w2" "$R"
export REAL_FETCH=1
before=$(stat -c %Y "$R/.git/FETCH_HEAD") # gnu-ok: Linux-only suite (platform guard above)
run_sweep "$S"
fl=$(grep -- '--no-write-fetch-head' "$GIT_LOG")
check "fetch form: one fetch for two records of one repo" "$(printf '%s\n' "$fl" | grep -c .)" "1"
contains "fetch form: carries core.hooksPath=/dev/null" "$fl" "core.hooksPath=/dev/null"
contains "fetch form: carries --prune --quiet origin" "$fl" "--prune --quiet --no-write-fetch-head origin"
contains "fetch form: is run against the repo" "$fl" "-C $R"
check "fetch form: the primary's FETCH_HEAD mtime is unchanged" "$(stat -c %Y "$R/.git/FETCH_HEAD")" "$before" # gnu-ok: Linux-only suite
unset REAL_FETCH
reset_logs

echo "ROW: --status"
S="$W/state-st"; mkdir -p "$S/pending" "$S/failed" "$S/done"
echo '{}' > "$S/pending/1-N1.json"; echo '{}' > "$S/pending/2-N2.json"; echo '{}' > "$S/failed/3-N3.json"; echo '{}' > "$S/done/4-N4.json"; echo 1700000000 > "$S/last"
snap_before=$(cd "$S" && find . -type f -o -type d | sort | tr '\n' ' '; cksum "$S"/pending/* "$S/last")
out=$(CLOSE_SWEEP_STATE_DIR="$S" bash "$SWEEP" --status 2>&1); rc=$?
check "--status prints pending, failed and last" "$out" "close-sweep: pending=2 failed=1 last=1700000000"
check "--status exits 0" "$rc" "0"
snap_after=$(cd "$S" && find . -type f -o -type d | sort | tr '\n' ' '; cksum "$S"/pending/* "$S/last")
check "--status writes nothing" "$snap_after" "$snap_before"
check "--status on a missing state dir" "$(CLOSE_SWEEP_STATE_DIR="$W/no-such-state" bash "$SWEEP" --status 2>&1)" "close-sweep: pending=0 failed=0 last=0"
absent "--status creates no state dir" "$W/no-such-state"

echo "ROW: capture and cost, claimed-elsewhere"
reset_logs
S="$W/state-cc"; DD="$W/docs-cc"
SID=4670c3a0-1111-4000-8000-000000000001
printf '{"type":"x","cwd":"/x","sessionId":"%s"}\n' "$SID" > "$PROJECTS/-x/$SID.jsonl"
mk_doc "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" ""; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "" "" "$GONE_PID" "" "$(now)" "$SID"
run_sweep "$S"
check "capture: the transcript is found by session id and captured once" "$(grep -c '"transcript_path"' "$CAPTURE_LOG")" "1"
contains "capture: the payload names the transcript, session and reason" "$(cat "$CAPTURE_LOG")" "\"session_id\": \"$SID\""
contains "capture: reason worker-close" "$(cat "$CAPTURE_LOG")" "worker-close"
check "capture: recorded as ok" "$(rec_field "$S" N1 capture)" "ok"
check "cost: one ledger row for the session" "$(grep -c "\"session\":\"$SID\"" "$WORKER_SESSION_COST_LEDGER")" "1"
S="$W/state-cc2"
mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "" "" "$GONE_PID" "" "$(now)" "$SID"
slug="$(printf '%s' "$SID" | tr -c 'A-Za-z0-9_-' '_')-$(printf '%s' "$SID" | cksum | awk '{print $1}')"
mkdir -p "$HOME/.claude/logs/end-session-wiki/captured/$slug"
run_sweep "$S"
check "capture: a taken slot is logged capture=claimed-elsewhere" "$(rec_field "$S" N1 capture)" "claimed-elsewhere"
check "capture: the capture helper is not called when the slot is taken" "$(grep -c '"transcript_path"' "$CAPTURE_LOG")" "1"
check "cost: a second record of the same session adds no ledger row" "$(grep -c "\"session\":\"$SID\"" "$WORKER_SESSION_COST_LEDGER")" "1"
rm -rf "$HOME/.claude/logs/end-session-wiki/captured/$slug"
reset_logs

echo "ROW: a sweep killed after record 4 and re-run digests 5 to 10 once, 1 to 4 not again"
reset_logs
S="$W/state-kill"; DD="$W/docs-kill"
for k in 1 2 3 4 5 6 7 8 9 10; do mk_doc "$DD/HIMMEL-9-N$k-sweep-2026-11-10.md" ""; mk_rec "$S" "$k" "$DD/HIMMEL-9-N$k-sweep-2026-11-10.md" "" "" "$GONE_PID" "" "$(( $(now) - 100 + k ))"; done
export DIGEST_KILL_AT=5
run_sweep "$S"
unset DIGEST_KILL_AT
check "kill: the first sweep digested 4 records before it was killed" "$(lines "$DIGEST_LOG")" "4"
check "kill: all ten are still pending" "$(njson "$S/pending")" "10"
run_sweep "$S"
check "kill: the re-run digests 5 to 10, 1 to 4 not again (10 calls in all)" "$(lines "$DIGEST_LOG")" "10"
check "kill: each session was digested exactly once" "$(grep -o '\[4670c3a0-0000-4000-8000-[0-9]*\]' "$DIGEST_LOG" | sort | uniq -c | awk '{print $1}' | sort -u | tr '\n' ' ')" "1 "
check "kill: all ten end in done/ with a digest" "$(njson "$S/done")" "10"
reset_logs

echo "ROW: a failed prune is logged and does not stop the drain"
reset_logs
cat > "$W/stubs/clean-fail.sh" <<'STUB'
#!/usr/bin/env bash
echo "ERR clean-garden: boom"
exit 1
STUB
chmod +x "$W/stubs/clean-fail.sh"
export CLEAN_SH_BIN="$W/stubs/clean-fail.sh"
build_world r 2 0
rc=0; run_sweep "$S" || rc=$?
check "failed prune: the drain returns 0" "$rc" "0"
check "failed prune: both records are in failed/" "$(njson "$S/failed")/$(njson "$S/pending")" "2/0"
check "failed prune: PRUNE-FAILED is logged for each" "$(sweep_out | grep -c 'close-sweep: PRUNE-FAILED')" "2"
contains "failed prune: the helper output is logged" "$(sweep_out)" "ERR clean-garden: boom"
reset_logs

echo "ROW: a record that cannot be saved stays in pending/"
reset_logs
build_world s 1 0
chmod 555 "$S/pending"
if ( : > "$S/pending/.probe" ) 2>/dev/null; then
    rm -f "$S/pending/.probe"; chmod 755 "$S/pending"
    echo "  SKIP: unsaved record: this user can write a mode-555 directory (root), so the row cannot be built here"
else
    rc=0; run_sweep "$S" || rc=$?
    chmod 755 "$S/pending"
    check "unsaved record: the drain returns 0" "$rc" "0"
    check "unsaved record: it stays in pending/" "$(rec_where "$S" N1)" "pending"
    contains "unsaved record: the failure is logged" "$(sweep_out)" "left in pending/"
    lacks "unsaved record: it is never logged as moved" "$(sweep_out)" "-> done"
fi

echo "ROW: pid stays alive"
reset_logs
S="$W/state-alive"; DD="$W/docs-alive"
sleep 300 & LP=$!; PIDS="$PIDS $LP"; ps=$(proc_start_of "$LP")
mk_doc "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" ""; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "" "" "$LP" "$ps"
rc=0; timeout 60 env CLOSE_SWEEP_STATE_DIR="$S" bash "$SWEEP" --drain > "$W/sweep.out" 2>&1 || rc=$? # gnu-ok: Linux-only suite
check "pid alive: the first drain returns" "$rc" "0"
check "pid alive: left in pending/ with sweeps_seen=1" "$(rec_where "$S" N1)/$(rec_field "$S" N1 sweeps_seen)" "pending/1"
check "pid alive: digested on the first sweep, with --pid" "$(grep -c "\[--pid\]\[$LP\]" "$DIGEST_LOG")" "1"
run_sweep "$S"
check "pid alive: still pending after the second sweep with sweeps_seen=2" "$(rec_where "$S" N1)/$(rec_field "$S" N1 sweeps_seen)" "pending/2"
run_sweep "$S"
check "pid alive: the third sweep moves it to done/ kept-alive" "$(rec_where "$S" N1)/$(rec_field "$S" N1 reap)/$(rec_field "$S" N1 prune)" "done/kept-alive/kept-alive"
check "pid alive: the digest stub logged exactly one call" "$(lines "$DIGEST_LOG")" "1"
kill "$LP" 2>/dev/null

echo "ROW: reused pid"
reset_logs
build_world n 1 0
sleep 300 & LP=$!; PIDS="$PIDS $LP"
rm -rf "$S"; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$R/.claude/worktrees/wm1" "$R" "$LP" "1"
run_sweep "$S"
check "reused pid: counted gone, the digest got --pid \"\"" "$(grep -c '\[--pid\]\[\]\[--projects\]' "$DIGEST_LOG")" "1"
check "reused pid: reaped (dry run, then apply)" "$(lines "$REAP_LOG")" "2"
absent "reused pid: pruned as a gone pid" "$R/.claude/worktrees/wm1"
kill "$LP" 2>/dev/null

echo "ROW: 10-minute bound"
reset_logs
S="$W/state-600"; DD="$W/docs-600"
sleep 300 & LP=$!; PIDS="$PIDS $LP"; ps=$(proc_start_of "$LP")
mk_doc "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" ""; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "" "" "$LP" "$ps" "$(( $(now) - 601 ))"
CLOSE_SWEEP_PID_WAIT=60 run_sweep "$S"
check "10-minute bound: leaves pending/ on its first sweep, kept-alive" "$(rec_where "$S" N1)/$(rec_field "$S" N1 prune)" "done/kept-alive"
kill "$LP" 2>/dev/null

echo "ROW: pid gone during the digest"
reset_logs
build_world p 1 0
sleep 2 & LP=$!; PIDS="$PIDS $LP"; ps=$(proc_start_of "$LP")
rm -rf "$S"; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$R/.claude/worktrees/wm1" "$R" "$LP" "$ps"
export DIGEST_SLEEP=3
CLOSE_SWEEP_PID_WAIT=1 run_sweep "$S"
unset DIGEST_SLEEP
check "pid gone during the digest: the digest was passed --pid" "$(grep -c "\[--pid\]\[$LP\]" "$DIGEST_LOG")" "1"
check "pid gone during the digest: reaped in that sweep" "$(lines "$REAP_LOG")" "2"
absent "pid gone during the digest: pruned in that sweep" "$R/.claude/worktrees/wm1"
check "pid gone during the digest: done/ pruned" "$(rec_where "$S" N1)/$(rec_field "$S" N1 prune)" "done/pruned"

echo "ROW: pid wait is a deadline"
reset_logs
S="$W/state-dl"; DD="$W/docs-dl"; t=$(now)
for k in 1 2 3 4 5; do
    sleep 60 & LP=$!; PIDS="$PIDS $LP"; ps=$(proc_start_of "$LP")
    mk_doc "$DD/HIMMEL-9-N$k-sweep-2026-11-10.md" ""
    mk_rec "$S" "$k" "$DD/HIMMEL-9-N$k-sweep-2026-11-10.md" "" "" "$LP" "$ps" "$((t + 2 * (k - 1)))"
done
t0=$(now); CLOSE_SWEEP_PID_WAIT=4 run_sweep "$S"; t1=$(now)
el=$((t1 - t0))
check "pid wait is a deadline: about 12 s in total (newest closed_at plus 4 s), not 20 s" "$([ "$el" -ge 11 ] && [ "$el" -le 16 ] && echo ok || echo "elapsed=$el")" "ok"
check "pid wait is a deadline: all five were digested once" "$(lines "$DIGEST_LOG")" "5"
for p in $PIDS; do kill "$p" 2>/dev/null; done; PIDS=""

echo "ROW: drain race (the pause seam)"
reset_logs
S="$W/state-race"; DD="$W/docs-race"
sleep 300 & LP=$!; PIDS="$PIDS $LP"; ps=$(proc_start_of "$LP")
mk_doc "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" ""; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "" "" "$LP" "$ps"
PAUSE="$W/pause"; : > "$PAUSE"
CLOSE_SWEEP_STATE_DIR="$S" CLOSE_SWEEP_TEST_PAUSE_FILE="$PAUSE" bash "$SWEEP" --drain > "$W/sweep.out" 2>&1 & DR=$!
i=0; while [ ! -e "$PAUSE.blocked" ] && [ "$i" -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
check "drain race: the drain blocks on the pause file between its last scan and its release" "$([ -e "$PAUSE.blocked" ] && echo blocked)" "blocked"
mk_doc "$DD/HIMMEL-9-N2-sweep-2026-11-10.md" ""; mk_rec "$S" 2 "$DD/HIMMEL-9-N2-sweep-2026-11-10.md" "" "" "$GONE_PID" "" "$(( $(now) + 1 ))"
rm -rf "$S"/run.* # another drain taking the lock in the free window removes this run's directory as stale
rm -f "$PAUSE"
i=0; while kill -0 "$DR" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
check "drain race: the new record was processed before the holder exited" "$(rec_where "$S" N2)" "done"
check "drain race: a record already seen in the run is not re-taken" "$(grep -c "\[$(rec_field "$S" N1 sid)\]" "$DIGEST_LOG")" "1"
check "drain race: the seen record stays pending" "$(rec_where "$S" N1)" "pending"
kill "$LP" 2>/dev/null

echo "ROW: pid exits at 25 s (the real digest step, a 60 s wait)"
reset_logs
build_world q 1 0
unset WORKER_SESSION_DIGEST_STEP_BIN
export WORKER_SESSION_DIGEST_BIN="$W/stubs/digestbin.sh" WORKER_SESSION_DIGEST_STATE_DIR="$W/dg-state" \
    HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$W/dg-fail.jsonl" HIMMEL_EVAL_RUNS_LEDGER="$W/dg-eval.jsonl"
export WORKER_SESSION_DIGEST_SETTLE_MAX=15 WORKER_SESSION_DIGEST_SETTLE_QUIET=3
SID25=4670c3a0-2222-4000-8000-000000000001
printf '{"type":"x","cwd":"/x","sessionId":"%s"}\n' "$SID25" > "$PROJECTS/-x/$SID25.jsonl"
printf '#!/usr/bin/env bash\nprintf '"'"'{"digest_v":1,"mapper_v":1,"trajectory_v":null,"session":"%s","status":"ok","model":null,"metrics":{},"failures":[]}\\n'"'"'\n' "$SID25" > "$W/stubs/digestbin.sh"
chmod +x "$W/stubs/digestbin.sh"
sleep 25 & LP=$!; PIDS="$PIDS $LP"; ps=$(proc_start_of "$LP")
rm -rf "$S"; mk_rec "$S" 1 "$DD/HIMMEL-9-N1-sweep-2026-11-10.md" "$R/.claude/worktrees/wm1" "$R" "$LP" "$ps" "$(now)" "$SID25"
CLOSE_SWEEP_PID_WAIT=60 run_sweep "$S"
check "pid exits at 25 s: one drain ends with the record in done/" "$(rec_where "$S" N1)" "done"
contains "pid exits at 25 s: digest=ok" "$(rec_field "$S" N1 digest)" "digest=ok"
check "pid exits at 25 s: the reap applied" "$(lines "$REAP_LOG")" "2"
check "pid exits at 25 s: prune=pruned" "$(rec_field "$S" N1 prune)" "pruned"
export WORKER_SESSION_DIGEST_STEP_BIN="$W/stubs/digest.sh"
unset WORKER_SESSION_DIGEST_BIN WORKER_SESSION_DIGEST_SETTLE_MAX WORKER_SESSION_DIGEST_SETTLE_QUIET

echo
echo "test-close-sweep: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
