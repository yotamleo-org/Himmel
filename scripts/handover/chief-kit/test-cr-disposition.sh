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
export HIMMEL_REPO="$REPO"
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
check "ready-check's owner-review line over the ready-pass fixture" "$(ready_pass_owner_review)" "$READY_PASS_OWNER_LINE"
# ready-check reads the branch from the GraphQL snapshot; a branch other than the fixture's keeps the earlier-head
# fixture deferral out of its items 7 and 18, so this suite exercises only cr-disposition.sh's own gate
export READY_STUB_GQL_BRANCH=gql-other
ready_pass_ledger "$REPO" "$SHA"
defer_finding() {
  local dout dto="${5:-HIMMEL-6352}"
  [ "$dto" != - ] || dto=""
  dout=$(CR_LEDGER="$LEDGER" bash "$LA" finding --branch "${4:-$BR}" --head "$FHEAD" --model gpt-6.1-sol --id "$1" \
    --severity "$2" --file scripts/config-ui/agui-web/src/main.tsx --line 23 --verdict deferred \
    --reason "Pre-existing production lifecycle defect outside approved e2e-only repair scope; chief-directed Bug follow-up verified and linked" \
    ${dto:+--deferred-to "$dto"} ${6:+--artifact "$6"} --fu-class hardening --fu-why no-check --text "$3" 2>&1) || {
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
check "4: the GO is written (its path is go.sh's last line)" "${out##*$'\n'}" "$HDIR/.locks/go/90.$SHA"
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
export HIMMEL_QUOTA_DIR="$tmp/quota-crd"
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
printf '%s\n' '#!/usr/bin/env bash' 'echo "API rate limit exceeded in the PR body"' 'echo "boom" >&2' 'exit 1' > "$tmp/bin/gh-stdout-rl"
chmod +x "$tmp/bin/gh-stdout-rl"
rc=0; out="$(GH_CMD="$tmp/bin/gh-stdout-rl" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
check    "11: a rate-limit phrase on stdout alone is not a rate limit" "$(mkers)" "0"
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

mkdir -p "$tmp/t11bin" "$tmp/t11root" "$tmp/t11noroot"
printf 'himmel_github_token_vm2=ghp_CRDREAD0123456789\n' > "$tmp/t11root/.env"
: > "$tmp/t11noroot/.env"
cat > "$tmp/t11bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "pr view "*"--json headRefName"*)
        printf '%s %s %s %s\n' "${GH_TOKEN:-main}" "$1" "$2" "$3" >> "$T11_LOG"
        case "${T11_MODE:-ok}" in
            hung) exec sleep 60 ;;
            rl) echo 'GraphQL: API rate limit already exceeded for user ID 1. (RATE_LIMIT)' >&2; exit 1 ;;
        esac
        printf '%s\n' "$READY_STUB_BRANCH"; exit 0 ;;
esac
exec "$T11_NEXT" "$@"
STUB
chmod +x "$tmp/t11bin/gh"
t11() {
  local root="$1"; shift
  : > "$tmp/t11.log"
  rc=0; out="$(env -u GH_CMD -u himmel_github_token_vm2 "$@" PATH="$tmp/t11bin:$PATH" T11_NEXT="$tmp/ready-bin/gh" T11_LOG="$tmp/t11.log" \
    GH_READ_ENV_ROOT="$root" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
}
rm -rf "$HIMMEL_QUOTA_DIR"
t11 "$tmp/t11root"
contains "12: a read on the read token reaches the check" "$out" "[OPEN] crit adopt-9@$FHEAD"
check    "12: the head-branch read goes out on the read token" "$(cat "$tmp/t11.log")" "ghp_CRDREAD0123456789 pr view 90"
t0=$SECONDS
t11 "$tmp/t11root" T11_MODE=hung CR_DISPOSITION_GH_TIMEOUT=2
check    "12: a hung read on the read token ends in exit 2" "$rc" "2"
check    "12: and is cut within the bound" "$([ $((SECONDS - t0)) -le 12 ] && echo yes || echo no)" "yes"
contains "12: its GH-STALL line names the read token" "$out" "GH-STALL github read timed out after 2s token=read caller=cr-disposition.sh"
rm -rf "$HIMMEL_QUOTA_DIR"
t11 "$tmp/t11root" T11_MODE=rl
check    "12: a read refused on both tokens is exit 2" "$rc" "2"
check    "12: the refused read token falls back to main once (a gate)" "$(tr '\n' '|' < "$tmp/t11.log")" "ghp_CRDREAD0123456789 pr view 90|main pr view 90|"
contains "12: the QUOTA-PAUSE line names main, the token that refused last" "$out" "QUOTA-PAUSE github graphql token=main"
contains "12: the marker carries both routes" "$(cat "$HIMMEL_QUOTA_DIR/blocked/90.$SHA" 2>/dev/null)" "routes=main,read"
t11 "$tmp/t11noroot"
contains "12 RED control: with no read token configured the check still runs" "$out" "[OPEN] crit adopt-9@$FHEAD"
check    "12 RED control: the head-branch read goes out on main, as today" "$(cat "$tmp/t11.log")" "main pr view 90"

mkdir -p "$tmp/t13bin" "$tmp/foreign"; git init -q "$tmp/foreign"
cat > "$tmp/t13bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in "pr view "*"--json headRefName"*) pwd -P > "$T13_LOG" ;; esac
exec "$T13_NEXT" "$@"
STUB
chmod +x "$tmp/t13bin/gh"
: > "$tmp/t13.log"
rc=0; out="$(cd "$tmp/foreign" && env -u GH_CMD -u himmel_github_token_vm2 PATH="$tmp/t13bin:$PATH" T13_NEXT="$tmp/ready-bin/gh" T13_LOG="$tmp/t13.log" \
  GH_READ_ENV_ROOT="$tmp/t11noroot" bash "$DISP" check 90 "$SHA" 2>&1)" || rc=$?
contains "13: from another repo's folder the gated checkout's ledger is read" "$out" "[OPEN] crit adopt-9@$FHEAD"
check    "13: the head-branch read runs in the gated checkout" "$(cat "$tmp/t13.log")" "$(cd "$REPO" && pwd -P)"

D1FIX="$HERE/fixtures/cr-disposition/d1-ruling-line.txt"
VD="$HDIR/$VSCOPE/verdicts"
FUKEY=HIMMEL-6352
OTHERKEY=HIMMEL-6353
d1() { sed -e "s/<fid>/$1/" -e "s/<fhead>/$FHEAD/" "$D1FIX"; }
export READY_STUB_BRANCH=t14
defer_finding t14-imp imp "A deferred Important on a trust path" t14
defer_finding t14-crit crit "A deferred Critical on a trust path" t14
cp "$LEDGER" "$tmp/ledger.bak14"
D1BOTH="$(d1 t14-imp)"$'\n'"$(d1 t14-crit)"
t14_reset() {
  [ ! -d "$VD" ] || chmod 755 "$VD"
  cp "$tmp/ledger.bak14" "$LEDGER"
  rm -rf "$VD"/JV* "$HDIR/.locks"
  export READY_STUB_BRANCH=t14 READY_CHECK_ANCHOR="$TA" READY_STUB_TRUST_FILE=scripts/lib/env-alias.sh \
    JIRA_CMD="$tmp/bin/jira" HANDOVER_DIR="$HDIR"
  verdict "$HDIR" JV1 "**GO** for head \`$SHA\`." 93
}
chk() { rc=0; out="$(bash "$DISP" check "$@" 2>&1)" || rc=$?; }
wv() {
  local wvout
  wvout=$(env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_JUDGE -u HIMMEL_CONSOLE_RELAY HANDOVER_DIR="$HDIR" CLAUDE_CODE_SESSION_ID=sess-judge \
    bash "$HERE/write-verdict.sh" "$1" GO "$SHA" --pr "$2" --model test-model --effort high --evidence-file "$3" 2>&1) \
    || { echo "FAIL - cannot write verdict $1: $wvout"; fails=$((fails+1)); }
}
printf '%s\n\n## Evidence checked\n\n- read the diff\n' "$D1BOTH" > "$evd/jv2-ev.md"
jv2() { wv JV2 93 "$evd/jv2-ev.md"; }
chief_rows() {
  local f
  for f in t14-imp t14-crit; do
    bash "$DISP" record 93 "$SHA" "$f@$FHEAD" follow-up:HIMMEL-6352 --source chief \
      --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1 || { echo "FAIL - chief row for $f not recorded"; fails=$((fails+1)); }
  done
}
both_open() {
  contains "$1: t14-imp stays open" "$out" "[OPEN] imp t14-imp@$FHEAD"
  contains "$1: t14-crit stays open" "$out" "[OPEN] crit t14-crit@$FHEAD"
}
one_line() {
  check    "$1: the output is one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
  contains "$1: it names $2" "$out" "$2"
  contains "$1: it says it is not a GitHub wait" "$out" "(not a GitHub wait"
}
gofile() { find "$HDIR/.locks/go" -type f 2>/dev/null | wc -l | tr -d ' '; }

t14_reset
gos --trust-reviewed JV1 93 "$SHA"
check "14 NC: a GO that rules nothing -> go.sh exit 9" "$rc" "9"
both_open "14 NC"
nogo  "14 NC"
chk 93 "$SHA" --trust-path yes
for f in imp:t14-imp crit:t14-crit; do
  contains "14 NC: ${f#*:}'s reason names the ruling line (R5-F45)" "$out" \
    "[OPEN] ${f%%:*} ${f#*:}@$FHEAD: no disposition row at this head; no judge GO at this head carries $(d1 "${f#*:}") (brief the judge with the deferred key)"
done

t14_reset; jv2
gos --trust-reviewed JV2 93 "$SHA"
check "14 R1: a judge GO through the real writer ruling both -> go.sh exit 0" "$rc" "0"
check "14 R1: the GO file is written" "$([ -f "$HDIR/.locks/go/93.$SHA" ] && gofile)" "1"
chk 93 "$SHA" --trust-path yes
contains "14 R1: t14-imp is cleared by JV2" "$out" "[OK] imp t14-imp@$FHEAD: follow-up:HIMMEL-6352 (verdict:JV2)"
contains "14 R1: t14-crit is cleared by JV2" "$out" "[OK] crit t14-crit@$FHEAD: follow-up:HIMMEL-6352 (verdict:JV2)"

t14_reset; jv2
gos --trust-reviewed JV1 93 "$SHA"
check "14 R1b: JV2 rules them while go.sh trusts JV1 -> exit 0" "$rc" "0"

t14_reset; chief_rows
gos --trust-reviewed JV1 93 "$SHA"
check    "14 R2: a chief coverage row clears no trust-path Important or Critical (the bounded exception) -> exit 9" "$rc" "9"
contains "14 R2: names the trust path" "$out" "trust path"
both_open "14 R2"
nogo     "14 R2"

t14_reset; jv2
mkdir -p "$VD/JV4"; mv "$VD/JV2"/*.md "$VD/JV4/"; rm -rf "$VD/JV2"
gos --trust-reviewed JV1 93 "$SHA"
check "14 R3: JV2's record moved under JV4 -> exit 9" "$rc" "9"
both_open "14 R3"

for c in a b c d e f; do
  t14_reset
  case "$c" in
    a) verdict "$HDIR" JV3a "**GO** for head \`$SHA\`." 93 "delta: no-op"$'\n'"$D1BOTH" ;;
    b) verdict "$HDIR" JV3b "**GO** for head \`$SHA\`." 94 "$D1BOTH" ;;
    c) verdict "$HDIR" JV3c "**GO** for head \`$SHA2\`." 93 "$D1BOTH" ;;
    d) verdict "$HDIR" JV3d "**GO** for head \`$SHA\`." 93 reason evid "$D1BOTH" ;;
    e) verdict "$HDIR" JV3e "**GO** for head \`$SHA\`." 93 "$D1BOTH"
       verdict "$HDIR" JV3e "**GO** for head \`$SHA\`." 94 reason sibling ;;
    f) verdict "$HDIR" JV3f "**GO** for head \`$SHA\`." 93 "delta-scope: x"$'\n'"$D1BOTH" ;;
  esac
  chk 93 "$SHA" --trust-path yes
  check "14 R4 ($c): a signed record that is not a GO for this PR and head clears nothing -> exit 1" "$rc" "1"
  both_open "14 R4 ($c)"
done
t14_reset
verdict "$HDIR" JV3ok "**GO** for head \`$SHA\`." 93 "$D1BOTH"
chk 93 "$SHA" --trust-path yes
check    "14 R4 control: the same signed record for PR 93 at the head -> exit 0" "$rc" "0"
contains "14 R4 control: t14-imp cleared" "$out" "[OK] imp t14-imp@$FHEAD: follow-up:HIMMEL-6352 (verdict:JV3ok)"
contains "14 R4 control: t14-crit cleared" "$out" "[OK] crit t14-crit@$FHEAD: follow-up:HIMMEL-6352 (verdict:JV3ok)"

for c in legacy two-attests reordered; do
  t14_reset
  case "$c" in
    legacy)      r5=$(printf '%s\n' "$D1BOTH" | sed 's/ attest:.*//') ;;
    two-attests) r5=$(printf '%s\n' "$D1BOTH" | sed 's/,no-weakened-guard$//') ;;
    reordered)   r5=$(printf '%s\n' "$D1BOTH" | sed 's/attest:ci-green,no-data-loss,/attest:no-data-loss,ci-green,/') ;;
  esac
  verdict "$HDIR" JV5 "**GO** for head \`$SHA\`." 93 "$r5"
  chk 93 "$SHA" --trust-path yes
  check "14 R5 ($c): not the D1 form -> exit 1" "$rc" "1"
  both_open "14 R5 ($c)"
done
t14_reset
verdict "$HDIR" JV5 "**GO** for head \`$SHA\`." 93 "- $(d1 t14-imp)"$'\n'"- $(d1 t14-crit)"
chk 93 "$SHA" --trust-path yes
check "14 R5 control: the D1 form after '- ' -> exit 0" "$rc" "0"
t14_reset
verdict "$HDIR" JV5 "**GO** for head \`$SHA\`." 93 reason later "e"$'\n\n'"## Verdict"$'\n\n'"$D1BOTH"
chk 93 "$SHA" --trust-path yes
check "14 R5b: the D1 lines under a second ## Verdict heading in the evidence -> exit 1" "$rc" "1"
both_open "14 R5b"

t14_reset
for f in t14-imp t14-crit; do bash "$DISP" record 93 "$SHA" "$f@$FHEAD" fix-here --source chief >/dev/null 2>&1; done
jv2
gos --trust-reviewed JV2 93 "$SHA"
check    "14 R6 (a): a fix-here row stays open whatever JV2 rules -> exit 9" "$rc" "9"
contains "14 R6 (a): says fix-here" "$out" "[OPEN] imp t14-imp@$FHEAD: the ruling is fix-here"
nogo     "14 R6 (a)"
t14_reset
bash "$DISP" record 93 "$SHA" "t14-imp@$FHEAD" follow-up:HIMMEL-6352 --source chief \
  --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
tail -n 1 "$LEDGER" | sed 's/,"mac":"[0-9a-f]*"//' > "$tmp/unsigned14.jsonl"
check "14 R6 (b): the raw row carries no mac" "$(grep -c '"mac"' "$tmp/unsigned14.jsonl")" "0"
cat "$tmp/unsigned14.jsonl" >> "$LEDGER"
jv2
gos --trust-reviewed JV2 93 "$SHA"
check    "14 R6 (b): an unsigned latest row stays open whatever JV2 rules -> exit 9" "$rc" "9"
contains "14 R6 (b): says no valid mac" "$out" "[OPEN] imp t14-imp@$FHEAD: its disposition row carries no valid mac"

t14_reset
printf '%s\n%s\n\n## Evidence checked\n\n- read the diff\n' "$(d1 t14-imp | sed "s/$FUKEY/$OTHERKEY/")" "$(d1 t14-crit)" > "$evd/r7-ev.md"
wv JV2 93 "$evd/r7-ev.md"
gos --trust-reviewed JV2 93 "$SHA"
check "14 R7 (a): a ruling for another key -> exit 9" "$rc" "9"
chk 93 "$SHA" --trust-path yes
contains "14 R7 (a): the reason names both keys" "$out" "judge JV2 rules follow-up:HIMMEL-6353 but the finding is deferred to HIMMEL-6352"
t14_reset; jv2
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/jira-miss"; chmod +x "$tmp/bin/jira-miss"
JIRA_CMD="$tmp/bin/jira-miss" gos --trust-reviewed JV2 93 "$SHA"
check    "14 R7 (b): the ruled key is not in Jira -> exit 9" "$rc" "9"
contains "14 R7 (b): says the key does not exist" "$out" "HIMMEL-6352 does not exist"
t14_reset
defer_finding t14-nokey imp "A deferral with no follow-up ticket" t14n -
verdict "$HDIR" JV2 "**GO** for head \`$SHA\`." 93 "$(d1 t14-nokey)"
rc=0; out="$(READY_STUB_BRANCH=t14n bash "$DISP" check 93 "$SHA" --trust-path yes 2>&1)" || rc=$?
check    "14 R7 (c): a deferral with no deferred_to gets no verdict route -> exit 1" "$rc" "1"
contains "14 R7 (c): it stays open" "$out" "[OPEN] imp t14-nokey@$FHEAD"

t14_reset
defer_finding t14-spec imp "A spec critic finding sharing the head" t14 HIMMEL-6352 spec
printf '%s\n%s\n\n## Evidence checked\n\n- read the diff\n' "$D1BOTH" "$(d1 t14-spec)" > "$evd/r14-ev.md"
wv JV2 93 "$evd/r14-ev.md"
chk 93 "$SHA" --trust-path yes
check    "14 R14: a ruling never clears a spec finding -> exit 1" "$rc" "1"
contains "14 R14: t14-spec stays open" "$out" "[OPEN] imp t14-spec@$FHEAD"
contains "14 R14: the diff Important is cleared" "$out" "[OK] imp t14-imp@$FHEAD: follow-up:HIMMEL-6352 (verdict:JV2)"
contains "14 R14: the diff Critical is cleared" "$out" "[OK] crit t14-crit@$FHEAD: follow-up:HIMMEL-6352 (verdict:JV2)"

t14_reset; jv2
verdict "$HDIR" JV7 "**GO** for head \`$SHA2\`." 93
printf '\0' >> "$VD/JV7/HIMMEL-1-judge-JV7.md"
chk 93 "$SHA" --trust-path yes
check   "14 R8 (a): a NUL-bearing record under a listed qid -> exit 2" "$rc" "2"
one_line "14 R8 (a)" "$VD/JV7/HIMMEL-1-judge-JV7.md"
gos --trust-reviewed JV2 93 "$SHA"
check   "14 R8 (f): through go.sh -> exit 11" "$rc" "11"
t14_reset; jv2
verdict "$HDIR" JV7 "**GO** for head \`$SHA2\`." 93
: > "$VD/JV7/empty.md"
chk 93 "$SHA" --trust-path yes
check   "14 R8 (b): an empty record beside a listed one -> exit 2" "$rc" "2"
one_line "14 R8 (b)" "$VD/JV7/empty.md"
t14_reset; jv2
rc=0; out="$(HANDOVER_DIR="$tmp/missing" bash "$DISP" check 93 "$SHA" --trust-path yes 2>&1)" || rc=$?
check   "14 R8 (c): an unresolved handover root -> exit 2" "$rc" "2"
one_line "14 R8 (c)" "$tmp/missing"
t14_reset; jv2
chk 93 "$SHA" --trust-path yes --repo -bad/x
check   "14 R8 (d): a repo with no verdict scope -> exit 2" "$rc" "2"
one_line "14 R8 (d)" "-bad/x"
t14_reset
verdict "$HDIR" JV7 "**GO** for head \`$SHA\`." 93 "$D1BOTH"
sed -i.x '$ s/^mac: .*/mac: 0000000000000000000000000000000000000000000000000000000000000000/' "$VD/JV7/HIMMEL-1-judge-JV7.md"
rm -f "$VD/JV7/HIMMEL-1-judge-JV7.md.x"
chk 93 "$SHA" --trust-path yes
check "14 R8 (e): the ruling only in a record whose mac fails -> exit 1 (the qid is dropped)" "$rc" "1"
both_open "14 R8 (e)"
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP - 14 R8 (g): root reads a mode-000 directory"
else
  t14_reset; jv2
  chmod 000 "$VD"
  chk 93 "$SHA" --trust-path yes
  chmod 755 "$VD"
  check   "14 R8 (g): an unreadable verdicts directory -> exit 2" "$rc" "2"
  one_line "14 R8 (g)" "$VD"
fi
t14_reset; jv2
verdict "$HDIR" JV8 "**NO-GO** for head \`deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\`." 93
chk 93 "$SHA" --trust-path yes
check   "14 R8 (h): a NO-GO at a head the checkout cannot order -> exit 2" "$rc" "2"
one_line "14 R8 (h)" "deadbeef"
t14_reset
printf '%s\r\n%s\r\n\r\n## Evidence checked\r\n\r\n- read the diff\r\n' "$(d1 t14-imp)" "$(d1 t14-crit)" > "$evd/r15-ev.md"
wv JV2 93 "$evd/r15-ev.md"
chk 93 "$SHA" --trust-path yes
check "14 R15: a CRLF evidence file still rules both (the mac is over the raw bytes) -> exit 0" "$rc" "0"

t14_reset; jv2
verdict "$HDIR" JV8 "**NO-GO** for head \`$SHA\`." 93
chk 93 "$SHA" --trust-path yes
check    "14 R10 (a): a judge's NO-GO at the head vetoes the ruling -> exit 1" "$rc" "1"
contains "14 R10 (a): the reason names JV8's NO-GO" "$out" "judge JV8 holds a NO-GO for PR 93 at or after $SHA"
t14_reset; jv2
DESC=$(GIT_AUTHOR_DATE="@2 +0000" GIT_COMMITTER_DATE="@2 +0000" git -C "$REPO" -c user.name=t -c user.email=t@example.com \
  commit-tree -p "$SHA" -m d "$SHA^{tree}")
verdict "$HDIR" JV8 "**NO-GO** for head \`$DESC\`." 93
chk 93 "$SHA" --trust-path yes
check "14 R10 (b): a NO-GO at a descendant of the head vetoes it -> exit 1" "$rc" "1"
both_open "14 R10 (b)"

t14_reset; chief_rows; jv2
gos --trust-reviewed JV2 93 "$SHA"
check "14 R9: chief coverage rows do not block the judge's ruling -> exit 0" "$rc" "0"
t14_reset
wv JV6 95 "$evd/jv2-ev.md"
READY_STUB_TRUST_FILE='' gos 95 "$SHA"
check "14 R11: off a trust path a plain go.sh with JV6 ruling both -> exit 0" "$rc" "0"
t14_reset
defer_finding t14b-imp imp "One deferred Important off a trust path" t14b
READY_STUB_BRANCH=t14b bash "$DISP" record 96 "$SHA" "t14b-imp@$FHEAD" follow-up:HIMMEL-6352 --source chief \
  --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
rc=0; out="$(READY_STUB_BRANCH=t14b HANDOVER_DIR="$tmp/missing" bash "$DISP" check 96 "$SHA" --trust-path no 2>&1)" || rc=$?
check "14 R12: a row-route pass reads no verdict, even with no handover root -> exit 0" "$rc" "0"

d1norm() { tr '\n' ' ' | sed 's/> //g; s/  */ /g'; }
d1doc=$(sed 's/HIMMEL-6352/<KEY>/' "$D1FIX" | d1norm)
d1doc=${d1doc% }
check "14 R13: the absence matcher fires on the old template wording" \
  "$(printf '%s\n' '> that head carries that line. The chief (never the worker) records it with `cr-disposition.sh record … --source' '> judge:<qid>`.' | d1norm | grep -c -e '--source judge:')" "1"
for doc in docs/handover/judge-brief-template.md docs/handover/chief-sections/judge.md; do
  dtext=$(d1norm < "$HERE/../../../$doc")
  contains "14 R13: $doc holds the ruling line" "$dtext" "$d1doc"
  check    "14 R13: $doc never asks for a judge-source row" "$(grep -c -e '--source judge:' <<< "$dtext")" "0"
done

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-cr-disposition.sh"
  exit 0
else
  echo "FAIL - test-cr-disposition.sh ($fails failure(s))"
  exit 1
fi
