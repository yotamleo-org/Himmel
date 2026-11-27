#!/usr/bin/env bash
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail, so A && B || C is if-then-else here
# shellcheck disable=SC2153  # REPO is exported by the sourced tick-test-fixture.sh
# shellcheck disable=SC2154  # fails is set by the sourced tick-test-fixture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
GEN="$HERE/drift-brief.py"
LINT="$HERE/brief-lint.sh"

mkdir -p "$W/repo/scripts/upstreams"
export DRIFT_NOW=2026-11-24T12:00Z

cat > "$W/drift-gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${DRIFT_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$DRIFT_GH_LOG"
[ -z "${DRIFT_GH_FAIL:-}" ] || exit 1
case " $* " in *" -R $DRIFT_EXPECT_REPO "*) ;; *) exit 7 ;; esac
if [ "${1:-} ${2:-}" = "issue view" ]; then cat "$DRIFT_BODY_FILE"; exit; fi
[ "${1:-} ${2:-}" = "issue list" ] || exit 7
case " $* " in *" --label ${DRIFT_ISSUE_LABEL:-fork-drift} "*) ;; *) exit 7 ;; esac
case " $* " in *" --state open "*) ;; *) exit 7 ;; esac
case " $* " in *" --json body "*) ;; *) exit 7 ;; esac
[ -z "${DRIFT_NO_OPEN:-}" ] || exit 0
cat "$DRIFT_BODY_FILE"
STUB
chmod +x "$W/drift-gh"
# shellcheck source=../../lib/env-value.sh
. "$HERE/../../lib/env-value.sh"
DRIFT_EXPECT_REPO="$(env_value HIMMEL_REPO git -C "$HERE" remote get-url origin | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')"
export TICK_DRIFT_GH="$W/drift-gh" DRIFT_BODY_FILE="$W/body.md" DRIFT_EXPECT_REPO

HEAD_ROWS='| Name | Kind | Current pin | Target | Action |
|---|---|---|---|---|'
ROW_TASTE='| taste-skill-core | upstream pin | f6b7657 | 6c0b5c7 | bump the marketplace.json sha pin to 6c0b5c7 |'
HELD_LINE='  npm:oxlint 1.93.0 (scripts/hooks/check-oxlint-complexity.sh): HELD     (latest 1.94.0 reviewed and held back: 72 h buffer)'

mk_body() {
    {
        if [ -n "$1" ]; then
            printf '### Needs update (1)\n\n%s\n%s\n\n' "$HEAD_ROWS" "$1"
        fi
        printf '<details>\n<summary>Current and other rows (2)</summary>\n\n```\n'
        printf '  claude-obsidian: CURRENT  (fork tracks AgriciDaniel/claude-obsidian @ v3.0.1; pin v3.0.1)\n'
        [ -z "$2" ] || printf '%s\n' "$2"
        printf '```\n\n</details>\n'
    } > "$DRIFT_BODY_FILE"
}
mk_holds() {
    printf '{"holds": [{"eco": "npm", "key": "oxlint", "current": "1.93.0", "latest_reviewed": "1.94.0", "reason": "buffer", "eligible": "%s"}]}\n' "$1" > "$W/repo/scripts/upstreams/pin-holds.json"
}
drift_of() { printf '%s\n' "$1" | grep '^TICK ' | tr ' ' '\n' | grep '^drift='; }
same() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (want '$3' got '$2')"; }
has_wake() { printf '%s\n' "$1" | grep -Fxq "WAKE drift-actionable $2"; }
wakes() { printf '%s\n' "$1" | grep -c '^WAKE drift-actionable ' || true; }

mk_holds 2026-11-25T08:00Z
mk_body "$ROW_TASTE" ''
export TICK_STATE_DIR="$W/state-once"
export DRIFT_GH_LOG="$W/gh.log"
out1="$(bash "$SUT")"
same 'one Needs-update row prints drift=1 on the TICK line' "$(drift_of "$out1")" 'drift=1'
has_wake "$out1" 1 && pass 'one actionable row wakes the chief' || fail 'one actionable row wakes the chief'
[ "$(wakes "$out1")" -eq 1 ] && pass 'the first tick of the day prints exactly one wake' || fail "the first tick printed $(wakes "$out1") wakes"
out2="$(bash "$SUT")"
same 'a second same-day tick still prints drift=1' "$(drift_of "$out2")" 'drift=1'
[ "$(wakes "$out2")" -eq 0 ] && pass 'a second same-day tick does not wake again' || fail "the second tick printed $(wakes "$out2") wakes"
[ "$(wc -l < "$DRIFT_GH_LOG")" -eq 1 ] && pass 'a second tick within the hour makes no gh call' || fail "two ticks made $(wc -l < "$DRIFT_GH_LOG") gh calls"
unset DRIFT_GH_LOG

mk_holds 2026-11-25T08:00Z
mk_body '' "$HELD_LINE"
export TICK_STATE_DIR="$W/state-buffer"
out3="$(bash "$SUT")"
same 'an in-buffer hold alone prints drift=0' "$(drift_of "$out3")" 'drift=0'
[ "$(wakes "$out3")" -eq 0 ] && pass 'an in-buffer hold alone gives no wake' || fail "an in-buffer hold woke $(wakes "$out3") times"

mk_holds 2026-11-24T08:00Z
export TICK_STATE_DIR="$W/state-cleared"
out4="$(bash "$SUT")"
has_wake "$out4" 1 && pass 'a buffer-cleared hold counts as one actionable row' || fail 'a buffer-cleared hold counts as one actionable row'

export TICK_STATE_DIR="$W/state-fail"
out5="$(DRIFT_GH_FAIL=1 bash "$SUT")"
same 'a failed gh read prints drift=?' "$(drift_of "$out5")" 'drift=?'
[ "$(wakes "$out5")" -eq 0 ] && pass 'a failed gh read never wakes' || fail "a failed read woke $(wakes "$out5") times"

mk_holds 2026-11-25T08:00Z
mk_body "$ROW_TASTE" ''
export TICK_STATE_DIR="$W/state-closed"
out7="$(DRIFT_NO_OPEN=1 bash "$SUT")"
same 'a closed issue with a stale actionable body prints drift=0' "$(drift_of "$out7")" 'drift=0'
[ "$(wakes "$out7")" -eq 0 ] && pass 'a closed issue never wakes' || fail "a closed issue woke $(wakes "$out7") times"
mk_body "$ROW_TASTE" ''
export TICK_STATE_DIR="$W/state-label"
bash "$SUT" > /dev/null
out9="$(DRIFT_ISSUE_LABEL=other-drift DRIFT_NO_OPEN=1 bash "$SUT" 2>&1)"
same 'a cached body of another label is not reused' "$(drift_of "$out9")" 'drift=0'
rm -f "$DRIFT_BODY_FILE"
export TICK_STATE_DIR="$W/state-noissue"
out8="$(DRIFT_NO_OPEN=1 bash "$SUT")"
same 'no open drift issue prints drift=0' "$(drift_of "$out8")" 'drift=0'
[ "$(wakes "$out8")" -eq 0 ] && pass 'no open drift issue never wakes' || fail "no open issue woke $(wakes "$out8") times"

mk_holds 2026-11-24T08:00Z
mk_body "$ROW_TASTE" "$HELD_LINE"
mkdir -p "$W/bucket" "$W/wt"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY
mkdir -p "$HANDOVER_DIR"
brief_out="$(python3 -I "$GEN" brief --body-file "$DRIFT_BODY_FILE" --holds "$W/repo/scripts/upstreams/pin-holds.json" \
    --out "$W/bucket" --worktree "$W/wt" --chief HIMMEL-test-chief --worker D1 --date 2026-11-24)"
brief="$(printf '%s\n' "$brief_out" | tail -n 1)"
[ -f "$brief" ] && pass 'the generator writes a brief into the bucket and prints its path' || fail "no brief at '$brief'"
drift_tok="$(grep -o 'D-D1-[0-9a-f]*' "$brief" 2>/dev/null | head -n 1)"
[ -n "$drift_tok" ] && [ "$(bash "$HERE/worker-token.sh" current "$brief" 2>/dev/null)" = "$drift_tok" ] \
    && pass "DB1: the drift brief's token is the record's current token" || fail "DB1: brief token '$drift_tok' is not the record's current token"
grep -qxE 'D-D1-[0-9a-f]{8}' <<< "$drift_tok" && pass 'DB1c: the token keeps the D-<worker>-<8 hex> shape' || fail "DB1c: token '$drift_tok'"
contains 'the brief names a Needs-update row' "$(cat "$brief" 2>/dev/null)" 'taste-skill-core'
contains 'the brief names a buffer-cleared hold row' "$(cat "$brief" 2>/dev/null)" 'oxlint'
contains 'the brief reads the issue body, not only its metadata' "$(cat "$brief" 2>/dev/null)" '--json body'
contains 'the brief lets an oxlint row edit its hook pin files' "$(grep '^> \*\*Writes:\*\*' "$brief" 2>/dev/null)" 'scripts/hooks/check-oxlint-hardening.sh'
brief_before="$(cat "$brief" 2>/dev/null)"
again_rc=0
python3 -I "$GEN" brief --body-file "$DRIFT_BODY_FILE" --holds "$W/repo/scripts/upstreams/pin-holds.json" \
    --out "$W/bucket" --worktree "$W/wt" --chief HIMMEL-test-chief --worker D1 --date 2026-11-24 >/dev/null 2>&1 || again_rc=$?
[ "$again_rc" -eq 1 ] && pass 'a repeated brief for the same worker and day exits 1' || fail "a repeated brief exited $again_rc"
same 'a repeated brief leaves the existing brief unchanged' "$(cat "$brief" 2>/dev/null)" "$brief_before"
lint_err="$(bash "$LINT" "$brief" 2>&1)" && pass 'the generated brief passes brief-lint.sh' || fail "brief-lint refused the generated brief: $lint_err"

mk_body '' "$HELD_LINE"
mk_holds 2026-11-25T08:00Z
none_rc=0
none_err="$(python3 -I "$GEN" brief --body-file "$DRIFT_BODY_FILE" --holds "$W/repo/scripts/upstreams/pin-holds.json" \
    --out "$W/bucket-none" --worktree "$W/wt" --chief HIMMEL-test-chief --worker D2 --date 2026-11-24 2>&1 >/dev/null)" || none_rc=$?
[ "$none_rc" -eq 1 ] && pass 'no actionable row exits 1' || fail "no actionable row exited $none_rc"
contains 'no actionable row says so on stderr' "$none_err" 'no actionable row'
[ ! -e "$W/bucket-none" ] && pass 'no actionable row writes no brief' || fail 'a brief file was written for no actionable row'

printf '%s\n' '{not json' > "$W/repo/scripts/upstreams/pin-holds.json"
mk_body "$ROW_TASTE" ''
export TICK_STATE_DIR="$W/state-badholds"
out6="$(bash "$SUT")"
same 'an unreadable holds file prints drift=?' "$(drift_of "$out6")" 'drift=?'
[ "$(wakes "$out6")" -eq 0 ] && pass 'an unreadable holds file never wakes' || fail "an unreadable holds file woke $(wakes "$out6") times"
count_rc=0
python3 -I "$GEN" count --body-file "$DRIFT_BODY_FILE" --holds "$W/repo/scripts/upstreams/pin-holds.json" >/dev/null 2>&1 || count_rc=$?
[ "$count_rc" -eq 2 ] && pass 'count exits 2 on an unreadable holds file' || fail "count exited $count_rc on an unreadable holds file"
printf '%s\n' '{"holds":"invalid"}' > "$W/repo/scripts/upstreams/pin-holds.json"
mk_body '' "$HELD_LINE"
shape_rc=0
python3 -I "$GEN" count --body-file "$DRIFT_BODY_FILE" --holds "$W/repo/scripts/upstreams/pin-holds.json" >/dev/null 2>&1 || shape_rc=$?
[ "$shape_rc" -eq 2 ] && pass 'count exits 2 on a holds value that is not a list' || fail "count exited $shape_rc on a holds value that is not a list"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-drift-brief.sh'
    exit 0
fi
printf 'FAIL - test-drift-brief.sh (%s failure(s))\n' "$fails"
exit 1
