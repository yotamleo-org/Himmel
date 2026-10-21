#!/usr/bin/env bash
# Tests for file-deferred-issues.sh: tracker routing (jira | forge | none) and,
# on the forge path, routing through the forge seam. A Jira-configured repo must
# never reach `gh issue create`.
# Exercises the GitHub path (FORGE=github via a `gh` stub on PATH + GH_CMD) and
# the Bitbucket issues-disabled graceful degrade (FORGE=bitbucket, CLI exit 3 →
# warn + exit 0, spec §5.2). No network: every forge call is stubbed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FDI="$SCRIPT_DIR/file-deferred-issues.sh"

PASS=0
FAIL=0
TMP_ROOT=""
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_contains() {  # name haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *)      fail "$1" "expected to contain '$3' in: $2" ;;
    esac
}
assert_not_contains() {  # name haystack needle
    case "$2" in
        *"$3"*) fail "$1" "expected NOT to contain '$3' in: $2" ;;
        *)      pass "$1" ;;
    esac
}
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi; }

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# A git repo with one commit — the script calls `git rev-parse --short HEAD`.
REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
git -C "$REPO" commit -q --allow-empty -m init
# The branch names the PR's ticket: the residual writer files against it.
git -C "$REPO" checkout -q -b feat/tst-5-fixture

# Two deferred-class findings.
INPUT="$TMP_ROOT/review.txt"
cat >"$INPUT" <<'EOF'
src/a.ts:10: NIT: rename foo. use bar.
docs/readme.md: LOW: missing example. add one.
EOF

# ── GitHub path: a `gh` stub on PATH (dedupe/label call bare `gh`) AND via
# GH_CMD (the seam's repo-context + issue-create). ISSUE_LIST_RESULT lets a case
# simulate "duplicate exists" by exporting an issue number.
BIN="$TMP_ROOT/bin"; mkdir -p "$BIN"
# PATH needs the unix form (/c/...): a `C:/...` element mis-splits on the `:`
# PATH separator under Git Bash, so the bare-`gh` dedupe/label calls would fall
# through to the real gh. GH_CMD is invoked directly (not via PATH), so the
# `C:/` form is fine there.
BIN_UNIX=$(cygpath -u "$BIN" 2>/dev/null || printf '%s' "$BIN")
GH_STUB="$BIN/gh"
cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"label create"*)            exit 0 ;;
    *"issue list"*)              printf '%s' "${ISSUE_LIST_RESULT:-}" ;;
    *"issue create"*)            echo "https://github.com/owner/repo/issues/99" ;;
    *) echo "gh-stub: unhandled: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB"

run_gh() {  # runs the filer on the GitHub path; echoes combined stdout+stderr
    ( cd "$REPO" && PATH="$BIN_UNIX:$PATH" JIRA_PROJECT_KEY='' TRACKER='' FORGE=github GH_CMD="$GH_STUB" \
        ISSUE_LIST_RESULT="${ISSUE_LIST_RESULT:-}" \
        bash "$FDI" --pr 1 --input "$INPUT" "$@" 2>&1 )
}

echo "TEST: GitHub path files both findings"
out=$(ISSUE_LIST_RESULT="" run_gh); rc=$?
assert_eq "github files → exit 0" "0" "$rc"
assert_contains "github filed first"  "$out" "filed https://github.com/owner/repo/issues/99"
assert_contains "github summary 2 filed" "$out" "2 filed"

echo "TEST: GitHub path dedupes when an issue already exists"
out=$(ISSUE_LIST_RESULT="42" run_gh); rc=$?
assert_eq "github dedupe → exit 0" "0" "$rc"
assert_contains "github skipped duplicate" "$out" "skipped (duplicate, issue #42)"
assert_not_contains "github dedupe files nothing" "$out" "filed https://github.com"

echo "TEST: GitHub path dry-run files nothing"
out=$(ISSUE_LIST_RESULT="" run_gh --dry-run); rc=$?
assert_eq "github dry-run → exit 0" "0" "$rc"
assert_contains "github dry-run plan" "$out" "skipped (dry-run)"
assert_not_contains "github dry-run no create" "$out" "filed https://github.com"

# ── GitHub path: a REAL create failure (rc neither 0 nor 3) must surface as
# FAILED + exit 3 — NOT be mistaken for the issues-disabled degrade.
BIN2="$TMP_ROOT/bin2"; mkdir -p "$BIN2"
BIN2_UNIX=$(cygpath -u "$BIN2" 2>/dev/null || printf '%s' "$BIN2")
cat >"$BIN2/gh" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"label create"*)            exit 0 ;;
    *"issue list"*)              printf '' ;;
    *"issue create"*)            echo "gh: HTTP 500 boom" >&2; exit 1 ;;
    *) echo "gh-stub2: unhandled: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$BIN2/gh"

echo "TEST: GitHub path surfaces a real create failure (exit 3, not a degrade)"
out=$( cd "$REPO" && PATH="$BIN2_UNIX:$PATH" JIRA_PROJECT_KEY='' TRACKER='' FORGE=github GH_CMD="$BIN2/gh" \
    bash "$FDI" --pr 1 --input "$INPUT" 2>&1 ); rc=$?
assert_eq "github create-fail → exit 3" "3" "$rc"
assert_contains "github FAILED line" "$out" "FAILED"
assert_not_contains "github create-fail not degraded" "$out" "issue tracker appears disabled"

# ── Bitbucket path: issues disabled → CLI `issue create` exits 3 → degrade.
BB_STUB="$TMP_ROOT/bb-stub.sh"
cat >"$BB_STUB" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    "repo view"*)    echo '{"workspace":"ws","repo_slug":"repo","full_name":"ws/repo","default_branch":"main"}' ;;
    "issue create"*) echo "bitbucket: issue create failed: issue tracker is disabled on this repository (404)" >&2; exit 3 ;;
    *) echo "bb-stub: unhandled: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$BB_STUB"

echo "TEST: Bitbucket issues-disabled degrades gracefully (spec §5.2)"
out=$( cd "$REPO" && JIRA_PROJECT_KEY='' TRACKER='' FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" \
    bash "$FDI" --pr 1 --input "$INPUT" 2>&1 ); rc=$?
assert_eq "bitbucket degrade → exit 0" "0" "$rc"
assert_contains "bitbucket warns issues disabled" "$out" "issue tracker appears disabled on this bitbucket repository"
assert_contains "bitbucket names finding 1" "$out" "src/a.ts:10: NIT: rename foo."
assert_contains "bitbucket names finding 2" "$out" "docs/readme.md: LOW: missing example."
assert_not_contains "bitbucket files nothing" "$out" "filed http"
assert_not_contains "bitbucket no summary line" "$out" "file-deferred-issues: summary"

# ── Critic-panel shape: a real captured `critic-panel.sh`
# transcript (`.git/panel-out/claudex+himmel-1449-fetch-health.findings`,
# committed here verbatim) — severity lives in the `## <section>` heading, the
# finding line is `- [id]: text [path:line]`. Quoted heredoc: the content has
# backticks that must NOT be shell-expanded.
PANEL_INPUT="$TMP_ROOT/panel-review.txt"
cat >"$PANEL_INPUT" <<'EOF'
# Critic Panel Review (2/2 critics responded)

## Critical Issues (0 found)

## Important Issues (1 found)
- [codex-1]: A malformed existing `sources` entry can crash `write_state` because `old.get(...)` is called without verifying `old` is an object, preventing future health runs from recovering the state file. [scripts/luna/fetch-health.py:408]

## Suggestions (3 found)
- [codex-2]: The `.env` parser stores raw values without handling common quoting/export syntax, so quoted Bitbucket credentials in `.env` will be sent with quotes and falsely fail authentication. [scripts/luna/fetch-health.py:308]
- [glm-3]: Request.remove_header() (called in AuthScopedRedirectHandler.redirect_request) is Python 3.12+ only; the cadence and test harness fall back to python (3.11) where it raises AttributeError, silently breaking redirect auth-stripping and failing test_redirect_handler_strips_auth_off_scope on that version [scripts/luna/fetch-health.py:74]
- [glm-4]: load_repo_env does not strip surrounding quotes or handle export-prefixed keys in .env lines, which could silently corrupt Bitbucket credentials if the .env file uses either convention (e.g. KEY="value" or export KEY=value) [scripts/luna/fetch-health.py:233]
EOF

run_gh_input() {  # runs the filer against a given --input file on the GitHub path
    ( cd "$REPO" && PATH="$BIN_UNIX:$PATH" JIRA_PROJECT_KEY='' TRACKER='' FORGE=github GH_CMD="$GH_STUB" \
        ISSUE_LIST_RESULT="${ISSUE_LIST_RESULT:-}" \
        bash "$FDI" --pr 1 --input "$1" --dry-run 2>&1 )
}

echo "TEST: critic-panel Suggestions are recognised and planned as deferred (HIMMEL-2068)"
out=$(ISSUE_LIST_RESULT="" run_gh_input "$PANEL_INPUT"); rc=$?
assert_eq "panel dry-run → exit 0" "0" "$rc"
dryrun_lines=$(printf '%s\n' "$out" | grep -c "^skipped (dry-run)")
assert_eq "panel dry-run plans exactly the 3 Suggestions" "3" "$dryrun_lines"
assert_contains "panel finding 1 carries path:line + id" "$out" "scripts/luna/fetch-health.py:308: SUGGESTION: [codex-2]"
assert_contains "panel finding 2 carries path:line + id" "$out" "scripts/luna/fetch-health.py:74: SUGGESTION: [glm-3]"
assert_contains "panel finding 3 carries path:line + id" "$out" "scripts/luna/fetch-health.py:233: SUGGESTION: [glm-4]"
assert_contains "panel recognised-summary line" "$out" "Suggestions=3, Important Issues=1, Critical Issues=0"

echo "TEST: critic-panel Important Issues finding is NOT filed"
assert_not_contains "important-issues finding absent from plan" "$out" "fetch-health.py:408"
assert_not_contains "important-issues codex-1 id absent from plan" "$out" "[codex-1]"

echo "TEST: an unparsable panel line (no bracketed location) is warned, not silently dropped"
MALFORMED_INPUT="$TMP_ROOT/panel-malformed.txt"
cat >"$MALFORMED_INPUT" <<'EOF'
## Suggestions (2 found)
- [glm-1]: A finding with no location bracket at all, just prose.
- [glm-2]: A valid one. [scripts/foo.py:10]
EOF
out=$(ISSUE_LIST_RESULT="" run_gh_input "$MALFORMED_INPUT"); rc=$?
assert_eq "malformed panel line does not abort the run → exit 0" "0" "$rc"
assert_contains "malformed line reported on stderr" "$out" "skipped (unparsable) glm-1: - [glm-1]: A finding with no location bracket"
assert_contains "well-formed sibling line still planned" "$out" "scripts/foo.py:10: SUGGESTION: [glm-2]"

echo "TEST: '## Suggestions (0 found)' with no findings anywhere → no deferred-class findings, exit 0"
ZERO_INPUT="$TMP_ROOT/panel-zero.txt"
cat >"$ZERO_INPUT" <<'EOF'
# Critic Panel Review (2/2 critics responded)

## Critical Issues (0 found)

## Important Issues (0 found)

## Suggestions (0 found)
EOF
out=$(ISSUE_LIST_RESULT="" run_gh_input "$ZERO_INPUT"); rc=$?
assert_eq "zero-findings panel input → exit 0" "0" "$rc"
assert_contains "zero-findings message" "$out" "no deferred-class findings detected in input — nothing to file."
assert_not_contains "zero-findings emits no unparsable warning" "$out" "skipped (unparsable)"

echo "TEST: canonical 'path:LINE: SEV: text' input still parses unchanged (regression)"
out=$(ISSUE_LIST_RESULT="" run_gh_input "$INPUT"); rc=$?
assert_eq "canonical dry-run → exit 0" "0" "$rc"
assert_contains "canonical finding 1 still planned" "$out" "src/a.ts:10: NIT: rename foo. use bar."
assert_contains "canonical finding 2 still planned" "$out" "docs/readme.md: LOW: missing example. add one."


# ── Tracker routing. A gh stub that LOGS every call proves a
# Jira-configured or tracker-less repo never reaches `gh issue create`; a jira
# stub logs its argv and captures the --desc-file body.
GLOG="$TMP_ROOT/gh.log"
LBIN="$TMP_ROOT/logbin"; mkdir -p "$LBIN"
LBIN_UNIX=$(cygpath -u "$LBIN" 2>/dev/null || printf '%s' "$LBIN")
cat >"$LBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GLOG"
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"issue list"*)              printf '' ;;
    *"issue create"*)            echo "https://github.com/owner/repo/issues/99" ;;
esac
STUB
chmod +x "$LBIN/gh"

JLOG="$TMP_ROOT/jira.log"
JDESC="$TMP_ROOT/jira.desc"
JSTUB="$TMP_ROOT/jira-stub.sh"
cat >"$JSTUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$JLOG"
case "$1" in
    list)   [ "${JIRA_LIST_FAIL:-}" = 1 ] && { echo "jira: 500" >&2; exit 1; }
            printf '%s' "${JIRA_LIST_RESULT:-}" ;;
    create) [ "${JIRA_CREATE_FAIL:-}" = 1 ] && { echo "jira: create refused" >&2; exit 1; }
            while [ $# -gt 0 ]; do [ "$1" = --desc-file ] && cp "$2" "$JDESC"; shift; done
            [ "${JIRA_CREATE_DUP:-}" = 1 ] && { echo "Duplicate TST-31"; exit 0; }
            echo "Created TST-7" ;;
esac
STUB
chmod +x "$JSTUB"

run_mode() {  # run_mode <TRACKER> <FORGE> [args...] — gh+jira stubs, logs reset
    local t="$1" f="$2"; shift 2
    : >"$GLOG"; : >"$JLOG"; rm -f "$JDESC"
    ( cd "$REPO" && PATH="$LBIN_UNIX:$PATH" TRACKER="$t" FORGE="$f" GH_CMD="$LBIN/gh" \
        JIRA_PROJECT_KEY="${JKEY-TST}" JIRA_CMD="$JSTUB" GLOG="$GLOG" JLOG="$JLOG" JDESC="$JDESC" \
        JIRA_LIST_RESULT="${JIRA_LIST_RESULT:-}" JIRA_LIST_FAIL="${JIRA_LIST_FAIL:-}" JIRA_CREATE_FAIL="${JIRA_CREATE_FAIL:-}" JIRA_CREATE_DUP="${JIRA_CREATE_DUP:-}" \
        bash "$FDI" --pr 1 --input "$INPUT" "$@" 2>&1 )
}

echo "TEST: tracker=jira files ONE ticket, never calls gh (RED: gh issue create)"
out=$(run_mode jira github); rc=$?
assert_eq "jira → exit 0" "0" "$rc"
assert_contains "jira prints tracker=jira" "$out" "tracker=jira"
assert_contains "jira prints the created key" "$out" "filed TST-7"
assert_eq "jira never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"
assert_eq "jira creates exactly one ticket" "1" "$(grep -c '^create' "$JLOG")"
assert_contains "jira create labels cr-deferred" "$(cat "$JLOG")" "--labels cr-deferred"
desc=$(cat "$JDESC" 2>/dev/null || true)
assert_contains "jira body has Impact" "$desc" "## Impact"
assert_contains "jira body has Plan" "$desc" "## Plan"
assert_contains "jira body has DoD" "$desc" "## DoD"
assert_contains "jira body has Agent detail" "$desc" "## Agent detail"
assert_contains "jira body numbers finding 1" "$desc" "1. "
assert_contains "jira body numbers finding 2" "$desc" "2. "
assert_contains "jira body carries both findings" "$desc" "docs/readme.md: LOW: missing example."
assert_contains "jira body names the PR" "$desc" "PR #1"
assert_contains "jira body carries the dedupe marker" "$desc" "crbatch"

echo "TEST: tracker=jira dedupe marker is repo-scoped (same findings, another repo, another marker)"
git -C "$REPO" config remote.origin.url "https://example.test/one/repo.git"
run_mode jira github --dry-run >/dev/null
marker_one=$(grep -o 'crbatch[0-9a-f]*' "$JLOG" | head -n1)
git -C "$REPO" config remote.origin.url "https://example.test/two/repo.git"
run_mode jira github --dry-run >/dev/null
marker_two=$(grep -o 'crbatch[0-9a-f]*' "$JLOG" | head -n1)
git -C "$REPO" config --unset remote.origin.url
assert_contains "repo-scoped marker present" "$marker_one" "crbatch"
if [ "$marker_one" != "$marker_two" ]; then pass "markers differ across repos"; else fail "markers equal across repos" "$marker_one"; fi

echo "TEST: tracker=jira dry-run creates nothing"
out=$(run_mode jira github --dry-run); rc=$?
assert_eq "jira dry-run → exit 0" "0" "$rc"
assert_contains "jira dry-run plan" "$out" "skipped (dry-run)"
assert_eq "jira dry-run no create" "0" "$(grep -c '^create' "$JLOG")"
assert_eq "jira dry-run never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"

echo "TEST: tracker=jira dedupes on an existing ticket"
out=$(JIRA_LIST_RESULT="TST-3	Task	Done	old" run_mode jira github); rc=$?
assert_eq "jira dedupe → exit 0" "0" "$rc"
assert_contains "jira skipped duplicate" "$out" "skipped (duplicate, TST-3)"
assert_eq "jira dedupe no create" "0" "$(grep -c '^create' "$JLOG")"

echo "TEST: tracker=jira dedupe lookup failure is fail-closed (exit 4)"
out=$(JIRA_LIST_FAIL=1 run_mode jira github); rc=$?
assert_eq "jira lookup-fail → exit 4" "4" "$rc"
assert_eq "jira lookup-fail no create" "0" "$(grep -c '^create' "$JLOG")"
assert_eq "jira lookup-fail never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"

echo "TEST: tracker=jira create failure exits 3 and does NOT fall back to GitHub"
out=$(JIRA_CREATE_FAIL=1 run_mode jira github); rc=$?
assert_eq "jira create-fail → exit 3" "3" "$rc"
assert_contains "jira FAILED line" "$out" "FAILED"
assert_eq "jira create-fail never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"

echo "TEST: tracker=jira files through the residual writer (RED: raw create, no --residual-of)"
out=$(run_mode jira github); rc=$?
assert_eq "writer → exit 0" "0" "$rc"
assert_contains "create carries --residual-of from the branch ticket" "$(grep '^create' "$JLOG")" "--residual-of TST-5"
assert_contains "create defaults --fu-class polish" "$(grep '^create' "$JLOG")" "--fu-class polish"
assert_contains "create defaults --class unclassified" "$(grep '^create' "$JLOG")" "--class unclassified"
assert_contains "create keeps the cr-deferred label" "$(grep '^create' "$JLOG")" "--labels cr-deferred"

echo "TEST: explicit --residual-of / --fu-class / --class override the defaults"
out=$(run_mode jira github --residual-of TST-9 --fu-class hardening --class shell-quoting); rc=$?
assert_eq "override → exit 0" "0" "$rc"
assert_contains "override parent" "$(grep '^create' "$JLOG")" "--residual-of TST-9"
assert_contains "override fu-class" "$(grep '^create' "$JLOG")" "--fu-class hardening"
assert_contains "override class" "$(grep '^create' "$JLOG")" "--class shell-quoting"

echo "TEST: the batch carries the class its findings hold in the CR ledger (RED: always unclassified)"
LEDGER_CLS="$TMP_ROOT/ledger-class.jsonl"
printf '%s\n' \
    '{"kind":"finding","head":"aaaaaaa","branch":"feat/tst-5-fixture","finding_id":"c1","file":"src/a.ts","line":10,"verdict":"deferred"}' \
    '{"kind":"amend","target_head":"aaaaaaa","branch":"feat/tst-5-fixture","finding_id":"c1","set":{"class":"unattributed"}}' \
    '{"kind":"amend","target_head":"aaaaaaa","branch":"feat/tst-5-fixture","finding_id":"c1","set":{"class":"shell-quoting"}}' \
    '{"kind":"finding","head":"aaaaaaa","branch":"feat/other","finding_id":"c9","file":"docs/readme.md","line":1,"verdict":"deferred"}' \
    '{"kind":"amend","target_head":"aaaaaaa","branch":"feat/other","finding_id":"c9","set":{"class":"other-branch-class"}}' >"$LEDGER_CLS"
out=$(CR_LEDGER="$LEDGER_CLS" run_mode jira github); rc=$?
assert_eq "ledger class → exit 0" "0" "$rc"
assert_contains "create passes the ledger class" "$(grep '^create' "$JLOG")" "--class shell-quoting"
assert_not_contains "another branch's class is not used" "$(grep '^create' "$JLOG")" "other-branch-class"
out=$(CR_LEDGER="$LEDGER_CLS" run_mode jira github --class explicit-class); rc=$?
assert_contains "an explicit --class beats the ledger" "$(grep '^create' "$JLOG")" "--class explicit-class"
printf '%s\n' \
    '{"kind":"finding","head":"aaaaaaa","branch":"feat/tst-5-fixture","finding_id":"c2","file":"docs/readme.md","line":1,"verdict":"deferred"}' \
    '{"kind":"amend","target_head":"aaaaaaa","branch":"feat/tst-5-fixture","finding_id":"c2","set":{"class":"new:doc-drift"}}' >>"$LEDGER_CLS"
out=$(CR_LEDGER="$LEDGER_CLS" run_mode jira github); rc=$?
assert_contains "two classes in one batch stay unclassified" "$(grep '^create' "$JLOG")" "--class unclassified"
out=$(CR_LEDGER="$TMP_ROOT/no-such-ledger.jsonl" run_mode jira github); rc=$?
assert_eq "an unreadable ledger still files" "0" "$rc"
assert_contains "no ledger class falls back to unclassified" "$(grep '^create' "$JLOG")" "--class unclassified"

echo "TEST: the writer reports an existing residual as a duplicate"
out=$(JIRA_CREATE_DUP=1 run_mode jira github); rc=$?
assert_eq "dup → exit 0" "0" "$rc"
assert_contains "dup reported" "$out" "skipped (duplicate, TST-31)"

echo "TEST: no parent ticket on the branch and no --residual-of is refused, nothing created"
git -C "$REPO" checkout -q -b plain-branch
out=$(run_mode jira github); rc=$?
git -C "$REPO" checkout -q feat/tst-5-fixture
assert_eq "no parent → exit 1" "1" "$rc"
assert_contains "no parent names the flag" "$out" "--residual-of"
assert_eq "no parent creates nothing" "0" "$(grep -c '^create' "$JLOG")"

echo "TEST: tracker=none (local tracker, no remote forge) files nothing remote"
out=$(run_mode local local-git); rc=$?
assert_eq "none → exit 0" "0" "$rc"
assert_contains "none prints tracker=none" "$out" "tracker=none"
assert_contains "none lists finding 1" "$out" "1. src/a.ts:10: NIT: rename foo. use bar."
assert_contains "none lists finding 2" "$out" "2. docs/readme.md: LOW: missing example."
assert_contains "none points at Ticket coverage" "$out" "Ticket coverage"
assert_eq "none never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"
assert_eq "none never calls jira" "0" "$(wc -c <"$JLOG" | tr -d ' ')"

echo "TEST: tracker=forge (no Jira, github forge) keeps issue filing"
out=$(JKEY='' run_mode "" github); rc=$?
assert_eq "forge → exit 0" "0" "$rc"
assert_contains "forge prints tracker=forge" "$out" "tracker=forge"
assert_contains "forge files an issue" "$out" "filed https://github.com/owner/repo/issues/99"
assert_eq "forge never calls jira" "0" "$(wc -c <"$JLOG" | tr -d ' ')"

echo "TEST: TRACKER=jira without JIRA_PROJECT_KEY is refused, never falls back to forge"
: >"$GLOG"
out=$( cd "$REPO" && env -u JIRA_PROJECT_KEY PATH="$LBIN_UNIX:$PATH" TRACKER=jira FORGE=github GH_CMD="$LBIN/gh" \
    GLOG="$GLOG" bash "$FDI" --pr 1 --input "$INPUT" 2>&1 ); rc=$?
assert_eq "jira-unconfigured → exit 2" "2" "$rc"
assert_eq "jira-unconfigured never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"

echo "TEST: default path — no TRACKER, no himmel.tracker, key only in the .env — resolves jira (RED without load_dotenv)"
printf 'JIRA_PROJECT_KEY=TST\n' >"$REPO/.env"
: >"$GLOG"; : >"$JLOG"
out=$( cd "$REPO" && env -u JIRA_PROJECT_KEY -u TRACKER PATH="$LBIN_UNIX:$PATH" FORGE=github GH_CMD="$LBIN/gh" \
    JIRA_CMD="$JSTUB" GLOG="$GLOG" JLOG="$JLOG" JDESC="$JDESC" \
    bash "$FDI" --pr 1 --input "$INPUT" --dry-run 2>&1 ); rc=$?
rm -f "$REPO/.env"
assert_eq "dotenv default → exit 0" "0" "$rc"
assert_contains "dotenv default prints tracker=jira" "$out" "tracker=jira"
assert_eq "dotenv default never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"

echo "TEST: explicit TRACKER=none or local on a GitHub forge files nothing remote (RED: tracker=forge)"
for explicit in none local; do
    out=$(JKEY='' run_mode "$explicit" github); rc=$?
    assert_eq "explicit $explicit → exit 0" "0" "$rc"
    assert_contains "explicit $explicit prints tracker=none" "$out" "tracker=none"
    assert_eq "explicit $explicit never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"
done
git -C "$REPO" config himmel.tracker none
out=$(JKEY='' run_mode "" github); rc=$?
git -C "$REPO" config --unset himmel.tracker
assert_contains "git config himmel.tracker=none prints tracker=none" "$out" "tracker=none"
assert_eq "git config himmel.tracker=none never calls gh" "0" "$(wc -c <"$GLOG" | tr -d ' ')"

echo "TEST: no JIRA_CMD — the Jira CLI comes from the script's own checkout, not the cwd repo (RED: exit 4)"
FAKE="$TMP_ROOT/fakehimmel"
mkdir -p "$FAKE/scripts/cr" "$FAKE/scripts/jira/dist"
cp "$FDI" "$FAKE/scripts/cr/file-deferred-issues.sh"
cp -R "$SCRIPT_DIR/../lib" "$FAKE/scripts/lib"
git init -q "$FAKE"
cat >"$FAKE/scripts/jira/dist/index.js" <<'STUB'
require('fs').appendFileSync(process.env.JLOG, process.argv.slice(2).join(' ') + '\n');
STUB
: >"$JLOG"
out=$( cd "$REPO" && env -u JIRA_CMD -u TRACKER JIRA_PROJECT_KEY=TST JLOG="$JLOG" \
    bash "$FAKE/scripts/cr/file-deferred-issues.sh" --pr 1 --input "$INPUT" --dry-run 2>&1 ); rc=$?
assert_eq "own-checkout CLI → exit 0" "0" "$rc"
assert_contains "own-checkout CLI was called for the dedupe lookup" "$(cat "$JLOG")" "list --project TST"
echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
