#!/usr/bin/env bash
# test-check-write-hold.sh — hermetic tests for check-write-hold.sh, the write half of the single-writer barrier.
#
# HOME, HANDOVER_DIR and the queue-lock runtime dirs are pinned to a temp dir at the top, so no row, event or lock
# lands in the real ~/.himmel/state/holds or the live release queue; a row at the end asserts no row of this run
# (named by its temp path) is in the real register. Locks are real queue-lock.sh locks under the temp root.
# A stub holds.py sits in a copied tree (stub_tree), so the hook carries no test seam for it.
#
# Every payload is a fixture file written by fx. Rows are aged with python's os.utime, so the suite needs no GNU touch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/check-write-hold.sh"
HOLDS="$HERE/../handover/chief-kit/holds.py"
QL="$HERE/../handover/queue-lock.sh"
TRUST="$HERE/../ci/ci-trust-paths.txt"
LAUNCHER="$HERE/run-hook-with-bash.js"
for tool in python3 git jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'SKIP - test-check-write-hold.sh (%s not installed)\n' "$tool"
        exit 0
    fi
done
# The grant line names the hook's own primary checkout's holds.py, the hook's sibling when that has none.
HOLDS_HOME="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
HOLDS_REAL="${HOLDS_HOME%/.git}/scripts/handover/chief-kit/holds.py"
[ -n "$HOLDS_HOME" ] && [ -f "$HOLDS_REAL" ] || HOLDS_REAL="$(cd "$(dirname "$HOLDS")" && pwd -P)/holds.py"

REAL_HOME="$HOME"

W="$(mktemp -d "${TMPDIR:-/tmp}/write-hold-test.XXXXXX")" || exit 1
W="$(cd "$W" && pwd -P)"
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT  # restore modes first: a chmod 000 dir would block the cleanup

export HOME="$W/home" HANDOVER_DIR="$W/h" XDG_RUNTIME_DIR="$W/xdg" HIMMELCTL_CACHE_DIR="$W/cache" HIMMEL_CONFIG_DIR="$W/cfg" TMPDIR="$W/tmp"
mkdir -p "$HOME" "$HANDOVER_DIR/u/r" "$XDG_RUNTIME_DIR" "$HIMMELCTL_CACHE_DIR" "$HIMMEL_CONFIG_DIR" "$TMPDIR" "$W/nobin" "$W/outside"
chmod 700 "$XDG_RUNTIME_DIR"
: > "$HIMMELCTL_CACHE_DIR/.env"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_DOC HIMMEL_HOLD_KEY HIMMEL_HOLD_DOC HIMMEL_HOLD_LABEL WRITE_HOLD_OK HOLDS_QUEUE_LOCK HOLDS_GH QUEUE_LOCK_TTL_SECONDS CLAUDE_CODE_SESSION_ID
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fails=0
total=0
pass() { total=$((total + 1)); printf 'ok - %s\n' "$1"; }
fail() { total=$((total + 1)); printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3' in '$2')" ;; *) pass "$1" ;; esac; }

hp() { python3 -I "$HOLDS" "$@"; }

R="$W/repo"
mkdir -p "$R/scripts/lib" "$R/sub" "$R/realdir"
git -C "$R" init -q -b main
: > "$R/scripts/lib/rename-aliases.tsv"
echo seed > "$R/seed.txt"
git -C "$R" add -A
git -C "$R" commit -q -m base
WT="$W/wt"
git -C "$R" worktree add -q -b wt-branch "$WT"

REG="$HOME/.himmel/state/holds"
EVENTS="$REG/events.log"
esc() { local s="${1//\%/%25}"; printf '%s' "${s//\//%2F}"; }
slugdir() { printf '%s/%s' "$REG" "$(esc "$R")"; }
rowf() { printf '%s/%s' "$(slugdir)" "$(esc "$1")"; }
ev_count() { if [ -f "$EVENTS" ]; then wc -l < "$EVENTS" | tr -d ' '; else echo 0; fi; }
ev_last() { tail -n 1 "$EVENTS" 2>/dev/null | cut -f2; }
row_field() { cut -f"$2" "$(rowf "$1")" 2>/dev/null; }
hasrow() { if [ -e "$(rowf "$2")" ]; then pass "$1"; else fail "$1 (no row for $2)"; fi; }
norow() { if [ -e "$(rowf "$2")" ]; then fail "$1 (row for $2)"; else pass "$1"; fi; }
age_row() { python3 -I -c 'import os,sys,time; t=time.time()-7200; os.utime(sys.argv[1],(t,t))' "$(rowf "$1")"; }
docof() {
    local f="$HANDOVER_DIR/u/r/$1-case.md"
    [ -f "$f" ] || printf '# doc\n' > "$f"
    printf '%s' "$f"
}

# fx [tool] [field] <path> [cwd]: the payload fixture every row feeds the hook. FX names the file.
FX="$W/fx.json"
fx() {
    jq -n --arg t "$1" --arg f "$2" --arg p "$3" --arg c "${4:-$R}" \
        '{tool_name:$t, cwd:$c, tool_input:{($f):$p}}' > "$FX"
}

# as_worker <key> <extra env...> : run HOOK_UT on $FX as that worker, with the doc and label the launcher would export.
HOOK_UT="$HOOK"
RC=0 OUT="" ERR=""
as_worker() {
    local key="$1"
    shift
    OUT=$(env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_KEY="$key" HIMMEL_HOLD_DOC="$(docof "$key")" HIMMEL_HOLD_LABEL="$key lbl" "$@" "$BASH" "$HOOK_UT" < "$FX" 2> "$W/err")
    RC=$?
    ERR=$(cat "$W/err")
}
# w <key> <path> [cwd]: a plain Write from that worker.
w() { fx Write file_path "$2" "${3:-$R}"; as_worker "$1"; }

deny_text() {  # deny_text <path> <holder> <rival>
    printf '%s is held by %s (%s lbl, claim). Keep working on other files, and send your chief: HOLD-ASK %s %s. Chief grants with: python3 -I %q grant --key %s --repo %q %q. Bypass: WRITE_HOLD_OK=1 in the launching shell' \
        "$1" "$2" "$2" "$1" "$3" "$HOLDS_REAL" "$3" "$R" "$1"
}
trust_text() {  # trust_text <path> <holder> <rival>: grant-route says chief
    printf '%s is a trust path, held by %s (%s lbl, claim). Keep working on other files. This deny is logged: your chief sees it on its tick (hreg=) and can stamp a grant with: python3 -I %q grant --key %s --repo %q --chief-doc CHIEF_DOC %q. Otherwise wait for its release, or the operator launches with WRITE_HOLD_OK=1' \
        "$1" "$2" "$2" "$HOLDS_REAL" "$3" "$R" "$1"
}
operator_text() {  # operator_text <path> <holder>: grant-route says operator
    printf '%s is a settings or CI-workflow path, held by %s (%s lbl, claim). Keep working on other files. This deny is logged: your chief sees it on its tick (hreg=), and only the operator grants it, in a real terminal. Otherwise wait for its release, or the operator launches with WRITE_HOLD_OK=1' "$1" "$2" "$2"
}

# stub_tree <holds.py body>: a copy of the hook whose sibling holds.py is the stub.
STUB="$W/stub"
stub_tree() {
    mkdir -p "$STUB/scripts/hooks" "$STUB/scripts/handover/chief-kit"
    cp "$HOOK" "$STUB/scripts/hooks/check-write-hold.sh" 2>/dev/null
    printf '%s\n' "$1" > "$STUB/scripts/handover/chief-kit/holds.py"
    HOOK_UT="$STUB/scripts/hooks/check-write-hold.sh"
}

KA=HIMMEL-101
KB=HIMMEL-102

# ---- the deny, and the row a free write publishes
w "$KA" "$R/a01.txt"
same "unheld file: exit 0" "$RC" 0
same "unheld file: nothing on stdout" "$OUT" ""
same "unheld file: nothing on stderr" "$ERR" ""
hasrow "unheld file: a row is published" a01.txt
same "the row's key is the worker's" "$(row_field a01.txt 1)" "$KA"
same "the row's label equals HIMMEL_HOLD_LABEL" "$(row_field a01.txt 2)" "$KA lbl"
same "the row's doc equals HIMMEL_HOLD_DOC" "$(row_field a01.txt 3)" "$(docof "$KA")"
same "the row's source is claim" "$(row_field a01.txt 4)" claim

before="$(ev_count)"
w "$KB" "$R/a01.txt"
same "another worker's live file: exit 2" "$RC" 2
same "the deny text is exact" "$ERR" "$(deny_text a01.txt "$KA" "$KB")"
lacks "the deny never names the per-repo opt-out" "$ERR" ".single-writer"
same "the deny is a structured decision" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision')" deny
same "the structured reason is the deny text" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "$(deny_text a01.txt "$KA" "$KB")"
same "the deny appends one event" "$(ev_count)" "$((before + 1))"
same "that event is a deny" "$(ev_last)" deny
same "the row still names the holder" "$(row_field a01.txt 1)" "$KA"

w "$KA" "$R/a01.txt"
same "own file: exit 0" "$RC" 0
same "own file: nothing on stdout" "$OUT" ""

hp grant --key "$KB" --repo "$R" a01.txt > /dev/null 2>&1
w "$KB" "$R/a01.txt"
same "a granted rival: exit 0" "$RC" 0

# ---- I12: a claim outlives the grace while its holder's real lock is held
K12=HIMMEL-121
K12B=HIMMEL-122
w "$K12" "$R/a12.txt"
age_row a12.txt
bash "$QL" acquire "$(docof "$K12")" sess-a12 > /dev/null 2>&1
w "$K12B" "$R/a12.txt"
same "I12 aged claim, holder's lock held: exit 2" "$RC" 2
contains "I12 the deny names the holder" "$ERR" "$K12"
bash "$QL" release "$(docof "$K12")" sess-a12 > /dev/null 2>&1
w "$K12B" "$R/a12.txt"
same "I12 aged claim, lock released: exit 0" "$RC" 0
same "I12 the rival took the row over" "$(row_field a12.txt 1)" "$K12B"

# ---- missing markers and off switches: pass, no row
fx Write file_path "$R/a20.txt"
OUT=$(env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_KEY="$KA" "$BASH" "$HOOK" < "$FX" 2> "$W/err"); RC=$?
same "key but no doc: exit 0" "$RC" 0
norow "key but no doc: no row" a20.txt

OUT=$(env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_DOC="$(docof "$KA")" "$BASH" "$HOOK" < "$FX" 2> "$W/err"); RC=$?
same "marker but no key: exit 0" "$RC" 0
norow "marker but no key: no row" a20.txt

OUT=$(env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_KEY='not a key' HIMMEL_HOLD_DOC="$(docof "$KA")" "$BASH" "$HOOK" < "$FX" 2> "$W/err"); RC=$?
same "a key the regex refuses: exit 0" "$RC" 0
norow "a key the regex refuses: no row" a20.txt

OUT=$(env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_KEY="$KA" HIMMEL_HOLD_DOC=u/r/rel-doc.md "$BASH" "$HOOK" < "$FX" 2> "$W/err"); RC=$?
same "a relative doc: exit 0" "$RC" 0
norow "a relative doc: no row" a20.txt

fx Write file_path "$R/a01.txt"
OUT=$(env HIMMEL_HOLD_KEY="$KB" HIMMEL_HOLD_DOC="$(docof "$KB")" "$BASH" "$HOOK" < "$FX" 2> "$W/err"); RC=$?
same "no HIMMEL_CONSOLE_LEG: exit 0" "$RC" 0
same "no HIMMEL_CONSOLE_LEG: no stdout" "$OUT" ""

w "$KA" "$R/a21.txt"
fx Write file_path "$R/a21.txt"
as_worker "$KB" WRITE_HOLD_OK=1
same "WRITE_HOLD_OK=1 on a held file: exit 0" "$RC" 0
same "WRITE_HOLD_OK=1 leaves the row alone" "$(row_field a21.txt 1)" "$KA"

touch "$REG/OFF"
w "$KB" "$R/a21.txt"
same "sentinel present, held file: exit 0" "$RC" 0
rm -f "$REG/OFF"

w "$KA" "$W/outside/a22.txt" "$W/outside"
same "a path outside a git repo: exit 0" "$RC" 0

w "$KA" "$R/scripts/ci/suite-tiers.tsv"
same "exempt path: exit 0" "$RC" 0
norow "exempt path: no row" scripts/ci/suite-tiers.tsv

before="$(ev_count)"
w "$KA" "$REG/$(esc "$R")/forged"
same "a direct write into the register: exit 2" "$RC" 2
same "a direct write into the register: one event" "$(ev_count)" "$((before + 1))"
contains "a direct write into the register: the deny says why" "$ERR" "holds register"
lacks "a direct write into the register: the printed holds.py path is the real one" "$ERR" "/../"

# ---- I2 and payload shapes
K2A=HIMMEL-201
K2B=HIMMEL-202
w "$K2A" "$R/b01.txt"; rc1=$RC
w "$K2B" "$R/b02.txt"; rc2=$RC
same "I2 disjoint files, first key: exit 0" "$rc1" 0
same "I2 disjoint files, second key: exit 0" "$rc2" 0

fx Write file_path "$R/b01.txt"
jq '. + {agent_id:"sub-1", agent_type:"general-purpose"}' "$FX" > "$FX.tmp" && mv "$FX.tmp" "$FX"
as_worker "$K2A"
same "same key, subagent payload: exit 0" "$RC" 0

w "$KA" "$R/b10.txt"
fx MultiEdit file_path "$R/b10.txt"
as_worker "$KB"
same "MultiEdit on a held file: exit 2" "$RC" 2
w "$KA" "$R/b11.ipynb"
fx NotebookEdit notebook_path "$R/b11.ipynb"
as_worker "$KB"
same "NotebookEdit notebook_path on a held file: exit 2" "$RC" 2

w "$KA" "$R/b12.txt"
w "$KB" "b12.txt" "$R"
same "a relative path onto a held file: exit 2" "$RC" 2
w "$KB" "sub/../b12.txt" "$R"
same "a .. spelling onto a held file: exit 2" "$RC" 2
w "$KB" "$R/no/such/dir/../../../b12.txt"
same "a .. spelling through missing directories: exit 2" "$RC" 2
: > "$R/b13.txt"
ln -s b13.txt "$R/link13"
w "$KA" "$R/b13.txt"
w "$KB" "$R/link13"
same "a symlink onto a held file: exit 2" "$RC" 2
contains "the symlink deny names the real file" "$ERR" "b13.txt is held by"
ln -s "$R/realdir" "$R/ldir"
w "$KA" "$R/realdir/b14.txt"
w "$KB" "$R/ldir/b14.txt"
same "a path through a symlinked directory onto a held file: exit 2" "$RC" 2

: > "$R/b15.txt"
w "$KA" "$R/b15.txt"
prev=b15.txt
i=1
while [ "$i" -le 9 ]; do
    ln -s "$prev" "$R/hop$i"
    prev="hop$i"
    i=$((i + 1))
done
w "$KB" "$R/hop8"
same "8 symlink hops onto a held file: exit 2" "$RC" 2
w "$KB" "$R/hop9"
same "9 symlink hops: past the limit the write passes" "$RC" 0
norow "9 symlink hops: no row" hop9

names_before="$(find "$(slugdir)" -type f | wc -l | tr -d ' ')"
w "$KA" "$R/sub"
same "a path naming a directory: exit 0" "$RC" 0
norow "a path naming a directory: no row" sub
w "$KA" "$R/nomiss/."
same "a directory spelling of a missing directory: exit 0" "$RC" 0
same "directory spellings publish no row" "$(find "$(slugdir)" -type f | wc -l | tr -d ' ')" "$names_before"

# ---- what the bash publisher writes, read back by holds.py
w "$KA" "$R/with space 100%.txt"
same "a path with a space and a percent: exit 0" "$RC" 0
contains "holds.py read returns that row" "$(hp read --repo "$R")" "with space 100%.txt	$KA	$KA lbl	claim"
w "$KB" "$R/with space 100%.txt"
same "a rival on a path with a space: exit 2" "$RC" 2
grant_line="$(printf '%s' "$ERR" | sed -n 's/.*Chief grants with: \(.*\)\. Bypass:.*/\1/p')"
bash -c "$grant_line" > /dev/null 2>&1
same "the printed grant line pastes and runs on a path with a space" "$?" 0
w "$KB" "$R/with space 100%.txt"
same "the pasted grant lets that rival write" "$RC" 0

fx Write file_path "$R/b20.txt"
OUT=$(env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_KEY="$KA" HIMMEL_HOLD_DOC="$(docof "$KA")" HIMMEL_HOLD_LABEL="$(printf 'tab\tlabel')" "$BASH" "$HOOK" < "$FX" 2> "$W/err"); RC=$?
same "a tab in the label: exit 0" "$RC" 0
contains "a tab in the label reads back cleaned, as holds.py cleans it" "$(hp read --repo "$R")" "b20.txt	$KA	tab label	claim"

leftover="$(find "$(slugdir)" -name '%00*' 2>/dev/null | wc -l | tr -d ' ')"
same "the publisher leaves no temp file behind" "$leftover" 0
printf 'x\n' > "$(slugdir)/%00w.4242"
lacks "a temp file the publisher left is never a row" "$(hp read --repo "$R")" "w.4242"
rm -f "$(slugdir)/%00w.4242"

# A stub ln on PATH loses the race: it copies a rival's row into place when RACE_ROW names one, and always fails.
mkdir -p "$W/stubln"
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ -z "${RACE_ROW:-}" ] || cp "$RACE_ROW" "$2"\nexit 1\n' > "$W/stubln/ln"
chmod +x "$W/stubln/ln"
w "$KA" "$R/b25.txt"
mv "$(rowf b25.txt)" "$W/race-row"
fx Write file_path "$R/b25.txt"
as_worker "$KB" PATH="$W/stubln:$PATH" RACE_ROW="$W/race-row"
same "a lost ln race answers as a contested row: exit 2" "$RC" 2
contains "a lost ln race: the deny names the winner" "$ERR" "$KA"
same "a lost ln race: the row still names the winner" "$(row_field b25.txt 1)" "$KA"
KR=HIMMEL-251
fx Write file_path "$R/b26.txt"
as_worker "$KR" PATH="$W/stubln:$PATH"
same "an ln that fails and leaves no row: exit 0" "$RC" 0
contains "an ln that fails and leaves no row: says what failed" "$ERR" "holds register"
norow "an ln that fails and leaves no row: no row" b26.txt

long="$(printf 'x%.0s' $(seq 1 300))"
names_before="$(find "$(slugdir)" -type f | wc -l | tr -d ' ')"
before="$(ev_count)"
w "$KA" "$R/$long"
same "a 300-byte path: exit 0" "$RC" 0
same "a 300-byte path: silent" "$ERR" ""
same "a 300-byte path: no row" "$(find "$(slugdir)" -type f | wc -l | tr -d ' ')" "$names_before"
same "a 300-byte path: one event" "$(ev_count)" "$((before + 1))"
same "a 300-byte path: that event is a fault" "$(ev_last)" fault

# Plan deviation, ruled by the chief: a row by this name would read as a grant of b30.txt to that key (holds.py op_read
# skips it, claim_one faults on it), so the hook publishes none. The gap: a file with such a name is written with no hold.
w "$KA" "$R/b30.txt"
before="$(ev_count)"
w "$KB" "$R/b30.txt.grant.$KB"
same "a path shaped like a grant: exit 0" "$RC" 0
norow "a path shaped like a grant: no row" "b30.txt.grant.$KB"
same "a path shaped like a grant: one fault event" "$(ev_count)" "$((before + 1))"
same "that event is a fault" "$(ev_last)" fault
w "$KB" "$R/b30.txt"
same "a path shaped like a grant grants nothing: the rival is still denied the real file" "$RC" 2

ESC_KEY=HIMMEL-301
for p in 'plain.txt' 'dir/sub/file.sh' 'a b c.txt' '100%.txt' '%2F.txt' '%25x' 'naïve/é.md' '[x]*?.txt' '~tilde' '-dash.txt' 'back\slash' 'amp&ersand' "quo'te" '#hash'; do
    want="$(python3 -I -c 'import os,sys; sys.path.insert(0, sys.argv[1]); import holds; sys.stdout.buffer.write(os.fsencode(holds.escape(sys.argv[2])))' "$(dirname "$HOLDS")" "$p")"
    w "$ESC_KEY" "$R/$p"
    if [ -e "$(slugdir)/$want" ]; then pass "escape is byte-equal to holds.py: $p"; else fail "escape is byte-equal to holds.py: $p (no $want)"; fi
done

# ponytail row: the common path does not fold rename-aliases.tsv, so the old spelling is its own row until the commit check.
printf 'scripts/oldx\tscripts/newx\tdirectory\tfail\tx\tx\n' > "$R/scripts/lib/rename-aliases.tsv"
w "$KA" "$R/scripts/newx/f.sh"
w "$KB" "$R/scripts/oldx/f.sh"
same "a renamed path passes under its other name" "$RC" 0
hasrow "the hook does not fold aliases: the old spelling has its own row" scripts/oldx/f.sh
: > "$R/scripts/lib/rename-aliases.tsv"

# ---- trust paths
w "$KA" "$R/scripts/handover/chief-kit/holds.py"
w "$KB" "$R/scripts/handover/chief-kit/holds.py"
same "a trust path held by a rival: exit 2" "$RC" 2
same "the trust path routes chief in the real holds.py" "$(python3 -I "$HOLDS_REAL" grant-route --repo "$R" -- scripts/handover/chief-kit/holds.py)" chief
same "route chief: the deny text is exact" "$ERR" "$(trust_text scripts/handover/chief-kit/holds.py "$KA" "$KB")"
lacks "route chief: the deny has no HOLD-ASK" "$ERR" "HOLD-ASK"
lacks "route chief: the deny no longer says there is no grant" "$ERR" "has no grant"
w "$KA" "$R/.claude/settings.json"
w "$KB" "$R/.claude/settings.json"
same "a settings file held by a rival: exit 2" "$RC" 2
same "a settings file routes operator in the real holds.py" "$(python3 -I "$HOLDS_REAL" grant-route --repo "$R" -- .claude/settings.json)" operator
same "route operator: the deny text is exact" "$ERR" "$(operator_text .claude/settings.json "$KA")"
lacks "route operator: the deny has no HOLD-ASK" "$ERR" "HOLD-ASK"
lacks "route operator: the deny offers no chief stamp" "$ERR" "--chief-doc"

w "$KA" "$R/scripts/hooks/lib/x.sh"
w "$KB" "$R/scripts/hooks/block-x.sh"
w "$KA" "$R/scripts/hooks/block-x.sh"; rc1=$RC; e1=$ERR
w "$KB" "$R/scripts/hooks/lib/x.sh"; rc2=$RC; e2=$ERR
same "crossed trust holders, first: exit 2" "$rc1" 2
same "crossed trust holders, second: exit 2" "$rc2" 2
same "crossed trust holders, first: trust-path text" "$e1" "$(trust_text scripts/hooks/block-x.sh "$KB" "$KA")"
same "crossed trust holders, second: trust-path text" "$e2" "$(trust_text scripts/hooks/lib/x.sh "$KA" "$KB")"

grep -vE '^(#|$)' "$TRUST" > "$W/trust-patterns"
for p in scripts/handover/chief-kit/holds.py scripts/hooks/check-write-hold.sh; do
    if printf '%s\n' "$p" | grep -qE -f "$W/trust-patterns"; then pass "$p matches ci-trust-paths.txt"; else fail "$p matches ci-trust-paths.txt"; fi
done

# ---- multi-key docs: only the first key is the worker's identity
K3A=HIMMEL-311
K3B=HIMMEL-312
printf '# %s %s\n' "$K3A" "$K3B" > "$HANDOVER_DIR/u/r/$K3A-$K3B.md"
hp claim --key "$K3A" --label orig --doc "$HANDOVER_DIR/u/r/$K3A-$K3B.md" --repo "$R" c01.txt > /dev/null 2>&1
fx Write file_path "$R/c01.txt"
OUT=$(env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_KEY="$K3A" HIMMEL_HOLD_DOC="$HANDOVER_DIR/u/r/$K3A-$K3B-RESUME.md" HIMMEL_HOLD_LABEL=resume "$BASH" "$HOOK" < "$FX" 2> "$W/err"); RC=$?
same "a multi-key doc's own RESUME worker, same first key: exit 0" "$RC" 0
w "$K3B" "$R/c02.txt"
w "$K3A" "$R/c02.txt"
same "a doc whose first key is that worker's second key: exit 2" "$RC" 2

# ---- repo identity and the per-repo opt-out
K4=HIMMEL-401
printf '> **Writes:** scripts/d01.sh\n' > "$HANDOVER_DIR/u/r/$K4-seed.md"
hp seed --key "$K4" --label seeded --doc "$HANDOVER_DIR/u/r/$K4-seed.md" --repo "$R" > /dev/null 2>&1
hasrow "the seed published its row" scripts/d01.sh
w "$KB" "$WT/scripts/d01.sh" "$WT"
same "seeded from the launcher's context, written from a linked worktree: exit 2" "$RC" 2
w "$KA" "$WT/d02.txt" "$WT"
same "a free write from a linked worktree: exit 0" "$RC" 0
hasrow "a row from a linked worktree lands in the primary's register" d02.txt

w "$KA" "$R/d10.txt"
touch "$WT/.single-writer"
w "$KB" "$WT/d10.txt" "$WT"
same "I8 marker only in the worktree: the barrier still applies" "$RC" 2
rm -f "$WT/.single-writer"
touch "$R/.single-writer"
w "$KB" "$R/d10.txt"
same "I8 marker at the primary, held file: exit 0" "$RC" 0
w "$KB" "$R/d11.txt"
same "I8 marker at the primary, free file: exit 0" "$RC" 0
norow "I8 marker at the primary: no row" d11.txt
rm -f "$R/.single-writer"

# ---- I5: every fault passes, silently unless the register itself is the fault
w "$KA" "$R/e01.txt"
for bad in 'not json' '[1]' '' '{"tool_input":{"file_path":7}}'; do
    printf '%s' "$bad" > "$FX"
    as_worker "$KB"
    same "bad stdin '$bad': exit 0" "$RC" 0
    same "bad stdin '$bad': silent" "$OUT$ERR" ""
done
fx Write file_path "$R/e01.txt"
as_worker "$KB" PATH="$W/nobin"
same "no jq on PATH: exit 0" "$RC" 0
same "no jq on PATH: silent" "$OUT$ERR" ""

stub_tree 'import sys; sys.exit(0)'
awk '{print} /^trap /{print ": \"${CRASH_ROW_UNSET_VARIABLE}\""}' "$HOOK" > "$HOOK_UT" 2>/dev/null
if grep -q CRASH_ROW_UNSET_VARIABLE "$HOOK_UT"; then pass "the crash row really crashes the hook"; else fail "the crash row really crashes the hook (no trap line to inject after)"; fi
as_worker "$KB"
same "a hook crash: exit 0" "$RC" 0
same "a hook crash: silent" "$OUT$ERR" ""

stub_tree 'import sys; sys.exit(0)'
awk '{print} /^trap /{print "if then fi"}' "$HOOK" > "$HOOK_UT" 2>/dev/null
as_worker "$KB"
same "a syntax error in the hook is not a deny: exit 0" "$RC" 0
same "a syntax error in the hook: silent" "$OUT$ERR" ""

stub_tree 'import sys; sys.stderr.write("some other failure\n"); sys.exit(1)'
fx Write file_path "$R/e01.txt"
before="$(ev_count)"
as_worker "$KB"
same "holds.py exit 1 with no holds: line: exit 0" "$RC" 0
same "holds.py exit 1 with no holds: line: one event" "$(ev_count)" "$((before + 1))"
same "holds.py exit 1 with no holds: line: that event is a fault" "$(ev_last)" fault

stub_tree 'import sys; sys.stderr.write("holds: e01.txt is held\n"); sys.exit(1)'
as_worker "$KB"
same "control: holds.py exit 1 with a holds: line: exit 2" "$RC" 2

stub_tree 'import sys; sys.exit(3)'
before="$(ev_count)"
as_worker "$KB"
same "holds.py exit 3: exit 0" "$RC" 0
same "holds.py exit 3: one event" "$(ev_count)" "$((before + 1))"
same "holds.py exit 3: that event is a fault" "$(ev_last)" fault

stub_tree 'import sys; sys.exit(0)'
before="$(ev_count)"
as_worker "$KB"
same "holds.py exit 0: exit 0" "$RC" 0
same "holds.py exit 0: no event" "$(ev_count)" "$before"

stub_tree 'import time; time.sleep(60)'
before="$(ev_count)"
start=$SECONDS
as_worker "$KB"
elapsed=$((SECONDS - start))
same "holds.py hanging: the write passes" "$RC" 0
if [ "$elapsed" -lt 15 ]; then pass "holds.py hanging: the hook's own bound fires under 15 s (${elapsed}s)"; else fail "holds.py hanging: the hook's own bound fires under 15 s (${elapsed}s)"; fi
same "holds.py hanging: one event" "$(ev_count)" "$((before + 1))"
same "holds.py hanging: that event is a fault" "$(ev_last)" fault
HOOK_UT="$HOOK"

before="$(ev_count)"
as_worker "$KB" TMPDIR="$W/no-such-tmp"
same "mktemp fails on a contested write: exit 0" "$RC" 0
same "mktemp fails on a contested write: one event" "$(ev_count)" "$((before + 1))"
same "mktemp fails on a contested write: that event is a fault" "$(ev_last)" fault

if [ "$(id -u)" != 0 ]; then
    KU=HIMMEL-501
    chmod 000 "$(slugdir)"
    w "$KU" "$R/e10.txt"
    same "unreadable register, first run: exit 0" "$RC" 0
    same "unreadable register, first run: one stderr line" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" 1
    contains "unreadable register, first run: says what failed" "$ERR" "holds register"
    if [ -e "$TMPDIR/himmel-hold-warned-$KU" ]; then pass "unreadable register: the marker is under the temp dir"; else fail "unreadable register: the marker is under the temp dir"; fi
    w "$KU" "$R/e11.txt"
    same "unreadable register, second run: exit 0" "$RC" 0
    same "unreadable register, second run: no stderr" "$ERR" ""
    chmod 755 "$(slugdir)"
fi

# ---- I11: the chain's first deny short-circuits, so an earlier deny leaves no row
if command -v node >/dev/null 2>&1; then
    fx ScheduleWakeup file_path "$R/f01.txt"
    env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_KEY="$KA" HIMMEL_HOLD_DOC="$(docof "$KA")" HIMMEL_HOLD_LABEL="$KA lbl" node "$LAUNCHER" --chain "$HERE/guard-worker-wakeup.sh" "$HOOK" < "$FX" > /dev/null 2>&1
    same "I11 an earlier member denies: the chain exits 2" "$?" 2
    norow "I11 an earlier deny leaves no row" f01.txt
    fx Write file_path "$R/f02.txt"
    env HIMMEL_CONSOLE_LEG=1 HIMMEL_HOLD_KEY="$KA" HIMMEL_HOLD_DOC="$(docof "$KA")" HIMMEL_HOLD_LABEL="$KA lbl" node "$LAUNCHER" --chain "$HERE/guard-worker-wakeup.sh" "$HOOK" < "$FX" > /dev/null 2>&1
    same "control: no earlier deny, the chain exits 0" "$?" 0
    hasrow "control: no earlier deny, the last member publishes" f02.txt
fi

# ---- the suite itself never touched the live register
if [ -e "$REAL_HOME/.himmel/state/holds/$(esc "$R")" ]; then fail "no row of this run is in the real register"; else pass "no row of this run is in the real register"; fi

printf '\n%d tests, %d failed\n' "$total" "$fails"
[ "$fails" -eq 0 ]
