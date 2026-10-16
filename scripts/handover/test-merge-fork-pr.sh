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
export STUB_ALLOW="$tmp/allow.json" STUB_PRVIEW="$tmp/prview.json" STUB_LOG="$tmp/gh.log"
: > "$STUB_LOG"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view")
        case "$*" in
            *defaultBranchRef*) printf 'o/himmel|main' ;;
            *) printf 'o/himmel' ;;
        esac ;;
    "api repos/o/himmel/contents/scripts/guardrails/himmel-adapters.json?ref=main")
        cat "$STUB_ALLOW" 2>/dev/null || exit 1 ;;
    "pr view") cat "$STUB_PRVIEW" 2>/dev/null || exit 1 ;;
    "pr merge") printf 'MERGE %s\n' "$*" >> "$STUB_LOG" ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

printf '%s\n' '[{"nwo":"yotamleo/qmd","upstream":"tobi/qmd","himmel_branch":"himmel/pin-http-auth","pin_site":"scripts/lib/qmd-bin.sh","role":"runtime-dependency","merge_allowed":true},{"nwo":"yotamleo/off","upstream":"x/off","himmel_branch":"himmel/x","pin_site":null,"role":"dormant","merge_allowed":false}]' > "$STUB_ALLOW"
prview() { printf '{"state":"%s","headRefOid":"%s","mergeable":"%s","baseRefName":"%s"}\n' "${1:-OPEN}" "${2:-$SHA}" "${3:-MERGEABLE}" "${4:-$BASE}" > "$STUB_PRVIEW"; }
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
rc=0; go --repo "$FORK" --trust-reviewed nojudge 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo no judge verdict -> exit 5" "$rc" 5
verdict j2 GO "$SHA" 19
rc=0; go --repo "$FORK" --trust-reviewed j2 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo verdict names another PR -> exit 5" "$rc" 5
rc=0; HIMMEL_CONSOLE_LEG=1 go --repo "$FORK" --trust-reviewed j1 18 "$SHA" >/dev/null 2>&1 || rc=$?
check "go --repo from a leg -> exit 3" "$rc" 3
check "go --repo refusals wrote nothing" "$(ls -A "$ROOT/.locks/go" 2>/dev/null)" ""
rc=0; out="$(go --repo "$FORK" --trust-reviewed j1 18 "$SHA" 2>&1)" || rc=$?
check "go --repo valid -> exit 0" "$rc" 0
check "go --repo valid prints the GO path" "$out" "$ROOT/.locks/go/18.$SHA"
contains "go --repo valid GO is trust-reviewed" "$(cat "$ROOT/.locks/go/18.$SHA")" "trust-reviewed=j1"
rm -f "$ROOT/.locks/go/18.$SHA"

# --- 2. merge-fork-pr.sh -----------------------------------------------------
for args in "" "$FORK" "$FORK 18" "$FORK 18 $SHA x" "$FORK x18 $SHA" "$FORK 018 $SHA" "$FORK 18 ${SHA%?}" "a/b/c 18 $SHA"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  merge $args >/dev/null 2>&1 || rc=$?
  check "merge usage [$args] -> exit 2" "$rc" 2
done
write_go "$FORK" 18 "$SHA" j1
rc=0; HIMMEL_CONSOLE_LEG=1 merge "$FORK" 18 "$SHA" >/dev/null 2>&1 || rc=$?
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
write_go o/himmel 18 "$SHA" j1
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

prview
rc=0; out="$(merge "$FORK" 18 "$SHA" 2>&1)" || rc=$?
check "merge valid -> exit 0" "$rc" 0
check "merge valid ran exactly one gh pr merge" "$(merged)" 1
contains "merge valid squashes with the head pinned" "$(cat "$STUB_LOG")" "MERGE pr merge 18 --repo $FORK --squash --match-head-commit $SHA"

if [ "$fails" -eq 0 ]; then
  echo "PASS - test-merge-fork-pr.sh"
else
  echo "FAIL - test-merge-fork-pr.sh ($fails failure(s))"
  exit 1
fi
