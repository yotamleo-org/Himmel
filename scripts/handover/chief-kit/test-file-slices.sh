#!/usr/bin/env bash
# Every row passes --jira-cli with a stub node file in this suite's temporary directory: the script never
# writes live Jira here. The stub logs each argv as one JSON line and answers from fixture files beside it.
# Its answers copy real output:
#   list   the live `list --jql "issue in linkedIssues(<given-scopes parent>)" --limit 100` rows (key, type, status, title)
#   get    the live `get` of that parent: its header line and its Labels/Priority/Fix versions/Sector lines
#   release spec-check  the live `SPEC ok <key> <spec path> <O-id>` line of that parent (exit 0) and `NO-SPEC <key>` (exit 1);
#          the real verb exits 1 for any line but SPEC ok (scripts/jira/src/commands/release.ts, spec-check)
#   the unbound warning, printed by spec-check on stderr as `WARN ` + scripts/jira/src/release/spec-sign.ts's text:
#          `${k} plan unbound: the record ${r.id} signed plan ${r.plan_path} without its hash; re-sign with --supersedes ${r.id} to bind it`
#   create, as scripts/jira/src/operations/create.ts prints it: success `Created ${key}` on stdout, exit 0;
#          `jira: PARTIAL: Created ${key} but ${step} failed: ${message}; still owed: ${pending}. The ticket exists: finish these by hand, do not re-run create.`
#          and `jira: OUTCOME UNKNOWN: the create request failed after it was sent (${msg}); the ticket may exist. Search for "${summary}" before filing again; create is not retried.`
#          on stderr with exit 1 (scripts/jira/src/index.ts prints a thrown message with console.error, exit 1);
#          a blocked-by step reads `linking ${by} to ${key}`.
# shellcheck disable=SC2016 # the backticks in fixture text are markdown code spans, never expansions
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/file-slices.sh"
REPO="$(cd "$HERE/../../.." && pwd)"
POLICY="$REPO/marketplace/plugins/himmel-ops/scripts/ticket-policy-cli.mjs"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/file-slices-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
SPEC_PATH="$WORK/bucket/specs/designs/HIMMEL-10314-given-scopes.md"
P=HIMMEL-10314

cat > "$WORK/stub.cjs" <<'JS'
const fs = require('fs');
const path = require('path');
const d = __dirname;
const a = process.argv.slice(2);
const at = (f) => path.join(d, f);
const rd = (f, dflt) => { try { return fs.readFileSync(at(f), 'utf8'); } catch { return dflt; } };
fs.appendFileSync(at('argv.log'), JSON.stringify(a) + '\n');
const bump = (f) => { const n = Number(rd(f, '0')) + 1; fs.writeFileSync(at(f), String(n)); return n; };
const failMode = (f, n) => { const m = rd(f, '').trim().split(/\s+/); return m[0] && Number(m[0]) === n ? (m[1] || 'exit') : ''; };
switch (a[0]) {
  case 'list': process.stdout.write(rd('list.txt', '')); break;
  case 'get': process.stdout.write(rd('get.txt', '')); break;
  case 'release':
    process.stdout.write(rd('spec.out', ''));
    process.stderr.write(rd('spec.err', ''));
    process.exit(Number(rd('spec.rc', '0').trim()));
    break;
  case 'create': {
    const n = bump('create.count');
    const key = `HIMMEL-${9000 + n}`;
    const title = a[a.indexOf('--title') + 1];
    const mode = failMode('create.fail', n);
    if (mode === 'exit') { process.stderr.write('jira: version v9 is closed; pick an open version\n'); process.exit(1); }
    if (mode === 'partial') {
      process.stderr.write(`jira: PARTIAL: Created ${key} but linking HIMMEL-9001 to ${key} failed: HTTP 500 Internal Server Error; still owed: linking HIMMEL-9001 to ${key}. The ticket exists: finish these by hand, do not re-run create.\n`);
      process.exit(1);
    }
    if (mode === 'unknown') {
      process.stderr.write(`jira: OUTCOME UNKNOWN: the create request failed after it was sent (socket hang up); the ticket may exist. Search for "${title}" before filing again; create is not retried.\n`);
      process.exit(1);
    }
    if (rd('stateful', '')) fs.appendFileSync(at('list.txt'), `${key}\tTask\tTo Do\t${title}\n`);
    console.log(`Created ${key}`);
    break;
  }
  case 'link': {
    const n = bump('link.count');
    if (failMode('link.fail', n)) { process.stderr.write('HTTP 500 Internal Server Error\n'); process.exit(1); }
    console.log(`Linked ${a[1]}`);
    break;
  }
  default: process.exit(9);
}
JS

LIVE_LIST="$(printf '%s\n' \
    'HIMMEL-11373	Task	To Do	Safety & enforcement: adopt keeps its plugin floor and tracked files clean' \
    'HIMMEL-10671	Task	To Do	Safety & enforcement: installers stop writing user scope, closing proof on a fresh VM (S7)' \
    'HIMMEL-10670	Task	To Do	Safety & enforcement: launch-guard and its readers use the given-scopes list (S6)' \
    'HIMMEL-10663	Task	Done	Safety & enforcement: the adopted guard chain is checked by launch-guard (S2a)' \
    'HIMMEL-10629	Task	To Do	Knowledge & steering: the given-scopes design reads in half the length' \
    'HIMMEL-10319	Task	wont do	Retire the manual machine-wide guardrail install and the launch guard'"'"'s user layer')"
LIVE_GET_HEAD='HIMMEL-10314	Story	To Do	Safety & enforcement: himmel protects only the projects a user names, and shows that list'
LIVE_GET_META="$(printf '%s\n' 'Labels: operator-directed, phase:sliced, residual, standalone' 'Priority: Medium' 'Fix versions: v1.1.3' 'Sector: Safety & enforcement')"

row() {
    R="$WORK/$1"
    mkdir -p "$R"
    cp "$WORK/stub.cjs" "$R/stub.cjs"
    printf '%s\n' "$LIVE_LIST" > "$R/list.txt"
    printf '%s\n\nImpact\nThe parent body.\n%s\n' "$LIVE_GET_HEAD" "$LIVE_GET_META" > "$R/get.txt"
    printf 'SPEC ok %s %s O-v1.1.3-1243\n' "$P" "$SPEC_PATH" > "$R/spec.out"
    printf '0\n' > "$R/spec.rc"
    : > "$R/argv.log"
}
epic() { printf 'HIMMEL-10314\tEpic\tTo Do\tSafety & enforcement: given scopes\n\nSector: Safety & enforcement\n' > "$R/get.txt"; }
filed() { printf '%s\tTask\tTo Do\tSafety & enforcement: %s (%s)\n' "$1" "$3" "$2" >> "$R/list.txt"; }
writes() { grep -cE '^\["(create|link|edit|transition)"' "$R/argv.log" 2>/dev/null; }
calls() { grep -cE "^\[\"$1\"" "$R/argv.log" 2>/dev/null; }
nth() { grep -E "^\[\"$1\"" "$R/argv.log" 2>/dev/null | sed -n "$2p"; }
run() { OUT="$(bash "$SUT" "$@" --jira-cli "$R/stub.cjs" 2>&1)"; RC=$?; }
body() { printf '%s\n' "$OUT" | awk -v id="$1" '$0 == "--- body " id " ---" {on=1; next} $0 == "--- end " id " ---" {on=0} on'; }

header() {
    printf -- '---\ntickets: HIMMEL-10314\n'
    [ "$2" = 1 ] && printf 'revision: r1\n'
    printf -- '---\n\n# Fixture plan\n\n**Spec:** `specs/designs/HIMMEL-10314-given-scopes.md` r17 (same bucket).\n\n'
    [ "$1" = 1 ] && printf '**Goal:** himmel loads only in the projects on its list; nothing himmel-owned stays at user scope\nexcept the spec'"'"'s user-kept rows.\n\n'
    return 0
}
slice() {
    printf '## %s: %s\n\nDepends on: %s\n\nWrites:\n- `%s` (the change)\n\nRED: `%s`: it fails today, before the change.\n\nDone:\n- the RED passes;\n- %s holds after the change.\n\n' \
        "$1" "$2" "$3" "$4" "$5" "$1"
}
base() {
    header 1 1
    slice S1 'the list' 'none.' 'scripts/himmelctl/lib/state.js' 'test-himmelctl-projects.sh'
    slice S2 'the adopted chain' 'S1.' 'scripts/lib/launch-guard-p.mjs' 'test-launch-guard-p-adopted.sh'
    slice S3 'the shared file strips' 'S1, S2. HIMMEL-1 lands in this same PR.' 'scripts/adopt.sh' 'test-adopt-shared-file-clean.sh'
}
F="$WORK/plans"; mkdir -p "$F" "$(dirname "$SPEC_PATH")"
base > "$F/base.md"
edit() {
    awk -v id="$3" -v pre="$4" -v rep="$5" '
        /^## / { cur = $2; sub(/:$/, "", cur) }
        cur == id && index($0, pre) == 1 { if (rep != "DELETE") print rep; next }
        { print }' "$1" > "$2"
}
edit "$F/base.md" "$F/no-red.md" S2 'RED:' DELETE
edit "$F/base.md" "$F/red-no-token.md" S2 'RED:' 'RED: the adopted chain test fails today.'
edit "$F/base.md" "$F/no-dep.md" S2 'Depends on:' DELETE
edit "$F/base.md" "$WORK/t.md" S2 '- the RED passes' DELETE; edit "$WORK/t.md" "$F/no-done.md" S2 '- S2 holds' DELETE
edit "$F/base.md" "$F/dep-s9.md" S3 'Depends on:' 'Depends on: S1, S9.'
edit "$F/base.md" "$F/cycle.md" S1 'Depends on:' 'Depends on: S3.'
edit "$F/base.md" "$WORK/t.md" S2 '- the RED passes' '- TBD'; edit "$WORK/t.md" "$F/tbd-done.md" S2 '- S2 holds' DELETE
edit "$F/base.md" "$F/tbd-dep.md" S2 'Depends on:' 'Depends on: TBD.'
{ edit "$F/base.md" /dev/stdout S3 'Depends on:' 'Depends on: M1.'; printf '## M1: the station run\n\nOperator station run, no ticket.\n'; } > "$F/dep-m1.md"
{ cat "$F/base.md"; slice S4 'the readers' 'S3.' 'scripts/lib/readers.sh' 'test-readers.sh'; } > "$F/four.md"
edit "$F/four.md" "$F/four-no-red.md" S4 'RED:' DELETE
{ header 1 1
  slice S3 'the shared file strips' 'S1, S2.' 'scripts/adopt.sh' 'test-adopt-shared-file-clean.sh'
  slice S2 'the adopted chain' 'S1.' 'scripts/lib/launch-guard-p.mjs' 'test-launch-guard-p-adopted.sh'
  slice S1 'the list' 'none.' 'scripts/himmelctl/lib/state.js' 'test-himmelctl-projects.sh'; } > "$F/reversed.md"
{ cat "$F/base.md"; slice S2 'the adopted chain again' 'S1.' 'scripts/lib/other.sh' 'test-other.sh'; } > "$F/dup-id.md"
sed 's/^## S\([0-9]\): /## Slice \1 — /' "$F/base.md" > "$F/slice-form.md"
{ header 0 1; base | sed '1,/^## S1:/{/^## S1:/!d;}'; } > "$F/no-goal.md"
{ header 1 0; base | sed '1,/^## S1:/{/^## S1:/!d;}'; } > "$F/no-revision.md"
edit "$F/base.md" "$F/wrapped.md" S3 'Depends on:' 'Depends on: S1,'
awk '{print} /^Depends on: S1,$/ {print "S2 (and S3b if it exists)."; print ". Lands with HIMMEL-1."}' "$F/wrapped.md" > "$F/wrapped2.md"
mv "$F/wrapped2.md" "$F/wrapped.md"
{ header 1 1
  slice S1 'the list' 'none.' 'scripts/himmelctl/lib/state.js' 'test-himmelctl-projects.sh'
  printf '%s\n' '## S2: the adopted chain' '' 'Depends on: S1.' '' 'Writes:' \
    '- `scripts/lib/test-launch-guard-p-adopted.sh`, `scripts/lib/test-hook-set-list.sh`, `scripts/lib/test-unwire-pretooluse-hooks.sh` (new and extended;' \
    '  one bullet, three paths)' \
    '- the A23 ceiling row, recorded with `scripts/ledger/ceiling-add.sh` when the slice merges' \
    '- the readers found by step 1' \
    '- `mcpServers.graphify`' \
    '- `adopt.sh`' \
    '- `~/.claude.json`' \
    '' 'RED: `test-launch-guard-p-adopted.sh`: adopted mode passes.' '' 'Done:' '- the RED passes.' ''
  printf '%s\n' '## S3: the station items' '' 'Depends on: S2.' '' 'Writes:' '- the readers found by step 1' '- `adopt.sh`' '' \
    'RED: `test-station-items.sh`: the items move.' '' 'Done:' '- the RED passes.' ''; } > "$F/writes-shapes.md"
{ header 1 1
  slice S1 'the list' 'none.' 'scripts/himmelctl/lib/state.js' 'test-himmelctl-projects.sh'
  printf '%s\n' '## S2: the adopted chain' '' 'Interfaces:' '' '```text' 'Depends on: S9.' 'Writes:' '- `scripts/lib/fenced-example.sh`' \
    'RED: `test-fenced.sh`' '```' '' 'Depends on: S1.' '' 'Writes:' '- `scripts/lib/launch-guard-p.mjs` (adopted mode)' '' \
    'RED: `test-launch-guard-p-adopted.sh`: adopted mode passes.' '' 'Done:' '- the RED passes, printing:' '  ```text' '  ok' '  ```' \
    '- the second result holds.' ''
  printf '%s\n' '## S3: the strips' '' 'Depends on: S2' '```text' 'example' '```' 'HIMMEL-6 is named after the fence.' '' 'Writes:' '- `scripts/adopt.sh` (strips)' \
    '```text' 'example' '```' '- `scripts/lib/not-this-slice.sh`' '' 'RED: `test-adopt-shared-file-clean.sh`: clean.' '' 'Done:' '- the RED passes.' ''; } > "$F/fenced.md"

row r1; run "$F/base.md" --parent "$P"
check "R1 the dry run exits 0" 0 "$RC"
has "R1 S1 is NEW with its title" "$OUT" 'NEW S1 "Safety & enforcement: the list (S1)"'
has "R1 S2 is NEW" "$OUT" 'NEW S2 '
has "R1 S3 is NEW" "$OUT" 'NEW S3 '
has "R1 counts sum to the sections" "$OUT" '# counts: sections=3 skip=0 filed=0 new=3 refused=0'
check "R1 the stub log has no write verb (I1)" 0 "$(writes)"
for id in S1 S2 S3; do if [ -n "$(body $id)" ]; then pass "R1 a body follows $id"; else fail "R1 no body for $id"; fi; done
lacks "R1 S3's trailing sentence never becomes an edge (I4)" "$(body S3)" 'HIMMEL-1 '
has "R1 S3's Edges line names both slice dependencies" "$(body S3)" 'Edges: S1 (not filed yet) blocks S3 (hard); S2 (not filed yet) blocks S3 (hard)'
has "R1 the header names the parent, its type and Sector, and the spec-check line" "$OUT" "parent $P (Story, Sector \"Safety & enforcement\") signed: SPEC ok $P"

row r1b; filed HIMMEL-77 S2 'the adopted chain'; run "$F/four-no-red.md" --parent "$P" --skip S1
check "R1b a REFUSED row exits 1" 1 "$RC"
rows="$(printf '%s\n' "$OUT" | grep -E '^(SKIP|FILED|NEW|REFUSED) ' | cut -d' ' -f1-2 | tr -d : | tr '\n' ' ')"
check "R1b rows in plan order" "SKIP S1 FILED S2 NEW S3 REFUSED S4 " "$rows"
has "R1b FILED names the listed key" "$OUT" 'FILED S2 HIMMEL-77'
has "R1b counts" "$OUT" '# counts: sections=4 skip=1 filed=1 new=1 refused=1'
check "R1b no body after the SKIP row (spec:F5)" "" "$(body S1)"
if [ -n "$(body S2)" ]; then pass "R1b a body after the FILED row"; else fail "R1b no body after the FILED row"; fi
if [ -n "$(body S3)" ]; then pass "R1b a body after the NEW row"; else fail "R1b no body after the NEW row"; fi
has "R1b a dependency on a skipped id links nothing and is noted" "$(body S3)" 'S1 is skipped'
has "R1b a dependency on a FILED id resolves to its key" "$(body S3)" 'HIMMEL-77 blocks S3 (hard)'

row r2; run "$F/no-red.md" --parent "$P"
check "R2 no RED line exits 1" 1 "$RC"; has "R2 names the missing RED line (I3)" "$OUT" 'REFUSED S2: no RED: line'
row r2b; run "$F/base.md" --parent "$P"; check "R2b control: RED restored exits 0" 0 "$RC"
row r2c; run "$F/no-dep.md" --parent "$P"
check "R2c no Depends on line exits 1" 1 "$RC"; has "R2c names it" "$OUT" 'REFUSED S2: no Depends on: line'
row r2d; run "$F/no-done.md" --parent "$P"
check "R2d a Done line with no bullet exits 1" 1 "$RC"; has "R2d names it" "$OUT" 'REFUSED S2: no Done: bullet'
row r2e; run "$F/red-no-token.md" --parent "$P"
check "R2e a RED line with no backticked token exits 1 (plan:P15)" 1 "$RC"; has "R2e names it" "$OUT" 'REFUSED S2: RED: line names no test'

row r3; run "$F/dep-s9.md" --parent "$P"
check "R3 an unknown dependency exits 1" 1 "$RC"; has "R3 names it (I4)" "$OUT" 'REFUSED S3: Depends on names S9, which is no heading'

row r4; run "$F/no-red.md" --parent "$P" --apply
check "R4 --apply on a refused section exits 1" 1 "$RC"; check "R4 no write verb (I5)" 0 "$(writes)"
row r4b; run "$F/cycle.md" --parent "$P" --apply
check "R4b a cycle exits 1" 1 "$RC"; has "R4b names the cycle" "$OUT" 'REFUSED: cycle'; check "R4b no write verb" 0 "$(writes)"

row r5; filed HIMMEL-77 S2 'the adopted chain'; run "$F/base.md" --parent "$P" --apply
check "R5 --apply exits 0" 0 "$RC"; has "R5 S2 is FILED" "$OUT" 'FILED S2 HIMMEL-77'
check "R5 creates S1 and S3 only (I6)" 2 "$(calls create)"
has "R5 the first create is S1" "$(nth create 1)" '(S1)"'
has "R5 the second create is S3" "$(nth create 2)" '(S3)"'
has "R5 S3's link names the FILED key" "$(nth link 1)" '"link","HIMMEL-9002","--blocked-by","HIMMEL-77"'
has "R5 the search reads the parent's linked issues with --limit 500" "$(nth list 1)" "\"list\",\"--jql\",\"issue in linkedIssues($P)\",\"--limit\",\"500\""
row r5b; filed HIMMEL-77 S2 'the adopted chain'; filed HIMMEL-78 S2 'the adopted chain, by hand'; run "$F/base.md" --parent "$P"
check "R5b two matches exit 1" 1 "$RC"; has "R5b names the duplicate match" "$OUT" 'REFUSED: S2 matches HIMMEL-77 and HIMMEL-78'

row r6; run "$F/base.md" --parent "$P" --apply
check "R6 --apply exits 0" 0 "$RC"; check "R6 three creates" 3 "$(calls create)"; check "R6 one link" 1 "$(calls link)"
c1="$(nth create 1)"; c2="$(nth create 2)"; c3="$(nth create 3)"
has "R6 creates S1 first" "$c1" '(S1)"'; has "R6 creates S2 second" "$c2" '(S2)"'; has "R6 creates S3 third" "$c3" '(S3)"'
lacks "R6 S1 has no blocker" "$c1" '--blocked-by'
has "R6 S2 is blocked by S1's key" "$c2" '"--blocked-by","HIMMEL-9001"'
has "R6 S3 is blocked by S1's key" "$c3" '"--blocked-by","HIMMEL-9001"'
check "R6 S3's second blocker is one link" '["link","HIMMEL-9003","--blocked-by","HIMMEL-9002"]' "$(nth link 1)"
for c in "$c1" "$c2" "$c3"; do
    has "R6 a create carries its home" "$c" "\"--follow-up-of\",\"$P\""
    has "R6 a create carries its labels" "$c" '"--labels","standalone"'
    has "R6 a create carries the parent Sector" "$c" '"--sector","Safety & enforcement"'
    has "R6 a create carries --desc-file" "$c" '"--desc-file",'
    has "R6 a create is a Task" "$c" '"--type","Task"'
done
has "R6 CREATED lines" "$OUT" 'CREATED S3 HIMMEL-9003'
has "R6 LINKED line" "$OUT" 'LINKED HIMMEL-9002 blocks HIMMEL-9003'
next_line="$(printf '%s\n' "$OUT" | grep '^NEXT chief:')"
check "R6d one NEXT chief line, last" "$next_line" "$(printf '%s\n' "$OUT" | tail -1)"
has "R6d --keys is the parent and the three created keys" "$next_line" "--keys $P,HIMMEL-9001,HIMMEL-9002,HIMMEL-9003 "
has "R6d it names the stub's spec path" "$next_line" "--spec $SPEC_PATH "
has "R6d it supersedes the stub's O-id" "$next_line" "--supersedes O-v1.1.3-1243 "
has "R6d it names the plan" "$next_line" "--plan $F/base.md "
row r6d; filed HIMMEL-77 S2 'the adopted chain'; run "$F/base.md" --parent "$P" --apply
has "R6d a FILED key is in --keys too" "$(printf '%s\n' "$OUT" | grep '^NEXT chief:')" "--keys $P,HIMMEL-9001,HIMMEL-77,HIMMEL-9002 "

row r6b; run "$F/dep-m1.md" --parent "$P" --apply
check "R6b exits 0" 0 "$RC"
has "R6b S3 waits for M1: blocked label" "$(nth create 3)" '"--labels","standalone,blocked"'
lacks "R6b an operator step is no blocker link" "$(nth create 3)" '--blocked-by'
has "R6b the body says what it waits for" "$(body S3)" 'Waits for: M1 (operator station run, no ticket)'
row r6c; epic; run "$F/dep-m1.md" --parent "$P" --apply --proposed-version v9
check "R6c exits 0" 0 "$RC"
c3="$(nth create 3)"
has "R6c an Epic home is --parent" "$c3" "\"--parent\",\"$P\""
has "R6c the Epic home labels only blocked" "$c3" '"--labels","blocked"'
has "R6c the placement is passed" "$c3" '"--proposed-version","v9"'
lacks "R6c no --follow-up-of under an Epic" "$c3" '--follow-up-of'
has "R6c an Epic's search reads its children" "$(nth list 1)" "\"parent = $P\""

row r6e; run "$F/reversed.md" --parent "$P" --apply
check "R6e exits 0" 0 "$RC"
has "R6e creates S1 first" "$(nth create 1)" '(S1)"'; has "R6e then S2" "$(nth create 2)" '(S2)"'; has "R6e then S3" "$(nth create 3)" '(S3)"'
has "R6e S3's blocker is a key printed earlier" "$(nth create 3)" '"--blocked-by","HIMMEL-9001"'
has "R6e S3's link names a key printed earlier" "$(nth link 1)" '"link","HIMMEL-9003","--blocked-by","HIMMEL-9002"'

row r7; printf '2 exit\n' > "$R/create.fail"; run "$F/base.md" --parent "$P" --apply
check "R7 a failed create exits 3" 3 "$RC"; has "R7 FILED-SO-FAR" "$OUT" 'FILED-SO-FAR S1=HIMMEL-9001'
check "R7 no third create (I8)" 2 "$(calls create)"; lacks "R7 no NEXT line after a stop" "$OUT" 'NEXT chief:'
row r7b; printf '2 partial\n' > "$R/create.fail"; run "$F/base.md" --parent "$P" --apply
check "R7b PARTIAL exits 3" 3 "$RC"; has "R7b the PARTIAL key is filed so far" "$OUT" 'FILED-SO-FAR S1=HIMMEL-9001 S2=HIMMEL-9002'
check "R7b no third create" 2 "$(calls create)"
row r7c; printf '1 exit\n' > "$R/link.fail"; run "$F/base.md" --parent "$P" --apply
check "R7c a failed link exits 3" 3 "$RC"
has "R7c FILED-SO-FAR has three keys" "$OUT" 'FILED-SO-FAR S1=HIMMEL-9001 S2=HIMMEL-9002 S3=HIMMEL-9003'
has "R7c the owed link is printed" "$OUT" "LINK-OWED node $R/stub.cjs link HIMMEL-9003 --blocked-by HIMMEL-9002"

row r8; printf 'NO-SPEC %s\n' "$P" > "$R/spec.out"; printf '1\n' > "$R/spec.rc"
run "$F/base.md" --parent "$P" --apply
check "R8 NO-SPEC refuses --apply" 1 "$RC"; check "R8 no write verb (I9)" 0 "$(writes)"
run "$F/base.md" --parent "$P"
check "R8 the dry run still exits 0" 0 "$RC"; has "R8 the dry run prints the line it got" "$OUT" "signed: NO-SPEC $P"
row r8b; printf 'SPEC ok %s %s O-v1.1.3-1243\n' "$P" "$WORK/bucket/specs/designs/HIMMEL-9999-other.md" > "$R/spec.out"
run "$F/base.md" --parent "$P" --apply
check "R8b a spec the plan does not name refuses --apply" 1 "$RC"; check "R8b no write verb" 0 "$(writes)"
row r8c; printf 'SPEC-STALE %s %s O-v1.1.3-1243\n' "$P" "$SPEC_PATH" > "$R/spec.out"; printf '1\n' > "$R/spec.rc"
run "$F/base.md" --parent "$P" --apply
check "R8c SPEC-STALE refuses --apply" 1 "$RC"; check "R8c no write verb" 0 "$(writes)"
run "$F/base.md" --parent "$P"
check "R8c the dry run exits 0" 0 "$RC"; has "R8c the dry run prints the line" "$OUT" "signed: SPEC-STALE $P"
row r17; unbound="WARN $P plan unbound: the record O-v1.1.3-1243 signed plan $F/base.md without its hash; re-sign with --supersedes O-v1.1.3-1243 to bind it"
printf '%s\n' "$unbound" > "$R/spec.err"
run "$F/base.md" --parent "$P"
has "R17 the dry-run header relays spec-check's stderr word for word (spec:F2)" "$(printf '%s\n' "$OUT" | sed -n 1,3p)" "$unbound"
run "$F/base.md" --parent "$P" --apply
check "R17 the warning refuses nothing" 0 "$RC"; check "R17 --apply still files" 3 "$(calls create)"

row r9; run "$F/base.md" --parent "$P"
for id in S1 S2 S3; do
    body "$id" > "$R/body-$id.md"
    v="$(node "$POLICY" --type Task --labels standalone --draft "$R/body-$id.md" --json)"
    has "R9 the $id body passes the policy (I10)" "$v" '"valid":true'
    check "R9 the $id body has exactly one Writes: line" 1 "$(grep -c '^Writes:' "$R/body-$id.md")"
    check "R9 the $id body has no Depends on: line" 0 "$(grep -c '^Depends on:' "$R/body-$id.md")"
done
has "R9 S1's Writes line names its path" "$(grep '^Writes:' "$R/body-S1.md")" 'scripts/himmelctl/lib/state.js'
row r9b; run "$F/tbd-done.md" --parent "$P"
check "R9b a placeholder Done exits 1" 1 "$RC"; has "R9b names the policy's DoD finding" "$OUT" 'REFUSED S2: ticket policy: "## DoD"'
row r9b2; run "$F/base.md" --parent "$P"; has "R9b control: a real Done bullet is NEW" "$OUT" 'NEW S2 '

row r12; echo on > "$R/stateful"; run "$F/base.md" --parent "$P" --apply
check "R12 the first run creates three" 3 "$(calls create)"
run "$F/base.md" --parent "$P" --apply
check "R12 the second run exits 0" 0 "$RC"
check "R12 the second run records zero creates (I6)" 3 "$(calls create)"
has "R12 the second run reads all three FILED" "$OUT" '# counts: sections=3 skip=0 filed=3 new=0 refused=0'
lacks "R12 nothing created, no NEXT line" "$OUT" 'NEXT chief:'

row r13; run "$F/writes-shapes.md" --parent "$P"
wl="$(body S2 | grep '^Writes:')"
check "R13 one Writes line with exactly the four paths (spec:F1)" \
    'Writes: scripts/lib/test-launch-guard-p-adopted.sh scripts/lib/test-hook-set-list.sh scripts/lib/test-unwire-pretooluse-hooks.sh scripts/ledger/ceiling-add.sh' "$wl"
check "R13 four Writes-bullet NOTEs (spec:F6)" 4 "$(printf '%s\n' "$OUT" | grep -c '^NOTE S2: Writes bullet with no path: ')"
check "R13 three not-a-repo-path NOTEs" 3 "$(printf '%s\n' "$OUT" | grep -c '^NOTE S2: not a repo path: ')"
has "R13 a pathless bullet is named" "$OUT" 'NOTE S2: Writes bullet with no path: the readers found by step 1'
has "R13 a section with no path is refused (spec:F7)" "$OUT" 'REFUSED S3: no himmel write path'
check "R13 exits 1" 1 "$RC"

row r14; run "$F/wrapped.md" --parent "$P" --apply
check "R14 a wrapped Depends on files" 0 "$RC"
c3="$(nth create 3)"
has "R14 the first id links" "$c3" '"--blocked-by","HIMMEL-9001"'
has "R14 the id on the continuation links" "$(nth link 1)" '"link","HIMMEL-9003","--blocked-by","HIMMEL-9002"'
check "R14 S3 gets one link only" 1 "$(calls link)"
lacks "R14 text after the first sentence is never linked" "$(cat "$R/argv.log")" 'HIMMEL-1"'
has "R14 an if-it-exists id with no heading is dropped and noted" "$OUT" 'NOTE S3: dropped S3b'
row r14c; run "$F/fenced.md" --parent "$P"
check "R14 a field line inside a fenced block is body, not a field" 0 "$RC"
check "R14 the fenced Writes path never reaches the Writes line" 'Writes: scripts/lib/launch-guard-p.mjs' "$(body S2 | grep '^Writes:')"
has "R14 the fenced Depends on never becomes a link" "$(body S2)" 'Edges: S1 (not filed yet) blocks S2 (hard)'
has "R14 the fenced RED line never becomes the RED test" "$(body S2)" 'The RED row `test-launch-guard-p-adopted.sh` fails'
has "R14 a fence nested in a Done bullet keeps the bullets after it" "$(body S2)" '- the second result holds.'
check "R14 a top-level fence ends the Writes list" 'Writes: scripts/adopt.sh' "$(body S3 | grep '^Writes:')"
lacks "R14 a top-level fence ends the Depends-on paragraph" "$(body S3)" 'HIMMEL-6'
row r14b; run "$F/tbd-dep.md" --parent "$P"
check "R14 Depends on: TBD exits 1" 1 "$RC"; has "R14 Depends on: TBD is refused" "$OUT" 'REFUSED S2: Depends on names no slice'

r15() {
    local name="$1" want="$2"; shift 2
    run "$@" --apply
    check "R15 $name exits 1" 1 "$RC"; has "R15 $name is named" "$OUT" "$want"; check "R15 $name: no write verb" 0 "$(writes)"
}
row r15a; r15 'a cycle among NEW slices' 'REFUSED: cycle' "$F/cycle.md" --parent "$P"
row r15b; r15 'two ## S2: sections' 'REFUSED: two ## S2: sections' "$F/dup-id.md" --parent "$P"
row r15c; filed HIMMEL-77 S2 x; filed HIMMEL-78 S2 y; r15 'two listed (S2) titles' 'REFUSED: S2 matches' "$F/base.md" --parent "$P"
row r15d; i=0; : > "$R/list.txt"; while [ $i -lt 500 ]; do printf 'HIMMEL-%d\tTask\tTo Do\tt%d\n' $((20000 + i)) $i >> "$R/list.txt"; i=$((i + 1)); done
r15 'a 500-row search' 'REFUSED: the search returned 500 rows' "$F/base.md" --parent "$P"
row r15e; r15 'a ## Slice 1 — plan' 'REFUSED: no ## S<id>: section' "$F/slice-form.md" --parent "$P"
row r15f; epic; r15 'an Epic parent with no --proposed-version' 'REFUSED: parent HIMMEL-10314 is an Epic' "$F/base.md" --parent "$P"
row r15g; filed HIMMEL-77 S2 'the adopted chain'; r15 'a --skip id that is filed' 'REFUSED: S2 is filed as HIMMEL-77; drop it from --skip' "$F/base.md" --parent "$P" --skip S2
row r15h; run "$F/base.md" --parent "$P" --apply; check "R15 control: the base fixture files" 3 "$(calls create)"

row r16; printf '2 unknown\n' > "$R/create.fail"; run "$F/base.md" --parent "$P" --apply
check "R16 OUTCOME UNKNOWN exits 3" 3 "$RC"; has "R16 names the slice" "$OUT" 'OUTCOME-UNKNOWN S2: do not re-run until the chief finds or rules out the ticket'
check "R16 no further call" 2 "$(calls create)"; check "R16 no link after it" 0 "$(calls link)"
row r16b; printf '2 partial\n' > "$R/create.fail"; run "$F/base.md" --parent "$P" --apply
check "R16 PARTIAL exits 3" 3 "$RC"; has "R16 PARTIAL key filed so far" "$OUT" 'S2=HIMMEL-9002'
has "R16 the PARTIAL line is relayed word for word" "$OUT" 'jira: PARTIAL: Created HIMMEL-9002 but linking HIMMEL-9001 to HIMMEL-9002 failed: HTTP 500 Internal Server Error; still owed: linking HIMMEL-9001 to HIMMEL-9002. The ticket exists: finish these by hand, do not re-run create.'
has "R16 the owed first-dependency link" "$OUT" "LINK-OWED node $R/stub.cjs link HIMMEL-9002 --blocked-by HIMMEL-9001"
row r16c; filed HIMMEL-77 S1 'the list'; run "$F/cycle.md" --parent "$P"
check "R16 a cycle written only in a FILED section does not refuse" 0 "$RC"; has "R16 S1 is FILED" "$OUT" 'FILED S1 HIMMEL-77'

row r18; run "$F/no-goal.md" --parent "$P" --apply
check "R18 no Goal exits 1" 1 "$RC"; has "R18 names it" "$OUT" 'REFUSED: no **Goal:** line'; check "R18 no write verb" 0 "$(writes)"
row r18b; run "$F/no-revision.md" --parent "$P"
check "R18 no revision still dry-runs" 0 "$RC"; has "R18 one revision NOTE" "$OUT" 'NOTE: plan has no revision'
has "R18 the Why names no revision" "$(body S1)" "Slice of $P, signed plan no-revision.md. Plan dependency: none"

row u; run "$F/base.md"; check "no --parent is a usage error" 2 "$RC"
run "$F/base.md" --parent "$P" --bogus; check "an unknown flag is a usage error" 2 "$RC"
check "a usage error makes no Jira call" 0 "$(grep -c . "$R/argv.log" 2>/dev/null)"

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo 'ALL PASS' || echo "$fails FAILED")"
[ "$fails" -eq 0 ]
