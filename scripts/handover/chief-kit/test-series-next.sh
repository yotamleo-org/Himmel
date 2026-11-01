#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-series-ledger.sh
# scripts/handover/chief-kit/test-series-next.sh - suite for series-next.sh, the driver of a stacked series
# (design section 5.2, failure rows F1 F2 F5 F7 F10 F13, invariants I3 I4 I5):
#   1. F5/F7  start       -> only the ledger's writer starts; one start per leg; item worktree on series/<sid>/<key>, locked
#   2. F1     pass        -> refuses a dirty authoring tree (names the key) and a HEAD past the ledger wip (SERIES-DRIFT)
#   3. commit/pass        -> commit records wip + committed; pass moves the writer; every other verb leaves it alone
#   4. F5     after pass  -> the old writer is refused, the new one starts the next item cut from the previous wip
#   5. F13    prune       -> the real worktree.sh prune keeps the locked item worktree (an unlocked twin is pruned)
#   6. F2     status      -> rows from ledger, git and gh alone; SERIES-DRIFT; GO-FILE; PR state
#   7. F10    abandon     -> marks the item abandoned; status prints PARENT-ABANDONED for the next item
#   8. item scope         -> start prints scope / do_not / commit_text from the ledger item; none = no block
#   9. integration        -> a ledger made by real gen-briefs, advanced by start + commit, holds the item's file in
#                            the real next-dispatchable.sh
#  10. series.md          -> exists, carries the hand-off order and the 8583 sentence
# SERIES_NEXT overrides the script under test (the RED control). Hermetic: temp dir, local bare origin, gh shim.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/../.." && pwd)"
DOCS="$(cd "$HERE/../../../docs/handover/worker-sections" && pwd)"
SCRIPT="${SERIES_NEXT:-$HERE/series-next.sh}"
LEDGER_PY="$HERE/series-ledger.py"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/series-next-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]: [$2]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: output contains [$3]: [$2]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }
sl()   { python3 -I "$LEDGER_PY" "$@"; }
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# nothing of the operator's environment may leak in: scratch HOME, a local origin that stands in for github
export HOME="$tmp/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config" GIT_CONFIG_NOSYSTEM=1 FORGE=github
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES SERIES_LEDGER_LOCK_TIMEOUT HIMMEL_FLAG_STACKED_SERIES
export HANDOVER_DIR="$tmp/handovers"; mkdir -p "$HANDOVER_DIR/.locks/go"

git init -q --bare "$tmp/origin.git"
REPO="$tmp/repo"
git clone -q "$tmp/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@test.local
git -C "$REPO" config user.name t
git -C "$REPO" config maintenance.auto false
git -C "$REPO" checkout -q -b main
printf 'base\n' > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -q -m base
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" remote set-head origin main >/dev/null 2>&1 || git -C "$REPO" fetch -q origin
MAIN="$(git -C "$REPO" rev-parse HEAD)"

# gh shim: PR rows come from two fixture files. pulls = what `gh api --paginate repos/owner/repo/pulls` lists (worktree.sh
# prune reads it); prs = what `gh pr list --head <branch>` prints after its --jq (series-next status reads it).
mkdir -p "$tmp/bin"
export GH_PULLS="$tmp/gh.pulls" GH_PRS="$tmp/gh.prs"; : > "$GH_PULLS"; : > "$GH_PRS"
cat > "$tmp/bin/gh" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
    *"auth status"*) exit 0 ;;
    *"repo view"*) echo owner/repo; exit 0 ;;
    *"api --paginate repos/owner/repo/pulls"*) cat "$GH_PULLS"; exit 0 ;;
    "pr list"*)
        b=""; p=""
        for a in "$@"; do [ "$p" = "--head" ] && b="$a"; p="$a"; done
        [ -n "${GH_PR_FAIL:-}" ] && exit 1
        awk -F'\t' -v b="$b" '$1 == b { print $2 "\t" $3 "\t" $4 }' "$GH_PRS"
        exit 0 ;;
esac
exit 0
SHIM
chmod +x "$tmp/bin/gh"
export GH_CMD="$tmp/bin/gh"

sn()      { rc=0; out="$( cd "$REPO" && bash "$SCRIPT" "$@" 2>&1 )" || rc=$?; }          # run from the primary checkout
sn_in()   { local d="$1"; shift; rc=0; out="$( cd "$d" && bash "$SCRIPT" "$@" 2>&1 )" || rc=$?; }
wtp()     { printf '%s/.claude/worktrees/series+%s+%s' "$REPO" "$1" "$2"; }
islocked() { git -C "$REPO" worktree list --porcelain | awk -v p="$1" '$1 == "worktree" { cur = ($2 == p) } cur && $1 == "locked" { f = 1 } END { exit !f }'; }
mk() { # <ledger> <writer> <key>...: a fresh ledger (sid = file name) with planned items
    local l="$1" w="$2"; shift 2
    sl create --ledger "$l" --sid "$(basename "$l" .json)" --completes-ticket no --writer "$w" || return 1
    local k; for k in "$@"; do sl add-item --ledger "$l" --key "$k" --writes "f-$k.txt" || return 1; done
}
commit_in() { # <worktree> <file>: one real commit
    printf 'work %s\n' "$2" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "work $2"
}

A="$tmp/handovers/doc-A.md"; B="$tmp/handovers/doc-B.md"; C="$tmp/handovers/doc-C.md"
L1="$tmp/ledgers/s1.json"; mkdir -p "$tmp/ledgers"
mk "$L1" "$A" K1 K2 K3 || { echo "FAIL: fixture ledger"; exit 1; }

# --- 1. F5 / F7: start --------------------------------------------------------------------------------------------
sn start --ledger "$L1" --doc "$B" K1
check "1: start by a doc that is not the writer refuses rc 2" "$rc" 2
contains "1: the refusal names the writer" "$out" "$A"
check "1: the refusal creates no worktree" "$([ -e "$(wtp s1 K1)" ] && echo yes || echo no)" no
check "1: the refusal leaves the item planned" "$(jget "$L1" 'd["items"][0]["state"]')" planned

sn start --ledger "$L1" --doc "$A" K1
check "1: start by the writer rc 0" "$rc" 0
check "1: item branch" "$(jget "$L1" 'd["items"][0]["branch"]')" series/s1/K1
check "1: item worktree" "$(jget "$L1" 'd["items"][0]["worktree"]')" "$(wtp s1 K1)"
check "1: item state authoring" "$(jget "$L1" 'd["items"][0]["state"]')" authoring
check "1: the first item is cut from origin/main" "$(jget "$L1" 'd["items"][0]["cut_from"]')" "$MAIN"
check "1: wip starts at the cut" "$(jget "$L1" 'd["items"][0]["wip"]')" "$MAIN"
check "1: the worktree is on the item branch at the cut" "$(git -C "$(wtp s1 K1)" rev-parse --abbrev-ref HEAD) $(git -C "$(wtp s1 K1)" rev-parse HEAD)" "series/s1/K1 $MAIN"
check "1: the worktree is locked (F13)" "$(islocked "$(wtp s1 K1)" && echo locked || echo free)" locked
check "1: start leaves the writer" "$(jget "$L1" 'd["writer"]')" "$A"
lacks "1: an item with no scope fields prints no ITEM-SCOPE block" "$out" "ITEM-SCOPE"

sn start --ledger "$L1" --doc "$A" K2
check "1: F7 a second start from the same doc refuses rc 2" "$rc" 2
contains "1: F7 refusal text" "$out" "one item per leg: hand off at READY"
check "1: F7 the second item stays planned" "$(jget "$L1" 'd["items"][1]["state"]')" planned
sn start --ledger "$L1" --doc "$A" K1
check "1: a started item cannot start again" "$rc" 2

# --- 2. F1: pass refusals --------------------------------------------------------------------------------------------
W1="$(wtp s1 K1)"
printf 'uncommitted\n' > "$W1/dirty.txt"
sn pass --ledger "$L1" --doc "$A" "$B"
check "2: F1 pass over a dirty authoring tree refuses rc 2" "$rc" 2
contains "2: F1 the refusal names the key" "$out" K1
check "2: F1 pass moved nothing" "$(jget "$L1" 'd["writer"]') $(jget "$L1" 'len(d["passes"])')" "$A 0"
sn commit --ledger "$L1" --doc "$A" K1
check "2: commit over a dirty tree refuses rc 2" "$rc" 2
check "2: the refused commit leaves the item authoring" "$(jget "$L1" 'd["items"][0]["state"]')" authoring
git -C "$W1" add dirty.txt; git -C "$W1" commit -q -m "k1 work"
sn pass --ledger "$L1" --doc "$A" "$B"
check "2: F1 pass with HEAD past the ledger wip refuses rc 2" "$rc" 2
contains "2: F1 SERIES-DRIFT K1 wip" "$out" "SERIES-DRIFT K1 wip"
check "2: F1 drift pass moved nothing" "$(jget "$L1" 'd["writer"]')" "$A"

# --- 3. commit / pass ---------------------------------------------------------------------------------------------
sn commit --ledger "$L1" --doc "$B" K1
check "3: commit by a non-writer refuses rc 2" "$rc" 2
sn commit --ledger "$L1" --doc "$A" K1
check "3: commit rc 0" "$rc" 0
K1WIP="$(git -C "$W1" rev-parse HEAD)"
check "3: commit records wip = the worktree HEAD" "$(jget "$L1" 'd["items"][0]["wip"]')" "$K1WIP"
check "3: commit moves the item to committed" "$(jget "$L1" 'd["items"][0]["state"]')" committed
check "3: commit leaves the writer" "$(jget "$L1" 'd["writer"]')" "$A"
sn commit --ledger "$L1" --doc "$A" K1
check "3: committing a committed item refuses rc 2" "$rc" 2
sn commit --ledger "$L1" --doc "$A" K2
check "3: committing a planned item refuses rc 2" "$rc" 2

sn pass --ledger "$L1" --doc "$B" "$C"
check "3: pass by a non-writer refuses rc 2" "$rc" 2
sn pass --ledger "$L1" --doc "$A" "$B"
check "3: pass over committed clean work rc 0" "$rc" 0
check "3: pass moves the writer" "$(jget "$L1" 'd["writer"]')" "$B"
check "3: pass appends one {from,to}" "$(jget "$L1" 'd["passes"][0]["from"] + " " + d["passes"][0]["to"] + " " + str(len(d["passes"]))')" "$A $B 1"

# --- 4. F5 after pass ---------------------------------------------------------------------------------------------
sn commit --ledger "$L1" --doc "$A" K1
check "4: F5 the old writer is refused after pass" "$rc" 2
contains "4: F5 the refusal names the new writer" "$out" "$B"
sn start --ledger "$L1" --doc "$B" K2
check "4: F5 the new writer starts the next item rc 0" "$rc" 0
W2="$(wtp s1 K2)"
check "4: the next item is cut from the previous item's wip" "$(jget "$L1" 'd["items"][1]["cut_from"]') $(git -C "$W2" rev-parse HEAD)" "$K1WIP $K1WIP"
check "4: the next item's worktree is locked" "$(islocked "$W2" && echo locked || echo free)" locked
check "4: start leaves the writer" "$(jget "$L1" 'd["writer"]')" "$B"
sn start --ledger "$L1" --doc "$B" K3
check "4: F7 holds for the new writer too" "$rc" 2

# --- 5. F13: worktree.sh prune keeps the locked item worktree -------------------------------------------------------
# prune matches a merged PR row by branch name and exact tip. The row below says the PR for K2's branch merged at the very
# sha K2 starts on (K1's head); the twin is an UNLOCKED worktree on the same sha with the same row.
git -C "$REPO" worktree add -q -b series/s1/TWIN "$(wtp s1 TWIN)" "$K1WIP" 2>/dev/null
printf 'owner/repo\tseries/s1/K2\tmerged\t%s\nowner/repo\tseries/s1/TWIN\tmerged\t%s\n' "$K1WIP" "$K1WIP" > "$GH_PULLS"
prune_out="$( cd "$REPO" && bash "$SCRIPTS/worktree.sh" prune 2>&1 )"; prune_rc=$?
[ "$prune_rc" = 0 ] || printf '%s\n' "$prune_out"
check "5: F13 prune rc 0" "$prune_rc" 0
check "5: F13 the unlocked twin is pruned (the control)" "$([ -e "$(wtp s1 TWIN)" ] && echo kept || echo pruned)" pruned
check "5: F13 the locked item worktree is kept" "$([ -e "$W2" ] && echo kept || echo pruned)" kept
check "5: F13 the earlier locked item worktree is kept" "$([ -e "$W1" ] && echo kept || echo pruned)" kept
: > "$GH_PULLS"

# --- 6. F2: status from ledger, git and gh alone --------------------------------------------------------------------
sn_in "$W2" status --ledger "$L1"
check "6: status rc 0, run from another worktree of the repo" "$rc" 0
contains "6: F2 K1 row: state, wip, ahead count, no PR" "$out" "ITEM K1 state=committed wip=${K1WIP:0:12} ahead=1 pr=-"
contains "6: F2 K2 row: state, wip, ahead count" "$out" "ITEM K2 state=authoring wip=${K1WIP:0:12} ahead=0 pr=-"
contains "6: F2 K3 row: planned" "$out" "ITEM K3 state=planned"
lacks "6: F2 no drift while ledger and git agree" "$out" "SERIES-DRIFT"
contains "6: status names the series and its writer" "$out" "SERIES s1 writer=$B"
commit_in "$W2" k2.txt
sn status --ledger "$L1"
contains "6: F2 a worktree HEAD past the ledger wip gives SERIES-DRIFT K2 wip" "$out" "SERIES-DRIFT K2 wip"
check "6: status changed nothing" "$(jget "$L1" 'd["items"][1]["wip"]') $(jget "$L1" 'd["writer"]')" "$K1WIP $B"
sl set --ledger "$L1" --key K2 wip="$K1WIP" >/dev/null   # (undo the drift for the rows below)
git -C "$W2" reset -q --hard "$K1WIP"

# status of a published item: the PR comes from gh by publish_branch; a GO file for it is named
L5="$tmp/ledgers/s5.json"; mk "$L5" "$A" K1 K2 || exit 1
PUBHEAD="$(printf 'published\n' | git -C "$REPO" hash-object --stdin)"
sl set --ledger "$L5" --key K1 state=published publish_branch=series/s5/K1-pub published_head="$PUBHEAD" wip="$MAIN" cut_from="$MAIN" >/dev/null
printf 'series/s5/K1-pub\t4242\tMERGED\t%s\n' "$PUBHEAD" > "$GH_PRS"
sn status --ledger "$L5"
contains "6: a published item's row carries the PR from gh" "$out" "ITEM K1 state=published wip=${MAIN:0:12} ahead=0 pr=#4242 MERGED"
lacks "6: no GO-FILE without a GO file" "$out" "GO-FILE"
printf 'go\n' > "$HANDOVER_DIR/.locks/go/4242.$PUBHEAD"
sn status --ledger "$L5"
contains "6: GO-FILE <pr> <path> when the GO file exists" "$out" "GO-FILE 4242 $HANDOVER_DIR/.locks/go/4242.$PUBHEAD"
GH_PR_FAIL=1 sn status --ledger "$L5"
contains "6: a gh failure shows pr=unknown, never a guess" "$out" "ITEM K1 state=published wip=${MAIN:0:12} ahead=0 pr=unknown"
: > "$GH_PRS"
sl set --ledger "$L5" --key K2 state=committed wip="$MAIN" worktree="$tmp/gone" >/dev/null
sn status --ledger "$L5"
contains "6: a committed item whose worktree is gone is drift" "$out" "SERIES-DRIFT K2 worktree"
sn status --ledger "$tmp/ledgers/none.json"
check "6: status of a missing ledger fails rc 1" "$rc" 1

# --- 7. F10: abandon --------------------------------------------------------------------------------------------------
L2="$tmp/ledgers/s2.json"; mk "$L2" "$A" K1 K2 || exit 1
sn abandon --ledger "$L2" --doc "$B" K1
check "7: abandon by a non-writer refuses rc 2" "$rc" 2
check "7: the refused abandon changed nothing" "$(jget "$L2" 'd["items"][0]["state"]')" planned
sn abandon --ledger "$L2" --doc "$A" K1
check "7: F10 abandon rc 0" "$rc" 0
check "7: F10 abandon marks K1 abandoned" "$(jget "$L2" 'd["items"][0]["state"]')" abandoned
check "7: abandon leaves the writer" "$(jget "$L2" 'd["writer"]')" "$A"
sn status --ledger "$L2"
contains "7: F10 status prints PARENT-ABANDONED K2" "$out" "PARENT-ABANDONED K2"
lacks "7: the abandoned item itself is not flagged" "$out" "PARENT-ABANDONED K1"
sn abandon --ledger "$L2" --doc "$A" K1
check "7: abandoning an abandoned item refuses rc 2" "$rc" 2
sn abandon --ledger "$L2" --doc "$A" K9
check "7: abandoning an unknown key refuses rc 2" "$rc" 2

# --- 8. the item's own scope, do-not lines and commit text ----------------------------------------------------------------
# a test-only fixture edit: series-ledger.py set does not list these item fields yet, so no production path writes them
cat > "$tmp/addfields.py" <<'PYEOF'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d["items"][1]["scope"] = "Edit only scripts/y.sh"
d["items"][1]["do_not"] = ["Do not touch scripts/x", "Do not turn stacked_series on"]
d["items"][1]["commit_text"] = "feat(y): [HIMMEL-9] y does the thing"
json.dump(d, open(path, "w"), indent=2)
PYEOF
L3="$tmp/ledgers/s3.json"; mk "$L3" "$A" K1 K2 || exit 1
sl set --ledger "$L3" --key K1 state=committed wip="$MAIN" branch=series/s3/K1 >/dev/null
python3 -I "$tmp/addfields.py" "$L3"
sn start --ledger "$L3" --doc "$A" K2
check "8: start on an item with scope fields rc 0" "$rc" 0
contains "8: the block opens with ITEM-SCOPE <key>" "$out" "ITEM-SCOPE K2"
contains "8: HIMMEL-8583 the do_not line is printed" "$out" "DO-NOT Do not touch scripts/x"
contains "8: the second do_not line is printed" "$out" "DO-NOT Do not turn stacked_series on"
contains "8: the scope is printed" "$out" "Edit only scripts/y.sh"
contains "8: the commit text is printed" "$out" "COMMIT-TEXT feat(y): [HIMMEL-9] y does the thing"
check "8: set-up by a fixture edit left the ledger a valid ledger" "$(sl read --ledger "$L3" >/dev/null 2>&1; echo $?)" 0
L4="$tmp/ledgers/s4.json"; mk "$L4" "$A" K1 || exit 1
sn start --ledger "$L4" --doc "$A" K1
check "8: an item with no fields starts rc 0" "$rc" 0
lacks "8: and prints no ITEM-SCOPE block" "$out" "ITEM-SCOPE"
lacks "8: and no DO-NOT or COMMIT-TEXT line" "$out" "DO-NOT"

# --- 9. integration: real gen-briefs -> start + commit -> real next-dispatchable ----------------------------------------
IB="$tmp/ibucket"; mkdir -p "$tmp/stub-jira" "$tmp/imirror" "$tmp/isigned"
cat > "$tmp/stub-jira/index.js" <<'JSEOF'
const a = process.argv.slice(2);
const keys = a.slice(a.indexOf(a[1] === 'core-check' ? '--key' : '--mirror') + (a[1] === 'core-check' ? 1 : 2));
if (a[1] === 'core-check') { for (const k of keys) console.log('NOT-CORE ' + k); }
else { for (const k of keys) console.log('SPEC ok ' + k + ' x'); }
JSEOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/wt-stub.sh"; chmod +x "$tmp/wt-stub.sh"
SRP="HIMMEL-9000 (the earlier fix). Source: \`git log -3 -- scripts/sa\`."
cat > "$tmp/iworkers.json" <<IWEOF
[
 {"label":"N931","keys":["HIMMEL-9301"],"slug":"sr-a","branch":"feat/himmel-9301-sr-a","title":"series writer","desc":"d","why":"w","prior":"$SRP","writes":"scripts/sa/a.sh","scope":"\`scripts/sa/a.sh\` completes-ticket: no","scope_short":"a.sh","commit":"feat(sa): [HIMMEL-9301] a","series":["N932"],"series_grant":{"family":"scripts/sa/","decision":388}},
 {"label":"N932","keys":["HIMMEL-9302"],"slug":"sr-b","branch":"feat/himmel-9302-sr-b","title":"series item b","desc":"d","why":"w","prior":"$SRP","writes":"scripts/sa/b.sh","scope":"\`scripts/sa/b.sh\` completes-ticket: no","scope_short":"b.sh","commit":"feat(sa): [HIMMEL-9302] b"}
]
IWEOF
gb_out="$( HIMMEL_FLAG_STACKED_SERIES=1 GEN_BRIEFS_WORKTREE_CMD="$tmp/wt-stub.sh" WT_LOG="$tmp/wt.log" GEN_BRIEFS_MIRROR="$tmp/imirror" \
    TICKET_STATUS_STATE_DIR="$tmp/state-empty" GEN_BRIEFS_NO_WT_CHECK=1 GEN_BRIEFS_JIRA_CLI="$tmp/stub-jira/index.js" CG_STUB_SIGNED="$tmp/isigned" \
    python3 "$HERE/gen-briefs.py" "$tmp/iworkers.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 \
    --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$IB" --date 2026-10-08 --repo "$REPO" --handover-root "$tmp/handovers" \
    --work-dir "$tmp/iwork" --deadline 1791475000 2>&1 )"; gb_rc=$?
[ "$gb_rc" = 0 ] || printf '%s\n' "$gb_out"
check "9: real gen-briefs writes the series brief and ledger (rc 0)" "$gb_rc" 0
IL="$IB/series/HIMMEL-9301-N931.json"; ID="$IB/HIMMEL-9301-N931-sr-a-2026-10-08.md"
check "9: the ledger names the brief as its writer" "$(jget "$IL" 'd["writer"]')" "$ID"
sn start --ledger "$IL" --doc "$ID" HIMMEL-9301
check "9: start on the gen-briefs ledger rc 0" "$rc" 0
commit_in "$(jget "$IL" 'd["items"][0]["worktree"]')" a.txt
sn commit --ledger "$IL" --doc "$ID" HIMMEL-9301
check "9: commit on the gen-briefs ledger rc 0" "$rc" 0
check "9: the item is committed in the ledger" "$(jget "$IL" 'd["items"][0]["state"]')" committed
mkdir -p "$tmp/inc/HIMMEL"
printf 'v1.0.1\tfalse\t\n' > "$tmp/inc/HIMMEL.versions.tsv"
printf -- '---\nkey: "HIMMEL-9390"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "High"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-9390: wants a series file\n\n## Description\n\nEdit scripts/sa/a.sh please.\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n' > "$tmp/inc/HIMMEL/HIMMEL-9390.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/nd-gh"; chmod +x "$tmp/nd-gh"
printf '{"schema":1,"legs":[]}\n' > "$IB/fleet.json"   # the predecessor has WRAPPED: only the ledger holds the file
nd="$( HIMMEL_FLAG_STACKED_SERIES=1 NEXT_DISPATCH_MIRROR="$tmp/inc/HIMMEL" NEXT_DISPATCH_GH_CMD="$tmp/nd-gh" \
    bash "$HERE/next-dispatchable.sh" --workers-from "$IB/fleet.json" --no-classify --why 2>/dev/null )"; nd_rc=$?
check "9: next-dispatchable rc 0" "$nd_rc" 0
contains "9: the started + committed item still holds its file (collision drop)" "$nd" "collision scripts/sa/a.sh held by series HIMMEL-9301-N931"

# --- 10. series.md --------------------------------------------------------------------------------------------------------
SM="$DOCS/series.md"
check "10: series.md exists" "$([ -f "$SM" ] && echo yes || echo no)" yes
sm="$(cat "$SM" 2>/dev/null)"
handoff="$(awk '/^## Hand-off at READY/ { on = 1; next } /^## / { on = 0 } on' "$SM" 2>/dev/null)"
pos() { printf '%s\n' "$handoff" | grep -n -m1 -F -- "$1" | cut -d: -f1; }
p_resume="$(pos 'RESUME doc')"; p_commit="$(pos 'series-next.sh commit')"; p_pass="$(pos 'series-next.sh pass')"; p_wrap="$(pos 'WRAPPED')"
check "10: the hand-off order is RESUME doc, commit, pass, WRAPPED" "$([ -n "$p_resume" ] && [ -n "$p_commit" ] && [ -n "$p_pass" ] && [ -n "$p_wrap" ] && [ "$p_resume" -lt "$p_commit" ] && [ "$p_commit" -lt "$p_pass" ] && [ "$p_pass" -lt "$p_wrap" ] && echo ordered || echo "no:$p_resume,$p_commit,$p_pass,$p_wrap")" ordered
# shellcheck disable=SC2016  # the backticks are literal page text
contains "10: the 8583 sentence" "$sm" 'series-next.sh start` prints the item'"'"'s `scope`, `do_not` and `commit_text` from the ledger item'
contains "10: status after any compaction" "$sm" "series-next.sh status"
contains "10: one item per leg" "$sm" "one item per leg"
contains "10: no compact mode" "$sm" "No compact mode"
contains "10: never edit the ledger JSON" "$sm" "never edit the ledger JSON"
for v in "status --ledger" "start --ledger" "commit --ledger" "pass --ledger" "abandon --ledger"; do
    contains "10: series.md documents series-next.sh $v" "$sm" "series-next.sh $v"
done
check "10: series-next.sh reads no flag" "$(grep -c -E 'himmel_flag|flags\.sh|flags\.tsv' "$SCRIPT" 2>/dev/null || true)" 0

[ "$fails" -eq 0 ] && echo "ALL OK" || { echo "$fails FAILED"; exit 1; }
