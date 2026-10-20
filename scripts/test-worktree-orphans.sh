#!/usr/bin/env bash
# Hermetic test for the leftover-worktree invariant: a registered worktree
# that backs no open PR and is not held (git worktree lock, FRESH queue lock,
# live process, RESUME brief, recent git activity) is either reclaimed by
# `worktree.sh prune` or reported by `worktree.sh prune --orphans`.
# Temp git repo + real worktrees + a stub gh whose PR listing honours
# state=open. Pattern follows scripts/test-clean-only.sh.
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SH="$SCRIPT_DIR/worktree.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
expect() {
    local label="$1" out="$2"; shift 2
    if "$@"; then pass "$label"; else fail "$label" "$out"; fi
}
expect_not() {
    local label="$1" out="$2" rc=0; shift 2
    "$@" || rc=$?
    if [ "$rc" -eq 1 ]; then pass "$label"; else fail "$label" "status=$rc: $out"; fi
}
is_dir() { [ -d "$1" ]; }
is_gone() { [ ! -d "$1" ]; }
rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p' | tail -1; }
rc_is() { [ "$(rc_of "$1")" = "$2" ]; }
has_ref() { git -C "$REPO" rev-parse --verify -q "$1" >/dev/null; }
ref_is() { [ "$(git -C "$REPO" rev-parse --verify -q "$1")" = "$2" ]; }

# ── shared setup ─────────────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-wt-orphans.XXXXXX") || exit 1
# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/canon-path.sh"
TMP_ROOT=$(canon_path "$TMP_ROOT") || { echo "setup: canon_path failed" >&2; exit 1; }

REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$REPO" config user.email t@test.com
git -C "$REPO" config user.name t
git -C "$REPO" config maintenance.auto false
printf 'base\n' > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -m main 2>/dev/null || true
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git init -q --bare "$TMP_ROOT/origin.git"
WT_HOME="$REPO/.claude/worktrees"
mkdir -p "$WT_HOME"
HANDOVER_ROOT="$TMP_ROOT/handover-root"
mkdir -p "$HANDOVER_ROOT"

# Stub gh: feat/* = merged PR at its tip, open/* = open PR, anything else has
# no PR. A state=open listing returns the open rows only, like the real API.
STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if grep -q "auth status" <<<"$args"; then exit 0; fi
if grep -q "repo view" <<<"$args"; then echo "owner/repo"; exit 0; fi
if grep -q "api --paginate repos/owner/repo/pulls" <<<"$args"; then
    if ! grep -q "state=open" <<<"$args"; then
        while IFS=' ' read -r branch sha; do
            printf 'owner/repo\t%s\tmerged\t%s\n' "$branch" "$sha"
        done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/feat)
    fi
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\topen\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/open)
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# mk_wt <name> <branch> [commit] — a branch worktree; commit=1 adds one
# commit off main so the tip is not on main.
mk_wt() {
    local name="$1" branch="$2" wt="$WT_HOME/$1"
    git -C "$REPO" worktree add -q "$wt" -b "$branch" >/dev/null 2>&1 || { echo "setup: worktree add $name failed" >&2; exit 1; }
    if [ "${3:-0}" = "1" ]; then
        printf '%s\n' "$name" > "$wt/$name.txt"
        { git -C "$wt" add "$name.txt" && git -C "$wt" commit -q -m "$name"; } || { echo "setup: commit in $name failed" >&2; exit 1; }
    fi
    echo "$wt"
}
# mk_detached <name> [commit] — a detached HEAD worktree; commit=1 leaves a
# commit no ref points at (the shepherd/judge shape after its run).
mk_detached() {
    local name="$1" wt="$WT_HOME/$1"
    git -C "$REPO" worktree add -q --detach "$wt" main >/dev/null 2>&1 || { echo "setup: worktree add $name failed" >&2; exit 1; }
    if [ "${2:-0}" = "1" ]; then
        printf '%s\n' "$name" > "$wt/$name.txt"
        { git -C "$wt" add "$name.txt" && git -C "$wt" commit -q -m "$name"; } || { echo "setup: commit in $name failed" >&2; exit 1; }
    fi
    echo "$wt"
}

# run_wt <args...> — prints combined output then "rc=<n>".
run_wt() {
    (
        export PATH="${RACE_PATH:+$RACE_PATH:}$STUB_DIR:$PATH"
        export FORGE=github
        export HANDOVER_DIR="$HANDOVER_ROOT"
        export WORKTREE_ORPHAN_HOURS="${WORKTREE_ORPHAN_HOURS-0}"
        cd "$REPO" || exit 1
        set +e
        out=$(bash "$WORKTREE_SH" "$@" 2>&1)
        rc=$?
        printf '%s\nrc=%s\n' "$out" "$rc"
    )
}

# ── case 1: prune reclaims a detached tree ───────────────────────────────────
echo "CASE 1: fleet prune reclaims an idle detached tree"
WT_DET=$(mk_detached det-off 1) || exit 1
DET_TIP=$(git -C "$WT_DET" rev-parse HEAD)
WT_DET_MAIN=$(mk_detached det-main) || exit 1
WT_DET_DIRTY=$(mk_detached det-dirty) || exit 1
printf 'changed\n' >> "$WT_DET_DIRTY/README"
WT_DET_IGN=$(mk_detached det-ignored) || exit 1
printf '.env\n' >> "$(git -C "$WT_DET_IGN" rev-parse --git-common-dir)/info/exclude"
printf 'SECRET=1\n' > "$WT_DET_IGN/.env"
WT_MERGED=$(mk_wt merged feat/merged 1) || exit 1
# An unpushed local-only ref is a ticket's only copy: neither its own
# worktree's reclaim nor a detached tree sitting on its tip may drop the ref.
WT_LOCALONLY=$(mk_wt localonly fix/local-only 1) || exit 1
LOCAL_TIP=$(git -C "$WT_LOCALONLY" rev-parse HEAD)
WT_DET_ONLOCAL="$WT_HOME/det-onlocal"
git -C "$REPO" worktree add -q --detach "$WT_DET_ONLOCAL" "$LOCAL_TIP" >/dev/null 2>&1 || { echo "setup: worktree add det-onlocal failed" >&2; exit 1; }
BRANCHES_BEFORE=$(git -C "$REPO" for-each-ref --format='%(refname)' refs/heads | grep -v '^refs/heads/feat/merged$')

out=$(run_wt prune)
expect "1: rc=0" "$out" rc_is "$out" 0
expect "1: detached tree with a commit on no ref reclaimed" "$out" is_gone "$WT_DET"
expect "1: its tip is pinned to wip/detached-<sha12> first" "$out" ref_is "refs/heads/wip/detached-${DET_TIP:0:12}" "$DET_TIP"
expect "1: detached tree already on main reclaimed" "$out" is_gone "$WT_DET_MAIN"
expect_not "1: a tip already on main gets no pin" "$out" has_ref "refs/heads/wip/detached-$(git -C "$REPO" rev-parse main | cut -c1-12)"
expect "1: dirty detached tree kept" "$out" is_dir "$WT_DET_DIRTY"
expect "1: dirty detached file survives" "$out" grepq "$(cat "$WT_DET_DIRTY/README")" changed
expect "1: dirty detached tree checkpointed" "$out" has_ref "refs/checkpoints/det-dirty-autosave"
expect "1: detached tree with ignored user data kept" "$out" is_dir "$WT_DET_IGN"
expect "1: ignored .env still present" "$out" test -f "$WT_DET_IGN/.env"
expect "1: control: merged branch tree still pruned" "$out" is_gone "$WT_MERGED"
BRANCHES_AFTER=$(git -C "$REPO" for-each-ref --format='%(refname)' refs/heads | grep -v '^refs/heads/wip/detached-')
expect "1: no branch ref deleted by a detached reclaim" "$out" test "$BRANCHES_BEFORE" = "$BRANCHES_AFTER"
expect "1: no-PR tree with an unpushed commit reclaimed, its ref kept" "$out" is_gone "$WT_LOCALONLY"
expect "1: unpushed local-only ref still at its tip" "$out" ref_is refs/heads/fix/local-only "$LOCAL_TIP"
expect "1: detached tree on a local-only tip reclaimed" "$out" is_gone "$WT_DET_ONLOCAL"
expect_not "1: a tip a local ref reaches gets no extra pin" "$out" has_ref "refs/heads/wip/detached-${LOCAL_TIP:0:12}"

# ── case 2: the idle gate keeps a fresh detached tree ────────────────────────
echo "CASE 2: idle gate"
WT_FRESH=$(mk_detached det-fresh) || exit 1
out=$(WORKTREE_ORPHAN_HOURS=1 run_wt prune)
expect "2: rc=0" "$out" rc_is "$out" 0
expect "2: freshly used detached tree kept under a 1h gate" "$out" is_dir "$WT_FRESH"

# ── case 3: --only reclaims a named detached tree regardless of age ──────────
echo "CASE 3: --only <detached>"
out=$(WORKTREE_ORPHAN_HOURS=1 run_wt prune --only "$WT_FRESH")
expect "3: rc=0" "$out" rc_is "$out" 0
expect "3: --only reclaimed the detached tree" "$out" is_gone "$WT_FRESH"

# A commit landing after the worktree list was read: the git shim commits in
# the tree at the first git call matching RACE_ON, after the prune's checks.
RACE_DIR="$TMP_ROOT/race-bin"
mkdir -p "$RACE_DIR"
cat > "$RACE_DIR/git" <<'SHIM'
#!/usr/bin/env bash
if [ ! -e "$RACE_DONE" ] && [[ " $* " == *" $RACE_ON "* ]]; then
    : > "$RACE_DONE"
    "$REAL_GIT" -C "$RACE_WT" commit -q --allow-empty -m race >/dev/null 2>&1
fi
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$RACE_DIR/git"
WT_RACE=$(mk_detached det-race) || exit 1
out=$(RACE_ON="for-each-ref --contains" REAL_GIT="$(command -v git)" RACE_WT="$WT_RACE" RACE_DONE="$TMP_ROOT/race-done" RACE_PATH="$RACE_DIR" run_wt prune --only "$WT_RACE")
RACE_TIP=$(git -C "$WT_RACE" rev-parse HEAD 2>/dev/null || true)
expect "3: the race fired" "$out" test -e "$TMP_ROOT/race-done"
expect "3: a detached tree whose HEAD moved during the prune is kept" "$out" is_dir "$WT_RACE"
expect "3: its new commit is still checked out" "$out" test "$(git -C "$WT_RACE" log -1 --format=%s 2>/dev/null)" = race
expect "3: the moved tree is reported" "$out" grepq "$out" "moved during prune"
[ -z "$RACE_TIP" ] || git -C "$REPO" worktree remove --force "$WT_RACE" >/dev/null 2>&1
# The same race on a merged branch tree: branch -D would take the new commit.
WT_BRACE=$(mk_wt brace feat/brace 1) || exit 1
out=$(RACE_ON="status --porcelain --untracked-files=no" REAL_GIT="$(command -v git)" RACE_WT="$WT_BRACE" RACE_DONE="$TMP_ROOT/brace-done" RACE_PATH="$RACE_DIR" run_wt prune --only "$WT_BRACE")
expect "3: the branch race fired" "$out" test -e "$TMP_ROOT/brace-done"
expect "3: a merged tree whose branch moved during the prune is kept" "$out" is_dir "$WT_BRACE"
expect "3: its branch still holds the new commit" "$out" test "$(git -C "$REPO" log -1 --format=%s feat/brace 2>/dev/null)" = race
expect "3: the moved branch is reported" "$out" grepq "$out" "feat/brace moved during prune"
git -C "$REPO" worktree remove --force "$WT_BRACE" >/dev/null 2>&1

# ── case 4: --orphans flags every unheld leftover ────────────────────────────
echo "CASE 4: prune --orphans"
WT_NOPR=$(mk_wt nopr fix/no-pr 1) || exit 1
WT_MDIRTY=$(mk_wt mdirty feat/mdirty 1) || exit 1
printf 'changed\n' >> "$WT_MDIRTY/README"
WT_OPEN=$(mk_wt openpr open/live 1) || exit 1
WT_LOCKED=$(mk_wt locked fix/locked 1) || exit 1
git -C "$REPO" worktree lock "$WT_LOCKED" >/dev/null 2>&1
WT_RESUME=$(mk_wt resumed fix/resumed 1) || exit 1
printf -- '---\nresume_cwd: %s\n---\n\n# resume\n' "$WT_RESUME" > "$HANDOVER_ROOT/HIMMEL-1-N1b-x-RESUME.md"
WT_OLDRESUME=$(mk_wt oldresume fix/old-resume 1) || exit 1
printf -- '---\nresume_cwd: %s\n---\n' "$WT_OLDRESUME" > "$HANDOVER_ROOT/HIMMEL-2-N2b-x-RESUME.md"
old_ts=$(date -d '30 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-30d +%Y%m%d%H%M) || { echo "setup: no date form for 30 days ago" >&2; exit 1; }
touch -t "$old_ts" "$HANDOVER_ROOT/HIMMEL-2-N2b-x-RESUME.md" || { echo "setup: touch -t failed" >&2; exit 1; }

out=$(run_wt prune --orphans)
expect "4: rc=1 on an orphan" "$out" rc_is "$out" 1
expect "4: no-PR branch tree flagged" "$out" grepq "$out" -F "ORPHAN $WT_NOPR branch=fix/no-pr"
expect "4: merged dirty tree flagged with its dirt count" "$out" grepq "$out" -E "ORPHAN $WT_MDIRTY branch=feat/mdirty dirty=1 "
expect "4: dirty detached tree flagged" "$out" grepq "$out" -E "ORPHAN $WT_DET_DIRTY branch=detached:[0-9a-f]{12} dirty=1 "
expect "4: a RESUME brief older than the hold flags again" "$out" grepq "$out" -F "ORPHAN $WT_OLDRESUME "
expect_not "4: open-PR tree not flagged" "$out" grepq "$out" -F "ORPHAN $WT_OPEN "
expect_not "4: locked tree not flagged" "$out" grepq "$out" -F "ORPHAN $WT_LOCKED "
expect_not "4: RESUME-held tree not flagged" "$out" grepq "$out" -F "ORPHAN $WT_RESUME "
expect_not "4: primary never flagged" "$out" grepq "$out" -F "ORPHAN $REPO "
expect "4: read-only: flagged trees untouched" "$out" is_dir "$WT_NOPR"
expect "4: read-only: merged dirty tree untouched" "$out" is_dir "$WT_MDIRTY"

out=$(WORKTREE_ORPHAN_HOURS=1 run_wt prune --orphans)
expect "4b: a tree touched within the idle window is held" "$out" rc_is "$out" 0

# ── case 5: ceiling alarm well below the hard ceiling ────────────────────────
echo "CASE 5: ceiling alarm"
out=$(HIMMEL_WORKTREE_ALARM=2 WORKTREE_ORPHAN_HOURS=1 run_wt prune --orphans)
expect "5: rc=1 at the alarm" "$out" rc_is "$out" 1
expect "5: CEILING line names live/ceiling" "$out" grepq "$out" -E "^CEILING [0-9]+/100 worktrees \(alarm at 2\)"
out=$(HIMMEL_WORKTREE_ALARM=99 WORKTREE_ORPHAN_HOURS=1 run_wt prune --orphans)
expect_not "5: no CEILING line under the alarm" "$out" grepq "$out" "^CEILING"

# ── case 6: flag hygiene ─────────────────────────────────────────────────────
echo "CASE 6: --orphans takes no other flag"
out=$(run_wt prune --orphans --dry-run)
expect "6: --orphans --dry-run refused" "$out" rc_is "$out" 1
expect "6: refusal names --orphans" "$out" grepq "$out" -- "--orphans"

# ── case 7: prune reclaims a clean parked branch tree, never its branch ─────
echo "CASE 7: fleet prune reclaims an idle clean branch tree with no open PR"
git -C "$REPO" push -q origin main >/dev/null 2>&1 || { echo "setup: push main failed" >&2; exit 1; }
WT_PARK=$(mk_wt park fix/park 1) || exit 1
WT_PARK_MAIN=$(mk_wt parkmain fix/park-main) || exit 1
WT_PARK_DIRTY=$(mk_wt parkdirty fix/park-dirty 1) || exit 1
printf 'wip\n' > "$WT_PARK_DIRTY/untracked.txt"
WT_PARK_MOD=$(mk_wt parkmod fix/park-mod 1) || exit 1
printf 'changed\n' >> "$WT_PARK_MOD/README"
WT_PARK_DOC=$(mk_wt parkdoc fix/park-doc 1) || exit 1
WT_PARK_DOC2=$(mk_wt parkdoc2 fix/park-doc-2 1) || exit 1
printf -- '---\nresume_cwd: %s/elsewhere\n---\n\nbranch fix/park-doc\n' "$TMP_ROOT" > "$HANDOVER_ROOT/leg-live.md"
HANDOVER_DIR="$HANDOVER_ROOT" bash "$SCRIPT_DIR/handover/queue-lock.sh" acquire "$HANDOVER_ROOT/leg-live.md" "orphans-test-$$" >/dev/null 2>&1 \
    || { echo "setup: queue-lock acquire failed" >&2; exit 1; }
PARK_TIP=$(git -C "$REPO" rev-parse fix/park)
out=$(WORKTREE_ORPHAN_HOURS=1 run_wt prune)
expect "7: rc=0 under a 1h gate" "$out" rc_is "$out" 0
expect "7: a parked tree touched within the idle window is kept" "$out" is_dir "$WT_PARK"
out=$(run_wt prune --dry-run)
expect "7: dry-run names the parked tree" "$out" grepq "$out" -F "would reclaim parked fix/park"
expect "7: dry-run removes nothing" "$out" is_dir "$WT_PARK"
out=$(run_wt prune)
expect "7: rc=0" "$out" rc_is "$out" 0
expect "7: clean parked tree with a local-only commit reclaimed" "$out" is_gone "$WT_PARK"
expect "7: its branch still holds the commit" "$out" ref_is fix/park "$PARK_TIP"
expect "7: clean parked tree with no commit reclaimed" "$out" is_gone "$WT_PARK_MAIN"
expect "7: its branch ref is kept" "$out" has_ref fix/park-main
expect "7: a parked tree with an untracked file is kept" "$out" is_dir "$WT_PARK_DIRTY"
expect "7: a parked tree with a tracked change is kept" "$out" is_dir "$WT_PARK_MOD"
expect "7: the open-PR tree is kept" "$out" is_dir "$WT_OPEN"
expect "7: the locked tree is kept" "$out" is_dir "$WT_LOCKED"
expect "7: the RESUME-held tree is kept" "$out" is_dir "$WT_RESUME"
expect "7: the reclaim names the kept branch and its unpushed commits" "$out" grepq "$out" -F "branch fix/park kept (1 unpushed commit(s))"
expect "7: a no-commit branch reports 0 unpushed" "$out" grepq "$out" -F "branch fix/park-main kept (0 unpushed commit(s))"
expect "7: a tree whose branch a live leg doc names is kept" "$out" is_dir "$WT_PARK_DOC"
expect "7: a branch that only shares the doc's branch prefix is reclaimed" "$out" is_gone "$WT_PARK_DOC2"
HANDOVER_DIR="$HANDOVER_ROOT" bash "$SCRIPT_DIR/handover/queue-lock.sh" release "$HANDOVER_ROOT/leg-live.md" >/dev/null 2>&1 || true

# a lock doc that cannot be read leaves "no live leg names this branch" unproven
WT_PARK_UNREAD=$(mk_wt parkunread fix/park-unread 1) || exit 1
printf -- '---\nresume_cwd: %s/elsewhere\n---\n\nbranch fix/other\n' "$TMP_ROOT" > "$HANDOVER_ROOT/leg-unread.md"
HANDOVER_DIR="$HANDOVER_ROOT" bash "$SCRIPT_DIR/handover/queue-lock.sh" acquire "$HANDOVER_ROOT/leg-unread.md" "orphans-test-unread-$$" >/dev/null 2>&1 \
    || { echo "setup: queue-lock acquire failed" >&2; exit 1; }
chmod 000 "$HANDOVER_ROOT/leg-unread.md"
out=$(run_wt prune)
chmod 600 "$HANDOVER_ROOT/leg-unread.md"
expect "7: a parked tree is kept when a live lock doc cannot be read" "$out" is_dir "$WT_PARK_UNREAD"
HANDOVER_DIR="$HANDOVER_ROOT" bash "$SCRIPT_DIR/handover/queue-lock.sh" release "$HANDOVER_ROOT/leg-unread.md" >/dev/null 2>&1 || true

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
