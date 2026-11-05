#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-series-next.sh
# scripts/handover/chief-kit/test-series-publish.sh - suite for series-publish.sh, the publish verb of a stacked series
# (design section 5.2 Publish, failure rows F6 and F10, invariants I3 I5):
#   1. refusals  -> not the writer, unknown item, planned / authoring item, dirty tree, HEAD past wip: rc 2, nothing moves
#   2. F6 clean  -> item k+1 publishes cut_from..wip onto origin/main after k's fix landed on another file: branch pushed,
#                   its commits are exactly k+1's own, the first commit keeps its trailer
#   3. record    -> ledger holds publish_branch + published_head + state published, the worktree is unlocked on the branch
#   4. F6 conflict -> k's fix rewrote a line k+1 also edits: PUBLISH-CONFLICT <file>, rc 2, nothing pushed, ledger byte-equal,
#                   worktree clean on the item branch at wip and still locked
#   5. F10       -> k abandoned, k+1 committed: the pushed branch carries k+1's own commits and none of k's
#   5b. push     -> a refused push (pre-receive hook) exits 1 and moves nothing; the retry publishes
#   5c. ledger   -> a failed ledger write exits 1 after the push and prints the exact two recovery lines; a second publish
#                   from the publish branch prints them again; running them records the item and unlocks the worktree
#   5d. origin   -> an origin branch that already exists is never overwritten; a forced push is told from a plain one by what
#                   a pre-receive hook saw, never by the rc
#   6. no PR     -> the gh shim (on PATH, with a positive control) saw no `pr create`; a published item cannot publish twice
#   7. previous  -> the item before waits: unpublished, no PR, gh empty or failing, PR open or closed refuse rc 2 naming it; merged
#                   or abandoned publishes (GH_CMD shim, as series-next.sh)
#   8. cherry-pick that fails with no conflicted file -> exit 1 with git's message, never PUBLISH-CONFLICT, item branch restored
#   9. cut_from not an ancestor of wip -> refused    10. no commits in cut..wip -> refused    11. a local publish branch -> refused
#   12. a failed fetch exits 1 (main moved from a second clone); 12b. origin unreachable    13. runs from a foreign cwd
#   14. the default branch is read from the remote (ls-remote --symref), not the cached origin/HEAD
#   15. a worktree outside <repo>/.claude/worktrees refuses; a failed unlock shows git's message; a read-only ledger dir
#       gives a refusal, not a traceback (skipped for root, whose 5c rows use a held ledger lock instead)
# SERIES_PUBLISH overrides the script under test (the RED control). Hermetic: temp dir, local bare origin, gh shim.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SERIES_PUBLISH:-$HERE/series-publish.sh}"
NEXT="$HERE/series-next.sh"
LEDGER_PY="$HERE/series-ledger.py"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/series-publish-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]: [$2]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: output contains [$3]: [$2]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }
sl()   { python3 -I "$LEDGER_PY" "$@"; }
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

export HOME="$tmp/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config" GIT_CONFIG_NOSYSTEM=1 FORGE=github
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES SERIES_LEDGER_LOCK_TIMEOUT HIMMEL_FLAG_STACKED_SERIES
export HANDOVER_DIR="$tmp/handovers"; mkdir -p "$HANDOVER_DIR/.locks/go"

git init -q --bare --template= "$tmp/origin.git"   # no template files, as on a minimal CI git: no hooks directory
git --git-dir="$tmp/origin.git" symbolic-ref HEAD refs/heads/main   # origin's default branch is what the verb reads, so it must exist
REPO="$tmp/repo"
git clone -q "$tmp/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@test.local
git -C "$REPO" config user.name t
git -C "$REPO" config maintenance.auto false
git -C "$REPO" checkout -q -b main
printf 'base\n' > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -q -m base
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" remote set-head origin main >/dev/null 2>&1 || git -C "$REPO" fetch -q origin

# a second clone of origin: main moves from here, so REPO's own origin/main is stale until the verb fetches
CL2="$tmp/clone2"
git clone -q "$tmp/origin.git" "$CL2" 2>/dev/null
git -C "$CL2" config user.email t@test.local
git -C "$CL2" config user.name t
main_move() { # <file> <content> <subject>: one commit on origin's main, made from the second clone
    git -C "$CL2" fetch -q origin && git -C "$CL2" checkout -q -B main origin/main && printf '%b' "$2" > "$CL2/$1" \
        && git -C "$CL2" add "$1" && git -C "$CL2" commit -q -m "$3" && git -C "$CL2" push -q origin HEAD:main \
        || { echo "FAIL: fixture main_move ($3)"; exit 1; }
}

# gh shim: records every call; nothing in the publish verb may reach `pr create`. `pr list --head B` answers from the
# tab-separated file $GH_PRS (branch, number, state); GH_PR_FAIL makes it exit 1, as a gh that cannot reach GitHub does.
mkdir -p "$tmp/bin"
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
export GH_PRS="$tmp/prs.tsv"; : > "$GH_PRS"
export GH_CWD_LOG="$tmp/gh-cwd.log"; : > "$GH_CWD_LOG"   # the directory every `pr list` ran in
cat > "$tmp/bin/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
    "pr list"*)
        b=""; p=""
        for a in "$@"; do [ "$p" = "--head" ] && b="$a"; p="$a"; done
        pwd -P >> "$GH_CWD_LOG"
        [ -n "${GH_PR_FAIL:-}" ] && exit 1
        awk -F'\t' -v b="$b" '$1 == b { print $2 "\t" $3 "\t" $4 }' "$GH_PRS"
        exit 0 ;;
    *"auth status"*) exit 0 ;;
    *"repo view"*) echo owner/repo; exit 0 ;;
esac
exit 0
SHIM
chmod +x "$tmp/bin/gh"
export GH_CMD="$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"   # a bare `gh` anywhere under the script resolves to the shim
gh --shim-control >/dev/null

sn()  { rc=0; out="$( cd "$REPO" && bash "$NEXT" "$@" 2>&1 )" || rc=$?; }
sp()  { rc=0; out="$( cd "$REPO" && bash "$SCRIPT" "$@" 2>&1 )" || rc=$?; }
wtp() { printf '%s/.claude/worktrees/series+%s+%s' "$REPO" "$1" "$2"; }
islocked() { git -C "$REPO" worktree list --porcelain | awk -v p="$1" '$1 == "worktree" { cur = ($2 == p) } cur && $1 == "locked" { f = 1 } END { exit !f }'; }
wcommit() { # <worktree> <file> <content> <subject>: one real commit carrying the trailer
    printf '%b' "$3" > "$1/$2"
    git -C "$1" add "$2" && git -C "$1" commit -q -m "$4" -m "Platforms tested: linux" || { echo "FAIL: fixture commit failed ($4 in $1)"; exit 1; }
}
mk() { # <ledger> <writer> <key>...
    local l="$1" w="$2"; shift 2
    sl create --ledger "$l" --sid "$(basename "$l" .json)" --completes-ticket no --writer "$w" || return 1
    local k; for k in "$@"; do sl add-item --ledger "$l" --key "$k" --writes "f-$k.txt" || return 1; done
}

A="$tmp/handovers/doc-A.md"; B="$tmp/handovers/doc-B.md"
mkdir -p "$tmp/ledgers"

# stack <sid> [ledger-dir]: K1 committed (shared-<sid>.txt + k1-<sid>.txt), writer passed A to B, K2 committed on top of K1
# and editing shared-<sid>.txt line 2. Every file name carries the sid, so a fixture commit never repeats bytes already on
# main (wcommit aborts on a failed commit). K1 is then left to the caller (fix commit, merge or abandon).
stack() {
    local sid="$1" L="${2:-$tmp/ledgers}/$1.json"
    mk "$L" "$A" K1 K2 || { echo "FAIL: fixture ledger $sid"; exit 1; }
    sn start --ledger "$L" --doc "$A" K1
    wcommit "$(wtp "$sid" K1)" "shared-$sid.txt" 'l1\nl2\nl3\n' "K1 adds shared"
    wcommit "$(wtp "$sid" K1)" "k1-$sid.txt" 'k1\n' "K1 adds k1"
    sn commit --ledger "$L" --doc "$A" K1
    sn pass --ledger "$L" --doc "$A" "$B"
    sn start --ledger "$L" --doc "$B" K2
    wcommit "$(wtp "$sid" K2)" "shared-$sid.txt" 'l1\nK2 line\nl3\n' "K2 edits shared"
    wcommit "$(wtp "$sid" K2)" "k2-$sid.txt" 'k2\n' "K2 adds k2"
    sn commit --ledger "$L" --doc "$B" K2
}
land_k1() { # <sid> [ledger-dir]: K1 published and its PR merged, main now holds K1 up to its recorded wip
    local w; w="$(git -C "$(wtp "$1" K1)" rev-parse HEAD)"
    git -C "$REPO" push -q origin "$w:refs/heads/main"
    sl set --ledger "${2:-$tmp/ledgers}/$1.json" --key K1 state=published publish_branch="series-pub/$1/K1" published_head="$w" \
        || { echo "FAIL: fixture land_k1 ledger ($1)"; exit 1; }
    printf 'series-pub/%s/K1\t1\tMERGED\tmain\n' "$1" >> "$GH_PRS"
}

# --- 1. refusals ----------------------------------------------------------------------------------------------------
L1="$tmp/ledgers/s1.json"
stack s1
W2="$(wtp s1 K2)"
before="$(cat "$L1")"
sp --ledger "$L1" --doc "$A" K2
check "1: a doc that is not the writer refuses rc 2" "$rc" 2
contains "1: the refusal names the writer" "$out" "$B"
sp --ledger "$L1" --doc "$B" NOPE
check "1: an unknown item refuses rc 2" "$rc" 2
printf 'uncommitted\n' > "$W2/dirty.txt"
sp --ledger "$L1" --doc "$B" K2
check "1: a dirty item worktree refuses rc 2" "$rc" 2
contains "1: the dirty refusal says so" "$out" "is dirty"
lacks "1: the dirty refusal is not a conflict" "$out" "PUBLISH-CONFLICT"
rm -f "$W2/dirty.txt"
wcommit "$W2" late.txt 'late\n' "K2 late commit"
sp --ledger "$L1" --doc "$B" K2
check "1: HEAD past the recorded wip refuses rc 2" "$rc" 2
contains "1: the drift refusal names wip" "$out" "SERIES-DRIFT K2 wip"
git -C "$W2" reset -q --hard HEAD~1
git -C "$W2" checkout -q -b side-s1
sp --ledger "$L1" --doc "$B" K2
check "1: a side branch at wip refuses rc 2" "$rc" 2
contains "1: the branch refusal names the item branch" "$out" "not on the item branch series/s1/K2"
lacks "1: the branch refusal is not a conflict" "$out" "PUBLISH-CONFLICT"
git -C "$W2" checkout -q series/s1/K2
git -C "$W2" branch -q -D side-s1
git -C "$W2" checkout -q -b series-pub/s1/K2   # a local publish branch that origin does not hold
sp --ledger "$L1" --doc "$B" K2
check "1: the publish branch with no origin copy refuses rc 2" "$rc" 2
contains "1: it says the head is not on origin" "$out" "is not on origin"
lacks "1: it prints no recovery line for an unpushed head" "$out" "published_head="
git -C "$W2" push -q origin "HEAD~1:refs/heads/series-pub/s1/K2"   # origin holds the branch, but at a different head
sp --ledger "$L1" --doc "$B" K2
check "1: the publish branch with origin at another head refuses rc 2" "$rc" 2
contains "1: it says the head is not on origin when origin holds another head" "$out" "is not on origin"
lacks "1: it prints no recovery line when origin holds another head" "$out" "published_head="
git -C "$W2" push -q origin --delete series-pub/s1/K2
git -C "$W2" checkout -q series/s1/K2
git -C "$W2" branch -q -D series-pub/s1/K2
L9="$tmp/ledgers/s9.json"
mk "$L9" "$A" P1 || exit 1
sp --ledger "$L9" --doc "$A" P1
check "1: a planned item refuses rc 2" "$rc" 2
contains "1: the state refusal says only committed publishes" "$out" "only a committed item publishes"
check "1: every refusal leaves the ledger byte-equal" "$(cat "$L1")" "$before"
check "1: every refusal leaves the item branch checked out at wip" "$(git -C "$W2" rev-parse --abbrev-ref HEAD) $(git -C "$W2" rev-parse HEAD)" "series/s1/K2 $(jget "$L1" 'd["items"][1]["wip"]')"
check "1: no refusal pushed a branch" "$(git -C "$REPO" ls-remote --heads origin 'series-pub/*' | wc -l | tr -d ' ')" 0

# --- 2. F6 clean: K1's fix touches another file ----------------------------------------------------------------------
W1="$(wtp s1 K1)"
wcommit "$W1" other-s1.txt 'fix\n' "K1 review fix on another file"
sn commit --ledger "$L1" --doc "$B" K1
land_k1 s1   # k merged: main now holds K1 incl. its fix
K2WIP="$(jget "$L1" 'd["items"][1]["wip"]')"
sp --ledger "$L1" --doc "$B" K2
check "2: clean publish rc 0" "$rc" 0
contains "2: prints PUBLISHED-BRANCH" "$out" "PUBLISHED-BRANCH K2 series-pub/s1/K2"
git -C "$REPO" fetch -q origin
check "2: the branch is on origin" "$(git -C "$REPO" ls-remote --heads origin series-pub/s1/K2 | wc -l | tr -d ' ')" 1
check "2: the pushed commits are exactly K2's own" "$(git -C "$REPO" log --reverse --format=%s origin/main..origin/series-pub/s1/K2 | tr '\n' '|')" "K2 edits shared|K2 adds k2|"
check "2: the first commit keeps its trailer" "$(git -C "$REPO" log --reverse --format=%b origin/main..origin/series-pub/s1/K2 | sed -n 1p)" "Platforms tested: linux"
check "2: the branch is based on origin/main" "$(git -C "$REPO" merge-base origin/main origin/series-pub/s1/K2)" "$(git -C "$REPO" rev-parse origin/main)"

# --- 3. record ------------------------------------------------------------------------------------------------------
check "3: ledger state published" "$(jget "$L1" 'd["items"][1]["state"]')" published
check "3: ledger publish_branch" "$(jget "$L1" 'd["items"][1]["publish_branch"]')" series-pub/s1/K2
check "3: ledger published_head is the worktree HEAD" "$(jget "$L1" 'd["items"][1]["published_head"]')" "$(git -C "$W2" rev-parse HEAD)"
check "3: published_head is the pushed head" "$(jget "$L1" 'd["items"][1]["published_head"]')" "$(git -C "$REPO" rev-parse origin/series-pub/s1/K2)"
check "3: the ledger keeps wip" "$(jget "$L1" 'd["items"][1]["wip"]')" "$K2WIP"
check "3: the worktree is on the publish branch" "$(git -C "$W2" rev-parse --abbrev-ref HEAD)" series-pub/s1/K2
check "3: the worktree is unlocked" "$(islocked "$W2" && echo locked || echo free)" free
check "3: the worktree is clean" "$(git -C "$W2" status --porcelain)" ""
check "3: the branch tracks origin" "$(git -C "$W2" rev-parse --abbrev-ref '@{u}')" origin/series-pub/s1/K2
check "3: the item branch stays at wip" "$(git -C "$REPO" rev-parse series/s1/K2)" "$K2WIP"
sp --ledger "$L1" --doc "$B" K2
check "3: a published item cannot publish again (rc 2)" "$rc" 2

# --- 4. F6 conflict: K1's fix rewrites a line K2 also edits ----------------------------------------------------------
L2="$tmp/ledgers/s2.json"
stack s2
W1="$(wtp s2 K1)"; W2="$(wtp s2 K2)"
wcommit "$W1" shared-s2.txt 'l1\nK1 fix\nl3\n' "K1 review fix rewrites line 2"
sn commit --ledger "$L2" --doc "$B" K1
land_k1 s2
before="$(cat "$L2")"
K2WIP="$(jget "$L2" 'd["items"][1]["wip"]')"
sp --ledger "$L2" --doc "$B" K2
check "4: a conflicting publish rc 2" "$rc" 2
contains "4: prints PUBLISH-CONFLICT with the file" "$out" "PUBLISH-CONFLICT shared-s2.txt"
check "4: nothing was pushed" "$(git -C "$REPO" ls-remote --heads origin 'series-pub/s2/*' | wc -l | tr -d ' ')" 0
check "4: the ledger is byte-equal" "$(cat "$L2")" "$before"
check "4: the worktree is back on the item branch at wip" "$(git -C "$W2" rev-parse --abbrev-ref HEAD) $(git -C "$W2" rev-parse HEAD)" "series/s2/K2 $K2WIP"
check "4: the worktree is clean" "$(git -C "$W2" status --porcelain)" ""
check "4: no cherry-pick is left in progress" "$([ -e "$(git -C "$W2" rev-parse --git-path CHERRY_PICK_HEAD)" ] && echo yes || echo no)" no
check "4: the worktree is still locked" "$(islocked "$W2" && echo locked || echo free)" locked
check "4: no local publish branch is left" "$(git -C "$REPO" branch --list 'series-pub/s2/*' | wc -l | tr -d ' ')" 0
sn status --ledger "$L2"
contains "4: status after the conflict still lists K2 committed" "$out" "ITEM K2 state=committed"
lacks "4: status after the conflict shows no drift" "$out" "SERIES-DRIFT K2"

# --- 5. F10: K1 abandoned, K2 committed ------------------------------------------------------------------------------
L3="$tmp/ledgers/s3.json"
mk "$L3" "$A" K1 K2 || exit 1
sn start --ledger "$L3" --doc "$A" K1
wcommit "$(wtp s3 K1)" k1-s3.txt 'k1\n' "K1 only work"
sn commit --ledger "$L3" --doc "$A" K1
sn pass --ledger "$L3" --doc "$A" "$B"
sn start --ledger "$L3" --doc "$B" K2
wcommit "$(wtp s3 K2)" k2-s3.txt 'k2\n' "K2 only work"
sn commit --ledger "$L3" --doc "$B" K2
sn abandon --ledger "$L3" --doc "$B" K1
check "5: control: K1 holds exactly one commit that main lacks" "$(git -C "$REPO" rev-list --count "$(jget "$L3" 'd["items"][0]["cut_from"]')..$(jget "$L3" 'd["items"][0]["wip"]')") $(git -C "$REPO" rev-list --count "origin/main..$(jget "$L3" 'd["items"][0]["wip"]')")" "1 1"
sp --ledger "$L3" --doc "$B" K2
check "5: F10 publish with an abandoned parent rc 0" "$rc" 0
git -C "$REPO" fetch -q origin
check "5: F10 the pushed commits are K2's own and none of K1's" "$(git -C "$REPO" log --format=%s origin/main..origin/series-pub/s3/K2 | tr '\n' '|')" "K2 only work|"
check "5: F10 K1's file is not on the pushed branch" "$(git -C "$REPO" cat-file -e origin/series-pub/s3/K2:k1-s3.txt 2>/dev/null && echo present || echo absent)" absent
check "5: F10 K2's own file is on the pushed branch (control)" "$(git -C "$REPO" cat-file -e origin/series-pub/s3/K2:k2-s3.txt 2>/dev/null && echo present || echo absent)" present

# --- 5b. a failed push moves nothing, and the retry works ------------------------------------------------------------
L4="$tmp/ledgers/s4.json"
stack s4
land_k1 s4
W2="$(wtp s4 K2)"
K2WIP="$(jget "$L4" 'd["items"][1]["wip"]')"
before="$(cat "$L4")"
mkdir -p "$tmp/origin.git/hooks"   # a git without template files creates no hooks directory
printf '#!/bin/sh\nexit 1\n' > "$tmp/origin.git/hooks/pre-receive"; chmod +x "$tmp/origin.git/hooks/pre-receive"
check "5b: control: the pre-receive hook is installed and executable" "$([ -x "$tmp/origin.git/hooks/pre-receive" ] && echo yes || echo no)" yes
sp --ledger "$L4" --doc "$B" K2
check "5b: a refused push exits 1" "$rc" 1
contains "5b: the failure names the push" "$out" "git push of series-pub/s4/K2 failed"
check "5b: the worktree is back on the item branch at wip" "$(git -C "$W2" rev-parse --abbrev-ref HEAD) $(git -C "$W2" rev-parse HEAD)" "series/s4/K2 $K2WIP"
check "5b: no local publish branch is left" "$(git -C "$REPO" branch --list 'series-pub/s4/*' | wc -l | tr -d ' ')" 0
check "5b: the ledger is byte-equal" "$(cat "$L4")" "$before"
check "5b: the worktree is still locked" "$(islocked "$W2" && echo locked || echo free)" locked
rm -f "$tmp/origin.git/hooks/pre-receive"
sp --ledger "$L4" --doc "$B" K2
check "5b: the retry after the push is accepted publishes rc 0" "$rc" 0
contains "5b: the retry prints PUBLISHED-BRANCH" "$out" "PUBLISHED-BRANCH K2 series-pub/s4/K2"

# --- 5c. a failed ledger write prints the exact recovery, and following it works -------------------------------------
RO="$tmp/ledgers ro"   # a space in the path: the printed lines must be shell-quoted
mkdir -p "$RO"
L5="$RO/s5.json"
stack s5 "$RO"
land_k1 s5 "$RO"
W2="$(wtp s5 K2)"
K2WIP="$(jget "$L5" 'd["items"][1]["wip"]')"
# the ledger lock is held by another process and the wait is 0 s: series-ledger.py set fails after the push, for any user
# (a read-only directory would not fail for root)
cat > "$tmp/hold-lock.py" <<'PY'
import fcntl, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)
PY
python3 -I "$tmp/hold-lock.py" "$L5.lock" "$tmp/lock-held" &
HOLDER=$!
for _ in $(seq 1 100); do [ -e "$tmp/lock-held" ] && break; sleep 0.1; done
check "5c: control: the ledger lock is held" "$([ -e "$tmp/lock-held" ] && echo yes || echo no)" yes
SERIES_LEDGER_LOCK_TIMEOUT=0 sp --ledger "$L5" --doc "$B" K2
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
PUBHEAD="$(git -C "$W2" rev-parse HEAD)"
printf -v SETLINE 'python3 -I %q set --ledger %q --key K2 publish_branch=series-pub/s5/K2 published_head=%s state=published' "$LEDGER_PY" "$L5" "$PUBHEAD"
check "5c: a failed ledger write exits 1" "$rc" 1
check "5c: the branch was pushed" "$(git -C "$REPO" ls-remote --heads origin series-pub/s5/K2 | wc -l | tr -d ' ')" 1
check "5c: the ledger still says committed at wip" "$(jget "$L5" 'd["items"][1]["state"]') $(jget "$L5" 'd["items"][1]["wip"]')" "committed $K2WIP"
contains "5c: the exact ledger line is printed" "$out" "$SETLINE"
contains "5c: the exact unlock line is printed" "$out" "git -C $W2 worktree unlock $W2"
contains "5c: it warns against series-next.sh commit" "$out" "do NOT run series-next.sh commit"
printf 'x\n' > "$W2/untracked-5c.txt"   # a dirty tree on the publish branch must still get the recovery lines, never "commit first"
sp --ledger "$L5" --doc "$B" K2
rm -f "$W2/untracked-5c.txt"
check "5c: a second publish from the publish branch refuses rc 2" "$rc" 2
contains "5c: the branch refusal prints the same ledger line" "$out" "$SETLINE"
contains "5c: the branch refusal prints the same unlock line" "$out" "git -C $W2 worktree unlock $W2"
lacks "5c: a dirty tree on the publish branch is not told to commit first" "$out" "commit it and run series-next.sh commit first"
eval "$SETLINE" && git -C "$W2" worktree unlock "$W2"
check "5c: following the printed lines publishes the item" "$(jget "$L5" 'd["items"][1]["state"]') $(jget "$L5" 'd["items"][1]["published_head"]')" "published $PUBHEAD"
check "5c: following the printed lines unlocks the worktree" "$(islocked "$W2" && echo locked || echo free)" free

# --- 5d. an origin branch that already exists is never overwritten: each layer has its own row ------------------------
# stack s6 with the item worktree HEAD pushed to origin's publish ref, so origin holds a branch the script must not touch.
L6="$tmp/ledgers/s6.json"
stack s6
land_k1 s6
W2="$(wtp s6 K2)"
K2WIP="$(jget "$L6" 'd["items"][1]["wip"]')"
# an unrelated commit is used because a copy of the item's own commits equals the cherry-picks when both fall in one second, and that push would succeed
OTHER="$(git -C "$W2" commit-tree -m 'an unrelated commit already on origin' 'HEAD^{tree}')"
git -C "$W2" push -q origin "$OTHER:refs/heads/series-pub/s6/K2"
OSHA="$(git -C "$REPO" ls-remote origin refs/heads/series-pub/s6/K2 | cut -f1)"
before="$(cat "$L6")"
# a: the pre-check sees the branch and refuses
sp --ledger "$L6" --doc "$B" K2
check "5d.a: an existing origin publish branch refuses rc 2" "$rc" 2
contains "5d.a: it says the branch already exists on origin" "$out" "already exists on origin"
check "5d.a: origin's branch is untouched" "$(git -C "$REPO" ls-remote origin refs/heads/series-pub/s6/K2 | cut -f1)" "$OSHA"
check "5d.a: the worktree is on the item branch at wip" "$(git -C "$W2" rev-parse --abbrev-ref HEAD) $(git -C "$W2" rev-parse HEAD)" "series/s6/K2 $K2WIP"
check "5d.a: the ledger is byte-equal" "$(cat "$L6")" "$before"
# b, c: a git that answers the pre-check wrongly. b: rc 2 (absent) while the branch exists, so the push is the last layer;
# c: rc 128 (origin unreadable), which must fail closed rather than read as absent.
REALGIT="$(command -v git)"
mkdir -p "$tmp/gitshim"
# shellcheck disable=SC2016  # the shim's own $* and $@ must stay literal
printf '#!/bin/sh\ncase "$*" in *ls-remote*--exit-code*) exit "$(cat "$GITSHIM_RC")" ;; *" fetch "*) [ -n "${GITSHIM_FETCHFAIL:-}" ] && { echo "fatal: shim: fetch failed" >&2; exit 128; } ;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$tmp/gitshim/git"
chmod +x "$tmp/gitshim/git"
export GITSHIM_RC="$tmp/gitshim.rc"
ORIGPATH="$PATH"
# a pre-receive hook that logs every ref update it is handed (ref, old, new, whether old is an ancestor of new) and rejects a
# non-fast-forward: the evidence that tells a forced push from a plain one, since the rc is the same either way. A plain push of
# a non-fast-forward is refused by the client and never reaches this hook; a forced one does.
HOOKLOG="$tmp/prereceive.log"
# shellcheck disable=SC2016  # the hook's own $old, $new and $anc must stay literal
printf '#!/bin/sh\nwhile read old new ref; do\n  if [ "$old" = 0000000000000000000000000000000000000000 ]; then anc=new\n  elif git merge-base --is-ancestor "$old" "$new" 2>/dev/null; then anc=yes; else anc=no; fi\n  echo "$ref anc=$anc" >> "%s"\n  [ "$anc" = no ] && exit 1\ndone\nexit 0\n' "$HOOKLOG" > "$tmp/origin.git/hooks/pre-receive"
chmod +x "$tmp/origin.git/hooks/pre-receive"
OTHER2="$(git -C "$W2" commit-tree -p "$OTHER" -m 'second' 'HEAD^{tree}')"
OTHER3="$(git -C "$W2" commit-tree -m 'third, unrelated to the second' 'HEAD^{tree}')"
git -C "$W2" push -q origin "$OTHER2:refs/heads/ctl-s6" >/dev/null 2>&1
git -C "$W2" push -q -f origin "$OTHER3:refs/heads/ctl-s6" >/dev/null 2>&1
contains "5d.b: control: a forced non-fast-forward push reaches the hook and the hook records it" "$(cat "$HOOKLOG")" "refs/heads/ctl-s6 anc=no"
: > "$HOOKLOG"
printf '2\n' > "$GITSHIM_RC"
PATH="$tmp/gitshim:$ORIGPATH"
sp --ledger "$L6" --doc "$B" K2
PATH="$ORIGPATH"
check "5d.b: control: the shim is the git the script ran" "$(PATH="$tmp/gitshim:$ORIGPATH" git ls-remote --exit-code --heads origin x >/dev/null 2>&1; echo $?)" 2
check "5d.b: a pre-check that wrongly says absent ends in a refused push, rc 1" "$rc" 1
contains "5d.b: it names the push" "$out" "git push of series-pub/s6/K2 failed"
check "5d.b: the push was a plain one: no forced update ever reached the pre-receive hook" "$(cat "$HOOKLOG")" ""
rm -f "$tmp/origin.git/hooks/pre-receive"
check "5d.b: origin's branch is still untouched" "$(git -C "$REPO" ls-remote origin refs/heads/series-pub/s6/K2 | cut -f1)" "$OSHA"
check "5d.b: no local publish branch is left" "$(git -C "$REPO" branch --list 'series-pub/s6/*' | wc -l | tr -d ' ')" 0
check "5d.b: the worktree is back on the item branch at wip" "$(git -C "$W2" rev-parse --abbrev-ref HEAD) $(git -C "$W2" rev-parse HEAD)" "series/s6/K2 $K2WIP"
check "5d.b: the ledger is byte-equal" "$(cat "$L6")" "$before"
printf '128\n' > "$GITSHIM_RC"
PATH="$tmp/gitshim:$ORIGPATH"
sp --ledger "$L6" --doc "$B" K2
PATH="$ORIGPATH"
check "5d.c: an unreadable origin (rc 128) fails closed, rc 1" "$rc" 1
contains "5d.c: it names the ls-remote failure" "$out" "git ls-remote origin failed (rc 128)"
check "5d.c: nothing was cherry-picked: no local publish branch" "$(git -C "$REPO" branch --list 'series-pub/s6/*' | wc -l | tr -d ' ')" 0
check "5d.c: the ledger is byte-equal" "$(cat "$L6")" "$before"

# --- 7. the previous item must have merged (or been abandoned) -------------------------------------------------------
L7="$tmp/ledgers/s7.json"
stack s7
W2="$(wtp s7 K2)"
K1WIP="$(jget "$L7" 'd["items"][0]["wip"]')"
PRS7="$tmp/prs7.tsv"
nothing_moved() { # <label> <sid> <ledger-before>
    check "$1: nothing was pushed" "$(git -C "$REPO" ls-remote --heads origin "series-pub/$2/*" | wc -l | tr -d ' ')" 0
    check "$1: the ledger is byte-equal" "$(cat "$tmp/ledgers/$2.json")" "$3"
    check "$1: the worktree is still on the item branch" "$(git -C "$W2" rev-parse --abbrev-ref HEAD)" "series/$2/K2"
    check "$1: no local publish branch is left" "$(git -C "$REPO" branch --list "series-pub/$2/*" | wc -l | tr -d ' ')" 0
}
before="$(cat "$L7")"
: > "$PRS7"
GH_PRS="$PRS7" sp --ledger "$L7" --doc "$B" K2
check "7: K1 committed and never published: K2 refuses rc 2" "$rc" 2
contains "7: the refusal names K1" "$out" "previous item K1"
lacks "7: the refusal is not a conflict" "$out" "PUBLISH-CONFLICT"
nothing_moved "7 no PR recorded" s7 "$before"
sl set --ledger "$L7" --key K1 state=published publish_branch=series-pub/s7/K1 published_head="$K1WIP"
before="$(cat "$L7")"
GH_PRS="$PRS7" sp --ledger "$L7" --doc "$B" K2
check "7: K1 with a publish branch and gh printing nothing: K2 refuses rc 2" "$rc" 2
contains "7: the refusal names K1" "$out" "previous item K1"
nothing_moved "7 gh prints nothing" s7 "$before"
GH_PR_FAIL=1 GH_PRS="$PRS7" sp --ledger "$L7" --doc "$B" K2
check "7: gh erroring fails closed: K2 refuses rc 2" "$rc" 2
contains "7: the refusal names K1" "$out" "previous item K1"
nothing_moved "7 gh errors" s7 "$before"
printf 'series-pub/s7/K1\t11\tOPEN\tmain\n' > "$PRS7"
GH_PRS="$PRS7" sp --ledger "$L7" --doc "$B" K2
check "7: K1's PR open: K2 refuses rc 2" "$rc" 2
contains "7: the refusal names K1 and its state" "$out" "previous item K1"
contains "7: the refusal says the PR is open" "$out" "OPEN"
nothing_moved "7 PR open" s7 "$before"
printf 'series-pub/s7/K1\t11\tCLOSED\tmain\n' > "$PRS7"
GH_PRS="$PRS7" sp --ledger "$L7" --doc "$B" K2
check "7: K1's PR closed unmerged: K2 refuses rc 2" "$rc" 2
contains "7: the refusal names K1" "$out" "previous item K1"
contains "7: the refusal says the PR is closed" "$out" "CLOSED"
nothing_moved "7 PR closed" s7 "$before"
printf 'series-pub/s7/K1\t11\tMERGED\trelease\n' > "$PRS7"
GH_PRS="$PRS7" sp --ledger "$L7" --doc "$B" K2
check "7: K1's PR merged into another branch than the default: K2 refuses rc 2" "$rc" 2
contains "7: the refusal names K1 and the branch it merged into" "$out" "previous item K1 has not merged into main (#11 MERGED into release)"
nothing_moved "7 PR merged elsewhere" s7 "$before"
printf 'series-pub/s7/K1\t11\tMERGED\tmain\n' > "$PRS7"
git -C "$REPO" push -q origin "$K1WIP:refs/heads/main"   # the merge itself: main now holds K1
GH_PRS="$PRS7" sp --ledger "$L7" --doc "$B" K2
check "7: K1's PR merged: K2 publishes rc 0" "$rc" 0
contains "7: it prints PUBLISHED-BRANCH" "$out" "PUBLISHED-BRANCH K2 series-pub/s7/K2"

# --- 8. a cherry-pick that fails with no conflicted file is a failure, not a conflict ---------------------------------
# main already holds K2's second commit (the same file with the same bytes), so that pick is empty: git stops, exit 1, no unmerged file
L8="$tmp/ledgers/s8.json"
stack s8
land_k1 s8
main_move k2-s8.txt 'k2\n' "main already holds K2's file"
W2="$(wtp s8 K2)"
K2WIP="$(jget "$L8" 'd["items"][1]["wip"]')"
before="$(cat "$L8")"
sp --ledger "$L8" --doc "$B" K2
check "8: an empty cherry-pick exits 1" "$rc" 1
contains "8: git's own message is shown" "$out" "now empty"
lacks "8: it is not reported as a conflict" "$out" "PUBLISH-CONFLICT"
nothing_moved "8" s8 "$before"
check "8: the worktree is back on the item branch at wip" "$(git -C "$W2" rev-parse --abbrev-ref HEAD) $(git -C "$W2" rev-parse HEAD)" "series/s8/K2 $K2WIP"
check "8: the worktree is clean" "$(git -C "$W2" status --porcelain)" ""
check "8: no cherry-pick is left in progress" "$([ -e "$(git -C "$W2" rev-parse --git-path CHERRY_PICK_HEAD)" ] && echo yes || echo no)" no
check "8: the worktree is still locked" "$(islocked "$W2" && echo locked || echo free)" locked

# --- 9. a cut that is not an ancestor of wip is refused ---------------------------------------------------------------
L9b="$tmp/ledgers/s9b.json"
stack s9b
W2="$(wtp s9b K2)"
OTHERCUT="$(git -C "$W2" commit-tree -m 'a commit that is not on K2s history' 'HEAD^{tree}')"
sl set --ledger "$L9b" --key K2 cut_from="$OTHERCUT"
before="$(cat "$L9b")"
sp --ledger "$L9b" --doc "$B" K2
check "9: a cut that is not an ancestor of wip refuses rc 2" "$rc" 2
contains "9: the refusal says so" "$out" "not an ancestor"
lacks "9: the refusal is not a conflict" "$out" "PUBLISH-CONFLICT"
nothing_moved "9" s9b "$before"

# --- 10. the empty-range guard: an item with no commits of its own does not publish -----------------------------------
L10="$tmp/ledgers/s10.json"
mk "$L10" "$A" K1 || exit 1
sn start --ledger "$L10" --doc "$A" K1
sl set --ledger "$L10" --key K1 state=committed   # committed with wip == cut: no commits in cut..wip
before="$(cat "$L10")"
sp --ledger "$L10" --doc "$A" K1
check "10: an item with no commits in cut..wip refuses rc 2" "$rc" 2
contains "10: the refusal says there are no commits" "$out" "has no commits in"
check "10: nothing was pushed" "$(git -C "$REPO" ls-remote --heads origin 'series-pub/s10/*' | wc -l | tr -d ' ')" 0
check "10: the ledger is byte-equal" "$(cat "$L10")" "$before"

# --- 11. the local publish-branch guard -------------------------------------------------------------------------------
L11="$tmp/ledgers/s11.json"
stack s11
land_k1 s11
W2="$(wtp s11 K2)"
git -C "$W2" branch -q series-pub/s11/K2 HEAD   # a local publish branch the script did not make; the worktree stays on the item branch
before="$(cat "$L11")"
sp --ledger "$L11" --doc "$B" K2
check "11: an existing local publish branch refuses rc 2" "$rc" 2
contains "11: the refusal names the local branch" "$out" "local branch series-pub/s11/K2 already exists"
check "11: nothing was pushed" "$(git -C "$REPO" ls-remote --heads origin 'series-pub/s11/*' | wc -l | tr -d ' ')" 0
check "11: the ledger is byte-equal" "$(cat "$L11")" "$before"
check "11: the worktree is still on the item branch" "$(git -C "$W2" rev-parse --abbrev-ref HEAD)" series/s11/K2
git -C "$W2" branch -q -D series-pub/s11/K2

# --- 12. a failed fetch is never ignored: main moved from a second clone, so a stale origin/main must not be used -------
L12="$tmp/ledgers/s12.json"
stack s12
land_k1 s12
git -C "$REPO" fetch -q origin   # REPO's origin/main is current here ...
main_move moved-s12.txt 'moved\n' "main moves from the second clone"   # ... and now it is stale, yet K2 would still apply onto it
W2="$(wtp s12 K2)"
before="$(cat "$L12")"
printf '2\n' > "$GITSHIM_RC"   # the shim's ls-remote answers as the real one does (no such branch), so only the fetch can fail
PATH="$tmp/gitshim:$ORIGPATH"
GITSHIM_FETCHFAIL=1 sp --ledger "$L12" --doc "$B" K2
check "12: control: the shim is the git the script ran and its fetch fails" "$(GITSHIM_FETCHFAIL=1 git -C "$REPO" fetch --quiet origin main >/dev/null 2>&1; echo $?)" 128
PATH="$ORIGPATH"
check "12: a failed fetch exits 1" "$rc" 1
contains "12: it names the fetch" "$out" "git fetch origin main failed"
nothing_moved "12" s12 "$before"
sp --ledger "$L12" --doc "$B" K2
check "12: with the fetch working, the publish rc 0" "$rc" 0
git -C "$REPO" fetch -q origin
check "12: the branch carries the commit main gained from the second clone" "$(git -C "$REPO" cat-file -e origin/series-pub/s12/K2:moved-s12.txt 2>/dev/null && echo present || echo absent)" present
check "12: the branch is based on the moved origin/main" "$(git -C "$REPO" merge-base origin/main origin/series-pub/s12/K2)" "$(git -C "$REPO" rev-parse origin/main)"

# --- 12b. origin unreachable: rc 1, nothing moved ---------------------------------------------------------------------
L13="$tmp/ledgers/s13.json"
stack s13
land_k1 s13
W2="$(wtp s13 K2)"
before="$(cat "$L13")"
ORIGURL="$(git -C "$REPO" remote get-url origin)"
git -C "$REPO" remote set-url origin "$tmp/nowhere.git"
sp --ledger "$L13" --doc "$B" K2
git -C "$REPO" remote set-url origin "$ORIGURL"
check "12b: an unreachable origin exits 1" "$rc" 1
nothing_moved "12b" s13 "$before"

# --- 13. the verb runs from any cwd: every git call names the item worktree --------------------------------------------
mkdir -p "$tmp/foreign"
L14="$tmp/ledgers/s14.json"
stack s14
land_k1 s14
W2="$(wtp s14 K2)"
rc=0; out="$( cd "$tmp/foreign" && bash "$SCRIPT" --ledger "$L14" --doc "$B" K2 2>&1 )" || rc=$?
check "13: control: the foreign cwd is not a git repository" "$(git -C "$tmp/foreign" rev-parse --git-dir >/dev/null 2>&1; echo $?)" 128
check "13: a publish run from a foreign cwd rc 0" "$rc" 0
contains "13: it prints PUBLISHED-BRANCH" "$out" "PUBLISHED-BRANCH K2 series-pub/s14/K2"
check "13: the branch is on origin" "$(git -C "$REPO" ls-remote --heads origin series-pub/s14/K2 | wc -l | tr -d ' ')" 1
check "13: gh asked about the previous item from inside the item worktree, not the caller's cwd" "$(tail -n 1 "$GH_CWD_LOG")" "$W2"

# --- 14. the default branch comes from the remote, not from a cached origin/HEAD ---------------------------------------
# origin's HEAD moves to trunk (main plus one commit); REPO's cached refs/remotes/origin/HEAD still says origin/main
L15="$tmp/ledgers/s15.json"
stack s15
git -C "$CL2" fetch -q origin
git -C "$CL2" checkout -q -B trunk origin/main
printf 'trunk\n' > "$CL2/trunk-s15.txt"; git -C "$CL2" add trunk-s15.txt; git -C "$CL2" commit -q -m "trunk moves on"
git -C "$CL2" push -q origin trunk
git --git-dir="$tmp/origin.git" symbolic-ref HEAD refs/heads/trunk
check "14: control: the cached origin/HEAD still says origin/main" "$(git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD)" origin/main
sp --ledger "$L15" --doc "$B" K1
git --git-dir="$tmp/origin.git" symbolic-ref HEAD refs/heads/main
check "14: publishing K1 rc 0" "$rc" 0
git -C "$REPO" fetch -q origin
check "14: the branch is based on origin's default branch (trunk)" "$(git -C "$REPO" merge-base origin/trunk origin/series-pub/s15/K1)" "$(git -C "$REPO" rev-parse origin/trunk)"

# --- 15. smaller fixes ------------------------------------------------------------------------------------------------
# 15a: a worktree path outside <repo>/.claude/worktrees is refused
L16="$tmp/ledgers/s16.json"
stack s16
land_k1 s16
K2WIP="$(jget "$L16" 'd["items"][1]["wip"]')"
git -C "$REPO" worktree add -q -b series/s16/K2x "$tmp/elsewhere" "$K2WIP"
sl set --ledger "$L16" --key K2 branch=series/s16/K2x worktree="$tmp/elsewhere"
before="$(cat "$L16")"
sp --ledger "$L16" --doc "$B" K2
check "15a: a worktree outside the worktrees directory refuses rc 2" "$rc" 2
contains "15a: the refusal says it is outside" "$out" "outside"
check "15a: nothing was pushed" "$(git -C "$REPO" ls-remote --heads origin 'series-pub/s16/*' | wc -l | tr -d ' ')" 0
check "15a: the ledger is byte-equal" "$(cat "$L16")" "$before"
# 15b: a worktree unlock failure shows git's own message
L17="$tmp/ledgers/s17.json"
stack s17
land_k1 s17
W2="$(wtp s17 K2)"
git -C "$REPO" worktree unlock "$W2"   # already unlocked, so the verb's own unlock fails
sp --ledger "$L17" --doc "$B" K2
check "15b: the publish itself still succeeds rc 0" "$rc" 0
contains "15b: it warns that the unlock failed" "$out" "WARN worktree unlock failed"
contains "15b: git's own unlock message is shown" "$out" "not locked"
# 15c: a ledger directory that cannot be written gives a refusal, not a traceback (root ignores directory permissions)
RO2="$tmp/ledgers-ro2"; mkdir -p "$RO2"
mk "$RO2/s18.json" "$A" K1 || exit 1
chmod a-w "$RO2"
if [ -w "$RO2" ]; then
    chmod u+w "$RO2"
    echo "skip - 15c: this user can write to a read-only directory (root); the lock-timeout rows in 5c cover the failed ledger write"
else
    sl set --ledger "$RO2/s18.json" --key K1 state=authoring 2>"$tmp/ro2.err"; rc=$?
    chmod u+w "$RO2"
    check "15c: a read-only ledger directory exits 1" "$rc" 1
    lacks "15c: no traceback" "$(cat "$tmp/ro2.err")" "Traceback"
    contains "15c: a one-line refusal names the ledger" "$(cat "$tmp/ro2.err")" "series-ledger: cannot write"
fi

# --- 6. no PR -------------------------------------------------------------------------------------------------------
contains "6: control: the shim is the gh on PATH and logs what it is given" "$(cat "$GH_LOG")" "--shim-control"
lacks "6: the gh shim saw no pr create" "$(cat "$GH_LOG")" "pr create"
lacks "6: the script never names a PR-opening verb" "$(cat "$SCRIPT" 2>/dev/null)" "gh pr create"

echo
[ "$fails" = 0 ] && { echo "PASS: all rows ok"; exit 0; }
echo "FAIL: $fails row(s) failed"; exit 1
