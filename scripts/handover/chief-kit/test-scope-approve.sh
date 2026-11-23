#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is the pass/fail reporting shape of the sibling suites
# test-scope-approve.sh — rows of scope-approve.sh that need no build of the Jira CLI.
#
#   bash scripts/handover/chief-kit/test-scope-approve.sh
#
# The real next-dispatchable.sh judges every fixture ticket on a fixture mirror (behind a wrapper that sets its fixture
# environment and can answer exit 3 on demand). The Jira CLI is a stub: it answers `release core-check` from a fixture
# table, logs every post and renders it into the fixture mirror the way mirror.ts would, and refreshes nothing. The rows
# that need the real `release core-check` and the real ADF renderer are in scope-approve-suite.sh (CI node-suites job).
# SCOPE_APPROVE_SCRIPT overrides the script under test (the RED control: a missing script fails every row).
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
SUT="${SCOPE_APPROVE_SCRIPT:-$HERE/scope-approve.sh}"
ND="$HERE/next-dispatchable.sh"
BRIEF="$HERE/../../../docs/handover/chief-sections/scope-helper.md"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scope-approve-test.XXXXXX")" || exit 1
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" HANDOVER_DIR="$WORK/h" TICKET_STATUS_STATE_DIR="$WORK/ts-none" HIMMEL_ADMISSIONS_LEDGER="$WORK/ledger-none.jsonl"
mkdir -p "$HOME" "$HANDOVER_DIR"
unset JIRA_PROJECT_KEY HIMMEL_JIRA_MIRROR SCOPE_APPROVE_TEST SCOPE_APPROVE_JIRA_CLI SCOPE_APPROVE_ND SCOPE_APPROVE_MIRROR SCOPE_APPROVE_REPO

M="$WORK/mirror"; B="$WORK/batches"; ST="$WORK/stub"; REPO="$WORK/repo"; STATE="$WORK/state"
mkdir -p "$M" "$B" "$ST" "$STATE/workers" "$WORK/bodies" "$REPO"

mkdir -p "$REPO/scripts/lib" "$REPO/docs"
: > "$REPO/scripts/lib/a.sh"; : > "$REPO/scripts/lib/b.sh"; : > "$REPO/docs/x.md"
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m fixture
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
GN="$WORK/git-none"; mkdir -p "$GN"
git -C "$GN" init -q -b main
git -C "$GN" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m init

cat > "$ST/index.js" <<'STUB_EOF'
const fs = require('fs');
const a = process.argv.slice(2);
const st = process.env.STUB_DIR, mir = process.env.STUB_MIRROR;
const log = (s) => fs.appendFileSync(st + '/cli.log', s + '\n');
const arg = (n) => a[a.indexOf(n) + 1];
if (a[0] === 'release' && a[1] === 'core-check') {
  const key = arg('--key');
  const f = st + '/core.' + key;
  const ans = fs.existsSync(f) ? fs.readFileSync(f, 'utf8').trim() : 'NOT-CORE';
  console.log(ans === 'CORE' ? 'CORE ' + key + ' scripts/ci/core-paths.txt' : ans + ' ' + key);
} else if (a[0] === 'comment') {
  const key = a[1];
  const adf = JSON.parse(fs.readFileSync(arg('--adf-file'), 'utf8'));
  const lines = adf.content.map((p) => p.content.map((t) => t.text).join(''));
  log('POST ' + key);
  fs.writeFileSync(st + '/body.' + key, lines.join('\n') + '\n');
  const mf = st + '/mode.' + key;
  const mode = fs.existsSync(mf) ? fs.readFileSync(mf, 'utf8').trim() : (fs.existsSync(st + '/mode') ? fs.readFileSync(st + '/mode', 'utf8').trim() : 'ok');
  const render = (ls) => fs.appendFileSync(mir + '/' + key + '.md', '\n### chief — 2026-11-23T00:00:00Z\n' + ls.join('\n') + '\n');
  if (mode === 'refuse') { console.error('HTTP 400: {"errors":{"comment":"refused"}}'); process.exit(1); }
  if (mode === 'timeout') { setTimeout(() => process.exit(0), 5000); return; }
  if (mode === 'other') render([lines[0], 'Writes: scripts/lib/other.sh']);
  else if (mode !== 'nomirror') render(lines);
  if (mode === 'ok-nd3') fs.writeFileSync(st + '/nd.exit3', '');
  console.error('Comment added to ' + key);
  console.log('10001');
} else if (a[0] === 'mirror') {
  log('MIRROR');
  if (fs.existsSync(st + '/mirror-fail')) { console.error('stub: mirror refresh failed'); process.exit(1); }
} else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
STUB_EOF

cat > "$WORK/nd-wrap.sh" <<WRAP_EOF
#!/usr/bin/env bash
[ ! -e "$ST/nd.exit3" ] || { echo "UNKNOWN fixture: ND cannot judge"; exit 3; }
exec env NEXT_DISPATCH_GIT_DIR="$GN" NEXT_DISPATCH_MAIN_REF=main NEXT_DISPATCH_BODY_CACHE="$WORK/cache.json" NEXT_DISPATCH_GH_CMD="$WORK/gh" \\
    NEXT_DISPATCH_JIRA_CLI="$WORK/nd-notcore.js" NEXT_DISPATCH_DEADLINE=400 bash "$ND" --workers-dir "$STATE/workers" "\$@"
WRAP_EOF
cat > "$WORK/nd-notcore.js" <<'NC_EOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else process.exit(2);
NC_EOF
cat > "$WORK/gh" <<GH_EOF
#!/usr/bin/env bash
case "\$1 \$2" in
    'pr list') exit 0 ;;
    'pr view') cat "$WORK/bodies/\$3" 2>/dev/null; exit \$? ;;
esac
exit 1
GH_EOF
chmod +x "$WORK/nd-wrap.sh" "$WORK/gh"

CHIEF=c1
BATCH=20261123T0000-SCOPE-701
fresh() {
    rm -rf "$M" "$B" "$ST/nd.exit3" "$ST/cli.log" "$ST"/body.* "$ST"/mode "$ST"/mode.* "$ST"/core.* "$ST/mirror-fail" "$STATE/status-events.jsonl" "$WORK/bodies"
    mkdir -p "$M" "$B" "$WORK/bodies"; : > "$STATE/status-events.jsonl"
}
tkt() {
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: fixture\n\n## Description\n\n%s\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n\n## Comments\n\n_(none)_\n' \
        "$1" "$1" "${2:-Something vague that names no file.}" > "$M/$1.md"
}
row() {
    jq -cn --arg k "$1" --argjson w "$2" --argjson n "${3:-[]}" --arg a "${4:-yes}" --arg b "${5:-$BATCH}" \
        '{batch:$b,key:$k,rank:1,title:"t",excerpt:"e",writes:$w,new:$n,core:false,why:"w",approve:$a}' >> "$B/batch.jsonl"
}
sa() {
    OUT="$(SCOPE_APPROVE_TEST=1 SCOPE_APPROVE_JIRA_CLI="$ST/index.js" SCOPE_APPROVE_ND="$WORK/nd-wrap.sh" SCOPE_APPROVE_MIRROR="$M" SCOPE_APPROVE_REPO="$REPO" \
        SCOPE_APPROVE_POST_TIMEOUT=1 STUB_DIR="$ST" STUB_MIRROR="$M" bash "$SUT" "$@" 2> "$WORK/err")"; RC=$?
}
run() { sa --chief "$CHIEF" "$@" "$B/batch.jsonl"; }
posts() { if [ -f "$ST/cli.log" ]; then grep -c '^POST ' "$ST/cli.log" || true; else echo 0; fi; }  # swallow-ok: grep -c exits 1 on a count of 0, and prints it
nd_why() { bash "$WORK/nd-wrap.sh" --no-classify --mirror "$M" --why-ticket "$1" 2>&1; }
sidecar() { cat "$B/batch.jsonl.posted" 2>/dev/null || true; }
merged_none() { printf '{"event":"merge","result":"moved","key":"%s","pr":"%s","contract":"no","remainder":"none","owed":"","owed_due":"2026-11-30"}\n' "$1" "$2" >> "$STATE/status-events.jsonl"; }

fresh; tkt SCOPE-702; row SCOPE-702 '[]'
run; check 'A2 rc0' 0 "$RC"; has 'A2 an empty writes is SKIPPED empty' "$OUT" 'SKIPPED SCOPE-702 empty'
check 'A2 no post' 0 "$(posts)"; [ ! -e "$B/batch.jsonl.posted" ] && pass 'A2 no sidecar' || fail 'A2 sidecar written'
has 'A2 ND still gates no-scope' "$(nd_why SCOPE-702)" 'GATE SCOPE-702 no-scope:'

fresh; tkt SCOPE-703; row SCOPE-703 '["scripts/lib/a.sh"]' '[]' no
run; has 'A3a a row left at approve other than yes is SKIPPED' "$OUT" 'SKIPPED SCOPE-703 approve'; check 'A3a no post' 0 "$(posts)"

fresh; tkt SCOPE-704; row SCOPE-704 '["scripts/lib/a.sh"]'; : > "$ST/nd.exit3"
run; has 'A4 ND exit 3 before the post is REFUSED unknown' "$OUT" 'REFUSED SCOPE-704 unknown'; check 'A4 no post' 0 "$(posts)"

fresh; tkt SCOPE-706; row SCOPE-706 '["scripts/lib/missing.sh"]'
tkt SCOPE-707; row SCOPE-707 '["scripts/lib/../a.sh"]'
tkt SCOPE-708; row SCOPE-708 '["scripts/lib"]'
tkt SCOPE-709; row SCOPE-709 '["no code"]'
tkt SCOPE-710; row SCOPE-710 '["/scripts/lib/a.sh"]'
run
for k in 706 707 708 709 710; do has "A6 SCOPE-$k is REFUSED path" "$OUT" "REFUSED SCOPE-$k path"; done
check 'A6 no post' 0 "$(posts)"

fresh; tkt SCOPE-711 'Writes: scripts/lib/other.sh'; row SCOPE-711 '["scripts/lib/a.sh"]'; before="$(cksum < "$M/SCOPE-711.md")"
run; has 'A8 a ticket scoped since the batch is SKIPPED scoped' "$OUT" 'SKIPPED SCOPE-711 scoped'
has 'A8 the line carries ND scope source' "$OUT" 'scripts/lib/other.sh'; check 'A8 no post' 0 "$(posts)"
check 'A8 the mirror file is byte-unchanged' "$before" "$(cksum < "$M/SCOPE-711.md")"

fresh; tkt SCOPE-712 'Writes: scripts/lib/other.sh'; merged_none SCOPE-712 7012; row SCOPE-712 '["scripts/lib/a.sh"]'
has 'A18 pre-check: ND gates no-scope for the merged PR whatever the ticket scope' "$(nd_why SCOPE-712)" 'GATE SCOPE-712 no-scope: merged PR #7012 records no remainder'
before="$(cksum < "$M/SCOPE-712.md")"
run; has 'A18 a ticket that has scope and the merged-PR gate is SKIPPED scoped' "$OUT" 'SKIPPED SCOPE-712 scoped'; check 'A18 no post' 0 "$(posts)"
check 'A18 the mirror file is byte-unchanged' "$before" "$(cksum < "$M/SCOPE-712.md")"

fresh; tkt SCOPE-713; row SCOPE-713 '["scripts/lib/a.sh"]'
printf '\n### chief — 2026-11-23T00:00:00Z\nreadiness: scope-batch %s approved by %s\nWrites: scripts/lib/a.sh\n' "$BATCH" "$CHIEF" >> "$M/SCOPE-713.md"
run; has 'A9.m the marker in the mirror and no sidecar is SKIPPED posted' "$OUT" 'SKIPPED SCOPE-713 posted'; check 'A9.m no post' 0 "$(posts)"

fresh; tkt SCOPE-714; row SCOPE-714 '["scripts/lib/a.sh"]'; printf 'SCOPE-714 2026-11-22T00:00:00Z\n' > "$B/other-batch.jsonl.posted"
run; has 'A16 a key in another batch sidecar is SKIPPED posted' "$OUT" 'SKIPPED SCOPE-714 posted'; check 'A16 no post' 0 "$(posts)"

fresh; tkt SCOPE-715; tkt SCOPE-716; tkt SCOPE-717
row SCOPE-715 '["scripts/lib/a.sh"]'; row SCOPE-715 '["scripts/lib/b.sh"]'; row SCOPE-716 '["scripts/lib/a.sh"]' '[]' yes 20260101T0000-SCOPE-1; row SCOPE-717 '"scripts/lib/a.sh"'
run; check 'A12 the duplicate key is REFUSED shape twice' 2 "$(printf '%s\n' "$OUT" | grep -c '^REFUSED SCOPE-715 shape')"
has 'A12 a mixed batch id is REFUSED shape' "$OUT" 'REFUSED SCOPE-716 shape'; has 'A12 a writes that is not a list is REFUSED shape' "$OUT" 'REFUSED SCOPE-717 shape'
check 'A12 no post' 0 "$(posts)"

fresh; tkt SCOPE-718; row SCOPE-718 '["scripts/lib/a.sh"]'; printf 'CORE' > "$ST/core.SCOPE-718"
run; has 'A3 a CORE answer is REFUSED core' "$OUT" 'REFUSED SCOPE-718 core'; check 'A3 no post' 0 "$(posts)"

fresh; tkt SCOPE-719; row SCOPE-719 '["scripts/lib/a.sh"]'
run --dry-run
has 'A13 dry run prints the marker line' "$OUT" "readiness: scope-batch $BATCH approved by $CHIEF"; has 'A13 dry run prints the Writes line' "$OUT" 'Writes: scripts/lib/a.sh'
check 'A13 dry run posts nothing' 0 "$(posts)"; [ ! -e "$B/batch.jsonl.posted" ] && pass 'A13 no sidecar' || fail 'A13 sidecar written'
lacks 'A13 no mirror refresh' "$(cat "$ST/cli.log" 2>/dev/null)" 'MIRROR'

sa; check 'A14 no --chief is usage (exit 2)' 2 "$RC"
sa --chief '' "$B/batch.jsonl"; check 'A14 an empty --chief is usage (exit 2)' 2 "$RC"
sa --chief c1 "$WORK/no-such-batch"; check 'A14 an unreadable batch file is exit 2' 2 "$RC"
OUT="$(env -u SCOPE_APPROVE_TEST SCOPE_APPROVE_JIRA_CLI=/seam/x.js bash "$SUT" 2>&1)"; RC=$?
check 'A14 usage with the seam unarmed exits 2' 2 "$RC"; has 'A14 the usage line names the real CLI path' "$OUT" 'scripts/jira/dist/index.js'; lacks 'A14 an unarmed seam is ignored' "$OUT" '/seam/x.js'

fresh; tkt SCOPE-702; row SCOPE-702 '["scripts/lib/a.sh"]'
run; check 'A2.ctl one post' 1 "$(posts)"; has 'A2.ctl the sidecar holds the key' "$(sidecar)" 'SCOPE-702 '
has 'A2.ctl the body is the marker line then one Writes line' "$(cat "$ST/body.SCOPE-702")" "readiness: scope-batch $BATCH approved by $CHIEF
Writes: scripts/lib/a.sh"

fresh; tkt SCOPE-706; row SCOPE-706 '["scripts/lib/missing.sh"]' '["scripts/lib/missing.sh"]'
run; check 'A6.ctl a missing file listed in new with an existing parent posts' 1 "$(posts)"
fresh; tkt SCOPE-706; row SCOPE-706 '["scripts/nope/missing.sh"]' '["scripts/nope/missing.sh"]'
run; has 'A6.ctl2 a new file whose parent is missing is REFUSED path' "$OUT" 'REFUSED SCOPE-706 path'
fresh; tkt SCOPE-711; row SCOPE-711 '["scripts/lib/a.sh"]'
run; check 'A8.ctl the same ticket while no-scope posts' 1 "$(posts)"
fresh; tkt SCOPE-704; row SCOPE-704 '["scripts/lib/a.sh"]'
run; check 'A4.ctl ND answering posts' 1 "$(posts)"
fresh; tkt SCOPE-719; row SCOPE-719 '["scripts/lib/a.sh"]'
run; check 'A13.ctl the same batch without --dry-run posts' 1 "$(posts)"; has 'A13.ctl one sidecar line' "$(sidecar)" 'SCOPE-719 '

fresh; tkt SCOPE-720; tkt SCOPE-721; row SCOPE-720 '["scripts/lib/a.sh"]'; row SCOPE-721 '["scripts/lib/b.sh"]'; printf 'refuse' > "$ST/mode.SCOPE-720"
run; has 'A15 a refused post is FAILED post' "$OUT" 'FAILED SCOPE-720 post'; check 'A15 exit 1' 1 "$RC"
lacks 'A15 no sidecar line for the failed key' "$(sidecar)" 'SCOPE-720'; has 'A15 the next row still posts' "$(sidecar)" 'SCOPE-721 '

fresh; tkt SCOPE-722; row SCOPE-722 '["scripts/lib/a.sh"]'; printf 'timeout' > "$ST/mode.SCOPE-722"
run; has 'A17 a post that times out is UNKNOWN' "$OUT" 'UNKNOWN SCOPE-722'; check 'A17 exit 1' 1 "$RC"
has 'A17 the sidecar line is marked unconfirmed' "$(sidecar)" 'SCOPE-722 '; has 'A17 unconfirmed' "$(sidecar)" 'unconfirmed'
run; has 'A17 a re-run is SKIPPED posted' "$OUT" 'SKIPPED SCOPE-722 posted'; check 'A17 one post in the log' 1 "$(posts)"

fresh; tkt SCOPE-705; row SCOPE-705 '["scripts/lib/a.sh"]'
run; has 'A5.ctl the real ND clears: CLEARED' "$OUT" 'CLEARED SCOPE-705'; check 'A5.ctl exit 0' 0 "$RC"
has 'A5.ctl one refresh' "$(cat "$ST/cli.log")" 'MIRROR'; has 'A5.ctl the summary line' "$OUT" "scope-approve: batch $BATCH cleared=1 stays=0 unknown=0 skipped=0 refused=0 failed=0"
has 'A5.ctl ND now reads the batch paths with no no-scope gate' "$(nd_why SCOPE-705)" '# scope SCOPE-705 readiness comment'; lacks 'A5.ctl no gate' "$(nd_why SCOPE-705)" 'no-scope:'
run; has 'A9 a second run of a cleared batch is SKIPPED posted' "$OUT" 'SKIPPED SCOPE-705 posted'; check 'A9 still one post' 1 "$(posts)"

fresh; tkt SCOPE-705; row SCOPE-705 '["scripts/lib/a.sh"]'; printf 'other' > "$ST/mode"
run; has 'A5 a comment naming other files is STAYS' "$OUT" 'STAYS SCOPE-705'; check 'A5 exit 1' 1 "$RC"; lacks 'A5 never CLEARED' "$OUT" 'CLEARED'

fresh; tkt SCOPE-705; row SCOPE-705 '["scripts/lib/a.sh"]'; printf 'ok-nd3' > "$ST/mode"
run; has 'A5.u ND exit 3 after the post is UNKNOWN' "$OUT" 'UNKNOWN SCOPE-705'; check 'A5.u exit 1' 1 "$RC"; lacks 'A5.u never CLEARED' "$OUT" 'CLEARED'

fresh; tkt SCOPE-707; row SCOPE-707 '["scripts/lib/a.sh"]'; printf 'nomirror' > "$ST/mode"
run; has 'A7 a post the mirror lacks is UNKNOWN (not in mirror yet)' "$OUT" 'UNKNOWN SCOPE-707 (not in mirror yet)'; check 'A7 exit 1' 1 "$RC"
run; has 'A7 a re-run is SKIPPED posted' "$OUT" 'SKIPPED SCOPE-707 posted'; check 'A7 one post in the log' 1 "$(posts)"
printf '\n### chief — 2026-11-23T00:00:00Z\nreadiness: scope-batch %s approved by %s\nWrites: scripts/lib/a.sh\n' "$BATCH" "$CHIEF" >> "$M/SCOPE-707.md"
sa --verify --chief "$CHIEF" "$B/batch.jsonl"; has 'A7 --verify after the mirror catches up prints CLEARED' "$OUT" 'CLEARED SCOPE-707'; check 'A7 --verify exit 0' 0 "$RC"; check 'A7 --verify posts nothing' 1 "$(posts)"

fresh; tkt SCOPE-723; row SCOPE-723 '["scripts/lib/a.sh"]'; : > "$ST/mirror-fail"
run; has 'A19 a failed refresh makes every posted key UNKNOWN' "$OUT" 'UNKNOWN SCOPE-723'; check 'A19 exit 1' 1 "$RC"

fresh; tkt SCOPE-724; merged_none SCOPE-724 7024; row SCOPE-724 '["scripts/lib/a.sh"]'
has 'A11 pre-check: ND gates no-scope for the merged PR' "$(nd_why SCOPE-724)" 'GATE SCOPE-724 no-scope: merged PR #7024 records no remainder'
run; check 'A11 posted' 1 "$(posts)"; has 'A11 a still-gated partial-merge ticket is STAYS' "$OUT" 'STAYS SCOPE-724'; check 'A11 exit 1' 1 "$RC"

usage_line='scope-approve.sh [--dry-run | --verify] --chief <session> <batch-file>'
usage_err="$(env -u SCOPE_APPROVE_TEST bash "$SUT" 2>&1 >/dev/null)"
has 'D-brief the script prints the usage line the brief quotes' "$usage_err" "$usage_line"
if [ -r "$BRIEF" ]; then
    for needle in '--dry-run' '--verify' '--chief <session>' 'a Bug reads BYPASS only when a core path is proposed' 'files, never directories' 'prose limit'; do
        check "D-brief names '$needle'" 1 "$([ "$(grep -cF -- "$needle" "$BRIEF")" -ge 1 ] && echo 1 || echo 0)"
    done
else
    fail "D-brief the helper brief is absent: $BRIEF"
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-scope-approve.sh"; exit 0; fi
echo "FAIL - test-scope-approve.sh ($fails failure(s))"; exit 1
