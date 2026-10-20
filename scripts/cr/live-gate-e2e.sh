#!/usr/bin/env bash
# scripts/cr/live-gate-e2e.sh — on-demand LIVE end-to-end of the review gate
# against a REAL throwaway GitHub repo.
#
# Drives one canned PR through: open; a posted review finding blocks
# (ready-check check 3); the CR ledger row lands (check 4); resolving the thread
# clears it; ready-check PASSes; merge-on-green --dry-run, run as a console leg,
# REFUSES and the PR stays OPEN. The shell suites only ever see stubbed gh; this
# is the one run against the real API.
#
# Usage: bash scripts/cr/live-gate-e2e.sh [--repo <owner/name>]
#   default repo: yotamleo/himmel-gate-e2e (private; created when absent).
# Env: HIMMEL_REPO (required, the primary checkout: ledger-append and
#      merge-on-green run from its copy). E2E_WORKDIR overrides the clone dir
#      (default <worktree>/.himmel-scratch/gate-e2e).
# Never runs in CI (refuses when CI or GITHUB_ACTIONS is set) and never targets
# himmel itself (refuses any repo named Himmel or the anchor's own origin).
# Idempotent: reuses the repo and clone, closes leftover test/e2e-* PRs first.
# The repo is NOT deleted at the end; delete it with
#   gh repo delete <owner/name> --yes
#
# Known ceiling: on a free-plan private repo both required-check reads return
# HTTP 403, so merge-on-green refuses at check-ci (exit 18) before its GO gate;
# the GO leg is therefore not reachable here (follow-up tickets in the PR).
# ponytail: refusal leg only, merge-with-GO needs a plan that can read rules.
# Platform guard: bash 3.2+; Linux/macOS only.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

REPO="yotamleo/himmel-gate-e2e"
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || { echo "live-gate-e2e: --repo needs owner/name" >&2; exit 2; }
            REPO="$2"; shift 2 ;;
        *) echo "usage: live-gate-e2e.sh [--repo <owner/name>]" >&2; exit 2 ;;
    esac
done

case "${CI:-}${GITHUB_ACTIONS:-}" in
    ''|0|false) ;;
    *) echo "live-gate-e2e: refusing to run in CI — on-demand only" >&2; exit 2 ;;
esac
case "$REPO" in
    ''|*[!A-Za-z0-9._/-]*|*/*/*|/*|*/) echo "live-gate-e2e: bad --repo '$REPO'" >&2; exit 2 ;;
    */*) ;;
    *) echo "live-gate-e2e: --repo must be owner/name" >&2; exit 2 ;;
esac
case "$(printf '%s' "${REPO#*/}" | tr '[:upper:]' '[:lower:]')" in
    himmel|himmel-private) echo "live-gate-e2e: refusing to target himmel itself ($REPO)" >&2; exit 2 ;; # leak-allow: hostname repo name, not a host
esac
ANCHOR="${HIMMEL_REPO:-}"
[ -n "$ANCHOR" ] && [ -f "$ANCHOR/scripts/cr/ledger-append.sh" ] || {
    echo "live-gate-e2e: HIMMEL_REPO must name the primary himmel checkout" >&2; exit 2; }
anchor_nwo=$(git -C "$ANCHOR" remote get-url origin 2>/dev/null | sed -n 's|.*github.com[:/]\([^ ]*\)$|\1|p' | sed 's|\.git$||')
repo_lc=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
anchor_lc=$(printf '%s' "$anchor_nwo" | tr '[:upper:]' '[:lower:]')
[ -z "$anchor_lc" ] || [ "$anchor_lc" != "$repo_lc" ] || {
    echo "live-gate-e2e: refusing to target the anchor's own origin ($REPO)" >&2; exit 2; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/prim.sh
. "$SELF_DIR/../lib/prim.sh" || exit 2
READY="$TREE/scripts/handover/console-kit/ready-check.sh"
WORK="${E2E_WORKDIR:-$TREE/.himmel-scratch/gate-e2e}"
BRANCH="test/e2e-$(date +%Y%m%d-%H%M%S)"
FAILS=0
step() { printf '\n== %s\n' "$*"; }
expect() { # <label> <want-rc> <got-rc>
    if [ "$2" = "$3" ]; then echo "[OK]   $1 (rc=$3)"; else
        echo "[FAIL] $1: want rc=$2 got rc=$3"; printf '%s\n' "${READY_OUT:-}" | grep '^\[FAIL\]'; FAILS=$((FAILS + 1)); fi
}
# A fresh snapshot cache per ready-check: the shared one is head-keyed with a
# 60s TTL, so a thread resolve would not show up on a re-run otherwise.
ready() { # <pr> <head>
    local d; d=$(tmpdir) || return 99
    GH_PR_SNAPSHOT_CACHE_DIR="$d" bash "$READY" "$@" >"$d/out" 2>&1
    local rc=$?; READY_OUT=$(cat "$d/out"); rm -rf "$d"; return $rc
}

step "repo $REPO"
if ! gh repo view "$REPO" --json name >/dev/null 2>&1; then
    gh repo create "$REPO" --private --add-readme \
        --description "Throwaway fixture repo for himmel HIMMEL-5232 review-gate live e2e" >/dev/null || { echo "create failed" >&2; exit 1; }
fi
priv=$(gh repo view "$REPO" --json isPrivate --jq .isPrivate)
[ "$priv" = "true" ] || { echo "live-gate-e2e: $REPO is not private — refusing" >&2; exit 2; }

step "clone + close leftovers"
if [ -d "$WORK/.git" ]; then
    work_nwo=$(git -C "$WORK" remote get-url origin 2>/dev/null | sed -n 's|.*github.com[:/]\([^ ]*\)$|\1|p' | sed 's|\.git$||')
    [ "$(printf '%s' "$work_nwo" | tr '[:upper:]' '[:lower:]')" = "$repo_lc" ] || { echo "live-gate-e2e: $WORK is not a clone of $REPO (origin=${work_nwo:-none}) — refusing to reset it" >&2; exit 2; }
    [ -z "$(git -C "$WORK" status --porcelain 2>/dev/null)" ] || { echo "live-gate-e2e: $WORK has uncommitted changes — refusing to reset it" >&2; exit 2; }
    git -C "$WORK" fetch -q origin || exit 1
    [ -z "$(git -C "$WORK" rev-list origin/main..main 2>/dev/null)" ] || { echo "live-gate-e2e: $WORK has local-only commits on main — refusing to reset it" >&2; exit 2; }
    git -C "$WORK" checkout -q main && git -C "$WORK" reset -q --hard origin/main || exit 1
else
    mkdir -p "$(dirname "$WORK")" && git clone -q "https://github.com/$REPO.git" "$WORK" || exit 1
fi
for n in $(gh pr list --repo "$REPO" --state open --json number,headRefName --jq '.[] | select(.headRefName | startswith("test/e2e-")) | .number'); do
    gh pr close "$n" --repo "$REPO" --delete-branch >/dev/null 2>&1 && echo "closed leftover PR #$n"
done

step "open canned PR"
cd "$WORK" || exit 1
git checkout -q -b "$BRANCH" || exit 1
printf 'canned fixture line %s\n' "$BRANCH" > canned.txt
git add canned.txt
git commit -q -m "test: [HIMMEL-5232] canned fixture line" \
    --trailer "Platforms tested: linux" --trailer "Security reviewed: manual — fixture text only" || exit 1
git push -q -u origin "$BRANCH" || exit 1
body=$(mktemp "${TMPDIR:-/tmp}/e2e-body.XXXXXX") || exit 1
printf 'Canned PR for the live review-gate e2e.\n\n## Ticket coverage\n- canned fixture: done\n' > "$body"
pr_url=$(gh pr create --repo "$REPO" --base main --head "$BRANCH" --title "test: [HIMMEL-5232] canned e2e PR" --body-file "$body")
rm -f "$body"
PR="${pr_url##*/}"
# A failed run still closes its canned PR (the final close below is explicit).
trap 'gh pr close "$PR" --repo "$REPO" --delete-branch >/dev/null 2>&1' EXIT
HEAD_SHA=$(git rev-parse HEAD)
echo "PR #$PR head $HEAD_SHA"

step "no ledger row yet: ready-check must FAIL on check 4"
ready "$PR" "$HEAD_SHA"; rc=$?
case "$READY_OUT" in *"[FAIL] 4."*) ;; *) rc=99 ;; esac
expect "ready-check without a ledger row" 1 $rc

step "post a review finding: it must block"
rj=$(mktemp "${TMPDIR:-/tmp}/e2e-review.XXXXXX") || exit 1
printf '{"commit_id":"%s","event":"COMMENT","body":"canned e2e review","comments":[{"path":"canned.txt","line":1,"side":"RIGHT","body":"Canned finding."}]}\n' "$HEAD_SHA" > "$rj"
gh api "repos/$REPO/pulls/$PR/reviews" --input "$rj" >/dev/null || { echo "review post failed" >&2; exit 1; }
rm -f "$rj"
bash "$ANCHOR/scripts/cr/ledger-append.sh" avail --branch "$BRANCH" --head "$HEAD_SHA" --model canned-critic --status ok
ready "$PR" "$HEAD_SHA"; rc=$?
case "$READY_OUT" in *"[FAIL] 3."*) ;; *) rc=99 ;; esac
expect "ready-check with an open thread (check 3)" 1 $rc

step "resolve the thread: ready-check must PASS"
tid=$(gh api graphql -f query="query{repository(owner:\"${REPO%%/*}\",name:\"${REPO#*/}\"){pullRequest(number:$PR){reviewThreads(first:10){nodes{id}}}}}" --jq '.data.repository.pullRequest.reviewThreads.nodes[0].id')
gh api graphql -f query="mutation{resolveReviewThread(input:{threadId:\"$tid\"}){thread{isResolved}}}" >/dev/null || { echo "resolve failed" >&2; exit 1; }
# The repo's own status context (CodeRabbit) posts asynchronously and re-pends
# after a review lands; ready-check check 1/2 needs it settled. Require three
# consecutive CLEAN reads, 5s apart, within 3 minutes.
n=0; clean=0
while [ "$n" -lt 36 ] && [ "$clean" -lt 3 ]; do
    mss=$(gh pr view "$PR" --repo "$REPO" --json mergeStateStatus --jq .mergeStateStatus)
    if [ "$mss" = "CLEAN" ]; then clean=$((clean + 1)); else clean=0; fi
    n=$((n + 1)); sleep 5
done
echo "mergeStateStatus=$mss, settled after $((n * 5))s"
ready "$PR" "$HEAD_SHA"; expect "ready-check after resolve" 0 $?

step "merge-on-green as a console leg with no GO: must refuse and leave the PR open"
# merge-on-green's MERGE-BLOCKED alert would DM the operator (a refusal on a
# throwaway PR is the expected outcome, not an incident). MERGE_BLOCK_ALERT_CMD
# replaces the sender: point it at a recorder so the alert is intercepted, never
# sent, and the run can assert it was intercepted.
sink=$(mktemp "${TMPDIR:-/tmp}/e2e-alert-sink.XXXXXX") || exit 1
# shellcheck disable=SC2016 # the stub's $2 must stay literal
printf '#!/bin/sh\nprintf "%%s\\n" "$2" >> "%s.log"\n' "$sink" > "$sink"
chmod 700 "$sink"
MERGE_BLOCK_ALERT_CMD="$sink" ARMAUTOMERGE=1 HIMMEL_CONSOLE_LEG=1 bash "$ANCHOR/scripts/handover/merge-on-green.sh" "$PR" --dry-run >/dev/null 2>&1
rc=$?
if [ -s "$sink.log" ]; then echo "[OK]   MERGE-BLOCKED alert intercepted, not sent"; else echo "[WARN] no alert reached the recorder (nothing was sent either)"; fi
rm -f "$sink" "$sink.log"
case "$rc" in 17|18) echo "[OK]   merge-on-green refused (rc=$rc; 18 = check-ci cannot read required set, 17 = no GO)" ;;
    *) echo "[FAIL] merge-on-green: want rc 17 or 18, got $rc"; FAILS=$((FAILS + 1)) ;; esac
state=$(gh pr view "$PR" --repo "$REPO" --json state --jq .state)
if [ "$state" = "OPEN" ]; then echo "[OK]   PR #$PR still OPEN"; else echo "[FAIL] PR #$PR state=$state"; FAILS=$((FAILS + 1)); fi

step "cleanup: close the canned PR"
if gh pr close "$PR" --repo "$REPO" --delete-branch >/dev/null 2>&1; then echo "[OK]   canned PR #$PR closed"; else
    echo "[FAIL] could not close PR #$PR — close it by hand: gh pr close $PR --repo $REPO"; FAILS=$((FAILS + 1)); fi

if [ "$FAILS" -eq 0 ]; then echo; echo "LIVE-GATE-E2E PASS"; exit 0; fi
echo; echo "LIVE-GATE-E2E FAIL ($FAILS)"; exit 1
