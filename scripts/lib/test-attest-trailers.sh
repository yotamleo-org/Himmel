#!/usr/bin/env bash
# scripts/lib/test-attest-trailers.sh - suite for scripts/lib/attest-trailers.sh.
# Every git case runs in a throw-away repo under mktemp.
# Platform guard: POSIX bash 3.2+; git and jq.
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-go.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$HERE/attest-trailers.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/attest-trailers-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }

BAD='Security reviewed: outbound write is one PR comment'
GOOD='Security reviewed: ad-hoc — reason'

# new_repo <name>: an initialised repo whose main holds one commit; echoes its path.
new_repo() {
    local r="$tmp/$1"
    mkdir -p "$r"
    git -C "$r" init -q -b main
    git -C "$r" config user.email t@example.com
    git -C "$r" config user.name tester
    git -C "$r" commit -q --allow-empty -m "chore: base"
    printf '%s' "$r"
}
# commit_file <repo> <file> <message>: add <file> (content = its name) and commit with <message>.
commit_file() {
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$2" >> "$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q -m "$3"
}
# run_range <repo> [args]: the helper's range over main..HEAD of <repo>; sets out and rc.
run_range() {
    local r="$1"; shift
    rc=0
    out="$(cd "$r" && bash "$LIB" range main HEAD "$@" 2>&1)" || rc=$?
}
# pr_json <repo> <commits-file> <files-file>: derive the PR snapshot shape from main..HEAD.
pr_files() {
    git -C "$1" diff --name-only main...HEAD > "$2"
}
pr_commits() {
    local oid first=1
    printf '['
    for oid in $(git -C "$1" rev-list --reverse main..HEAD); do
        [ "$first" = 1 ] || printf ','
        first=0
        jq -n -c --arg oid "$oid" --arg h "$(git -C "$1" log -1 --format=%s "$oid")" --arg b "$(git -C "$1" log -1 --format=%b "$oid")" \
            --argjson p "$(git -C "$1" log -1 --format=%P "$oid" | wc -w | tr -d ' ')" \
            '{oid: $oid, parents: {totalCount: $p}, messageHeadline: $h, messageBody: $b}'
    done
    printf ']'
}
run_pr() {
    local r="$1"; shift
    pr_files "$r" "$tmp/files.txt"
    pr_commits "$r" > "$tmp/commits.json"
    rc=0
    out="$(bash "$LIB" pr-json "$tmp/commits.json" "$tmp/files.txt" "$@" 2>&1)" || rc=$?
}
# both <repo> <label> <want-rc> <want-text>: assert range and pr-json agree.
both() {
    run_range "$1"
    check "range $2: rc" "$rc" "$3"
    contains "range $2: output" "$out" "$4"
    run_pr "$1"
    check "pr-json $2: rc" "$rc" "$3"
    contains "pr-json $2: output" "$out" "$4"
}

# --- range and pr-json x {first, later, none, merge-only, docs-only, scripts README only}
R=$(new_repo first)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one

Platforms tested: linux
Security reviewed: manual — read the diff"
commit_file "$R" scripts/y.sh "fix(x): [HIMMEL-1] two"
both "$R" "trailers in the first commit" 0 "ATTEST PASS"

R=$(new_repo later)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one"
commit_file "$R" scripts/y.sh "fix(x): [HIMMEL-1] two

Platforms tested: linux
Security reviewed: manual — read the diff"
both "$R" "trailers on a later commit" 0 "ATTEST PASS"
run_range "$R"
contains "range later: the found line" "$out" "ATTEST platforms needed found: Platforms tested: linux"

R=$(new_repo none)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one"
commit_file "$R" scripts/y.sh "fix(x): [HIMMEL-1] two"
both "$R" "no trailer anywhere" 1 "ATTEST FAIL missing=platforms,security"

R=$(new_repo mergeonly)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one"
git -C "$R" checkout -q -b side main
commit_file "$R" other.txt "chore: [HIMMEL-1] side"
git -C "$R" checkout -q feat
git -C "$R" merge -q --no-ff side -m "Merge side

Platforms tested: linux
Security reviewed: manual — merge only"
commit_file "$R" scripts/y.sh "fix(x): [HIMMEL-1] two"
both "$R" "a trailer only on a merge commit" 1 "ATTEST FAIL missing=platforms,security"

R=$(new_repo docsonly)
git -C "$R" checkout -q -b feat
commit_file "$R" docs/a.md "docs: [HIMMEL-1] note"
both "$R" "docs-only" 0 "ATTEST platforms not-needed"
run_range "$R"
contains "range docs-only: security not needed" "$out" "ATTEST security not-needed"

R=$(new_repo readme)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/telegram/README.md "docs: [HIMMEL-1] note"
both "$R" "scripts README only" 0 "ATTEST platforms not-needed"

# --- mixed case, in the first commit and in a later commit only
R=$(new_repo mixedfirst)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one

Platforms tested: Linux
Security reviewed: Manual — read the diff"
both "$R" "mixed case, first commit" 0 "ATTEST PASS"
R=$(new_repo mixedlater)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one"
commit_file "$R" scripts/y.sh "fix(x): [HIMMEL-1] two

PLATFORMS TESTED: linux
Security reviewed: Manual — read the diff"
both "$R" "mixed case, later commit only" 0 "ATTEST PASS"

# --- the split verdict (a bad token first, a good one later), both kinds
R=$(new_repo split)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one

Platforms tested: yes
$BAD"
commit_file "$R" scripts/y.sh "fix(x): [HIMMEL-1] two

Platforms tested: linux
$GOOD"
both "$R" "split verdict" 0 "ATTEST security needed found: Security reviewed: ad-hoc — reason"
run_range "$R" --only platforms
contains "range --only platforms: names only platforms" "$out" "ATTEST platforms needed found: Platforms tested: linux"
case "$out" in *"ATTEST security"*) echo "FAIL - --only platforms: a security line was printed"; fails=$((fails+1)) ;; *) echo "ok - --only platforms: no security line" ;; esac

# --- exit 2: no merge base, bad JSON, an empty file list
R=$(new_repo nobase)
git -C "$R" checkout -q --orphan unrelated
git -C "$R" commit -q --allow-empty -m "chore: unrelated root"
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one"
rc=0; out="$(cd "$R" && bash "$LIB" range main HEAD 2>&1)" || rc=$?
check "range without a merge base: rc" "$rc" "2"
contains "range without a merge base: ATTEST ERROR" "$out" "ATTEST ERROR"

printf '%s' '{"not":"an array"}' > "$tmp/obj.json"
printf 'scripts/x.sh\n' > "$tmp/one.txt"
rc=0; out="$(bash "$LIB" pr-json "$tmp/obj.json" "$tmp/one.txt" 2>&1)" || rc=$?
check "pr-json non-array JSON: rc" "$rc" "2"
contains "pr-json non-array JSON: ATTEST ERROR" "$out" "ATTEST ERROR"
printf '%s' '[]' > "$tmp/empty-commits.json"
: > "$tmp/empty.txt"
rc=0; out="$(bash "$LIB" pr-json "$tmp/empty-commits.json" "$tmp/empty.txt" 2>&1)" || rc=$?
check "pr-json empty file list: rc" "$rc" "2"
contains "pr-json empty file list: ATTEST ERROR" "$out" "ATTEST ERROR"
printf '%s' '[{"messageHeadline":"Merge main","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]' > "$tmp/noparents.json"
rc=0; out="$(bash "$LIB" pr-json "$tmp/noparents.json" "$tmp/one.txt" 2>&1)" || rc=$?
check "pr-json a commit with no parent count (could be a merge): rc 2" "$rc" "2"
contains "pr-json a commit with no parent count: ATTEST ERROR" "$out" "ATTEST ERROR"
rc=0; out="$(bash "$LIB" pr-json "$tmp/no-such.json" "$tmp/one.txt" 2>&1)" || rc=$?
check "pr-json unreadable commits file: rc" "$rc" "2"
rc=0; out="$(bash "$LIB" bogus 2>&1)" || rc=$?
check "an unknown subcommand: rc" "$rc" "2"

# --- attest_files, needs, attest_sec_near_miss, attest_found (sourced)
# shellcheck source=attest-trailers.sh
. "$LIB"
check "attest_files platforms: a script" "$(printf 'scripts/a.sh\ndocs/b.md\n' | attest_files platforms)" "scripts/a.sh"
check "attest_files platforms: a README under scripts/ is not a script" "$(printf 'scripts/README.md\n' | attest_files platforms)" ""
check "attest_files platforms: a bin file" "$(printf 'tools/bin/run\n' | attest_files platforms)" "tools/bin/run"
check "attest_files security: docs are not code" "$(printf 'docs/a.md\nhandovers/x.txt\nsrc/a.ts\n' | attest_files security)" "src/a.ts"
check "needs: a script needs both" "$(printf 'scripts/a.sh\n' | attest_needs | tr '\n' ',')" "platforms,security,"
check "needs: src needs security only" "$(printf 'src/a.ts\n' | attest_needs | tr '\n' ',')" "security,"
check "needs: docs need nothing" "$(printf 'docs/a.md\n' | attest_needs | tr '\n' ',')" ""
rc=0; bash "$LIB" needs < /dev/null > /dev/null 2>&1 || rc=$?
check "needs on the command line: rc 0" "$rc" "0"
rc=0; attest_sec_near_miss "manually" || rc=$?
check "near miss: manually" "$rc" "0"
rc=0; attest_sec_near_miss "review" || rc=$?
check "near miss: review is not one" "$rc" "1"
rc=0; printf 'Security reviewed: manual — x\n' | attest_found security || rc=$?
check "attest_found security: a conforming line" "$rc" "0"
rc=0; printf 'Security reviewed: manually\n' | attest_found security || rc=$?
check "attest_found security: a near miss does not conform" "$rc" "1"
rc=0; printf 'Platforms tested: linuxish\n' | attest_found platforms || rc=$?
check "attest_found platforms: linuxish does not conform" "$rc" "1"

# --- a failing grep is "cannot classify" (exit 2), never "needs nothing": a gate that reads an
# error as an empty file class would pass a code diff with no attestation
badbin="$tmp/badbin"
mkdir -p "$badbin"
printf '#!/bin/sh\nexit 2\n' > "$badbin/grep"
chmod +x "$badbin/grep"
rc=0; out="$(printf 'scripts/a.sh\n' | PATH="$badbin:$PATH" bash "$LIB" needs 2>&1)" || rc=$?
check "needs with a failing grep: rc 2" "$rc" "2"
R=$(new_repo badgrep)
git -C "$R" checkout -q -b feat
commit_file "$R" scripts/x.sh "fix(x): [HIMMEL-1] one"
rc=0; out="$(cd "$R" && PATH="$badbin:$PATH" bash "$LIB" range main HEAD 2>&1)" || rc=$?
check "range with a failing grep: rc 2" "$rc" "2"
printf '%s' '[{"messageHeadline":"fix(x): [HIMMEL-1] one","messageBody":"","parents":{"totalCount":1}}]' > "$tmp/bg-commits.json"
printf 'scripts/x.sh\n' > "$tmp/bg-files.txt"
rc=0; out="$(PATH="$badbin:$PATH" bash "$LIB" pr-json "$tmp/bg-commits.json" "$tmp/bg-files.txt" 2>&1)" || rc=$?
check "pr-json with a failing grep: rc 2" "$rc" "2"

# --- T10 pin moved from the hook suite: the matcher lines hold no backslash (BSD grep reads \b as a literal b)
for var in ATTEST_PLATFORMS_RE ATTEST_SECURITY_RE; do
    line=$(grep -F -e "${var}=" "$LIB" | head -n 1)
    [ -n "$line" ] || { echo "FAIL - could not locate the $var assignment"; fails=$((fails+1)); continue; }
    stripped="${line//\\/}"
    check "$var holds no backslash escape" "$([ "$stripped" = "$line" ] && echo clean || echo backslash)" "clean"
done

# --- I4: the helper is the only reader. Exact expected lists, run from the repo root.
cd "$REPO_ROOT" || exit 1
vocab=$(git grep -l -F -e 'pr-review-toolkit|ad-hoc' -e 'pr-review-toolkit*|ad-hoc*' -e 'gitbash|git-bash' -- scripts ':!scripts/lint' ':!scripts/lib/test-attest-trailers.sh' | sort | tr '\n' ' ')
check "I4 vocabulary: only the helper and W1's pinned copy hold the token and platform lists" "$vocab" \
    "scripts/hooks/check-commit-msg.sh scripts/lib/attest-trailers.sh "
classes=$(git grep -l -F -e '^docs/|^handovers/' -e 'ps1|psm1|psd1|cmd|bat' -- scripts ':!scripts/lint' ':!scripts/lib/test-attest-trailers.sh' | sort | tr '\n' ' ')
check "I4 file classes: only the helper and the CR-lane filter hold the file classes" "$classes" \
    "scripts/hooks/check-cr-before-push.sh scripts/lib/attest-trailers.sh "

# --- display parity: the refusal texts keep human-readable lists, which must name every alternative the helper accepts
plat_alts=${ATTEST_PLATFORM_RE#(}; plat_alts=${plat_alts%)}
old_ifs=$IFS; IFS='|'
for alt in $plat_alts; do
    case "$(cat scripts/hooks/check-platforms-tested.sh)" in
        *"$alt"*) echo "ok - check-platforms-tested.sh names the platform [$alt]" ;;
        *) echo "FAIL - check-platforms-tested.sh does not name the platform [$alt]"; fails=$((fails+1)) ;;
    esac
done
tok_alts=${ATTEST_SEC_TOKEN_RE#(}; tok_alts=${tok_alts%%)*}
for alt in $tok_alts; do
    case "$(cat scripts/hooks/check-security-reviewed.sh)" in
        *"$alt"*) echo "ok - check-security-reviewed.sh names the token [$alt]" ;;
        *) echo "FAIL - check-security-reviewed.sh does not name the token [$alt]"; fails=$((fails+1)) ;;
    esac
done
IFS=$old_ifs

# --- W1 token parity: check-commit-msg.sh keeps a pinned copy of the token regex
w1=$(grep -E "^[[:space:]]*(local )?sec_token_re='" scripts/hooks/check-commit-msg.sh | head -n 1)
w1="${w1#*sec_token_re=\'}"; w1="${w1%\'*}"
check "W1 sec_token_re equals ATTEST_SEC_TOKEN_RE" "$w1" "$ATTEST_SEC_TOKEN_RE"
# --- W1 platform parity: the same for the platform list
w1p=$(grep -E "^[[:space:]]*(local )?plat_token_re='" scripts/hooks/check-commit-msg.sh | head -n 1)
w1p="${w1p#*plat_token_re=\'}"; w1p="${w1p%\'*}"
check "W1 plat_token_re equals ATTEST_PLATFORM_RE" "$w1p" "$ATTEST_PLATFORM_RE"

if [ "$fails" -ne 0 ]; then
    echo "FAIL - test-attest-trailers.sh ($fails failure(s))"
    exit 1
fi
echo "ok - test-attest-trailers.sh"
