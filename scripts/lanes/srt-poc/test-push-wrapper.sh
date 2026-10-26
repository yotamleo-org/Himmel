#!/usr/bin/env bash
# shellcheck disable=SC2015
# Hermetic tests for push-wrapper.sh (POC): a local bare origin in a
# temp dir, no network, no credentials. Rows: one allowed push, then every
# refusal class the operator ruling names (force, +refspec, main, other
# branches) plus the delete / URL-remote shapes.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/push-wrapper.sh"
TMP="$(mktemp -d -t srt-poc-pw.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

ORIGIN="$TMP/origin.git"
WT="$TMP/wt"
git init -q --bare "$ORIGIN"
git init -q "$WT"
(
    cd "$WT" || exit 1
    git config user.email t@example.invalid
    git config user.name t
    git checkout -q -b main
    echo a > a.txt
    git add a.txt
    git commit -q -m base
    git remote add origin "$ORIGIN"
    git push -q origin main
    git checkout -q -b feat/mine
    echo b > b.txt
    git add b.txt
    git commit -q -m mine
) || { echo "FAIL fixture setup"; exit 1; }

origin_ref() { git --git-dir="$ORIGIN" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || echo none; }
MAIN_BEFORE="$(origin_ref main)"

run() { (cd "$WT" && bash "$SUT" --worker-branch feat/mine -- "$@") >"$TMP/out" 2>&1; }

# allowed: own branch
if run origin feat/mine && [ "$(origin_ref feat/mine)" = "$(git -C "$WT" rev-parse HEAD)" ]; then
    ok "own branch push lands"
else
    bad "own branch push lands ($(cat "$TMP/out"))"
fi

refused() { # <name> <args...>
    name="$1"
    shift
    before="$(origin_ref feat/mine)|$(origin_ref main)|$(origin_ref feat/other)"
    run "$@"
    rc=$?
    after="$(origin_ref feat/mine)|$(origin_ref main)|$(origin_ref feat/other)"
    if [ "$rc" -eq 20 ] && [ "$before" = "$after" ]; then ok "refuses $name"; else bad "refuses $name (rc=$rc, refs $before -> $after)"; fi
}

(cd "$WT" && git commit -q --amend -m rewritten)
refused "--force" --force origin feat/mine
refused "-f" -f origin feat/mine
refused "--force-with-lease" --force-with-lease origin feat/mine
refused "+refspec" origin +feat/mine:feat/mine
refused "push to main" origin HEAD:main
refused "push to master" origin HEAD:master
refused "another branch" origin HEAD:feat/other
refused "delete via :ref" origin :feat/mine
refused "--delete" --delete origin feat/mine
refused "URL remote" "$ORIGIN" feat/mine
refused "--mirror" --mirror origin

[ "$(origin_ref main)" = "$MAIN_BEFORE" ] && ok "main untouched" || bad "main untouched"

echo "fails=$fails"
[ "$fails" -eq 0 ]
