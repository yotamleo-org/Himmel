#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # single-quoted $ text is literal on purpose; P<n>_CMD are read by name below
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
# shellcheck source=../lib/override-env.sh
. "$REPO/scripts/lib/override-env.sh"
scrub_override_env
HOOK="$HERE/guard-judge-write-scope.sh"
LAUNCHER="$HERE/run-hook-with-bash.js"
SETTINGS="$REPO/.claude/settings.json"
JUDGE_DIR_SH="$REPO/scripts/judge-dir.sh"
WRITE_VERDICT="$REPO/scripts/handover/chief-kit/write-verdict.sh"
HEAD40=0123456789abcdef0123456789abcdef01234567

for t in jq node git; do
    command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t not on PATH"; exit 1; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/judge-write-scope.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
T=$(cd -P "$T" && pwd -P)
ROOTS=""
cleanup() {
    local r
    for r in $ROOTS; do
        if [ -L "$r" ]; then rm -f "$r"; elif [ -d "$r" ]; then chmod -R u+rwx "$r" 2>/dev/null; rm -rf "$r"; fi
    done
    rm -rf "$T"
}
trap cleanup EXIT

REAL_ID=$(command -v id)
REAL_UID=$("$REAL_ID" -u)
mkdir -p "$T/bin" "$T/nojq"
printf '#!/bin/sh\nif [ "$#" = 1 ] && [ "$1" = -u ] && [ -n "${FX_UID:-}" ]; then echo "$FX_UID"; exit 0; fi\nexec %s "$@"\n' \
    "$REAL_ID" > "$T/bin/id"
chmod +x "$T/bin/id"
cp "$T/bin/id" "$T/nojq/id"

NEXT_UID=$((60000 + ($$ % 4000) * 4))
new_root() {
    while [ -e "/tmp/claude-$NEXT_UID" ] || [ -L "/tmp/claude-$NEXT_UID" ] || [ "$NEXT_UID" = "$REAL_UID" ]; do
        NEXT_UID=$((NEXT_UID + 1))
    done
    mkdir -m "$1" "/tmp/claude-$NEXT_UID" || { echo "FATAL: cannot create /tmp/claude-$NEXT_UID"; exit 1; }
    ROOTS="$ROOTS /tmp/claude-$NEXT_UID"
    NEW_UID=$NEXT_UID
    NEXT_UID=$((NEXT_UID + 1))
}

chain_cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit|NotebookEdit") | .hooks[].command' "$SETTINGS")
MEMBERS=()
for w in $(printf '%s\n' "${chain_cmd#*; else }" | grep -o '\$CLAUDE_PROJECT_DIR/scripts/hooks/[A-Za-z0-9._-]*\.sh'); do
    MEMBERS+=("$REPO/${w#\$CLAUDE_PROJECT_DIR/}")
done
[ "${#MEMBERS[@]}" -ge 2 ] || { echo "FATAL: no Edit|Write|MultiEdit|NotebookEdit chain read from $SETTINGS"; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

wpayload() {
    jq -cn --arg at "$1" --arg aid "$2" --arg tool "$3" --arg p "$4" --arg c "${5:-evidence}" --arg cwd "$REPO" '
        {hook_event_name: "PreToolUse", cwd: $cwd, tool_name: $tool,
         tool_input: (if $tool == "NotebookEdit" then {notebook_path: $p, new_source: $c}
                      elif $tool == "Edit" then {file_path: $p, old_string: "evidence", new_string: $c}
                      elif $tool == "MultiEdit" then {file_path: $p, edits: [{old_string: "evidence", new_string: $c}]}
                      elif $tool == "Read" then {file_path: $p}
                      else {file_path: $p, content: $c} end)}
        + (if $at == "-" then {} else {agent_type: $at} end)
        + (if $aid == "-" then {} else {agent_id: $aid} end)'
}

run_chain() {
    local label=$1 payload=$2
    shift 2
    printf '%s' "$payload" | env -u HIMMEL_CONSOLE_LEG -u HIMMEL_HOLD_KEY -u HIMMEL_HOLD_DOC -u HIMMEL_CONSOLE_RELAY \
        -u JUDGE_WRITE_SCOPE_OK PATH="$T/bin:$PATH" CLAUDE_PROJECT_DIR="$REPO" FX_UID="$FXU" "$@" \
        node "$LAUNCHER" --chain "${MEMBERS[@]}" > "$T/out-$label" 2> "$T/err-$label"
    RC=$?
}

run_fence() {
    local label=$1 payload=$2
    shift 2
    printf '%s' "$payload" | env -u JUDGE_WRITE_SCOPE_OK PATH="$T/bin:$PATH" FX_UID="$FXU" "$@" \
        bash "$HOOK" > "$T/out-$label" 2> "$T/err-$label"
    RC=$?
}

fence_named() { grep -q 'guard-judge-write-scope' "$T/out-$1" "$T/err-$1" 2>/dev/null; }

fence_denies() {
    local label=$1
    run_chain "$@"
    if [ "$RC" = 2 ] && fence_named "$label"; then
        ok "$label (chain rc 2, the fence's deny)"
    else
        bad "$label: want the fence's deny (chain rc 2), got rc=$RC: $(head -c 300 "$T/err-$label")"
    fi
}

chain_allows() {
    local label=$1
    run_chain "$@"
    if [ "$RC" = 0 ] && ! fence_named "$label"; then
        ok "$label (chain rc 0, no fence output)"
    else
        bad "$label: want chain rc 0 with no fence output, got rc=$RC: $(head -c 300 "$T/err-$label")"
    fi
}

fence_silent() {
    local label=$1
    run_fence "$@"
    if [ "$RC" = 0 ] && [ ! -s "$T/out-$label" ] && [ ! -s "$T/err-$label" ]; then
        ok "$label (the fence alone: exit 0, no output)"
    else
        bad "$label: want the fence alone silent with exit 0, got rc=$RC: $(head -c 300 "$T/out-$label" "$T/err-$label")"
    fi
}

new_root 700
FXU=$NEW_UID
FXROOT="/tmp/claude-$FXU"
mkdir -p "$T/no-sessions" "$T/home"
judge_dir() {
    env -u TMP_REAP_TMP_ROOT PATH="$T/bin:$PATH" FX_UID="${2:-$FXU}" TMP_REAP_SESSIONS_DIR="$T/no-sessions" \
        bash "$JUDGE_DIR_SH" "$1"
}
JD=$(judge_dir 9101) || { echo "FATAL: judge-dir.sh made no dir"; exit 1; }
[ "$JD" = "$FXROOT/j9101" ] || { echo "FATAL: judge-dir.sh made $JD, not $FXROOT/j9101"; exit 1; }
printf 'evidence\n' > "$JD/evidence.md"

git init -q "$T/repo"
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/repo" worktree add -q -b feat/x "$T/repo-wt" 2>/dev/null || { echo "FATAL: no fixture worktree"; exit 1; }
WT="$T/repo-wt"

git init -q "$T/primary"
mkdir -p "$T/primary/.claude"
printf '{}\n' > "$T/primary/.claude/settings.json"
git -C "$T/primary" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

echo "=== W: a judge-ro write anywhere but a .md/.txt file directly in a judge dir is refused by the fence"
fence_denies W1-worktree-file "$(wpayload judge-ro aj1 Write "$WT/notes.md")"
fence_denies W2-root "$(wpayload judge-ro aj1 Write "$FXROOT/evidence.md")"
fence_denies W2b-plugin-scoped-type "$(wpayload himmel-ops:judge-ro aj1 Write "$WT/notes.md")"
mkdir -m 700 "$FXROOT/j9103"
fence_denies W3-no-holder "$(wpayload judge-ro aj1 Write "$FXROOT/j9103/evidence.md")"
JD4=$(judge_dir 9104) && : > "$JD4/.verdict-written"
fence_denies W4-released-dir "$(wpayload judge-ro aj1 Write "$FXROOT/j9104/evidence.md")"
ln -s "$JD" "$FXROOT/j9105"
fence_denies W5-symlinked-judge-dir "$(wpayload judge-ro aj1 Write "$FXROOT/j9105/evidence.md")"
mkdir -m 700 "$FXROOT/j9106"
ln -s "$JD/.holder" "$FXROOT/j9106/.holder"
fence_denies W5b-symlinked-holder "$(wpayload judge-ro aj1 Write "$FXROOT/j9106/evidence.md")"
run_fence W6-dotdot "$(wpayload judge-ro aj1 Write "$JD/../j9101/evidence.md")"
if [ "$RC" = 2 ] && fence_named W6-dotdot; then
    ok "W6-dotdot (the fence alone: rc 2, the fence's deny)"
else
    bad "W6-dotdot: want the fence's own deny (rc 2), got rc=$RC: $(head -c 300 "$T/err-W6-dotdot")"
fi
run_chain W6-dotdot-chain "$(wpayload judge-ro aj1 Write "$JD/../j9101/evidence.md")"
if [ "$RC" = 2 ] && grep -q 'block-unexpanded-file-path: the file path is not in the form' "$T/err-W6-dotdot-chain"; then
    ok "W6-dotdot-chain (chain rc 2, the long-path guard's form deny comes first)"
else
    bad "W6-dotdot-chain: want the long-path guard's form deny (chain rc 2), got rc=$RC: $(head -c 300 "$T/err-W6-dotdot-chain")"
fi
fence_denies W7-sh-name "$(wpayload judge-ro aj1 Write "$JD/evidence.sh")"
mkdir -p "$T/hroot/tuser/himmel/verdicts/Hj9101a"
fence_denies W8-verdicts-under-handover-root "$(wpayload judge-ro aj1 Write "$T/hroot/tuser/himmel/verdicts/Hj9101a/judge.md")"
fence_denies W9-edit "$(wpayload judge-ro aj1 Edit "$JD/evidence.md")"
fence_denies W10-multiedit "$(wpayload judge-ro aj1 MultiEdit "$JD/evidence.md")"
fence_denies W10b-notebookedit "$(wpayload judge-ro aj1 NotebookEdit "$JD/evidence.ipynb")"
fence_denies W11-agent-id-no-agent-type "$(wpayload - aj1 Write "$WT/notes.md")"
fence_denies W11b-agent-type-false "$(wpayload - aj1 Write "$WT/notes.md" | jq -c '.agent_type = false')"

printf '%s' "$(wpayload judge-ro aj1 Write "$JD/evidence.md")" \
    | env -u JUDGE_WRITE_SCOPE_OK PATH="$T/nojq" FX_UID="$FXU" "$BASH" "$HOOK" > "$T/out-W12" 2> "$T/err-W12"
RC=$?
if [ "$RC" = 2 ] && grep -q '"permissionDecision":"deny"' "$T/out-W12"; then
    ok "W12-no-jq (the fence alone: exit 2 with a deny decision)"
else
    bad "W12-no-jq: want exit 2 with a deny decision, got rc=$RC: $(head -c 300 "$T/err-W12")"
fi
printf '%s' "$(wpayload brief-drafter ab1 Write "$WT/notes.md")" \
    | env -u JUDGE_WRITE_SCOPE_OK PATH="$T/nojq" FX_UID="$FXU" "$BASH" "$HOOK" > "$T/out-W12c" 2> "$T/err-W12c"
RC=$?
if [ "$RC" = 0 ] && [ ! -s "$T/out-W12c" ]; then
    ok "W12c-no-jq-other-caller (the fence alone: exit 0, no decision)"
else
    bad "W12c-no-jq-other-caller: want exit 0 with no output, got rc=$RC: $(head -c 300 "$T/out-W12c")"
fi

new_root 755
U13=$NEW_UID
JD13=$(judge_dir 9113 "$U13") || { echo "FATAL: no judge dir under the 0755 root"; exit 1; }
fence_denies W13-root-mode-0755 "$(wpayload judge-ro aj1 Write "$JD13/evidence.md")" FX_UID="$U13"
mkdir -p "$JD/sub"
fence_denies W14-nested-subdir "$(wpayload judge-ro aj1 Write "$JD/sub/evidence.md")"
printf 'x\n' > "$T/elsewhere.md"
ln -s "$T/elsewhere.md" "$JD/link.md"
fence_denies W14b-target-is-symlink "$(wpayload judge-ro aj1 Write "$JD/link.md")"
printf 'x\n' > "$T/outside-hl.md"
ln "$T/outside-hl.md" "$JD/hl.md" || { echo "FATAL: cannot hard-link into the fixture judge dir"; exit 1; }
fence_denies W14c-target-is-hard-link "$(wpayload judge-ro aj1 Write "$JD/hl.md")"
rm -f "$T/outside-hl.md"
fence_silent W14d-hard-link-count-back-to-one "$(wpayload judge-ro aj1 Write "$JD/hl.md")"

if grep -q 'bash .*/scripts/judge-dir.sh' "$T/err-W1-worktree-file" && grep -q 'JUDGE_WRITE_SCOPE_OK=1' "$T/err-W1-worktree-file"; then
    ok "W1 deny text names judge-dir.sh and the single-run bypass"
else
    bad "W1 deny text must name 'bash <primary checkout>/scripts/judge-dir.sh <PR>' and JUDGE_WRITE_SCOPE_OK=1: $(head -c 400 "$T/err-W1-worktree-file")"
fi
run_fence W1-bypass "$(wpayload judge-ro aj1 Write "$WT/notes.md")" JUDGE_WRITE_SCOPE_OK=1
if [ "$RC" = 0 ] && [ ! -s "$T/out-W1-bypass" ]; then
    ok "W1-bypass (JUDGE_WRITE_SCOPE_OK=1: the fence exits 0 with no decision)"
else
    bad "W1-bypass: want exit 0 with no decision, got rc=$RC"
fi

echo "=== A: every other caller is untouched"
chain_allows A1-brief-drafter-worktree "$(wpayload brief-drafter ab1 Write "$WT/notes.md")"
chain_allows A2-main-session-judge-dir "$(wpayload - - Write "$JD/evidence.md")"
chain_allows A2b-main-session-worktree "$(wpayload - - Write "$WT/notes.md")"
chain_allows A3-explore-read "$(wpayload Explore ae1 Read "$WT/notes.md")"
chain_allows A4-judge-ro-own-judge-dir "$(wpayload judge-ro aj1 Write "$JD/evidence.md")"
if [ -f "$HOOK" ]; then
    fence_silent A1-fence-alone "$(wpayload brief-drafter ab1 Write "$WT/notes.md")"
    fence_silent A2-fence-alone "$(wpayload - - Write "$WT/notes.md")"
    fence_silent A3-fence-alone "$(wpayload Explore ae1 Read "$WT/notes.md")"
    fence_silent A4-fence-alone "$(wpayload judge-ro aj1 Write "$JD/evidence.md")"
else
    bad "A1-A4 fence-alone rows: $HOOK is absent"
fi

echo "=== P1-P10: replayed refused evidence writes"
IFS= read -r -d '' P1_CMD <<'P_END' || true
cat > /tmp/claude-@UID@/j5328/evidence-Hj5328a.md <<'EOF'
Head pinning: gh pr view 5328 headRefOid = 09891a8a95f012efba6e0823ae1471e6c27338b3; git cat-file -t prints commit. All reads by full sha (git diff origin/main...<sha>, git show <sha>:<path>).
A3, keep lists (Evidence 1): at head, .claude/agents/comment-sicko.md's keep list has five items (legal headers, external-dependency behaviour, prettier-ignore and lint suppressions, API doc comments, issue/RFC links). The marker item is removed. The new paragraph sends an accepted limitation to the ceilings ledger and calls a comment that records one meat. The header's deviation list declares the new line. no-comments/SKILL.md deviation item 4 now says the keep list has no himmel addition. I read both files in full and found no exemption left. marketplace/plugins/himmel-ops/agents/comment-review.md reads the charter and has no keep list of its own. The enforcement.md no-history-comments row now names the refusal. I checked its wording against scripts/lint/ticket-refs.awk:142 (the word and colon, any case, diff mode, outside a whole-file row) and scripts/lint/check-history-comments.sh:93-95 (the refusal text names ceiling-add.sh add). The wording is accurate.
EOF
echo written
P_END
IFS= read -r -d '' P2_CMD <<'P_END' || true
cat > /tmp/claude-@UID@/j5322/evidence-Gj5322a.md <<'EOF'
- gh pr view 5322 headRefOid = ce2f284579ecffd009f78d9513052a7039a503b6; git cat-file -t = commit.
- PR worktree .claude/worktrees/fix+himmel-9914-guard-empty-expansion-escaped-dollar: git status --porcelain is empty and HEAD = ce2f2845 (full sha). The lib's sha256 there matches git show <head>:scripts/lib/guard-empty-expansion.sh (4536a17f...). The primary checkout's lib matches git show <merge-base>:... (cf763781...). The primary is clean under scripts/hooks and scripts/lib.
EOF
wc -l /tmp/claude-@UID@/j5322/evidence-Gj5322a.md
P_END
IFS= read -r -d '' P3_CMD <<'P_END' || true
cat > /tmp/claude-@UID@/j5308e/evidence.md <<'EOF'
A2, overlapping files: git diff origin/main...9d03 --stat touches 4 files: scripts/cr/critic-panel.sh, panel-first-pass.sh, review-round.sh and the new test-panel-first-pass-pr-base.sh. None of them is in main's 58-file name list for 5e230d68..f37ae7b9, so the sides share no file and nothing needed resolving. That fits the handover's "merged forward clean" (Evidence 4) and the PR body has no "## Conflicts resolved" section. The body's line "Merge-forward: not needed at this head" is out of date at 9d03; it is prose only (out of scope, a nit).
EOF
bash @REPO@/scripts/handover/chief-kit/write-verdict.sh Gj5308e GO 9d030018605b3ae72997500b63938ff51f98ce1a --pr 5308 --evidence-file /tmp/claude-@UID@/j5308e/evidence.md --model claude-opus-5-5 --effort high
P_END
IFS= read -r -d '' P4_CMD <<'P_END' || true
cat > /tmp/claude-@UID@/j5329/evidence-Hj5329a.md <<'EOF'
A4 outside fixture edits. judge-call.test.mjs:244, test-pr-check-rounds.sh:2919, test-auto-go.sh:174, test-headed-arm-worker.sh:2930 (row 26), test-merge-on-green.sh:3594 (go_write): each only adds HIMMEL_REPO=<the fixture repo the test already cd's into>; no assertion is added, removed or changed. In test-go.sh the 4565 "outside any repo -> exit 4" row keeps its meaning by setting HIMMEL_REPO=$ROOT14 (non-repo); go27/go29/go29q add the same token.
A5 RED/GREEN. New rows: test-go.sh section 32 (nowhere, decoy origin other/luna, checkout; GO written, rc 0), test-chief-wait.sh (rdy-cwd: ready-check and cr-disposition cwd = HIMMEL_REPO, gh pr checks -R o/x), test-verdict-go.sh section 10 (steps run in HIMMEL_REPO, relative --doc is caller path, relative HIMMEL_REPO rc 2), test-write-verdict.sh 27 and 31 (bind PR read names the gated origin from a non-repo cwd; --delta-noop from a non-repo cwd classifies in HIMMEL_REPO). The worker doc's RED counts at base b44b63bd8 (go 4, write-verdict 7, verdict-go 3, chief-wait 3) match what the rows would fail on main by my reading (go: nowhere+decoy x 2 checks; verdict-go: nowhere cwd, relative doc, relative HIMMEL_REPO; chief-wait: rc.cwd, disp.cwd, -R). test-write-verdict row 31 first case runs without HIMMEL_REPO, so the default (script's own primary) branch is exercised. headed-arm-worker 16-row SKIP: only row 26 of that suite invokes go.sh, and headed-arm-worker.sh calls none of the four scripts, so the other rows cannot be moved by this diff; the worker's base comparison is credible but I did not reproduce it.
EOF
echo written
P_END
IFS= read -r -d '' P5_CMD <<'P_END' || true
mkdir -p @HOME@/.cache/himmel/verdicts/j5161xy/scratch && cat > @HOME@/.cache/himmel/verdicts/j5161xy/scratch/evidence.md <<'EOF'
- Test files: a word-diff of scripts/test-* and himmel-bus/tests shows only words inside assert/check/pass/fail/run_launcher_expect/test() labels, SKIP echo text, trailing comments, and three removed comment lines change. test-claude-deepseek.sh: with the test() name stripped, the old and new bodies are byte-identical (A5 confirmed: names only, plus nothing else).
- test-uninstall-ux.sh w1_writer args: the case arm matches PENDING\(*\) and both new strings still start PENDING( and end ), and that branch only prints a pass label. test-uninstall-real-home-callers.sh ALLOW_WHY is read only as a non-empty check (line 470). test-clean-stray-sweep.sh fake find stderr text: no assert reads it (lines 270-295 match other strings).
EOF
echo written; wc -l @HOME@/.cache/himmel/verdicts/j5161xy/scratch/evidence.md
P_END
IFS= read -r -d '' P6_CMD <<'P_END' || true
cat > /tmp/claude-@UID@/j5163/evidence.md <<'EOF'
- The two names elsewhere: himmel-doctor.sh plus test-himmel-doctor.sh use HimmelTelegramBridge as an observability expected_tasks registry name for the C24 systemd probe. That code is independent of the capture list. uninstall.sh:330 and test-uninstall-ux.sh:304 name them on purpose. himmelctl test-wizard-luna-sections.sh:484 and test-wizard-statusreport.sh:740 do not read EXTRA_KNOWN_TASKS. None is left broken.
Q4 trust paths: no. No pattern in scripts/ci/ci-trust-paths.txt at head matches scripts/install/.
EOF
echo written
P_END
IFS= read -r -d '' P7_CMD <<'P_END' || true
cat > /tmp/claude-@UID@/j5165/evidence-j5165xz.md <<'EOF'
F3 (nit). In JS, `[^ ]` matches a newline, so `- DISPOSITION N1 parked ` with a trailing space clears in board.ts. grep -c in tick.sh does not clear it, so the board would drop a row the tick still wakes on. Under-listing only.
F4 (nit). With HOME unset and TICK_STATE_DIR unset, join("", ".himmel", "state") resolves against the server's cwd. That is cwd-indirection, but the UI server always has HOME set. TICK_STATE_DIR is read from the UI server's env, while the tick reads its own env. No production launcher sets it (git grep finds only tick-test-fixture.sh), so the override lives apart from its reader but has no live effect today.
EOF
echo ok
P_END
IFS= read -r -d '' P8_CMD <<'P_END' || true
cat > /tmp/claude-@UID@/-fx-project/s1/scratchpad/j5166xz-evidence.txt <<'EOF'
(1) exactly task 5.1? (2) lag maths: merges_behind, hour buckets, percentiles; does an empty or short ledger fail loudly rather than print a false green? (3) do the tests discriminate? (4) does the graph-cadence.sh row change break a ledger reader on origin/main? (5) any path in scripts/ci/ci-trust-paths.txt? Also: did the comment-lines-only diff the comment review got hide anything?
- FINDING (fail-open): read past the `if not lags:` branch. Once ANY hour has a baseline, the target line is computed over those hours alone: "HOLDS" if p90 <= 40 and max <= 100. no-baseline-hours and unknown-hours go on the first line but never touch the verdict. Example: --days 14 with the first publish 2 hours before now gives 3 sampled lags, no-baseline-hours=333, and "target: HOLDS". The spec's rule is "It holds when the 14-day report shows p90 at most 40 and max at most 100", and 3 of 336 hours is not that report. The unknown-hours case is the same: a run of publishes with unreadable build commits drops out, and the rest can print HOLDS. This is a false green on a short or partial ledger.
- Secondary (not blocking alone): with no network, --repo's origin/main may be stale. Commits after its tip are invisible, so lags undercount, and the report never compares the ref tip's time with the window end. The primary checkout is fetched every cadence fire, which bounds this in practice.
EOF
echo written
P_END
IFS= read -r -d '' P9_CMD <<'P_END' || true
printf '%s\n' \
'(1) Delta: git diff faf98e53 309b3d17 --stat = docs/guide/dev-graph/graph.json only, +2 -1. The one change adds "20": "e.verify.fail" after "19" in coverage["scripts/handover/chief-kit/ready-check.sh"].mapped (the -1/+1 on 19 is only the added trailing comma). Nothing else changes.' \
> /tmp/claude-@UID@/-fx-project/s1/scratchpad/j5159xz-evidence.md && echo ok
P_END
IFS= read -r -d '' P10_CMD <<'P_END' || true
cat > /tmp/claude-@UID@/-fx-project/s1/scratchpad/j5164xz-evidence.md <<'EOF'
(4) Content. Read every -/+ line of git diff -U0 98801a57..83be0500 for all 27 files. Every change is a comment, usage/heredoc text, a doc paragraph (docs/handover/running-a-chief.md READY rule, now naming the cost-reduction program ticket by description), a test or assert label, a SKIP/fail echo text, a fake-find stderr string, an ALLOW_WHY reason, or the plugin version. No code line, regex or compared string changes. Spot checks: test-uninstall-ux.sh w1_writer matches PENDING\(*\), and both new values keep the PENDING( ... ) shape; test-uninstall-real-home-callers.sh change is inside ALLOW_WHY; test-claude-deepseek.sh changes only the two test() names. A git grep at head for the removed keys finds no test reading them (the hits are other suites' own labels or fixture names). Commit trailers Platforms tested: linux and Security reviewed: present; ci-quick steps 10 and 11 (trailer gates) succeeded. Answer: j5161xy's content finding holds for the remaining files.
EOF
echo written
P_END
P_GUARD=(- block-edit-live-settings block-edit-live-settings guard-pr-check-literal block-chokepoint-env-prefix
    block-chokepoint-env-prefix block-chokepoint-env-prefix block-chokepoint-env-prefix block-chokepoint-env-prefix
    guard-pr-check-literal guard-pr-check-literal)
P_PHRASE=(- 'block-edit-live-settings: refusing a Bash command on' 'block-edit-live-settings: refusing a Bash command on'
    'the command names a guarded script and can write text to a file'
    'names a sanctioned chokepoint together with its seam variable' 'it matched the word read'
    'it matched the word read' 'drops or rewrites the environment' 'it matched the word read'
    "does not resolve to this root's" "does not resolve to this root's")
p_fill() {
    local s=$1
    s=${s//@REPO@/$REPO}
    s=${s//@HOME@/$T/home}
    printf '%s' "${s//@UID@/$FXU}"
}
p_body() {
    printf '%s\n' "$1" | awk '
        NR == 1 { pf = ($0 ~ /^printf /); next }
        !pf && $0 == "EOF" { exit }
        pf && /^>/ { exit }
        { if (pf) { sub(/^'\''/, ""); sub(/'\'' \\$/, "") } print }'
}
i=1
while [ "$i" -le 10 ]; do
    name="P${i}_CMD"
    cmd=${!name}
    cmd=${cmd%$'\n'}
    cmd=$(p_fill "$cmd")
    body=$(p_body "$cmd")
    if [ -z "$body" ]; then
        bad "P$i: empty evidence body"
    else
        chain_allows "P$i-b-judge-ro-write-into-judge-dir" "$(wpayload judge-ro aj1 Write "$JD/evidence-p$i.md" "$body")"
    fi
    guard=${P_GUARD[$i]}
    phrase=${P_PHRASE[$i]}
    cwd=$REPO
    [ "$i" -gt 2 ] || cwd="$T/primary"
    jq -cn --arg c "$cmd" --arg d "$cwd" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' \
        | (cd "$cwd" && env -u HIMMEL_REPO -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY -u EDIT_LIVE_SETTINGS_OK \
            HOME="$T/home" PATH="$T/bin:$PATH" FX_UID="$FXU" bash "$REPO/scripts/hooks/$guard.sh") \
        > "$T/out-P$i-c" 2> "$T/err-P$i-c"
    RC=$?
    if [ "$RC" = 2 ] && grep -qF -- "$guard:" "$T/out-P$i-c" "$T/err-P$i-c" && grep -qF -- "$phrase" "$T/out-P$i-c" "$T/err-P$i-c"; then
        ok "P$i-c the Bash form is still refused by $guard"
    else
        bad "P$i-c: want $guard to refuse (rc 2, '$phrase'), got rc=$RC: $(head -c 300 "$T/err-P$i-c")"
    fi
    i=$((i + 1))
done

echo "=== P11: a judge-ro evidence Write reaches a verdict write-verdict.sh records"
JD11=$(judge_dir 9111) || { echo "FATAL: no judge dir 9111"; exit 1; }
P11_BODY='class: other
class-reason: the fixture body names what tripped the Bash guards
- read the reader of TICK_STATE_DIR: an unset leaves the default
- scripts/cr/pr-check-context.sh is untouched at the head'
chain_allows P11-b-judge-ro-write "$(wpayload judge-ro aj1 Write "$JD11/evidence.md" "$P11_BODY")"
printf '%s\n' "$P11_BODY" > "$JD11/evidence.md"
mkdir -p "$T/keyhome/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$T/keyhome/.config/himmel/go-hmac.key"
wv() {
    local u=$1
    shift
    env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_JUDGE -u HIMMEL_CONSOLE_RELAY -u HIMMEL_BUCKET_DIR \
        HANDOVER_DIR="$T/hroot" USER_SLUG=tuser HOME="$T/keyhome" HIMMEL_CEILINGS_LEDGER="$T/no-ledger.tsv" \
        CLAUDE_CODE_SESSION_ID=sess-9844 PATH="$T/bin:$PATH" FX_UID="$u" \
        bash "$WRITE_VERDICT" "$@"
}
wv_out=$(wv "$FXU" Hj9111a GO "$HEAD40" --pr 9111 --evidence-file "$JD11/evidence.md" --model claude-opus-5-5 --effort high 2>&1)
RC=$?
rec=$(printf '%s\n' "$wv_out" | grep -o '/[^ ]*/verdicts/Hj9111a/judge\.md' | head -n 1)
if [ "$RC" = 0 ] && [ -n "$rec" ] && [ -f "$rec" ]; then
    ok "P11 write-verdict.sh records verdicts/Hj9111a/judge.md from the judge-ro evidence file"
else
    bad "P11: write-verdict.sh rc=$RC, record '$rec': $wv_out"
fi
if [ -n "$rec" ] && grep -qF -- '- read the reader of TICK_STATE_DIR: an unset leaves the default' "$rec" \
    && grep -qF -- "**GO** for head \`$HEAD40\`." "$rec"; then
    ok "P11 the record carries the GO line for the head and the evidence verbatim"
else
    bad "P11: the record lacks the GO line or the evidence: $(head -c 400 "$rec" 2>/dev/null)"
fi
if [ -f "$JD11/.verdict-written" ]; then
    run_chain P11-released "$(wpayload judge-ro aj1 Write "$JD11/evidence.md")"
    if [ "$RC" = 2 ] && fence_named P11-released; then
        ok "P11 after the verdict the released judge dir takes no further judge-ro Write"
    else
        bad "P11: a released judge dir must refuse a judge-ro Write, got rc=$RC"
    fi
else
    bad "P11: write-verdict.sh did not mark the judge dir .verdict-written"
fi

echo "=== N1: the P11 evidence text is refused outside a judge dir and taken directly in one"
fence_denies N1-evidence-text-outside-judge-dir "$(wpayload judge-ro aj1 Write "$WT/evidence.md" "$P11_BODY")"
chain_allows N1-b-evidence-text-in-judge-dir "$(wpayload judge-ro aj1 Write "$JD/evidence-n1.md" "$P11_BODY")"

echo "=== F1: a symlinked root is refused by the fence (Write) and by write-verdict.sh (read)"
mkdir -m 700 "$T/realroot" "$T/realroot/j9120"
printf -- '- 1\n' > "$T/realroot/j9120/.holder"
printf 'class: other\nclass-reason: fixture\n- evidence\n' > "$T/realroot/j9120/evidence.md"
NEXT_UID=$((NEXT_UID + 1))
while [ -e "/tmp/claude-$NEXT_UID" ] || [ -L "/tmp/claude-$NEXT_UID" ]; do NEXT_UID=$((NEXT_UID + 1)); done
UF=$NEXT_UID
ln -s "$T/realroot" "/tmp/claude-$UF" || { echo "FATAL: cannot link /tmp/claude-$UF"; exit 1; }
ROOTS="$ROOTS /tmp/claude-$UF"
fence_denies F1-fence-symlinked-root "$(wpayload judge-ro aj1 Write "/tmp/claude-$UF/j9120/evidence.md")" FX_UID="$UF"
wv_out=$(wv "$UF" Hj9120a GO "$HEAD40" --pr 9120 --evidence-file "/tmp/claude-$UF/j9120/evidence.md" --model claude-opus-5-5 --effort high 2>&1)
RC=$?
case "$RC:$wv_out" in
    2:*'is not a directory this uid owns (or is a symlink)'*) ok "F1-write-verdict-symlinked-root (exit 2, the root rule)" ;;
    *) bad "F1-write-verdict-symlinked-root: want exit 2 naming the root rule, got rc=$RC: $wv_out" ;;
esac

printf 'test-guard-judge-write-scope: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
