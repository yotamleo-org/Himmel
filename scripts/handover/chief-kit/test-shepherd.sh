#!/usr/bin/env bash
# test-shepherd.sh — Drives shepherd.sh with a stub gh on PATH, stub
# ready-check / check-ci / impacted-suites, and a real scratch git repo (a bare
# origin carrying refs/pull/7/head), in a scratch HOME. bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-shepherd.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHEP="${SHEPHERD:-$HERE/shepherd.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
has() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in: $3)" ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shepherd-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@t; git config --global user.name t
git config --global init.defaultBranch main
mkdir -p "$WORK/emptyroot" "$WORK/himmelcfg"
: > "$WORK/emptyroot/.env"
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
export GH_READ_ENV_ROOT="$WORK/emptyroot" HIMMEL_SECRETS_KEYRING=off HIMMEL_CONFIG_DIR="$WORK/himmelcfg"

# Scratch repo: bare origin + clone; PR 7 head = one commit adding test-a.sh.
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
( cd "$WORK/repo" && echo base > f && git add f && git commit -qm base && git push -q origin main \
  && git checkout -q -b pr && printf '#!/bin/sh\nexit 0\n' > test-a.sh && git add test-a.sh && git commit -qm pr \
  && git push -q origin pr:refs/pull/7/head && git checkout -q main )
HEADSHA=$(git -C "$WORK/repo" rev-parse pr)

# Stubs. gh prints $WORK/pr.json; ready-check/check-ci exit with the code in a file.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/sh
cat "$SHEP_PRJSON"
EOF
chmod +x "$WORK/bin/gh"
cat > "$WORK/rc-stub.sh" <<'EOF'
#!/bin/sh
# usage: rc-stub.sh <name> ...: exit with the code in $SHEP_STUBDIR/<name>.rc (default 0)
n="$1"; shift
[ "$n" = ready ] && printf '%s\n' "$*" >> "$SHEP_STUBDIR/ready.args"
[ "$n" = ready ] && case "$1" in --only) n=cov ;; esac
c=0; [ -f "$SHEP_STUBDIR/$n.rc" ] && c=$(cat "$SHEP_STUBDIR/$n.rc")
echo "stub $n rc=$c fail line" ; exit "$c"
EOF
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec sh "$SHEP_STUBDIR/../rc-stub.sh" ready "$@"\n' > "$WORK/ready-stub"
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec sh "$SHEP_STUBDIR/../rc-stub.sh" ci "$@"\n' > "$WORK/ci-stub"
printf '#!/bin/sh\necho test-a.sh\n' > "$WORK/impacted-stub"
export SHEP_STUBDIR="$WORK/stubs"; mkdir -p "$SHEP_STUBDIR"
export SHEP_PRJSON="$WORK/pr.json"
export PATH="$WORK/bin:$PATH"
export SHEPHERD_READY_CHECK="$WORK/ready-stub" SHEPHERD_CHECK_CI="$WORK/ci-stub" SHEPHERD_IMPACTED="$WORK/impacted-stub"
export SHEPHERD_LEDGER="$WORK/ledger.jsonl"

setup() { # <cloud-done yes|no> <ledger ok|none> <suite-exit>
    rm -rf "${SHEP_STUBDIR:?}"/* "$WORK/repo/.claude"
    git -C "$WORK/repo" worktree prune
    if [ "$1" = yes ]; then c='[{"body":"CLOUD-DONE https://x"}]'; else c='[{"body":"hello"}]'; fi
    printf '{"headRefOid":"%s","baseRefName":"main","comments":%s}\n' "$HEADSHA" "$c" > "$SHEP_PRJSON"
    if [ "$2" = ok ]; then printf '{"kind":"avail","head":"%s","status":"ok"}\n' "$HEADSHA" > "$SHEPHERD_LEDGER"; else : > "$SHEPHERD_LEDGER"; fi
    printf '#!/bin/sh\nexit %s\n' "$3" > "$WORK/suite-body"
}
# the worktree checks out test-a.sh from the PR head (exit 0); a failing suite
# is simulated by the impacted stub naming a suite that does not pass.
run() { ( cd "$WORK/repo" && bash "$SHEP" 7 2>&1 ); }

# (a) usage
out=$(bash "$SHEP" 2>&1); check "(a) no args exits 2" 2 $?
out=$(bash "$SHEP" 07 2>&1); check "(a) leading zero exits 2" 2 $?

# (b) clean path
setup yes ok 0
out=$(run); rc=$?
check "(b) clean path exits 0" 0 "$rc"
has "(b) block says READY-CANDIDATE" "SHEPHERD 7 $HEADSHA READY-CANDIDATE" "$out"
has "(b) steering skipped" "steering: skipped" "$out"
has "(b) suite verdict line" "suite test-a.sh: PASS" "$out"
has "(b) the full ready-check read is warn-only (--observe)" "--observe 7 $HEADSHA" "$(cat "$SHEP_STUBDIR/ready.args" 2>/dev/null)"
check "(b) clean run removes its own worktree" "" "$([ -d "$WORK/repo/.claude/worktrees/shepherd-7" ] && echo yes)"
wtl=$(git -C "$WORK/repo" worktree list 2>&1)
has "(b) worktree list probe ran" "[main]" "$wtl"
case "$wtl" in *shepherd-7*) fail "(b) worktree no longer listed (still in: $wtl)" ;; *) pass "(b) worktree no longer listed" ;; esac

# (c) failed suite -> needs worker
setup yes ok 0
printf '#!/bin/sh\necho test-fail.sh\n' > "$WORK/impacted-stub"
( cd "$WORK/repo" && git checkout -q pr && printf '#!/bin/sh\nexit 1\n' > test-fail.sh && git add test-fail.sh && git commit -qm f \
  && git push -q -f origin pr:refs/pull/7/head && git checkout -q main )
HEADSHA=$(git -C "$WORK/repo" rev-parse pr); setup yes ok 0
out=$(run); rc=$?
check "(c) failed suite exits 1" 1 "$rc"
has "(c) names suite-failed" "NEEDS-WORKER" "$out"
has "(c) suite-failed reason" "suite-failed:1" "$out"
has "(c) suite verdict FAIL" "suite test-fail.sh: FAIL" "$out"
printf '#!/bin/sh\necho test-a.sh\n' > "$WORK/impacted-stub"

# (d) coverage gap
setup yes ok 0; echo 1 > "$SHEP_STUBDIR/cov.rc"
out=$(run); rc=$?
check "(d) coverage gap exits 1" 1 "$rc"
has "(d) coverage-gap reason" "coverage-gap" "$out"

# (e) CI pending
setup yes ok 0; echo 2 > "$SHEP_STUBDIR/ci.rc"
out=$(run); rc=$?
check "(e) CI pending exits 1" 1 "$rc"
has "(e) names ci-pending" "ci-pending" "$out"
has "(e) ci line says PENDING" "ci: PENDING" "$out"

# (f) CLOUD-DONE absent: steering is NOT skipped, nothing else runs
setup no ok 0
out=$(run); rc=$?
check "(f) no CLOUD-DONE exits 1" 1 "$rc"
has "(f) steering DUE" "steering: DUE" "$out"
has "(f) steering-required reason" "steering-required" "$out"
check "(f) no worktree made" "" "$([ -d "$WORK/repo/.claude/worktrees/shepherd-7" ] && echo yes)"

# (g) panel not run -> says so, needs worker
setup yes none 0
out=$(run); rc=$?
check "(g) no ledger row exits 1" 1 "$rc"
has "(g) panel NOT-RUN stated" "panel: NOT-RUN" "$out"
has "(g) panel-not-run reason" "panel-not-run" "$out"

# (h) gh failure -> infra error
setup yes ok 0; printf 'not json\n' > "$SHEP_PRJSON"
out=$(run); rc=$?
check "(h) unreadable PR exits 2" 2 "$rc"

# (i) impacted-suites failing is not an empty list
setup yes ok 0
printf '#!/bin/sh\nexit 1\n' > "$WORK/impacted-stub"
out=$(run); rc=$?
check "(i) discovery failure exits 1" 1 "$rc"
has "(i) suites-discovery-failed reason" "suites-discovery-failed" "$out"
printf '#!/bin/sh\necho test-a.sh\n' > "$WORK/impacted-stub"

# (j) a reused worktree with local changes is refused, not tested
setup yes ok 0
git -C "$WORK/repo" worktree add --quiet --detach "$WORK/repo/.claude/worktrees/shepherd-7" "$HEADSHA"
echo stray > "$WORK/repo/.claude/worktrees/shepherd-7/stray.txt"
out=$(run); rc=$?
check "(j) dirty reused worktree exits 2" 2 "$rc"
has "(j) says local changes" "local changes" "$out"
check "(j) refused tree and its file are kept" yes "$([ -f "$WORK/repo/.claude/worktrees/shepherd-7/stray.txt" ] && echo yes)"

# (k) a non-avail ledger row at the head is not a panel pass
setup yes none 0
printf '{"kind":"finding","head":"%s","status":"ok"}\n' "$HEADSHA" > "$SHEPHERD_LEDGER"
out=$(run); rc=$?
check "(k) non-avail row exits 1" 1 "$rc"
has "(k) panel NOT-RUN stated" "panel: NOT-RUN" "$out"

# (l) a run that leaves a modified file keeps the tree and the file
setup yes ok 0
printf '#!/bin/sh\necho dirty > dirty.txt\n' > "$WORK/dirtier.sh"
printf '#!/bin/sh\necho %s\n' "$WORK/dirtier.sh" > "$WORK/impacted-stub"
out=$(run); rc=$?
check "(l) dirtying run exits 0" 0 "$rc"
check "(l) dirty worktree is kept" yes "$([ -d "$WORK/repo/.claude/worktrees/shepherd-7" ] && echo yes)"
check "(l) the modified file is still there" yes "$([ -f "$WORK/repo/.claude/worktrees/shepherd-7/dirty.txt" ] && echo yes)"
printf '#!/bin/sh\necho test-a.sh\n' > "$WORK/impacted-stub"

# (n) a run that leaves an ignored file keeps the tree and the file
setup yes ok 0
echo '*.local' >> "$WORK/repo/.git/info/exclude"
printf '#!/bin/sh\necho secret > .env.local\n' > "$WORK/ignorer.sh"
printf '#!/bin/sh\necho %s\n' "$WORK/ignorer.sh" > "$WORK/impacted-stub"
out=$(run); rc=$?
check "(n) ignoring run exits 0" 0 "$rc"
check "(n) worktree with an ignored file is kept" yes "$([ -d "$WORK/repo/.claude/worktrees/shepherd-7" ] && echo yes)"
check "(n) the ignored file is still there" yes "$([ -f "$WORK/repo/.claude/worktrees/shepherd-7/.env.local" ] && echo yes)"
: > "$WORK/repo/.git/info/exclude"
printf '#!/bin/sh\necho test-a.sh\n' > "$WORK/impacted-stub"

# (m) a failing run (exit 1) still removes its clean tree
setup yes ok 0; echo 1 > "$SHEP_STUBDIR/cov.rc"
out=$(run); rc=$?
check "(m) coverage-gap exits 1" 1 "$rc"
check "(m) clean tree removed on the NEEDS-WORKER path" "" "$([ -d "$WORK/repo/.claude/worktrees/shepherd-7" ] && echo yes)"

setup yes ok 0; echo 2 > "$SHEP_STUBDIR/ready.rc"
out=$(run); rc=$?
check "(o) ready-check exit 2 exits 1" 1 "$rc"
has "(o) the line says not evaluated" "ready-check: not evaluated" "$out"
has "(o) its own reason" "ready-check-not-evaluated" "$out"
case "$out" in *"ready-check: FAIL"*) fail "(o) a refused read is not a FAIL" ;; *) pass "(o) a refused read is not a FAIL" ;; esac
setup yes ok 0; echo 1 > "$SHEP_STUBDIR/ready.rc"
out=$(run); rc=$?
check "(o) ready-check exit 1 exits 1" 1 "$rc"
has "(o) a real fail still says FAIL" "ready-check: FAIL" "$out"
has "(o) a real fail keeps ready-check-failed" "ready-check-failed" "$out"

READTOK=ghp_READTOKEN0123456789
mkdir -p "$WORK/ttroot" "$WORK/tt"
printf 'himmel_github_token_vm2=%s\n' "$READTOK" > "$WORK/ttroot/.env"
ln -s "$HERE/fixtures/gh-two-token-stub.sh" "$WORK/tt/gh"
TTLOG="$WORK/tt.log"
logn() { grep -c -E -- "$1" "$TTLOG"; }
printf '#!/bin/sh\necho test-a.sh\n' > "$WORK/impacted-stub"
tt_run() {
    : > "$TTLOG"
    out=$( cd "$WORK/repo" && env -u GH_CMD GH_READ_ENV_ROOT="$1" PATH="$WORK/tt:$PATH" GH_STUB_DELEGATE="$WORK/bin/gh" \
        GH_STUB_READ_TOKEN="$READTOK" GHLOG="$TTLOG" HIMMEL_SECRETS_KEYRING=off HIMMEL_CONFIG_DIR="$WORK/himmelcfg" \
        bash "$SHEP" 7 2>&1 ); rc=$?
}
setup yes ok 0
GH_STUB_MAINFAIL=rate tt_run "$WORK/ttroot"
check "(p) main spent: shepherd exits 0" 0 "$rc"
has "(p) main spent: the PR view gives the head" "SHEPHERD 7 $HEADSHA READY-CANDIDATE" "$out"
case "$out" in *"cannot read PR"*) fail "(p) main spent: no 'cannot read PR head'" ;; *) pass "(p) main spent: no 'cannot read PR head'" ;; esac
check "(p) main spent: the PR view logs tok=read" 1 "$(logn '^tok=read argv=pr view 7 --json headRefOid,baseRefName,comments')"
check "(p) main spent: no read logs tok=main" 0 "$(logn '^tok=main ')"
setup yes ok 0
tt_run "$WORK/emptyroot"
check "(p) control, no read token: shepherd exits 0" 0 "$rc"
has "(p) control: the PR view gives the head" "SHEPHERD 7 $HEADSHA READY-CANDIDATE" "$out"
check "(p) control: the PR view logs tok=main" 1 "$(logn '^tok=main argv=pr view 7 --json headRefOid,baseRefName,comments')"
check "(p) control: no call logs tok=read" 0 "$(logn '^tok=read ')"
setup yes ok 0
: > "$TTLOG"
out=$( cd "$WORK/repo" && env -u GH_CMD PATH="$WORK/tt:$PATH" GH_STUB_DELEGATE="$WORK/bin/gh" GH_STUB_READ_TOKEN="$READTOK" GHLOG="$TTLOG" \
    bash "$SHEP" 7 2>&1 ); rc=$?
check "(p) pin: the suite's inherited GH_READ_ENV_ROOT is the empty fixture root" "$WORK/emptyroot" "$GH_READ_ENV_ROOT"
check "(p) pin: a run() shaped call reads from the empty root, so it logs tok=main" 1 "$(logn '^tok=main argv=pr view 7 --json headRefOid,baseRefName,comments')"
check "(p) pin: a run() shaped call logs no tok=read" 0 "$(logn '^tok=read ')"
setup yes ok 0
: > "$TTLOG"
out=$( cd "$WORK/repo" && GH_CMD="$WORK/bin/gh" GH_READ_ENV_ROOT="$WORK/ttroot" PATH="$WORK/tt:$PATH" GH_STUB_DELEGATE="$WORK/bin/gh" \
    GH_STUB_READ_TOKEN="$READTOK" GHLOG="$TTLOG" GH_STUB_MAINFAIL=rate HIMMEL_SECRETS_KEYRING=off bash "$SHEP" 7 2>&1 ); rc=$?
check "(p) a set GH_CMD seam still wins: shepherd exits 0" 0 "$rc"
check "(p) a set GH_CMD seam never reaches the two-token stub" 0 "$(wc -l < "$TTLOG" | tr -d ' ')"

printf '\n%s failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
