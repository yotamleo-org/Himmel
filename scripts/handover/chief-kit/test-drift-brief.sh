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
drift_tok="$(tr '`' '\n' < "$brief" | grep '^D-D1-' | head -n 1)"
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

gold_primary="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)"
gold_primary="${gold_primary%/.git}"
plain="$(python3 -I "$GEN" brief --body-file "$DRIFT_BODY_FILE" --holds "$W/repo/scripts/upstreams/pin-holds.json" \
    --out "$W/bucket-b4" --worktree /wt --chief HIMMEL-test-chief --worker D1 --date 2026-11-24 | tail -n 1)"
plain_diff="$(sed -E -e 's/D-D1-[0-9a-f]{8}/D-D1-TOKEN/g' -e "s#$gold_primary#__PRIMARY__#g" \
    -e 's# -R [A-Za-z0-9._-]+/[A-Za-z0-9._-]+##g' "$plain" | diff "$HERE/fixtures/drift-brief-plain.golden" - 2>&1)"
same 'B4: a plain drift brief equals the golden' "$plain_diff" ''

ROW_STATION='| cli-proxy-api | carried tool | 8.1.0 | v8.1.7 | station tool: VM-first upgrade |'
mk_pr() {
    local n="$1" t="$2" b="$3"
    shift 3
    jq -n --argjson n "$n" --arg t "$t" --arg b "$b" '{number: $n, title: $t, headRefName: "dependabot/x/p\($n)", body: $b, files: [$ARGS.positional[] | {path: .}]}' --args "$@"
}
prs_file() { jq -s '.' > "$W/prs.json"; }
comb_n=0
comb() {
    local list="$1"
    shift
    comb_n=$((comb_n + 1))
    comb_dir="$W/comb-$comb_n"
    comb_rc=0
    comb_brief="$(python3 -I "$GEN" brief --body-file "$DRIFT_BODY_FILE" --holds "$W/repo/scripts/upstreams/pin-holds.json" \
        --out "$comb_dir" --worktree "$W/wt" --chief HIMMEL-test-chief --worker D1 --date 2026-11-24 \
        --dependabot-prs "$list" --prs-file "$W/prs.json" "$@" 2> "$W/comb.err" | tail -n 1)" || comb_rc=$?
    comb_err="$(cat "$W/comb.err")"
    comb_text="$(cat "$comb_brief" 2>/dev/null)"
}
line_of() { printf '%s\n' "$comb_text" | grep -F -- "$1" | head -n 1; }
block_of() { printf '%s\n' "$comb_text" | awk -v h="$1" 'index($0, h) == 1 { on = 1; next } on && ($0 !~ /^> - /) { exit } on'; }
writes_of() { line_of '> **Writes:**'; }

mkdir -p "$W/lint-mirror" "$W/lint-stub"
printf '{"lastSync":"2026-11-01T00:00:00Z"}\n' > "$W/lint-mirror/.cursor.json"
printf -- '---\nkey: "HIMMEL-1"\nstatus: "To Do"\ntype: "Task"\npriority: "Medium"\nlabels: []\n---\n# HIMMEL-1: t\n' > "$W/lint-mirror/HIMMEL-1.md"
cat > "$W/lint-stub/index.js" <<'STUBEOF'
const fs = require('fs');
const a = process.argv.slice(2);
if (process.env.LINT_STUB_LOG) fs.appendFileSync(process.env.LINT_STUB_LOG, a.join(' ') + '\n');
if (a[0] === 'release' && a[1] === 'core-check') {
  const hit = a[a.indexOf('--paths') + 1].split(',').find((p) => p.startsWith('marketplace/plugins/himmel-bus/'));
  for (const k of a.slice(a.indexOf('--key') + 1)) console.log(hit ? 'CORE ' + k + ' ' + hit : 'NOT-CORE ' + k);
} else if (a[0] === 'release' && a[1] === 'spec-check') {
  for (const k of a.slice(a.indexOf('--mirror') + 2)) console.log('NO-SPEC ' + k);
  process.exit(1);
} else if (a[0] === 'release' && a[1] === 'bucket-check') {
  for (const k of a.slice(a.indexOf('--mirror') + 2)) console.log('IN ' + k + ' current=v1.1.3 via=mirror');
} else process.exit(2);
STUBEOF
keyed_lint() { LINT_STUB_LOG="$W/lint.log" BRIEF_LINT_MIRROR="$W/lint-mirror" BRIEF_LINT_JIRA_CLI="$W/lint-stub/index.js" bash "$LINT" "$1" 2>&1; }

TRIAGE=marketplace/plugins/obsidian-triage/tools/requirements.txt
{
    mk_pr 11 'chore(deps): [HIMMEL-7588]: Bump pyyaml from 6.0.3 to 6.0.4' '' "$TRIAGE"
    mk_pr 12 'Bump certifi from 1.0 to 1.1' '' marketplace/plugins/obsidian-triage/tools/requirements-scrapling.txt
    mk_pr 13 'Bump av from 1.0 to 1.1' '' marketplace/plugins/obsidian-triage/tools/requirements-whisper.txt
} | prs_file
mk_holds 2026-11-25T08:00Z
mk_body "$ROW_TASTE
$ROW_STATION" ''
comb '#11,#12' --key HIMMEL-1
same 'B1: a combined brief is written' "$comb_rc" '0'
case "$comb_brief" in */HIMMEL-1-D1-dependabot-drift-4470-2026-11-24.md) pass 'B1: the doc stem names the combined drift leg' ;; *) fail "B1: stem '$comb_brief' ($comb_err)" ;; esac
same 'B1: the Dependabot block lists the given PRs only' "$(block_of '> **Dependabot PRs:**' | grep -oE '^> - #[0-9]+' | tr -d '> -' | paste -sd, -)" '#11,#12'
contains 'B1: a PR line carries its title and head' "$comb_text" '> - #12 Bump certifi from 1.0 to 1.1 (dependabot/x/p12)'
contains 'B1: the station row is in its own block' "$(block_of '> **Station tools (VM-first, listed apart):**')" 'cli-proxy-api'
same 'B1: the station row appears once' "$(printf '%s\n' "$comb_text" | grep -c '^> - cli-proxy-api')" '1'
same 'B1: the description counts PRs and rows' "$(line_of 'description:')" 'description: "Land the 2 open Dependabot bumps and the 2 actionable fork-drift rows of the open drift issue (2026-11-24) in one bump PR; completes-ticket: no"'
KP=HIMMEL
contains 'B1: the title names both' "$(line_of "# $KP-1 ")" "# $KP-1 - the open Dependabot bumps and the actionable 4470 drift rows land together - "
# shellcheck disable=SC2016  # literal backticks from the brief
contains 'B1: the commit subject names both' "$comb_text" 'commit `chore(deps): [HIMMEL-1] the open Dependabot bumps and the actionable 4470 drift rows land together`'
rm -f "$W/lint.log"
lint_err="$(keyed_lint "$comb_brief")" && pass 'B1: the keyed combined brief passes brief-lint.sh' || fail "B1: brief-lint refused: $lint_err"
contains 'B1: the lint reached its core gate' "$(cat "$W/lint.log" 2>/dev/null)" 'release core-check'

mk_body '' ''
comb '#11'
same 'B2: PRs with no drift row write a brief' "$comb_rc:$([ -f "$comb_brief" ] && echo written)" '0:written'
comb ''
same 'B2: no PR and no row exits 1' "$comb_rc" '1'
contains 'B2: and says no actionable row' "$comb_err" 'no actionable row'
comb '#99'
same 'B2: a PR that is not in the file exits 2' "$comb_rc" '2'
contains 'B2: and names the PR' "$comb_err" 'drift-brief: PR #99 is not open'
for alone in '--dependabot-prs #11' "--prs-file $W/prs.json"; do
    alone_rc=0
    # shellcheck disable=SC2086  # one flag and its value, split on purpose
    alone_err="$(python3 -I "$GEN" brief --body-file "$DRIFT_BODY_FILE" --holds "$W/repo/scripts/upstreams/pin-holds.json" \
        --out "$W/comb-alone" --worktree "$W/wt" --chief HIMMEL-test-chief --worker D1 --date 2026-11-24 $alone 2>&1 >/dev/null)" || alone_rc=$?
    same "B2: ${alone%% *} alone exits 2" "$alone_rc" '2'
    contains "B2: ${alone%% *} alone prints the usage line" "$alone_err" 'usage:'
done

CI_REQ=.github/ci-image/requirements.txt
X_REQ=marketplace/plugins/x/tools/requirements.txt
mk_pr 21 'Bump a from 1 to 2' '' "$CI_REQ" "$X_REQ" | prs_file
mk_body "$ROW_TASTE" ''
comb '#21'
for want in "$CI_REQ" "$X_REQ" .github/workflows/ci.yml scripts/ci/release-age-allow.txt; do
    contains "B3: Writes carry $want" "$(writes_of) " " $want "
done
contains 'B3: the trust sentence names the trust paths' "$(line_of 'trust-reviewed GO')" "$CI_REQ, .github/workflows/ci.yml, scripts/ci/release-age-allow.txt"
contains 'B3: hashes are regenerated' "$comb_text" 'gets its hashes regenerated'
contains 'B3: a young security release gets an allow line' "$comb_text" 'line naming the advisory'
contains 'B3: a landed PR is closed as superseded' "$comb_text" '--comment "Superseded by #'
contains 'B3: a deferred PR is closed as deferred' "$comb_text" '--comment "Deferred: <reason>, tracked in <KEY>"'
contains 'B3: the deferral ticket is High or above' "$comb_text" 'High or above'
mk_pr 22 'Bump a from 1 to 2' '' "$X_REQ" | prs_file
comb '#22'
case " $(writes_of) " in *' .github/workflows/ci.yml '*) fail 'B3: ci.yml is in Writes with no ci-image file' ;; *' '"$X_REQ"' '*) pass 'B3: no ci-image file, no ci.yml in Writes' ;; *) fail "B3: no Writes line ($comb_err)" ;; esac
mk_pr 23 'Bump a/b from 1 to 2' '' .github/workflows/x.yml | prs_file
comb '#23'
contains 'B3: an actions workflow file is in Writes' "$(writes_of) " ' .github/workflows/x.yml '
# shellcheck disable=SC2016  # literal backticks from the brief
contains 'B3: the Writes note still forbids other workflow files' "$(line_of '> **Writes note:**')" 'every `.github/workflows/` file except `ci.yml` and the Dependabot PRs'\'' own files'

BUS=marketplace/plugins/himmel-bus/package.json
{ mk_pr 31 'Bump zod from 4 to 5' '' "$BUS"; mk_pr 32 'Bump a from 1 to 2' '' "$X_REQ"; } | prs_file
comb '#31,#32' --key HIMMEL-1
same 'B5: the core-path PR is left out of the Dependabot block' "$(block_of '> **Dependabot PRs:**' | grep -oE '^> - #[0-9]+' | tr -d '> -' | paste -sd, -)" '#32'
case "$(writes_of)" in *himmel-bus*) fail 'B5: a core path is in Writes' ;; *"$X_REQ"*) pass 'B5: no core path in Writes' ;; *) fail "B5: no Writes line ($comb_err)" ;; esac
not_contains 'B5: no close line for it' "$comb_text" 'gh pr close 31'
contains 'B5: stderr names the core path' "$comb_err" "drift-brief: PR #31 touches core path $BUS: route it apart"
contains 'B5: the NOT-in-scope line names it' "$(line_of '> NOT in scope:')" '#31'
lint_err="$(keyed_lint "$comb_brief")" && pass 'B5: the brief without it passes brief-lint.sh' || fail "B5: brief-lint refused: $lint_err"
sed "s#^> \*\*Writes:\*\* #&$BUS #" "$comb_brief" > "$comb_dir/with-core.md"
keyed_lint "$comb_dir/with-core.md" > /dev/null && fail 'B5: the core path put back into Writes was accepted' || pass 'B5: the core path put back into Writes is refused'
mk_body '' ''
comb '#31'
same 'B5: only a core-path PR and no row exits 1' "$comb_rc" '1'

ROW_FOO='| npm:foo | npm package | 1.0 | 1.3 | bump scripts/jira, site to 1.3 plus synced_base in scripts/upstreams.json |'
ROW_BAR='| pypi:bar | pypi package | 1.0 | 1.3 | bump site to 1.3 plus synced_base in scripts/upstreams.json |'
printf '{"holds": [{"eco": "npm", "key": "foo", "current": "1.0", "latest_reviewed": "1.3", "reason": "buffer", "eligible": "2026-11-25T08:00Z"}]}\n' > "$W/repo/scripts/upstreams/pin-holds.json"
mk_body "$ROW_FOO" ''
# shellcheck disable=SC2016  # literal backticks from Dependabot's group body
mk_pr 41 'Bump the npm group with 2 updates' 'Updates `foo` from 1.0 to 1.2' site/package.json site/package-lock.json | prs_file
comb '#41'
contains 'B6: a partly carried row narrows to the uncovered directory' "$comb_text" '> - npm:foo (npm package): 1.0 to 1.3 - bump scripts/jira to 1.3 '
contains 'B6: the NOT-in-scope line names the carried directory' "$(line_of '> NOT in scope:')" '#41 carries site'
# shellcheck disable=SC2016  # literal backticks from Dependabot's group body
mk_pr 42 'Bump the npm group with 2 updates' 'Updates `foo` from 1.0 to 1.2' site/package.json scripts/jira/package.json | prs_file
comb '#42'
not_contains 'B6: a fully carried row is dropped' "$comb_text" '> - npm:foo '
contains 'B6: the NOT-in-scope line says who carries it' "$(line_of '> NOT in scope:')" 'npm:foo carried by #42'
mk_body "$ROW_BAR" ''
mk_pr 43 'Bump bar from 1.0 to 1.2' '' site/requirements.txt | prs_file
comb '#43'
contains 'B6: a pypi row matches a title' "$(line_of '> NOT in scope:')" 'pypi:bar carried by #43'
mk_holds 2026-11-24T08:00Z
mk_body '' '  npm:oxlint 1.93.0 (site): HELD     (latest 1.94.0 reviewed and held back: 72 h buffer)'
mk_pr 44 'Bump oxlint from 1.93.0 to 1.94.0' '' site/package.json | prs_file
comb '#44'
contains 'B6: a buffer-cleared hold row a PR carries is dropped' "$(line_of '> NOT in scope:')" 'oxlint carried by #44'

: > "$DRIFT_BODY_FILE"
mk_pr 51 'Bump a from 1 to 2' '' "$X_REQ" | prs_file
comb '#51'
same 'B7: an empty issue body writes a PRs-only brief' "$comb_rc:$(block_of '> **Dependabot PRs:**' | grep -c '^> - #51 ')" '0:1'

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
