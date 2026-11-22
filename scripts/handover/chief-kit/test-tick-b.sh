#!/usr/bin/env bash
# test-tick-b.sh — the second half of test-tick.sh: the batched chief tick rows from the UNVERIFIED lock state on.
#
# PLATFORM GUARD: The chief kit is Linux-only
# (pgrep, atq, /tmp suite locks, and claudex/konsole); this Bash 3.2 suite
# exercises that platform-specific script.
# selector: names chokepoint-seam-guard.sh claude-sessions.sh orphan-loops.sh
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail, so A && B || C is if-then-else here
# shellcheck disable=SC2153  # REPO is exported by the sourced tick-test-fixture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Fail closed: a missing or broken fixture must fail the suite, never run it with zero rows.
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
iso_ago() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ; }
# --- a lock queue-lock can neither attribute to this doc nor rule
# out (status `held -- UNVERIFIED`, rc 11) reads UNVERIFIED -- never FREE, which
# the chief reads as "reclaim it", and never folded into WRAPPED by the worker's
# own tail. RED control (pre-fix tick.sh): workers=N380:UNKNOWN.
u3290="HIMMEL-3380-N380-unverified-2026-09-22-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$u3290.md"
contains 'an unattributable lock reads UNVERIFIED, not FREE/WRAPPED/UNKNOWN' "$(bash "$SUT" --workers "$W/handover/$u3290.md" 2>/dev/null)" 'workers=N380:UNVERIFIED '

# --- a past-TTL lock whose owner is provably dead (status
# `STALE-DEAD`, rc 12) reads STALE-DEAD and is NOT a held leg: it must not
# fold into the FRESH/STALE held set. RED control (pre-fix tick.sh):
# workers=N390:STALE.
d5541="HIMMEL-5541-N390-stale-dead-2026-10-01-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' > "$W/handover/$d5541.md"
out5541="$(bash "$SUT" --workers "$W/handover/$d5541.md" 2>/dev/null)"
contains 'a past-TTL dead-owner lock reads STALE-DEAD' "$out5541" 'workers=N390:STALE-DEAD '
not_contains 'a STALE-DEAD lock is not folded into STALE' "$out5541" 'workers=N390:STALE '

# --- board=<ok|STALE:<age>|MISSING|skip> -- the chief's progress
# board (<doc stem>.board.json, written by board.mjs next to the chief doc) must be
# structurally checked, not remembered. RED control (pre-fix tick.sh): the line
# carries no board= field at all, so a chief that never rendered one, or whose
# board is days old, is invisible to its own tick. The freshness reference is a
# fingerprint of the state a board shows (workers, tails, open PRs, queue, last GO),
# stored in the board JSON by board.mjs and recomputed here -- not the doc's mtime,
# which every Results bullet bumps and would read STALE all day.
b3361="HIMMEL-3361-N361-board-2026-09-21-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' > "$W/handover/$b3361.md"
mkcmdline 361 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3361-N361-board work
mk_pgrep_x "$W/bin-3361" 361
board3361="$W/handover/chief.board.json"
rm -f "$board3361"
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
write_console3361() {  # write_console3361 <last GO value> [extra Results bullet]
    printf '%s\n' '# chief' '' '## Live state' '' \
        'legs: `N361:J-N361-0a1b2c9d:cachyos-x8664-pid361:361`' 'queue: N361 (3361)' "last GO: $1" 'acked: none' ${3:+"$3"} '' \
        '## Results (newest at the bottom)' '- 12:00 DISPATCH N361' ${2:+"$2"} \
        > "$W/handover/chief.md"
}
t3361() { PATH="$W/bin-3361:$PATH" bash "$SUT" --workers "$W/handover/$b3361.md" "$@"; }
out="$(bash "$SUT")"
write_console3361 none
contains 'a chief with no board file reads board=MISSING' "$(t3361)" ' board=MISSING'
# The default fixture has no chief doc at all: nothing to check, like workerset=skip.
contains 'no chief doc reads board=skip' "$out" ' board=skip'
contains '--verbose labels the board' "$(t3361 --verbose)" 'board: MISSING'
# --emit-fp is the seam board.mjs reads: the tick line, then the fingerprint.
fp3361="$(t3361 --emit-fp | sed -n '2p')"
case "$fp3361" in
    board-fp=[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) pass '--emit-fp prints the fingerprint on line 2' ;;
    *) fail "--emit-fp line 2 is not board-fp=<16 hex> ('$fp3361')" ;;
esac
# A board whose fingerprint is not the current one is STALE, aged by its mtime.
printf '%s\n' '{' ' "freshness": {' '  "board_fp": "0000000000000000"' ' }' '}' > "$board3361"
touch -d '3 hours ago' "$board3361"  # gnu-ok: chief kit is Linux-only
contains 'a board with another fingerprint reads board=STALE:<age>' "$(t3361)" ' board=STALE:3h'
touch -d '12 minutes ago' "$board3361"  # gnu-ok: chief kit is Linux-only
contains 'a young stale board ages in minutes' "$(t3361)" ' board=STALE:12m'
# The real generator's output is fresh under the real tick: one derivation. The
# stubs on PATH answer gh/bank/atq for both, so the two runs see the same state.
if command -v node >/dev/null 2>&1; then
    bpath3361="$(PATH="$W/bin-3361:$PATH" BOARD_TICK="$SUT" node "$HERE/board.mjs" --doc "$W/handover/chief.md" --workers "$W/handover/$b3361.md" --repo "$REPO" 2>&1)"
    if [ "$bpath3361" = "$board3361" ] && [ -f "$board3361" ]; then
        pass 'board.mjs writes the board JSON next to the chief doc'
    else
        fail "board.mjs did not write the board ($bpath3361)"
    fi
    contains 'a board rendered from the current state reads board=ok' "$(t3361)" ' board=ok'
    # The freshness is read from board.json, so a board with no static page on disk is not a stale board.
    if compgen -G "$W/handover/*.html" >/dev/null; then fail 'board.mjs left an html page in the bucket'; fi
    contains 'a board with no static page on disk still reads board=ok' "$(t3361)" ' board=ok'
    # A Results bullet is not a state change: the board stays ok.
    write_console3361 none '- 12:05 RULING nothing about state'
    contains 'a Results bullet does not stale the board' "$(t3361)" ' board=ok'
    # A GO is: republish.
    # shellcheck disable=SC2016  # backtick span, literal fixture text
    write_console3361 '`1023:abc`'
    contains 'a new last GO stales the board' "$(t3361)" ' board=STALE:'
    # The epics: and decisions: lines are rendered panels: editing them is a republish.
    write_console3361 none '' 'epics: HIMMEL-3332=5'
    contains 'a new epics: line stales the board' "$(t3361)" ' board=STALE:'
    write_console3361 none '' 'decisions: widen the fleet cap?'
    contains 'a new decisions: line stales the board' "$(t3361)" ' board=STALE:'
    write_console3361 none
    # A worker tail change (READY) is a phase change: republish.
    printf '%s\n' '- 12:30 READY 1023 abc GREEN' >> "$W/handover/$b3361.md"
    contains 'a worker phase change stales the board' "$(t3361)" ' board=STALE:'
    # --- one Live-state block, read by tick.sh and by board.mjs, names
    # the same workers. RED control (pre-fix board.mjs): its own parser accepted a
    # three-field span (N4), an empty-field span (N5), a span in a `>` line (N8) and
    # a detail bullet (N6), and rejected a label with _ . - (N3_x.y-z). The tick
    # reads no --workers here, so every Live-state entry is `unarmed=` and the board,
    # given no worker docs, lists exactly its Live-state labels.
    # shellcheck disable=SC2016  # backtick worker spans, literal fixture text
    printf '%s\n' '# chief' '' '## Live state' '' \
        'legs: `N1:J-N1-0a1b2c9d:cachyos-x8664-pid1001:1001` a note `procs:2` `N2b:J-N2b-0a1b2c9d:cachyos-x8664-pid1002:1002`' \
        '  `N3_x.y-z:J-N3-0a1b2c9d:cachyos-x8664-pid1003:1003` `N4:J-N4-0a1b2c9d:cachyos-x8664-pid1004` `N5::J-N5-0a1b2c9d:1005`' \
        '> quoted `N8:J-N8-0a1b2c9d:cachyos-x8664-pid1008:1008` after a > terminator' \
        'legs: `N7:J-N7-0a1b2c9d:cachyos-x8664-pid1007:1007`' \
        '- detail `N6:J-N6-0a1b2c9d:cachyos-x8664-pid1006:1006` under the block' \
        'queue: none' 'last GO: none' 'acked: none' '' '## Results' '- 12:00 DISPATCH' \
        > "$W/handover/chief.md"
    tickset3366="$(PATH="$W/bin-3361:$PATH" bash "$SUT" --doc "$W/handover/chief.md" | sed -n 's/.* workerset=STALE:unarmed=\([^ ;]*\).*/\1/p' | tr '+' '\n' | sort)"
    PATH="$W/bin-3361:$PATH" BOARD_TICK="$SUT" node "$HERE/board.mjs" --doc "$W/handover/chief.md" --repo "$REPO" --out "$W/handover/board-3366.html" >/dev/null 2>&1
    boardset3366="$(grep -o 'data-label="[^"]*"' "$W/handover/board-3366.html" | sed 's/^data-label="//; s/"$//' | sort)"
    contains 'the tick reads a label with _ . - as a worker' "$tickset3366" 'N3_x.y-z'
    if [ -n "$tickset3366" ] && [ "$tickset3366" = "$boardset3366" ]; then
        pass 'tick.sh and board.mjs read one Live-state block as the same worker set'
    else
        fail "tick.sh and board.mjs read different worker sets (tick: $(printf '%s' "$tickset3366" | tr '\n' ' ') board: $(printf '%s' "$boardset3366" | tr '\n' ' '))"
    fi
else
    printf 'SKIP - board round-trip (node not installed)\n'
fi

# --- a WRAPPED worker (lock free, tail says WRAPPED) whose own
# session process is STILL alive in the census reads CLOSABLE, not WRAPPED --
# the window is sitting there finished but not yet closed, and this is the
# signal a chief should wake on and go close it.
w3747a="HIMMEL-3747-N640-closable-2026-09-27-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w3747a.md"
mkcmdline 140 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3747-N640-closable-2026-09-27 work
mk_pgrep_x "$W/bin-3747a" 140
o3747a="$(PATH="$W/bin-3747a:$PATH" bash "$SUT" --workers "$W/handover/$w3747a.md")"
contains 'a WRAPPED worker whose session process is still alive reads CLOSABLE' "$o3747a" 'workers=N640:CLOSABLE'

# Control: the same WRAPPED doc, but no live session anywhere in the census --
# the normal end of a worker once its window is actually gone. Must stay WRAPPED.
w3747b="HIMMEL-3747-N641-gone-2026-09-27-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w3747b.md"
mk_pgrep_x "$W/bin-3747b"
o3747b="$(PATH="$W/bin-3747b:$PATH" bash "$SUT" --workers "$W/handover/$w3747b.md")"
contains 'a WRAPPED worker whose session process is gone stays WRAPPED, not CLOSABLE' "$o3747b" 'workers=N641:WRAPPED'

# Control: a fatal census (pgrep itself failing) must never claim CLOSABLE --
# fail closed to WRAPPED, since "session process alive" cannot be proven.
w3747c="HIMMEL-3747-N642-unproven-2026-09-27-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w3747c.md"
mkcmdline 141 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3747-N642-unproven-2026-09-27 work
mkdir -p "$W/bin-3747c"
cat > "$W/bin-3747c/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
chmod +x "$W/bin-3747c/pgrep"
o3747c="$(PATH="$W/bin-3747c:$PATH" bash "$SUT" --workers "$W/handover/$w3747c.md")"
contains 'a fatal census must not promote a live-looking worker to CLOSABLE' "$o3747c" 'workers=N642:WRAPPED'

# --- a relaunched worker (-r<N> session suffix) reads CLOSABLE too, and
# closable=<n> counts CLOSABLE workers whose doc has sat untouched past TICK_CLOSABLE_MIN
# minutes (default 5): the windows a chief missed, not the one it is closing now.
w5923a="HIMMEL-5923-N650-relaunch-2026-10-16-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w5923a.md"
mkcmdline 142 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-5923-N650-relaunch-2026-10-16-r1 work
mk_pgrep_x "$W/bin-5923a" 142
touch -d '20 minutes ago' "$W/handover/$w5923a.md"
o5923a="$(PATH="$W/bin-5923a:$PATH" bash "$SUT" --workers "$W/handover/$w5923a.md")"
contains 'a WRAPPED worker running as <name>-r1 reads CLOSABLE' "$o5923a" 'workers=N650:CLOSABLE'
contains 'an old CLOSABLE worker is counted in closable=1' "$o5923a" ' closable=1'
touch "$W/handover/$w5923a.md"
o5923b="$(PATH="$W/bin-5923a:$PATH" bash "$SUT" --workers "$W/handover/$w5923a.md")"
contains 'a freshly WRAPPED CLOSABLE worker is still CLOSABLE' "$o5923b" 'workers=N650:CLOSABLE'
case "$o5923b" in *' closable='*) fail 'a fresh CLOSABLE worker must not be counted in closable=' ;; *) pass 'a fresh CLOSABLE worker is not counted in closable=' ;; esac
o5923c="$(PATH="$W/bin-3747b:$PATH" bash "$SUT" --workers "$W/handover/$w3747b.md")"
case "$o5923c" in *' closable='*) fail 'no CLOSABLE leg: closable= must be absent' ;; *) pass 'no CLOSABLE leg: closable= is absent' ;; esac

# --- a BLOCKED hand-off naming its launched successor, with the worker's own lock free, is a
# closable named hand-off: CLOSABLE and counted in closable=. A held lock, or a later ordinary
# BLOCKED after the hand-off, is a working worker. (closable=0 prints as an absent field.)
w8949a="HIMMEL-8949-N660-handoff-2026-11-04"
s8949="$W/handover/HIMMEL-8949-N660b-handoff-2026-11-04-RESUME.md"
printf '%s\n' '# successor' '' '## Results' '' '- 13:05 LIVE — resumed' > "$s8949"
printf '%s\n' '# worker' '' '## Results' '' '- 12:00 LIVE — working' "- 13:00 BLOCKED — context 80 %, RESUME written: $s8949" > "$W/handover/$w8949a.md"
mkcmdline 143 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-8949-N660-handoff-2026-11-04 work
mk_pgrep_x "$W/bin-8949" 143
touch -d '20 minutes ago' "$W/handover/$w8949a.md"
o8949a="$(PATH="$W/bin-8949:$PATH" bash "$SUT" --workers "$W/handover/$w8949a.md")"
contains 'a BLOCKED hand-off naming its successor with its lock free reads CLOSABLE' "$o8949a" 'workers=N660:CLOSABLE'
contains 'a BLOCKED hand-off naming its successor with its lock free is counted in closable=1' "$o8949a" ' closable=1'
# the fixture queue-lock stub reports any *odd-name* doc as held
w8949b="HIMMEL-8949-N661-odd-name-2026-11-04"
s8949b="$W/handover/HIMMEL-8949-N661b-odd-name-2026-11-04-RESUME.md"
printf '%s\n' '# successor' '' '## Results' '' '- 13:05 LIVE — resumed' > "$s8949b"
printf '%s\n' '# worker' '' '## Results' '' '- 12:00 LIVE — working' "- 13:00 BLOCKED — context 80 %, RESUME written: $s8949b" > "$W/handover/$w8949b.md"
mkcmdline 144 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-8949-N661-odd-name-2026-11-04 work
mk_pgrep_x "$W/bin-8949b" 144
touch -d '20 minutes ago' "$W/handover/$w8949b.md"
o8949b="$(PATH="$W/bin-8949b:$PATH" bash "$SUT" --workers "$W/handover/$w8949b.md")"
case "$o8949b" in *'N661:CLOSABLE'*|*' closable='*) fail 'a BLOCKED hand-off with its lock held must not be closable' ;; *) pass 'a BLOCKED hand-off with its lock held is not closable (closable=0)' ;; esac
printf '%s\n' '- 13:30 LIVE — working again' '- 14:00 BLOCKED — waiting on CI' >> "$W/handover/$w8949a.md"
touch -d '20 minutes ago' "$W/handover/$w8949a.md"
o8949c="$(PATH="$W/bin-8949:$PATH" bash "$SUT" --workers "$W/handover/$w8949a.md")"
case "$o8949c" in *'N660:CLOSABLE'*|*' closable='*) fail 'a later ordinary BLOCKED after the hand-off must not be closable' ;; *) pass 'a later ordinary BLOCKED after the hand-off is not closable (closable=0)' ;; esac

# --- denials= (classifier-denial jsonl -> tick line, SHIP-STEP /
# REPEAT / PAUSE-RISK / none / skip). mkdenial writes one row at an offset
# (minutes before "now") so tests control window inclusion without a stale
# fixture; row shape matches scripts/hooks/log-classifier-denial.sh's fields.
mkdenial() {  # mkdenial <log> <mins-ago> <session_title> <input_head>
    ts="$(date -u -d "-${2} minutes" +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","session_title":"%s","input_head":"%s"}\n' "$ts" "$3" "$4" >> "$1"
}

d3724a="$W/denials-3724a.jsonl"
: > "$d3724a"
mkdenial "$d3724a" 5 worker-a 'git push origin main'
o3724a="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724a" bash "$SUT" 2>/dev/null)"
contains 'a denied ship-step command reads SHIP-STEP' "$o3724a" 'denials=worker-a:1:SHIP-STEP'

d3724b="$W/denials-3724b.jsonl"
: > "$d3724b"
mkdenial "$d3724b" 5 worker-a 'ls -la'
mkdenial "$d3724b" 3 worker-a 'cat foo'
o3724b="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724b" bash "$SUT" 2>/dev/null)"
contains '2 non-ship denials in the window read REPEAT' "$o3724b" 'denials=worker-a:2:REPEAT'

d3724c="$W/denials-3724c.jsonl"
: > "$d3724c"
mkdenial "$d3724c" 5 worker-a 'ls -la'
mkdenial "$d3724c" 4 worker-a 'cat foo'
mkdenial "$d3724c" 3 worker-a 'pwd'
o3724c="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724c" bash "$SUT" 2>/dev/null)"
contains '3+ non-ship denials in the window read PAUSE-RISK' "$o3724c" 'denials=worker-a:3:PAUSE-RISK'

d3724d="$W/denials-3724d.jsonl"
: > "$d3724d"
i=0
while [ "$i" -lt 17 ]; do
    mkdenial "$d3724d" 90 worker-a 'ls -la'
    i=$((i + 1))
done
mkdenial "$d3724d" 5 worker-a 'pwd'
o3724d="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724d" bash "$SUT" 2>/dev/null)"
contains 'an all-time total approaching 20 reads PAUSE-RISK even with 1 in-window' "$o3724d" 'denials=worker-a:1:PAUSE-RISK'

d3724e="$W/denials-3724e.jsonl"
: > "$d3724e"
mkdenial "$d3724e" 90 worker-a 'ls -la'
o3724e="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724e" bash "$SUT" 2>/dev/null)"
contains 'a denial older than the window is excluded, reading none' "$o3724e" 'denials=none'

d3724f="$W/denials-3724f.jsonl"
: > "$d3724f"
o3724f="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724f" bash "$SUT" 2>/dev/null)"
contains 'an empty log reads none' "$o3724f" 'denials=none'

o3724g="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$W/denials-3724-missing.jsonl" bash "$SUT" 2>/dev/null)"
contains 'a missing log reads none, not skip: no log means no denials' "$o3724g" 'denials=none'

# Non-worktree sessions group by session id (not the cwd basename), so a
# re-dispatched slug in the same directory does not inherit an old session's
# count -> no false PAUSE-RISK. Worktree rows keep the slug as their label.
mksess() {  # mksess <log> <mins-ago> <session_title> <session_id> <cwd> <input_head>
    ts="$(date -u -d "-${2} minutes" +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","session_title":"%s","session_id":"%s","cwd":"%s","input_head":"%s"}\n' "$ts" "$3" "$4" "$5" "$6" >> "$1"
}
d3724s="$W/denials-3724s.jsonl"
: > "$d3724s"
mksess "$d3724s" 6 repo aaaaaaaa11111111 /home/u/repo 'ls'
mksess "$d3724s" 5 repo aaaaaaaa11111111 /home/u/repo 'cat x'
mksess "$d3724s" 4 repo bbbbbbbb22222222 /home/u/repo 'pwd'
o3724s="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724s" bash "$SUT" 2>/dev/null)"
contains 'two sessions in one non-worktree cwd get separate labels' "$o3724s" 'denials=repo#aaaaaaaa:2:REPEAT,repo#bbbbbbbb:1'
not_contains 'and the second session does not inherit the first one count' "$o3724s" 'PAUSE-RISK'
d3724w="$W/denials-3724w.jsonl"
: > "$d3724w"
mksess "$d3724w" 5 feat+foo cccccccc33333333 /r/.claude/worktrees/feat+foo 'ls'
o3724w="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724w" bash "$SUT" 2>/dev/null)"
contains 'a worktree row keeps the bare slug as its label' "$o3724w" 'denials=feat+foo:1 '

# A window straddling a hook rotation: the earlier denial sits in <log>.1, the
# later one in the live log. Both must count (REPEAT), not just the live one.
d3724x="$W/denials-3724x.jsonl"
: > "$d3724x"
mksess "$d3724x.1" 6 repo dddddddd44444444 /home/u/repo 'ls'
mksess "$d3724x" 4 repo dddddddd44444444 /home/u/repo 'cat x'
o3724x="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724x" bash "$SUT" 2>/dev/null)"
contains 'a denial rotated into <log>.1 still counts inside the window' "$o3724x" 'denials=repo#dddddddd:2:REPEAT'

# HARD RULE: input_head and reason_tag never leave the host --
# they classify locally and must not be echoed into the tick line.
d3724r="$W/denials-3724r.jsonl"
: > "$d3724r"
ts="$(date -u -d '-3 minutes' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","session_title":"worker-r","input_head":"UNIQUE-HEAD-7f3a git push","reason_tag":"[UNIQUE-TAG-9c1e]"}\n' "$ts" >> "$d3724r"
o3724r="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724r" bash "$SUT" 2>/dev/null)"
contains 'a ship-step row still classifies SHIP-STEP' "$o3724r" 'denials=worker-r:1:SHIP-STEP'
not_contains 'the tick line never echoes input_head' "$o3724r" 'UNIQUE-HEAD-7f3a'
not_contains 'the tick line never echoes reason_tag' "$o3724r" 'UNIQUE-TAG-9c1e'

# Valid non-object JSON lines (a scalar, an array) survive `fromjson?`; they
# must be dropped, not abort the slurp and hide every real denial.
d3724h="$W/denials-3724h.jsonl"
: > "$d3724h"
mkdenial "$d3724h" 5 worker-a 'git push origin main'
printf '%s\n' '5' '[1]' >> "$d3724h"
o3724h="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724h" bash "$SUT" 2>/dev/null)"
contains 'scalar and array lines in the log keep denials= populated' "$o3724h" 'denials=worker-a:1:SHIP-STEP'

# A valid object whose input_head is not a string must be skipped, not make
# test() fail and turn the whole column into skip.
d3724i="$W/denials-3724i.jsonl"
: > "$d3724i"
mkdenial "$d3724i" 5 worker-a 'git push origin main'
printf '%s\n' '{"ts":"2099-01-01T00:00:00Z","session_title":"worker-b","input_head":5}' >> "$d3724i"
o3724i="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724i" bash "$SUT" 2>/dev/null)"
contains 'a non-string input_head row is skipped, denials= stays populated' "$o3724i" 'denials=worker-a:1:SHIP-STEP'

# --- ciq= (queue-latency.sh -> compact field + SATURATED on two
# consecutive full ticks). The stub prints $STUB_CIQ_OUT verbatim, after
# STUB_CIQ_SLEEP seconds, and appends one line per call to $STUB_CIQ_CALLS.
mkdir -p "$W/repo/scripts/ci"
cat > "$W/repo/scripts/ci/queue-latency.sh" <<'STUB'
#!/usr/bin/env bash
printf 'x\n' >> "${STUB_CIQ_CALLS:-/dev/null}"
[ -z "${STUB_CIQ_SLEEP:-}" ] || sleep "$STUB_CIQ_SLEEP"
printf '%s\n' "$STUB_CIQ_OUT"
STUB
chmod +x "$W/repo/scripts/ci/queue-latency.sh"
ciq_full='ci-queue: jobs_in_progress=20/20 macos=3/5 queued=4 oldest_wait=62m'
ciq_idle='ci-queue: jobs_in_progress=0/20 macos=0/5 queued=0 oldest_wait=0m'
ciq_calls="$W/ciq-calls.txt"
ciq_tick() { STUB_CIQ_OUT="$1" STUB_CIQ_CALLS="$ciq_calls" bash "$SUT" 2>/dev/null; }

rm -rf "$W/state"; : > "$ciq_calls"
o3840a="$(ciq_tick "$ciq_idle")"
contains 'an idle queue prints the compact ciq= field' "$o3840a" 'ciq=0/20,mac=0/5,q=0,wait=0m'
not_contains 'an idle queue is not flagged SATURATED' "$o3840a" 'SATURATED'
calls="$(wc -l < "$ciq_calls" | tr -d '[:space:]')"
if [ "$calls" = 1 ]; then pass 'one tick runs the probe exactly once'; else fail "probe calls per tick = $calls, want 1"; fi

rm -rf "$W/state"
o3840b="$(ciq_tick "$ciq_full")"
contains 'one full tick prints the field' "$o3840b" 'ciq=20/20,mac=3/5,q=4,wait=62m'
not_contains 'one full tick is not yet SATURATED' "$o3840b" 'SATURATED'
o3840c="$(ciq_tick "$ciq_full")"
contains 'two consecutive full ticks read SATURATED' "$o3840c" 'ciq=20/20,mac=3/5,q=4,wait=62m,SATURATED'
ciq_tick "$ciq_idle" >/dev/null
o3840e="$(ciq_tick "$ciq_full")"
not_contains 'a non-full tick between two full ones resets the streak' "$o3840e" 'SATURATED'

# unknown: neither sets nor clears. full, unknown, full -> SATURATED (state
# survived); idle, unknown, full -> not saturated (unknown did not set it).
rm -rf "$W/state"
ciq_tick "$ciq_full" >/dev/null
o3840f="$(ciq_tick 'ci-queue: unknown')"
contains 'a failed probe prints ciq=unknown' "$o3840f" 'ciq=unknown'
o3840g="$(ciq_tick "$ciq_full")"
contains 'unknown does not clear the saturation state' "$o3840g" 'SATURATED'
rm -rf "$W/state"
ciq_tick "$ciq_full" >/dev/null
ciq_tick "$ciq_idle" >/dev/null
ciq_tick 'ci-queue: unknown' >/dev/null
o3840h="$(ciq_tick "$ciq_full")"
not_contains 'unknown does not set the saturation state' "$o3840h" 'SATURATED'

# a line with an empty numeric field is malformed: unknown, not a partial summary.
o3840k="$(ciq_tick 'ci-queue: jobs_in_progress=/20 macos=0/5 queued=0 oldest_wait=0m')"
contains 'an empty numeric field reads ciq=unknown' "$o3840k" 'ciq=unknown'

# probe timeout: a hung probe reads unknown inside the bound and leaves state alone.
if [ -n "$_TIMEOUT_BIN" ]; then
    rm -rf "$W/state"
    ciq_tick "$ciq_full" >/dev/null
    t0="$(date +%s)"
    o3840i="$(STUB_CIQ_SLEEP=30 TICK_CIQ_TIMEOUT=1 STUB_CIQ_OUT="$ciq_full" bash "$SUT" 2>/dev/null)"
    t1="$(date +%s)"
    contains 'a hung probe reads ciq=unknown' "$o3840i" 'ciq=unknown'
    if [ $((t1 - t0)) -lt 15 ]; then pass 'a hung probe is cut off inside the bound'; else fail "hung probe took $((t1 - t0))s"; fi
    o3840j="$(ciq_tick "$ciq_full")"
    contains 'a timed-out probe leaves the saturation state untouched' "$o3840j" 'SATURATED'
else
    skip 'probe timeout rows: no timeout binary'
fi

# --- tracker=<ok|STALE:<age>|MISSING|skip> -- the roadmap tracker page
# (roadmap-tracker.html, rendered by tracker.py next to the chief doc) is checked
# against the Jira mirror's newest updated time plus the plan files, like board=.
# RED control (pre-change tick.sh): no tracker= field, so a tracker that drifted from
# Jira is invisible. The plan dir rides on an optional `tracker-plan:` Live state line.
if command -v python3 >/dev/null 2>&1; then
    t3933_dir="$W/tracker3933"
    t3933_plan="$t3933_dir/plan"
    t3933_mir="$t3933_dir/mirror"
    t3933_out="$W/handover/roadmap-tracker.html"
    mkdir -p "$t3933_plan/stage1" "$t3933_plan/stage3" "$t3933_mir"
    printf '%s\n' '{"main_sha_at_build":"abcdef123456"}' > "$t3933_plan/stage3/meta.json"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
        v1.0.1 0.1 0 0 0 0 0.1 1 > "$t3933_plan/stage3/versions.tsv"
    printf '%s\t%s\t%s\t%s\n' key version layer effort_mid HIMMEL-1 v1.0.1 bugs 1 > "$t3933_plan/stage3/placement.tsv"
    printf '%s\t%s\t%s\n' key close_flag close_evidence > "$t3933_plan/stage3/closures.tsv"
    printf '%s\t%s\n' key reason > "$t3933_plan/stage3/unplaced.tsv"
    printf '%s\t%s\n' key theme HIMMEL-1 tooling > "$t3933_plan/stage1/C01.tsv"
    write_mirror3933() {  # write_mirror3933 <updated> <statusCategory>
        printf '%s\n' '---' 'key: "HIMMEL-1"' "updated: \"$1\"" "statusCategory: \"$2\"" 'fixVersions: ["v1.0.1"]' 'type: "Bug"' '---' '# HIMMEL-1: a planned bug' \
            > "$t3933_mir/HIMMEL-1.md"
    }
    # shellcheck disable=SC2016  # backtick worker span, literal fixture text
    write_console3933() {  # write_console3933 [tracker: value, omitted = no line]
        printf '%s\n' '# chief' '' '## Live state' '' \
            'legs: `N361:J-N361-0a1b2c9d:cachyos-x8664-pid361:361`' 'queue: N361 (3361)' 'last GO: none' 'acked: none' \
            ${1:+"tracker: $1"} "tracker-plan: $t3933_plan" '' \
            '## Results (newest at the bottom)' '- 12:00 DISPATCH N361' > "$W/handover/chief.md"
    }
    # TRACKER_HANDOVERS_DIR: tick's --emit-fp reads live workers from the same fake bucket the render did.
    t3933() { PATH="$W/bin-3361:$PATH" TICK_TRACKER_MIRROR_DIR="$t3933_mir" TRACKER_HANDOVERS_DIR="$W/tracker3933/luna/handovers/tester/himmel" bash "$SUT" --workers "$W/handover/$b3361.md" "$@"; }
    t3933_render() { python3 "$HERE/tracker.py" --plan-dir "$t3933_plan" --out "$t3933_out" --luna-map "$W/tracker3933/luna-map.json" --mirror-dir "$t3933_mir" --luna-root "$W/tracker3933/luna" --handovers "$W/tracker3933/luna/handovers/tester/himmel" >/dev/null; }
    rm -f "$t3933_out" "$t3933_out.fp"
    write_mirror3933 2026-09-30T10:00:00.000+0000 'To Do'
    write_console3933
    contains 'a chief with no tracker: line reads tracker=skip' "$(t3933)" ' tracker=skip'
    write_console3933 none
    contains 'tracker: none reads tracker=skip' "$(t3933)" ' tracker=skip'
    write_console3933 'https://claude.ai/artifact/x'
    contains 'a tracker: line with no rendered page reads tracker=MISSING' "$(t3933)" ' tracker=MISSING'
    contains '--verbose labels the tracker' "$(t3933 --verbose)" 'tracker: MISSING'
    t3933_render
    contains 'a freshly rendered tracker reads tracker=ok' "$(t3933)" ' tracker=ok'
    # A ticket in a planned version changes status in Jira: the mirror's updated moves.
    write_mirror3933 2026-09-30T11:30:00.000+0000 Done
    touch -d '3 hours ago' "$t3933_out"  # gnu-ok: chief kit is Linux-only
    contains 'a mirror that moved past the render reads tracker=STALE:<age>' "$(t3933)" ' tracker=STALE:3h'
    t3933_render
    contains 're-rendering after the change reads tracker=ok again' "$(t3933)" ' tracker=ok'
    # A plan file edit is a staleness too, not only the mirror.
    printf '%s\t%s\t%s\t%s\n' HIMMEL-2 v1.0.1 bugs 1 >> "$t3933_plan/stage3/placement.tsv"
    contains 'a plan file change reads tracker=STALE' "$(t3933)" ' tracker=STALE:'
    # a rendered page the chief has not republished reads REPUBLISH; a publish stamp newer than the page reads ok.
    head -n -1 "$t3933_plan/stage3/placement.tsv" > "$t3933_plan/stage3/placement.tmp" && mv "$t3933_plan/stage3/placement.tmp" "$t3933_plan/stage3/placement.tsv"
    t3933_render
    touch -d '5 hours ago' "$t3933_out.published" || exit 1  # gnu-ok: chief kit is Linux-only
    touch -d '2 hours ago' "$t3933_out" || exit 1  # gnu-ok: chief kit is Linux-only
    contains 'a page newer than its publish stamp reads tracker=REPUBLISH:<age>' "$(t3933)" ' tracker=REPUBLISH:2h'
    touch "$t3933_out.published" || exit 1
    contains 'a publish stamp newer than the page reads tracker=ok' "$(t3933)" ' tracker=ok'
    touch -d '1 hour' "$t3933_out" || exit 1  # gnu-ok: chief kit is Linux-only
    rm -f "$t3933_out.published"
    contains 'no publish stamp keeps reading tracker=ok' "$(t3933)" ' tracker=ok'
    # a focus-owned page is written by focus-refresh.sh, which records its own fingerprint (.vfp, and sha8 in
    # focus-state) and never the all-versions .fp: the tick compares that one for such a doc.
    t7508_state() { printf 'status=ok\nstage=\ngen=3\ndirty=\nsha8=%s\nsdrift=0:0\nver=%s\nts=1\n' "$1" "${2:-}" > "$W/handover/focus-state"; }
    t7508_doc() { write_console3933 'https://claude.ai/artifact/x'; sed -i "/^tracker-plan:/a $1" "$W/handover/chief.md"; }  # gnu-ok: chief kit is Linux-only
    t3933_render || exit 1
    printf '%s\n' stale-all-versions-fp > "$t3933_out.fp"
    printf '%s\n' 0a1b2c3d4e5f6071 > "$t3933_out.vfp"
    t7508_state 0a1b2c3d
    t7508_doc 'focus-version: v1.0.1'
    contains 'a focus-owned doc whose .vfp matches the focus state reads tracker=ok' "$(t3933)" ' tracker=ok'
    t7508_doc 'release: v1.0'
    contains 'a doc with a release: line and no focus-version: line is focus-owned too' "$(t3933)" ' tracker=ok'
    t7508_state 0a1b2c3d v1.0.1
    t7508_doc 'focus-version: v1.0.1'
    contains 'a focus state recording the pinned version reads tracker=ok' "$(t3933)" ' tracker=ok'
    t7508_state 0a1b2c3d v1.0.0
    contains 'a focus-version switched since the last refresh reads tracker=STALE' "$(t3933)" ' tracker=STALE:'
    t7508_doc 'focus-version: auto'
    contains 'focus-version: auto keeps the recorded version out of the compare' "$(t3933)" ' tracker=ok'
    t7508_doc 'release: v1.0'
    contains 'a release-only doc keeps the recorded version out of the compare' "$(t3933)" ' tracker=ok'
    t7508_state 0a1b2c3d
    printf '%s\n' ffffffff00000000 > "$t3933_out.vfp"
    contains 'a focus-owned page whose .vfp differs from the focus state reads tracker=STALE' "$(t3933)" ' tracker=STALE:'
    printf '%s\n' 0a1b2c3d4e5f6071 > "$t3933_out.vfp"
    t7508_doc 'focus-version: none'
    contains 'a doc the focus refresh does not own keeps the .fp comparison' "$(t3933)" ' tracker=STALE:'
    t7508_doc 'focus-version: v1.0.1'
    rm -f "$W/handover/focus-state"
    contains 'no focus state falls back to the .fp comparison' "$(t3933)" ' tracker=STALE:'
    rm -f "$t3933_out.vfp"
else
    skip 'tracker= rows: no python3'
fi

# --- plan-index=<ok|ok:pending|REFRESHING|FAIL:<why>|skip> -- the tick keeps the
# roadmap-plan qmd index fresh without ever waiting on it: only `plan-index.sh --check` (a
# fingerprint) runs inline; a stale index launches --refresh DETACHED. A stub qmd only, an
# --out under $W (never ~/.himmel/state). RED control (pre-change tick.sh): no plan-index= field.
if command -v python3 >/dev/null 2>&1; then
    p4051="$W/pi4051"; p4051_plan="$p4051/plan"; p4051_mir="$p4051/mirror"; p4051_out="$p4051/out"; p4051_calls="$p4051/qmd-calls"
    mkdir -p "$p4051_plan/stage1" "$p4051_plan/stage3" "$p4051_mir"
    printf 'key\ttheme\tepic\tgoals\timpact\timpact_evidence\talignment\tdeps\tdup_of\tclose_flag\tclose_evidence\tnotes\nHIMMEL-111\tKnowledge substrate\tHIMMEL-100\tG7\t2\te\t0.5\t\t\tnone\t\tn\n' > "$p4051_plan/stage1/C01.tsv"
    printf 'key\tuser_impact\tissue_plain\nHIMMEL-111\tinternal\tA plain sentence.\n' > "$p4051_plan/stage1/C01.explain.tsv"
    printf 'key\troi\tconfidence\teffort_mid\trank\tversion\tcommit\tslice_effort\tlayer\treason\nHIMMEL-111\t1\t1\t1\t1\tv1.0.1\tcommitted\t\tbugs\twhy-one\n' > "$p4051_plan/stage3/placement.tsv"
    printf '{"stage":3}\n' > "$p4051_plan/stage3/meta.json"
    echo one > "$p4051_mir/HIMMEL-111.md"
    cat > "$p4051/qmd" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$QMD_CALLS"
reg="$QMD_CALLS.registered"
case "$1 ${2:-}" in
    "collection list") [ -f "$reg" ] && echo "roadmap-plan (3 files)"; exit 0 ;;
    "collection add") printf '%s\n' "$3" > "$reg"; exit 0 ;;
    "collection show") [ -f "$reg" ] && echo "Path: $(cat "$reg")"; exit 0 ;;
esac
[ -n "${QMD_SLEEP:-}" ] && [ "$1" = embed ] && sleep "$QMD_SLEEP"
if [ "${QMD_FAIL:-0}" = 1 ] && [ "$1" = embed ]; then exit 3; fi
exit 0
STUB
    chmod +x "$p4051/qmd"
    # shellcheck disable=SC2016  # backtick worker span, literal fixture text
    write_console4051() {  # write_console4051 [plan dir, omitted = no tracker-plan: line]
        printf '%s\n' '# chief' '' '## Live state' '' \
            'legs: `N361:J-N361-0a1b2c9d:cachyos-x8664-pid361:361`' 'queue: N361 (3361)' 'last GO: none' 'acked: none' \
            ${1:+"tracker-plan: $1"} '' \
            '## Results (newest at the bottom)' '- 12:00 DISPATCH N361' > "$W/handover/chief.md"
    }
    t4051() {
        PATH="$W/bin-3361:$PATH" QMD_CALLS="$p4051_calls" ROADMAP_QMD_BIN="$p4051/qmd" TICK_PLAN_INDEX_OUT="$p4051_out" \
            TICK_TRACKER_MIRROR_DIR="$p4051_mir" bash "$SUT" --workers "$W/handover/$b3361.md" "$@"
    }
    wait4051() {  # the detached refresh writes OUT/.last-run, then its EXIT trap drops .launch
        local i=0
        while { [ ! -f "$p4051_out/.last-run" ] || [ -d "$p4051_out/.launch" ]; } && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
    }
    write_console4051
    not_contains 'no plan dir configured omits plan-index=' "$(t4051)" ' plan-index='
    [ ! -e "$p4051_out" ] && pass 'skip touches no state' || fail 'skip created the out dir'
    write_console4051 "$p4051/missing"
    not_contains 'a configured but absent plan dir omits plan-index=' "$(t4051)" ' plan-index='

    write_console4051 "$p4051_plan"
    contains 'a never-built index reads plan-index=REFRESHING' "$(t4051)" ' plan-index=REFRESHING'
    wait4051
    contains 'the detached refresh embedded the collection' "$(cat "$p4051_calls" 2>/dev/null)" 'embed -c roadmap-plan'
    not_contains 'after the refresh the tick omits healthy plan-index=' "$(t4051)" ' plan-index='
    contains '--verbose labels the plan index' "$(t4051 --verbose)" 'plan-index: ok'
    n4051="$(wc -l < "$p4051_calls")"
    t4051 >/dev/null
    [ "$(wc -l < "$p4051_calls")" -eq "$n4051" ] && pass 'an unchanged index never relaunches qmd' || fail 'ok tick called qmd'

    # a mirror change inside the minimum interval: stale but not yet due
    echo two >> "$p4051_mir/HIMMEL-111.md"
    contains 'stale but inside the minimum interval reads plan-index=ok:pending' "$(t4051)" ' plan-index=ok:pending'
    [ "$(wc -l < "$p4051_calls")" -eq "$n4051" ] && pass 'ok:pending launches no refresh' || fail 'pending tick called qmd'
    rm -f "$p4051_out/.last-run"
    contains 'stale and due (interval 0) reads plan-index=REFRESHING' "$(TICK_PLAN_INDEX_MIN_SECS=0 t4051)" ' plan-index=REFRESHING'
    wait4051
    not_contains 'the due refresh made the index healthy again' "$(t4051)" ' plan-index='

    # a failing qmd: FAIL:<why>, and the backoff stops a relaunch every tick
    echo three >> "$p4051_mir/HIMMEL-111.md"
    rm -f "$p4051_out/.last-run"
    TICK_PLAN_INDEX_MIN_SECS=0 QMD_FAIL=1 t4051 >/dev/null
    wait4051
    contains 'a failed refresh reads plan-index=FAIL:' "$(t4051)" ' plan-index=FAIL:'
    n4051="$(wc -l < "$p4051_calls")"
    t4051 >/dev/null; sleep 0.3
    [ "$(wc -l < "$p4051_calls")" -eq "$n4051" ] && pass 'a recent failure is not relaunched' || fail 'failure relaunched inside the backoff'

    # a slow qmd never holds the tick: it returns while the refresh is still running
    echo four >> "$p4051_mir/HIMMEL-111.md"
    rm -f "$p4051_out/.last-fail" "$p4051_out/.last-run"
    s4051=$SECONDS
    o4051="$(TICK_PLAN_INDEX_MIN_SECS=0 QMD_SLEEP=4 t4051)"
    e4051=$((SECONDS - s4051))
    contains 'a slow qmd still reads plan-index=REFRESHING' "$o4051" ' plan-index=REFRESHING'
    [ "$e4051" -le 2 ] && pass "the tick does not wait on the refresh (${e4051}s)" || fail "tick waited ${e4051}s on a 4s qmd"
    contains 'while the refresh holds the lock the tick reads REFRESHING' "$(t4051)" ' plan-index=REFRESHING'
    wait4051

    # an overlapping launch (OUT/.launch held) reads REFRESHING and a duplicate wrapper exits
    # without touching the live refresh's bookkeeping
    echo five >> "$p4051_mir/HIMMEL-111.md"
    mkdir "$p4051_out/.launch"; echo 77 > "$p4051_out/.last-run"
    n4051="$(wc -l < "$p4051_calls")"
    contains 'a held launch lock reads plan-index=REFRESHING' "$(TICK_PLAN_INDEX_MIN_SECS=0 t4051)" ' plan-index=REFRESHING'
    # drive the PRODUCTION wrapper (not a hand copy); RED control: pre-change the
    # wrapper was inline in tick.sh, so plan-index-launch.sh is absent and the first check fails
    wrap4059="$(dirname "$SUT")/plan-index-launch.sh"
    [ -f "$wrap4059" ] && pass 'the launch wrapper is its own script' || fail 'plan-index-launch.sh is missing'
    bash "$wrap4059" "$p4051_out" bash -c 'echo clobbered > "$1/.last-run"' _ "$p4051_out"
    [ -f "$wrap4059" ] && [ "$(cat "$p4051_out/.last-run")" = 77 ] && [ "$(wc -l < "$p4051_calls")" -eq "$n4051" ] && pass 'a held launch lock blocks a duplicate refresh' || fail 'duplicate refresh ran past .launch'
    rmdir "$p4051_out/.launch"
    # a free .launch: the wrapper runs the command, records rc, and releases the lock
    bash "$wrap4059" "$p4051_out" bash -c 'exit 5'
    [ "$(cat "$p4051_out/.last-run" 2>/dev/null)" = 5 ] && [ ! -d "$p4051_out/.launch" ] && pass 'the wrapper records rc and releases .launch' || fail 'wrapper did not record rc / release .launch'
    rm -f "$p4051_out/.last-run" "$p4051_out/.last-fail"

    # a run the test guard refused (exit 77) is not a failed refresh; any other non-zero is
    echo refused >> "$p4051_mir/HIMMEL-111.md"
    # shellcheck disable=SC2016  # $1 expands in the child bash
    bash "$wrap4059" "$p4051_out" bash -c 'echo "$1"; exit 1' _ 'a real failure line'
    [ "$(cat "$p4051_out/.last-fail" 2>/dev/null)" = 'a real failure line' ] && pass 'exit 1 still writes .last-fail' || fail 'exit 1 wrote no .last-fail'
    contains 'exit 1 still reads plan-index=FAIL:' "$(t4051)" ' plan-index=FAIL:'
    rm -f "$p4051_out/.last-run" "$p4051_out/.last-fail"
    # shellcheck disable=SC2016  # $1 expands in the child bash
    bash "$wrap4059" "$p4051_out" bash -c 'echo "$1"; exit 77' _ 'plan-index: refused by the test guard'
    [ ! -e "$p4051_out/.last-fail" ] && [ "$(cat "$p4051_out/.last-run" 2>/dev/null)" = 77 ] && pass 'exit 77 records rc and writes no .last-fail' || fail 'exit 77 wrote .last-fail or lost rc'
    not_contains 'exit 77 never reads plan-index=FAIL:' "$(t4051)" ' plan-index=FAIL:'
    wait4051
    rm -f "$p4051_out/.last-run" "$p4051_out/.last-fail"

    # an --out path with a quote and a command substitution must neither run
    # text nor leave .launch behind (the old double-quoted trap re-parsed $o when it fired)
    p4051_out_save="$p4051_out"
    # shellcheck disable=SC2016  # the $( is a literal hostile path component
    p4051_out="$p4051/o\"x\$(touch $p4051/PWNED)"
    t4051 >/dev/null; wait4051
    [ ! -e "$p4051/PWNED" ] && [ -f "$p4051_out/.last-run" ] && [ ! -d "$p4051_out/.launch" ] && pass 'a hostile --out path is cleaned up without running text' || fail 'hostile --out path left .launch or ran text'
    p4051_out="$p4051_out_save"

    # the wrapper writes .last-run BEFORE its EXIT trap removes .launch, so a wait
    # on .last-run alone can assert inside that gap under load. RED control: a wrapper copy with
    # a sleep injected into the trap widens the gap; a .last-run-only wait4051 fails this check
    p4051_out="$p4051/o4734"; mkdir -p "$p4051_out"
    sed "s/^trap '/trap 'sleep 1; /" "$wrap4059" > "$p4051/launch4734.sh"
    bash "$p4051/launch4734.sh" "$p4051_out" true &
    wait4051
    [ -f "$p4051_out/.last-run" ] && [ ! -d "$p4051_out/.launch" ] && pass 'wait4051 waits out the .last-run-to-.launch-release gap' || fail 'wait4051 returned while .launch was still held'
    wait
    p4051_out="$p4051_out_save"

    # a launcher that is not installed reads FAIL:no-launcher and writes .last-fail
    p4051_out="$p4051/out-nolauncher"
    contains 'a missing launcher reads plan-index=FAIL:no-launcher' "$(TICK_PLAN_INDEX_LAUNCHER=no-such-launcher-4059 t4051)" ' plan-index=FAIL:no-launcher'
    [ -s "$p4051_out/.last-fail" ] && pass 'a missing launcher writes .last-fail' || fail 'no .last-fail for a missing launcher'
    # one installed word must not mask a missing one
    rm -rf "$p4051_out"
    contains 'a half-installed launcher reads plan-index=FAIL:no-launcher' "$(TICK_PLAN_INDEX_LAUNCHER='env no-such-launcher-4059' t4051)" ' plan-index=FAIL:no-launcher'
    rm -rf "$p4051_out"
    contains 'a blank launcher reads plan-index=FAIL:no-launcher' "$(TICK_PLAN_INDEX_LAUNCHER=' ' t4051)" ' plan-index=FAIL:no-launcher'
    p4051_out="$p4051_out_save"
else
    skip 'plan-index= rows: no python3'
fi

# removing the fleet-based skip would read a metered account
# without a live OpenRouter worker; missing the field hides its effective floor.
cat > "$W/repo/scripts/lanes/openrouter-cost.sh" <<'STUB'
#!/usr/bin/env bash
printf 'read\n' >> "$OR_READS"
printf '%s\n' "${OR_READING-balance=7.50:key-limit_remaining spend=?}"
STUB
export OR_READS="$W/or-reads"
not_contains 'no live OpenRouter worker omits or=' \
  "$(STUB_FLEET_LINE='bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/8' bash "$SUT")" ' or='
[ ! -e "$OR_READS" ] && pass 'no OpenRouter worker skips all cost reads' || fail 'cost helper read without OpenRouter worker'
contains 'live OpenRouter worker surfaces smaller key cap and label' \
  "$(STUB_FLEET_LINE='bank-preflight: FLEET native=1 claudex=0 openrouter=1 reserved=0 total=2/8' bash "$SUT")" ' or=7.50:key-limit_remaining'
[ -f "$OR_READS" ] && pass 'live OpenRouter worker reads cost helper' || fail 'no balance read for OpenRouter worker'
contains 'unknown balance is honest' \
  "$(OR_READING='balance=? spend=?' STUB_FLEET_LINE='bank-preflight: FLEET native=0 claudex=0 openrouter=1 reserved=0 total=1/8' bash "$SUT")" ' or=?'
contains 'verbose labels metered balance' \
  "$(STUB_FLEET_LINE='bank-preflight: FLEET native=0 claudex=0 openrouter=1 reserved=0 total=1/8' bash "$SUT" --verbose)" 'OpenRouter: 7.50:key-limit_remaining'

contains 'OpenRouter tick bank is the lane verdict, not subscription usage' \
  "$(CADENCE_USAGE_LANE=openrouter STUB_PF_VERDICT=SKIPPED-BANK bash "$SUT")" ' usage=openrouter:SKIPPED-BANK '
case "$(CADENCE_BANK_LANE=openrouter STUB_PF_VERDICT=SKIPPED-BANK bash "$SUT")" in # old-term-ok
  *' usage=openrouter:'*) fail 'the retired CADENCE_BANK_LANE selected the OpenRouter lane' ;; # old-term-ok
  *) pass 'the retired CADENCE_BANK_LANE selects no lane' ;; # old-term-ok
esac
contains 'OpenRouter worker marker selects lane verdict' \
  "$(CADENCE_USAGE_LANE='' WORKER_SESSION_LANE=openrouter STUB_PF_VERDICT=BANK-UNKNOWN bash "$SUT")" ' usage=openrouter:BANK-UNKNOWN '
contains 'OpenRouter funded verdict surfaces without changing raw balance' \
  "$(CADENCE_USAGE_LANE=openrouter STUB_FLEET_LINE='bank-preflight: FLEET native=0 claudex=0 openrouter=1 reserved=0 total=1/8' bash "$SUT")" ' usage=openrouter:PROCEED '

# --- spare=<pct>@<h>h ---------------------------------------------
# tick reads usage-monitor.sh --spare; this stub prints STUB_SPARE verbatim (the
# projection maths is test-bank-monitor.sh's), so only tick's gating is pinned.
cat > "$W/repo/scripts/lib/usage-monitor.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--spare" ] || exit 2
printf '%s\n' "${STUB_SPARE-seven_day_reset_in=?  unspent_at_reset=?}"
STUB
spare_has() { case "$2" in *' spare='*) fail "$1 (out='$2')" ;; *) pass "$1" ;; esac; }
spare_out="$(STUB_SPARE='seven_day_reset_in=6.4h unspent_at_reset=33.7' bash "$SUT")"
contains 'spare= shows when spare >= 10 and reset <= 24h' "$spare_out" ' fails=? vmrun=off spare=33@6h'
spare_has 'spare= is absent below the spare threshold' "$(STUB_SPARE='seven_day_reset_in=6.4h unspent_at_reset=9.9' bash "$SUT")"
spare_has 'spare= is absent when the reset is more than 24h out' "$(STUB_SPARE='seven_day_reset_in=24.5h unspent_at_reset=60.0' bash "$SUT")"
spare_has 'spare= is absent when the monitor reads ?' "$(STUB_SPARE='seven_day_reset_in=? unspent_at_reset=?' bash "$SUT")"
contains 'TICK_SPARE_MIN moves the spare threshold' \
  "$(TICK_SPARE_MIN=5 STUB_SPARE='seven_day_reset_in=6.4h unspent_at_reset=9.9' bash "$SUT")" ' spare=9@6h'
contains 'TICK_SPARE_HOURS moves the reset window' \
  "$(TICK_SPARE_HOURS=48 STUB_SPARE='seven_day_reset_in=30.0h unspent_at_reset=60.0' bash "$SUT")" ' spare=60@30h'
contains 'verbose labels spare' \
  "$(STUB_SPARE='seven_day_reset_in=6.4h unspent_at_reset=33.7' bash "$SUT" --verbose)" 'spare: 33@6h'
rm -f "$W/repo/scripts/lib/usage-monitor.sh"
spare_has 'a missing usage-monitor.sh leaves spare= absent and the tick intact' "$(bash "$SUT")"

# --- a READY with no GO file for 30 minutes is a wake. tails= is in the
# chief-wait action key, so the entry moving READY -> READY!stale wakes it once.
# RED control (pre-fix tick.sh): the old READY worker reads tails=N568:READY.
d4568="$W/handover/HIMMEL-4568-N568-stale-ready-2026-10-06.md"
head4568=0123456789abcdef0123456789abcdef01234567
printf '%s\n' '# worker' '- 10:00 LIVE — working' "- 10:40 READY 4568 $head4568 GREEN" > "$d4568"
tail4568() { bash "$SUT" --workers "$d4568" 2>/dev/null | sed -E 's/.* tails=([^ ]*) .*/\1/'; }
contains 'a fresh READY with no GO reads plain READY' "$(tail4568)" 'N568:READY'
case "$(tail4568)" in *'!stale'*) fails=$((fails+1)); printf 'FAIL - a fresh READY must not be stale\n' ;; *) printf 'ok - a fresh READY is not stale\n' ;; esac
touch -d '31 minutes ago' "$d4568"
contains 'a READY older than 30 minutes with no GO file reads READY!stale' "$(tail4568)" 'N568:READY!stale'
mkdir -p "$W/handover/.locks/go"
printf 'pr=4568\nhead=%s\n' "$head4568" > "$W/handover/.locks/go/4568.$head4568"
[ "$(tail4568)" = N568:READY ] && printf 'ok - a READY with its GO file present is plain READY however old\n' || { fails=$((fails+1)); printf 'FAIL - GO-present READY went stale\n'; }
rm -f "$W/handover/.locks/go/4568.$head4568"
printf '%s\n' '# worker' "- 10:40 READY 4568 $head4568 GREEN" '- 10:41 LIVE — fixing a review finding' > "$d4568"
touch -d '31 minutes ago' "$d4568"
[ "$(tail4568)" = N568:LIVE ] && printf 'ok - an old LIVE tail is never marked stale\n' || { fails=$((fails+1)); printf 'FAIL - old LIVE went stale\n'; }

# --- acts= is the worker's newest actionable bullet (READY, BLOCKED, FINDING, MERGED)
# plus a count, so a READY a later LIVE/RESOLVED/SUCCESSION bullet buries, and a second
# BLOCKED after a first, still move the wake key. RED control (pre-fix tick.sh): no acts= field.
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
d6292="$W/handover/HIMMEL-6292-N6292-acts-2026-10-19.md"
head6292=0123456789abcdef0123456789abcdef01234567
acts6292() { bash "$SUT" --workers "$d6292" 2>/dev/null | sed -n -E 's/.* acts=([^ ]*).*/\1/p'; }
printf '%s\n' '# worker' '- 10:00 LIVE — working' "- 10:40 READY 6292 $head6292 GREEN" > "$d6292"
same 'acts= names a READY bullet' "$(acts6292)" 'N6292:READY#1'
printf '%s\n' '# worker' "- 10:40 READY 6292 $head6292 GREEN" '- 10:41 LIVE — fixing a review finding' > "$d6292"
same 'acts= keeps a READY a later LIVE bullet buries' "$(acts6292)" 'N6292:READY#1'
printf '%s\n' '# worker' "- 10:40 READY 6292 $head6292 GREEN" '- 10:41 SUCCESSION accepted — relay from the old chief' > "$d6292"
same 'acts= keeps a READY a later SUCCESSION bullet buries' "$(acts6292)" 'N6292:READY#1'
printf '%s\n' '# worker' '- 10:00 BLOCKED — q1' '- 10:05 RESOLVED — ruling received' '- 10:20 BLOCKED — q2' > "$d6292"
same 'acts= counts a second BLOCKED so it wakes again' "$(acts6292)" 'N6292:BLOCKED#2'
printf '%s\n' '# worker' '- 10:00 LIVE — working' > "$d6292"
same 'acts= is absent for a worker with no actionable bullet' "$(acts6292)" ''

# --- (8349 P-A) --pool-dispositions reads stacked-series rows: a stackable ticket and a ticket held by a series
# are dispositioned (never pool-unresolved), and each key-carrying series row prints one `# pool-keys <line> <first> <keys>`.
# RED control (pre-change tick.sh): both tickets print `# pool-unresolved`, and no `# pool-keys` line exists.
pk_rows="$W/pool-series.rows"
printf 'SERIES\tLOCAL\tHIMMEL-801,HIMMEL-802\tHigh\tv1\tfiles=a.sh\n%s\n%s\n%s\n%s\n%s\n' \
    'STACKABLE HIMMEL-803 scripts/lib/a.sh' \
    '# disposition HIMMEL-801 listed SERIES HIMMEL-801' \
    '# disposition HIMMEL-803 stackable on N9 (2/4)' \
    '# disposition HIMMEL-804 collision a.sh held by series s1' \
    'LOCAL	HIMMEL-805	High	v1	plain row' > "$pk_rows"
pk_out="$(bash "$SUT" --pool-dispositions < "$pk_rows" 2>/dev/null)"
not_contains '(8349) a stackable-on ticket is not pool-unresolved' "$pk_out" 'pool-unresolved stackable HIMMEL-803 '
not_contains '(8349) a ticket held by a series is not pool-unresolved' "$pk_out" 'pool-unresolved collision HIMMEL-804 '
contains '(8349) a SERIES row prints its keys' "$pk_out" '# pool-keys 1 SERIES HIMMEL-801,HIMMEL-802'
contains '(8349) a STACKABLE row prints its key' "$pk_out" '# pool-keys 2 STACKABLE HIMMEL-803'
contains '(8349) a held-by-series disposition prints its key' "$pk_out" '# pool-keys 5 # HIMMEL-804'
same '(8349) a plain row and a listed disposition print no pool-keys line' "$(printf '%s\n' "$pk_out" | grep -c '^# pool-keys ')" '3'

dc_rel1='specs/decisions/chief-direction-2026-11-07-p1.md'
dc_rel2='specs/decisions/chief-direction-2026-11-07-p2.md'
dc_doc="$W/handover/chief-dc9502.md"
printf '%s\n' '# DC — CHIEF' '' '## Current direction' '' "Full original text of every ruling below, byte for byte, is in 2 files under the bucket ($dc_rel1 $dc_rel2). READ ALL OF THEM in your first turn." 'OPERATOR 11-05 AB, decision 5: reading.' '' '## Results' > "$dc_doc"
dc_stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
dc_read() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"dc-%s","name":"Read","input":{"file_path":"%s/%s"}}]}}\n' "$dc_stamp" "$1" "$W/handover" "$2"; }
dc_tick() { TOKEN='' bash "$SUT" --doc "$dc_doc" 2>/dev/null; }
printf '{"type":"custom-title","customTitle":"chief-dc9502"}\n{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"dc-0","name":"Read","input":{"file_path":"%s/chief-dc9502.md"}}]}}\n' "$dc_stamp" "$W/handover" > "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
dc_out="$(dc_tick)"
contains '(9502) a chief transcript that never Reads the companions is flagged with the count' "$dc_out" 'ACTION direction-companions-unread=2/2'
contains '(9502) the flag names each unread companion' "$dc_out" "$dc_rel2"
dc_read 1 "$dc_rel1" >> "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
dc_out="$(dc_tick)"
contains '(9502) one companion Read of two leaves one flagged' "$dc_out" 'ACTION direction-companions-unread=1/2'
not_contains '(9502) the companion that was Read is not named' "$dc_out" "$dc_rel1"
dc_read 2 "$dc_rel2" >> "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
not_contains '(9502) a chief that Read every companion is not flagged' "$(dc_tick)" 'direction-companions-unread'
printf '{"type":"custom-title","customTitle":"chief-dc9502"}\n{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"next I read %s"},{"type":"tool_use","id":"dc-9","name":"Read","input":{"file_path":"%s/%s"}}]}}\n' "$dc_stamp" "$dc_rel2" "$W/handover" "$dc_rel1" > "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
dc_out="$(dc_tick)"
contains '(9502) a companion named only in message text, beside a Read of the other, is still flagged' "$dc_out" 'ACTION direction-companions-unread=1/2'
not_contains '(9502) the companion that was Read in that message is not named' "$dc_out" "$dc_rel1"
printf '{"type":"custom-title","customTitle":"someone-else"}\n' > "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
not_contains '(9502) no transcript with the chief title: no guess, no flag' "$(dc_tick)" 'direction-companions-unread'
printf '{"type":"custom-title","customTitle":"chief-dc9502"}\n' > "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
printf '%s\n' '# DC — CHIEF' '' '## Current direction' '' 'In work: the fixture.' '' '## Results' > "$dc_doc"
not_contains '(9502) a doc with no Full original text line is not flagged' "$(dc_tick)" 'direction-companions-unread'
rm -f "$TICK_PROJECTS_DIR/p/dc9502.jsonl" "$dc_doc"

uw_m="$W/uw-mirror/HIMMEL"; mkdir -p "$uw_m" "$W/uw-tmp" "$W/uw-dir"
uw_doc="$W/uw-dir/uw-chief.md"
uw_mirror() {
    printf '%s\n' '---' "key: \"$1\"" "statusCategory: \"$2\"" 'links:' "  blocks: ${4:-[]}" "  blocked_by: $3" '  relates: []' '---' '' "# $1" > "$uw_m/$1.md"
}
uw_live() { printf '%s\n' '# UW — CHIEF' '' '## Live state' '' "$@" '' '## Results' > "$uw_doc"; }
uw_tick() { NEXT_DISPATCH_MIRROR="$uw_m" TMPDIR="$W/uw-tmp" TOKEN='' bash "$SUT" "$@" --doc "$uw_doc" 2>/dev/null; }
uw_chains() { uw_tick --verbose | sed -n 's/^chains: //p'; }
uw_mirror HIMMEL-1 'In Progress' '[]'
uw_mirror HIMMEL-2 'To Do' '[]'
uw_live 'pool-disposition: HIMMEL-2 question after HIMMEL-1 merges'
contains '(9860) an after disposition with no blocked-by link in the mirror prints chains=UNWIRED:1' "$(uw_tick)" ' chains=UNWIRED:1'
contains '(9860) the verbose tick names the same unwired count' "$(uw_tick --verbose)" 'chains: UNWIRED:1'
uw_mirror HIMMEL-2 'To Do' '["HIMMEL-1"]'
not_contains '(9860) the wired twin (HIMMEL-2 blocked by HIMMEL-1 in the mirror) prints no UNWIRED value' "$(uw_tick)" 'UNWIRED'
uw_mirror HIMMEL-2 'To Do' '[]'
uw_mirror HIMMEL-1 'In Progress' '[]' '["HIMMEL-2"]'
not_contains '(9860) a link read from the blocking side (HIMMEL-1 blocks HIMMEL-2) is wired too' "$(uw_tick)" 'UNWIRED'
uw_mirror HIMMEL-1 'Done' '[]'
not_contains '(9860) a closed key does not count' "$(uw_tick)" 'UNWIRED'
uw_mirror HIMMEL-1 'In Progress' '[]'
uw_live 'pool-disposition: HIMMEL-2 slice after HIMMEL-1 lands'
contains '(9860) a slice disposition counts like a question disposition' "$(uw_tick)" ' chains=UNWIRED:1'
uw_mirror MY_APP-110 'In Progress' '[]'
uw_mirror MY_APP-101 'To Do' '[]'
uw_live 'pool-disposition: MY_APP-101 question after MY_APP-110 merges'
contains '(10193) an underscore project key is read like any other key' "$(uw_tick)" ' chains=UNWIRED:1'
rm -f "$uw_m/MY_APP-110.md" "$uw_m/MY_APP-101.md"
uw_live 'pool-disposition: HIMMEL-2 question when HIMMEL-1 merges'
not_contains '(9860) a disposition with no after clause counts nothing' "$(uw_tick)" 'UNWIRED'
uw_live 'pool-disposition: HIMMEL-2 question after HIMMEL-1 merges'
chmod 000 "$uw_m/HIMMEL-2.md"
if [ -r "$uw_m/HIMMEL-2.md" ]; then
    rm -f "$uw_m/HIMMEL-2.md"
fi
not_contains '(9860) an unreadable mirror file counts nothing' "$(uw_tick)" 'UNWIRED'
rm -f "$uw_m/HIMMEL-2.md"; uw_mirror HIMMEL-2 'To Do' '[]'
mkdir -p "$W/uw-tmp/himmel-chain-links-$UID"
printf '%s\n' 'HIMMEL-1 blocks HIMMEL-2' > "$W/uw-tmp/himmel-chain-links-$UID/$(realpath -- "$uw_doc" | sha256sum | cut -d' ' -f1)"
not_contains '(9860) a pair live-state.sh recorded as final counts nothing' "$(uw_tick)" 'UNWIRED'
rm -rf "$W/uw-tmp"
uw_mirror HIMMEL-5 'Done' '[]'
printf '%s\n' '[{"name":"c","steps":[{"key":"HIMMEL-1"},{"key":"HIMMEL-5"}]}]' > "$W/uw-dir/focus-chains.json"
contains '(9860) a stale focus chain and an unwired pair print chains=STALE:<n>/<m>,UNWIRED:<k>' "$(uw_tick)" ' chains=STALE:1/2,UNWIRED:1'
uw_mirror HIMMEL-2 'To Do' '["HIMMEL-1"]'
uw_stale="$(uw_chains)"
printf '%s\n' '[{"name":"c","steps":[{"key":"HIMMEL-1"},{"key":"HIMMEL-2"}]}]' > "$W/uw-dir/focus-chains.json"
uw_ok="$(uw_chains)"
printf '%s\n' '[{"name":"c","steps":[{"key":"HIMMEL-1"},{"key":"HIMMEL-99"}]}]' > "$W/uw-dir/focus-chains.json"
uw_skip="$(uw_chains)"
[ "$uw_stale|$uw_ok|$uw_skip" = 'STALE:1/2|ok|skip' ] && pass '(9860) with only a wired pair the STALE, ok and skip values stay byte-identical' || fail "(9860) with only a wired pair chains read $uw_stale|$uw_ok|$uw_skip, not STALE:1/2|ok|skip"
rm -rf "$W/uw-tmp" "$W/uw-mirror" "$W/uw-dir"

export OWED_STALE_SECS=14400
ow_m="$W/ow-mirror/HIMMEL"; mkdir -p "$ow_m" "$W/ow-tmp" "$W/ow-dir"
ow_doc="$W/ow-dir/ow-chief.md"
printf '%s\n' '# OW — CHIEF' '' '## Live state' '' '## Results' > "$ow_doc"
ow_tick() { NEXT_DISPATCH_MIRROR="$ow_m" TMPDIR="$W/ow-tmp" TOKEN='' bash "$SUT" "$@" --doc "$ow_doc" 2>/dev/null; }
ow_add() { OWE_NOW_EPOCH="$(( $(date +%s) - $1 ))" bash "$HERE/owe.sh" add --bucket "$W/ow-dir" --chief OW --kind "$2" --text "$3" > /dev/null; }
not_contains '(10006) no owed ledger prints no owed=' "$(ow_tick)" ' owed='
ow_add 3600 ticket 'file the fold bug'
ow_add 1800 proof 'run the live succession'
ow_out="$(ow_tick)"
contains '(10006) two open rows print owed=2:1h, the oldest age' "$ow_out" ' owed=2:1h '
not_contains '(10006) a keyless ticket row under 4 hours wakes nothing' "$ow_out" 'ACTION owed-stale'
contains '(10006) the verbose tick names the owed count and age' "$(ow_tick --verbose)" 'owed: 2:1h'
ow_add 18000 proof 'sign the spec'
not_contains '(10006) a proof row past 4 hours is aged but never an owed-stale action' "$(ow_tick)" 'ACTION owed-stale'
ow_add 18000 ticket 'file the lost proof ticket'
ow_out="$(ow_tick)"
contains '(10006) a keyless ticket row past 4 hours prints ACTION owed-stale= naming its id' "$ow_out" 'ACTION owed-stale=1:o4: '
contains '(10006) the action names the owe.sh close command' "$ow_out" 'close --bucket'
contains '(10006) the oldest age follows the 5 hour row' "$ow_out" ' owed=4:5h '
bash "$HERE/owe.sh" close --bucket "$W/ow-dir" --id o4 --key HIMMEL-99999 > /dev/null
ow_out="$(ow_tick)"
not_contains '(10006) closing the stale ticket with a key stops the owed-stale action' "$ow_out" 'ACTION owed-stale'
contains '(10006) the closed row leaves the count' "$ow_out" ' owed=3:5h '
ow_out="$(OWED_STALE_SECS=60 ow_tick)"
contains '(10006) OWED_STALE_SECS moves the stale line for a still-open ticket row' "$ow_out" 'ACTION owed-stale=1:o1: '
ow_out="$(OWED_STALE_SECS=0090 ow_tick)"
contains '(10006) a zero-padded OWED_STALE_SECS reads as decimal, not octal' "$ow_out" 'ACTION owed-stale=1:o1: a ticket you owe has no key after 0h'
for ow_id in o1 o2 o3; do bash "$HERE/owe.sh" close --bucket "$W/ow-dir" --id "$ow_id" --key 0123abc > /dev/null; done
not_contains '(10006) every row closed hides owed=' "$(ow_tick)" ' owed='
ow_yesterday="$(date -u -d yesterday +%F)"
ow_tomorrow="$(date -u -d tomorrow +%F)"
bash "$HERE/owe.sh" add --bucket "$W/ow-dir" --chief OW --kind step --key HIMMEL-10210 --text "run the live proof by $ow_tomorrow" >/dev/null
not_contains '(10210) a future keyed step has no due event' "$(ow_tick)" 'ACTION owed-notify='
bash "$HERE/owe.sh" add --bucket "$W/ow-dir" --chief OW --kind step --key HIMMEL-10210 --text "sign the spec by $ow_yesterday" >/dev/null
ow_out="$(ow_tick)"
contains '(10210) a past-due keyed step raises owed-stale' "$ow_out" 'ACTION owed-stale=1:o6:'
contains '(10210) the accepted due action is a durable notification input' "$ow_out" 'ACTION owed-notify=o7'
ow_stale="$(grep '^ACTION owed-stale=' <<<"$ow_out" || true)"
case "$ow_stale" in
    *'file it'*) fail "(10194) a past-due step's owed-stale line gives the step advice, not \"file it\": $ow_stale" ;;
    'ACTION owed-stale=1:o6: an owed step is past its due date (o6): do it and close the row with its evidence (bash '*'owe.sh close --bucket '*'owe.sh add --bucket '*)
        pass "(10194) a past-due step's owed-stale line gives the step advice, not \"file it\"" ;;
    *) fail "(10194) a past-due step's owed-stale line gives the step advice, not \"file it\": $ow_stale" ;;
esac
bash "$HERE/owe.sh" close --bucket "$W/ow-dir" --id o7 --key wake-delivered >/dev/null
not_contains '(10210) acknowledged due action does not notify on every tick' "$(ow_tick)" 'ACTION owed-notify='
bash "$HERE/owe.sh" add --bucket "$W/ow-dir" --chief OW --kind step --key HIMMEL-10210 --text 'date evidence missing' >/dev/null
contains '(10210) missing due evidence is explicit reconciliation' "$(ow_tick)" 'ACTION owed-invalid=o8'
ow_t="$(OWE_NOW_EPOCH="$(( $(date +%s) - 18000 ))" bash "$HERE/owe.sh" add --bucket "$W/ow-dir" --chief OW --kind ticket --text 'file the second lost ticket')"
ow_s="$(bash "$HERE/owe.sh" add --bucket "$W/ow-dir" --chief OW --kind step --key drain-proof --text "run the drain proof by $ow_yesterday")"
ow_out="$(ow_tick)"
ow_stale="$(grep '^ACTION owed-stale=' <<<"$ow_out" || true)"
case "$ow_stale" in
    "ACTION owed-stale=2:$ow_t,$ow_s: a ticket you owe has no key after 4h ($ow_t): file it, then bash "*" (chief-sections/owed.md); an owed step is past its due date ($ow_s): do it and close "*)
        pass '(10194) a stale ticket row and a past-due step row print count 2, the ticket clause first, each clause naming only its own id in brackets' ;;
    *) fail "(10194) a stale ticket row and a past-due step row print count 2, the ticket clause first, each clause naming only its own id in brackets: $ow_stale" ;;
esac
ow_note="$(bash "$HERE/owe.sh" list --bucket "$W/ow-dir" --json | jq -r --arg s "$ow_s" '.[] | select(.event == "step-due" and .source_id == $s) | .id')"
bash "$HERE/owe.sh" close --bucket "$W/ow-dir" --id "$ow_note" --key wake-delivered >/dev/null
ow_out="$(ow_tick)"
ow_n="$(bash "$HERE/owe.sh" list --bucket "$W/ow-dir" --json | jq -r --arg s "$ow_s" 'if any(.[]; .id == $s) then length else "step-closed" end')"
if [[ "$ow_out" != *'an owed step is past its due date'* && "$ow_out" == *" owed=$ow_n:"* ]]; then
    pass '(10194) after the step-due wake is delivered, the next tick has no step clause and owed= still counts the step'
else
    fail "(10194) after the step-due wake is delivered, the next tick has no step clause and owed= still counts the step (open rows $ow_n): $ow_out"
fi
printf '%s\n' 'not json' >> "$W/ow-dir/owed.jsonl"
contains '(10006) an unreadable ledger prints owed=?' "$(ow_tick)" ' owed=?'
rm -rf "$W/ow-tmp" "$W/ow-mirror" "$W/ow-dir"

sp_root="$W/sp root"; sp_hd="$sp_root/handover"; sp_state="$sp_root/state"
mkdir -p "$sp_hd/sp bucket" "$sp_state" "$sp_root/bin" "$sp_root/mirror/HIMMEL" "$sp_root/tmp"
sp_doc="$sp_hd/sp bucket/sp-chief.md"; printf '# chief\n' > "$sp_doc"
sp_body="## Ticket coverage
- a: done
- the live proof: owed $(printf '\342\206\222') proof by $(date -u -d '+3 days' +%F)"  # gnu-ok: chief kit is Linux-only
printf '%s\n' "$sp_body" > "$sp_root/body.md"
# shellcheck disable=SC2016  # the stub body is single-quoted on purpose: "$*" and "$@" expand when it runs
printf '#!/usr/bin/env bash\nif [ "$*" = "pr view 91 --repo acme/repo --json body -q .body" ]; then cat %q; exit 0; fi\nexec %q "$@"\n' \
    "$sp_root/body.md" "$W/bin/gh" > "$sp_root/bin/gh"
chmod +x "$sp_root/bin/gh"
sp_owed() {
    printf '%s\n' "$sp_body" | python3 -I "$HERE/../../lib/pr_remainder.py" --owed-lines | \
        python3 -I "$HERE/owed-events.py" spool --key "$2" --pr 91 --repo acme/repo --spool "$1"
}
sp_tick() { PATH="$sp_root/bin:$PATH" HANDOVER_DIR="$sp_hd" TICKET_STATUS_STATE_DIR="$sp_state" NEXT_DISPATCH_MIRROR="$sp_root/mirror/HIMMEL" TMPDIR="$sp_root/tmp" TOKEN='' bash "$SUT" --doc "$sp_doc" 2>/dev/null; }
sp_spool="$(TICKET_STATUS_STATE_DIR="$sp_state" bash -c '. "$1" && ts_state_dir' _ "$HERE/../../lib/ticket-status.sh")/owe-spool.jsonl"
sp_key="$(printf '%s-%s' HIMMEL 374)"
sp_owed "$sp_spool" "$sp_key"
sp_id="$(jq -r .identity "$sp_spool")"
sp_tick > /dev/null
if bash "$HERE/owe.sh" list --bucket "$sp_hd/sp bucket" --json 2>/dev/null | jq -e --arg i "$sp_id" --arg k "$sp_key" \
    'length == 1 and (.[0] | .kind == "step" and .key == $k and .identity == $i and .chief == "sp-chief")' >/dev/null 2>&1; then
    pass '(10194) one tick drains a spooled owed line into the chief'"'"'s ledger'
else
    fail "(10194) one tick drains a spooled owed line into the chief's ledger: $(cat "$sp_hd/sp bucket/owed.jsonl" 2>&1)"
fi
sp_state="$sp_root/state two"; sp_spool="$sp_state/owe-spool.jsonl"
sp_owed "$sp_spool" ACME-5
sp_line1="$(cat "$sp_spool")" # read-sink-ok: the suite's own temp spool
printf '%s' '{"kind":"owed","schema":1,"ts":"2026-' >> "$sp_spool"
sp_sum="$(cksum < "$sp_spool")"
sp_act="$(sp_tick | grep '^ACTION owed-spool-bad=')"
case "$sp_act" in
    'ACTION owed-spool-bad=2: '*) pass '(10194) a torn spool line prints ACTION owed-spool-bad=2' ;;
    *) fail "(10194) a torn spool line prints ACTION owed-spool-bad=2: $sp_act" ;;
esac
sp_check="$(sed -n 's/^ACTION owed-spool-bad=[^:]*: \(.*\) lists them; rebuild a lost row with .*/\1/p' <<<"$sp_act")"
sp_rebuild="$(sed -n 's/.* rebuild a lost row with \(.*\), then drop the bad line with .*/\1/p' <<<"$sp_act")"
sp_drop="$(sed -n 's/.*, then drop the bad line with \(.*\) (chief-sections\/owed\.md)$/\1/p' <<<"$sp_act")"
# read-sink-ok: the suite's own temp spool
[ "$(bash -c "$sp_check" 2>&1)" = 2 ] && [ "$(cksum < "$sp_spool")" = "$sp_sum" ] \
    && pass '(10194) the printed --check runs verbatim, lists the torn line and leaves the spool unchanged' \
    || fail "(10194) the printed --check runs verbatim, lists the torn line and leaves the spool unchanged: $sp_check"
bash -c "${sp_drop//<line>/2}" 2>/dev/null
printf '%s\n' "$sp_line1" | cmp -s - "$sp_spool" \
    && pass '(10194) the printed --drop removes only the torn line, byte for byte' \
    || fail "(10194) the printed --drop removes only the torn line, byte for byte: $sp_drop: $(cat "$sp_spool")" # read-sink-ok: the suite's own temp spool
sp_rebuild="${sp_rebuild//<n>/91}"; sp_rebuild="${sp_rebuild//<owner\/name>/acme/repo}"
PATH="$sp_root/bin:$PATH" bash -c "${sp_rebuild//<KEY>/$sp_key}" 2>/dev/null
sp_owed "$sp_root/expect.jsonl" "$sp_key"
# read-sink-ok: the suite's own temp spool
if [ "$(head -n 1 "$sp_spool")" = "$sp_line1" ] && [ "$(wc -l < "$sp_spool")" -eq 2 ] \
    && [ "$(sed -n 2p "$sp_spool" | jq -c 'del(.ts)')" = "$(jq -c 'del(.ts)' "$sp_root/expect.jsonl")" ]; then
    pass '(10194) the printed rebuild pipeline appends the row the spool verb computes for that PR body'
else
    fail "(10194) the printed rebuild pipeline appends the row the spool verb computes for that PR body: $sp_rebuild: $(cat "$sp_spool")" # read-sink-ok: the suite's own temp spool
fi
rm -rf "$sp_root"

if [ -n "$_TIMEOUT_BIN" ]; then
    cut_m="$W/cut/HIMMEL"; mkdir -p "$cut_m" "$W/cut-bin" "$W/cut/releases"
    printf 'v1.1.3\tfalse\t\tfalse\n' > "$W/cut/HIMMEL.versions.tsv"
    cut_i=0
    while [ "$cut_i" -lt 16 ]; do
        cut_i=$((cut_i + 1))
        printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "Medium"\nlabels: ["residual"]\nfixVersions: ["v1.1.3"]\nparent: null\n---\n\n# HIMMEL-%s: fixture\n' "$cut_i" "$cut_i" > "$cut_m/HIMMEL-$cut_i.md"
    done
    # shellcheck disable=SC2016  # the stub body is single-quoted on purpose: its variables expand when it runs
    printf '#!/usr/bin/env bash\n[ -z "${CAP_MIRROR:-}" ] || [ -z "${CUT_PY_SLEEP:-}" ] || exec sleep "$CUT_PY_SLEEP"\n[ -z "${CAP_MIRROR:-}" ] || [ -z "${CUT_PY_FAIL:-}" ] || exit 1\nexec %s "$@"\n' "$(command -v python3)" > "$W/cut-bin/python3"
    printf '#!/usr/bin/env bash\n[ "$*" = "R8843 --json" ] || exit 9\nsleep 5\n' > "$W/cut/rmq-sleep.sh"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$W/cut/rmq-fail.sh"
    cat > "$W/cut/rmq-ok.sh" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "R8843 --json" ] || exit 9
printf '{"status":"OK","versions":[],"lease":{"released":true},"requests":{"open":["Q-1"],"claimed":[],"oldest_open":"%s"}}\n' "$(date -u -d '10 min ago' +%Y-%m-%dT%H:%M:%SZ)"
STUB
    cat > "$W/cut-bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
    "variable get CI_GO_GATE"*) [ -z "\${CUT_CRF_SLEEP:-}" ] || sleep "\$CUT_CRF_SLEEP"; echo on ;;
    "api repos/acme/repo/pulls/3101") echo '{"state":"open","head":{"sha":"deadbeef01","repo":{"full_name":"acme/repo","fork":false}},"base":{"repo":{"full_name":"acme/repo"}}}' ;;
    "api repos/acme/repo/commits/deadbeef01") printf '{"commit":{"committer":{"date":"%s"}}}\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
    "api --paginate repos/acme/repo/commits/deadbeef01/check-runs"*) echo '{"check_runs":[{"id":1,"name":"lint","status":"completed","conclusion":"failure","completed_at":"2026-10-23T10:03:00Z"}]}' ;;
    "api --paginate repos/acme/repo/issues/3101/events"*) echo '[]' ;;
    *) exec "$W/bin/gh" "\$@" ;;
esac
STUB
    chmod +x "$W/cut-bin/python3" "$W/cut/rmq-sleep.sh" "$W/cut/rmq-fail.sh" "$W/cut/rmq-ok.sh" "$W/cut-bin/gh"
    git -C "$W/repo" init -q 2>/dev/null
    git -C "$W/repo" remote add origin https://github.com/acme/repo.git
    printf '# chief\nrelease: R8843\n' > "$W/handover/cut-chief.md"
    cut_rows="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\\n' 3101 feat/himmel-8843-x false me false "$(iso_ago 1)" 0 deadbeef01 '')"
    cut_tick() { PATH="$W/cut-bin:$PATH" NEXT_DISPATCH_MIRROR="$cut_m" HIMMEL_RELEASE_STATE_DIR="$W/cut/releases" STUB_PR_ROWS="$cut_rows" TICK_RMQ_PROBE="$W/cut/rmq-${CUT_RMQ:-ok}.sh" TOKEN='' bash "$SUT" --doc "$W/handover/cut-chief.md" "$@" 2>/dev/null; printf '%s\n' "$?" > "$W/cut/rc"; }
    cut_exit() { [ "$(cat "$W/cut/rc")" = 0 ] && pass "(8843) $1 exits 0" || fail "(8843) $1 exits $(cat "$W/cut/rc")"; }
    cut_healthy="$(cut_tick | sed 's/cheap-red:[0-9]*s/cheap-red:Ns/')"
    cut_exit 'a healthy tick'
    case "$cut_healthy" in *' residual-cap=v1.1.3:16 open=v1.1.3:16 rm-queue=1,10m crfirst=#3101:cheap-red:Ns') pass '(8843) a healthy tick ends in the residual-cap, open, rm-queue and crfirst fields' ;; *) fail "(8843) a healthy tick changed its residual-cap, open, rm-queue or crfirst fields: $cut_healthy" ;; esac
    cut_verbose="$(cut_tick --verbose)"
    cut_exit 'a healthy verbose tick'
    contains '(8843) a healthy verbose tick prints the residual-cap line' "$cut_verbose" 'residual-cap: v1.1.3:16'
    contains '(10260) a healthy verbose tick prints the open line' "$cut_verbose" 'open: v1.1.3:16'
    contains '(8843) a healthy verbose tick prints the release-queue line' "$cut_verbose" 'rm-queue: 1,10m'
    contains '(8843) a healthy verbose tick prints the held CI-release head' "$cut_verbose" 'crfirst: #3101:cheap-red:'
    contains '(8843) a healthy tick prints the residual-cap count' "$cut_healthy" ' residual-cap=v1.1.3:16'
    contains '(10260) a healthy tick prints the open count' "$cut_healthy" ' open=v1.1.3:16'
    contains '(8843) a healthy tick prints the release queue' "$cut_healthy" ' rm-queue=1,10m'
    contains '(8843) a healthy tick prints the held CI-release head' "$cut_healthy" ' crfirst=#3101:cheap-red:Ns'
    cut_cap="$(CUT_PY_SLEEP=5 TICK_DEADLINE_SEC=1 cut_tick)"
    cut_exit 'a tick whose cap read the deadline cuts'
    contains '(8843) a cap read the deadline cuts prints residual-cap=?' "$cut_cap" ' residual-cap=?'
    contains '(10260) a read the deadline cuts prints open=?' "$cut_cap" ' open=?'
    cut_cap="$(CUT_PY_FAIL=1 cut_tick)"
    cut_exit 'a tick whose cap read fails'
    not_contains '(8843) a failed cap read still leaves residual-cap= off' "$cut_cap" ' residual-cap='
    not_contains '(10260) a failed read leaves open= off' "$cut_cap" ' open='
    cut_rmq="$(CUT_RMQ=sleep TICK_DEADLINE_SEC=1 cut_tick)"
    cut_exit 'a tick whose release-queue read the deadline cuts'
    contains '(8843) a release-queue read the deadline cuts prints rm-queue=?' "$cut_rmq" ' rm-queue=?'
    cut_rmq="$(CUT_RMQ=fail cut_tick)"
    cut_exit 'a tick whose release-queue read fails'
    contains '(8843) a failed release-queue read still reads rm-queue=off' "$cut_rmq" ' rm-queue=off'
    cut_crf="$(CUT_CRF_SLEEP=1.5 TICK_CRFIRST_FLOOR_SEC=1 TICK_DEADLINE_SEC=2 cut_tick)"
    cut_exit 'a tick whose CI-release sweep the bound cuts'
    contains '(8843) a CI-release sweep the bound cuts prints crfirst=?' "$cut_crf" ' crfirst=?'
    cut_crf="$(CUT_CRF_SLEEP=1.5 TICK_DEADLINE_SEC=2 cut_tick)"
    cut_exit 'a tick whose sweep is reached with the deadline already past'
    contains '(8843) a sweep reached with the deadline already past still finishes and prints its heads' "$cut_crf" ' crfirst=#3101:cheap-red:'
    cut_crf="$(STUB_PR_FAIL=1 cut_tick)"
    cut_exit 'a tick whose pr read fails'
    not_contains '(8843) a failed pr read leaves crfirst= off' "$cut_crf" 'crfirst='
    rm -rf "$W/repo/.git" "$W/cut" "$W/cut-bin" "$W/handover/cut-chief.md"
else
    skip '(8843) cut-read rows: no timeout binary'
fi

help_out="$(bash "$SUT" --help 2>&1)"
help_cites="$(printf '%s\n' "$help_out" | grep -oE 'HIMMEL-[0-9]+|decision [0-9]+' | sort -u | tr '\n' ' ')"
if [ -n "$help_cites" ]; then
    fail "(9823) tick.sh --help cites a ticket key or decision number: $help_cites"
else
    pass '(9823) tick.sh --help cites no ticket key and no decision number'
fi
contains '(9823) tick.sh --help still prints the usage line' "$help_out" 'usage: tick.sh [--verbose]'
for help_field in 'fleet=<live>/<cap>' 'flakes=<rows>/<suites>' 'parked=<leg>' 'holds=<leg>' 'hreg=<n>/<n>/<n>' 'chains=UNWIRED:<k>' 'review=<date>' 'cadence=<name>' 'pool-stale=<n>' 'wt-orphans=<n|unknown>'; do
    contains "(9823) tick.sh --help still documents $help_field" "$help_out" "$help_field"
done

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick-b.sh'
    exit 0
fi
printf 'FAIL - test-tick-b.sh (%s failure(s))\n' "$fails"
exit 1
