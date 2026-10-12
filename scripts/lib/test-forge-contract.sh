#!/usr/bin/env bash
# test-forge-contract.sh — the forge contract (I6, HIMMEL-4762 / HIMMEL-4748
# WP4): one case list run against all four forge backends.
#   github     recorded fixtures replayed through a GH_CMD stub
#   bitbucket  documented-shape fixtures replayed through a BITBUCKET_CMD stub
#              (no Bitbucket account; see scripts/lib/fixtures/forge/README.md)
#   local-git  a temp repo whose origin is a file:// bare remote
#   none       every verb refuses with rc 4
# Plus the local-git change-id collision (feat/a-b then feat-a/b, rc 2) and the
# adapter ledger (one line per verb call when set, no file when unset).
# No network; HOME and git config are sandboxed under a temp root.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$SCRIPT_DIR/fixtures/forge"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi
}

if ! command -v jq >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
    echo "FAIL: test-forge-contract.sh needs jq (the GH_CMD stub's --jq) and node"
    exit 1
fi

ROOT=$(mktemp -d) || exit 1
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() { rm -rf "$ROOT" 2>/dev/null || true; }
trap cleanup EXIT

export HOME="$ROOT/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HIMMEL_ADAPTER_LEDGER FORGE
export CR_APP=0 CR_TRIGGER_LEDGER_PATH="$ROOT/cr-triggered-heads"

# shellcheck source=scripts/lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/forge.sh"

# ── stubs ────────────────────────────────────────────────────────────────────
# gh: route the subcommand to its fixture, then apply --jq / -q like gh does
# (jq -r). Anything unrecorded fails, as a real gh call with no network would.
GH_STUB="$ROOT/gh-stub"
cat > "$GH_STUB" <<EOF
#!/usr/bin/env bash
FIX="$FIX/github"
EOF
cat >> "$GH_STUB" <<'EOF'
f=""
case "$1 $2" in
    "repo view") f="$FIX/repo-view.json" ;;
    "pr list")
        f="$FIX/pr-list-open.json"
        for a in "$@"; do [ "$a" = "feat/none" ] && f=empty; done ;;
    "pr view")   [ "$3" = "2464" ] && f="$FIX/pr-view.json" ;;
    "pr checks") [ "$3" = "2464" ] && f="$FIX/pr-checks.json" ;;
esac
if [ -z "$f" ]; then echo "gh-stub: unrecorded call: $*" >&2; exit 1; fi
q=""
while [ "$#" -gt 0 ]; do
    case "$1" in --jq|-q) q="$2"; shift ;; esac
    shift
done
if [ "$f" = empty ]; then json='[]'; else json=$(cat "$f"); fi
if [ -n "$q" ]; then printf '%s' "$json" | jq -r "$q"; else printf '%s\n' "$json"; fi
EOF
chmod +x "$GH_STUB"

BB_STUB="$ROOT/bb-stub"
cat > "$BB_STUB" <<EOF
#!/usr/bin/env bash
FIX="$FIX/bitbucket"
EOF
cat >> "$BB_STUB" <<'EOF'
case "$1 $2" in
    "repo view") cat "$FIX/repo-view.json" ;;
    "pr list")   cat "$FIX/pr-list-open.json" ;;
    "pr get")    [ "$3" = "42" ] && cat "$FIX/pr-get.json" || { echo "bb-stub: no PR $3" >&2; exit 1; } ;;
    *) echo "bb-stub: unrecorded call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$BB_STUB"
export GH_CMD="$GH_STUB" BITBUCKET_CMD="$BB_STUB"

# ── repos ────────────────────────────────────────────────────────────────────
# github / bitbucket run in a repo with no origin (FORGE chooses the backend).
HOSTED="$ROOT/hosted"
git init -q -b main "$HOSTED"
git -C "$HOSTED" commit -q --allow-empty -m init

# local-git: a working repo whose origin is a file:// bare remote; feat/x has a
# commit beyond main so its change reads OPEN.
BARE="$ROOT/bare.git"
LG="$ROOT/lg"
git init -q --bare -b main "$BARE"
git init -q -b main "$LG"
git -C "$LG" remote add origin "file://$BARE"
git -C "$LG" commit -q --allow-empty -m init
git -C "$LG" push -q origin main
git -C "$LG" checkout -q -b feat/x
git -C "$LG" commit -q --allow-empty -m "feat x"
LG_HEAD=$(git -C "$LG" rev-parse HEAD)
LG_COMMON=$(cd "$LG/.git" && pwd -P)
printf 'feat: x\n' > "$ROOT/title"
printf 'body\n' > "$ROOT/body"

NONE_REPO="$ROOT/none"
git init -q -b main "$NONE_REPO"

dir_for() {
    case "$1" in
        github|bitbucket) printf '%s' "$HOSTED" ;;
        local-git)        printf '%s' "$LG" ;;
        none)             printf '%s' "$NONE_REPO" ;;
    esac
}

# run <forge> <verb> [args...] — sets OUT and RC.
run() {
    local f="$1"; shift
    OUT=$(cd "$(dir_for "$f")" && FORGE="$f" "$@" 2>/dev/null)
    RC=$?
}

# check_view <label> — the change_view contract: exactly the keys
# id/head/base/title/state/merged, state OPEN|MERGED|CLOSED, merged a boolean
# equal to (state == MERGED).
check_view() {
    local verdict
    verdict=$(printf '%s' "$OUT" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  let j; try { j = JSON.parse(s) } catch { console.log("not JSON"); return }
  const keys = Object.keys(j).sort().join(",");
  if (keys !== "base,head,id,merged,state,title") { console.log("keys " + keys); return }
  for (const k of ["id","head","base","title","state"]) if (typeof j[k] !== "string") { console.log(k + " not a string"); return }
  if (!["OPEN","MERGED","CLOSED"].includes(j.state)) { console.log("state " + j.state); return }
  if (j.merged !== (j.state === "MERGED")) { console.log("merged " + j.merged); return }
  console.log("ok");
})')
    assert_eq "$1" "ok" "$verdict"
}

# ── the case list ────────────────────────────────────────────────────────────
# expect <forge> <case> <rc> [stdout] — stdout compared only when given.
expect() {
    local f="$1" c="$2" want_rc="$3"
    assert_eq "$f: $c rc" "$want_rc" "$RC"
    if [ "$#" -ge 4 ]; then assert_eq "$f: $c stdout" "$4" "$OUT"; fi
}

GH_VIEW='{"id":"2464","head":"59d4d28d3b892290672c5e923f3b4d3b25ca8cf4","base":"main","title":"fix(lib): [HIMMEL-3571] git-clean scrub helpers clear the remaining repository-redirecting GIT_* variables","state":"MERGED","merged":true}'
GH_CHECKS=$(printf 'pass\tshell-unit (ubuntu-latest)\npass\tjira-cli-smoke\npass\tleak-classes\npass\tgit-env-scrub')
BB_VIEW='{"id":"42","head":"","base":"main","title":"feat: example change","state":"MERGED","merged":true}'
LG_VIEW="{\"id\":\"br-feat-x\",\"head\":\"$LG_HEAD\",\"base\":\"main\",\"title\":\"feat: x\",\"state\":\"OPEN\",\"merged\":false}"

for f in github bitbucket local-git none; do
    echo "TEST: forge contract — $f"
    case "$f" in github) id=2464 ;; bitbucket) id=42 ;; local-git) id=br-feat-x ;; none) id=1 ;; esac

    # change_open: only local-git opens a change through the forge seam.
    run "$f" forge_change_open feat/x "$ROOT/title" "$ROOT/body"
    case "$f" in
        local-git) expect "$f" "change_open feat/x" 0 br-feat-x ;;
        *)         expect "$f" "change_open is refused" 4 "" ;;
    esac

    run "$f" forge_change_id feat/x
    case "$f" in
        github)    expect "$f" "change_id feat/x" 0 2475 ;;
        bitbucket) expect "$f" "change_id feat/x" 0 42 ;;
        local-git) expect "$f" "change_id feat/x" 0 br-feat-x ;;
        none)      expect "$f" "change_id is refused" 4 "" ;;
    esac

    run "$f" forge_change_view "$id"
    case "$f" in
        github)    expect "$f" "change_view $id" 0 "$GH_VIEW"; check_view "$f: change_view shape" ;;
        bitbucket) expect "$f" "change_view $id" 0 "$BB_VIEW"; check_view "$f: change_view shape" ;;
        local-git) expect "$f" "change_view $id" 0 "$LG_VIEW"; check_view "$f: change_view shape" ;;
        none)      expect "$f" "change_view is refused" 4 "" ;;
    esac

    run "$f" forge_checks "$id"
    case "$f" in
        github) expect "$f" "checks $id" 0 "$GH_CHECKS" ;;
        *)      expect "$f" "checks is refused" 4 "" ;;
    esac

    run "$f" forge_repo_id
    case "$f" in
        github)    expect "$f" "repo_id" 0 yotamleo/Himmel ;;
        bitbucket) expect "$f" "repo_id" 0 examplews/example-repo ;;
        local-git) expect "$f" "repo_id" 0 "local:$LG_COMMON" ;;
        none)      expect "$f" "repo_id is refused" 4 "" ;;
    esac
done

# local-git: a branch whose commits are already in main reads MERGED; a
# deleted branch reads CLOSED.
echo "TEST: local-git change state follows the branch"
git -C "$LG" checkout -q main
git -C "$LG" merge -q --ff-only feat/x
run local-git forge_change_view br-feat-x
assert_eq "local-git: merged branch reads MERGED" "MERGED" \
    "$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).state))')"
git -C "$LG" branch -q -D feat/x
run local-git forge_change_view br-feat-x
assert_eq "local-git: deleted branch reads CLOSED" "CLOSED" \
    "$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).state))')"
run local-git forge_change_view br-nope
expect local-git "change_view of an unknown id" 1 ""

# ── the change-id collision ──────────────────────────────────────────────────
echo "TEST: local-git refuses a change-id collision"
run local-git forge_change_open feat/a-b "$ROOT/title" "$ROOT/body"
expect local-git "open feat/a-b" 0 br-feat-a-b
run local-git forge_change_id feat-a/b
expect local-git "change_id feat-a/b collides with feat/a-b" 2 ""
run local-git forge_change_open feat-a/b "$ROOT/title" "$ROOT/body"
expect local-git "open feat-a/b collides with feat/a-b" 2 ""
assert_eq "local-git: the first record still owns br-feat-a-b" "feat/a-b" \
    "$(_lg_field "$LG_COMMON/himmel/changes/br-feat-a-b.json" branch)"
run local-git forge_change_id feat/a-b
expect local-git "change_id feat/a-b still resolves" 0 br-feat-a-b
run local-git forge_change_id "feat/a+b"
expect local-git "change_id of a branch outside the id grammar" 2 ""

# ── the adapter ledger ───────────────────────────────────────────────────────
# Every public verb, every backend: exactly one ledger line naming that verb
# and forge, whatever the verb's rc.
echo "TEST: adapter ledger — one line per verb call"
VERBS="auth_status repo_nwo default_branch user_slug pr_find_open pr_create pr_set_body pr_mergeable pr_merge pr_has_merged issue_create change_id change_view change_open checks repo_id"
for f in github bitbucket local-git none; do
    bad=""
    for v in $VERBS; do
        led="$ROOT/ledger-$f-$v.jsonl"
        ( cd "$(dir_for "$f")" && FORGE="$f" HIMMEL_ADAPTER_LEDGER="$led" "forge_$v" x x x x ) >/dev/null 2>&1 </dev/null
        n=0; [ -f "$led" ] && n=$(wc -l < "$led" | tr -d ' ')
        if [ "$n" != 1 ] || ! grep -q "\"forge\":\"$f\",\"op\":\"$v\"" "$led"; then
            bad="$bad $v($n)"
        fi
    done
    assert_eq "$f: every verb appends exactly one ledger line" "" "$bad"
done

echo "TEST: adapter ledger — unset writes nothing"
NOLEDGER="$ROOT/noledger"
mkdir -p "$NOLEDGER"
for f in github bitbucket local-git none; do
    for v in $VERBS; do
        ( cd "$(dir_for "$f")" && FORGE="$f" TMPDIR="$NOLEDGER" "forge_$v" x x x x ) >/dev/null 2>&1 </dev/null
    done
done
assert_eq "no ledger file anywhere under the temp root" "" \
    "$(find "$ROOT" -name '*.jsonl' ! -name 'ledger-*' -print)"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
