#!/usr/bin/env bash
# scripts/cr/test-critic-pre-existing-tag.sh -- tests for critic-pre-existing-tag.py
# Bash 3.2 safe. Hermetic: a throwaway git repo and a
# recording stub in place of ledger-append.sh; one row runs the real writer.
#
# Statechart rows: S2 (no tag on a [context] finding), S3 (rounds 2 and 3
# only). Invariant I1 (a Critical is never tagged, so never deferred).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
assert_has() {
    case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2'; got: $1)" ;; esac
}
assert_lacks() {
    case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2'; got: $1)" ;; *) ok "$3" ;; esac
}
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

TAG="$HERE/critic-pre-existing-tag.py"

# --- fixture: main holds a.txt (base1..base10) and b.txt (b1..b10). The first
# feature commit (P1) appends pr-line to a.txt. The second (P2, the delta)
# prepends delta-line to a.txt and deletes b.txt line 5 (a deletion-only hunk).
# At P2 a.txt line 1 is the delta, lines 2..11 are base code, line 12 is the
# PR's round-1 code. The delta diff shows a.txt lines 1..4 and b.txt lines 2..7
# (hunks with their three lines of context); the whole PR diff adds a.txt lines
# 9..12.
repo="$tmp/repo"
mkdir -p "$repo"
(
    fixture_enter_git_init_dir "$repo" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    git config diff.context 3
    printf 'base1\nbase2\nbase3\nbase4\nbase5\nbase6\nbase7\nbase8\nbase9\nbase10\n' > a.txt
    printf 'b1\nb2\nb3\nb4\nb5\nb6\nb7\nb8\nb9\nb10\n' > b.txt
    git add a.txt b.txt
    git commit -q -m base
    git checkout -q -b feature
    printf 'pr-line\n' >> a.txt
    git commit -q -am round1
    { printf 'delta-line\n'; cat a.txt; } > a.new && mv a.new a.txt
    sed '5d' b.txt > b.new && mv b.new b.txt
    git commit -q -am delta
) || { echo "FAIL: fixture setup failed" >&2; exit 1; }
db_sha="$(git -C "$repo" rev-parse main)"
p1="$(git -C "$repo" rev-parse feature~1)"
p2="$(git -C "$repo" rev-parse feature)"

# A recording stand-in for ledger-append.sh: logs its argv, exits FAKE_AMEND_RC.
stub="$tmp/ledger-append-stub.sh"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AMEND_LOG"
exit "${FAKE_AMEND_RC:-0}"
EOF
chmod +x "$stub"
AMEND_LOG="$tmp/amend.log"
export AMEND_LOG

findings='## Critical Issues (1 found)
- [codex-1]: crit on base code [a.txt:8]
## Important Issues (10 found)
- [codex-2]: imp on base code far from the change [a.txt:8]
- [codex-3]: imp on the PRs round-1 code [a.txt:12]
- [codex-4]: imp on the delta [a.txt:1]
- [codex-5]: imp from context on base code [context] [a.txt:8]
- [codex-6]: model says it is old [pre-existing] [a.txt:1]
- [codex-7]: imp in a file that is not there [missing.txt:1]
- [codex-8]: imp with a symbol citation [a.txt#base2]
- [codex-10]: imp on an unchanged context line of the delta hunk [a.txt:3]
- [codex-11]: imp on a context line beside a deletion-only hunk [b.txt:4]
- [codex-12]: imp on base code far from the deletion [b.txt:9]
## Suggestions (1 found)
- [codex-9]: sug on base code [a.txt:8]'

# run_tag <round> [extra args...]: findings on stdin, tagged text in $out.
run_tag() {
    rm -f "$AMEND_LOG"
    _round="$1"; shift
    out="$( (cd "$repo" && printf '%s\n' "$findings" | python3 -I "$TAG" --round "$_round" --head "$p2" --db-sha "$db_sha" \
        --branch feature --ledger-append "$stub" "$@") 2>"$tmp/err" )"; rc=$?
    err="$(cat "$tmp/err")"
    amends="$(cat "$AMEND_LOG" 2>/dev/null)"
}

# --- the second round with a delta start point ------------------------------
run_tag 2 --from "$p1"
assert_eq "$rc" "0" "T1 round 2 exits 0 ($err)"
assert_has "$out" "- [codex-2]: imp on base code far from the change [pre-existing] [a.txt:8]" "T1 an Important on base code outside every hunk gets [pre-existing]"
assert_has "$amends" "amend --branch feature --head $p2 --id codex-2 --set pre_existing=true" "T1 the tag is recorded as an amend with the pre_existing field"
assert_has "$out" "- [codex-12]: imp on base code far from the deletion [pre-existing] [b.txt:9]" "T1 base code outside a deletion hunk's window is [pre-existing]"
assert_eq "$(printf '%s\n' "$amends" | grep -c .)" "2" "T1 exactly the two out-of-hunk Importants are amended"
assert_has "$out" "- [codex-3]: imp on the PRs round-1 code [outside-delta] [a.txt:12]" "T1 a line the PR added in round 1, outside the delta hunks, gets [outside-delta]"
assert_lacks "$out" "round-1 code [pre-existing]" "T1 a line the PR changed is never [pre-existing]"
assert_lacks "$amends" "codex-3" "T1 [outside-delta] is informational: no amend"
assert_has "$out" "- [codex-10]: imp on an unchanged context line of the delta hunk [a.txt:3]" "T1 an unchanged context line of the delta hunk is NOT tagged (the delta may have broken it)"
assert_lacks "$amends" "codex-10" "T1 a context-line citation earns no amend"
assert_has "$out" "- [codex-11]: imp on a context line beside a deletion-only hunk [b.txt:4]" "T1 a citation beside a deletion-only hunk is NOT tagged"
assert_lacks "$amends" "codex-11" "T1 a deletion-only hunk's neighbour earns no amend"
assert_has "$out" "- [codex-4]: imp on the delta [a.txt:1]" "T1 an Important on the delta is left as it is"
assert_has "$out" "- [codex-1]: crit on base code [a.txt:8]" "T1 a Critical on base code is untouched (I1)"
assert_lacks "$amends" "codex-1 " "T1 a Critical gets no amend (I1)"
assert_has "$out" "- [codex-5]: imp from context on base code [context] [a.txt:8]" "T1 a [context] Important is untouched (S2)"
assert_lacks "$amends" "codex-5" "T1 a [context] Important gets no amend (S2)"
assert_has "$out" "- [codex-6]: model says it is old [a.txt:1]" "T1 a [pre-existing] the model wrote is stripped, not trusted"
assert_lacks "$amends" "codex-6" "T1 a model-written [pre-existing] earns no amend"
assert_has "$out" "- [codex-7]: imp in a file that is not there [missing.txt:1]" "T1 a citation git blame cannot place is untouched"
assert_has "$out" "- [codex-8]: imp with a symbol citation [a.txt#base2]" "T1 a symbol citation is untouched"
assert_has "$out" "- [codex-9]: sug on base code [a.txt:8]" "T1 a Suggestion is untouched"
assert_has "$out" "## Important Issues (10 found)" "T1 headings pass through"

# --- the third round without a start point: [pre-existing] still works, no [outside-delta]
run_tag 3
assert_has "$out" "[codex-2]: imp on base code far from the change [pre-existing] [a.txt:8]" "T2 round 3 tags [pre-existing]"
assert_lacks "$out" "[outside-delta]" "T2 without a delta there is nothing to be outside of"
assert_has "$out" "- [codex-10]: imp on an unchanged context line of the delta hunk [a.txt:3]" "T2 a context line of the whole-PR diff is not tagged either"
assert_has "$out" "- [codex-11]: imp on a context line beside a deletion-only hunk [b.txt:4]" "T2 a deletion-only hunk's neighbour is not tagged either"

# --- the repository's own diff.context: the panel's plain git diff reads it, so the tagger must too.
# With diff.context=10 the delta hunk of a.txt shows lines 1..11, so base line 8 was shown.
git -C "$repo" config diff.context 10
run_tag 2 --from "$p1"
git -C "$repo" config diff.context 3
assert_has "$out" "- [codex-2]: imp on base code far from the change [a.txt:8]" "T2b a line shown through the repository's diff.context is NOT tagged"
assert_eq "$amends" "" "T2b a line shown through diff.context earns no amend"

# --- rounds 1 and 4 never tag, never amend (S3) ------------------------------
for r in 1 4 5; do
    run_tag "$r" --from "$p1"
    assert_eq "$out" "$findings" "T3 round $r passes the findings through unchanged (S3)"
    assert_eq "$amends" "" "T3 round $r writes no amend (S3)"
done

# --- a failed amend leaves the finding untagged (it keeps blocking) -----------
FAKE_AMEND_RC=1 run_tag 2 --from "$p1"
assert_has "$out" "- [codex-2]: imp on base code far from the change [a.txt:8]" "T4 a refused amend leaves the finding untagged"
assert_lacks "$out" "[pre-existing]" "T4 no tag without the ledger field"
assert_has "$err" "codex-2" "T4 the refusal names the finding on stderr"

# --- the real ledger writer end to end ----------------------------------------
real="$tmp/real"
mkdir -p "$real"
cp "$HERE/ledger-append.sh" "$HERE/anchor-handoff.sh" "$HERE/known-findings.json" "$HERE/ledger-amend-auth.js" "$real/"
led="$tmp/real-ledger.jsonl"
CR_LEDGER="$led" bash "$real/ledger-append.sh" finding --branch feature --head "$p2" --model codex --id codex-2 --severity imp --file a.txt --line 8 --verdict "" >/dev/null 2>&1
rm -f "$AMEND_LOG"
out="$( (cd "$repo" && printf '%s\n' "$findings" | CR_LEDGER="$led" python3 -I "$TAG" --round 2 --head "$p2" --db-sha "$db_sha" \
    --branch feature --from "$p1" --ledger-append "$real/ledger-append.sh") 2>"$tmp/err" )"; rc=$?
assert_eq "$rc" "0" "T5 the real writer: exit 0 ($(cat "$tmp/err"))"
assert_has "$out" "[codex-2]: imp on base code far from the change [pre-existing] [a.txt:8]" "T5 the real writer: tagged"
assert_has "$(cat "$led")" '"pre_existing":true' "T5 the real writer: the amend row carries pre_existing true"

# --- usage ---------------------------------------------------------------------
python3 -I "$TAG" --round 2 </dev/null >/dev/null 2>&1
assert_eq "$?" "2" "T6 missing --head/--db-sha/--branch is a usage error"

if [ "$fail" -eq 0 ]; then echo "PASS test-critic-pre-existing-tag"; else echo "FAILURES in test-critic-pre-existing-tag"; exit 1; fi
