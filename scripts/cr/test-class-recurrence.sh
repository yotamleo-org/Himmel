#!/usr/bin/env bash
# Tests for class-recurrence.sh: the restructure trigger. A fixture ledger and a
# Jira stub (JIRA_CMD) stand in for the real ones; no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR="$SCRIPT_DIR/class-recurrence.sh"

PASS=0
FAIL=0
TMP_ROOT=""
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() { [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT" 2>/dev/null; return 0; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_contains() {  # name haystack needle
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to contain '$3' in: $2" ;; esac
}
assert_not_contains() {  # name haystack needle
    case "$2" in *"$3"*) fail "$1" "expected NOT to contain '$3' in: $2" ;; *) pass "$1" ;; esac
}
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi; }
count() { grep -c "$1" "$2" 2>/dev/null || true; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/class-recurrence-test.XXXXXX") || exit 1
LEDGER="$TMP_ROOT/ledger.jsonl"
MERGED="$TMP_ROOT/merged.txt"
MEMBERS="$TMP_ROOT/members.txt"
JSTATE="$TMP_ROOT/jstate"
JLOG="$TMP_ROOT/jira.log"
JSTUB="$TMP_ROOT/jira-stub"
mkdir -p "$JSTATE"

TS_NEW=$(node -e 'console.log(new Date(Date.now()-864e5).toISOString())')
TS_OLD=$(node -e 'console.log(new Date(Date.now()-30*864e5).toISOString())')

# finding <branch> <id> <file> <ts>; amend <branch> <id> <class> <deferred 0|1>
finding() {
    printf '{"kind":"finding","ts":"%s","branch":"%s","head":"h-%s","model":"m","finding_id":"%s","severity":"imp","file":"%s","line":1,"verdict":"agreed"}\n' "$4" "$1" "$1" "$2" "$3" >>"$LEDGER"
}
amend() {
    if [ "$4" = 1 ]; then
        printf '{"kind":"amend","ts":"%s","branch":"%s","target_head":"h-%s","finding_id":"%s","set":{"verdict":"deferred","deferred_to":"HIMMEL-1","fu_class":"hardening","class":"%s"}}\n' "$TS_NEW" "$1" "$1" "$2" "$3" >>"$LEDGER"
    else
        printf '{"kind":"amend","ts":"%s","branch":"%s","target_head":"h-%s","finding_id":"%s","set":{"verdict":"fixed","class":"%s"}}\n' "$TS_NEW" "$1" "$1" "$2" "$3" >>"$LEDGER"
    fi
}
# seed <class> <file> <ts> <deferred-count> <branch...>: one finding per branch, the first N deferred
seed() {
    local class="$1" file="$2" ts="$3" nd="$4" i=0 b; shift 4
    for b in "$@"; do
        i=$((i+1))
        finding "$b" "f-$class" "$file" "$ts"
        if [ "$i" -le "$nd" ]; then amend "$b" "f-$class" "$class" 1; else amend "$b" "f-$class" "$class" 0; fi
    done
}

: >"$LEDGER"
# 5 merged PRs, 2 deferring: the pair that must fire.
seed hook-fail-direction scripts/hooks/foo.sh "$TS_NEW" 2 a1 a2 a3 a4 a5
# 5 merged PRs, only 1 deferring: no fire.
seed quiet-class scripts/hooks/foo.sh "$TS_NEW" 1 b1 b2 b3 b4 b5
# 4 merged PRs, 2 deferring: no fire.
seed small-class scripts/hooks/foo.sh "$TS_NEW" 2 c1 c2 c3 c4
# 4 merged PRs + 1 unmerged branch (5 branches, 2 deferring): the unmerged one is not a merged PR, no fire.
seed unmerged-class scripts/hooks/foo.sh "$TS_NEW" 2 d1 d2 d3 d4 d-unmerged
# 5 PRs and 2 deferring but 30 days old: outside the rolling window.
seed stale-class scripts/hooks/foo.sh "$TS_OLD" 2 e1 e2 e3 e4 e5
# 5 PRs, 2 deferring, spread over two areas (3 + 2): neither area reaches 5 PRs.
seed split-class scripts/hooks/foo.sh "$TS_NEW" 2 g1 g2 g3
seed split-class scripts/cr/bar.sh "$TS_NEW" 0 g4 g5
# attribution still missing: never a class.
seed unattributed scripts/hooks/foo.sh "$TS_NEW" 2 h1 h2 h3 h4 h5
# 5 PRs, 2 deferring, matches a structural-fix epic member through the members file.
seed eval-tokenizer-split scripts/hooks/lib/x.sh "$TS_NEW" 2 m1 m2 m3 m4 m5

printf '%s\n' a1 a2 a3 a4 a5 b1 b2 b3 b4 b5 c1 c2 c3 c4 d1 d2 d3 d4 e1 e2 e3 e4 e5 g1 g2 g3 g4 g5 h1 h2 h3 h4 h5 m1 m2 m3 m4 m5 >"$MERGED"
printf 'eval-tokenizer-split TST-5061\n' >"$MEMBERS"

# The Jira stub logs every call; `list` answers from state files keyed on the JQL.
cat >"$JSTUB" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$JLOG"
sub="$1"; shift
if [ "${JIRA_LIST_FAIL:-}" = 1 ] && [ "$sub" = list ]; then echo "boom" >&2; exit 1; fi
case "$sub" in
  list)
    jql=""; while [ $# -gt 0 ]; do [ "$1" = --jql ] && jql="$2"; shift; done
    case "$jql" in
      *'labels = "restructure-class-'*)
          id=${jql#*restructure-class-}; id=${id%%\"*}
          case "$jql" in *'statusCategory != Done'*) [ -f "$JSTATE/done-$id" ] && exit 0 ;; esac
          [ -f "$JSTATE/ticket-$id" ] && cat "$JSTATE/ticket-$id" ;;
      *'key = '*)
          mk=${jql#*key = }; mk=${mk%% *}
          [ -f "$JSTATE/done-key-$mk" ] || printf '%s\tTask\tTo Do\tmember\tx\n' "$mk" ;;
      *restructure-trigger*) cat "$JSTATE/week" 2>/dev/null ;;
      *'labels = residual'*) cat "$JSTATE/residuals" 2>/dev/null ;;
    esac
    exit 0 ;;
  create)
    n=$(( $(wc -l <"$JSTATE/created" 2>/dev/null || echo 0) + 100 ))
    key="TST-$n"; echo "$key" >>"$JSTATE/created"
    labels=""; desc=""; while [ $# -gt 0 ]; do case "$1" in --labels) labels="$2";; --desc-file) desc="$2";; esac; shift; done
    cp "$desc" "$JSTATE/body-$key"
    id=$(printf '%s' "$labels" | tr ',' '\n' | sed -n 's/^restructure-class-//p' | head -n1)
    printf '%s\tTask\tTo Do\ttitle\t%s\n' "$key" "$labels" >"$JSTATE/ticket-$id"
    echo "Created $key  title" ;;
  comment)
    [ "${JIRA_COMMENT_FAIL:-}" = 1 ] && { echo "boom" >&2; exit 1; }
    key="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = --comment-file ] && cat "$2" >>"$JLOG"; shift; done ;; # read-sink-ok: the comment file is the script's own mktemp body in this suite's sandbox
  fix-version)
    [ "${JIRA_FIXVER_FAIL:-}" = 1 ] && { echo "boom" >&2; exit 1; }
    : ;;
  get)
    printf '%s\nFix versions: v1.1.3\n' "$1" ;;
  *) : ;;
esac
STUB
chmod +x "$JSTUB"

reset() { rm -rf "$JSTATE"; mkdir -p "$JSTATE"; : >"$JLOG"; }
run() {  # run [args...]
    ( cd "$TMP_ROOT" && JIRA_PROJECT_KEY=TST JIRA_CMD="$JSTUB" JLOG="$JLOG" JSTATE="$JSTATE" \
        JIRA_LIST_FAIL="${JIRA_LIST_FAIL:-}" JIRA_COMMENT_FAIL="${JIRA_COMMENT_FAIL:-}" JIRA_FIXVER_FAIL="${JIRA_FIXVER_FAIL:-}" GH_CMD="${GH_CMD:-false}" \
        bash "$CR" --ledger "$LEDGER" --members "$MEMBERS" "$@" 2>&1 )
}

echo "TEST: residual lookup warns on stderr at and above the 500-row cap"
for n in 499 500 501; do
    reset
    awk -v n="$n" 'BEGIN { for (i = 1; i <= n; i++) printf "TST-%d\tTask\tTo Do\tresidual\tresidual\n", i }' >"$JSTATE/residuals"
    out=$(JIRA_PROJECT_KEY=TST JIRA_CMD="$JSTUB" JLOG="$JLOG" JSTATE="$JSTATE" \
        bash "$CR" --ledger "$LEDGER" --members "$MEMBERS" --merged-file "$MERGED" --dry-run 2>"$TMP_ROOT/cap.err"); rc=$?
    assert_eq "$n residuals exits 0" "0" "$rc"
    err=$(cat "$TMP_ROOT/cap.err")
    if [ "$n" -eq 499 ]; then
        assert_not_contains "below the cap does not warn" "$err" "WARN"
    else
        assert_contains "$n residuals warns on stderr" "$err" "WARN class-recurrence: the query hit its 500-row cap"
        assert_contains "$n residuals warns that results are partial" "$err" "partial"
    fi
    assert_not_contains "$n residuals keeps warning off stdout" "$out" "WARN"
done

echo "TEST: a pair in 5 merged PRs, 2 deferring, files exactly one ticket (RED: nothing is filed today)"
reset
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "run exits 0" "0" "$rc"
assert_eq "exactly one ticket filed" "1" "$(count '^create' "$JLOG")"
assert_contains "ticket carries the class label" "$(cat "$JLOG")" "restructure-class-hook-fail-direction"
assert_contains "ticket carries the trigger label" "$(cat "$JLOG")" "restructure-trigger"
assert_contains "ticket sits in epic 6176" "$(cat "$JLOG")" "--parent TST-6176"
assert_contains "output names the filed ticket" "$out" "filed TST-100"
body=$(cat "$JSTATE/body-TST-100" 2>/dev/null || true)
assert_contains "body names the area" "$body" "scripts/hooks"
assert_contains "body lists a merged branch" "$body" "a1"
assert_contains "body has Proof" "$body" "## Proof"
assert_not_contains "no ticket for 1-of-5 deferring" "$(cat "$JLOG")" "quiet-class"
assert_not_contains "no ticket for 4 PRs" "$(cat "$JLOG")" "small-class"
assert_not_contains "unmerged branch is not a merged PR" "$(cat "$JLOG")" "unmerged-class"
assert_not_contains "stale rows are outside the window" "$(cat "$JLOG")" "stale-class"
assert_not_contains "areas are counted apart" "$(cat "$JLOG")" "split-class"
assert_not_contains "unattributed is never a class" "$(cat "$JLOG")" "unattributed"

echo "TEST: a re-run comments on that ticket instead of filing a second"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "re-run exits 0" "0" "$rc"
assert_eq "still one create" "1" "$(count '^create' "$JLOG")"
assert_contains "re-run comments on the ticket" "$(cat "$JLOG")" "comment TST-100"
assert_contains "output says updated" "$out" "updated TST-100"

echo "TEST: --dry-run writes nothing"
reset
printf 'TST-601\tTask\tTo Do\tp1\tresidual,class-hook-fail-direction\n' >"$JSTATE/residuals"
out=$(run --merged-file "$MERGED" --dry-run); rc=$?
assert_eq "dry-run exits 0" "0" "$rc"
assert_eq "dry-run creates nothing" "0" "$(count '^create' "$JLOG")"
assert_eq "dry-run makes no Jira write" "0" "$(count '^\(create\|edit\|comment\|link\|fix-version\) ' "$JLOG")"
assert_contains "dry-run names the plan" "$out" "dry-run"

echo "TEST: open residuals of the class are folded (link, label, backlog)"
reset
printf 'TST-201\tTask\tTo Do\tpatch one\tresidual,class-hook-fail-direction\n' >"$JSTATE/residuals"
printf 'TST-202\tTask\tTo Do\tpatch two\tresidual,class-hook-fail-direction\n' >>"$JSTATE/residuals"
printf 'TST-203\tTask\tTo Do\talready folded\tresidual,class-hook-fail-direction,folded-into-TST-77\n' >>"$JSTATE/residuals"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "fold run exits 0" "0" "$rc"
log=$(cat "$JLOG")
assert_contains "link residual 1" "$log" "link TST-201 TST-100"
assert_contains "link residual 2" "$log" "link TST-202 TST-100"
assert_contains "label residual 1" "$log" "edit TST-201 --add-labels folded-into-TST-100"
assert_contains "backlog residual 1 (fixVersion removed)" "$log" "fix-version TST-201 --remove v1.1.3"
assert_contains "backlog residual 2 (fixVersion removed)" "$log" "fix-version TST-202 --remove v1.1.3"
assert_not_contains "already-folded residual untouched" "$log" "TST-203 TST-100"
body=$(cat "$JSTATE/body-TST-100" 2>/dev/null || true)
assert_contains "RED row for residual 1 in the body" "$body" "RED: TST-201"
assert_contains "RED row for residual 2 in the body" "$body" "RED: TST-202"
assert_not_contains "no RED row for the folded one" "$body" "RED: TST-203"

echo "TEST: a second run folds only new residuals and comments their RED rows"
: >"$JLOG"
printf 'TST-201\tTask\tTo Do\tpatch one\tresidual,class-hook-fail-direction,folded-into-TST-100\nTST-202\tTask\tTo Do\tpatch two\tresidual,class-hook-fail-direction,folded-into-TST-100\nTST-204\tTask\tTo Do\tpatch three\tresidual,class-hook-fail-direction\n' >"$JSTATE/residuals"
out=$(run --merged-file "$MERGED"); rc=$?
log=$(cat "$JLOG")
assert_eq "no second create" "0" "$(count '^create' "$JLOG")"
assert_contains "new residual linked" "$log" "link TST-204 TST-100"
assert_not_contains "old residual not re-linked" "$log" "link TST-201"
assert_contains "comment carries the RED row" "$log" "RED: TST-204"

echo "TEST: 3 open residuals of one class trigger with no ledger rows"
reset
printf 'TST-301\tTask\tTo Do\tp1\tresidual,class-lonely-class\nTST-302\tTask\tTo Do\tp2\tresidual,class-lonely-class\nTST-303\tTask\tTo Do\tp3\tresidual,class-lonely-class\n' >"$JSTATE/residuals"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "residual-arm run exits 0" "0" "$rc"
assert_contains "residual arm files the class ticket" "$(cat "$JLOG")" "restructure-class-lonely-class"
reset
printf 'TST-301\tTask\tTo Do\tp1\tresidual,class-two-class\nTST-302\tTask\tTo Do\tp2\tresidual,class-two-class\n' >"$JSTATE/residuals"
out=$(run --merged-file "$MERGED"); rc=$?
assert_not_contains "2 residuals do not trigger" "$(cat "$JLOG")" "two-class"

echo "TEST: open residuals labelled class-unclassified or class-unattributed never trigger"
reset
printf 'TST-311\tTask\tTo Do\tp1\tresidual,class-unclassified\nTST-312\tTask\tTo Do\tp2\tresidual,class-unclassified\nTST-313\tTask\tTo Do\tp3\tresidual,class-unclassified\nTST-321\tTask\tTo Do\tp4\tresidual,class-unattributed\nTST-322\tTask\tTo Do\tp5\tresidual,class-unattributed\nTST-323\tTask\tTo Do\tp6\tresidual,class-unattributed\n' >"$JSTATE/residuals"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "placeholder-residual run exits 0" "0" "$rc"
assert_not_contains "3 unclassified residuals file no restructure ticket" "$(cat "$JLOG")" "restructure-class-unclassified"
assert_not_contains "3 unattributed residuals file no restructure ticket" "$(cat "$JLOG")" "restructure-class-unattributed"
assert_not_contains "the dry-run output never lists the placeholder" "$(run --merged-file "$MERGED" --dry-run)" "unclassified"

echo "TEST: weekly cap of 2 new tickets"
reset
printf 'TST-90\nTST-91\n' >"$JSTATE/week"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "capped run exits 0" "0" "$rc"
assert_eq "cap reached: nothing created" "0" "$(count '^create' "$JLOG")"
assert_contains "output says capped" "$out" "capped"

echo "TEST: a class held by a structural-fix epic member is labelled, not re-filed"
reset
out=$(run --merged-file "$MERGED"); rc=$?
log=$(cat "$JLOG")
assert_contains "member gets the class label" "$log" "edit TST-5061 --add-labels restructure-class-eval-tokenizer-split"
assert_not_contains "no ticket for the member's class" "$(grep '^create' "$JLOG")" "eval-tokenizer-split"
assert_contains "output names the member" "$out" "member TST-5061"

echo "TEST: a residual is labelled folded only after its backlog step succeeded"
reset
printf 'TST-401\tTask\tTo Do\tp1\tresidual,class-hook-fail-direction\n' >"$JSTATE/residuals"
out=$(JIRA_FIXVER_FAIL=1 run --merged-file "$MERGED"); rc=$?
assert_eq "backlog failure exits 3" "3" "$rc"
assert_not_contains "no folded label after a failed backlog step" "$(cat "$JLOG")" "edit TST-401 --add-labels"

echo "TEST: a failed evidence comment folds nothing, so a retry still sees the residuals"
reset
printf 'TST-100\tTask\tTo Do\ttitle\trestructure-class-hook-fail-direction\n' >"$JSTATE/ticket-hook-fail-direction"
printf 'TST-402\tTask\tTo Do\tp1\tresidual,class-hook-fail-direction\n' >"$JSTATE/residuals"
out=$(JIRA_COMMENT_FAIL=1 run --merged-file "$MERGED"); rc=$?
assert_eq "comment failure exits 3" "3" "$rc"
assert_not_contains "no link after a failed comment" "$(cat "$JLOG")" "link TST-402"
assert_not_contains "no folded label after a failed comment" "$(cat "$JLOG")" "edit TST-402 --add-labels"

echo "TEST: a Done restructure ticket is not reused, a new one is filed"
reset
printf 'TST-50\tTask\tDone\told\trestructure-class-hook-fail-direction\n' >"$JSTATE/ticket-hook-fail-direction"
: >"$JSTATE/done-hook-fail-direction"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "recurrence after a closed restructure exits 0" "0" "$rc"
assert_eq "a new ticket is filed" "1" "$(count '^create' "$JLOG")"
assert_not_contains "the closed ticket gets no comment" "$(cat "$JLOG")" "comment TST-50 "

echo "TEST: a Done epic member is not labelled, a new ticket is filed"
reset
: >"$JSTATE/done-key-TST-5061"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "closed member exits 0" "0" "$rc"
assert_not_contains "the closed member is not labelled" "$(cat "$JLOG")" "edit TST-5061 --add-labels"
assert_contains "a new ticket carries the member's class" "$(grep '^create' "$JLOG")" "restructure-class-eval-tokenizer-split"

echo "TEST: a residual left unfolded beside a folded sibling is retried"
reset
printf 'TST-100\tTask\tTo Do\ttitle\trestructure-class-lonely-class\n' >"$JSTATE/ticket-lonely-class"
printf 'TST-501\tTask\tTo Do\tp1\tresidual,class-lonely-class,folded-into-TST-100\nTST-502\tTask\tTo Do\tp2\tresidual,class-lonely-class\nTST-503\tTask\tTo Do\tp3\tresidual,class-lonely-class\n' >"$JSTATE/residuals"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "retry run exits 0" "0" "$rc"
assert_contains "unfolded residual 2 is linked" "$(cat "$JLOG")" "link TST-502 TST-100"
assert_contains "unfolded residual 3 is linked" "$(cat "$JLOG")" "link TST-503 TST-100"
assert_not_contains "the folded sibling is untouched" "$(cat "$JLOG")" "link TST-501"
reset
printf 'TST-504\tTask\tTo Do\tp4\tresidual,class-lone-one\n' >"$JSTATE/residuals"
out=$(run --merged-file "$MERGED"); rc=$?
assert_not_contains "a lone unfolded residual with no folded sibling does not trigger" "$(cat "$JLOG")" "lone-one"

echo "TEST: a finding deferred and then fixed no longer counts as deferring"
reset
seed revived-class scripts/hooks/foo.sh "$TS_NEW" 2 u1 u2 u3 u4 u5
for b in u1 u2; do
    printf '{"kind":"amend","ts":"%s","branch":"%s","target_head":"h-%s","finding_id":"f-revived-class","set":{"verdict":"fixed"}}\n' "$TS_NEW" "$b" "$b" >>"$LEDGER"
done
printf '%s\n' u1 u2 u3 u4 u5 >>"$MERGED"
out=$(run --merged-file "$MERGED"); rc=$?
assert_eq "revived-class run exits 0" "0" "$rc"
assert_not_contains "deferred-then-fixed findings do not fire the class" "$(cat "$JLOG")" "revived-class"

echo "TEST: --dry-run counts the tickets it would file against the weekly cap"
reset
printf 'TST-90\n' >"$JSTATE/week"
printf 'TST-301\tTask\tTo Do\tp1\tresidual,class-lonely-class\nTST-302\tTask\tTo Do\tp2\tresidual,class-lonely-class\nTST-303\tTask\tTo Do\tp3\tresidual,class-lonely-class\n' >"$JSTATE/residuals"
out=$(run --merged-file "$MERGED" --dry-run); rc=$?
assert_eq "dry-run with a cap exits 0" "0" "$rc"
assert_eq "one class would be filed" "1" "$(printf '%s\n' "$out" | grep -c 'would filed')"
assert_eq "the other is capped" "1" "$(printf '%s\n' "$out" | grep -c 'capped (')"

echo "TEST: fail-closed paths"
reset
out=$(JIRA_LIST_FAIL=1 run --merged-file "$MERGED"); rc=$?
assert_eq "jira lookup failure exits 4" "4" "$rc"
assert_eq "lookup failure creates nothing" "0" "$(count '^create' "$JLOG")"
reset
out=$(run); rc=$?
assert_eq "no merged list and gh failing exits 2" "2" "$rc"
assert_eq "no merged list creates nothing" "0" "$(count '^create' "$JLOG")"
out=$(cd "$TMP_ROOT" && env -u JIRA_PROJECT_KEY JIRA_CMD="$JSTUB" bash "$CR" --ledger "$LEDGER" --merged-file "$MERGED" 2>&1); rc=$?
assert_eq "missing JIRA_PROJECT_KEY exits 2" "2" "$rc"

echo
echo "class-recurrence tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
