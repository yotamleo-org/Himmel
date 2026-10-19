#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-go.sh
# scripts/handover/test-merge-fork-pr.sh - suite for the console's fork-merge path:
# console-kit/go.sh --repo (writes a GO for an allowlisted fork PR) and
# merge-fork-pr.sh (the only chokepoint that merges one). gh is a stub.
#   1. go.sh --repo: usage, allowlist (absent / merge_allowed false), PR state
#      (head, MERGEABLE, OPEN, base = himmel_branch), judge verdict, leg refused,
#      and a valid write.
#   2. merge-fork-pr.sh: usage, leg/relay refused, non-allowlisted repo refused,
#      missing / forged / stale / other-repo / non-judged GO refused, head moved
#      after the GO refused, and an allowlisted repo with a valid GO merges.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GO_SH="$HERE/console-kit/go.sh"
MERGE_SH="$HERE/merge-fork-pr.sh"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY CONSOLE_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-fork-pr-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
export HOME="$tmp/home"; mkdir -p "$HOME"
export USER_SLUG=u

SHA=0123456789abcdef0123456789abcdef01234567
OLD=89abcdef0123456789abcdef0123456789abcdef
FORK=yotamleo/qmd
BASE=himmel/pin-http-auth
# The harness repo is whatever the checkout under test names as origin; the stub's
# gh repo view answers the FORK as the default repo to prove nothing reads that.
ORIGIN_NWO=$(git -C "$HERE" remote get-url origin | sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)##; s#\.git$##')
export STUB_ORIGIN_NWO="$ORIGIN_NWO"
export STUB_ALLOW="$tmp/allow.json" STUB_PRVIEW="$tmp/prview.json" STUB_LOG="$tmp/gh.log" STUB_THREADS="$tmp/threads.txt"
printf '0 false\n' > "$STUB_THREADS"
: > "$STUB_LOG"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view")
        case "$*" in
            *defaultBranchRef*) printf 'main' ;;
            *) printf 'yotamleo/qmd' ;;
        esac ;;
    "api repos/"*"/contents/scripts/guardrails/himmel-adapters.json?ref=main")
        case "$2" in "repos/$STUB_ORIGIN_NWO/contents/"*) cat "$STUB_ALLOW" 2>/dev/null || exit 1 ;; *) exit 1 ;; esac ;;
    "pr view") cat "$STUB_PRVIEW" 2>/dev/null || exit 1 ;;
    "api graphql")
        read -r n h < "$STUB_THREADS" 2>/dev/null || exit 1
        case "$n" in ''|*[!0-9]*) echo 'not json'; exit 0 ;; esac
        nodes=""; i=0; while [ "$i" -lt "$n" ]; do nodes="$nodes{\"isResolved\":false},"; i=$((i+1)); done
        printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":%s},"nodes":[%s{"isResolved":true}]}}}}}\n' "$h" "$nodes" ;;
    "pr merge")
        printf 'MERGE %s\n' "$*" >> "$STUB_LOG"
        [ -n "${STUB_NOFLIP:-}" ] || { sed 's/"state":"OPEN"/"state":"MERGED"/' "$STUB_PRVIEW" > "$STUB_PRVIEW.tmp" && mv "$STUB_PRVIEW.tmp" "$STUB_PRVIEW"; } ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

printf '%s\n' '[{"nwo":"yotamleo/qmd","upstream":"tobi/qmd","himmel_branch":"himmel/pin-http-auth","pin_site":"scripts/lib/qmd-bin.sh","role":"runtime-dependency","merge_allowed":true},{"nwo":"yotamleo/off","upstream":"x/off","himmel_branch":"himmel/x","pin_site":null,"role":"dormant","merge_allowed":false}]' > "$STUB_ALLOW"
GOODCHK='[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'
prview() { printf '{"state":"%s","headRefOid":"%s","mergeable":"%s","baseRefName":"%s","mergeStateStatus":"%s","statusCheckRollup":%s}\n' "${1:-OPEN}" "${2:-$SHA}" "${3:-MERGEABLE}" "${4:-$BASE}" "${5:-CLEAN}" "${6:-$GOODCHK}" > "$STUB_PRVIEW"; }
prview

fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grep -qF -e "$3" <<< "$2" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }

ROOT="$tmp/root"; mkdir -p "$ROOT"
VBUCKET="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
VSCOPE="u/$VBUCKET"
mkdir -p "$HOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"

# verdict <qid> <word> <head> <pr> - a signed judge record, as write-verdict.sh lays it out.
verdict() {
  local vf="$ROOT/$VSCOPE/verdicts/$1/HIMMEL-5899-judge-$1.md" vmac
  mkdir -p "$ROOT/$VSCOPE/verdicts/$1"
  # shellcheck disable=SC2016
  printf '# VERDICT %s - judge\n\n## Reason (scope asked)\n\nq\n\n## Verdict\n\n**%s** for head `%s`\n\npr: %s\n\nreason\n\n## Evidence checked\n\ne\n' "$1" "$2" "$3" "$4" > "$vf"
  vmac="$(cat "$vf" | bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../lib/go-gate.sh" "$VSCOPE" "$1" "HIMMEL-5899-judge-$1")" || { echo "FAIL: cannot sign $vf" >&2; return 1; }
  printf 'mac: %s\n' "$vmac" >> "$vf"
}
# write_go <nwo> <pr> <head> [<trust id>] - a GO file the way go.sh signs it, for hand-built cases.
write_go() {
  local mac
  mac="$(bash -c '. "$1"; go_mac "$2" "$3" "$4" "$5"' _ "$HERE/../lib/go-gate.sh" "$2" "$3" "$1" "${4:-}")"
  mkdir -p "$ROOT/.locks/go"
  { printf 'pr=%s\nhead=%s\nby=t\nat=t\n' "$2" "$3"; [ -z "${4:-}" ] || printf 'trust-reviewed=%s\n' "$4"; printf 'mac=%s\n' "$mac"; } > "$ROOT/.locks/go/$2.$3"
}
go() { HANDOVER_DIR="$ROOT" bash "$GO_SH" "$@"; }
merge() { HANDOVER_DIR="$ROOT" bash "$MERGE_SH" "$@"; }
merged() { grep -c '^MERGE ' "$STUB_LOG"; }
# A leg always runs under its claude session; without a claude ancestor the
# chokepoint seam guard refuses a leg marker with 96 before the leg check runs.
_as_claude() { (exec -a claude bash -c '"$@"; exit $?' _ "$@"); }

# --- 1. go.sh --repo ---------------------------------------------------------
verdict j1 GO "$SHA" 18
rc=0; go --repo "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo without --trust-reviewed -> exit 2" "$rc" 2
rc=0; go --repo "$FORK" --fix-main-red 5 --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo with --fix-main-red -> exit 2" "$rc" 2
rc=0; go --repo 'a/b/c' --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo malformed nwo -> exit 2" "$rc" 2
rc=0; go --repo other/repo --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo non-allowlisted repo -> exit 6" "$rc" 6
rc=0; go --repo yotamleo/off --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo merge_allowed false -> exit 6" "$rc" 6
rc=0; STUB_ALLOW="$tmp/none.json" go --repo "$FORK" --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo unreadable allowlist -> exit 6" "$rc" 6
for st in "CLOSED $SHA MERGEABLE $BASE" "OPEN $OLD MERGEABLE $BASE" "OPEN $SHA CONFLICTING $BASE" "OPEN $SHA MERGEABLE main"; do
  # shellcheck disable=SC2086  # word-splitting is the point
  prview $st
  rc=0; go --repo "$FORK" --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
  check "go --repo PR state [$st] -> exit 7" "$rc" 7
done
prview
for mss in UNSTABLE BLOCKED BEHIND DIRTY UNKNOWN; do
  prview OPEN "$SHA" MERGEABLE "$BASE" "$mss"
  rc=0; go --repo "$FORK" --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
  check "go --repo mergeStateStatus $mss (pending or red checks) -> exit 7" "$rc" 7
done
prview
for th in "1 false" "0 true" "garbage" ""; do
  printf '%s\n' "$th" > "$STUB_THREADS"
  rc=0; go --repo "$FORK" --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
  check "go --repo review threads [$th] -> exit 7" "$rc" 7
done
printf '0 false\n' > "$STUB_THREADS"
printf '%s\n' '[{"nwo":"'"$ORIGIN_NWO"'","upstream":"x/y","himmel_branch":"main","pin_site":null,"role":"self","merge_allowed":true}]' > "$tmp/self.json"
rc=0; STUB_ALLOW="$tmp/self.json" go --repo "$ORIGIN_NWO" --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo the anchor's own repo -> exit 6" "$rc" 6
rc=0; go --repo "$FORK" --trust-reviewed nojudge 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo no judge verdict -> exit 5" "$rc" 5
verdict j2 GO "$SHA" 19
rc=0; go --repo "$FORK" --trust-reviewed j2 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo verdict names another PR -> exit 5" "$rc" 5
rc=0; HANDOVER_DIR="$ROOT" HIMMEL_CONSOLE_LEG=1 _as_claude bash "$GO_SH" --repo "$FORK" --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo from a leg -> exit 3" "$rc" 3
check "go --repo refusals wrote nothing" "$(ls -A "$ROOT/.locks/go" 2>/dev/null)" ""
rc=0; out="$(go --repo "$FORK" --trust-reviewed j1 18 "$SHA" 2>&1)" || rc=$?
check "go --repo valid -> exit 0" "$rc" 0
check "go --repo valid prints the GO path" "$out" "$ROOT/.locks/go/18.$SHA"
contains "go --repo valid GO is trust-reviewed" "$(cat "$ROOT/.locks/go/18.$SHA")" "trust-reviewed=j1"

# e2e: the GO go.sh just signed is the one merge-fork-pr.sh accepts, and the
# same file fails the himmel repo's own verifier (the mac binds the fork nwo).
rc=0; bash -c '. "$1"; go_trust_gate 18 "$2" "$3" "$4" >/dev/null' _ "$HERE/../lib/go-gate.sh" "$SHA" "$ROOT" "$FORK" || rc=$?
check "e2e: go.sh GO verifies for the fork repo" "$rc" 0
rc=0; bash -c '. "$1"; go_trust_gate 18 "$2" "$3" "$4" >/dev/null' _ "$HERE/../lib/go-gate.sh" "$SHA" "$ROOT" "$ORIGIN_NWO" || rc=$?
check "e2e: the same GO fails against the himmel repo" "$rc" 2
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "e2e: merge-fork-pr.sh accepts the GO go.sh wrote" "$rc" 0
check "e2e: exactly one merge ran" "$(merged)" 1
: > "$STUB_LOG"
prview
rm -f "$ROOT/.locks/go/18.$SHA"

# --- 2. merge-fork-pr.sh -----------------------------------------------------
for args in "" "$FORK" "$FORK 18" "$FORK 18 $SHA x" "$FORK x18 $SHA" "$FORK 018 $SHA" "$FORK 18 ${SHA%?}" "a/b/c 18 $SHA"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  merge $args >/dev/null 2>&1 || rc=$?
  check "merge usage [$args] -> exit 2" "$rc" 2
done
write_go "$FORK" 18 "$SHA" j1
rc=0; HANDOVER_DIR="$ROOT" HIMMEL_CONSOLE_LEG=1 _as_claude bash "$MERGE_SH" "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge from a leg -> exit 3" "$rc" 3
rc=0; HIMMEL_CONSOLE_RELAY=1 merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge from a relay -> exit 3" "$rc" 3
rc=0; merge other/repo 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge non-allowlisted repo -> exit 6" "$rc" 6
rc=0; merge yotamleo/off 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge merge_allowed false -> exit 6" "$rc" 6
check "merge refusals so far merged nothing" "$(merged)" 0

rm -f "$ROOT/.locks/go/18.$SHA"
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge missing GO -> exit 8" "$rc" 8
printf 'pr=18\nhead=%s\nby=t\nat=t\nmac=%s\n' "$SHA" "0000000000000000000000000000000000000000000000000000000000000000" > "$ROOT/.locks/go/18.$SHA"
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge forged GO -> exit 8" "$rc" 8
write_go "$FORK" 18 "$OLD" j1
prview OPEN "$SHA"
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge stale GO (GO is for an older head) -> exit 8" "$rc" 8
rm -f "$ROOT/.locks/go/18.$OLD"
write_go "$ORIGIN_NWO" 18 "$SHA" j1
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge GO signed for another repo -> exit 8" "$rc" 8
write_go "$FORK" 18 "$SHA"
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge GO with no judge (not trust-reviewed) -> exit 8" "$rc" 8
check "merge GO refusals merged nothing" "$(merged)" 0

write_go "$FORK" 18 "$SHA" j1
prview OPEN "$OLD"
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge head moved after the GO -> exit 7" "$rc" 7
prview CLOSED "$SHA"
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge PR no longer OPEN -> exit 7" "$rc" 7
prview OPEN "$SHA" MERGEABLE main
rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge PR base is not the himmel_branch -> exit 7" "$rc" 7
check "merge state refusals merged nothing" "$(merged)" 0

for mss in UNSTABLE BLOCKED BEHIND DIRTY UNKNOWN; do
  prview OPEN "$SHA" MERGEABLE "$BASE" "$mss"
  rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
  check "merge mergeStateStatus $mss (pending or red checks) -> exit 7" "$rc" 7
done
prview
for th in "1 false" "0 true" "garbage" ""; do
  printf '%s\n' "$th" > "$STUB_THREADS"
  rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
  check "merge review threads [$th] -> exit 7" "$rc" 7
done
printf '0 false\n' > "$STUB_THREADS"
rc=0; STUB_ALLOW="$tmp/self.json" merge "$ORIGIN_NWO" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge the anchor's own repo -> exit 6" "$rc" 6
# a CLEAN fork PR with no registered check yet, or one still pending, is not ready
for chk in '[]' 'null' '[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]' '[{"context":"ci","state":"PENDING"}]'; do
  prview OPEN "$SHA" MERGEABLE "$BASE" CLEAN "$chk"
  rc=0; out="$(go --repo "$FORK" --trust-reviewed j1 18 "$SHA" 2>&1)" || rc=$?
  check "go --repo CLEAN with checks [$chk] -> exit 7" "$rc" 7
  contains "go --repo CLEAN with checks [$chk] names the checks" "$out" "check"
  rc=0; merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
  check "merge CLEAN with checks [$chk] -> exit 7" "$rc" 7
done
check "merge check refusals merged nothing" "$(merged)" 0
prview
check "merge readiness refusals merged nothing" "$(merged)" 0
prview
rc=0; STUB_NOFLIP=1 merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "merge queued but not MERGED afterwards -> exit 7" "$rc" 7
: > "$STUB_LOG"
prview
rc=0; out="$(merge "$FORK" 18 "$SHA" 2>&1)" || rc=$?
check "merge valid -> exit 0" "$rc" 0
check "merge valid ran exactly one gh pr merge" "$(merged)" 1
contains "merge valid squashes with the head pinned" "$(cat "$STUB_LOG")" "MERGE pr merge 18 --repo $FORK --squash --match-head-commit $SHA"

# --- 3. a relative entry hands off to the anchor named by the launch env (as go.sh) ---
# Marker copies keep everything up to the real hand-off sourcing line, then
# echo a label: a pass proves the shipped line triggers the hand-off.
# shellcheck disable=SC2016  # the literal line the script carries, not an expansion
MF_SRC='. "$_ah_d/../cr/anchor-handoff.sh" || exit 2'
mk_mf_tree() {  # <root> <label>
  mkdir -p "$1/scripts/handover" "$1/scripts/cr"
  git init -q "$1"
  cp "$HERE/../cr/anchor-handoff.sh" "$1/scripts/cr/anchor-handoff.sh"
  awk -v src="$MF_SRC" '{ print } $0 == src { exit }' "$MERGE_SH" > "$1/head.tmp"
  if ! grep -qxF "$MF_SRC" "$1/head.tmp"; then
    echo "FAIL - hand-off setup: the merge script does not carry the hand-off sourcing line verbatim"; fails=$((fails+1))
  fi
  printf '%s\necho "RAN:%s"\n' "$(cat "$1/head.tmp")" "$2" > "$1/scripts/handover/merge-fork-pr.sh"
  rm -f "$1/head.tmp"
}
MF_WT="$tmp/mf-wt"; MF_ANCHOR="$tmp/mf-anchor"
mk_mf_tree "$MF_WT" branch
mk_mf_tree "$MF_ANCHOR" anchor
out=$(cd "$MF_WT" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$MF_ANCHOR" bash scripts/handover/merge-fork-pr.sh 2>/dev/null)
check "merge: relative entry hands off to the anchor" "$out" "RAN:anchor"
out=$(cd "$MF_WT" && env -u CR_ANCHOR_HANDED_OFF HIMMEL_REPO="$MF_ANCHOR" bash "$MF_WT/scripts/handover/merge-fork-pr.sh" 2>/dev/null)
check "merge: absolute entry runs local" "$out" "RAN:branch"
rc=0; (cd "$MF_WT" && env -u CR_ANCHOR_HANDED_OFF -u HIMMEL_REPO bash scripts/handover/merge-fork-pr.sh >/dev/null 2>&1) || rc=$?
check "merge: relative entry with the anchor unset exits 2" "$rc" 2

out=$(jq -r '.[] | select(.nwo == "yotamleo/qmd") | .himmel_branch' "$HERE/../guardrails/himmel-adapters.json" 2>/dev/null)
check "registry: yotamleo/qmd himmel_branch is the fork main the pin tracks" "$out" "main"

if [ "$fails" -eq 0 ]; then
  echo "PASS - test-merge-fork-pr.sh"
else
  echo "FAIL - test-merge-fork-pr.sh ($fails failure(s))"
  exit 1
fi
