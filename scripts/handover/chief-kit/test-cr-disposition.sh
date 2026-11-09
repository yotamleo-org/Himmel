#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-go.sh
# scripts/handover/chief-kit/test-cr-disposition.sh - suite for
# cr-disposition.sh and the go.sh refusal it drives (exit 9): a Critical or
# Important finding the worker deferred on its own never gets a GO.
#   1. a worker-deferred Important (shaped like a real CR ledger row) -> exit 9.
#   2. record: refused from a worker, follow-up needs all three attests.
#   3. a chief follow-up naming a key that does not exist -> exit 9.
#   4. a chief follow-up with three attests and a real key -> GO written.
#   5. a disposition at another head, a tampered row, fix-here -> exit 9.
#   6. a Critical needs a judge source whose GO verdict rules this head.
#   7. an Important on a trust-path PR needs a judge source too.
#
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GOSH="$HERE/go.sh"
DISP="$HERE/cr-disposition.sh"
LA="$HERE/../../cr/ledger-append.sh"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cr-disp-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
scratch="/tmp/claude-$(id -u)"
[ -d "$scratch" ] || mkdir -m 700 "$scratch" || { echo "FAIL: cannot create $scratch" >&2; rm -rf "$tmp"; exit 1; }
evd="$(mktemp -d "$scratch/cr-disp-test.XXXXXX")" || { echo "FAIL: mktemp -d in $scratch failed" >&2; rm -rf "$tmp"; exit 1; }
trap 'rm -rf "$tmp" "$evd"' EXIT
tmp="$(cd "$tmp" && pwd)"
export HIMMEL_CEILINGS_LEDGER="$tmp/no-ceilings-ledger.tsv"
case "${HIMMEL_CEILINGS_LEDGER:-}" in "$tmp"/*) ;; *) echo "FAIL: the ceilings ledger is not pinned inside the temp dir"; exit 1 ;; esac
export HOME="$tmp/home"; mkdir -p "$HOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "repo view --json nameWithOwner"*) printf 'o/r'; exit 0 ;;
esac
exit 91
STUB
# jira stub: the fixture's follow-up key exists, every other key is not found.
cat > "$tmp/bin/jira" <<'STUB'
#!/usr/bin/env bash
[ "$1" = get ] && [ "$2" = HIMMEL-6352 ] && { printf 'HIMMEL-6352\tBug\tTo Do\tt\n'; exit 0; }
echo "Issue does not exist" >&2; exit 1
STUB
chmod +x "$tmp/bin/gh" "$tmp/bin/jira"
export PATH="$tmp/bin:$PATH"
export JIRA_CMD="$tmp/bin/jira"

# shellcheck source=scripts/handover/chief-kit/testlib-ready-pass.sh
# shellcheck disable=SC1091
. "$HERE/testlib-ready-pass.sh"
ready_pass_bin "$tmp/ready-bin"
export PATH="$tmp/ready-bin:$PATH"
REPO="$tmp/repo"
git init -q "$REPO"
cd "$REPO" || { echo "FAIL: cd $REPO" >&2; exit 1; }
LEDGER="$(git rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl"

fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grep -qF -e "$3" <<< "$2" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }

export USER_SLUG=u
VBUCKET="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
VSCOPE="u/$VBUCKET"
# verdict <root> <qid> <verdict line> <pr> [ruling] [name] [evidence] -a signed judge record, as test-go.sh builds it.
verdict() {
  local vf="$1/$VSCOPE/verdicts/$2/${6:-HIMMEL-1-judge-$2}.md" vmac
  mkdir -p "$1/$VSCOPE/verdicts/$2"
  printf '# VERDICT %s - judge\n\n## Reason (scope asked)\n\nq\n\n## Verdict\n\n%s\n\npr: %s\n\n%s\n\n## Evidence checked\n\n%s\n' \
    "$2" "$3" "$4" "${5:-reason}" "${7:-e}" > "$vf"
  # shellcheck disable=SC2094  # the read finishes before the append below
  vmac="$(bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../../lib/go-gate.sh" "$VSCOPE" "$2" "$(basename "$vf" .md)" < "$vf")" || return 1  # read-sink-ok: the test's own verdict fixture under its temp dir
  printf 'mac: %s\n' "$vmac" >> "$vf"
}

BR=chore/himmel-5647-config-ui-playwright-ci
FHEAD=1080d424a81d7cb754e1abd312fa3d87467863b7
# check 19 fetches origin/main and reads origin/main..<head>: real heads
SHA=$(ready_pass_repo "$REPO") || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
SHA2=$(ready_pass_repo "$REPO" 2) || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
export READY_STUB_HEAD="$SHA" READY_STUB_BRANCH="$BR"
# ready-check reads the branch from the GraphQL snapshot; a branch other than the fixture's keeps the earlier-head
# fixture deferral out of its items 7 and 18, so this suite exercises only cr-disposition.sh's own gate
export READY_STUB_GQL_BRANCH=gql-other
ready_pass_ledger "$REPO" "$SHA"
# defer_finding <id> <severity> <text> - a worker-deferred finding at $FHEAD, written
# through the ledger's single writer (test-pr-check-run invariant 7).
defer_finding() {
  local dout
  dout=$(CR_LEDGER="$LEDGER" bash "$LA" finding --branch "$BR" --head "$FHEAD" --model gpt-6.1-sol --id "$1" \
    --severity "$2" --file scripts/config-ui/agui-web/src/main.tsx --line 23 --verdict deferred \
    --reason "Pre-existing production lifecycle defect outside approved e2e-only repair scope; chief-directed Bug follow-up verified and linked" \
    --deferred-to HIMMEL-6352 --fu-class hardening --fu-why no-check --text "$3" 2>&1) || {
    echo "FAIL: fixture finding $1 was not written: $dout" >&2; exit 1; }
}
defer_finding census-reset-1 imp "Fleet census rerender recreates source and resets active transcript"
HDIR="$tmp/root"; mkdir -p "$HDIR"
export HANDOVER_DIR="$HDIR"
gos() { rc=0; out="$(bash "$GOSH" "$@" 2>&1)" || rc=$?; }
nogo() { check "$1 -> nothing written" "$(find "$HDIR/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"; }

# --- 1. a worker-deferred Important never gets a GO --------------------------
gos 90 "$SHA"
check    "1: worker-deferred Important -> exit 9" "$rc" "9"
contains "1: names the finding at its head" "$out" "census-reset-1@$FHEAD"
nogo     "1: worker-deferred Important"

# --- 2. record refuses a worker and a follow-up short of three attests -------
rc=0; HIMMEL_CONSOLE_LEG=1 bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-6352 \
  --source chief --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1 || rc=$?
check "2: record from a chief worker -> exit 3" "$rc" "3"
rc=0; bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-6352 \
  --source chief --attest ci-green,no-data-loss >/dev/null 2>&1 || rc=$?
check "2: follow-up with two attests -> exit 2" "$rc" "2"
rc=0; bash "$DISP" record 90 "$SHA" "nope-1@$FHEAD" fix-here --source chief >/dev/null 2>&1 || rc=$?
check "2: record for a finding not in the ledger -> exit 2" "$rc" "2"
check "2: refusals append nothing" "$(grep -c '"disposition"' "$LEDGER")" "0"

# --- 3. a follow-up naming a key that does not exist ----------------------
bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-999999 \
  --source chief --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
gos 90 "$SHA"
check    "3: follow-up to a missing key -> exit 9" "$rc" "9"
contains "3: says the key does not exist" "$out" "HIMMEL-999999 does not exist"
nogo     "3: missing key"

# --- 4. a chief follow-up with three attests passes ---------------------
rc=0; CHIEF_SESSION_NAME=chief-x bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-6352 \
  --source chief --attest no-weakened-guard --attest ci-green --attest no-data-loss >/dev/null 2>&1 || rc=$?
check "4: record follow-up with repeated --attest -> exit 0" "$rc" "0"
contains "4: the source names CHIEF_SESSION_NAME over its old name" "$(cat "$LEDGER")" "console:chief-x"
gos 90 "$SHA"
check "4: judged follow-up with three attests -> exit 0" "$rc" "0"
check "4: the GO is written" "$out" "$HDIR/.locks/go/90.$SHA"
rm -rf "$HDIR/.locks"

# --- 5. head-bound, tamper-evident, fix-here never clears -----------------
ready_pass_ledger "$REPO" "$SHA2"
READY_STUB_HEAD="$SHA2" gos 90 "$SHA2"
check "5: disposition recorded at another head -> exit 9" "$rc" "9"
cp "$LEDGER" "$tmp/ledger.bak"
sed -i.x 's/"disposition":"follow-up:HIMMEL-6352"/"disposition":"follow-up:HIMMEL-6353"/' "$LEDGER"
gos 90 "$SHA"
check    "5: an edited disposition row -> exit 9" "$rc" "9"
contains "5: names the bad mac" "$out" "mac"
cp "$tmp/ledger.bak" "$LEDGER"
bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" fix-here --source chief >/dev/null 2>&1
gos 90 "$SHA"
check    "5: a later fix-here on a still-deferred finding -> exit 9" "$rc" "9"
contains "5: says fix-here" "$out" "fix-here"
cp "$tmp/ledger.bak" "$LEDGER"
nogo     "5: refusals"

# --- 6. a Critical needs a judge --------------------------------------------
defer_finding codex-9 crit "A deferred Critical"
gos 90 "$SHA"
check "6: worker-deferred Critical -> exit 9" "$rc" "9"
bash "$DISP" record 90 "$SHA" "codex-9@$FHEAD" follow-up:HIMMEL-6352 \
  --source chief --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
gos 90 "$SHA"
check    "6: chief follow-up on a Critical -> exit 9" "$rc" "9"
contains "6: says a judge must rule" "$out" "judge"
rc=0; bash "$DISP" record 90 "$SHA" "codex-9@$FHEAD" follow-up:HIMMEL-6352 \
  --source judge:JD1 --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1 || rc=$?
check "6: record judge source -> exit 0" "$rc" "0"
gos 90 "$SHA"
check "6: judge source with no GO verdict on this head -> exit 9" "$rc" "9"
verdict "$HDIR" JD1 "**GO** for head \`$SHA\`." 90
gos 90 "$SHA"
check    "6: a GO verdict that does not rule the finding -> exit 9" "$rc" "9"
contains "6: says the verdict does not rule it" "$out" "does not rule"
JDIR="$HDIR/$VSCOPE/verdicts/JD1"
{ cat "$JDIR/HIMMEL-1-judge-JD1.md"; printf -- '- codex-9@%s follow-up:HIMMEL-6352\n' "$FHEAD"; } > "$JDIR/forged.md"
verdict "$HDIR" JD1 "**GO** for head \`$SHA2\`." 90 "- codex-9@$FHEAD follow-up:HIMMEL-6352" other
verdict "$HDIR" JD1 "**GO** for head \`$SHA\`." 91 "- codex-9@$FHEAD follow-up:HIMMEL-6352" otherpr
gos 90 "$SHA"
check "6: a ruling only in an unsigned, other-head or other-PR file -> exit 9" "$rc" "9"
rm -f "$JDIR/forged.md" "$JDIR/other.md" "$JDIR/otherpr.md"
verdict "$HDIR" JD1 "**GO** for head \`$SHA\`." 90 reason evid "- codex-9@$FHEAD follow-up:HIMMEL-6352"
gos 90 "$SHA"
check "6: a ruling only under Evidence checked -> exit 9" "$rc" "9"
rm -f "$JDIR/evid.md"
verdict "$HDIR" JD1 "**GO** for head \`$SHA\`." 90 "- codex-9@$FHEAD follow-up:HIMMEL-6352"
gos 90 "$SHA"
check "6: judge source with a GO verdict ruling the finding -> exit 0" "$rc" "0"
rm -rf "$HDIR/.locks"

# --- 7. an Important on a trust-path PR needs a judge ----------------------
TA="$tmp/anchor"; TO="$tmp/origin.git"
git init -q --bare "$TO"; git init -q "$TA"
mkdir -p "$TA/scripts/lib"; cp "$HERE/../../lib/go-gate.sh" "$TA/scripts/lib/go-gate.sh"
# ready-check's check 19 runs the anchor's impacted-suites.sh
mkdir -p "$TA/scripts/cr"
cp "$HERE/../../cr/impacted-suites.sh" "$HERE/../../cr/anchor-handoff.sh" "$TA/scripts/cr/"
cp "$HERE/../../lib/review-default-base.sh" "$TA/scripts/lib/"
git -C "$TA" add -A; git -C "$TA" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$TA" remote add origin "$TO"; git -C "$TA" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$TO" symbolic-ref HEAD refs/heads/main
export READY_CHECK_ANCHOR="$TA" READY_STUB_TRUST_FILE=scripts/lib/env-alias.sh
verdict "$HDIR" JT1 "**GO** for head \`$SHA\`." 90 "census-reset-1@$FHEAD follow-up:HIMMEL-6352"
gos --trust-reviewed JT1 90 "$SHA"
check    "7: chief follow-up on a trust-path Important -> exit 9" "$rc" "9"
contains "7: names the trust path" "$out" "trust path"
bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-6352 \
  --source judge:JT1 --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
gos --trust-reviewed JT1 90 "$SHA"
check "7: judge follow-up on a trust-path Important -> exit 0" "$rc" "0"
unset READY_CHECK_ANCHOR READY_STUB_TRUST_FILE

# --- 8. past the first signed amend, only a signed amend lowers it ---------
defer_finding ledger-gap-1 imp "Ledger amend rows carry no authentication"
CR_LEDGER="$LEDGER" bash "$LA" amend --head "$FHEAD" --id ledger-gap-1 --set "reason=cutover row" \
  --reason "first signed amend" >/dev/null 2>&1 || { echo "FAIL: fixture signed amend was not written" >&2; exit 1; }
# An unsigned amend: written by the sanctioned writer, then its mac stripped.
unsigned_amend() {
  CR_LEDGER="$LEDGER" bash "$LA" amend --head "$FHEAD" --id ledger-gap-1 --set "$1" \
    --reason "hand-written" >/dev/null 2>&1 || { echo "FAIL: fixture amend was not written" >&2; exit 1; }
  sed -i.x '$ s/,"amend_mac":"[0-9a-f]*"//' "$LEDGER"
}
unsigned_amend verdict=disproved
out="$(bash "$DISP" check 90 "$SHA" 2>&1)"
contains "8: an unsigned disproved amend leaves it open" "$out" "[OPEN] imp ledger-gap-1@$FHEAD"
unsigned_amend severity=sug
out="$(bash "$DISP" check 90 "$SHA" 2>&1)"
contains "8: an unsigned severity downgrade leaves it open" "$out" "[OPEN] imp ledger-gap-1@$FHEAD"
CR_LEDGER="$LEDGER" bash "$LA" amend --head "$FHEAD" --id ledger-gap-1 --set verdict=disproved \
  --reason "the rows are signed now" >/dev/null 2>&1 || { echo "FAIL: fixture signed disproval was not written" >&2; exit 1; }
out="$(bash "$DISP" check 90 "$SHA" 2>&1)"
check "8: a signed disproved amend clears it" "$(grep -c 'ledger-gap-1@' <<< "$out")" "0"

# --- 9. an adopter PR's judge verdict lives in the adopter's bucket ---
defer_finding adopt-9 crit "A deferred Critical on an adopter PR"
printf 'class: other\nclass-reason: fixture\n- adopt-9@%s follow-up:HIMMEL-6352\n\n## Evidence checked\n\n- read the diff\n' "$FHEAD" > "$evd/adopt-ev.md"
bash "$DISP" record 90 "$SHA" "adopt-9@$FHEAD" follow-up:HIMMEL-6352 \
  --source judge:JA1 --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
wvout=$(env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_JUDGE -u HIMMEL_CONSOLE_RELAY HANDOVER_DIR="$HDIR" CLAUDE_CODE_SESSION_ID=sess-judge \
  bash "$HERE/write-verdict.sh" JA1 GO "$SHA" --pr 90 --repo o/other-repo --model test-model --effort high --evidence-file "$evd/adopt-ev.md" 2>&1) \
  || { echo "FAIL: cannot write the adopter verdict: $wvout" >&2; fails=$((fails+1)); }
rc=0; out="$(bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
contains "9: without --repo the adopter bucket is not read" "$out" "[OPEN] crit adopt-9@$FHEAD"
check "9: without --repo the check fails" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero
rc=0; out="$(bash "$DISP" check 90 "$SHA" --repo o/other-repo 2>&1)" || rc=$?
contains "9: --repo finds the GO in the adopter bucket" "$out" "[OK] crit adopt-9@$FHEAD"
check "9: --repo leaves the adopter finding out of the open set" "$(grep -c '\[OPEN\] crit adopt-9@' <<< "$out")" 0
rc=0; out="$(bash "$DISP" check 90 "$SHA" --repo o/third-repo 2>&1)" || rc=$?
contains "9: --repo of another repo does not read it" "$out" "[OPEN] crit adopt-9@$FHEAD"
check "9: another repo's check fails" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero

# --- 10. a GitHub rate limit on the head-branch read reads as a rate limit ---
# GH_CMD replaces gh for the one `pr view --json headRefName` call: the GraphQL answer
# (RATE_LIMIT), the REST wording, an unrelated failure and a success.
gh_stub() {  # <name> <stderr text, empty for success>
  { printf '#!/usr/bin/env bash\n'
    if [ -n "$2" ]; then printf 'echo %q >&2; exit 1\n' "$2"; else printf 'printf "%%s\\n" %q; exit 0\n' "$BR"; fi
  } > "$tmp/bin/$1"
  chmod +x "$tmp/bin/$1"
}
gh_stub gh-rl-gql  "GraphQL: API rate limit already exceeded for user ID 1. (RATE_LIMIT)"
gh_stub gh-rl-rest "gh: HTTP 403: API rate limit exceeded for user ID 1."
gh_stub gh-other   "GraphQL: Could not resolve to a PullRequest with the number of 90."
gh_stub gh-ok      ""
export HIMMEL_QUOTA_DIR="$tmp/quota-crd"   # markers land here, never in the real ~/.himmel
for stub in gh-rl-gql gh-rl-rest; do
  rc=0; out="$(GH_CMD="$tmp/bin/$stub" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
  check    "10: $stub -> exit 2" "$rc" "2"
  contains "10: $stub names a GitHub rate limit" "$out" "GitHub rate limit"
  contains "10: $stub says to retry after the quota returns" "$out" "retry after the quota returns"
  check    "10: $stub is not the unreadable-branch line" "$(grep -c "cannot read PR" <<< "$out")" "0"
done
rc=0; out="$(GH_CMD="$tmp/bin/gh-other" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
check    "10: an unrelated gh failure -> exit 2" "$rc" "2"
contains "10: an unrelated gh failure keeps the old line" "$out" "cr-disposition: cannot read PR #90's head branch"
check    "10: an unrelated gh failure is not called a rate limit" "$(grep -c "rate limit" <<< "$out")" "0"
rc=0; out="$(GH_CMD="$tmp/bin/gh-ok" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
contains "10: a gh success reaches the check" "$out" "[OPEN] crit adopt-9@$FHEAD"
check    "10: a gh success prints neither head-branch line" "$(grep -c "cannot read PR\|rate limit" <<< "$out")" "0"

# --- 11. the quota gates (T3): the one quota line, a bounded read, and a marker on `check` ---
# A refused read prints QUOTA-PAUSE (exit 2) and leaves one marker keyed <pr>.<head>; a hung read is cut by
# CR_DISPOSITION_GH_TIMEOUT and prints GH-STALL; `record`, a usage error and an unrelated failure leave none.
mkers() { find "$HIMMEL_QUOTA_DIR/blocked" -type f ! -name '.lock*' 2>/dev/null | wc -l | tr -d ' '; }
rm -rf "$HIMMEL_QUOTA_DIR"
rc=0; out="$(GH_CMD="$tmp/bin/gh-rl-gql" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
check    "11: a refused read -> exit 2" "$rc" "2"
contains "11: a refused read prints the QUOTA-PAUSE line" "$out" "QUOTA-PAUSE github graphql token=main"
contains "11: the line says nothing was judged" "$out" "nothing-was-judged"
check    "11: a refused read leaves one marker keyed <pr>.<head>" "$(find "$HIMMEL_QUOTA_DIR/blocked" -type f -name "90.$SHA" | wc -l | tr -d ' ')" "1"
contains "11: the marker names the reason" "$(cat "$HIMMEL_QUOTA_DIR/blocked/90.$SHA")" "reason=rate-limit"
contains "11: the marker names the bucket" "$(cat "$HIMMEL_QUOTA_DIR/blocked/90.$SHA")" "buckets=graphql"
mk_first=$(sed -n 's/^first_epoch=//p' "$HIMMEL_QUOTA_DIR/blocked/90.$SHA")
sleep 1
GH_CMD="$tmp/bin/gh-rl-rest" bash "$DISP" check 90 "$SHA" >/dev/null 2>&1
check    "11: a second writer keeps first_epoch" "$(sed -n 's/^first_epoch=//p' "$HIMMEL_QUOTA_DIR/blocked/90.$SHA")" "$mk_first"
check    "11: a second writer leaves one marker" "$(mkers)" "1"
rm -rf "$HIMMEL_QUOTA_DIR"
rc=0; out="$(GH_CMD="$tmp/bin/gh-rl-gql" bash "$DISP" record 90 "$SHA" "adopt-9@$FHEAD" fix-here --source chief 2>&1)" || rc=$?
check    "11: record on a refused read is exit 2" "$rc" "2"
check    "11: record leaves no marker (only check does)" "$(mkers)" "0"
rc=0; out="$(GH_CMD="$tmp/bin/gh-other" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
check    "11: an unrelated gh failure leaves no marker" "$(mkers)" "0"
check    "11: an unrelated gh failure prints no quota line" "$(grep -c 'QUOTA-PAUSE\|GH-STALL' <<< "$out" | tr -d ' ')" "0"
rc=0; out="$(bash "$DISP" check x1 "$SHA" 2>&1)" || rc=$?
check    "11: a usage error leaves no marker" "$(mkers)" "0"
# a rate limit named only on stdout is not a rate limit (the classifier reads stderr)
printf '%s\n' '#!/usr/bin/env bash' 'echo "API rate limit exceeded in the PR body"' 'echo "boom" >&2' 'exit 1' > "$tmp/bin/gh-stdout-rl"
chmod +x "$tmp/bin/gh-stdout-rl"
rc=0; out="$(GH_CMD="$tmp/bin/gh-stdout-rl" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
check    "11: a rate-limit phrase on stdout alone is not a rate limit" "$(mkers)" "0"
# a hung read: cut by CR_DISPOSITION_GH_TIMEOUT, named a stall
printf '%s\n' '#!/usr/bin/env bash' 'exec sleep 60' > "$tmp/bin/gh-hung"
chmod +x "$tmp/bin/gh-hung"
t0=$SECONDS
rc=0; out="$(CR_DISPOSITION_GH_TIMEOUT=2 GH_CMD="$tmp/bin/gh-hung" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
check    "11: a hung read ends in exit 2" "$rc" "2"
check    "11: a hung read is cut within the bound" "$([ $((SECONDS - t0)) -le 12 ] && echo yes || echo no)" "yes"
contains "11: a hung read prints the GH-STALL line" "$out" "GH-STALL github read timed out after 2s"
check    "11: a hung read prints no false cause" "$(grep -c "cannot read PR" <<< "$out" | tr -d ' ')" "0"
check    "11: a hung read leaves one marker" "$(mkers)" "1"
contains "11: the stall marker names the reason" "$(cat "$HIMMEL_QUOTA_DIR/blocked/90.$SHA")" "reason=stall"

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-cr-disposition.sh"
  exit 0
else
  echo "FAIL - test-cr-disposition.sh ($fails failure(s))"
  exit 1
fi
