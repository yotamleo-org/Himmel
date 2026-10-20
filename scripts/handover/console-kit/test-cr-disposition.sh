#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-go.sh
# scripts/handover/console-kit/test-cr-disposition.sh - suite for
# cr-disposition.sh and the go.sh refusal it drives (exit 9): a Critical or
# Important finding the leg deferred on its own never gets a GO.
#   1. a leg-deferred Important (shaped like a real CR ledger row) -> exit 9.
#   2. record: refused from a leg, follow-up needs all three attests.
#   3. a console follow-up naming a key that does not exist -> exit 9.
#   4. a console follow-up with three attests and a real key -> GO written.
#   5. a disposition at another head, a tampered row, fix-here -> exit 9.
#   6. a Critical needs a judge source whose GO verdict rules this head.
#   7. an Important on a trust-path PR needs a judge source too.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GOSH="$HERE/go.sh"
DISP="$HERE/cr-disposition.sh"
LA="$HERE/../../cr/ledger-append.sh"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY CONSOLE_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cr-disp-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
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

# shellcheck source=scripts/handover/console-kit/testlib-ready-pass.sh
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
SHA=2222222222222222222222222222222222222222
SHA2=3333333333333333333333333333333333333333
export READY_STUB_HEAD="$SHA" READY_STUB_BRANCH="$BR"
ready_pass_ledger "$REPO" "$SHA"
# defer_finding <id> <severity> <text> - a leg-deferred finding at $FHEAD, written
# through the ledger's single writer (test-pr-check-run invariant 7).
defer_finding() {
  local dout
  dout=$(CR_LEDGER="$LEDGER" bash "$LA" finding --branch "$BR" --head "$FHEAD" --model gpt-6.1-sol --id "$1" \
    --severity "$2" --file scripts/config-ui/agui-web/src/main.tsx --line 23 --verdict deferred \
    --reason "Pre-existing production lifecycle defect outside approved e2e-only repair scope; console-directed Bug follow-up verified and linked" \
    --deferred-to HIMMEL-6352 --fu-class hardening --text "$3" 2>&1) || {
    echo "FAIL: fixture finding $1 was not written: $dout" >&2; exit 1; }
}
defer_finding census-reset-1 imp "Fleet census rerender recreates source and resets active transcript"
HDIR="$tmp/root"; mkdir -p "$HDIR"
export HANDOVER_DIR="$HDIR"
gos() { rc=0; out="$(bash "$GOSH" "$@" 2>&1)" || rc=$?; }
nogo() { check "$1 -> nothing written" "$(find "$HDIR/.locks" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"; }

# --- 1. a leg-deferred Important never gets a GO --------------------------
gos 90 "$SHA"
check    "1: leg-deferred Important -> exit 9" "$rc" "9"
contains "1: names the finding at its head" "$out" "census-reset-1@$FHEAD"
nogo     "1: leg-deferred Important"

# --- 2. record refuses a leg and a follow-up short of three attests -------
rc=0; HIMMEL_CONSOLE_LEG=1 bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-6352 \
  --source console --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1 || rc=$?
check "2: record from a console leg -> exit 3" "$rc" "3"
rc=0; bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-6352 \
  --source console --attest ci-green,no-data-loss >/dev/null 2>&1 || rc=$?
check "2: follow-up with two attests -> exit 2" "$rc" "2"
rc=0; bash "$DISP" record 90 "$SHA" "nope-1@$FHEAD" fix-here --source console >/dev/null 2>&1 || rc=$?
check "2: record for a finding not in the ledger -> exit 2" "$rc" "2"
check "2: refusals append nothing" "$(grep -c '"disposition"' "$LEDGER")" "0"

# --- 3. a follow-up naming a key that does not exist ----------------------
bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-999999 \
  --source console --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
gos 90 "$SHA"
check    "3: follow-up to a missing key -> exit 9" "$rc" "9"
contains "3: says the key does not exist" "$out" "HIMMEL-999999 does not exist"
nogo     "3: missing key"

# --- 4. a console follow-up with three attests passes ---------------------
rc=0; bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-6352 \
  --source console --attest no-weakened-guard --attest ci-green --attest no-data-loss >/dev/null 2>&1 || rc=$?
check "4: record follow-up with repeated --attest -> exit 0" "$rc" "0"
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
bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" fix-here --source console >/dev/null 2>&1
gos 90 "$SHA"
check    "5: a later fix-here on a still-deferred finding -> exit 9" "$rc" "9"
contains "5: says fix-here" "$out" "fix-here"
cp "$tmp/ledger.bak" "$LEDGER"
nogo     "5: refusals"

# --- 6. a Critical needs a judge --------------------------------------------
defer_finding codex-9 crit "A deferred Critical"
gos 90 "$SHA"
check "6: leg-deferred Critical -> exit 9" "$rc" "9"
bash "$DISP" record 90 "$SHA" "codex-9@$FHEAD" follow-up:HIMMEL-6352 \
  --source console --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
gos 90 "$SHA"
check    "6: console follow-up on a Critical -> exit 9" "$rc" "9"
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
git -C "$TA" add -A; git -C "$TA" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$TA" remote add origin "$TO"; git -C "$TA" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$TO" symbolic-ref HEAD refs/heads/main
export READY_CHECK_ANCHOR="$TA" READY_STUB_TRUST_FILE=scripts/lib/env-alias.sh
verdict "$HDIR" JT1 "**GO** for head \`$SHA\`." 90 "census-reset-1@$FHEAD follow-up:HIMMEL-6352"
gos --trust-reviewed JT1 90 "$SHA"
check    "7: console follow-up on a trust-path Important -> exit 9" "$rc" "9"
contains "7: names the trust path" "$out" "trust path"
bash "$DISP" record 90 "$SHA" "census-reset-1@$FHEAD" follow-up:HIMMEL-6352 \
  --source judge:JT1 --attest ci-green,no-data-loss,no-weakened-guard >/dev/null 2>&1
gos --trust-reviewed JT1 90 "$SHA"
check "7: judge follow-up on a trust-path Important -> exit 0" "$rc" "0"
unset READY_CHECK_ANCHOR READY_STUB_TRUST_FILE

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-cr-disposition.sh"
  exit 0
else
  echo "FAIL - test-cr-disposition.sh ($fails failure(s))"
  exit 1
fi
