#!/usr/bin/env bash
# Hermetic test for `clean-garden.sh --only <worktree-path|branch>`:
# prune exactly ONE worktree, so a chief wrapping one worker cannot reach across
# a fleet-wide sweep and remove another live worker's cwd. Temp git repo + real
# worktrees + a stub gh that reports every feat/* branch as merged at its tip.
# Pattern follows scripts/test-clean-prune-strays.sh.
set -uo pipefail

# grepq <text> [grep-args...] — `grep -q` against <text> with NO pipeline
#  (pipefail + early-exit grep = false negatives).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/worktree.sh"
CLEAN_SH="$SCRIPT_DIR/clean.sh"

PASS=0
FAIL=0
TMP_ROOT=""
HOLDER_PID=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null || true; fi
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
# expect <label> <output> <command...> — pass when the command succeeds.
expect() {
    local label="$1" out="$2"; shift 2
    if "$@"; then pass "$label"; else fail "$label" "$out"; fi
}
# expect_not <label> <output> <command...> — pass when the command reports
# absence (status 1); any other non-zero status is an execution error, a fail.
expect_not() {
    local label="$1" out="$2" rc=0; shift 2
    "$@" || rc=$?
    if [ "$rc" -eq 1 ]; then pass "$label"; else fail "$label" "status=$rc: $out"; fi
}
is_dir() { [ -d "$1" ]; }
is_gone() { [ ! -d "$1" ]; }
rc_is() { [ "$(rc_of "$1")" = "$2" ]; }
rc_nonzero() { [ "$(rc_of "$1")" != "0" ]; }
has_branch() { git -C "$REPO" rev-parse --verify -q "refs/heads/$1" >/dev/null; }

# ── shared setup ─────────────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-clean-only.XXXXXX")
# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/canon-path.sh"
CANON_ROOT=$(canon_path "$TMP_ROOT") || { echo "setup: canon_path failed" >&2; exit 1; }
TMP_ROOT="$CANON_ROOT"
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

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
# A real local bare repo as origin (not a fake https URL) so the
# only-allow-unmerged "head is on the remote" check can do a
# genuine `git ls-remote origin` — gh (stubbed below) still answers the PR
# cache/NWO lookups, independent of this URL.
ORIGIN_BARE="$TMP_ROOT_UNIX/origin.git"
git init -q --bare "$ORIGIN_BARE"
git -C "$REPO" remote add origin "$ORIGIN_BARE"

# Stub gh: every feat/* branch is a merged PR at its current tip; open/* and
# closed/* branches get a PR row in that state; any
# other branch has no PR row at all ("none").
STUB_DIR="$TMP_ROOT_UNIX/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if grep -q "auth status" <<<"$args"; then exit 0; fi
if grep -q "repo view" <<<"$args"; then echo "owner/repo"; exit 0; fi
if grep -q "api --paginate repos/owner/repo/pulls" <<<"$args"; then
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\tmerged\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/feat)
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\topen\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/open)
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\tclosed\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/closed)
    exit 0
fi
if grep -q -- <<<"$args" "--state merged"; then echo "1"; exit 0; fi
if grep -q -- <<<"$args" "--state open"; then exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# A second stub whose PR-cache fetch fails outright (models an
# unresolvable PR_STATE — gh/cache failure — which must stay fail-closed
# even under --only-allow-unmerged).
STUB_DIR_FAIL="$TMP_ROOT_UNIX/bin-fail"
mkdir -p "$STUB_DIR_FAIL"
cat > "$STUB_DIR_FAIL/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if grep -q "auth status" <<<"$args"; then exit 0; fi  # pipefail-ok: $args is a small captured argv
if grep -q "repo view" <<<"$args"; then echo "owner/repo"; exit 0; fi  # pipefail-ok: same $args
if grep -q "api --paginate repos/owner/repo/pulls" <<<"$args"; then  # pipefail-ok: same $args
    exit 1
fi
exit 0
STUB
chmod +x "$STUB_DIR_FAIL/gh"

mk_wt() {
    local name="$1" branch="$2"
    git -C "$REPO" worktree add -q "$TMP_ROOT/$name" -b "$branch" >/dev/null 2>&1
    echo "$TMP_ROOT/$name"
}

# run_clean <script> <args...> — runs from inside the fixture repo; prints
# combined output then a final "rc=<n>" line. Honors RUN_CLEAN_STUB_DIR to
# swap in the failing-gh stub for one call.
run_clean() {
    local script="$1"; shift
    (
        cd "${RUN_CLEAN_REPO:-$REPO}" || exit 1
        set +e
        out=$(PATH="${RUN_CLEAN_STUB_DIR:-$STUB_DIR}:${PATH}" FORGE=github bash "$script" "$@" 2>&1)
        rc=$?
        printf '%s\nrc=%s\n' "$out" "$rc"
    )
}
rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p' | tail -1; }

WT_A=$(mk_wt wt-a feat/a)          # the --only target (path form)
WT_B=$(mk_wt wt-b feat/b)          # merged sibling — must SURVIVE an --only run
WT_C=$(mk_wt wt-c feat/c)          # --only target (branch form)
WT_D=$(mk_wt wt-d feat/d)          # merged sibling — must survive
WT_OPEN=$(mk_wt wt-open wip/open)  # no merged PR — --only must refuse
WT_DIRTY=$(mk_wt wt-dirty feat/dirty)
printf 'changed\n' >> "$WT_DIRTY/README"   # tracked change — --only must refuse
WT_HELD=$(mk_wt wt-held feat/held) # a live process's cwd — --only must refuse
WT_DRY=$(mk_wt wt-dry feat/dry)

# ── case 1: --only <path> prunes that worktree ONLY ──────────────────────────
echo "CASE 1: --only <path>"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_A")
expect "1: rc=0" "$out" rc_is "$out" 0
expect "1: target worktree pruned" "$out" is_gone "$WT_A"
# RED core: a fleet-wide sweep would have taken every merged sibling.
expect "1: merged sibling wt-b survived" "$out" is_dir "$WT_B"
expect "1: merged sibling wt-d survived" "$out" is_dir "$WT_D"
expect "1: merged sibling wt-held survived" "$out" is_dir "$WT_HELD"
expect "1: sibling branch feat/b kept" "$out" has_branch feat/b
expect_not "1: target branch feat/a deleted with its worktree" "$out" has_branch feat/a

# ── case 2: --only <branch> ──────────────────────────────────────────────────
echo "CASE 2: --only <branch>"
out=$(run_clean "$CLEAN_GARDEN" prune --only feat/c)
expect "2: rc=0" "$out" rc_is "$out" 0
expect "2: target worktree pruned by branch name" "$out" is_gone "$WT_C"
expect "2: siblings survived" "$out" is_dir "$WT_B"

# ── case 3: refuses a non-candidate, non-zero, worktree kept ─────────────────
echo "CASE 3: refusals"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_OPEN")
expect "3a: un-merged target refused non-zero" "$out" rc_nonzero "$out"
expect "3a: un-merged target kept" "$out" is_dir "$WT_OPEN"
expect "3a: message names the refusal" "$out" grepq "$out" "not a prune candidate"

out=$(run_clean "$CLEAN_GARDEN" prune --only feat/dirty)
expect "3b: dirty target refused non-zero" "$out" rc_nonzero "$out"
expect "3b: dirty target kept" "$out" is_dir "$WT_DIRTY"
expect "3b: dirty check still fires under --only" "$out" grepq "$out" "uncommitted changes"

out=$(run_clean "$CLEAN_GARDEN" prune --only "$REPO")
expect "3c: primary refused non-zero" "$out" rc_nonzero "$out"
expect "3c: primary untouched" "$out" is_dir "$REPO/.git"

out=$(run_clean "$CLEAN_GARDEN" prune --only feat/no-such-branch)
expect "3d: unknown target refused non-zero" "$out" rc_nonzero "$out"
expect "3d: message names the refusal" "$out" grepq "$out" "not a registered worktree"

# ── case 4: a live process's cwd still blocks --only (worktree_in_use) ───────
echo "CASE 4: live cwd holder"
# PLATFORM GUARD: worktree-inuse detects a live cwd holder by scanning /proc; hosts
# without it (macOS) fall back to a rename probe that cannot see a holder
# so the refusal cannot be provoked there and is skipped.
if [ -d /proc/self ]; then
( cd "$WT_HELD" && exec sleep 60 ) &
HOLDER_PID=$!
sleep 0.3
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_HELD")
expect "4: live-cwd target refused non-zero" "$out" rc_nonzero "$out"
expect "4: live-cwd target kept" "$out" is_dir "$WT_HELD"
expect "4: message says in use" "$out" grepq "$out" "in use"
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
else
echo "  SKIP: 4: no /proc on this platform, live-cwd holder cannot be detected"
fi
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_HELD")
expect "4 control: same target with no holder is pruned" "$out" is_gone "$WT_HELD"

# ── case 5: --dry-run under --only mutates nothing ───────────────────────────
echo "CASE 5: --only --dry-run"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_DRY" --dry-run)
expect "5: rc=0" "$out" rc_is "$out" 0
expect "5: dry-run names the target" "$out" grepq "$out" "would prune feat/dry"
expect_not "5: dry-run plans no sibling" "$out" grepq "$out" "would prune feat/b"
expect "5: dry-run removed nothing" "$out" is_dir "$WT_DRY"

# ── case 6: flag hygiene ─────────────────────────────────────────────────────
echo "CASE 6: flag hygiene"
out=$(run_clean "$CLEAN_GARDEN" prune --only)
expect "6a: --only with no value refused" "$out" rc_nonzero "$out"
expect "6a: usage error names the flag" "$out" grepq "$out" -e "--only needs"
out=$(run_clean "$CLEAN_GARDEN" prune feat/newone --only feat/b)
expect "6b: --only with a create branch refused" "$out" rc_nonzero "$out"
expect "6b: nothing pruned" "$out" is_dir "$WT_B"
out=$(run_clean "$CLEAN_GARDEN" prune --only feat/b --no-prune)
expect "6c: --only with --no-prune refused" "$out" rc_nonzero "$out"
expect "6c: nothing pruned" "$out" is_dir "$WT_B"

# ── case 7: clean.sh forwards --only ─────────────────────────────────────────
echo "CASE 7: clean.sh passthrough"
out=$(run_clean "$CLEAN_SH" --only feat/d)
expect "7: rc=0" "$out" rc_is "$out" 0
expect "7: clean.sh --only pruned the target" "$out" is_gone "$WT_D"
expect "7: sibling feat/b survived" "$out" is_dir "$WT_B"

# ── case 8: an ambiguous target (path of one worktree, branch of another) ────
echo "CASE 8: ambiguous target"
mkdir -p "$REPO/feat"
git -C "$REPO" worktree add -q "$REPO/feat/amb" -b feat/amb-holder >/dev/null 2>&1
WT_AMB_BR=$(mk_wt wt-amb-br feat/amb)   # branch feat/amb; the other one's PATH is repo/feat/amb
out=$(run_clean "$CLEAN_GARDEN" prune --only feat/amb)
expect "8: ambiguous target refused non-zero" "$out" rc_nonzero "$out"
expect "8: message names the ambiguity" "$out" grepq "$out" "matches 2 worktrees"
expect "8: path-matched worktree kept" "$out" is_dir "$REPO/feat/amb"
expect "8: branch-matched worktree kept" "$out" is_dir "$WT_AMB_BR"

# ── case 9: --only-allow-unmerged ──────────────────────────────
echo "CASE 9: --only-allow-unmerged"

WT_UA_NONE=$(mk_wt wt-ua-none none/case)
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_NONE")
expect "9a control: no-PR branch refused WITHOUT the flag" "$out" rc_nonzero "$out"
expect "9a control: kept" "$out" is_dir "$WT_UA_NONE"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_NONE" --only-allow-unmerged)
expect "9a: no-PR branch, clean, zero-ahead pruned WITH the flag" "$out" is_gone "$WT_UA_NONE"

WT_UA_CLOSED=$(mk_wt wt-ua-closed closed/case)
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_CLOSED" --only-allow-unmerged)
expect "9b: closed-unmerged PR, clean, zero-ahead pruned WITH the flag" "$out" is_gone "$WT_UA_CLOSED"

WT_UA_OPEN=$(mk_wt wt-ua-open open/case)
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_OPEN" --only-allow-unmerged)
expect "9c: OPEN PR still refused even WITH the flag" "$out" rc_nonzero "$out"
expect "9c: open-PR worktree kept" "$out" is_dir "$WT_UA_OPEN"

WT_UA_DIRTY=$(mk_wt wt-ua-dirty none/dirty)
printf 'changed\n' >> "$WT_UA_DIRTY/README"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_DIRTY" --only-allow-unmerged)
expect "9d: dirty tree still refused WITH the flag" "$out" rc_nonzero "$out"
expect "9d: dirty worktree kept" "$out" is_dir "$WT_UA_DIRTY"

WT_UA_PUSHED=$(mk_wt wt-ua-pushed none/pushed)
printf 'extra\n' > "$WT_UA_PUSHED/extra.txt"
git -C "$WT_UA_PUSHED" add extra.txt
git -C "$WT_UA_PUSHED" commit -q -m "extra commit ahead of main"
git -C "$REPO" push -q origin "none/pushed:refs/heads/none/pushed"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_PUSHED" --only-allow-unmerged)
expect "9e: ahead-of-main but head pushed to origin pruned WITH the flag" "$out" is_gone "$WT_UA_PUSHED"

# 9g: a never-merged branch's worker scratch may be its only copy,
# so the root-scratch arms do NOT apply under --only-allow-unmerged; only tool
# churn (package-lock.json) stays discardable.
WT_UA_SCRATCH=$(mk_wt wt-ua-scratch none/scratch)
printf 'x\n' > "$WT_UA_SCRATCH/.pr-body.txt"
mkdir -p "$WT_UA_SCRATCH/.scratch"; printf 'x\n' > "$WT_UA_SCRATCH/.scratch/a.txt"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_SCRATCH" --only-allow-unmerged)
expect "9g: unmerged branch with root scratch refused WITH the flag" "$out" rc_nonzero "$out"
expect "9g: unmerged scratch worktree kept" "$out" is_dir "$WT_UA_SCRATCH"
WT_UA_CHURN=$(mk_wt wt-ua-churn none/churn)
printf 'lock\n' > "$WT_UA_CHURN/package-lock.json"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_CHURN" --only-allow-unmerged)
expect "9g control: tool churn alone still pruned WITH the flag" "$out" is_gone "$WT_UA_CHURN"

# 9g2: the REAL repo .gitignore must not hide
# .himmel-scratch/ from the stray scan, or `git worktree remove` would delete a
# never-merged branch's only scratch. Branch pushed so the ahead check passes.
WT_UA_REAL=$(mk_wt wt-ua-real none/realignore)
cp "$SCRIPT_DIR/../.gitignore" "$WT_UA_REAL/.gitignore"
git -C "$WT_UA_REAL" add .gitignore
git -C "$WT_UA_REAL" commit -q -m "carry the real repo .gitignore"
git -C "$REPO" push -q origin "none/realignore:refs/heads/none/realignore"
mkdir -p "$WT_UA_REAL/.himmel-scratch"; printf 'x\n' > "$WT_UA_REAL/.himmel-scratch/notes.md"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_REAL" --only-allow-unmerged)
expect "9g2: .himmel-scratch/notes.md under the REAL .gitignore refused WITH the flag" "$out" rc_is "$out" 1
expect "9g2: worktree with .himmel-scratch kept" "$out" is_dir "$WT_UA_REAL"

WT_UA_NOTPUSHED=$(mk_wt wt-ua-notpushed none/notpushed)
printf 'extra\n' > "$WT_UA_NOTPUSHED/extra.txt"
git -C "$WT_UA_NOTPUSHED" add extra.txt
git -C "$WT_UA_NOTPUSHED" commit -q -m "extra commit, never pushed"
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_NOTPUSHED" --only-allow-unmerged)
expect "9f: ahead-of-main and NOT on origin refused WITH the flag" "$out" rc_nonzero "$out"
expect "9f: unpushed-ahead worktree kept" "$out" is_dir "$WT_UA_NOTPUSHED"

WT_UA_UNKNOWN=$(mk_wt wt-ua-unknown none/unknown)
out=$(RUN_CLEAN_STUB_DIR="$STUB_DIR_FAIL" run_clean "$CLEAN_GARDEN" prune --only "$WT_UA_UNKNOWN" --only-allow-unmerged)
expect "9g: unresolvable PR state (gh/cache failure) refused WITH the flag" "$out" rc_nonzero "$out"
expect "9g: unknown-state worktree kept" "$out" is_dir "$WT_UA_UNKNOWN"

out=$(run_clean "$CLEAN_GARDEN" prune --only-allow-unmerged)
expect "9h: --only-allow-unmerged with no --only refused" "$out" rc_nonzero "$out"
expect "9h: usage error names the flag" "$out" grepq "$out" -e "--only-allow-unmerged requires --only"

echo "CASE 10: repo-name case and an unreadable repo name"
STUB_DIR_CASE="$TMP_ROOT_UNIX/bin-case"
mkdir -p "$STUB_DIR_CASE"
cat > "$STUB_DIR_CASE/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if grep -q "auth status" <<<"$args"; then exit 0; fi
if grep -q "repo view" <<<"$args"; then
    case "${GH_VIEW:-fail}" in
        lower) echo "owner/repo"; exit 0 ;;
        canon) echo "Owner/Repo"; exit 0 ;;
        *) exit 1 ;;
    esac
fi
if grep -qi "api --paginate repos/owner/repo/pulls" <<<"$args"; then
    row_repo="Owner/Repo"
    [ "${GH_VIEW:-fail}" = fail ] && row_repo="Renamed/Repo"
    for kind in feat:merged open:open closed:closed; do
        while IFS=' ' read -r branch sha; do
            printf '%s\t%s\t%s\t%s\n' "$row_repo" "$branch" "${kind#*:}" "$sha"
        done < <(git for-each-ref --format='%(refname:short) %(objectname)' "refs/heads/${kind%%:*}")
    done
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR_CASE/gh"

REPO2="$TMP_ROOT/repo-case"
git clone -q "$REPO" "$REPO2" >/dev/null 2>&1
git -C "$REPO2" config user.email t@test.com
git -C "$REPO2" config user.name t
git -C "$REPO2" config maintenance.auto false
git -C "$REPO2" remote set-url origin git@github.com:owner/repo.git
mk_wt2() {
    git -C "$REPO2" worktree add -q "$TMP_ROOT/$1" -b "$2" >/dev/null 2>&1
    echo "$TMP_ROOT/$1"
}
run_case() {
    local view="$1"; shift
    GH_VIEW="$view" GIT_SSH_COMMAND=false GIT_TERMINAL_PROMPT=0 \
        RUN_CLEAN_STUB_DIR="$STUB_DIR_CASE" RUN_CLEAN_REPO="$REPO2" run_clean "$@"
}

WT_C_OPEN=$(mk_wt2 wt-case-open open/unreadable)
out=$(run_case fail "$CLEAN_GARDEN" prune --only "$WT_C_OPEN" --only-allow-unmerged)
expect "10a: unreadable repo name, open PR: refused" "$out" rc_nonzero "$out"
expect "10a: unreadable repo name, open PR: worktree kept" "$out" is_dir "$WT_C_OPEN"

WT_C_OPEN2=$(mk_wt2 wt-case-open2 open/lowercase)
out=$(run_case lower "$CLEAN_GARDEN" prune --only "$WT_C_OPEN2" --only-allow-unmerged)
expect "10b: lowercase repo name, open PR: refused" "$out" rc_nonzero "$out"
expect "10b: lowercase repo name, open PR: worktree kept" "$out" is_dir "$WT_C_OPEN2"

WT_C_CLOSED=$(mk_wt2 wt-case-closed closed/lowercase)
out=$(run_case lower "$CLEAN_GARDEN" prune --only "$WT_C_CLOSED" --only-allow-unmerged)
expect "10c: lowercase repo name, closed PR: pruned" "$out" is_gone "$WT_C_CLOSED"
WT_C_MERGED=$(mk_wt2 wt-case-merged feat/lowercase)
out=$(run_case lower "$CLEAN_GARDEN" prune --only "$WT_C_MERGED")
expect "10c: lowercase repo name, merged PR: pruned" "$out" is_gone "$WT_C_MERGED"
WT_C_MERGED2=$(mk_wt2 wt-case-merged2 feat/canonical)
out=$(run_case canon "$CLEAN_GARDEN" prune --only "$WT_C_MERGED2")
expect "10c: canonical repo name, merged PR: pruned" "$out" is_gone "$WT_C_MERGED2"

echo "CASE 11: --pr-cache and the pr-cache verb"
REPO3="$TMP_ROOT/repo-pc"
git clone -q "$REPO" "$REPO3" >/dev/null 2>&1
git -C "$REPO3" config user.email t@test.com
git -C "$REPO3" config user.name t
git -C "$REPO3" config maintenance.auto false
git -C "$REPO3" remote set-url origin https://github.com/owner/repo.git
mk_wt3() {
    git -C "$REPO3" worktree add -q "$TMP_ROOT/$1" -b "$2" >/dev/null 2>&1
    echo "$TMP_ROOT/$1"
}
PC_GH_LOG="$TMP_ROOT_UNIX/pc-gh.log"
STUB_DIR_PC="$TMP_ROOT_UNIX/bin-pc"
mkdir -p "$STUB_DIR_PC"
cat > "$STUB_DIR_PC/gh" <<STUB
#!/usr/bin/env bash
args="\$*"
echo "\$args" >> "$PC_GH_LOG"
case "\$args" in *"auth status"*) exit 0 ;; esac
case "\$args" in *"repo view"*)
    case "\${GH_VIEW:-lower}" in lower) echo "owner/repo"; exit 0 ;; canon) echo "Owner/Repo"; exit 0 ;; *) exit 1 ;; esac ;;
esac
case "\$args" in *"api --paginate repos/"*"/pulls"*)
    [ "\${GH_PULLS:-ok}" = fail ] && exit 1
    row_repo="owner/repo"; [ "\${GH_VIEW:-lower}" = canon ] && row_repo="Owner/Repo"
    for kind in feat:merged open:open; do
        while IFS=' ' read -r branch sha; do
            printf '%s\t%s\t%s\t%s\n' "\$row_repo" "\$branch" "\${kind#*:}" "\$sha"
        done < <(git for-each-ref --format='%(refname:short) %(objectname)' "refs/heads/\${kind%%:*}")
    done
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR_PC/gh"
run_pc() {
    GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 \
        RUN_CLEAN_STUB_DIR="$STUB_DIR_PC" RUN_CLEAN_REPO="$REPO3" run_clean "$CLEAN_GARDEN" "$@"
}
run_verb() {
    (
        cd "$REPO3" || exit 1
        set +e
        PATH="$STUB_DIR_PC:$PATH" FORGE=github GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 \
            bash "$CLEAN_GARDEN" pr-cache 2>/dev/null
        printf 'rc=%s\n' "$?"
    )
}
mk_branch_listed_by_stub() { mk_wt3 "$1" "feat/$2" >/dev/null; }
gh_calls() { if [ -s "$PC_GH_LOG" ]; then grep -c . "$PC_GH_LOG"; else echo 0; fi; }
gh_pull_calls() { if [ -s "$PC_GH_LOG" ]; then grep -c 'api --paginate' "$PC_GH_LOG" || true; else echo 0; fi; }
eq() { [ "$1" = "$2" ]; }
PCF="$TMP_ROOT_UNIX/pc-files"
mkdir -p "$PCF"
SHA0="0000000000000000000000000000000000000000"
pc_valid() { printf '# nwo=owner/repo\n# scope=branch %s\n# complete rows=0\n' "$2" > "$1"; }
pc_refusal() {
    local label="$1" br="$2" reason="$3" wt
    wt=$(mk_wt3 "wt-pc-${label// /-}" "$br")
    out=$(run_pc prune --only "$wt" --only-allow-unmerged --pr-cache "$PCF/bad.txt")
    expect "11 $label: rc 2" "$out" rc_is "$out" 2
    expect "11 $label: worktree kept" "$out" is_dir "$wt"
    expect "11 $label: stderr reason" "$out" grepq "$out" -F "ERR worktree: --pr-cache: $reason"
    pc_valid "$PCF/ok.txt" "$br"
    out=$(run_pc prune --only "$wt" --only-allow-unmerged --pr-cache "$PCF/ok.txt")
    expect "11 $label control (valid file prunes): rc 0" "$out" rc_is "$out" 0
    expect "11 $label control (valid file prunes): worktree removed" "$out" is_gone "$wt"
}

: > "$PCF/bad.txt"
pc_refusal "empty cache" none/pc-empty "no nwo header"
printf '# nwo=owner/repo\n# scope=all\nowner/repo\tx1\tmerged\t%s\nowner/repo\tx2\tmerged\t%s\n' "$SHA0" "$SHA0" > "$PCF/bad.txt"
pc_refusal "truncated cache" none/pc-trunc "no complete trailer"
printf '# nwo=owner/repo\n# scope=all\nowner/repo\tx1\tmerged\t%s\nowner/repo\tx2\tmerged\t%s\n# complete rows=3\n' "$SHA0" "$SHA0" > "$PCF/bad.txt"
pc_refusal "rows cut, trailer kept" none/pc-cut "trailer rows=3 but 2 rows"
printf '# nwo=owner/repo\n# scope=branch a\n# complete rows=0\n' > "$PCF/bad.txt"
pc_refusal "scope for another branch" none/pc-scope "scope branch a does not cover"
printf '# nwo=yotamleo-org/Himmel\n# scope=all\nyotamleo-org/Himmel\tx\tmerged\t%s\n# complete rows=1\n' "$SHA0" > "$PCF/bad.txt"
pc_refusal "nwo of another repo" none/pc-nwo "nwo yotamleo-org/Himmel is not origin owner/repo"
printf '# nwo=owner/repo\n# scope=all\nOwner/Repo\tx\tmerged\t%s\n# complete rows=1\n' "$SHA0" > "$PCF/bad.txt"
pc_refusal "row repo differs from header" none/pc-row "row repo Owner/Repo is not header owner/repo"
printf '# nwo=owner/repo\n# scope=all\nowner/repo\tx\topen\n# complete rows=1\n' > "$PCF/bad.txt"
pc_refusal "row cut before its head" none/pc-nohead "malformed row"
printf '# nwo=owner/repo\n# scope=all\nowner/repo\tx\n# complete rows=1\n' > "$PCF/bad.txt"
pc_refusal "row cut before its state" none/pc-nostate "malformed row"
printf '# nwo=owner/repo\n# scope=all\nowner/repo\tx\tweird\t%s\n# complete rows=1\n' "$SHA0" > "$PCF/bad.txt"
pc_refusal "row with an unknown state" none/pc-badstate "malformed row"
printf '# nwo=owner/repo\n# scope=all\nowner/repo\tx1\tmerged\t%s\nowner/repo\tx2\tmerged\t%s\nowner/repo\tx3\tmerged\t%s\n# complete rows=18446744073709551619\n' "$SHA0" "$SHA0" "$SHA0" > "$PCF/bad.txt"
pc_refusal "trailer count that overflows to the row count" none/pc-wrap "no complete trailer"
printf '# nwo=owner/repo\n# complete rows=0\n' > "$PCF/bad.txt"
pc_refusal "no scope header" none/pc-noscope "no usable scope header"

WT_PC_UNR=$(mk_wt3 wt-pc-unreadable none/pc-unreadable)
out=$(run_pc prune --only "$WT_PC_UNR" --only-allow-unmerged --pr-cache "$PCF/nonexistent.txt")
expect "11 unreadable cache: rc 2" "$out" rc_is "$out" 2
expect "11 unreadable cache: worktree kept" "$out" is_dir "$WT_PC_UNR"
expect "11 unreadable cache: stderr reason" "$out" grepq "$out" -F "ERR worktree: --pr-cache: cannot read $PCF/nonexistent.txt"
pc_valid "$PCF/ok.txt" none/pc-unreadable
out=$(run_pc prune --only "$WT_PC_UNR" --only-allow-unmerged --pr-cache "$PCF/ok.txt")
expect "11 unreadable cache control (valid file prunes): worktree removed" "$out" is_gone "$WT_PC_UNR"

WT_PC_NOVAL=$(mk_wt3 wt-pc-noval none/pc-noval)
out=$(run_pc prune --only "$WT_PC_NOVAL" --only-allow-unmerged --pr-cache)
expect "11 --pr-cache with no file: rc 2" "$out" rc_is "$out" 2
expect "11 --pr-cache with no file: worktree kept" "$out" is_dir "$WT_PC_NOVAL"
expect "11 --pr-cache with no file: stderr reason" "$out" grepq "$out" -F "ERR worktree: --pr-cache: needs a file"

pc_valid "$PCF/ok.txt" none/pc-noval
out=$(run_pc prune --pr-cache "$PCF/ok.txt")
expect "11 --pr-cache without --only: rc 2" "$out" rc_is "$out" 2
expect "11 --pr-cache without --only: stderr reason" "$out" grepq "$out" -F "ERR worktree: --pr-cache: needs --only"
expect "11 --pr-cache without --only: the target survived" "$out" is_dir "$WT_PC_NOVAL"
out=$(run_pc prune --only "$WT_PC_NOVAL" --only-allow-unmerged --pr-cache "$PCF/ok.txt")
expect "11 --pr-cache without --only control (with --only prunes)" "$out" is_gone "$WT_PC_NOVAL"

WT_PC_NG=$(mk_wt pc-notgithub none/pc-notgithub)
pc_valid "$PCF/ok.txt" none/pc-notgithub
out=$(run_clean "$CLEAN_GARDEN" prune --only "$WT_PC_NG" --only-allow-unmerged --pr-cache "$PCF/ok.txt")
expect "11 origin is not a GitHub remote: rc 2" "$out" rc_is "$out" 2
expect "11 origin is not a GitHub remote: worktree kept" "$out" is_dir "$WT_PC_NG"
expect "11 origin is not a GitHub remote: stderr reason" "$out" grepq "$out" -F "ERR worktree: --pr-cache: origin is not a GitHub remote"

WT_PC_OPEN=$(mk_wt3 wt-pc-open open/pc-case)
PC_OPEN_TIP=$(git -C "$WT_PC_OPEN" rev-parse HEAD)
printf '# nwo=Owner/Repo\n# scope=all\nOwner/Repo\topen/pc-case\topen\t%s\nOwner/Repo\tother\tmerged\t%s\n# complete rows=2\n' "$PC_OPEN_TIP" "$SHA0" > "$PCF/case.txt"
out=$(run_pc prune --only "$WT_PC_OPEN" --only-allow-unmerged --pr-cache "$PCF/case.txt")
expect "11 case-different nwo, open PR: refused as not a prune candidate (rc 1, not the file refusal rc 2)" "$out" rc_is "$out" 1
expect "11 case-different nwo, open PR: worktree kept" "$out" is_dir "$WT_PC_OPEN"
expect "11 case-different nwo, open PR: the open-PR reason of the summary" "$out" grepq "$out" -F "not a prune candidate"
printf '# nwo=Owner/Repo\n# scope=all\nOwner/Repo\tother\tmerged\t%s\n# complete rows=1\n' "$SHA0" > "$PCF/case.txt"
out=$(run_pc prune --only "$WT_PC_OPEN" --only-allow-unmerged --pr-cache "$PCF/case.txt")
expect "11 case-different nwo, no PR control: pruned" "$out" is_gone "$WT_PC_OPEN"

WT_PC_MERGED=$(mk_wt3 wt-pc-merged feat/pc-merged)
PC_MERGED_TIP=$(git -C "$WT_PC_MERGED" rev-parse HEAD)
printf '# nwo=owner/repo\n# scope=branch feat/pc-merged\nowner/repo\tfeat/pc-merged\tmerged\t%s\n# complete rows=1\n' "$PC_MERGED_TIP" > "$PCF/merged.txt"
: > "$PC_GH_LOG"
out=$(run_pc prune --only "$WT_PC_MERGED" --pr-cache "$PCF/merged.txt")
expect "11 merged head-match row from --pr-cache: rc 0" "$out" rc_is "$out" 0
expect "11 merged head-match row from --pr-cache: worktree removed" "$out" is_gone "$WT_PC_MERGED"
expect "11 merged head-match row from --pr-cache: no gh call" "$out" eq "$(gh_calls)" 0
WT_PC_UNPUSHED=$(mk_wt3 wt-pc-unpushed none/pc-unpushed)
printf 'extra\n' > "$WT_PC_UNPUSHED/extra.txt"
git -C "$WT_PC_UNPUSHED" add extra.txt
git -C "$WT_PC_UNPUSHED" commit -q -m "unpushed commit"
pc_valid "$PCF/ok.txt" none/pc-unpushed
: > "$PC_GH_LOG"
out=$(run_pc prune --only "$WT_PC_UNPUSHED" --only-allow-unmerged --pr-cache "$PCF/ok.txt")
expect "11 no row and an unpushed commit: refused" "$out" rc_nonzero "$out"
expect "11 no row and an unpushed commit: worktree kept" "$out" is_dir "$WT_PC_UNPUSHED"
expect "11 no row and an unpushed commit: no gh call" "$out" eq "$(gh_calls)" 0

WT_PC_LOCKED=$(mk_wt3 wt-pc-locked feat/pc-locked)
git -C "$REPO3" worktree lock "$WT_PC_LOCKED"
PC_LOCKED_TIP=$(git -C "$WT_PC_LOCKED" rev-parse HEAD)
printf '# nwo=owner/repo\n# scope=branch feat/pc-locked\nowner/repo\tfeat/pc-locked\tmerged\t%s\n# complete rows=1\n' "$PC_LOCKED_TIP" > "$PCF/locked.txt"
out=$(run_pc prune --only "$WT_PC_LOCKED" --pr-cache "$PCF/locked.txt")
expect "11 R9 locked with a cache file: refused" "$out" rc_nonzero "$out"
expect "11 R9 locked with a cache file: kept" "$out" is_dir "$WT_PC_LOCKED"
expect "11 R9 locked with a cache file: says locked" "$out" grepq "$out" "is locked"
git -C "$REPO3" worktree unlock "$WT_PC_LOCKED"
out=$(run_pc prune --only "$WT_PC_LOCKED" --pr-cache "$PCF/locked.txt")
expect "11 R9 locked control (unlocked prunes with the same file)" "$out" is_gone "$WT_PC_LOCKED"
if [ -d /proc/self ]; then
    WT_PC_HELD=$(mk_wt3 wt-pc-held feat/pc-held)
    PC_HELD_TIP=$(git -C "$WT_PC_HELD" rev-parse HEAD)
    printf '# nwo=owner/repo\n# scope=branch feat/pc-held\nowner/repo\tfeat/pc-held\tmerged\t%s\n# complete rows=1\n' "$PC_HELD_TIP" > "$PCF/held.txt"
    ( cd "$WT_PC_HELD" && exec sleep 60 ) &
    HOLDER_PID=$!
    sleep 0.3
    out=$(run_pc prune --only "$WT_PC_HELD" --pr-cache "$PCF/held.txt")
    expect "11 R9 in use with a cache file: refused" "$out" rc_nonzero "$out"
    expect "11 R9 in use with a cache file: kept" "$out" is_dir "$WT_PC_HELD"
    expect "11 R9 in use with a cache file: says in use" "$out" grepq "$out" "in use"
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
    HOLDER_PID=""
    out=$(run_pc prune --only "$WT_PC_HELD" --pr-cache "$PCF/held.txt")
    expect "11 R9 in use control (no holder prunes with the same file)" "$out" is_gone "$WT_PC_HELD"
else
    echo "  SKIP: 11 R9 in use: no /proc on this platform"
fi

mk_branch_listed_by_stub wt-pc-v1 pc-v1
: > "$PC_GH_LOG"
out=$(GH_VIEW=lower run_verb)
expect "11 verb: rc 0" "$out" grepq "$out" -x "rc=0"
expect "11 verb: first line is the walked nwo" "$out" eq "$(printf '%s\n' "$out" | sed -n 1p)" "# nwo=owner/repo"
expect "11 verb: scope is all" "$out" eq "$(printf '%s\n' "$out" | sed -n 2p)" "# scope=all"
expect "11 verb: lists the feat row" "$out" grepq "$out" -F "owner/repo	feat/pc-v1	merged	"
PC_VERB_ROWS=$(printf '%s\n' "$out" | grep -c -v -e '^#' -e '^rc=')
expect "11 verb: the trailer matches the row count" "$out" grepq "$out" -x "# complete rows=$PC_VERB_ROWS"
expect "11 verb: exactly one pulls call" "$out" eq "$(gh_pull_calls)" 1
printf '%s\n' "$out" | grep -v '^rc=' > "$PCF/verb.txt"
WT_PC_V2=$(mk_wt3 wt-pc-v2 none/pc-v2)
out=$(run_pc prune --only "$WT_PC_V2" --only-allow-unmerged --pr-cache "$PCF/verb.txt")
expect "11 verb output is read back by --pr-cache (scope=all, no row for the branch: pruned)" "$out" is_gone "$WT_PC_V2"
: > "$PC_GH_LOG"
out=$(GH_VIEW=canon run_verb)
expect "11 verb: header is forge_repo_nwo's canonical case" "$out" eq "$(printf '%s\n' "$out" | sed -n 1p)" "# nwo=Owner/Repo"
: > "$PC_GH_LOG"
out=$(GH_VIEW=lower GH_PULLS=fail run_verb)
expect "11 verb: failed walk is rc 1 with empty stdout" "$out" eq "$out" "rc=1"
: > "$PC_GH_LOG"
out=$(GH_VIEW=fail run_verb)
expect "11 verb: failed repo-name lookup is rc 1 with empty stdout" "$out" eq "$out" "rc=1"
expect "11 verb: failed repo-name lookup makes no pulls walk" "$out" eq "$(gh_pull_calls)" 0

# ── control: the plain (fleet-wide) run still prunes every merged sibling ────
echo "CONTROL: plain --prune-only"
out=$(run_clean "$CLEAN_GARDEN" prune --prune-only)
expect "control: plain prune still takes the merged sibling feat/b" "$out" is_gone "$WT_B"

echo
echo "test-clean-only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
