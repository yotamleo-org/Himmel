#!/usr/bin/env bash
# Smoke test for scripts/cr/pr-check-step0.sh.
#
# Runs the script under test against an isolated mktemp fixture only - never
# the real repo. The fixture's scripts/cr/pr-check-context.sh is a stub, so
# this test exercises pr-check-step0.sh's own HIMMEL_REPO handling and
# hand-off, not pr-check-context.sh's own logic (that has its own suite).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/pr-check-step0.sh"

pass=0
fail=0
check() {
    # $1 = got  $2 = want  $3 = label
    if [ "$1" = "$2" ]; then
        pass=$((pass + 1))
        echo "PASS: $3"
    else
        fail=$((fail + 1))
        echo "FAIL: $3 -- got '$1' want '$2'"
    fi
}
check_rc() {
    # $1 = got  $2 = want  $3 = label
    if [ "$1" -eq "$2" ]; then
        pass=$((pass + 1))
        echo "PASS: $3"
    else
        fail=$((fail + 1))
        echo "FAIL: $3 -- got rc=$1 want rc=$2"
    fi
}

tmp="$(mktemp -d -t test-pr-check-step0.XXXXXX)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/fixture"
mkdir -p "$fixture/scripts/cr"
cp "$SCRIPT" "$fixture/scripts/cr/pr-check-step0.sh"
cat >"$fixture/scripts/cr/pr-check-context.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub-pr-check-context: HIMMEL_REPO=$HIMMEL_REPO"
EOF
chmod +x "$fixture/scripts/cr/pr-check-context.sh"
run="$fixture/scripts/cr/pr-check-step0.sh"

# T1: HIMMEL_REPO unset -> fail closed, exit 2, remedy on stderr.
out1="$(env -u HIMMEL_REPO bash "$run" 2>&1)"
rc1=$?
check "$out1" "pr-check: HIMMEL_REPO is unset or empty — cannot locate himmel from a trusted source outside the repo under review; adopt/setup wires it into settings.json env, or export it non-empty in your launching shell, then re-run" "T1 unset HIMMEL_REPO prints remedy"
check_rc "$rc1" 2 "T1 unset HIMMEL_REPO exits 2"

# T2: HIMMEL_REPO set but empty -> same fail-closed remedy as unset.
out2="$(HIMMEL_REPO="" bash "$run" 2>&1)"
rc2=$?
check "$out2" "pr-check: HIMMEL_REPO is unset or empty — cannot locate himmel from a trusted source outside the repo under review; adopt/setup wires it into settings.json env, or export it non-empty in your launching shell, then re-run" "T2 empty HIMMEL_REPO prints remedy"
check_rc "$rc2" 2 "T2 empty HIMMEL_REPO exits 2"

# T3: HIMMEL_REPO set -> hands off to the anchor's pr-check-context.sh with
# HIMMEL_REPO still in its environment.
out3="$(HIMMEL_REPO="$fixture" bash "$run" 2>&1)"
rc3=$?
check "$out3" "stub-pr-check-context: HIMMEL_REPO=$fixture" "T3 set HIMMEL_REPO hands off to pr-check-context.sh"
check_rc "$rc3" 0 "T3 set HIMMEL_REPO exits 0 (stub's own exit)"

# T4-T6: the real pr-check-context.sh against a scratch ADOPTER repo
# (a temp clone, never HOME, never a real repo). No CR marker exists there, and the
# adopter lane must still be told to review against origin/<base> rather than stop.
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
adopter="$tmp/adopter"
# shellcheck source=../lib/git-clean.sh
. "$DIR/../lib/git-clean.sh"
git_env_scrub
setup_fail() { echo "FAIL: adopter fixture setup: $1"; exit 1; }
git init -q -b main "$adopter" || setup_fail init
git -C "$adopter" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "init" || setup_fail "initial commit"
git clone -q --bare "$adopter" "$tmp/adopter-origin.git" || setup_fail "bare clone"
git -C "$adopter" remote add origin "$tmp/adopter-origin.git" || setup_fail "remote add"
git -C "$adopter" fetch -q origin || setup_fail fetch
git -C "$adopter" checkout -q -b feat/x || setup_fail "feature checkout"
git -C "$adopter" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "feature" || setup_fail "feature commit"
git -C "$adopter" rev-parse -q --verify refs/remotes/origin/main >/dev/null || setup_fail "origin/main ref missing"
[ "$(git -C "$adopter" branch --show-current)" = "feat/x" ] || setup_fail "not on feat/x"

out4="$(cd "$adopter" && HIMMEL_REPO="$REPO_ROOT" bash "$SCRIPT" 2>/dev/null)"
rc4=$?
check_rc "$rc4" 0 "T4 adopter feature branch, no marker: step 0 exits 0"
case "$out4" in *"pr-check-context: anchor_lane=adopter"*) a_ok=yes ;; *) a_ok=no ;; esac
check "$a_ok" "yes" "T4 fixture resolves to the adopter lane"
case "$out4" in *"pr-check-context: no_marker_review=yes"*) nm=yes ;; *) nm=no ;; esac
check "$nm" "yes" "T5 adopter lane with no marker prints no_marker_review=yes"

# T6: on the default branch step 0 still refuses (exit 4), no marker or not.
git -C "$adopter" checkout -q main || setup_fail "main checkout"
(cd "$adopter" && HIMMEL_REPO="$REPO_ROOT" bash "$SCRIPT" >/dev/null 2>&1)
rc6=$?
check_rc "$rc6" 4 "T6 adopter default branch still refused with exit 4"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
