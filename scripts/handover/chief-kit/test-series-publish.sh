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
#   6. no PR     -> the gh shim (on PATH, with a positive control) saw no `pr create`; a published item cannot publish twice
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

git init -q --bare "$tmp/origin.git"
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

# gh shim: records every call; nothing in the publish verb may reach `pr create`
mkdir -p "$tmp/bin"
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
cat > "$tmp/bin/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in *"auth status"*) exit 0 ;; *"repo view"*) echo owner/repo; exit 0 ;; esac
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
land_k1() { # <sid>: k merged, main now holds K1 up to its recorded wip
    git -C "$REPO" push -q origin "$(git -C "$(wtp "$1" K1)" rev-parse HEAD):refs/heads/main"
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
check "5: F10 K1's file is not on the pushed branch" "$(git -C "$REPO" ls-tree --name-only origin/series-pub/s3/K2 | grep -c 'k1-s3' || true)" 0

# --- 5b. a failed push moves nothing, and the retry works ------------------------------------------------------------
L4="$tmp/ledgers/s4.json"
stack s4
land_k1 s4
W2="$(wtp s4 K2)"
K2WIP="$(jget "$L4" 'd["items"][1]["wip"]')"
before="$(cat "$L4")"
printf '#!/bin/sh\nexit 1\n' > "$tmp/origin.git/hooks/pre-receive"; chmod +x "$tmp/origin.git/hooks/pre-receive"
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
land_k1 s5
W2="$(wtp s5 K2)"
K2WIP="$(jget "$L5" 'd["items"][1]["wip"]')"
chmod a-w "$RO"   # the ledger cannot be replaced: series-ledger.py set fails after the push
sp --ledger "$L5" --doc "$B" K2
chmod u+w "$RO"
PUBHEAD="$(git -C "$W2" rev-parse HEAD)"
printf -v SETLINE 'python3 -I %q set --ledger %q --key K2 publish_branch=series-pub/s5/K2 published_head=%s state=published' "$LEDGER_PY" "$L5" "$PUBHEAD"
check "5c: a failed ledger write exits 1" "$rc" 1
check "5c: the branch was pushed" "$(git -C "$REPO" ls-remote --heads origin series-pub/s5/K2 | wc -l | tr -d ' ')" 1
check "5c: the ledger still says committed at wip" "$(jget "$L5" 'd["items"][1]["state"]') $(jget "$L5" 'd["items"][1]["wip"]')" "committed $K2WIP"
contains "5c: the exact ledger line is printed" "$out" "$SETLINE"
contains "5c: the exact unlock line is printed" "$out" "git -C $W2 worktree unlock $W2"
contains "5c: it warns against series-next.sh commit" "$out" "do NOT run series-next.sh commit"
sp --ledger "$L5" --doc "$B" K2
check "5c: a second publish from the publish branch refuses rc 2" "$rc" 2
contains "5c: the branch refusal prints the same ledger line" "$out" "$SETLINE"
contains "5c: the branch refusal prints the same unlock line" "$out" "git -C $W2 worktree unlock $W2"
eval "$SETLINE" && git -C "$W2" worktree unlock "$W2"
check "5c: following the printed lines publishes the item" "$(jget "$L5" 'd["items"][1]["state"]') $(jget "$L5" 'd["items"][1]["published_head"]')" "published $PUBHEAD"
check "5c: following the printed lines unlocks the worktree" "$(islocked "$W2" && echo locked || echo free)" free

# --- 6. no PR -------------------------------------------------------------------------------------------------------
contains "6: control: the shim is the gh on PATH and logs what it is given" "$(cat "$GH_LOG")" "--shim-control"
lacks "6: the gh shim saw no pr create" "$(cat "$GH_LOG")" "pr create"
lacks "6: the script never names a PR-opening verb" "$(cat "$SCRIPT" 2>/dev/null)" "gh pr create"

echo
[ "$fails" = 0 ] && { echo "PASS: all rows ok"; exit 0; }
echo "FAIL: $fails row(s) failed"; exit 1
