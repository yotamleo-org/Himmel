#!/usr/bin/env bash
# Smoke test for scripts/handover/generate-morning-briefing.sh
#
# Assertions match ASCII substrings only — both the 🌅/✅/🔴/🧹/📋 emoji and
# the em-dash separator are multibyte; MINGW `grep -qF` can SIGABRT on those,
# so every header is matched by an ASCII tail ("Morning Report", "Completed (",
# "In-flight WIP", "Stale worktrees", "Moved to Done", "TL;DR", "Suggested order").
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# lead_of <report> — the four leading answers: everything before "## TL;DR".
lead_of() { sed '/^## TL;DR/q' <<< "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/generate-morning-briefing.sh"

# Hermetic: neutralize env the script reads, so an operator's exported
# MORNING_REPORT_LLM (would flip on --llm → a real claude call mid-suite) or
# FORGE (would override the per-test remote-URL forge detection) can't leak in.
export MORNING_REPORT_LLM=0
unset FORGE 2>/dev/null || true
# Hermetic: running the suite inside Codex would trip the --llm no-fork guard.
unset CODEX_THREAD_ID 2>/dev/null || true
# Hermetic: the shift-spend reader and the worker-doc scan read the operator's real ledgers and
# handover root; empty means "no such input" unless a test names one.
export MORNING_SHIFT_SPEND_CMD=""
export MORNING_WAITING_DIR=""
# The shift record (shifts.jsonl) and the shift helper: empty means no such input unless a test names one.
export SHIFTS_FILE=""
export MORNING_SHIFT_CMD=""

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}

assert_absent() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then fail "$name" "present: $needle"; else pass "$name"; fi
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi
# Hermetic: the operator's real failure-review digests must not leak in.
export HIMMEL_FAILURE_REVIEW_DIR="$TMP_ROOT/failure-review"
mkdir -p "$TMP_ROOT/emptyroot"; : > "$TMP_ROOT/emptyroot/.env"
export GH_READ_ENV_ROOT="$TMP_ROOT/emptyroot" HIMMEL_SECRETS_KEYRING=off

# Fake gh + jira + claude CLIs -----------------------------------------

FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
# The open-PR CI and review query (reviewDecision): FAKE_GH_PR_OPEN, else the call fails.
case " $* " in
    *reviewDecision*)
        [ -n "${FAKE_GH_PR_OPEN:-}" ] || exit 1
        printf '%s\n' "$FAKE_GH_PR_OPEN"; exit 0 ;;
esac
case "$1 $2" in
    "pr list")
        # --search present => merged date query; else the all-state PR map.
        if printf '%s ' "$@" | grep -q -- '--search'; then
            # FAKE_GH_SEARCH_FROM set => only the search for exactly that day finds the PRs.
            if [ -n "${FAKE_GH_SEARCH_FROM:-}" ] && ! printf '%s\n' "$@" | grep -qxF -- "merged:>=$FAKE_GH_SEARCH_FROM"; then
                printf '[]\n'
            else
                printf '%s\n' "${FAKE_GH_PR_JSON:-[]}"
            fi
        elif printf '%s ' "$@" | grep -q -- '--state open'; then
            # The open-PR list: FAKE_GH_PR_OPENLIST, else the OPEN rows of the all-state fixture.
            if [ -n "${FAKE_GH_PR_OPENLIST:-}" ]; then printf '%s\n' "$FAKE_GH_PR_OPENLIST"
            else printf '%s' "${FAKE_GH_PR_ALL:-[]}" | jq -c '[.[] | select(.state == "OPEN")]'; fi
        else
            printf '%s\n' "${FAKE_GH_PR_ALL:-[]}"
        fi
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH"

FAKE_JIRA="$TMP_ROOT/jira-fake.sh"
cat >"$FAKE_JIRA" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    versions) printf '%s\n' "${FAKE_JIRA_VERSIONS:-}";;
    list)
        # FAKE_JIRA_LOG set => every list call's argv is appended to it.
        [ -n "${FAKE_JIRA_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_JIRA_LOG"
        status=""; prev=""; jql=0
        for a in "$@"; do [ "$prev" = "--status" ] && status="$a"; [ "$a" = "--jql" ] && jql=1; prev="$a"; done
        # The report-day Done query (status CHANGED TO Done DURING) reads FAKE_JIRA_DONE_OUT, every other --jql reads FAKE_JIRA_JQL_OUT.
        case "$*" in *"CHANGED TO Done DURING"*) printf '%s\n' "${FAKE_JIRA_DONE_OUT:-}"; exit 0 ;; esac
        [ "$jql" -eq 1 ] && { printf '%s\n' "${FAKE_JIRA_JQL_OUT:-}"; exit 0; }
        case "$status" in
            "To Do")        printf '%s\n' "${FAKE_JIRA_TODO:-}";;
            "In Progress")  printf '%s\n' "${FAKE_JIRA_INPROG:-}";;
            *)              printf '%s\n' "${FAKE_JIRA_OUT:-}";;   # Done cross-ref
        esac ;;
esac
exit 0
FAKE
chmod +x "$FAKE_JIRA"

FAKE_CLAUDE="$TMP_ROOT/claude-fake.sh"
cat >"$FAKE_CLAUDE" <<'FAKE'
#!/usr/bin/env bash
# Emits sentinel blocks (with surrounding chrome) regardless of prompt; exit 0.
cat <<'OUT'
some preamble chrome
<<<TLDR_BEGIN>>>
LLM TL;DR line one
LLM TL;DR line two
<<<TLDR_END>>>
<<<ORDER_BEGIN>>>
1. LLM-suggested first
<<<ORDER_END>>>
<<<BACKLOG_BEGIN>>>
**theme A** — HIMMEL-801
<<<BACKLOG_END>>>
trailing chrome
OUT
exit 0
FAKE
chmod +x "$FAKE_CLAUDE"

# Partial fake: emits ONLY the TLDR block (ORDER + BACKLOG sentinels absent) —
# exercises per-block fail-open (TLDR from LLM, ORDER + BACKLOG fall back).
FAKE_CLAUDE_PARTIAL="$TMP_ROOT/claude-partial.sh"
cat >"$FAKE_CLAUDE_PARTIAL" <<'FAKE'
#!/usr/bin/env bash
cat <<'OUT'
<<<TLDR_BEGIN>>>
ONLY TLDR FROM LLM
<<<TLDR_END>>>
OUT
exit 0
FAKE
chmod +x "$FAKE_CLAUDE_PARTIAL"

# ORDER block whose first line is blank: the lead's next step is the first nonblank line.
FAKE_CLAUDE_BLANK="$TMP_ROOT/claude-blank-order.sh"
cat >"$FAKE_CLAUDE_BLANK" <<'FAKE'
#!/usr/bin/env bash
cat <<'OUT'
<<<ORDER_BEGIN>>>

1. FIRST NONBLANK STEP
2. second
<<<ORDER_END>>>
OUT
exit 0
FAKE
chmod +x "$FAKE_CLAUDE_BLANK"

# Failing gh fake: the all-state PR query (no --search) exits non-zero, to
# exercise the pr_map_ok=0 reachability path (gh down != clean garden).
FAKE_GH_FAIL="$TMP_ROOT/gh-fail.sh"
cat >"$FAKE_GH_FAIL" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        if printf '%s ' "$@" | grep -q -- '--search'; then
            printf '%s\n' "${FAKE_GH_PR_JSON:-[]}"; exit 0
        fi
        echo "gh: simulated auth failure" >&2; exit 1
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH_FAIL"

# Setup a tmp git repo with a marker SHA + 3 commits referencing tickets.
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
(
    cd "$REPO"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git branch -m main 2>/dev/null || true
    MARKER=$(git rev-parse HEAD)
    echo "$MARKER" > "$TMP_ROOT/MARKER"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "feat(scope): HIMMEL-901 add A"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "fix(scope): HIMMEL-902 bug B"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "chore: nothing"
)
# Forge seam: the merged-PR section is gated to a github origin.
git -C "$REPO" remote add origin https://github.com/test/test.git
MARKER=$(cat "$TMP_ROOT/MARKER")

# Two extra worktrees: one keyed to an In-Progress ticket, one unkeyed.
git -C "$REPO" worktree add -q -b feat/himmel-901-thing "$TMP_ROOT/wt901" >/dev/null 2>&1 || true
git -C "$REPO" worktree add -q -b feat/random-slug      "$TMP_ROOT/wtrand" >/dev/null 2>&1 || true

run_script() {
    (
        cd "$REPO"
        # shellcheck disable=SC2030
        export GH_CMD="$FAKE_GH"
        # shellcheck disable=SC2030
        export JIRA_CMD="$FAKE_JIRA"
        bash "$SCRIPT" "$@"
    )
}

# Test 1: default run, all sections (🌅 schema) -----------------------

echo "TEST: default run produces the morning-report schema"
OUT_DEFAULT="$TMP_ROOT/out1.md"
out=$(FAKE_GH_PR_JSON='[{"number":42,"title":"feat(scope): HIMMEL-901 add A","mergedAt":"2026-05-25T00:00:00Z"}]' \
    FAKE_JIRA_DONE_OUT=$'HIMMEL-901\tTask\tDone\tAdd A' \
    run_script --since "$MARKER" --out "$OUT_DEFAULT")
file=$(cat "$OUT_DEFAULT")
assert_contains "header"             "Morning Report"               "$file"
assert_contains "tldr section"       "## TL;DR"                     "$file"
assert_contains "completed section"  "Completed ("                  "$file"
assert_contains "commits subsection" "### Commits"                  "$file"
assert_contains "done subsection"    "Moved to Done on"             "$file"
assert_contains "wip section"        "In-flight WIP"                "$file"
assert_contains "stale section"      "Stale worktrees"              "$file"
assert_contains "order section"      "Suggested order"              "$file"
assert_contains "PR row #42"         "#42"                          "$file"
assert_contains "commit cited"       "HIMMEL-901"                   "$file"
assert_contains "marker echoed"      "$MARKER"                      "$file"
# Removed section must NOT reappear:
if grepq "$file" 'Items for operator review'; then fail "stale 'Items for operator review' section present"; else pass "operator-review section removed"; fi

# Test 2: local-date default -----------------------------------------

echo "TEST: default output is local-dated (no -u)"
LOCALDATE=$(date +%F)
assert_contains "local date in header" "Morning Report" "$file"
assert_contains "local date present"   "$LOCALDATE"     "$file"

# Test 3: --since SHA limits window -----------------------------------

echo "TEST: --since SHA limits the commit window"
LATEST=$(git -C "$REPO" rev-parse HEAD)
OUT2="$TMP_ROOT/out2.md"
out=$(run_script --since "$LATEST" --out "$OUT2")
file=$(cat "$OUT2")
assert_contains "no-commits message" "No commits found since" "$file"

# Test 4: --out writes to requested location --------------------------

echo "TEST: --out PATH respected (creates parent dirs)"
OUT3="$TMP_ROOT/sub/path/out3.md"
out=$(run_script --since "$MARKER" --out "$OUT3")
if [ -f "$OUT3" ]; then pass "wrote $OUT3"; else fail "did not create parent dir for --out"; fi

# Test 5: PR section absent (empty gh result) -------------------------

echo "TEST: empty gh PR list renders helpful message"
OUT4="$TMP_ROOT/out4.md"
out=$(FAKE_GH_PR_JSON='[]' run_script --since "$MARKER" --out "$OUT4")
file=$(cat "$OUT4")
assert_contains "empty PR fallback" "No merged PRs found" "$file"

# Test 5b: gh search qualifier is inclusive of today ----
# The FAKE_GH stub (above) does not itself filter by the qualifier's value —
# it only branches on whether --search is present — so this test captures
# the exact argv sent to gh and asserts the qualifier string, independent
# of test 1's coincidental fixture date.

echo "TEST: gh search qualifier is merged:>=DATE, not merged:>DATE"
FAKE_GH_CAPTURE="$TMP_ROOT/gh-capture.sh"
cat >"$FAKE_GH_CAPTURE" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        if printf '%s ' "$@" | grep -q -- '--search'; then
            printf '%s\n' "$@" > "$GH_ARGV_CAPTURE"
            printf '%s\n' "${FAKE_GH_PR_JSON:-[]}"
        else
            printf '%s\n' "${FAKE_GH_PR_ALL:-[]}"
        fi
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH_CAPTURE"
TODAY=$(date +%F)
CAPTURE="$TMP_ROOT/gh-argv-capture.txt"
OUT_SEARCH="$TMP_ROOT/out-search.md"
out=$( cd "$REPO"; GH_CMD="$FAKE_GH_CAPTURE" JIRA_CMD="$FAKE_JIRA" GH_ARGV_CAPTURE="$CAPTURE" \
    FAKE_GH_PR_JSON='[]' bash "$SCRIPT" --since "$MARKER" --out "$OUT_SEARCH" )
if [ -f "$CAPTURE" ] && grep -q -- "merged:>=$TODAY" "$CAPTURE"; then
    pass "search qualifier merged:>=\$today"
else
    fail "search qualifier merged:>=\$today" "captured: $(cat "$CAPTURE" 2>/dev/null || echo '<none>')"
fi

# Test 6: jira unavailable -------------------------------------------

echo "TEST: jira unavailable yields ticket-keys-only fallback"
OUT5="$TMP_ROOT/out5.md"
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" JIRA_CMD="/no/such/binary" bash "$SCRIPT" --since "$MARKER" --out "$OUT5"
)
file=$(cat "$OUT5")
assert_contains "ticket keys listed in fallback" "HIMMEL-901" "$file"
# A failed jira CLI must surface a reachability banner — a 0 count means
# "unknown", not "none" (silent-failure-hunter HIGH).
assert_contains "jira-down banner" "jira unavailable" "$file"
assert_contains "jira-down: shipped Done gap"  "not available (jira unavailable) Done" "$(lead_of "$file")"
assert_contains "jira-down: next in-flight gap" "In-Progress tickets: not available"   "$(lead_of "$file")"

# Test 7: --dry-run touches no files ----------------------------------

echo "TEST: --dry-run touches no files"
OUT6="$TMP_ROOT/out6.md"
out=$(run_script --since "$MARKER" --out "$OUT6" --dry-run)
if [ -f "$OUT6" ]; then fail "--dry-run created $OUT6"; else pass "--dry-run did not write file"; fi
assert_contains "dry-run prints body" "Morning Report" "$out"

# Test 8: Done block is the day's transitions ------------------------

echo "TEST: Done block lists every ticket the transition query returns, not only those the commits name"
OUT7="$TMP_ROOT/out7.md"
out=$(FAKE_GH_PR_JSON='[]' \
    FAKE_JIRA_DONE_OUT=$'HIMMEL-901\tTask\tDone\tA
HIMMEL-902\tTask\tDone\tB
HIMMEL-999\tTask\tDone\tNot in commits' \
    run_script --since "$MARKER" --out "$OUT7")
file=$(cat "$OUT7")
assert_contains "Done block has HIMMEL-901" "HIMMEL-901 — Task — A" "$file"
assert_contains "Done block has HIMMEL-902" "HIMMEL-902 — Task — B" "$file"
assert_contains "Done block keeps HIMMEL-999 (the commits are no filter)" "HIMMEL-999 — Task — Not in commits" "$file"

# Test 9: In-flight WIP join rule + catch-all ------------------------

echo "TEST: In-flight WIP correlates by ticket key + catch-all"
OUT_WIP="$TMP_ROOT/wip.md"
out=$(FAKE_GH_PR_ALL='[{"number":50,"state":"OPEN","headRefName":"feat/himmel-901-thing","title":"x"},{"number":51,"state":"OPEN","headRefName":"feat/random-slug","title":"y"}]' \
    FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing\nHIMMEL-903\tTask\tIn Progress\tNoBranch' \
    run_script --since "$MARKER" --out "$OUT_WIP")
file=$(cat "$OUT_WIP")
assert_contains "wip correlated ticket"   "HIMMEL-901" "$file"
assert_contains "wip correlated pr"       "#50"        "$file"
assert_contains "wip uncorrelated ticket" "HIMMEL-903" "$file"
assert_contains "wip catchall pr"         "#51"        "$file"

# Test 10: Stale worktrees = merged-PR only --------------------------

echo "TEST: stale worktrees = merged-PR branch only; main/open/no-PR not flagged"
OUT_STALE="$TMP_ROOT/stale.md"
out=$(FAKE_GH_PR_ALL='[{"number":60,"state":"MERGED","headRefName":"feat/himmel-901-thing","title":"x"},{"number":61,"state":"OPEN","headRefName":"feat/random-slug","title":"y"}]' \
    run_script --since "$MARKER" --out "$OUT_STALE")
file=$(cat "$OUT_STALE")
assert_contains "stale flags merged" "feat/himmel-901-thing" "$file"
# Stale-table rows are the only "| \`branch\` |" lines in the report.
stale_tbl=$(printf '%s\n' "$file" | grep -E '^\| `' || true)
# shellcheck disable=SC2016  # literal backtick-main-backtick in the table row, no expansion intended
if grepq "$stale_tbl" -E '`main`'; then fail "stale flagged main"; else pass "main not flagged stale"; fi
if grepq "$stale_tbl" 'feat/random-slug'; then fail "stale flagged OPEN-PR worktree"; else pass "open-PR worktree not flagged stale"; fi

# Test 11: non-github origin degrades gracefully ---------------------

echo "TEST: non-github origin degrades gh sections without abort"
REPO_BB="$TMP_ROOT/repo_bb"; cp -r "$REPO" "$REPO_BB"
git -C "$REPO_BB" remote set-url origin https://bitbucket.org/test/test.git
OUT_BB="$TMP_ROOT/bb.md"
rc=0
out=$( cd "$REPO_BB"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" bash "$SCRIPT" --since "$MARKER" --out "$OUT_BB" ) || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$OUT_BB" ]; then pass "non-github run did not abort"; else fail "non-github run aborted (rc=$rc)"; fi
bb_file=$(cat "$OUT_BB")
assert_contains "bb still has wip header" "In-flight WIP"    "$bb_file"
assert_contains "bb stale degraded"       "non-github forge" "$bb_file"

# Test 13: TL;DR + Suggested order heuristics ------------------------

echo "TEST: TL;DR + Suggested order heuristics render"
OUT_TL="$TMP_ROOT/tldr.md"
out=$(FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing' \
    run_script --since "$MARKER" --out "$OUT_TL")
file=$(cat "$OUT_TL")
# Assert COMPUTED content (1 In-Progress, no stale, no PRs), not just
# the static template labels — a wrong count/order must not ship green.
assert_contains "tldr 1 in-flight" "**1** in-flight" "$file"
assert_contains "tldr links the Board" "Backlog: on the Board" "$file"
assert_contains "order advance"    "Advance 1 In-Progress ticket(s)." "$file"

# Test 14: --llm splices enriched blocks -----------------------------

echo "TEST: --llm splices multi-line enriched blocks"
OUT_LLM="$TMP_ROOT/llm.md"
out=$( cd "$REPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" CLAUDE_CMD="$FAKE_CLAUDE" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_LLM" --llm )
file=$(cat "$OUT_LLM")
assert_contains "llm tldr spliced"   "LLM TL;DR line one"  "$file"
assert_contains "llm tldr multiline" "LLM TL;DR line two"  "$file"
assert_contains "llm order spliced"  "LLM-suggested first" "$file"
assert_absent   "llm backlog block is not spliced" "theme A" "$file"

# Test 15: --llm fails open to heuristic -----------------------------

echo "TEST: --llm fails open to heuristic when claude errors"
OUT_LLF="$TMP_ROOT/llmfail.md"
rc=0
out=$( cd "$REPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" CLAUDE_CMD="/no/such/claude" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_LLF" --llm ) || rc=$?
if [ "$rc" -eq 0 ]; then pass "llm failure did not abort"; else fail "llm failure aborted rc=$rc"; fi
assert_contains "fallback tldr heuristic" "in-flight" "$(cat "$OUT_LLF")"
assert_contains "llm failed: spend line says failed" "turn (--llm) failed; heuristic used" "$(lead_of "$(cat "$OUT_LLF")")"
if grepq "$(lead_of "$(cat "$OUT_LLF")")" -F -- "one bounded"; then fail "failed llm run reported as a bounded turn"; else pass "failed llm run not reported as a bounded turn"; fi

echo "TEST: ORDER block starting with a blank line → next step is the first nonblank line"
OUT_BLK="$TMP_ROOT/blankorder.md"
out=$( cd "$REPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" CLAUDE_CMD="$FAKE_CLAUDE_BLANK" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_BLK" --llm )
assert_contains "blank-first order: next step" "Next step: 1. FIRST NONBLANK STEP" "$(lead_of "$(cat "$OUT_BLK")")"

# Test 16: --llm per-block fail-open (only TLDR present) --------------

echo "TEST: --llm per-block fail-open (TLDR from LLM, ORDER falls back)"
OUT_PARTIAL="$TMP_ROOT/partial.md"
out=$( cd "$REPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" CLAUDE_CMD="$FAKE_CLAUDE_PARTIAL" \
       FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing' \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_PARTIAL" --llm )
file=$(cat "$OUT_PARTIAL")
assert_contains "partial: llm tldr taken"    "ONLY TLDR FROM LLM"               "$file"
assert_contains "partial: order fell back"   "Advance 1 In-Progress ticket(s)." "$file"

# Test 16b: --llm under Codex never forks claude ----------

echo "TEST: --llm under Codex (CODEX_THREAD_ID) never calls claude, falls back"
CODEX_STUB_HIT="$TMP_ROOT/codex-stub-hit"
CODEX_STUB="$TMP_ROOT/claude-codex-stub.sh"
cat >"$CODEX_STUB" <<FAKE
#!/usr/bin/env bash
: >"$CODEX_STUB_HIT"
exit 0
FAKE
chmod +x "$CODEX_STUB"
OUT_CODEX="$TMP_ROOT/codex.md"
rc=0
err=$( cd "$REPO"; CODEX_THREAD_ID=thr-test GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" CLAUDE_CMD="$CODEX_STUB" \
       FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing' \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_CODEX" --llm 2>&1 >/dev/null ) || rc=$?
if [ "$rc" -eq 0 ]; then pass "codex --llm did not abort"; else fail "codex --llm aborted rc=$rc"; fi
if [ -e "$CODEX_STUB_HIT" ]; then fail "codex --llm forked claude"; else pass "codex --llm never called claude"; fi
assert_contains "codex: notice"             "skipping --llm under Codex"        "$err"
assert_contains "codex: heuristic fallback" "Advance 1 In-Progress ticket(s)." "$(cat "$OUT_CODEX")"

# Test 17: gh unreachable → pr_map_ok=0 banner + stale "unavailable" --

echo "TEST: gh all-state query failure → reachability banner + stale unavailable"
OUT_GHF="$TMP_ROOT/ghfail.md"
out=$( cd "$REPO"; GH_CMD="$FAKE_GH_FAIL" JIRA_CMD="$FAKE_JIRA" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_GHF" )
file=$(cat "$OUT_GHF")
assert_contains "gh-down banner"          "gh PR state unavailable"      "$file"
assert_contains "gh-down stale message"   "stale detection unavailable"  "$file"
assert_contains "gh-down: TL;DR stale unavailable" "stale worktrees unavailable" "$file"
if grepq "$file" -F -- "**0** stale branches"; then fail "gh-down: TL;DR never shows 0 stale"; else pass "gh-down: TL;DR never shows 0 stale"; fi
assert_contains "gh-down: waits open PRs gap"    "Open PRs: not available"             "$(lead_of "$file")"
assert_contains "gh-down: waits stale gap"       "Stale worktrees: not available"      "$(lead_of "$file")"
assert_contains "bb: waits stale gap"            "Stale worktrees: not available"      "$(lead_of "$bb_file")"

echo "TEST: gh missing → merged-PR count and open PRs read not available, never 0"
OUT_GHM="$TMP_ROOT/ghmissing.md"
out=$( cd "$REPO"; GH_CMD="/no/such/gh" JIRA_CMD="$FAKE_JIRA" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_GHM" )
file=$(cat "$OUT_GHM")
assert_contains "gh-missing: shipped count gap" "not available PRs merged to main" "$(lead_of "$file")"
assert_contains "gh-missing: waits open PRs gap" "Open PRs: not available"        "$(lead_of "$file")"
if grepq "$(lead_of "$file")" -F -- "**0** PRs merged"; then fail "gh-missing rendered the shipped count as 0"; else pass "gh-missing did not render the shipped count as 0"; fi

echo "TEST: unparseable gh merged-PR list → count unknown, never 0"
OUT_PRU="$TMP_ROOT/prunknown.md"
out=$( cd "$REPO"; FAKE_GH_PR_JSON="not json" GH_CMD="$FAKE_GH_FAIL" JIRA_CMD="$FAKE_JIRA" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_PRU" )
file=$(cat "$OUT_PRU")
assert_contains "pr count rendered unknown" "Completed (unknown PRs merged" "$file"
assert_contains "unparseable: shipped count gap" "not available PRs merged to main" "$(lead_of "$file")"
if grepq "$file" -F -- "Completed (0 PRs merged"; then fail "unparseable list rendered as 0 PRs"; else pass "unparseable list not rendered as 0 PRs"; fi

echo "TEST: valid JSON that is not an array → count unknown, never 0"
OUT_PRO="$TMP_ROOT/probject.md"
out=$( cd "$REPO"; FAKE_GH_PR_JSON="{}" GH_CMD="$FAKE_GH_FAIL" JIRA_CMD="$FAKE_JIRA" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_PRO" )
file=$(cat "$OUT_PRO")
assert_contains "non-array rendered unknown" "Completed (unknown PRs merged" "$file"

# BSD awk (macOS) rejects a newline inside `-v`; the catch-all
# must not hand awk the raw newline-joined branch list.
echo "TEST: no awk -v carries the raw multi-line annotated_branches"
# ponytail: a source grep, because Linux gawk accepts the newline BSD awk
# rejects; the macOS shard's "wip catchall pr" case is the behavioural proof,
# shellcheck disable=SC2016  # the pattern is a literal, not an expansion
raw_v=$(grep -nE 'awk .*-v [A-Za-z_]+="\$annotated_branches"' "$SCRIPT" || true)
if [ -z "$raw_v" ]; then pass "annotated_branches not passed raw via awk -v"; else fail "raw multi-line awk -v" "$raw_v"; fi

# the daily failure-review digest nests under its own section.
echo "TEST: failure review section embeds today's digest, else says none"
OUT_FR0="$TMP_ROOT/fr0.md"
run_script --since "$MARKER" --out "$OUT_FR0" >/dev/null
file=$(cat "$OUT_FR0")
assert_contains "failure review: section"   "Failure review"                 "$file"
assert_contains "failure review: none"      "No failure review digest for"   "$file"
mkdir -p "$HIMMEL_FAILURE_REVIEW_DIR"
printf '## Failure review\n\n- failures: 3 rows, 2 classes, 2 workers\n\n### Top classes\n\n- error/Edit: 2 rows\n' \
    > "$HIMMEL_FAILURE_REVIEW_DIR/failure-review-$(date +%F).md"
OUT_FR1="$TMP_ROOT/fr1.md"
run_script --since "$MARKER" --out "$OUT_FR1" >/dev/null
file=$(cat "$OUT_FR1")
assert_contains "failure review: digest body"   "- failures: 3 rows, 2 classes, 2 workers" "$file"
assert_contains "failure review: demoted"       "#### Top classes"                     "$file"
if grepq "$file" -x '## Failure review'; then fail "failure review: inner heading not dropped"; else pass "failure review: inner heading dropped"; fi
rm -rf "$HIMMEL_FAILURE_REVIEW_DIR"

# The prompt-cache line is never silently absent.
echo "TEST: prompt cache section reports unmonitored without metrics, else the ratio"
export CACHE_HEALTH_STATE_DIR="$TMP_ROOT/cache-health"
OUT_CH0="$TMP_ROOT/ch0.md"
run_script --since "$MARKER" --out "$OUT_CH0" >/dev/null
file=$(cat "$OUT_CH0")
assert_contains "cache line: section"   "Prompt cache"                              "$file"
assert_contains "cache line: missing"   "cache: unmonitored (metrics missing)"      "$file"
mkdir -p "$CACHE_HEALTH_STATE_DIR"
printf '{"schema":1,"generated_at":%s,"overall":{"hit_pct":97.5},"roles":{}}\n' "$(date +%s)" > "$CACHE_HEALTH_STATE_DIR/metrics.json"
printf '{"ts":%s,"overall":97.5,"roles":{"console":98.0,"worker":96.0}}\n' "$(date +%s)" > "$CACHE_HEALTH_STATE_DIR/history.jsonl"
OUT_CH1="$TMP_ROOT/ch1.md"
run_script --since "$MARKER" --out "$OUT_CH1" >/dev/null
file=$(cat "$OUT_CH1")
assert_contains "cache line: ratio"     "cache: 7d read ratio 97.5%"                "$file"
unset CACHE_HEALTH_STATE_DIR

# The report leads with the frame 16 four answers; every older section stays below.
echo "TEST: first four headings are the frame 16 answers, every older section kept below"
OUT_F16="$TMP_ROOT/f16.md"
out=$(FAKE_GH_PR_JSON='[{"number":42,"title":"feat(scope): HIMMEL-901 add A","mergedAt":"2026-05-25T00:00:00Z"}]' \
    FAKE_GH_PR_ALL='[{"number":50,"state":"OPEN","headRefName":"feat/himmel-901-thing","title":"x"},{"number":51,"state":"OPEN","headRefName":"feat/random-slug","title":"y"}]' \
    FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing' \
    run_script --since "$MARKER" --out "$OUT_F16")
file=$(cat "$OUT_F16")
# Headings with the multibyte emoji stripped, so the match is ASCII-only.
h2_ascii=$(grep -E '^## ' "$OUT_F16" | LC_ALL=C sed 's/[^ -~]//g' | tr -s ' ' || true)
first_four=$(printf '%s\n' "$h2_ascii" | sed -n '1,4p')
rest=$(printf '%s\n' "$h2_ascii" | sed -n '5,$p')
want_first=$'## What shipped\n## What waits on you\n## What it spent\n## What runs next'
if [ "$first_four" = "$want_first" ]; then pass "first four headings are the frame 16 ones, in order"; else fail "first four headings" "got: $(printf '%s' "$first_four" | tr '\n' '|')"; fi
want_rest=$'## Chiefs\n## Spend per shift\n## TL;DR\n## Completed (1 PRs merged to main)\n## In-flight WIP\n## Stale worktrees\n## Docs drift\n## Failure review\n## Prompt cache\n## Suggested order'
if [ "$rest" = "$want_rest" ]; then pass "every pre-change section kept below, in order"; else fail "sections below the four" "got: $(printf '%s' "$rest" | tr '\n' '|')"; fi
assert_contains "f16: commits subsection kept" "### Commits"                  "$file"
assert_contains "f16: done subsection kept"    "Moved to Done on"             "$file"
# Fields with an input are computed; a field with none says so, never a guess.
lead=$(lead_of "$file")
assert_contains "f16: shipped counts"          "**1** PRs merged"             "$lead"
assert_contains "f16: waits counts open PRs"   "**2** open PR(s)"             "$lead"
assert_contains "f16: spent gap is explicit"   "Claude usage of the shift: not available" "$lead"
assert_contains "f16: next counts in flight"   "**1** In-Progress"            "$lead"
assert_contains "f16: releases gap is explicit" "Release progress: not available" "$lead"

# The three inputs the lead lines read: shift spend, what waits on you, release progress.
# Each computes from its input and falls back to the "not available" line without it.
echo "TEST: shift spend line shows the shift's computed spend, and reads not available without it"
FAKE_SPEND="$TMP_ROOT/shift-spend-fake.sh"
cat >"$FAKE_SPEND" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
{"window":{"since":"s","until":"u"},"fields":{
 "claude_bank":{"status":"ok","unit":"percent","value":48,"seven_day":{"start":92,"end":40,"peak":100,"delta":48,"resets":1}},
 "api_cost":{"status":"ok","unit":"USD","value":"13.035507","runs":31,"partial":true},
 "codex_tokens":{"status":"not available"},"openrouter":{"status":"not available"}}}
JSON
FAKE
chmod +x "$FAKE_SPEND"
FAKE_SPEND_NA="$TMP_ROOT/shift-spend-na.sh"
cat >"$FAKE_SPEND_NA" <<'FAKE'
#!/usr/bin/env bash
echo '{"fields":{"claude_bank":{"status":"not available"},"api_cost":{"status":"not available"}}}'
FAKE
chmod +x "$FAKE_SPEND_NA"
OUT_SP="$TMP_ROOT/spend.md"
run_script --since "$MARKER" --out "$OUT_SP" >/dev/null
lead=$(lead_of "$(cat "$OUT_SP")")
assert_contains "spend: absent input still says not available" "Claude usage of the shift: not available" "$lead"
MORNING_SHIFT_SPEND_CMD="$FAKE_SPEND" run_script --since "$MARKER" --out "$OUT_SP" >/dev/null
lead=$(lead_of "$(cat "$OUT_SP")")
assert_contains "spend: weekly bank burn shown"  "weekly bank **+48** points" "$lead"
assert_contains "spend: API lane dollars shown, a floor marked" "API lane **at least \$13.04**" "$lead"
if grepq "$lead" -F -- "Claude usage of the shift: not available"; then fail "spend: computed line replaces the gap"; else pass "spend: computed line replaces the gap"; fi
assert_contains "spend: a reset inside the shift marks the bank figure an estimate" "weekly bank **+48** points (a reset inside the shift: an estimate)" "$lead"
FAKE_SPEND_Z="$TMP_ROOT/shift-spend-noreset.sh"
sed 's/"resets":1/"resets":0/' "$FAKE_SPEND" > "$FAKE_SPEND_Z"
chmod +x "$FAKE_SPEND_Z"
MORNING_SHIFT_SPEND_CMD="$FAKE_SPEND_Z" run_script --since "$MARKER" --out "$OUT_SP" >/dev/null
lead=$(lead_of "$(cat "$OUT_SP")")
assert_contains "spend: zero resets still shows the bank figure" "weekly bank **+48** points" "$lead"
if grepq "$lead" -F -- "a reset inside the shift"; then fail "spend: zero resets is not called a reset"; else pass "spend: zero resets is not called a reset"; fi
MORNING_SHIFT_SPEND_CMD="$FAKE_SPEND_NA" run_script --since "$MARKER" --out "$OUT_SP" >/dev/null
assert_contains "spend: every field unavailable reads not available" "Claude usage of the shift: not available" "$(lead_of "$(cat "$OUT_SP")")"
MORNING_SHIFT_SPEND_CMD="false" run_script --since "$MARKER" --out "$OUT_SP" >/dev/null
assert_contains "spend: a failing reader reads not available" "Claude usage of the shift: not available" "$(lead_of "$(cat "$OUT_SP")")"

echo "TEST: waiting-on-you lines count GOs, worker questions and CI/review state, and read not available without input"
WAITD="$TMP_ROOT/waitdocs"
mkdir -p "$WAITD/u/repo"
printf '## Results\n- 13:00 LIVE — x\n- 14:05 READY 77 abc GREEN\n' > "$WAITD/u/repo/a.md"
printf '## Results\n- 08:00 LIVE — y\n- 09:30 BLOCKED — push refused\n' > "$WAITD/u/repo/b.md"
printf '## Results\n- 08:00 FINDING — z\n- 09:00 RESOLVED — z\n- 10:00 WRAPPED — done\n' > "$WAITD/u/repo/c.md"
# A second GO from today at an EARLIER time of day than yesterday's: only the date tells which waits longer.
printf '## Results\n- 09:10 LIVE — w\n- 09:15 READY 78 def GREEN\n' > "$WAITD/u/repo/d.md"
TODAY_D=$(date +%F)
YDAY_STAMP=$(date -d '1 day ago' +%Y%m%d%H%M 2>/dev/null || date -v-1d +%Y%m%d%H%M) # gnu-ok: paired with the BSD date -v form
YDAY_D=$(date -d '1 day ago' +%F 2>/dev/null || date -v-1d +%F) # gnu-ok: paired with the BSD date -v form
touch -t "$YDAY_STAMP" "$WAITD/u/repo/a.md"
OPEN_JSON='[{"number":1,"reviewDecision":"APPROVED","createdAt":"2026-10-29T10:00:00Z","statusCheckRollup":[{"conclusion":"SUCCESS"}]},{"number":2,"reviewDecision":"CHANGES_REQUESTED","createdAt":"2026-10-30T10:00:00Z","statusCheckRollup":[{"conclusion":"FAILURE"}]},{"number":3,"reviewDecision":"","createdAt":"2026-10-31T10:00:00Z","statusCheckRollup":[{"state":"ERROR"}]}]'
OUT_WT="$TMP_ROOT/waiting.md"
run_script --since "$MARKER" --out "$OUT_WT" >/dev/null
assert_contains "waiting: absent input still says not available" "Approvals, CI and review state, worker questions: not available" "$(lead_of "$(cat "$OUT_WT")")"
MORNING_WAITING_DIR="$WAITD" FAKE_GH_PR_OPEN="$OPEN_JSON" run_script --since "$MARKER" --out "$OUT_WT" >/dev/null
lead=$(lead_of "$(cat "$OUT_WT")")
assert_contains "waiting: GOs counted, the oldest picked by date before time" "**2** worker(s) awaiting your GO (oldest bullet 14:05, doc last written $YDAY_D)" "$lead"
assert_contains "waiting: questions counted with the oldest time and the doc's day" "**1** worker question(s) (oldest bullet 09:30, doc last written $TODAY_D)" "$lead"
assert_contains "waiting: review state counted"  "**1** approved, **1** changes requested" "$lead"
assert_contains "waiting: failing checks counted with the oldest PR date" "**2** with failing checks (oldest open PR since 2026-10-29)" "$lead"
if grepq "$lead" -F -- "Approvals, CI and review state, worker questions: not available"; then fail "waiting: computed lines replace the gap"; else pass "waiting: computed lines replace the gap"; fi
# BSD userland (macOS): `date -r` takes epoch seconds, not a file, `date -d` and `stat -c` do not exist, `stat -f %m` does.
# The shim stands in for BSD on a GNU host (it delegates to the real GNU tools); a real BSD host runs the fallback natively above.
if date -d @0 +%F >/dev/null 2>&1; then # gnu-ok: this probe decides whether the host is GNU
BSD_SHIM="$TMP_ROOT/bsd-shim"
mkdir -p "$BSD_SHIM"
REAL_DATE=$(command -v date)
REAL_STAT=$(command -v stat)
cat >"$BSD_SHIM/date" <<FAKE
#!/usr/bin/env bash
case "\$1" in
    -d) exit 1 ;;
    -r) case "\$2" in ''|*[!0-9]*) exit 1 ;; esac; epoch="\$2"; shift 2; exec "$REAL_DATE" -d "@\$epoch" "\$@" ;;
esac
exec "$REAL_DATE" "\$@"
FAKE
cat >"$BSD_SHIM/stat" <<FAKE
#!/usr/bin/env bash
case "\$1" in
    -c) exit 1 ;;
    -f) exec "$REAL_STAT" -c %Y "\$3" ;;
esac
exec "$REAL_STAT" "\$@"
FAKE
chmod +x "$BSD_SHIM/date" "$BSD_SHIM/stat"
PATH="$BSD_SHIM:$PATH" MORNING_WAITING_DIR="$WAITD" run_script --since "$MARKER" --out "$OUT_WT" >/dev/null
assert_contains "waiting: a BSD date and stat still read the worker docs" "worker(s) awaiting your GO (oldest bullet 14:05, doc last written $YDAY_D)" "$(lead_of "$(cat "$OUT_WT")")"
else
    pass "waiting: a BSD date and stat still read the worker docs (native BSD host: the rows above already ran the fallback)"
fi
MANY_OPEN=$(jq -n -c '[range(100) | {number: ., reviewDecision: "", createdAt: "2026-10-29T10:00:00Z", statusCheckRollup: []}]')
MORNING_WAITING_DIR="$WAITD" FAKE_GH_PR_OPEN="$MANY_OPEN" run_script --since "$MARKER" --out "$OUT_WT" >/dev/null
assert_contains "waiting: a capped open-PR read says it saw only the first 100" "(first 100 open PRs only)" "$(lead_of "$(cat "$OUT_WT")")"
MORNING_WAITING_DIR="$WAITD" run_script --since "$MARKER" --out "$OUT_WT" >/dev/null
lead=$(lead_of "$(cat "$OUT_WT")")
assert_contains "waiting: workers read while CI state is unavailable" "**2** worker(s) awaiting your GO" "$lead"
assert_contains "waiting: CI state says not available on its own" "CI and review state: not available" "$lead"
mkdir -p "$TMP_ROOT/emptydocs"
MORNING_WAITING_DIR="$TMP_ROOT/emptydocs" run_script --since "$MARKER" --out "$OUT_WT" >/dev/null
assert_contains "waiting: a root with no worker docs reads not available, not zero" "Approvals, CI and review state, worker questions: not available" "$(lead_of "$(cat "$OUT_WT")")"

echo "TEST: release progress line shows done/total per unreleased version, and reads not available without input"
OUT_REL="$TMP_ROOT/release.md"
run_script --since "$MARKER" --out "$OUT_REL" >/dev/null
assert_contains "release: absent input still says not available" "Release progress: not available" "$(lead_of "$(cat "$OUT_REL")")"
FAKE_JIRA_VERSIONS=$'v1.0.0\ttrue\t2026-09-09\tfalse\nv1.1.3\tfalse\t\tfalse\nv9.9.9\tfalse\t\ttrue' \
    FAKE_JIRA_JQL_OUT=$'KEY\tTYPE\tSTATUS\tSUMMARY\nHIMMEL-1\tTask\tDone\ta\nHIMMEL-2\tBug\tDone\tb\nHIMMEL-3\tTask\tTo Do\tc' \
    run_script --since "$MARKER" --out "$OUT_REL" >/dev/null
lead=$(lead_of "$(cat "$OUT_REL")")
assert_contains "release: done/total shown for the unreleased version" "Release progress: v1.1.3 **2**/3 done" "$lead"
if grepq "$lead" -F -- "v1.0.0"; then fail "release: a released version is left out"; else pass "release: a released version is left out"; fi
if grepq "$lead" -F -- "v9.9.9"; then fail "release: an archived version is left out"; else pass "release: an archived version is left out"; fi
FAKE_JIRA_VERSIONS=$'2026 Q4\tfalse\t\tfalse\nbad"name\tfalse\t\tfalse' \
    FAKE_JIRA_JQL_OUT=$'HIMMEL-1\tTask\tDone\ta\nHIMMEL-3\tTask\tTo Do\tc' \
    run_script --since "$MARKER" --out "$OUT_REL" >/dev/null
lead=$(lead_of "$(cat "$OUT_REL")")
assert_contains "release: a version not named vX.Y.Z is read too" "Release progress: 2026 Q4 **1**/2 done" "$lead"
if grepq "$lead" -F -- 'bad"name'; then fail "release: a name with a quote is never put into a query"; else pass "release: a name with a quote is never put into a query"; fi
FAKE_JIRA_VERSIONS=$'v1.1.3\tfalse\t\tfalse' \
    FAKE_JIRA_JQL_OUT="$(awk 'BEGIN { for (i = 1; i <= 1000; i++) printf "K-%d\tTask\tDone\tx\n", i }')" \
    run_script --since "$MARKER" --out "$OUT_REL" >/dev/null
assert_contains "release: a read capped at 1000 rows says so" "Release progress: v1.1.3 **1000**/1000+ done" "$(lead_of "$(cat "$OUT_REL")")"
FAKE_JIRA_VERSIONS=$'v1.1.3\tfalse\t\tfalse' FAKE_JIRA_JQL_OUT="" \
    run_script --since "$MARKER" --out "$OUT_REL" >/dev/null
assert_contains "release: a version with no rows reads not available, not 0/0" "Release progress: not available" "$(lead_of "$(cat "$OUT_REL")")"

# An adopted project: only adopt.sh's portable set plus the report's own files,
# in a repo that is not himmel, with a GitHub origin and no tracker.
echo "TEST: adopted project prints its own report with no tracker"
HIMMEL_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADOPTED="$TMP_ROOT/adopted"
mkdir -p "$ADOPTED"
git init -q --initial-branch=main "$ADOPTED" 2>/dev/null || git init -q "$ADOPTED"
git -C "$ADOPTED" remote add origin git@github.com:acme/widgets.git
while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$HIMMEL_SRC/$f" ] || continue
    mkdir -p "$ADOPTED/$(dirname "$f")"
    cp "$HIMMEL_SRC/$f" "$ADOPTED/$f"
done < <(awk '/^PORTABLE_FILES=\(/{f=1;next} f&&/^\)/{exit} f{print $1}' "$HIMMEL_SRC/scripts/adopt.sh")
if [ -f "$ADOPTED/scripts/handover/generate-morning-briefing.sh" ] && [ -f "$ADOPTED/.claude/commands/morning-report.md" ]; then
    pass "portable set ships the generator and the command"
else
    fail "portable set ships the generator and the command" "missing under $ADOPTED"
fi
git -C "$ADOPTED" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "chore: first"
git -C "$ADOPTED" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "feat: second widget"
OUT_AD="$TMP_ROOT/adopted-report.md"
# Another project's digest in the shared state dir must not reach this report.
mkdir -p "$HIMMEL_FAILURE_REVIEW_DIR"
printf '## Failure review\n\n- failures: 9 rows\n' > "$HIMMEL_FAILURE_REVIEW_DIR/failure-review-$(date +%F).md"
rc=0
( cd "$ADOPTED"; env -u JIRA_PROJECT_KEY -u JIRA_CMD -u TRACKER GH_CMD="$FAKE_GH" \
    FAKE_GH_PR_JSON='[{"number":7,"title":"add widget","mergedAt":"2026-05-25T00:00:00Z"}]' \
    FAKE_GH_PR_ALL='[{"number":8,"state":"OPEN","headRefName":"feat/other","title":"z"}]' \
    bash scripts/handover/generate-morning-briefing.sh --out "$OUT_AD" >"$TMP_ROOT/adopted.out" 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$OUT_AD" ]; then pass "adopted run exits 0 and writes the report"; else fail "adopted run exits 0 and writes the report" "rc=$rc: $(head -3 "$TMP_ROOT/adopted.out")"; fi
file=$(cat "$OUT_AD" 2>/dev/null || true)
assert_contains "adopted: merged PR row"       "#7"                 "$file"
assert_contains "adopted: own commit listed"   "feat: second widget" "$file"
assert_contains "adopted: first commit listed (full short history)" "chore: first" "$file"
assert_contains "adopted: open PR counted"     "**1** open PR(s)"   "$file"
rm -rf "$HIMMEL_FAILURE_REVIEW_DIR"
assert_contains "adopted: no tracker said so"  "No Jira tracker configured" "$file"
assert_contains "adopted: marker names the whole history" "Source markers: the whole history" "$file"
if grepq "$file" -F -- "--since start of history"; then fail "adopted: marker does not offer a non-revision as --since"; else pass "adopted: marker does not offer a non-revision as --since"; fi
for bad in "jira unavailable" "HIMMEL" "/pr-check" "/clean" "Prompt cache" "Failure review"; do
    # An absent report must not pass the absence checks.
    if ! grepq "$file" -F -- "Morning Report" || grepq "$file" -F -- "$bad"; then fail "adopted: no '$bad' in the report"; else pass "adopted: no '$bad' in the report"; fi
done

echo "TEST: adopted project with a tracker prints the tracker sections"
OUT_ADT="$TMP_ROOT/adopted-tracker.md"
rc=0
( cd "$ADOPTED"; env -u JIRA_PROJECT_KEY GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" \
    FAKE_JIRA_DONE_OUT=$'ACME-3\tTask\tDone\tPolish' \
    bash scripts/handover/generate-morning-briefing.sh --out "$OUT_ADT" >/dev/null 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ]; then pass "adopted+tracker: run exits 0"; else fail "adopted+tracker: run exits 0" "rc=$rc"; fi
file=$(cat "$OUT_ADT" 2>/dev/null || true)
assert_contains "adopted+tracker: Done row" "ACME-3" "$file"
if ! grepq "$file" -F -- "Morning Report" || grepq "$file" -F -- "No Jira tracker configured"; then fail "adopted+tracker: not called trackerless"; else pass "adopted+tracker: not called trackerless"; fi

echo "TEST: an invalid tracker setting is named, not called absent"
OUT_ADI="$TMP_ROOT/adopted-invalid-tracker.md"
rc=0
( cd "$ADOPTED"; env -u JIRA_PROJECT_KEY -u JIRA_CMD TRACKER=jira GH_CMD="$FAKE_GH" \
    bash scripts/handover/generate-morning-briefing.sh --out "$OUT_ADI" >/dev/null 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ]; then pass "invalid tracker: run exits 0"; else fail "invalid tracker: run exits 0" "rc=$rc"; fi
file=$(cat "$OUT_ADI" 2>/dev/null || true)
assert_contains "invalid tracker: setting named" "tracker setting is invalid" "$file"

# Shifts, chiefs and per-shift spend ---------------------------------
# The generator reads the shift record (shifts.jsonl), counts each shift id in exactly one
# report (the first made after its row is written), and prints the window, the chiefs and a
# per-shift spend table whose columns carry a source mark and are never summed.

SH_DIR="$TMP_ROOT/shifts"
mkdir -p "$SH_DIR"
SH_FILE="$SH_DIR/shifts.jsonl"
ROW_NIGHT='{"id":"2026-10-27T20:00:00+01:00","name":"night","opened":"2026-10-27T20:00:00+01:00","closed":"2026-10-28T00:10:00+01:00","why":"idle","zone":"local","chiefs":[{"name":"HY-roadmap-chief","bucket":"roadmap","span":{"start":"2026-10-27T20:00:00+01:00","end":"2026-10-28T00:10:00+01:00","approx":false},"prs":[11]}],"buckets":["roadmap"],"gap":0}'
ROW_DAY='{"id":"2026-10-28T08:00:00+01:00","name":"day","opened":"2026-10-28T08:00:00+01:00","closed":"2026-10-28T20:00:00+01:00","why":"cut","zone":"local","chiefs":[{"name":"IC-roadmap-chief","bucket":"roadmap","span":{"start":"2026-10-28T08:00:00+01:00","end":"2026-10-28T20:00:00+01:00","approx":false},"prs":[12,13]}],"buckets":["roadmap"],"gap":0}'
ROW_EVE='{"id":"2026-10-28T20:00:00+01:00","name":"night","opened":"2026-10-28T20:00:00+01:00","closed":"2026-10-29T08:00:00+01:00","why":"cut","zone":"local","chiefs":[{"name":"IJ-roadmap-chief","bucket":"roadmap","span":{"start":"2026-10-28T20:00:00+01:00","end":"2026-10-29T08:00:00+01:00","approx":false},"prs":[14]}],"buckets":["roadmap"],"gap":0}'

echo "TEST: a shift whose close is written after midnight is counted in exactly one report"
printf '%s\n' "$ROW_NIGHT" > "$SH_FILE"
SH_OUT1="$SH_DIR/r-10-28.md"; SH_OUT2="$SH_DIR/r-10-29.md"
SHIFTS_FILE="$SH_FILE" MORNING_TODAY=2026-10-28 run_script --since "$MARKER" --out "$SH_OUT1" >/dev/null
printf '%s\n' "$ROW_DAY" >> "$SH_FILE"
SHIFTS_FILE="$SH_FILE" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_OUT2" >/dev/null
r1=$(cat "$SH_OUT1"); r2=$(cat "$SH_OUT2") # read-sink-ok: both files are this suite's own outputs under its temp dir
assert_contains "shifts: the late-closed night shift is in the first report" "2026-10-27T20:00:00+01:00" "$r1"
if grepq "$r2" -F -- "2026-10-27T20:00:00+01:00"; then fail "shifts: the night shift is not counted again in the next report"; else pass "shifts: the night shift is not counted again in the next report"; fi
assert_contains "shifts: the day shift written later is in the next report" "2026-10-28T08:00:00+01:00" "$r2"
if grepq "$r1" -F -- "2026-10-28T08:00:00+01:00"; then fail "shifts: the day shift is not in the earlier report"; else pass "shifts: the day shift is not in the earlier report"; fi
SHIFTS_FILE="$SH_FILE" MORNING_TODAY=2026-10-28 run_script --since "$MARKER" --out "$SH_OUT1" >/dev/null
if grepq "$(cat "$SH_OUT1")" -F -- "2026-10-28T08:00:00+01:00"; then fail "shifts: re-running an older day does not take a later shift"; else pass "shifts: re-running an older day does not take a later shift"; fi
SHIFTS_FILE="$SH_FILE" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_OUT2" >/dev/null
assert_contains "shifts: re-running the same day keeps its shift" "2026-10-28T08:00:00+01:00" "$(cat "$SH_OUT2")" # read-sink-ok: this suite's own output under its temp dir
printf '%s\n' "$ROW_EVE" >> "$SH_FILE"
SHIFTS_FILE="$SH_FILE" MORNING_TODAY=2026-10-29 run_script --dry-run --since "$MARKER" >/dev/null
SHIFTS_FILE="$SH_FILE" MORNING_TODAY=2026-10-30 run_script --since "$MARKER" --out "$SH_DIR/r-10-30.md" >/dev/null
assert_contains "shifts: a dry run takes no shift, so the next real report counts it" "2026-10-28T20:00:00+01:00" "$(cat "$SH_DIR/r-10-30.md")"

echo "TEST: no shift record reads not available"
SHIFTS_FILE="" run_script --since "$MARKER" --out "$SH_DIR/none.md" >/dev/null
assert_contains "shifts: no record says so" "Shifts: not available" "$(cat "$SH_DIR/none.md")"

echo "TEST: PRs merged per shift is counted over [opened, closed); a PR merged at the close time counts in the next shift"
SH_FILE2="$SH_DIR/shifts2.jsonl"
printf '%s\n%s\n' "$ROW_DAY" "$ROW_EVE" > "$SH_FILE2"
PRS='[{"number":11,"title":"feat: A-1 early","mergedAt":"2026-10-28T06:59:59Z"},{"number":12,"title":"feat: A-2 inside day","mergedAt":"2026-10-28T10:00:00Z"},{"number":13,"title":"feat: A-3 at the close","mergedAt":"2026-10-28T19:00:00Z"},{"number":14,"title":"feat: A-4 inside night","mergedAt":"2026-10-29T03:00:00Z"}]'
FAKE_GH_SEARCH_FROM=2026-10-27 FAKE_GH_PR_JSON="$PRS" SHIFTS_FILE="$SH_FILE2" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_DIR/prs.md" --since-date 2026-10-28 >/dev/null
prs=$(cat "$SH_DIR/prs.md")
cell() { awk -F'|' -v id="$1" -v col="$2" 'index($2, id) { gsub(/^ +| +$/, "", $col); print $col; exit }' <<< "$3"; }
shift_row() { grep -E "^\| (day|night) $1 \|" <<< "$2" | head -1; }
day_prs=$(cell "2026-10-28T08:00:00+01:00" 4 "$prs"); night_prs=$(cell "2026-10-28T20:00:00+01:00" 4 "$prs")
if [ "$day_prs" = "1" ]; then pass "prs: the day shift counts only the PR merged inside [opened, closed)"; else fail "prs: the day shift counts only the PR merged inside [opened, closed)" "got '$day_prs'"; fi
if [ "$night_prs" = "2" ]; then pass "prs: the PR merged at the close time counts in the next shift"; else fail "prs: the PR merged at the close time counts in the next shift" "got '$night_prs'"; fi
assert_contains "prs: the bar names both windows" "Spend per shift covers each shift over its own [opened, closed)" "$prs"
assert_contains "prs: the report window is named" "The tiles, Completed and Chiefs cover 2026-10-29 00:00 to 2026-10-30 00:00" "$prs"

echo "TEST: shift times stored to the minute (no seconds, the real shift.ts form) still name the shift and count its PRs"
SH_FILE2M="$SH_DIR/shifts2m.jsonl"
{ jq -c 'walk(if type == "string" then sub(":00\\+01:00$"; "+01:00") else . end)' <<< "$ROW_DAY"; jq -c 'walk(if type == "string" then sub(":00\\+01:00$"; "+01:00") else . end)' <<< "$ROW_EVE"; } > "$SH_FILE2M"
FAKE_GH_SEARCH_FROM=2026-10-27 FAKE_GH_PR_JSON="$PRS" SHIFTS_FILE="$SH_FILE2M" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_DIR/prs-min.md" --since-date 2026-10-28 >/dev/null
prsm=$(cat "$SH_DIR/prs-min.md")
day_prs_m=$(cell "2026-10-28T08:00+01:00" 4 "$prsm"); night_prs_m=$(cell "2026-10-28T20:00+01:00" 4 "$prsm")
if [ "$day_prs_m" = "1" ]; then pass "prs: a minute-form day shift counts only the PR merged inside it"; else fail "prs: a minute-form day shift counts only the PR merged inside it" "got '$day_prs_m'"; fi
if [ "$night_prs_m" = "2" ]; then pass "prs: a minute-form night shift counts the PR merged at the day's close"; else fail "prs: a minute-form night shift counts the PR merged at the day's close" "got '$night_prs_m'"; fi

echo "TEST: the per-shift PR query searches from the day before the earliest shift opened (a stub that accepts any date cannot catch a wrong one)"
FAKE_GH_SEARCH_FROM=2099-01-01 FAKE_GH_PR_JSON="$PRS" SHIFTS_FILE="$SH_FILE2" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_DIR/prs-wrong-date.md" --since-date 2026-10-28 >/dev/null
day_prs_w=$(cell "2026-10-28T08:00:00+01:00" 4 "$(cat "$SH_DIR/prs-wrong-date.md")") # read-sink-ok: this suite's own output under its temp dir
if [ "$day_prs_w" = "0" ]; then pass "prs: a search from the wrong day finds no PRs, so the right-day rows above are a real check"; else fail "prs: a search from the wrong day finds no PRs, so the right-day rows above are a real check" "got '$day_prs_w'"; fi

echo "TEST: spend per shift shows a source mark per column, sums no column, and reads not available for a missing source"
FAKE_SPEND_SH="$TMP_ROOT/shift-spend-per-shift.sh"
cat >"$FAKE_SPEND_SH" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
{"window":{"since":"s","until":"u"},"fields":{
 "claude_bank":{"status":"ok","source":"cadence log: usage samples","unit":"percent","five_hour":{"peak":41},"seven_day":{"delta":7.5}},
 "codex_tokens":{"status":"ok","source":"codex rollouts: token_count","unit":"tokens","value":3400},
 "codex_bank":{"status":"not available"},
 "api_cost":{"status":"ok","source":"local-priced: launch records","unit":"USD","value":"2.5"},
 "openrouter":{"status":"not available"}}}
JSON
FAKE
chmod +x "$FAKE_SPEND_SH"
MORNING_SHIFT_SPEND_CMD="$FAKE_SPEND_SH" SHIFTS_FILE="$SH_FILE2" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_DIR/spend.md" >/dev/null
sp=$(cat "$SH_DIR/spend.md")
dayrow=$(shift_row "2026-10-28T08:00:00\\+01:00" "$sp")
assert_contains "spend table: header names the spend columns" "| Claude bank | Codex tokens | Codex bank | API \$ | OpenRouter \$ |" "$sp"
assert_contains "spend table: the Claude bank cell carries its source mark" "41% (cadence log)" "$dayrow"
assert_contains "spend table: the Codex tokens cell carries its source mark" "3400 tokens (codex rollouts)" "$dayrow"
assert_contains "spend table: the API cell carries its source mark" "\$2.50 (local-priced)" "$dayrow"
assert_contains "spend table: a missing source reads not available" "not available" "$dayrow"
if grepq "$sp" -F -- "Spend per shift: total"; then fail "spend table: no summed column"; else pass "spend table: no summed column"; fi
MORNING_SHIFT_SPEND_CMD="false" SHIFTS_FILE="$SH_FILE2" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_DIR/spend-na.md" >/dev/null
dayrow=$(shift_row "2026-10-28T08:00:00\\+01:00" "$(cat "$SH_DIR/spend-na.md")")
assert_contains "spend table: a failing reader leaves every spend cell not available" "| not available | not available | not available | not available | not available |" "$dayrow"

echo "TEST: the Chiefs section lists each chief of the counted shifts with its span and shift"
assert_contains "chiefs: heading"     "## 👥 Chiefs" "$sp"
assert_contains "chiefs: a chief row" "IC-roadmap-chief" "$sp"

echo "TEST: a report that could not be written does not claim its shifts"
SH_FILE3="$SH_DIR/shifts3.jsonl"
printf '%s\n' "$ROW_DAY" > "$SH_FILE3"
: > "$SH_DIR/not-a-dir"
SHIFTS_FILE="$SH_FILE3" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_DIR/not-a-dir/r.md" >/dev/null 2>&1 || true
SHIFTS_FILE="$SH_FILE3" MORNING_TODAY=2026-10-30 run_script --since "$MARKER" --out "$SH_DIR/after-failed.md" >/dev/null
assert_contains "shifts: a shift whose report failed to write is counted by the next report" "2026-10-28T08:00:00+01:00" "$(cat "$SH_DIR/after-failed.md")"

echo "TEST: the Waiting snapshot is the last clock cut's, not a later idle close's empty one"
SH_FILE4="$SH_DIR/shifts4.jsonl"
WAIT_CUT=$(jq -c '. + {waiting:[{kind:"go",ticket:"HIMMEL-1",title:"ship the thing",chief:"IC-roadmap-chief",since:null}]}' <<<"$ROW_DAY")
WAIT_IDLE=$(jq -c '. + {waiting:[]}' <<<"$ROW_NIGHT")
printf '%s\n%s\n' "$WAIT_CUT" "$WAIT_IDLE" > "$SH_FILE4"
SHIFTS_FILE="$SH_FILE4" MORNING_TODAY=2026-10-29 run_script --since "$MARKER" --out "$SH_DIR/wait.md" >/dev/null
assert_contains "waiting snapshot: the cut's row is shown" "ship the thing" "$(cat "$SH_DIR/wait.md")"

# The report is written to the handover root or not at all ----------------

# mk_fixture <dir> [himmel]: a one-commit git repo; "himmel" adds scripts/handover/chief-kit/ (the himmel-checkout marker).
mk_fixture() {
    git init -q --initial-branch=main "$1" 2>/dev/null || git init -q "$1"
    git -C "$1" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    if [ "${2:-}" = himmel ]; then mkdir -p "$1/scripts/handover/chief-kit"; fi
}
# gen_in <dir> <args...>: run the generator in <dir> with HANDOVER_DIR unset (a caller sets it with env); rc in $GEN_RC, stderr in $GEN_ERR.
gen_in() {
    local dir="$1"; shift
    GEN_RC=0
    # A scratch HOME, config dir and cache dir keep the station's own configured root out of the run.
    GEN_ERR=$(cd "$dir" && env -u HANDOVER_DIR HOME="$RT_DIR/home" HIMMEL_CONFIG_DIR="$RT_DIR/conf" HIMMELCTL_CACHE_DIR="$RT_DIR/cache" GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" MORNING_TODAY=2026-10-29 "$@" 2>&1 >/dev/null) || GEN_RC=$?
}
# check <name> <detail> <command...>: pass when the command succeeds.
check() { local name="$1" detail="$2"; shift 2; if "$@"; then pass "$name"; else fail "$name" "$detail"; fi; }
rc_is() { [ "$GEN_RC" -eq "$1" ]; }
gone() { [ ! -e "$1" ]; }
has_text() { grep -qF -- "$2" "$1"; }
RT_DIR="$TMP_ROOT/root-fixtures"; mkdir -p "$RT_DIR/home" "$RT_DIR/conf" "$RT_DIR/cache" "$RT_DIR/cache-nokey"
printf 'UNRELATED_KEY=1\n' > "$RT_DIR/cache-nokey/.env"
HIM_REPO="$RT_DIR/himmel"; mk_fixture "$HIM_REPO" himmel
ENV_REPO="$RT_DIR/himmel-env"; mk_fixture "$ENV_REPO" himmel
mkdir -p "$RT_DIR/envroot"; printf 'HANDOVER_DIR=%s\n' "$RT_DIR/envroot" > "$ENV_REPO/.env"
ADOPT_REPO="$RT_DIR/adopter"; mk_fixture "$ADOPT_REPO"

echo "TEST: a himmel checkout with no handover root refuses and writes nothing"
gen_in "$HIM_REPO" bash "$SCRIPT"
check "no root: exit 1" "got rc=$GEN_RC" rc_is 1
assert_contains "no root: stderr names HANDOVER_DIR" "HANDOVER_DIR" "$GEN_ERR"
assert_contains "no root: stderr says no report was written" "no report was written" "$GEN_ERR"
assert_contains "no root: stderr prints the command shape" "HANDOVER_DIR=<root> bash scripts/handover/generate-morning-briefing.sh" "$GEN_ERR"
check "no root: nothing created in the checkout" "handovers/ exists" gone "$HIM_REPO/handovers"

echo "TEST: a himmel checkout with a HANDOVER_DIR that is not a directory refuses too"
gen_in "$HIM_REPO" env HANDOVER_DIR="$RT_DIR/typo" bash "$SCRIPT"
check "typo root: exit 1" "got rc=$GEN_RC" rc_is 1
check "typo root: nothing created in the checkout" "handovers/ exists" gone "$HIM_REPO/handovers"

echo "TEST: controls — HANDOVER_DIR, --out and an adopter checkout still write"
mkdir -p "$RT_DIR/root"
gen_in "$HIM_REPO" env HANDOVER_DIR="$RT_DIR/root" bash "$SCRIPT"
check "HANDOVER_DIR set: exit 0" "rc=$GEN_RC $GEN_ERR" rc_is 0
check "HANDOVER_DIR set: report under the root" "missing or empty" has_text "$RT_DIR/root/morning-report-2026-10-29.md" "Morning Report"
gen_in "$HIM_REPO" bash "$SCRIPT" --out "$RT_DIR/explicit.md"
check "--out with no root: exit 0" "rc=$GEN_RC $GEN_ERR" rc_is 0
check "--out with no root: report at --out" "missing or empty" has_text "$RT_DIR/explicit.md" "Morning Report"
check "--out with no root: nothing in the checkout" "handovers/ exists" gone "$HIM_REPO/handovers"
gen_in "$ENV_REPO" bash "$SCRIPT"
check "root in .env, not exported: exit 0" "rc=$GEN_RC $GEN_ERR" rc_is 0
check "root in .env, not exported: report under that root" "missing or empty" has_text "$RT_DIR/envroot/morning-report-2026-10-29.md" "Morning Report"
check "root in .env, not exported: nothing in the checkout" "handovers/ exists" gone "$ENV_REPO/handovers"
rm -f "$RT_DIR/envroot/morning-report-2026-10-29.md"
gen_in "$ENV_REPO" env HIMMELCTL_CACHE_DIR="$RT_DIR/cache-nokey" bash "$SCRIPT"
check "cache .env without the key: exit 0" "rc=$GEN_RC $GEN_ERR" rc_is 0
check "cache .env without the key: the checkout .env root is read" "missing or empty" has_text "$RT_DIR/envroot/morning-report-2026-10-29.md" "Morning Report"
rm -f "$RT_DIR/envroot/morning-report-2026-10-29.md"
git -C "$ENV_REPO" worktree add -q -b env-wt "$RT_DIR/env-wt" >/dev/null 2>&1
gen_in "$RT_DIR/env-wt" env HIMMELCTL_CACHE_DIR="$RT_DIR/cache-nokey" bash "$SCRIPT"
check "linked worktree: exit 0" "rc=$GEN_RC $GEN_ERR" rc_is 0
check "linked worktree: the primary checkout .env root is read" "missing or empty" has_text "$RT_DIR/envroot/morning-report-2026-10-29.md" "Morning Report"
gen_in "$ADOPT_REPO" bash "$SCRIPT"
check "adopter checkout: exit 0" "rc=$GEN_RC $GEN_ERR" rc_is 0
check "adopter checkout: Mode A still writes" "missing or empty" has_text "$ADOPT_REPO/handovers/morning-report-2026-10-29.md" "Morning Report"

echo "TEST: a failing shift helper is named with its exit code and first stderr line"
FAKE_SHIFT_FAIL="$TMP_ROOT/shift-fail.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "shift-cli: no handover root is set (HANDOVER_DIR)" >&2' 'echo "second line" >&2' 'exit 2' > "$FAKE_SHIFT_FAIL"
chmod +x "$FAKE_SHIFT_FAIL"
gen_in "$ADOPT_REPO" env SHIFTS_FILE="$RT_DIR/shifts.jsonl" MORNING_SHIFT_CMD="$FAKE_SHIFT_FAIL" bash "$SCRIPT" --out "$RT_DIR/helper.md"
check "helper failure: the run still exits 0" "got rc=$GEN_RC" rc_is 0
check "helper failure: the report is still written" "missing or empty helper.md" has_text "$RT_DIR/helper.md" "Morning Report"
assert_contains "helper failure: WARNING carries the exit code" "exit 2" "$GEN_ERR"
assert_contains "helper failure: WARNING carries the first stderr line" "shift-cli: no handover root is set (HANDOVER_DIR)" "$GEN_ERR"
if grepq "$GEN_ERR" -F -- "second line"; then fail "helper failure: only the first stderr line"; else pass "helper failure: only the first stderr line"; fi

# Report day, real Done, no Backlog, remote stale rows, failure review table ----------------------------

# ago <days>: the UTC time that many days before now.
ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ; } # gnu-ok: paired with the BSD date -v form
# dc <repo> <iso date> <subject>: an empty commit with both dates pinned.
dc() { GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git -C "$1" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "$3"; }
# mk_day_repo <dir>: a repo with a tagged first commit on 2026-10-30 and a github origin.
mk_day_repo() {
    git init -q --initial-branch=main "$1" 2>/dev/null || { git init -q "$1"; git -C "$1" symbolic-ref HEAD refs/heads/main; }
    dc "$1" 2026-10-30T12:00:00Z "init"
    git -C "$1" tag v0
    git -C "$1" remote add origin https://github.com/test/test.git
}
# mkref <repo> <branch> <days old>: a remote-tracking branch whose last commit is that old.
mkref() {
    local d c
    d=$(ago "$3")
    c=$(GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git -C "$1" -c user.email=t@test.com -c user.name=test commit-tree -m x -p "$(git -C "$1" rev-parse HEAD)" "$(git -C "$1" rev-parse 'HEAD^{tree}')")
    git -C "$1" update-ref "refs/remotes/origin/$2" "$c"
}
# run_day <repo> <args...>: the generator on report day 2026-11-03, station zone UTC, no operator config.
run_day() {
    local repo="$1"; shift
    ( cd "$repo"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" MORNING_TODAY=2026-11-03 TZ=UTC \
        HIMMEL_LUNA_CONFIG_PATH="$TMP_ROOT/no-config.json" JIRA_PROJECT_KEY=HIMMEL bash "$SCRIPT" "$@" )
}

echo "TEST: Commits are the report day and Done is read from the day's transitions"
DAYREPO="$TMP_ROOT/dayrepo"; mk_day_repo "$DAYREPO"
dc "$DAYREPO" 2026-11-02T10:00:00Z "chore: HIMMEL-801 older day A"
dc "$DAYREPO" 2026-11-02T12:00:00Z "chore: HIMMEL-802 older day B"
dc "$DAYREPO" 2026-11-03T10:00:00Z "feat: HIMMEL-901 day A"
dc "$DAYREPO" 2026-11-03T11:00:00Z "fix: HIMMEL-902 day B"
JLOG="$TMP_ROOT/jira-argv.log"; : >"$JLOG"
OUT_DAY="$TMP_ROOT/day.md"
FAKE_JIRA_LOG="$JLOG" \
    FAKE_JIRA_DONE_OUT=$'HIMMEL-901\tTask\tDone\tDay A\nHIMMEL-950\tBug\tDone\tNo commit' \
    FAKE_GH_PR_JSON='[{"number":77,"title":"feat: HIMMEL-901 day A","mergedAt":"2026-11-03T10:30:00Z"}]' \
    run_day "$DAYREPO" --out "$OUT_DAY" >/dev/null
file=$(cat "$OUT_DAY")
jlog=$(cat "$JLOG")
assert_contains "day: the Commits heading counts only the report day" "Commits (2 on Tue 3 Nov)" "$file"
assert_absent   "day: the since-tag range is not the default window" "since v0" "$(grep -E '^### Commits' <<<"$file" || true)"
assert_contains "day: the report day's commit is listed" "HIMMEL-901 day A" "$file"
assert_absent   "day: a commit of the day before is not listed" "older day A" "$file"
assert_contains "day: the Done query is project scoped and reads transitions" "project = HIMMEL AND status CHANGED TO Done DURING" "$jlog"
assert_contains "day: the Done window is the report day to the next" '("2026-11-03", "2026-11-04")' "$jlog"
assert_absent   "day: the Done list is no longer the status filter" "--status Done" "$jlog"
assert_contains "day: the Done heading names the day and the count" "Moved to Done on Tue 3 Nov (2)" "$file"
assert_contains "day: a Done row names the merged PR that carries its key" "HIMMEL-901 — Task — Day A — PR #77" "$file"
assert_contains "day: a ticket Done without a commit is still listed" "HIMMEL-950 — Bug — No commit" "$file"
assert_contains "day: the lead counts the day's Done" "**2** Done that day" "$(lead_of "$file")"
OUT_DAYS="$TMP_ROOT/day-since.md"
run_day "$DAYREPO" --since v0 --out "$OUT_DAYS" >/dev/null
assert_contains "day: --since stays an explicit override and the heading says since" "Commits (4 since v0)" "$(cat "$OUT_DAYS")"
OUT_DAYE="$TMP_ROOT/day-empty.md"
( cd "$DAYREPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" MORNING_TODAY=2026-11-05 TZ=UTC HIMMEL_LUNA_CONFIG_PATH="$TMP_ROOT/no-config.json" \
    bash "$SCRIPT" --out "$OUT_DAYE" >/dev/null )
assert_contains "day: a day without commits says so" "No commits found on Thu 5 Nov" "$(cat "$OUT_DAYE")"

echo "TEST: the report day's zone is pinned on the git call (report_day=utc vs the station zone)"
ZONEREPO="$TMP_ROOT/zonerepo"; mk_day_repo "$ZONEREPO"
dc "$ZONEREPO" 2026-11-02T22:00:00Z "chore: early-utc"
dc "$ZONEREPO" 2026-11-03T23:30:00Z "feat: late-utc"
printf '{"reports":{"report_day":"utc"}}\n' > "$TMP_ROOT/utc-config.json"
OUT_ZU="$TMP_ROOT/zone-utc.md"; OUT_ZL="$TMP_ROOT/zone-local.md"
( cd "$ZONEREPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" MORNING_TODAY=2026-11-03 TZ=AEST-10 HIMMEL_LUNA_CONFIG_PATH="$TMP_ROOT/utc-config.json" \
    bash "$SCRIPT" --out "$OUT_ZU" >/dev/null )
( cd "$ZONEREPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" MORNING_TODAY=2026-11-03 TZ=AEST-10 HIMMEL_LUNA_CONFIG_PATH="$TMP_ROOT/no-config.json" \
    bash "$SCRIPT" --out "$OUT_ZL" >/dev/null )
zu=$(cat "$OUT_ZU"); zl=$(cat "$OUT_ZL") # read-sink-ok: both paths are this test's own mktemp outputs, not argv or env
assert_contains "zone utc: the heading counts one commit" "Commits (1 on Tue 3 Nov)" "$zu"
assert_contains "zone utc: a 23:30 UTC commit counts on its UTC day" "late-utc" "$zu"
assert_absent   "zone utc: the +10 local morning of the next UTC day does not shift the window" "early-utc" "$zu"
assert_contains "zone local: the station zone (+10) takes the commit that is 08:00 there" "early-utc" "$zl"
assert_absent   "zone local: the 23:30 UTC commit is the next local day" "late-utc" "$zl"

echo "TEST: the day window is half open and a commit dated out of order does not end the walk"
EDGEREPO="$TMP_ROOT/edgerepo"; mk_day_repo "$EDGEREPO"
dc "$EDGEREPO" 2026-11-03T00:00:00Z "chore: at-day-start"
dc "$EDGEREPO" 2026-11-03T10:00:00Z "feat: hidden-by-skew"
n=1; while [ "$n" -le 7 ]; do dc "$EDGEREPO" 2026-10-31T10:00:00Z "chore: skew-$n"; n=$((n+1)); done
dc "$EDGEREPO" 2026-11-04T00:00:00Z "chore: at-next-midnight"
OUT_EDGE="$TMP_ROOT/edge.md"
run_day "$EDGEREPO" --out "$OUT_EDGE" >/dev/null
edge=$(cat "$OUT_EDGE")
assert_contains "edge: a commit at the day's first second counts" "at-day-start" "$edge"
assert_absent   "edge: a commit at the next day's first second does not" "at-next-midnight" "$edge"
assert_contains "edge: a day commit under seven older-dated commits is still counted" "hidden-by-skew" "$edge"
assert_contains "edge: the heading counts exactly the two commits of the day" "Commits (2 on Tue 3 Nov)" "$edge"

echo "TEST: no Backlog section; --backlog-limit is accepted and ignored with a stderr note"
OUT_BL2="$TMP_ROOT/nobacklog.md"
err=$(FAKE_JIRA_TODO=$'HIMMEL-801\tTask\tTo Do\tAlpha' FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing' \
    run_day "$DAYREPO" --out "$OUT_BL2" --backlog-limit 5 2>&1 >/dev/null)
file=$(cat "$OUT_BL2")
if grepq "$file" -E '^## .*Backlog'; then fail "backlog: no Backlog heading"; else pass "backlog: no Backlog heading"; fi
assert_absent   "backlog: the To Do tickets are not listed" "HIMMEL-801" "$file"
assert_absent   "backlog: the suggested order does not offer the backlog" "Pull from the" "$file"
assert_contains "backlog: the TL;DR links once to the Board" "Backlog: on the Board" "$file"
assert_contains "backlog: --backlog-limit says it is ignored" "--backlog-limit is ignored" "$err"

echo "TEST: stale table lists idle remote branches whose PR is not open"
REMREPO="$TMP_ROOT/remrepo"; mk_day_repo "$REMREPO"
for spec in main:20 old-closed:8 old-open:8 recent:3 old-nopr:9 old-merged:10; do mkref "$REMREPO" "${spec%%:*}" "${spec##*:}"; done
git -C "$REMREPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
: > "$REMREPO/.git/FETCH_HEAD"
PRALL='[{"number":91,"state":"CLOSED","headRefName":"old-closed","title":"a"},{"number":92,"state":"OPEN","headRefName":"old-open","title":"b"},{"number":93,"state":"MERGED","headRefName":"old-merged","title":"c"}]'
OUT_RM="$TMP_ROOT/remote-stale.md"
FAKE_GH_PR_ALL="$PRALL" run_day "$REMREPO" --out "$OUT_RM" >/dev/null
rem=$(grep -F '`origin/' "$OUT_RM" || true)
assert_contains "remote: a branch with a CLOSED PR is listed with the delete command" "git push origin --delete old-closed" "$rem"
assert_contains "remote: its row names the PR and its state" "PR #91 CLOSED" "$rem"
assert_contains "remote: a branch with a MERGED PR is listed" "origin/old-merged" "$rem"
assert_contains "remote: an idle branch with no PR is listed" "origin/old-nopr" "$rem"
assert_absent   "remote: a branch with an OPEN PR is never listed" "old-open" "$rem"
assert_absent   "remote: a 3-day-old branch is not listed" "origin/recent" "$rem"
assert_absent   "remote: origin/main is never listed" "origin/main" "$rem"
assert_absent   "remote: origin/HEAD is never listed" "origin/HEAD" "$rem"
assert_contains "remote: the waits line counts the remote rows" "**3** stale branch(es)" "$(lead_of "$(cat "$OUT_RM")")"
assert_contains "remote: the report says how fresh the remote refs are" "Remote refs as last fetched" "$(cat "$OUT_RM")"
OUT_RM2="$TMP_ROOT/remote-stale2.md"
FAKE_GH_PR_ALL="$PRALL" STALE_BRANCH_DAYS=2 run_day "$REMREPO" --out "$OUT_RM2" >/dev/null
assert_contains "remote: STALE_BRANCH_DAYS lowers the idle bar" "origin/recent" "$(cat "$OUT_RM2")"
OUT_RM3="$TMP_ROOT/remote-stale3.md"
rc=0
FAKE_GH_PR_ALL="$PRALL" STALE_BRANCH_DAYS=08 run_day "$REMREPO" --out "$OUT_RM3" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "remote: STALE_BRANCH_DAYS=08 is decimal, not an octal error"; else fail "remote: STALE_BRANCH_DAYS=08 is decimal, not an octal error" "rc=$rc"; fi
assert_contains "remote: STALE_BRANCH_DAYS=08 still lists the 9-day-old branch" "origin/old-nopr" "$(cat "$OUT_RM3" 2>/dev/null || true)"

echo "TEST: an open PR that fell out of the capped all-state list is still never listed"
OUT_RM4="$TMP_ROOT/remote-stale4.md"
PRALL_NOOPEN='[{"number":91,"state":"CLOSED","headRefName":"old-closed","title":"a"},{"number":93,"state":"MERGED","headRefName":"old-merged","title":"c"}]'
FAKE_GH_PR_ALL="$PRALL_NOOPEN" FAKE_GH_PR_OPENLIST='[{"headRefName":"old-open"}]' run_day "$REMREPO" --out "$OUT_RM4" >/dev/null
rem4=$(grep -F '`origin/' "$OUT_RM4" || true)
assert_absent   "open list: an open PR missing from the all-state list gets no row" "old-open" "$rem4"
assert_absent   "open list: it gets no delete command" "--delete old-open" "$(cat "$OUT_RM4")"
assert_contains "open list: a closed PR still gets its row" "git push origin --delete old-closed" "$rem4"

echo "TEST: a branch missing from an all-state list that hit its cap is PR unknown, with no delete command"
OUT_RM5="$TMP_ROOT/remote-stale5.md"
PRCAP=$(jq -nc '[range(500) | {number: (. + 1000), state: "MERGED", headRefName: ("capped-\(.)"), title: "t"}]')
FAKE_GH_PR_ALL="$PRCAP" run_day "$REMREPO" --out "$OUT_RM5" >/dev/null
rem5=$(grep -F '`origin/' "$OUT_RM5" || true)
assert_contains "cap: a miss reads PR unknown" "PR unknown" "$rem5"
assert_absent   "cap: a miss gets no delete command" "git push origin --delete old-nopr" "$(cat "$OUT_RM5")"

echo "TEST: an open-PR list that hit its cap skips the remote rows"
OUT_RM6="$TMP_ROOT/remote-stale6.md"
OPENCAP=$(jq -nc '[range(500) | {headRefName: ("open-\(.)")}]')
FAKE_GH_PR_ALL="$PRALL_NOOPEN" FAKE_GH_PR_OPENLIST="$OPENCAP" run_day "$REMREPO" --out "$OUT_RM6" >/dev/null 2>&1
rem6=$(grep -F '`origin/' "$OUT_RM6" || true)
assert_absent "open cap: no remote row is listed" "origin/" "$rem6"
assert_absent "open cap: no delete command is offered" "git push origin --delete" "$(cat "$OUT_RM6")"

echo "TEST: sixteen or more idle branches print 15 rows and a count by kind"
MANYREPO="$TMP_ROOT/manyrepo"; mk_day_repo "$MANYREPO"
n=1; while [ "$n" -le 20 ]; do mkref "$MANYREPO" "idle-$n" 9; n=$((n+1)); done
OUT_MANY="$TMP_ROOT/many-stale.md"
FAKE_GH_PR_ALL='[]' run_day "$MANYREPO" --out "$OUT_MANY" >/dev/null
rows=$(grep -cF '| `origin/' "$OUT_MANY" || true)
if [ "$rows" = "15" ]; then pass "many: 15 remote rows are printed"; else fail "many: 15 remote rows are printed" "got $rows"; fi
assert_contains "many: the rest are counted by kind" "and 5 more (0 worktree, 5 remote)" "$(cat "$OUT_MANY")"
assert_contains "many: the waits line counts all twenty" "**20** stale branch(es)" "$(lead_of "$(cat "$OUT_MANY")")"

echo "TEST: the failure review is a table from the digest's JSON, with no worker name"
FRV="$SCRIPT_DIR/../eval/worker-digest/failure_review.py"
FRD="$TMP_ROOT/frfix"; mkdir -p "$FRD/out"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FRD/notify"; chmod +x "$FRD/notify"
fr_row() { # <class> <worker>
    jq -nc --arg w "$2" --arg c "$1" '{v:1, ts:"2026-11-03T08:00:00Z", host:"h", source:"scripts/eval/worker-digest/worker_ledger.py", kind:"leg-failure",
        session:"4713c1a5-0000-4000-8000-000000000001", leg:$w, console:"c", ticket:"HIMMEL-4713", pr:2030, agent:{id:"main", role:"leg", kind:"k", model:"claude-opus-5-5"},
        class:$c, failure:($c | split("/")[0]), count:1, identical_retry:0, recovered:false, first_ts:1, last_ts:2, tool_call_ids:["t"]}' >>"$FRD/ledger.jsonl"
}
i=1
for cls in denied/guard-a denied/guard-b denied/guard-c denied/guard-d denied/guard-e denied/guard-f error/tool-g error/tool-h error/tool-i error/tool-j error/tool-k error/tool-l; do
    fr_row "$cls" N7771; [ $((i % 2)) -eq 0 ] && fr_row "$cls" N7772; [ $((i % 3)) -eq 0 ] && fr_row "$cls" N7773
    i=$((i+1))
done
fr_row traj/identical-retry N7771; fr_row traj/zz-other N7772; fr_row traj/zz-other N7773
( export TZ=UTC JIRA_PROJECT_KEY=HIMMEL FAILURE_REVIEW_NOTIFY_CMD="$FRD/notify" FAILURE_REVIEW_FRICTION_CMD="" \
    HIMMEL_EVAL_RUNS_LEDGER="$FRD/never-runs.jsonl" HIMMEL_EVAL_CHANGES_LEDGER="$FRD/never-changes.jsonl" WORKER_SESSION_DIGEST_STATE_DIR="$FRD/never-digest"
  python3 -I "$FRV" --ledger "$FRD/ledger.jsonl" --state "$FRD/state.json" --log "$FRD/log.jsonl" --inbox "$FRD/inbox.md" \
    --out-dir "$FRD/out" --now 2026-11-03T12:00:00Z --jira-bin "$FRD/never-jira" >"$FRD/run.out" 2>&1 ) || fail "failure review fixture: failure_review.py ran" "$(head -c 300 "$FRD/run.out")"
FRJSON="$FRD/out/failure-review-2026-11-03.json"
if [ -f "$FRJSON" ] && [ -f "$FRD/out/failure-review-2026-11-03.md" ]; then pass "failure review fixture: the real writer made the .md and the .json"; else fail "failure review fixture: the real writer made the .md and the .json" "$(ls "$FRD/out")"; fi
run_fr() { # <out file>: the report for 2026-11-03 reading the fixture digest dir
    HIMMEL_FAILURE_REVIEW_DIR="$FRD/out" run_day "$DAYREPO" --out "$1" >/dev/null
}
OUT_FR="$TMP_ROOT/fr-table.md"
run_fr "$OUT_FR"
file=$(cat "$OUT_FR")
fr_start=$(jq -r '.window.start' "$FRJSON"); fr_end=$(jq -r '.window.end' "$FRJSON")
fr_nclass=$(jq '.classes | length' "$FRJSON"); fr_rows=$(jq '[.classes[].rows] | add' "$FRJSON")
fr_ntraj=$(jq '.totals.classes - (.classes | length)' "$FRJSON"); fr_trows=$(jq '.totals.rows - ([.classes[].rows] | add)' "$FRJSON")
assert_contains "failure table: the header row" "| Class | Kind | Rows | Workers | New or recurring | Route |" "$file"
assert_contains "failure table: a class row carries kind, workers and route" "| denied/guard-" "$file"
assert_contains "failure table: the routing decision is shown" "would-file" "$file"
assert_contains "failure table: the digest's own window is shown verbatim" "$fr_start to $fr_end" "$file"
assert_contains "failure table: only the top 10 classes, the rest counted" "and 2 more classes" "$file"
assert_absent   "failure table: no worker name is printed" "N777" "$file"
assert_absent   "failure table: the raw digest is not pasted" "raw digest" "$file"
if [ "$fr_ntraj" = "2" ]; then pass "count rule: the fixture holds two traj/ classes that classes[] leaves out"; else fail "count rule: the fixture holds two traj/ classes that classes[] leaves out" "got $fr_ntraj"; fi
assert_contains "count rule: the class count is classes[], not totals.classes" "**$fr_nclass** classes" "$file"
assert_contains "count rule: the row count is the sum of classes[]" "**$fr_rows** rows" "$file"
assert_contains "count rule: the trajectory signals are named, not counted as classes" "and $fr_ntraj trajectory signals (not listed) over $fr_trows rows" "$file"
if [ "$(jq 'has("schema_version")' "$FRJSON")" = "false" ]; then pass "schema: the real writer emits no schema_version, so the table above is the absent-version row"; else fail "schema: the real writer emits no schema_version"; fi

echo "TEST: a JSON the reader cannot trust falls back to the raw digest with one line saying why"
FRBAK="$FRD/good.json"; cp "$FRJSON" "$FRBAK"
OUT_FR1="$TMP_ROOT/fr-v1.md"
jq '. + {schema_version: 1}' "$FRBAK" > "$FRJSON"; run_fr "$OUT_FR1"
assert_contains "schema: schema_version 1 is accepted" "| Class | Kind | Rows |" "$(cat "$OUT_FR1")"
OUT_FR2="$TMP_ROOT/fr-v2.md"
jq '. + {schema_version: 2}' "$FRBAK" > "$FRJSON"; run_fr "$OUT_FR2"
file=$(cat "$OUT_FR2")
assert_contains "schema: schema_version 2 is rejected to the raw digest" "raw digest" "$file"
assert_contains "schema: the rejection says why" "JSON was not used" "$file"
assert_contains "schema: the reason names the version" "schema_version 2" "$file"
assert_absent   "schema: no table from a rejected file" "| Class | Kind |" "$file"
OUT_FR3="$TMP_ROOT/fr-bad.md"
printf '{"window": ' > "$FRJSON"; run_fr "$OUT_FR3"
file=$(cat "$OUT_FR3")
assert_contains "schema: malformed JSON is rejected to the raw digest" "raw digest" "$file"
assert_contains "schema: the malformed reason" "not valid JSON" "$file"
OUT_FR4="$TMP_ROOT/fr-missing.md"
jq 'del(.classes[0].rows)' "$FRBAK" > "$FRJSON"; run_fr "$OUT_FR4"
assert_contains "schema: a class row missing a field is rejected" "a required field is missing" "$(cat "$OUT_FR4")"
OUT_FR5="$TMP_ROOT/fr-nojson.md"
rm -f "$FRJSON"; run_fr "$OUT_FR5"
file=$(cat "$OUT_FR5")
assert_contains "no JSON: the raw digest disclosure" "<summary>raw digest</summary>" "$file"
assert_contains "no JSON: the markdown digest is inside it, headings dropped a level" "#### Top classes" "$file"
assert_absent   "no JSON: no 'not used' line when there was no JSON to use" "JSON was not used" "$file"
assert_contains "no JSON: the worker lines are the raw digest's own" "workers N7771" "$file"
OUT_FR6="$TMP_ROOT/fr-nodigest.md"
rm -f "$FRD/out/failure-review-2026-11-03.md"; run_fr "$OUT_FR6"
assert_contains "no digest at all: today's no-digest line" "No failure review digest for 2026-11-03" "$(cat "$OUT_FR6")"

echo "TEST: the five PR list reads ride the read token while main is rate limited"
READTOK=ghp_READTOKEN0123456789
mkdir -p "$TMP_ROOT/ttroot" "$TMP_ROOT/emptyroot" "$TMP_ROOT/tt" "$TMP_ROOT/himmelcfg"
printf 'himmel_github_token_vm2=%s\n' "$READTOK" > "$TMP_ROOT/ttroot/.env"
: > "$TMP_ROOT/emptyroot/.env"
ln -s "$SCRIPT_DIR/chief-kit/fixtures/gh-two-token-stub.sh" "$TMP_ROOT/tt/gh"
TTLOG="$TMP_ROOT/tt.log"
tt_brief() {
    : > "$TTLOG"
    ( cd "$REPO"; env -u GH_CMD GH_READ_ENV_ROOT="$1" PATH="$TMP_ROOT/tt:$PATH" GH_STUB_DELEGATE="$FAKE_GH" GH_STUB_READ_TOKEN="$READTOK" \
        GHLOG="$TTLOG" HIMMEL_SECRETS_KEYRING=off HIMMEL_CONFIG_DIR="$TMP_ROOT/himmelcfg" JIRA_CMD="$FAKE_JIRA" \
        FAKE_GH_SEARCH_FROM=2026-10-27 FAKE_GH_PR_JSON="$PRS" FAKE_GH_PR_OPEN='[]' SHIFTS_FILE="$SH_FILE2" MORNING_TODAY=2026-10-29 \
        bash "$SCRIPT" --since "$MARKER" --out "$2" --since-date 2026-10-28 >/dev/null )
}
tt_logn() { grep -c -E -- "$1" "$TTLOG"; }
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
GH_STUB_MAINFAIL=rate tt_brief "$TMP_ROOT/ttroot" "$TMP_ROOT/tt-spent.md"
tt_spent=$(cat "$TMP_ROOT/tt-spent.md")
tt_day=$(cell "2026-10-28T08:00:00+01:00" 4 "$tt_spent"); tt_night=$(cell "2026-10-28T20:00:00+01:00" 4 "$tt_spent")
if [ "$tt_day" = "1" ] && [ "$tt_night" = "2" ]; then pass "tt: main spent: the shift merged-PR read fills the PRs cells"; else fail "tt: main spent: the shift merged-PR read fills the PRs cells" "day '$tt_day' night '$tt_night'"; fi
assert_contains "tt: main spent: the merged-PR read fills the Completed section" "HIMMEL-901" "$tt_spent"
if [ "$(tt_logn '^tok=read argv=pr list ')" = "5" ]; then pass "tt: main spent: the five PR list reads log tok=read"; else fail "tt: main spent: the five PR list reads log tok=read" "got $(tt_logn '^tok=read argv=pr list ')"; fi
if [ "$(tt_logn '^tok=main ')" = "0" ]; then pass "tt: main spent: no read logs tok=main"; else fail "tt: main spent: no read logs tok=main" "got $(tt_logn '^tok=main ')"; fi
tt_brief "$TMP_ROOT/emptyroot" "$TMP_ROOT/tt-control.md"
if [ "$(tt_logn '^tok=main argv=pr list ')" = "5" ] && [ "$(tt_logn '^tok=read ')" = "0" ]; then pass "tt: control, no read token: the five reads log tok=main"; else fail "tt: control, no read token: the five reads log tok=main" "main $(tt_logn '^tok=main argv=pr list ') read $(tt_logn '^tok=read ')"; fi

# Summary --------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
