#!/usr/bin/env bash
# Two adopted projects each start a /afk-shift and keep their own queue, plan,
# ledger, stop marker and morning report; a shift from the himmel clone keeps
# its current paths.
#
# Each scratch project carries its own copy of scripts/afk/ and the two lib
# files the shift sources, the layout adopt.sh leaves behind. The "himmel
# clone" is a scratch project that also has scripts/adopt.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

PASS=0
FAIL=0
TMP_ROOT=$(mktemp -d -t afk-per-project.XXXXXX) || exit 1
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

FAKE_HOME="$TMP_ROOT/home"
SHARED_ROOT="$TMP_ROOT/handovers"
mkdir -p "$FAKE_HOME/.himmel" "$SHARED_ROOT"
# The station config names himmel's own queue; an adopted project must never inherit it.
printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$FAKE_HOME/.himmel/himmel.conf"

# Fake jira: `list --project KEY` prints one ticket in KEY; anything else fails.
FAKE_JIRA="$TMP_ROOT/jira-fake.sh"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    '[ "${1:-}" = list ] || { echo "fake jira: not a list call: $*" >&2; exit 64; }' \
    'p=""; while [ $# -gt 0 ]; do [ "$1" = --project ] && p="$2"; shift; done' \
    '[ -n "$p" ] || { echo "fake jira: list without --project" >&2; exit 64; }' \
    'printf "%s-1\tTask\tTo Do\tWork in %s\n" "$p" "$p"' > "$FAKE_JIRA"
chmod +x "$FAKE_JIRA"

# mkproject <dir> [clone] — a git project carrying the adopted shift scripts.
mkproject() {
    mkdir -p "$1/scripts/afk" "$1/scripts/lib"
    git init -q -b main "$1"
    cp "$REPO_ROOT"/scripts/afk/*.sh "$REPO_ROOT"/scripts/afk/*.tmpl "$1/scripts/afk/"
    cp "$REPO_ROOT/scripts/lib/load-dotenv.sh" "$REPO_ROOT/scripts/lib/handover-path.sh" "$1/scripts/lib/"
    if [ "${2:-}" = clone ]; then : > "$1/scripts/adopt.sh"; fi
}

# inproj <dir> <cmd...> — run a command from <dir> with the scratch HOME and shared root.
inproj() {
    local d="$1"; shift
    (cd "$d" && env -u AFK_STOP_DIR -u OVERNIGHT_STOP_DIR -u AFK_PROJECT -u OVERNIGHT_PROJECT \
        HOME="$FAKE_HOME" HANDOVER_DIR="$SHARED_ROOT" JIRA_CMD="$FAKE_JIRA" PROVISION_CMD=false "$@")
}

A="$TMP_ROOT/alpha"; B="$TMP_ROOT/beta"; C="$TMP_ROOT/himmel"
mkproject "$A"; mkproject "$B"; mkproject "$C" clone
today=$(date -u +%F)

echo "TEST: each adopted project plans from its own Jira queue"
rc_a=0; plan_a=$(inproj "$A" env JIRA_PROJECT_KEY=AAA bash scripts/afk/build-plan.sh 2>&1) || rc_a=$?
rc_b=0; plan_b=$(inproj "$B" env JIRA_PROJECT_KEY=BBB bash scripts/afk/build-plan.sh 2>&1) || rc_b=$?
if [ "$rc_a" -eq 0 ] && [[ "$plan_a" == *AAA-1* ]]; then pass "alpha queue is AAA"; else fail "alpha queue is AAA" "rc=$rc_a $plan_a"; fi
if [ "$rc_b" -eq 0 ] && [[ "$plan_b" == *BBB-1* ]]; then pass "beta queue is BBB"; else fail "beta queue is BBB" "rc=$rc_b $plan_b"; fi

echo "TEST: the default jira CLI runs from a project path with a space"
S="$TMP_ROOT/with space"; mkproject "$S"
mkdir -p "$S/scripts/jira/dist"
cp "$FAKE_JIRA" "$S/scripts/jira/dist/fake.sh"
printf '%s\n' 'require("child_process").execFileSync(__dirname + "/fake.sh", process.argv.slice(2), { stdio: "inherit" });' > "$S/scripts/jira/dist/index.js"
rc_s=0; plan_s=$(inproj "$S" env -u JIRA_CMD JIRA_PROJECT_KEY=SPC bash scripts/afk/build-plan.sh 2>&1) || rc_s=$?
if [ "$rc_s" -eq 0 ] && [[ "$plan_s" == *SPC-1* ]]; then pass "spaced path keeps the CLI one argument"; else fail "spaced path keeps the CLI one argument" "rc=$rc_s $plan_s"; fi

echo "TEST: an adopted project with no JIRA_PROJECT_KEY is refused, never handed himmel's queue"
rc=0; out=$(inproj "$A" env -u JIRA_PROJECT_KEY bash scripts/afk/build-plan.sh 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && [[ "$out" == *JIRA_PROJECT_KEY* ]] && [[ "$out" != *HIMMEL-1* ]]; then
    pass "unset key refused (rc 1)"
else
    fail "unset key refused (rc 1)" "rc=$rc out=$out"
fi

echo "TEST: an adopted project reads its key from its own .env, not the station's himmel.conf"
D="$TMP_ROOT/demo"; mkproject "$D"
printf 'JIRA_PROJECT_KEY=DEMO\n' > "$D/.env"
plan_d=$(inproj "$D" env -u JIRA_PROJECT_KEY bash scripts/afk/build-plan.sh 2>&1)
if [[ "$plan_d" == *DEMO-1* ]] && [[ "$plan_d" != *HIMMEL-1* ]]; then pass "demo queue is DEMO from its .env"; else fail "demo queue is DEMO from its .env" "$plan_d"; fi

echo "TEST: each adopted project keeps its plan and ledger in its own state dir"
rc_d=0
dir_a=$(inproj "$A" bash scripts/afk/project-state.sh dir 2>&1) || rc_d=$?
dir_b=$(inproj "$B" bash scripts/afk/project-state.sh dir 2>&1) || rc_d=$?
if [ "$rc_d" -eq 0 ] && [ -n "$dir_a" ] && [ "$dir_a" != "$dir_b" ] && [ -d "$dir_a" ] && [ -d "$dir_b" ]; then
    pass "state dirs differ and exist"
else
    fail "state dirs differ and exist" "rc=$rc_d a=$dir_a b=$dir_b"
fi
case "$dir_a" in "$SHARED_ROOT/afk/alpha-"*) pass "alpha state under <handover root>/afk/" ;; *) fail "alpha state under <handover root>/afk/" "$dir_a" ;; esac

echo "TEST: the key is the primary checkout's, the same from a worktree"
git -C "$A" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$A" worktree add -q "$TMP_ROOT/alpha-wt" -b wt
mkdir -p "$TMP_ROOT/alpha-wt/scripts"
cp -R "$A/scripts/afk" "$A/scripts/lib" "$TMP_ROOT/alpha-wt/scripts/"
key_a=$(inproj "$A" bash scripts/afk/project-state.sh key 2>&1)
key_wt=$(inproj "$TMP_ROOT/alpha-wt" bash scripts/afk/project-state.sh key 2>&1)
if [[ "$key_a" =~ ^alpha-[0-9]+$ ]] && [ "$key_a" = "$key_wt" ]; then pass "worktree key = primary key ($key_a)"; else fail "worktree key = primary key" "primary=$key_a worktree=$key_wt"; fi

echo "TEST: two --separate-git-dir projects whose git dirs share a parent keep two keys"
for p in sep1 sep2; do
    mkdir -p "$TMP_ROOT/$p" "$TMP_ROOT/gitdirs"
    git init -q -b main --separate-git-dir "$TMP_ROOT/gitdirs/$p.git" "$TMP_ROOT/$p"
    cp -R "$A/scripts" "$TMP_ROOT/$p/"
done
key_s1=$(inproj "$TMP_ROOT/sep1" bash scripts/afk/project-state.sh key 2>&1)
key_s2=$(inproj "$TMP_ROOT/sep2" bash scripts/afk/project-state.sh key 2>&1)
if [[ "$key_s1" =~ ^sep1-[0-9]+$ ]] && [[ "$key_s2" =~ ^sep2-[0-9]+$ ]] && [ "$key_s1" != "$key_s2" ]; then pass "separate git dirs keep their own keys"; else fail "separate git dirs keep their own keys" "sep1=$key_s1 sep2=$key_s2"; fi
git -C "$TMP_ROOT/sep1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$TMP_ROOT/sep1" worktree add -q "$TMP_ROOT/sep1-wt" -b wt
cp -R "$A/scripts" "$TMP_ROOT/sep1-wt/"
key_s1wt=$(inproj "$TMP_ROOT/sep1-wt" bash scripts/afk/project-state.sh key 2>&1)
if [ "$key_s1wt" = "$key_s1" ]; then pass "a separate-git-dir worktree shares its project's key"; else fail "a separate-git-dir worktree shares its project's key" "project=$key_s1 worktree=$key_s1wt"; fi

echo "TEST: a stop in one adopted project does not halt the other"
inproj "$A" bash scripts/afk/stop-marker.sh set >/dev/null 2>&1
if inproj "$A" bash scripts/afk/stop-marker.sh check; then pass "alpha sees its own stop"; else fail "alpha sees its own stop"; fi
rc=0; inproj "$B" bash scripts/afk/stop-marker.sh check || rc=$?
if [ "$rc" -eq 1 ]; then pass "beta not stopped by alpha"; else fail "beta not stopped by alpha" "rc=$rc"; fi

echo "TEST: a /stop from the himmel clone (the global marker) halts every adopted shift"
mkdir -p "$FAKE_HOME/.claude"; : > "$FAKE_HOME/.claude/.overnight-stop"
if inproj "$B" bash scripts/afk/stop-marker.sh check; then pass "beta halts on the global marker"; else fail "beta halts on the global marker"; fi
# A git that cannot name the common dir leaves the project key unresolvable.
FAIL_GIT="$TMP_ROOT/failgit"; mkdir -p "$FAIL_GIT"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'for a in "$@"; do [ "$a" = --git-common-dir ] && exit 128; done' \
    "exec $(command -v git) \"\$@\"" > "$FAIL_GIT/git"
chmod +x "$FAIL_GIT/git"
rc=0; inproj "$B" env PATH="$FAIL_GIT:$PATH" bash scripts/afk/stop-marker.sh check 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then pass "an unresolvable project still halts on the global marker"; else fail "an unresolvable project still halts on the global marker" "rc=$rc"; fi
rm -f "$FAKE_HOME/.claude/.overnight-stop"

echo "TEST: each adopted project writes its own morning report"
printf 'AAA-1\tfeat/a\t1\tdone\tok\n' > "$TMP_ROOT/rows-a.tsv"
printf 'BBB-1\tfeat/b\t2\tdone\tok\n' > "$TMP_ROOT/rows-b.tsv"
rc_ra=0; out_a=$(inproj "$A" bash scripts/afk/morning-report.sh --rows "$TMP_ROOT/rows-a.tsv" --no-unlanded 2>&1) || rc_ra=$?
rc_rb=0; out_b=$(inproj "$B" bash scripts/afk/morning-report.sh --rows "$TMP_ROOT/rows-b.tsv" --no-unlanded 2>&1) || rc_rb=$?
rep_a="$dir_a/overnight-report-$today.md"; rep_b="$dir_b/overnight-report-$today.md"
if [ "$rc_ra" -eq 0 ] && [ -f "$rep_a" ] && grep -q 'AAA-1' "$rep_a" && ! grep -q 'BBB-1' "$rep_a"; then pass "alpha report holds only alpha"; else fail "alpha report holds only alpha" "rc=$rc_ra $out_a"; fi
if [ "$rc_rb" -eq 0 ] && [ -f "$rep_b" ] && grep -q 'BBB-1' "$rep_b" && ! grep -q 'AAA-1' "$rep_b"; then pass "beta report holds only beta"; else fail "beta report holds only beta" "rc=$rc_rb $out_b"; fi

echo "TEST: a shift from the himmel clone keeps its current paths"
plan_c=$(inproj "$C" env JIRA_PROJECT_KEY=ZZZ bash scripts/afk/build-plan.sh 2>&1)
case "$plan_c" in *"HIMMEL-1"*) pass "clone queue stays HIMMEL" ;; *) fail "clone queue stays HIMMEL" "$plan_c" ;; esac
dir_c=$(inproj "$C" bash scripts/afk/project-state.sh dir 2>&1)
if [ "$dir_c" = /tmp ]; then pass "clone ledger stays in /tmp"; else fail "clone ledger stays in /tmp" "$dir_c"; fi
rm -f "$FAKE_HOME/.claude/.overnight-stop"
inproj "$C" bash scripts/afk/stop-marker.sh set >/dev/null 2>&1
if [ -f "$FAKE_HOME/.claude/.overnight-stop" ]; then pass "clone stop marker stays ~/.claude/.overnight-stop"; else fail "clone stop marker stays ~/.claude/.overnight-stop"; fi
out_c=$(inproj "$C" bash scripts/afk/morning-report.sh --rows "$TMP_ROOT/rows-a.tsv" --no-unlanded 2>&1)
if [ -f "$SHARED_ROOT/overnight-report-$today.md" ]; then pass "clone report stays at the handover root"; else fail "clone report stays at the handover root" "$out_c"; fi

echo
echo "per-project: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
