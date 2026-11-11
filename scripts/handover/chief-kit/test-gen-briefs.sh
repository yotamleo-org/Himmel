#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-brief-lint.sh
# test-gen-briefs.sh — Exercises gen-briefs.py on a fixture workers
# JSON: the briefs it writes pass brief-lint.sh (the arming-time check
# headed-arm-worker runs), the launcher carries the hook-integrity bypass export
# only for hook=true, bad input is refused, nothing is overwritten. The worktree
# step is stubbed (GEN_BRIEFS_WORKTREE_CMD) and every path is a fixture: no real
# bucket, worktree or launch. GEN_BRIEFS overrides the script under test (the
# RED control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-gen-briefs.sh
set -u
export UNGUARDED_LAUNCH_OK=1  # HIMMEL-9026: scratch fixtures; guard rows drop it
unset CLAUDE_GLM_CONFIG_DIR  # the classifier reads it for its claude-glm lists: an inherited one would redirect every salus row
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${GEN_BRIEFS:-$HERE/gen-briefs.py}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gen-briefs-test.XXXXXX")" || exit 1
# Physical path: gen-briefs.py resolves a relative --repo through getcwd, which names /private/var/... on macOS, not the logical TMPDIR.
WORK="$(cd "$WORK" && pwd -P)" || exit 1
trap 'rm -rf "$WORK"' EXIT
BUCKET="$WORK/bucket"; REPO="$WORK/repo"; mkdir -p "$REPO"
# No bus identity, so relay-batch never reaches the real himmel-bus store.
unset HIMMEL_BUS_NAME
export HIMMEL_FLAG_PR_SIZE_GATE=0

cat > "$WORK/wt.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$WT_LOG"
w="$PWD/.claude/worktrees/$(printf '%s' "$1" | tr / +)"; mkdir -p "$w"
[ ! -e "$PWD/.git" ] || printf 'gitdir: %s\n' "$PWD/.git" > "$w/.git"
[ "$1" = "fix/fail-me" ] && exit 1
echo "created worktree $1"
EOF
chmod +x "$WORK/wt.sh"
export WT_LOG="$WORK/wt.log" GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh"
export GEN_BRIEFS_MIRROR="$WORK/mirror"; mkdir -p "$GEN_BRIEFS_MIRROR"  # the proof check reads this fixture mirror, never the real one
export TICKET_STATUS_STATE_DIR="$WORK/state-empty"  # the partial-merge block reads status-events.jsonl here, never the real one
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/gh-down.sh"; chmod +x "$WORK/gh-down.sh"
export GEN_BRIEFS_GH_CMD="$WORK/gh-down.sh"
export GEN_BRIEFS_NO_WT_CHECK=1 # the older rows use a fixture --repo with no real worktrees; the bucket and worktree-guard rows unset it
# The core gate asks the jira CLI (release core-check, spec-check) per key. This suite points GEN_BRIEFS_JIRA_CLI at a
# fixture stand-in over the fixture mirror, so it needs no built scripts/jira/dist (untracked, absent in CI).
mkdir -p "$WORK/stub-jira"
cat > "$WORK/stub-jira/index.js" <<'EOF'
const fs = require('fs');
const a = process.argv.slice(2);
const opt = (n) => { const i = a.indexOf(n); return i < 0 ? null : a[i + 1]; };
const mirror = opt('--mirror');
const ticket = (k) => {
  let t;
  try { t = fs.readFileSync(mirror + '/' + k + '.md', 'utf8'); } catch (e) { return null; }
  const f = (n) => ((t.match(new RegExp('^' + n + ': (.*)$', 'm')) || [])[1] || '').replace(/"/g, '');
  return { type: f('type'), prio: f('priority'), labels: f('labels') };
};
if (a[0] === 'release' && a[1] === 'core-check') {
  const paths = (opt('--paths') || '').split(',').filter(Boolean);
  const abs = paths.find((p) => p.startsWith('/'));  // the real CLI throws on an absolute --paths (core.ts expandPaths)
  if (abs) { console.error('release core-check: --paths takes repository-relative paths; ' + abs + ' is absolute'); process.exit(1); }
  const hit =paths.find((p) => /^(scripts\/handover\/|marketplace\/plugins\/himmel-bus\/)/.test(p));
  for (const k of a.slice(a.indexOf('--key') + 1)) {
    const t = ticket(k);
    if (!t) console.log((fs.existsSync(process.env.CG_STUB_UNKNOWN + '/' + k) ? 'UNKNOWN ' : 'NOT-CORE ') + k);  // only a key the suite marks is a mirror miss
    else if (t.labels.includes('core') && !hit && a.includes('--docs-only') && paths.length > 0 && paths.every((p) => p.startsWith('docs/') || p.endsWith('.md'))) console.log('BYPASS ' + k + ' design label-only core ticket, docs-only Writes');
    else if (fs.existsSync(process.env.CG_STUB_NEEDS + '/' + k)) process.stdout.write(fs.readFileSync(process.env.CG_STUB_GOLDEN, 'utf8'));
    else if (t.type === 'Bug' && /^(Highest|Blocker)$/.test(t.prio)) console.log('BYPASS ' + k + ' emergency Bug at ' + t.prio);
    else if (t.type === 'Bug') console.log('BYPASS ' + k + ' bug a Bug is not gated');
    else if (hit) console.log('CORE ' + k + ' ' + hit);
    else if (t.labels.includes('core')) console.log('CORE ' + k + ' label core');
    else console.log('NOT-CORE ' + k);
  }
} else if (a[0] === 'release' && a[1] === 'spec-check') {
  let missing = 0;
  for (const k of a.slice(a.indexOf('--mirror') + 2)) {
    let r = '';
    try { r = fs.readFileSync(process.env.CG_STUB_SIGNED + '/' + k, 'utf8').trim(); } catch (e) { missing = 1; }
    console.log(r ? 'SPEC ok ' + k + ' ' + r : 'NO-SPEC ' + k);
  }
  process.exit(missing);
} else if (a[0] === 'release' && a[1] === 'bucket-check') {
  for (const k of a.slice(a.indexOf('--mirror') + 2)) console.log('IN ' + k + ' current=v1.1.3 via=mirror');
} else if (a[0] === 'mirror') {
  if (process.env.MIRROR_LOG) fs.appendFileSync(process.env.MIRROR_LOG, 'mirror ' + a.join(' ') + ' project=' + process.env.JIRA_PROJECT_KEY + '\n');
  const src = process.env.MIRROR_FRESH;
  if (src && fs.existsSync(src)) for (const f of fs.readdirSync(src)) fs.copyFileSync(src + '/' + f, opt('--root') + '/' + f);
} else if (a[0] === 'live-test' && a[1] === '--json') {
  // prints one of the canned verb outputs (scripts/jira/src/fixtures/live-test-*.json); LT_STUB_RC makes the verb fail
  if (process.env.LT_STUB_RC) { console.error('stub jira: live-test failed'); process.exit(Number(process.env.LT_STUB_RC)); }
  process.stdout.write(fs.readFileSync(process.env.LT_STUB_FILE || (process.env.LT_FIXTURES + '/live-test-none.json'), 'utf8'));
} else {
  console.error('stub jira: unknown command ' + a.join(' '));
  process.exit(2);
}
EOF
export GEN_BRIEFS_JIRA_CLI="$WORK/stub-jira/index.js" CG_STUB_SIGNED="$WORK/cg-signed" CG_STUB_UNKNOWN="$WORK/cg-unknown"; mkdir -p "$CG_STUB_UNKNOWN"
LT_FIXTURES="$(cd "$HERE/../../jira/src/fixtures" && pwd)"; export LT_FIXTURES
export CG_STUB_NEEDS="$WORK/cg-needs" CG_STUB_GOLDEN="$HERE/../../jira/src/release/fixtures/bypass-needs-spec.line"; mkdir -p "$CG_STUB_NEEDS"
# brief-lint.sh (run on every generated brief, and by the launcher) asks the same stand-in over the same fixture mirror
export BRIEF_LINT_JIRA_CLI="$GEN_BRIEFS_JIRA_CLI" BRIEF_LINT_MIRROR="$GEN_BRIEFS_MIRROR"
cat > "$WORK/stub-route.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ROUTE_LOG"
case "$1" in
fold-list)
    b="$(basename "$3")"
    if [ -f "$ROUTE_STUB/$b.fail" ]; then cat "$ROUTE_STUB/$b.fail" >&2; exit 1; fi
    [ ! -f "$ROUTE_STUB/$b.fold" ] || cat "$ROUTE_STUB/$b.fold" ;;
round-status)
    if [ -f "$ROUTE_STUB/$2.fail" ]; then cat "$ROUTE_STUB/$2.fail" >&2; exit 1; fi
    if [ -f "$ROUTE_STUB/$2.json" ]; then cat "$ROUTE_STUB/$2.json"; else printf '{"key":"%s","spec":1,"plan":0,"writer":1,"next":"full","why":"spec round 2: full; plan round 1: full"}\n' "$2"; fi ;;
*) echo "stub route: unknown verb $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$WORK/stub-route.sh"
export GEN_BRIEFS_ROUTE_CMD="$WORK/stub-route.sh" ROUTE_LOG="$WORK/route.log" ROUTE_STUB="$WORK/route-stub"; mkdir -p "$ROUTE_STUB"

cat > "$WORK/workers.json" <<'EOF'
[
 {"label":"N901","keys":["HIMMEL-9001"],"slug":"plain-fix","branch":"fix/himmel-9001-plain-fix","title":"a plain fix","desc":"fix the plain thing","why":"it is broken","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","writes":"scripts/x/","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9001] fix the plain thing"},
 {"label":"N902","keys":["HIMMEL-9002","HIMMEL-9003"],"slug":"hook-fix","branch":"fix/himmel-9002-hook-fix","title":"a hook fix","desc":"fix the hook thing","why":"the hook is broken","prior":"none found (qmd jira-himmel hook thing)","writes":"scripts/hooks/h.sh","scope":"`scripts/hooks/h.sh`","scope_short":"h.sh","hook":true,"judge":true,"env":true,"commit":"fix(hooks): [HIMMEL-9002] fix the hook","extra":"GREEN controls stay."}
]
EOF

run() { python3 "$SUT" "$WORK/workers.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$BUCKET" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/w" --deadline 1791475000 "$@"; }

out="$(run --manifest "$WORK/fleet.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "a valid workers file generates (rc 0)" || fail "rc=$rc: $out"
D1="$BUCKET/HIMMEL-9001-N901-plain-fix-2026-10-08.md"
D2="$BUCKET/HIMMEL-9002-N902-hook-fix-2026-10-08.md"
[ -f "$D1" ] && [ -f "$D2" ] && pass "one brief per worker, named <KEY>-<label>-<slug>-<date>.md" || fail "briefs missing in $BUCKET"
bash "$HERE/brief-lint.sh" "$D1" 2>"$WORK/lint1.err"; rc=$?
[ "$rc" = 0 ] && pass "brief 1 passes brief-lint.sh" || fail "brief 1 brief-lint rc=$rc: $(cat "$WORK/lint1.err")"
bash "$HERE/brief-lint.sh" "$D2" 2>"$WORK/lint2.err"; rc=$?
[ "$rc" = 0 ] && pass "brief 2 (none found (<query>) prior art) passes brief-lint.sh" || fail "brief 2 brief-lint rc=$rc: $(cat "$WORK/lint2.err")"

# Every generated brief tells its worker to run the named notes search and graph lookup and cite them
for b in "$D1" "$D2"; do
    BD="$(tr '\n' ' ' < "$b" | tr -s ' ')"
    has "$(basename "$b") carries the jira-himmel notes search" "$BD" "scripts/lib/qmd-bounded.sh query -c jira-himmel"
    has "$(basename "$b") carries the luna notes search" "$BD" "scripts/lib/qmd-bounded.sh query -c luna"
    has "$(basename "$b") carries the graph-lookup directive" "$BD" "scripts/graphify/worker-graph.sh explain"
    has "$(basename "$b") names the graph-qmd: Results bullet" "$BD" "graph-qmd: <what each returned and whether used>"
    lacks "$(basename "$b") leaves no <topic> placeholder" "$BD" "<topic>"
    lacks "$(basename "$b") leaves no <symbol> placeholder" "$BD" "<symbol>"
done
# the directive names the leg's own query and symbol: the title and first Writes path by default, search_query/search_symbol when set
has "brief 1 defaults the notes query to the title" "$(tr '\n' ' ' < "$D1" | tr -s ' ')" 'query -c luna "a plain fix"'
has "brief 1 defaults the graph symbol to the first Writes path" "$(tr '\n' ' ' < "$D1" | tr -s ' ')" 'worker-graph.sh explain "scripts/x/"'
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["search_query"]="brief prior art cite duty"; l[0]["search_symbol"]="brief-lint.sh"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/named.json"
nout="$(python3 "$SUT" "$WORK/named.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/named-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/wn" --deadline 1791475000 2>&1)"; rc=$?
NB="$(tr '\n' ' ' < "$WORK/named-bucket/HIMMEL-9001-N901-plain-fix-2026-10-08.md" | tr -s ' ')"
bash "$HERE/brief-lint.sh" "$WORK/named-bucket/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>"$WORK/lintn.err"; lrc=$?
{ [ "$rc" = 0 ] && [ "$lrc" = 0 ]; } && pass "a leg that names its search_query and search_symbol generates and lints" || fail "named-search generation rc=$rc lint rc=$lrc: $nout $(cat "$WORK/lintn.err")"
has "the named notes query reaches both collections" "$NB" 'query -c jira-himmel "brief prior art cite duty"'
has "the named notes query reaches the luna collection" "$NB" 'query -c luna "brief prior art cite duty"'
has "the named graph symbol reaches the directive" "$NB" 'worker-graph.sh explain "brief-lint.sh"'
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["writes"]="none named"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/nowrites.json"
python3 "$SUT" "$WORK/nowrites.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/nowrites-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/wnw" --deadline 1791475000 >/dev/null 2>&1; rc=$?
NW="$(tr '\n' ' ' < "$WORK/nowrites-bucket/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>/dev/null | tr -s ' ')"
bash "$HERE/brief-lint.sh" "$WORK/nowrites-bucket/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>"$WORK/lint-nw.err"; lrc=$?
{ [ "$rc" = 0 ] && [ "$lrc" = 0 ]; } && pass "a no-writes leg generates and lints" || fail "no-writes rc=$rc lint rc=$lrc: $(cat "$WORK/lint-nw.err")"
has "a no-writes leg says it has no graph lookup" "$NW" "no graph lookup"
lacks "a no-writes leg never asks the graph to explain none" "$NW" 'explain "none"'
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["writes"]="Makefile scripts/x/"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/rootfile.json"
python3 "$SUT" "$WORK/rootfile.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/rootfile-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/wrf" --deadline 1791475000 >/dev/null 2>&1
has "a root-level Writes file (no slash, no dot) still gets the graph lookup" "$(tr '\n' ' ' < "$WORK/rootfile-bucket/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>/dev/null)" 'worker-graph.sh explain "Makefile"'
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["writes"]="none named"; l[0]["search_symbol"]="gen-briefs.py"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/nowrites-sym.json"
python3 "$SUT" "$WORK/nowrites-sym.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/nwsym-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/wns" --deadline 1791475000 >/dev/null 2>&1
has "a no-writes leg that names a search_symbol gets the graph lookup" "$(tr '\n' ' ' < "$WORK/nwsym-bucket/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>/dev/null)" 'worker-graph.sh explain "gen-briefs.py"'
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["search_query"]="has <topic> in it"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/badq.json"
python3 "$SUT" "$WORK/badq.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/badq-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/wq" --deadline 1791475000 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "a search_query with an angle bracket is refused (rc 1)" || fail "bad search_query rc=$rc"
# shellcheck disable=SC2016  # the command substitution must stay literal text in the fixture
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["search_symbol"]="$(touch /tmp/x)"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/subst.json"
python3 "$SUT" "$WORK/subst.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/subst-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/ws" --deadline 1791475000 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "a search_symbol with a command substitution is refused (rc 1)" || fail "command-substitution search_symbol rc=$rc"
# shellcheck disable=SC2016  # literal command substitution and backticks in the fixture title
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["title"]="fix $(touch /tmp/x) and `id`"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/dtitle.json"
python3 "$SUT" "$WORK/dtitle.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/dtitle-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/wd" --deadline 1791475000 >/dev/null 2>&1; rc=$?
DT="$(tr '\n' ' ' < "$WORK/dtitle-bucket/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>/dev/null)"
{ [ "$rc" = 0 ] && case "$DT" in *'query -c luna "fix (touch /tmp/x) and id"'*) true ;; *) false ;; esac; } \
    && pass "a title with command substitution is sanitized in the default query, never pasted live" || fail "title substitution rc=$rc: $DT"

# every brief tells a worker a new suite needs no row, and no longer grants one
has "brief 1 says a new suite needs no row" "$(tr '\n' ' ' < "$D1" | tr -s ' ')" "A new test suite needs no row in scripts/ci/suite-tiers.tsv or scripts/ci/suite-durations.tsv"
has "brief 2 says a new suite needs no row" "$(tr '\n' ' ' < "$D2" | tr -s ' ')" "A new test suite needs no row in scripts/ci/suite-tiers.tsv or scripts/ci/suite-durations.tsv"
lacks "brief 1 no longer grants a new suite its own rows" "$(tr '\n' ' ' < "$D1" | tr -s ' ')" "name the rows in READY"

# contract item 3: a worker runs locally only the RED rows it builds; every other impacted suite is CI-gated
B1="$(tr '\n' ' ' < "$D1" | tr -s ' ')"
lacks "brief 1 no longer tells the worker to run the full suite of every touched file" "$B1" "the full suite of every file you touched"
has "brief 1 hands every other impacted test-*.sh on to CI as SUITE <p> = CI" "$B1" "write \`SUITE <p> = CI\` for every other impacted \`test-*.sh\` you did not change and CI runs"
lacks "brief 1 no longer lists suites as SKIP CI-gated per decision 101" "$B1" "SKIP CI-gated per decision 101"
has "brief 1 points at the one statement of the rule" "$B1" "scripts/cr/pr-check-ref/33-step3-impacted.md"
has "brief 1 routes VM-only checks through the VM queue" "$B1" "VM queue"
has "brief 1 forbids run-shell-tests.sh full or sharded locally" "$B1" "never run run-shell-tests.sh full or sharded locally"
has "brief 1 limits local runs to the RED rows, changed suites, JS/TS and refused suites" "$B1" "Run locally the RED rows of the item you build, the suites you changed or added, JS/TS suites, and every suite \`--check\` refuses \`= CI\` for"

# the three most-refused shapes are taught where the worker first meets them (7370, 7371, 7372)
has "brief 1 teaches the exact quiet-run RED command, nothing inside the backticks after the suite" "$B1" "run it as \`bash scripts/quiet-run.sh suite -- bash <test-*.sh>\` with nothing appended"
has "brief 1 names the quiet-run log path to Read" "$B1" "Read the log path its ERR line prints"
has "brief 1 teaches the Edit tool / python3 -I <file> shape" "$B1" "run as \`python3 -I <file>\`"
has "brief 1 teaches the SWEEP record grammar and its write command" "$B1" "write its \`SWEEP [<id>@<head>] class=… :: sites=…\` line (a one-site finding: \`:: single-site search=git grep …\`) with \`bash scripts/cr/write-verdicts.sh sweep --branch <b> --from-file <f>\`"
has "brief 1 teaches the single-site search form for a one-site finding" "$B1" ":: single-site search=git grep"

# the wrap step checks the queue lock: the brief's wrap command carries --queue-doc with THIS worker's doc
has "brief 1 wrap command passes --queue-doc with its own doc" "$(cat "$D1")" "wrap-subtree-check.sh --queue-doc $D1"
has "brief 2 wrap command passes --queue-doc with its own doc" "$(cat "$D2")" "wrap-subtree-check.sh --queue-doc $D2"
has "the worker preface's HALT/WRAP step passes --queue-doc" "$(tr '\n' ' ' < "$HERE/../../../docs/handover/worker-preface.md" | tr -s ' ')" "wrap-subtree-check.sh --queue-doc <doc>"

# the arming gate lints every brief, so a generated brief must also
# arm through the launcher itself (dry-run reaches the gate before it exits).
# (a copy whose resume_cwd is a plain directory: the worktree check is a later gate and the copy leaves D1 alone; the lint needs an absolute one)
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$WORK/preflight.sh"
mkdir -p "$WORK/arm"; sed "s|^resume_cwd:.*|resume_cwd: $WORK|" "$D1" > "$WORK/arm/HIMMEL-9001-N901-copy.md"
rc=0; arm_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --profile worker-impl HIMMEL-9001-N901 "$WORK/arm/HIMMEL-9001-N901-copy.md" "$WORK/arm/signal" 9999999999 "$WORK/arm/log" claude-sonnet-5-5 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "a generated brief arms through headed-arm-worker.sh (brief-lint gate)" || fail "generated brief refused by headed-arm-worker.sh rc=$rc: $arm_out"

b1="$(cat "$D1" 2>/dev/null)"; b2="$(cat "$D2" 2>/dev/null)"
has "the brief names the chief" "$b1" "HIMMEL-nextleg-2026-10-08BZ-roadmap-chief"
has "the brief carries a nonce in the chief letter's shape" "$b1" "BZ-N901-"
has "the brief names the base sha" "$b1" "4ccb59dd6de2eba962c75f136096cd7b721ae312"
has "the brief names the worktree under the repo" "$b1" "$REPO/.claude/worktrees/fix+himmel-9001-plain-fix"
has "the brief carries the handover root" "$b1" "$WORK/handovers"
has "a two-key worker's Why lists both tickets' get commands" "$b2" "get HIMMEL-9003"
has "a hook worker's brief says it is launched with the bypass" "$b2" "hook-integrity bypass flag"
lacks "a plain worker's brief does not" "$b1" "hook-integrity bypass flag"
has "a judge worker's brief announces the opus judge" "$b2" "chief runs an opus judge"
has "the other worker's scope is listed under 'other live workers'" "$b1" "N902 (h.sh)"
has "the brief puts the write list on its own '> **Writes:**' line (HIMMEL-7469)" "$(grep -c '^> \*\*Writes:\*\* ' "$D1")" "1"
[ "$(grep '^> \*\*Writes:\*\* ' "$D1")" = "> **Writes:** scripts/x/" ] && pass "the Writes line is the scope's paths only (HIMMEL-7469)" || fail "the Writes line is not exactly the scope's paths: $(grep '^> \*\*Writes:\*\* ' "$D1")"
lacks "the Writes line carries no backtick prose (HIMMEL-7469)" "$(grep '^> \*\*Writes:\*\* ' "$D1")" '`'
# a worker flagged for CI, infra or the environment gets a RED-first line requiring a real-environment fixture.
has "a flagged worker's brief requires a fixture copied from the real environment" "$b2" "copied from the real environment"
lacks "an unflagged worker's brief does not" "$b1" "copied from the real environment"

l1="$(cat "$BUCKET/launch-N901.sh" 2>/dev/null)"; l2="$(cat "$BUCKET/launch-N902.sh" 2>/dev/null)"
lacks "a plain worker's launcher has NO bypass export" "$l1" "HIMMEL_HOOK_INTEGRITY_BYPASS_OK"
has "a hook worker's launcher exports the bypass" "$l2" "export HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1"
has "the launcher calls headed-arm-worker.sh under the repo" "$l1" "$REPO/scripts/handover/chief-kit/headed-arm-worker.sh --profile worker-impl --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief"
has "the launcher passes the deadline and model" "$l1" "1791475000"
has "the launcher is syntactically valid bash" "$(bash -n "$BUCKET/launch-N901.sh" 2>&1 && echo ok)" "ok"
[ -x "$BUCKET/launch-N901.sh" ] && pass "launchers are executable" || fail "launcher not executable"
has "it prints one manifest add per worker" "$out" "fleet-manifest.sh add $WORK/fleet.json $D2"
# the printed add line carries --lane, so the manifest never stores lane unknown.
has "the add line for a default worker carries --lane native" "$out" "fleet-manifest.sh add $WORK/fleet.json $D1 --lane native"
has "and so does the second worker's" "$out" "fleet-manifest.sh add $WORK/fleet.json $D2 --lane native"
# The printed lines, run as printed from the repo root, build a manifest relay-batch resolves.
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
# fleet-manifest.sh takes a util-linux flock (its PLATFORM GUARD): without one no manifest row is written, so the relay rows have nothing to read.
if command -v flock >/dev/null 2>&1; then
printf '%s\n' "$out" | grep '^bash scripts/handover/chief-kit/fleet-manifest.sh add ' > "$WORK/adds.txt"
while IFS= read -r addline; do (cd "$REPO_ROOT" && eval "$addline" >/dev/null 2>&1); done < "$WORK/adds.txt"
cp "$WORK/fleet.json" "$WORK/chief.fleet.json" 2>/dev/null
# shellcheck disable=SC2016  # the backticks are literal markers in the Live state
printf '## Live state\nlegs: `N901:tok1:lock:1` `N902:tok2:lock:2`\n' > "$WORK/chief.md"
cat > "$WORK/census.sh" <<'EOC'
#!/usr/bin/env bash
printf '1\tHIMMEL-9001-N901-plain-fix-2026-10-08\tm\t0\n2\tHIMMEL-9002-N902-hook-fix-2026-10-08\tm\t0\n'
EOC
rb="$(RELAY_BATCH_CENSUS="$WORK/census.sh" bash "$HERE/relay-batch.sh" "$WORK/chief.md" --successor X-chief 2>&1)"
lacks "relay-batch on a gen-briefs-built manifest prints no UNRESOLVED-LANE" "$rb" "UNRESOLVED-LANE"
has "relays the first worker" "$rb" "SENDMESSAGE to=HIMMEL-9001-N901-plain-fix-2026-10-08"
has "and relays the second worker" "$rb" "SENDMESSAGE to=HIMMEL-9002-N902-hook-fix-2026-10-08"
else
  echo "SKIP relay-batch rows (no flock on this host, so fleet-manifest.sh writes no row)"
fi
# the sidecar Telegram /launch-worker checks is written with the launcher.
side="$(cat "$WORK/fleet.launchers.sha256" 2>/dev/null)"
# hashlib, not sha256sum: macOS ships shasum only.
sha_of() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
has "the sha256 sidecar records launcher 1 at write time" "$side" "$(sha_of "$BUCKET/launch-N901.sh")  $BUCKET/launch-N901.sh"
has "and launcher 2" "$side" "$(sha_of "$BUCKET/launch-N902.sh")  $BUCKET/launch-N902.sh"
has "it created both worktrees via the seam" "$(paste -sd, "$WORK/wt.log")" "fix/himmel-9001-plain-fix,fix/himmel-9002-hook-fix"
[ -f "$WORK/workers.json.out" ] && pass "the .out file records the nonces" || fail "no .out file"
has "nothing was launched (no signal files)" "$(ls "$WORK/w" 2>&1)" "No such file"

# A chief that runs only the launcher must still leave the worker in the manifest,
# added BEFORE the arm. The launcher runs against a fixture repo (real fleet-manifest.sh and libs,
# stub headed-arm-worker.sh) with `sleep` stubbed off the PATH.
if command -v flock >/dev/null 2>&1; then
R7811="$WORK/repo7811"; mkdir -p "$R7811/scripts/handover/chief-kit" "$WORK/bin7811"
cp -R "$REPO_ROOT/scripts/lib" "$R7811/scripts/lib"
cp "$HERE/fleet-manifest.sh" "$R7811/scripts/handover/chief-kit/fleet-manifest.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$WORK/arm7811.log" > "$R7811/scripts/handover/chief-kit/headed-arm-worker.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin7811/sleep"; chmod +x "$WORK/bin7811/sleep"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b7811" --repo "$R7811" --handover-root /h --no-worktree --manifest "$WORK/f7811.fleet.json" >/dev/null 2>&1
PATH="$WORK/bin7811:$PATH" bash "$WORK/b7811/launch-N901.sh" >/dev/null 2>&1; rc7811=$?
[ "$rc7811" -eq 0 ] && pass "the generated launcher exits 0 (HIMMEL-7811)" || fail "the generated launcher exited $rc7811"
d7811="$(find "$WORK/b7811" -maxdepth 1 -name 'HIMMEL-9001-N901-plain-fix-*.md' 2>/dev/null | head -n1)"
[ -n "$d7811" ] && bash "$HERE/fleet-manifest.sh" list "$WORK/f7811.fleet.json" 2>&1 | grep -Fxq -- "$d7811" && pass "the generated launcher leaves its exact worker doc in the fleet manifest (HIMMEL-7811)" || fail "the fleet manifest does not list the exact worker doc [$d7811]"
l7811="$(cat "$WORK/b7811/launch-N901.sh" 2>/dev/null)"
add_pos="${l7811%%fleet-manifest.sh add*}"; arm_pos="${l7811%%headed-arm-worker.sh*}"
[ "${#add_pos}" -lt "${#arm_pos}" ] && pass "the launcher adds the worker to the manifest before it arms (HIMMEL-7811)" || fail "manifest add does not precede the arm in the launcher"
PATH="$WORK/bin7811:$PATH" bash "$WORK/b7811/launch-N901.sh" >/dev/null 2>&1; rc7811=$?
[ "$rc7811" -eq 0 ] && pass "the re-run launcher exits 0 (HIMMEL-7811)" || fail "the re-run launcher exited $rc7811"
[ "$(bash "$HERE/fleet-manifest.sh" list "$WORK/f7811.fleet.json" 2>&1 | grep -c N901)" = 1 ] && pass "running the launcher twice adds the worker once (HIMMEL-7811)" || fail "launcher re-run duplicated the manifest row"
# A failed manifest add stops the launch: the arm never runs.
R7811f="$WORK/repo7811f"; mkdir -p "$R7811f/scripts/handover/chief-kit"
cp -R "$REPO_ROOT/scripts/lib" "$R7811f/scripts/lib"
printf '#!/usr/bin/env bash\nexit 1\n' > "$R7811f/scripts/handover/chief-kit/fleet-manifest.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$WORK/arm7811f.log" > "$R7811f/scripts/handover/chief-kit/headed-arm-worker.sh"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b7811f" --repo "$R7811f" --handover-root /h --no-worktree --manifest "$WORK/f7811f.fleet.json" >/dev/null 2>&1
has "the launcher for the failed-add check carries the manifest add (HIMMEL-7811)" "$(cat "$WORK/b7811f/launch-N901.sh" 2>/dev/null)" "fleet-manifest.sh"
PATH="$WORK/bin7811:$PATH" bash "$WORK/b7811f/launch-N901.sh" >/dev/null 2>&1; rc7811f=$?
[ "$rc7811f" -ne 0 ] && pass "a failed manifest add makes the launcher exit non-zero (HIMMEL-7811)" || fail "launcher exited 0 after a failed manifest add"
[ ! -s "$WORK/arm7811f.log" ] && pass "a failed manifest add stops the launch before the arm (HIMMEL-7811)" || fail "the arm ran after a failed manifest add"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b7811n" --repo "$R7811" --handover-root /h --no-worktree >/dev/null 2>&1; rc7811n=$?
[ "$rc7811n" -eq 0 ] && pass "generation without --manifest succeeds (HIMMEL-7811)" || fail "generation without --manifest exited $rc7811n"
has "the launcher generated without --manifest still arms (HIMMEL-7811)" "$(cat "$WORK/b7811n/launch-N901.sh" 2>/dev/null)" "headed-arm-worker.sh"
lacks "a launcher generated without --manifest adds nothing (HIMMEL-7811)" "$(cat "$WORK/b7811n/launch-N901.sh" 2>/dev/null)" "fleet-manifest.sh"
else
  echo "SKIP launcher manifest rows (no flock on this host)"
fi

# --- refusals ---------------------------------------------------------------
run >/dev/null 2>"$WORK/again.err"; rc=$?
[ "$rc" = 1 ] && pass "re-running over existing briefs refuses (rc 1)" || fail "overwrite rc=$rc"

rm -rf "$BUCKET"
sed 's/"prior":"HIMMEL-9000[^"]*"/"prior":"none"/' "$WORK/workers.json" > "$WORK/bare.json"
python3 "$SUT" "$WORK/bare.json" --base 4ccb59d --chief BZ --bucket "$BUCKET" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/bare.err"; rc=$?
[ "$rc" = 1 ] && pass "a bare 'none' prior art is refused (rc 1)" || fail "bare none rc=$rc"
[ ! -e "$BUCKET/launch-N901.sh" ] && pass "and nothing is written for it" || fail "wrote files for an invalid worker"

printf '[{"label":"N903","keys":["HIMMEL-1"]}]\n' > "$WORK/short.json"
python3 "$SUT" "$WORK/short.json" --base 4ccb59d --chief BZ --bucket "$BUCKET" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/short.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'missing' "$WORK/short.err" && pass "a worker missing required keys is refused" || fail "missing keys rc=$rc"

python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --console BZ --bucket "$WORK/b-oldflag" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/oldflag.err"; rc=$?
[ "$rc" = 2 ] && grep -q 'unrecognized arguments: --console' "$WORK/oldflag.err" && [ ! -e "$WORK/b-oldflag/launch-N901.sh" ] && pass "the retired --console flag is refused (rc 2, nothing written)" || fail "--console rc=$rc"

sed 's#fix/himmel-9001-plain-fix#fix/fail-me#' "$WORK/workers.json" > "$WORK/wtfail.json"
python3 "$SUT" "$WORK/wtfail.json" --base 4ccb59d --chief BZ --bucket "$WORK/b2" --repo "$REPO" --handover-root /h >/dev/null 2>"$WORK/wtfail.err"; rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/b2/launch-N901.sh" ] && pass "a failed worktree writes no brief for that worker" || fail "worktree failure rc=$rc"

mkdir -p "$WORK/b3"; : > "$WORK/b3/launch-N901.sh"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b3" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/coll.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'launch-N901.sh already exists' "$WORK/coll.err" && [ ! -s "$WORK/b3/launch-N901.sh" ] && ! ls "$WORK/b3"/*.md >/dev/null 2>&1 && pass "an existing launcher is refused before anything is written" || fail "launcher collision rc=$rc"

python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); d=dict(l[0]); d["label"]="N999"; d["keys"]=["HIMMEL-9999"]; l.append(d); json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/dupbr.json"
python3 "$SUT" "$WORK/dupbr.json" --base 4ccb59d --chief BZ --bucket "$WORK/b4" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/dupbr.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'duplicate worker branches' "$WORK/dupbr.err" && pass "two workers sharing a branch are refused" || fail "dup branch rc=$rc"

# The nonce <letter>-<label>-<hex> must stay inside the vault token grammar (1-3 upper-case letters, label N + 1-5 digits).
tok() { # <name> <stderr fragment> <gen-briefs args...>: refused, rc 1, nothing written
    local n="$1" frag="$2"; shift 2
    rm -rf "$WORK/bt-tok"
    python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --bucket "$WORK/bt-tok" --repo "$REPO" --handover-root /h --no-worktree "$@" >/dev/null 2>"$WORK/tok.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$frag" "$WORK/tok.err" && ! ls "$WORK/bt-tok"/* >/dev/null 2>&1; then pass "$n"; else fail "$n (rc=$rc, err: $(cat "$WORK/tok.err"))"; fi
}
tok "a 4-letter --letter is refused" "letter" --chief BZ --letter ABCD
tok "a lower-case --letter is refused" "letter" --chief BZ --letter bz
tok "an explicitly empty --letter is refused" "letter" --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --letter ""
tok "a letter derived from the chief name that is 4 letters long is refused" "letter" --chief HIMMEL-nextleg-2026-10-08ABCD-roadmap-chief
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --letter ABC --bucket "$WORK/bt-ok" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'ABC-N901-' "$WORK/bt-ok"/HIMMEL-9001-N901-*.md && pass "a 3-letter --letter is accepted and minted" || fail "3-letter letter rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["label"]="N123456"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lbl6.json"
python3 "$SUT" "$WORK/lbl6.json" --base 4ccb59d --chief BZ --bucket "$WORK/bt-lbl" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lbl6.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'label' "$WORK/lbl6.err" && pass "a 6-digit worker label is refused" || fail "6-digit label rc=$rc"

# A per-worker lane key is carried through and validated.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-ok.json"
lout="$(python3 "$SUT" "$WORK/lane-ok.json" --base 4ccb59d --chief BZ --bucket "$WORK/b5" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f5.json" 2>&1)"
has "a worker's lane key is printed as --lane" "$lout" "--lane claudex"
# The launcher itself carries the lane, so a claudex worker needs no hand edit that breaks the sidecar sha.
has "a claudex worker's launcher passes --lane claudex" "$(cat "$WORK/b5/launch-N901.sh")" "--lane claudex "
has "and its sidecar sha matches the launcher bytes" "$(cat "$WORK/f5.launchers.sha256" 2>/dev/null)" "$(sha_of "$WORK/b5/launch-N901.sh")  $WORK/b5/launch-N901.sh"
python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/b5n" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f5n.json" >/dev/null 2>&1; rc5n=$?
[ "$rc5n" -eq 0 ] && pass "a native worker's generation succeeds (HIMMEL-7811)" || fail "native worker generation exited $rc5n"
has "a native worker's launcher has an arm line to check" "$(grep 'headed-arm-worker.sh' "$WORK/b5n/launch-N901.sh" 2>/dev/null)" "headed-arm-worker.sh"
lacks "a native worker's arm line has no --lane (its manifest add line carries --lane native, HIMMEL-7811)" "$(grep 'headed-arm-worker.sh' "$WORK/b5n/launch-N901.sh")" "--lane"
has "and its sidecar sha matches the launcher bytes" "$(cat "$WORK/f5n.launchers.sha256" 2>/dev/null)" "$(sha_of "$WORK/b5n/launch-N901.sh")  $WORK/b5n/launch-N901.sh"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="Bad Lane"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-bad.json"
python3 "$SUT" "$WORK/lane-bad.json" --base 4ccb59d --chief BZ --bucket "$WORK/b6" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-bad.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-bad.err" && [ ! -e "$WORK/b6/launch-N901.sh" ] && pass "an invalid lane is refused before anything is written" || fail "bad lane rc=$rc"
# A non-string lane (a JSON number) is refused too, not a TypeError after the artifacts are written.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]=123; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-num.json"
python3 "$SUT" "$WORK/lane-num.json" --base 4ccb59d --chief BZ --bucket "$WORK/b7" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-num.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-num.err" && [ ! -e "$WORK/b7/launch-N901.sh" ] && pass "a numeric lane is refused before anything is written" || fail "numeric lane rc=$rc"
# A trailing newline is not a lowercase word: the whole value must match.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="native\n"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-nl.json"
python3 "$SUT" "$WORK/lane-nl.json" --base 4ccb59d --chief BZ --bucket "$WORK/b8" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/lane-nl.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-nl.err" && [ ! -e "$WORK/b8/launch-N901.sh" ] && pass "a lane with a trailing newline is refused" || fail "newline lane rc=$rc"

# an ab_arm key writes the brief ruling line, exports WORKER_SESSION_AUTOCOMPACT_AB in the launcher
# and passes --arm on the printed manifest add line; a bad value is refused; no key changes nothing.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="400k"; l[0]["profile"]="worker-docs"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ab-ok.json"
about="$(python3 "$SUT" "$WORK/ab-ok.json" --base 4ccb59d --chief BZ --bucket "$WORK/b9" --repo "$REPO" --handover-root /h --no-worktree --manifest "$WORK/f9.json" 2>&1)"
abdoc="$(cat "$WORK/b9/HIMMEL-9001-N901-plain-fix-"*.md 2>/dev/null)"
has "ab_arm 400k: the brief carries the ruling line" "$abdoc" "> **Context:** ab-400k — operator-ruling: HIMMEL-5193"
has "ab_arm 400k: the launcher exports WORKER_SESSION_AUTOCOMPACT_AB=400000" "$(cat "$WORK/b9/launch-N901.sh" 2>/dev/null)" "export WORKER_SESSION_AUTOCOMPACT_AB=400000"
has "ab_arm 400k: the manifest add line passes --arm 400k" "$about" "--arm 400k"
bash "$HERE/brief-lint.sh" "$WORK/b9/HIMMEL-9001-N901-plain-fix-"*.md 2>"$WORK/lint-ab.err"; rc=$?
[ "$rc" = 0 ] && pass "ab_arm brief passes brief-lint.sh" || fail "ab_arm brief-lint rc=$rc: $(cat "$WORK/lint-ab.err")"
lacks "no ab_arm: the plain brief has no Context line" "$b1" "operator-ruling: HIMMEL-5193"
lacks "no ab_arm: the plain launcher exports no arm" "$l1" "WORKER_SESSION_AUTOCOMPACT_AB"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="500k"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ab-bad.json"
python3 "$SUT" "$WORK/ab-bad.json" --base 4ccb59d --chief BZ --bucket "$WORK/b10" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ab-bad.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'ab_arm' "$WORK/ab-bad.err" && [ ! -e "$WORK/b10/launch-N901.sh" ] && pass "an invalid ab_arm is refused before anything is written" || fail "bad ab_arm rc=$rc"
# an A/B arm on a profile that gives a Sonnet launch its own ceiling is refused here, not printed as a launcher
# the wrapper would refuse; the same arm on a non-native lane (no Sonnet ceiling there) or on worker-docs is fine.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="200k"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ab-impl.json"
python3 "$SUT" "$WORK/ab-impl.json" --base 4ccb59d --chief BZ --bucket "$WORK/b10b" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ab-impl.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'Sonnet ceiling' "$WORK/ab-impl.err" && [ ! -e "$WORK/b10b/launch-N901.sh" ] && pass "an ab_arm on worker-impl with a Sonnet model is refused naming the Sonnet ceiling" || fail "ab_arm on worker-impl rc=$rc: $(cat "$WORK/ab-impl.err")"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="200k"; l[0]["profile"]="worker-eval"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ab-eval.json"
python3 "$SUT" "$WORK/ab-eval.json" --base 4ccb59d --chief BZ --bucket "$WORK/b10c" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ab-eval.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'Sonnet ceiling' "$WORK/ab-eval.err" && pass "an ab_arm on worker-eval with a Sonnet model is refused" || fail "ab_arm on worker-eval rc=$rc"

# an opus (or fable) worker needs a tier {category, reason}; without it nothing is
# written (exit 1), with it the brief carries the Tier line headed-arm-worker.sh's own gate accepts.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/opus-no.json"
python3 "$SUT" "$WORK/opus-no.json" --base 4ccb59d --chief BZ --bucket "$WORK/b11" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/opus-no.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier' "$WORK/opus-no.err" && [ ! -e "$WORK/b11/launch-N901.sh" ] && ! ls "$WORK/b11"/*.md >/dev/null 2>&1 && pass "an opus worker without a tier is refused and nothing is written" || fail "opus without tier rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"multi-step design: the gate shape is open"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/opus-ok.json"
python3 "$SUT" "$WORK/opus-ok.json" --base 4ccb59d --chief BZ --bucket "$WORK/b12" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/opus-ok.err"; rc=$?
[ "$rc" = 0 ] && pass "an opus worker with a tier generates (rc 0)" || fail "opus with tier rc=$rc: $(cat "$WORK/opus-ok.err")"
TD="$(find "$WORK/b12" -name 'HIMMEL-9001-N901-plain-fix-*.md' 2>/dev/null | head -n 1)"
has "the opus brief carries the Tier line" "$(cat "$TD" 2>/dev/null)" "> **Tier:** opus — design: multi-step design: the gate shape is open"
# the launcher's own gate is the check: a copy without resume_cwd (as in the arming row above) arms, not refused.
mkdir -p "$WORK/tier-arm"; sed "s|^resume_cwd:.*|resume_cwd: $WORK|" "$TD" > "$WORK/tier-arm/HIMMEL-9001-N901-copy.md"
rc=0; tier_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --profile worker-impl HIMMEL-9001-N901 "$WORK/tier-arm/HIMMEL-9001-N901-copy.md" "$WORK/tier-arm/signal" 9999999999 "$WORK/tier-arm/log" claude-opus-5-5 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "headed-arm-worker.sh's Tier gate accepts the generated opus brief" || fail "opus brief refused by headed-arm-worker.sh rc=$rc: $tier_out"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"cheap","reason":"x"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/tier-badcat.json"
python3 "$SUT" "$WORK/tier-badcat.json" --base 4ccb59d --chief BZ --bucket "$WORK/b13" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/tier-badcat.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.category' "$WORK/tier-badcat.err" && pass "a tier category outside the four tags is refused" || fail "bad tier category rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"  "}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/tier-blank.json"
python3 "$SUT" "$WORK/tier-blank.json" --base 4ccb59d --chief BZ --bucket "$WORK/b14" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/tier-blank.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.reason' "$WORK/tier-blank.err" && pass "a blank tier reason is refused" || fail "blank tier reason rc=$rc"
lacks "a sonnet worker's brief has no Tier line" "$b1" "**Tier:**"

# A lane worker (lane other than native or claudex) cannot read the state repo, so a worker whose
# text points at a path under the handover root is refused and nothing is written; a native or claudex worker may.
SPEC="$WORK/handovers/yotamleo/himmel/specs/plan/2026-08-10-plan.md"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="openrouter"; l[0]["model"]="claude-sonnet-5-5"; l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-spec.json" "$SPEC"
python3 "$SUT" "$WORK/lane-spec.json" --base 4ccb59d --chief BZ --bucket "$WORK/b15" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-spec.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'handover root' "$WORK/lane-spec.err" && [ ! -e "$WORK/b15/launch-N901.sh" ] && ! ls "$WORK/b15"/*.md >/dev/null 2>&1 && pass "a lane worker pointing at a handover-root path is refused and nothing is written" || fail "lane worker spec path rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="openrouter"; l[0]["model"]="claude-sonnet-5-5"; l[0]["tier"]={"category":"design","reason":"spec at "+sys.argv[3]}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-tier.json" "$SPEC"
python3 "$SUT" "$WORK/lane-tier.json" --base 4ccb59d --chief BZ --bucket "$WORK/b18" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-tier.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'tier.reason' "$WORK/lane-tier.err" && pass "a lane-worker tier.reason naming a handover-root path is refused" || fail "lane worker tier reason rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/native-spec.json" "$SPEC"
python3 "$SUT" "$WORK/native-spec.json" --base 4ccb59d --chief BZ --bucket "$WORK/b16" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/native-spec.err"; rc=$?
[ "$rc" = 0 ] && pass "a native worker may point at a handover-root path (rc 0)" || fail "native spec path rc=$rc: $(cat "$WORK/native-spec.err")"
# A claudex worker runs with the native worker-impl settings, the project's additionalDirectories and the qmd MCP config, so it reads the handover root too.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["why"]="Read this first - it is the spec: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/claudex-spec.json" "$SPEC"
python3 "$SUT" "$WORK/claudex-spec.json" --base 4ccb59d --chief BZ --bucket "$WORK/b19" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/claudex-spec.err"; rc=$?
[ "$rc" = 0 ] && grep -q -- "$SPEC" "$WORK/b19"/*.md 2>/dev/null && pass "a claudex worker may point at a handover-root path (rc 0, path kept in the brief)" || fail "claudex spec path rc=$rc: $(cat "$WORK/claudex-spec.err")"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-ok.json"
python3 "$SUT" "$WORK/lane-ok.json" --base 4ccb59d --chief BZ --bucket "$WORK/b17" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-ok.err"; rc=$?
[ "$rc" = 0 ] && pass "a lane worker with no handover-root path generates (rc 0)" || fail "lane worker clean rc=$rc: $(cat "$WORK/lane-ok.err")"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["lane"]="openrouter"; l[0]["model"]="claude-sonnet-5-5"; l[0]["writes"]=sys.argv[3]; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-writes.json" "$SPEC"
python3 "$SUT" "$WORK/lane-writes.json" --base 4ccb59d --chief BZ --bucket "$WORK/lane-writes" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-writes.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'handover root' "$WORK/lane-writes.err" && [ ! -e "$WORK/lane-writes/launch-N901.sh" ] && pass "the new writes field preserves the lane handover-root restriction" || fail "lane writes restriction rc=$rc"
# A non-native worker with no model key takes the lane's model: no native model argument in the launcher, the lane model in the brief header.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-nomodel.json"
python3 "$SUT" "$WORK/lane-nomodel.json" --base 4ccb59d --chief BZ --bucket "$WORK/b20" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-nomodel.err"; rc=$?
[ "$rc" = 0 ] && [ -s "$WORK/b20/launch-N901.sh" ] && [ -n "$(find "$WORK/b20" -name 'HIMMEL-9001-N901-*.md')" ] && pass "a claudex worker with no model key generates its brief and launcher (rc 0)" || fail "claudex no-model rc=$rc: $(cat "$WORK/lane-nomodel.err")"
# claudex is a live lane: nothing the generator writes or prints calls it dormant.
lacks "a claudex worker's brief carries no dormant text" "$(tr '[:upper:]' '[:lower:]' < "$(find "$WORK/b20" -name 'HIMMEL-9001-N901-*.md' | head -n 1)")" "dormant"
lacks "a claudex worker's launcher carries no dormant text" "$(tr '[:upper:]' '[:lower:]' < "$WORK/b20/launch-N901.sh")" "dormant"
lacks "a claudex worker's generation prints no dormant text" "$(tr '[:upper:]' '[:lower:]' < "$WORK/lane-nomodel.err")" "dormant"
lacks "a claudex worker with no model key passes no native model argument" "$(cat "$WORK/b20/launch-N901.sh")" "claude-sonnet-5-5"
lacks "a claudex worker with no model key leaves the lane default to headed-arm-worker" "$(cat "$WORK/b20/launch-N901.sh")" "gpt-6.1-sol"
has "its brief header names the lane model and the lane" "$(cat "$WORK/b20"/HIMMEL-9001-N901-*.md)" "gpt-6.1-sol, claudex"
# A claudex worker's named model is the launcher's trailing model argument, and headed-arm-worker.sh hands it to
# scripts/claude-codex as CODEX_MODEL: the launcher's own arguments, run as a dry run.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["model"]="gpt-6-astra"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-astra.json"
python3 "$SUT" "$WORK/lane-astra.json" --base 4ccb59d --chief BZ --bucket "$WORK/b20a" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>&1
has "a claudex worker with a model key passes it as the launcher's model argument" "$(grep -F headed-arm-worker.sh "$WORK/b20a/launch-N901.sh")" '.log" gpt-6-astra >'
mkdir -p "$WORK/astra-arm"; sed "s|^resume_cwd:.*|resume_cwd: $WORK|" "$(find "$WORK/b20a" -name 'HIMMEL-9001-N901-*.md' | head -n 1)" > "$WORK/astra-arm/HIMMEL-9001-N901-copy.md"
rc=0; astra_out="$(HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --lane claudex --profile worker-impl HIMMEL-9001-N901 "$WORK/astra-arm/HIMMEL-9001-N901-copy.md" "$WORK/astra-arm/signal" 9999999999 "$WORK/astra-arm/log" gpt-6-astra 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "the generated claudex brief arms with the named model" || fail "claudex brief refused by headed-arm-worker.sh rc=$rc: $astra_out"
has "and the named model reaches the worker as CODEX_MODEL" "$astra_out" "CODEX_MODEL=gpt-6-astra"
lacks "and the claudex launch prints no dormant warning" "$(printf '%s' "$astra_out" | tr '[:upper:]' '[:lower:]')" "dormant"
# An effort key exports WORKER_SESSION_EFFORT in the launcher.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["effort"]="high"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-effort.json"
python3 "$SUT" "$WORK/lane-effort.json" --base 4ccb59d --chief BZ --bucket "$WORK/b21" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>&1
has "an effort key exports WORKER_SESSION_EFFORT in the launcher" "$(cat "$WORK/b21/launch-N901.sh")" "export WORKER_SESSION_EFFORT=high"
# An opus model on a non-native lane is refused before anything is written.
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["model"]="claude-opus-5-5"; l[0]["tier"]={"category":"design","reason":"multi-step design"}; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lane-opus.json"
python3 "$SUT" "$WORK/lane-opus.json" --base 4ccb59d --chief BZ --bucket "$WORK/b22" --repo "$REPO" --handover-root "$WORK/handovers" --no-worktree >/dev/null 2>"$WORK/lane-opus.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'lane' "$WORK/lane-opus.err" && [ ! -e "$WORK/b22/launch-N901.sh" ] && pass "an opus model on a non-native lane is refused before anything is written" || fail "opus on claudex rc=$rc"

# The scope's LAST completes-ticket value becomes one dedicated machine-readable
# line (merge-on-green.sh reads it from the worker doc); a scope stating neither writes no line.
ct_brief() { # <scope text> <bucket>
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]=sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ct.json" "$1" || { fail "completes-ticket fixture setup failed"; return 1; }
    python3 "$SUT" "$WORK/ct.json" --base 4ccb59d --chief BZ --bucket "$2" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ct.err" || fail "completes-ticket scope generation rc=$?: $(cat "$WORK/ct.err")"
    cat "$2"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null
}
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["writes"]="scripts/wr/a.sh docs/writes-only.md"; l[0]["scope"]="scripts/wr-context/read.sh. Stay off scripts/lib/. completes-ticket: no"; l[0]["prior"]="HIMMEL-9000: docs/prior.md"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/wr.json"
python3 "$SUT" "$WORK/wr.json" --base 4ccb59d --chief BZ --bucket "$WORK/wr1" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/wr.err"; wr_rc=$?
[ "$wr_rc" = 0 ] && pass "explicit ticket Writes text generates" || fail "explicit Writes generation rc=$wr_rc: $(cat "$WORK/wr.err")"
wr_brief="$(cat "$WORK/wr1"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
wr_line="$(printf '%s\n' "$wr_brief" | grep '^> \*\*Writes:\*\* ')"
[ "$wr_line" = "> **Writes:** scripts/wr/a.sh docs/writes-only.md" ] && pass "Writes derives only from the ticket Writes text, never scope or prior (HIMMEL-7949)" || fail "Writes must use the explicit writes key only: $wr_line"
wr_note="$(printf '%s\n' "$wr_brief" | grep '^> \*\*Writes note:\*\* ')"
has "Writes note retains scope context" "$wr_note" "scripts/wr-context/read.sh"
has "Writes note retains stay-off paths" "$wr_note" "Stay off scripts/lib/"
has "Writes note retains prior art paths" "$wr_note" "docs/prior.md"
has "the original prior art field stays" "$wr_brief" "> **Prior art:** HIMMEL-9000: docs/prior.md"
has "the original scope field stays" "$wr_brief" "> **Scope / do not:** your Writes: scripts/wr-context/read.sh. Stay off scripts/lib/. completes-ticket: no"
lacks "the scope line no longer says a write onto another holder's file is denied" "$wr_brief" "A write onto a file another holder has is denied"
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the scope line says a free file outside Writes is claimed and recorded" "$wr_brief" 'a write onto a free file outside your Writes is claimed, recorded and named on your PR'"'"'s `outside-writes:` line for review'
lacks "the scope line no longer says writes are confined" "$wr_brief" "writes confined to"
lacks "the scope line no longer says stay off the other workers' files" "$wr_brief" "Stay off those"

cat > "$WORK/ov-gh.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "pr list" ] && [ -n "${OV_FIXTURE:-}" ] && { cat "$OV_FIXTURE"; exit 0; }
exit 1
EOF
chmod +x "$WORK/ov-gh.sh"
cat > "$WORK/ov-prs.json" <<'EOF'
[{"number":4242,"title":"outside fix","headRefName":"contrib/x","isCrossRepository":true,"files":[{"path":"scripts/wr/a.sh"},{"path":"docs/other.md"}]},
 {"number":4243,"title":"our fix","headRefName":"fix/himmel-1-y","isCrossRepository":false,"files":[{"path":"scripts/unrelated/z.sh"}]},
 {"number":4244,"title":"the worker's own PR","headRefName":"fix/himmel-9001-plain-fix","isCrossRepository":false,"files":[{"path":"scripts/wr/a.sh"}]}]
EOF
cat > "$WORK/ov-none.json" <<'EOF'
[{"number":4243,"title":"our fix","headRefName":"fix/himmel-1-y","isCrossRepository":false,"files":[{"path":"scripts/unrelated/z.sh"}]}]
EOF
ovgen() {
    OV_FIXTURE="$2" GEN_BRIEFS_GH_CMD="$1" python3 "$SUT" "$3" --base 4ccb59d --chief BZ --bucket "$4" --repo "$REPO" --handover-root /h --no-worktree >"$WORK/ov.out" 2>&1; OV_RC=$?
}
ovgen "$WORK/ov-gh.sh" "$WORK/ov-prs.json" "$WORK/wr.json" "$WORK/ov1"
[ "$OV_RC" = 0 ] && pass "a wave whose Writes overlap an open PR generates (rc 0)" || fail "overlap generation rc=$OV_RC: $(cat "$WORK/ov.out")"
OV1="$(cat "$WORK"/ov1/*-N901-plain-fix-*.md 2>/dev/null)"
has "the brief names the open PR that changes a Writes file" "$OV1" '> **Overlaps:** PR #4242'
has "an outside PR is marked as an outside contributor's" "$OV1" 'PR #4242 (outside contributor) also changes scripts/wr/a.sh'
has "the brief says to merge forward if they land first" "$OV1" 'Merge forward if they land first'
lacks "the Overlaps line names no PR that shares no Writes file" "$OV1" '#4243'
lacks "the Overlaps line names none of the worker's own PR" "$OV1" '#4244'
lacks "the brief no longer says a write onto a held file is denied" "$OV1" 'A write onto a file another holder has is denied'
has "the outside-writes sentence stays" "$OV1" "named on your PR's \`outside-writes:\` line for review"
bash "$HERE/brief-lint.sh" "$WORK"/ov1/*-N901-plain-fix-*.md 2>"$WORK/ovlint.err"; rc=$?
[ "$rc" = 0 ] && pass "a brief with an Overlaps line passes brief-lint.sh" || fail "overlaps brief-lint rc=$rc: $(cat "$WORK/ovlint.err")"
[ "$(printf '%s\n' "$OV1" | grep -c '^> \*\*Writes:\*\* ')" = 1 ] && pass "the Overlaps line adds no second Writes line" || fail "Writes line count changed"
ovgen "$WORK/ov-gh.sh" "" "$WORK/wr.json" "$WORK/ov2"
[ "$OV_RC" = 0 ] && pass "a failing gh does not stop generation (rc 0)" || fail "failing-gh generation rc=$OV_RC: $(cat "$WORK/ov.out")"
has "a failing gh gives unknown (gh failed)" "$(cat "$WORK"/ov2/*-N901-plain-fix-*.md 2>/dev/null)" 'Overlaps:** unknown (gh failed)'
ovgen "$WORK/ov-gh.sh" "$WORK/ov-none.json" "$WORK/wr.json" "$WORK/ov3"
[ "$OV_RC" = 0 ] && pass "a wave with no overlap generates (rc 0)" || fail "no-overlap generation rc=$OV_RC: $(cat "$WORK/ov.out")"
has "no overlap says none seen at launch" "$(cat "$WORK"/ov3/*-N901-plain-fix-*.md 2>/dev/null)" 'Overlaps:** none seen at launch'
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["writes"]="scripts/x/"; l[1]["writes"]="scripts/x/y.sh scripts/hooks/h.sh"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ov-wave.json"
cat > "$WORK/ov-dir.json" <<'EOF'
[{"number":4250,"title":"t","headRefName":"fix/a","isCrossRepository":false,"files":[{"path":"scripts/x/deep/q.sh"}]}]
EOF
ovgen "$WORK/ov-gh.sh" "$WORK/ov-dir.json" "$WORK/ov-wave.json" "$WORK/ov4"
[ "$OV_RC" = 0 ] && pass "a two-worker wave with a directory overlap generates (rc 0)" || fail "wave generation rc=$OV_RC: $(cat "$WORK/ov.out")"
OV4A="$(cat "$WORK"/ov4/*-N901-plain-fix-*.md 2>/dev/null)"
OV4B="$(cat "$WORK"/ov4/*-N902-hook-fix-*.md 2>/dev/null)"
has "a Writes directory matches a PR file under it" "$OV4A" 'PR #4250 also changes scripts/x/deep/q.sh'
has "a worker names the sibling that also writes under its directory" "$OV4A" 'worker N902 also writes scripts/x/y.sh'
has "the sibling names the first worker back" "$OV4B" 'worker N901 also writes scripts/x/y.sh'
lacks "the sibling with no PR overlap names no PR" "$OV4B" 'PR #4250'
ovgen "$WORK/ov-gh.sh" "" "$WORK/ov-wave.json" "$WORK/ov5"
[ "$OV_RC" = 0 ] && pass "a wave with a failing gh generates (rc 0)" || fail "wave failing-gh generation rc=$OV_RC: $(cat "$WORK/ov.out")"
OV5A="$(cat "$WORK"/ov5/*-N901-plain-fix-*.md 2>/dev/null)"
has "a failing gh still says unknown for the PRs" "$OV5A" 'Overlaps:** unknown (gh failed)'
has "a failing gh still names the wave sibling" "$OV5A" 'worker N902 also writes scripts/x/y.sh'
cat > "$WORK/ov-fork.json" <<'EOF'
[{"number":4260,"title":"fork","headRefName":"fix/himmel-9001-plain-fix","isCrossRepository":true,"files":[{"path":"scripts/wr/a.sh"}]}]
EOF
ovgen "$WORK/ov-gh.sh" "$WORK/ov-fork.json" "$WORK/wr.json" "$WORK/ov6"
has "a fork PR on the same branch name still counts as an overlap" "$(cat "$WORK"/ov6/*-N901-plain-fix-*.md 2>/dev/null)" 'PR #4260 (outside contributor) also changes scripts/wr/a.sh'
has "the brief carries the Conflicts resolved duty" "$OV1" '## Conflicts resolved'
has "the duty says to merge forward and never rebase" "$OV1" 'git merge origin/main'
lacks "the duty asks for no hand-written Results bullet" "$OV1" 'Append the same lines as one Results bullet'
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0].pop("writes",None); json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/wr-empty.json"
python3 "$SUT" "$WORK/wr-empty.json" --base 4ccb59d --chief BZ --bucket "$WORK/wr-empty" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/wr-empty.err"; wr_rc=$?
[ "$wr_rc" = 1 ] && grep -q "Writes" "$WORK/wr-empty.err" && ! find "$WORK/wr-empty" -name '*.md' 2>/dev/null | grep -q . && pass "missing writes is refused by the brief-lint run, never inferred holds, and no brief is kept" || fail "missing writes rc=$wr_rc: $(cat "$WORK/wr-empty.err")"
ct_count() { printf '%s\n' "$1" | grep -c '^> \*\*Completes ticket:\*\* '; }
ct_no="$(ct_brief 'one PR. completes-ticket: no' "$WORK/ct1")"
has "scope ending completes-ticket: no writes the no line" "$ct_no" "> **Completes ticket:** no"
[ "$(ct_count "$ct_no")" = 1 ] && pass "exactly one Completes ticket line (no)" || fail "Completes ticket line count (no) = $(ct_count "$ct_no")"
ct_yes="$(ct_brief 'one PR. completes-ticket: yes' "$WORK/ct2")"
has "scope ending completes-ticket: yes writes the yes line" "$ct_yes" "> **Completes ticket:** yes"
[ "$(ct_count "$ct_yes")" = 1 ] && pass "exactly one Completes ticket line (yes)" || fail "Completes ticket line count (yes) = $(ct_count "$ct_yes")"
ct_last="$(ct_brief 'completes-ticket: yes in the middle, but later completes-ticket: no' "$WORK/ct3")"
has "the LAST completes-ticket value wins" "$ct_last" "> **Completes ticket:** no"
lacks "an earlier, overridden value writes no yes line" "$ct_last" "> **Completes ticket:** yes"
ct_none="$(ct_brief 'one PR, nothing stated' "$WORK/ct4")"
[ "$(ct_count "$ct_none")" = 0 ] && pass "a scope stating neither writes no Completes ticket line" || fail "Completes ticket line written without a stated value"
# The Ship step states the same value and the matching merge command (one value per brief).
lacks "a completes-ticket: no brief states no 'completes-ticket: yes' anywhere" "$ct_no" "completes-ticket: yes"
ship_no="$(printf '%s\n' "$ct_no" | grep '^> 4\. Ship:')"
lacks "a completes-ticket: no Ship step has no --jira-transition" "$ship_no" "--jira-transition"
has "a completes-ticket: no Ship step merges bare" "$ship_no" 'merge-on-green.sh`'
has "a completes-ticket: no Ship step leaves the ticket In Progress" "$ship_no" "In Progress"
ship_yes="$(printf '%s\n' "$ct_yes" | grep '^> 4\. Ship:')"
has "a completes-ticket: yes Ship step keeps --jira-transition" "$ship_yes" "merge-on-green.sh --jira-transition"
has "a completes-ticket: yes Ship step states yes" "$ship_yes" "completes-ticket: yes"
ship_last="$(printf '%s\n' "$ct_last" | grep '^> 4\. Ship:')"
lacks "the LAST value (no) also drives the Ship step" "$ship_last" "--jira-transition"
has "the LAST value (no) writes the bare-merge Ship wording" "$ship_last" "completes-ticket: no (leave the ticket In Progress after the merge)"
ship_none="$(printf '%s\n' "$ct_none" | grep '^> 4\. Ship:')"
has "a scope stating neither keeps the yes Ship step" "$ship_none" "merge-on-green.sh --jira-transition"
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the yes Ship step names the relative merge spelling" "$ship_yes" '`bash scripts/handover/merge-on-green.sh --jira-transition`'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the no Ship step names the relative merge spelling" "$ship_no" '`bash scripts/handover/merge-on-green.sh`'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the yes Ship step ends the merge with the --go GO file" "$ship_yes" 'then `--go <the GO file'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "the no Ship step ends the merge with the --go GO file" "$ship_no" 'then `--go <the GO file'
# A claudex worker's classifier refuses merge-path actions, so its Ship step ends at READY: no
# merge command anywhere in the brief, the chief is named as the merger, and the worker waits
# for MERGED. A native worker of the same scope keeps the merge step (asserted above).
cx_brief() { # <completes value> <bucket>
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]="claudex"; l[0]["scope"]="one PR. completes-ticket: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/cx.json" "$1" || { fail "claudex ship fixture setup failed"; return 1; }
    python3 "$SUT" "$WORK/cx.json" --base 4ccb59d --chief BZ --bucket "$2" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/cx.err" || fail "claudex ship generation rc=$?: $(cat "$WORK/cx.err")"
    cat "$2"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null
}
cx_no="$(cx_brief no "$WORK/cx1")"
ship_cx="$(printf '%s\n' "$cx_no" | grep '^> 4\. Ship:')"
lacks "a claudex Ship step has no merge-on-green.sh" "$ship_cx" "merge-on-green.sh"
lacks "a claudex Ship step has no merge-on-GO clause" "$ship_cx" "Merge only on GO"
has "a claudex Ship step names the chief as the merger" "$ship_cx" "the chief merges"
has "a claudex Ship step waits for MERGED" "$ship_cx" "MERGED #<pr>"
has "a claudex Ship step still ends at READY" "$ship_cx" 'READY <pr> <full-40-hex-head> GREEN'
has "a claudex completes-ticket: no Ship step keeps the clause" "$ship_cx" "completes-ticket: no"
lacks "the claudex brief carries no merge-on-green.sh anywhere" "$cx_no" "merge-on-green.sh"
cx_yes="$(cx_brief yes "$WORK/cx2")"
ship_cxy="$(printf '%s\n' "$cx_yes" | grep '^> 4\. Ship:')"
lacks "a claudex completes-ticket: yes Ship step has no merge-on-green.sh" "$ship_cxy" "merge-on-green.sh"
has "a claudex completes-ticket: yes Ship step keeps the clause" "$ship_cxy" "completes-ticket: yes"
bash "$HERE/brief-lint.sh" "$WORK"/cx1/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-cx.err"; rc=$?
[ "$rc" = 0 ] && pass "a claudex brief with the chief-merges Ship step passes brief-lint.sh" || fail "claudex brief-lint rc=$rc: $(cat "$WORK/lint-cx.err")"
bash "$HERE/brief-lint.sh" "$WORK"/ct1/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-ct.err"; rc=$?
[ "$rc" = 0 ] && pass "a brief with the Completes ticket line passes brief-lint.sh" || fail "Completes ticket brief-lint rc=$rc: $(cat "$WORK/lint-ct.err")"

# READY is a bullet only and the merge is no message, on every lane.
lane_brief() { # <lane> <completes value> <bucket>
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["lane"]=sys.argv[3]; l[0]["scope"]="one PR. completes-ticket: "+sys.argv[4]
if sys.argv[3] not in ("native","claudex"): l[0]["model"]="claude-sonnet-5-5"
json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ln.json" "$1" "$2" || { fail "lane brief fixture setup failed"; return 1; }
    python3 "$SUT" "$WORK/ln.json" --base 4ccb59d --chief BZ --bucket "$3" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ln.err" || fail "lane brief generation rc=$?: $(cat "$WORK/ln.err")"
    cat "$3"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null
}
bullet_rows() { # <label> <ship line> <expect no MERGED step: 1|0> <expect no second-key: 1|0>
    local ship="$2"
    [ -n "$ship" ] && pass "$1: brief has a Ship step" || fail "$1: brief has no Ship step"
    lacks "$1: no READY message" "$ship" "to the chief quoting your token"
    # shellcheck disable=SC2016 # literal backticks in the expected brief text
    [ "$3" = 1 ] && lacks "$1: no MERGED step" "$ship" 'MERGED, `cd` out'
    [ "$4" = 1 ] && lacks "$1: no second-key message" "$ship" "say so after MERGED"
    has "$1: READY bullet named" "$ship" "never a message"
}
ship_ln_n="$(lane_brief native yes "$WORK/ln1" | grep '^> 4\. Ship:')"
bullet_rows "native yes" "$ship_ln_n" 1 1
ship_ln_nn="$(lane_brief native no "$WORK/ln2" | grep '^> 4\. Ship:')"
bullet_rows "native no" "$ship_ln_nn" 1 0
ship_ln_c="$(lane_brief claudex yes "$WORK/ln3" | grep '^> 4\. Ship:')"
bullet_rows "claudex yes" "$ship_ln_c" 0 1
# shellcheck disable=SC2016 # literal text in the expected brief
has "claudex: chief's MERGED message kept" "$ship_ln_c" 'MERGED #<pr> → <sha>'
ship_ln_o="$(lane_brief openrouter yes "$WORK/ln4" | grep '^> 4\. Ship:')"
bullet_rows "openrouter yes" "$ship_ln_o" 1 1
pre=$(grep -n 'READY <pr> <full head> GREEN' "$HERE/../../../docs/handover/worker-preface.md")
pb=0
for t in "$pre" "$ship_ln_n"; do
    case "$t" in *"never a message"*"bullet"*|*"bullet"*"never a message"*) pb=$((pb + 1)) ;; esac
done
[ "$pb" = 2 ] && pass "preface and brief agree: READY never a message" || fail "preface and brief agree: READY never a message (both must say bullet and never a message; $pb of 2 do)"

# JUDGE-REQUEST has one channel per lane, and the worker docs point at it.
hd="$HERE/../../../docs/handover"
grep 'JUDGE-REQUEST' "$hd/worker-preface.md" | grep -qF 'worker-sections/judge-request.md' && pass "preface: JUDGE-REQUEST points at its section" || fail "preface: JUDGE-REQUEST does not point at worker-sections/judge-request.md"
jr="$hd/worker-sections/judge-request.md"
jrok=0; [ -r "$jr" ] && jrok=1
for w in 'SendMessage' 'send' 'at READY' 'once per head'; do
    [ -r "$jr" ] && grep -qF -- "$w" "$jr" || jrok=0
done
[ "$jrok" = 1 ] && pass "judge-request section: channel per lane" || fail "judge-request section: missing or lacks SendMessage, send, at READY, once per head"
for l in claudex openrouter; do
    grep 'JUDGE-REQUEST' "$hd/worker-preface-$l.md" | grep -qF 'send' && pass "$l preface: JUDGE-REQUEST on the bus" || fail "$l preface: JUDGE-REQUEST not on the bus"
done
# The claudex "Only ... go by bus" list must itself name JUDGE-REQUEST (it spans two lines).
only="$(tr '\n' ' ' < "$hd/worker-preface-claudex.md" | grep -oE 'Only `[^.]*go by bus' | head -1)"
case "$only" in *'JUDGE-REQUEST'*) pass "claudex preface: the Only-by-bus list names JUDGE-REQUEST" ;; *) fail "claudex preface: the Only-by-bus list omits JUDGE-REQUEST ($only)" ;; esac
# The chief's READY fallback: a READY whose head has no judge dispatches one before any GO.
grep -qF 'dispatch the judge now, before any GO' "$hd/chief-sections/merges.md" && pass "merges: READY fallback dispatches the judge" || fail "merges: READY fallback does not say to dispatch the judge now, before any GO"

# A completes-ticket value other than yes or no is refused (it used to fall through to the closing
# merge): nothing is written, and the message names the worker label and the value. Case is ignored.
# shellcheck disable=SC2016  # the backticks are literal characters in the value under test
for bad in partial maybe yess '"no"' '`yes`'; do
    rm -rf "$WORK/ctb-out"
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]="one PR. completes-ticket: "+sys.argv[3]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ctb.json" "$bad"
    python3 "$SUT" "$WORK/ctb.json" --base 4ccb59d --chief BZ --bucket "$WORK/ctb-out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ctb.err"; rc=$?
    [ "$rc" = 1 ] && grep -q "N901" "$WORK/ctb.err" && grep -qF -- "$bad" "$WORK/ctb.err" && pass "completes-ticket: $bad is refused naming the worker and the value" || fail "completes-ticket: $bad rc=$rc: $(cat "$WORK/ctb.err")"
    [ ! -e "$WORK/ctb-out/launch-N901.sh" ] && ! ls "$WORK/ctb-out"/*.md >/dev/null 2>&1 && pass "and nothing is written for $bad" || fail "files written for completes-ticket: $bad"
done
ct_mixed="$(ct_brief 'one PR. completes-ticket: YES' "$WORK/ct5")"
has "an upper-case YES still writes the yes line" "$ct_mixed" "> **Completes ticket:** yes"
ct_mixed="$(ct_brief 'one PR. completes-ticket: No' "$WORK/ct6")"
has "a mixed-case No still writes the no line" "$ct_mixed" "> **Completes ticket:** no"
ct_nl="$(ct_brief "one PR. completes-ticket:
no" "$WORK/ct7")"
has "a value on the next line is read, not refused as empty" "$ct_nl" "> **Completes ticket:** no"
# A bad value earlier in the scope is refused even when a good one comes last.
rm -rf "$WORK/ctb-early"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["scope"]="completes-ticket: partial, later completes-ticket: no"; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ctb.json"
python3 "$SUT" "$WORK/ctb.json" --base 4ccb59d --chief BZ --bucket "$WORK/ctb-early" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ctb.err"; rc=$?
[ "$rc" = 1 ] && pass "an earlier bad value is refused even when the last value is no" || fail "early bad value rc=$rc"

# Windows and WSL are dropped: a worker whose title, desc, why or scope names them is refused (rc 1,
# nothing written) unless it sets platform_removal AND its title says it removes something.
# pl_gen <title> <field> <value> [platform_removal]: one worker with <field> set to <value>.
pl_gen() {
    rm -rf "$WORK/pl-out"
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0][sys.argv[3]]=sys.argv[4]
if len(sys.argv)>5: l[0]["platform_removal"]=True if sys.argv[5]=="yes" else sys.argv[5]
json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/pl.json" "$@"
    python3 "$SUT" "$WORK/pl.json" --base 4ccb59d --chief BZ --bucket "$WORK/pl-out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pl.err"
}
pl_written() { [ -n "$(find "$WORK/pl-out" -type f -print -quit 2>/dev/null)" ]; }
pl_complete() { ls "$WORK/pl-out"/*.md >/dev/null 2>&1 && ls "$WORK/pl-out"/launch-*.sh >/dev/null 2>&1; }
pl_gen title 'AG-UI session name handles Windows cwd separators'; rc=$?
[ "$rc" = 1 ] && grep -q "N901" "$WORK/pl.err" && grep -qi "windows" "$WORK/pl.err" && ! pl_written && pass "a worker titled with Windows is refused, naming the worker, nothing written" || fail "windows title rc=$rc: $(cat "$WORK/pl.err")"
pl_gen desc 'run the WSL codex lane'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a desc naming WSL is refused" || fail "wsl desc rc=$rc"
pl_gen scope 'the .ps1 twin'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a scope naming a .ps1 file is refused" || fail "ps1 scope rc=$rc"
pl_gen writes 'scripts/old.ps1'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "the new writes field preserves the dropped-platform restriction" || fail "ps1 writes rc=$rc"
pl_gen why 'it breaks under Git Bash'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "a why naming Git Bash is refused" || fail "git bash why rc=$rc"
pl_gen title 'Remove Windows leftovers' yes; rc=$?
[ "$rc" = 0 ] && pl_complete && pass "a Windows removal worker with platform_removal true is accepted" || fail "removal worker rc=$rc: $(cat "$WORK/pl.err")"
pl_gen title 'Fix Windows leftovers' yes; rc=$?
[ "$rc" = 1 ] && grep -q "platform_removal" "$WORK/pl.err" && ! pl_written && pass "platform_removal true on a non-removal title is refused" || fail "non-removal platform_removal rc=$rc: $(cat "$WORK/pl.err")"
for bad in false yes 1; do
    pl_gen title 'Remove Windows leftovers' "$bad"; rc=$?
    case "$bad" in yes) want=0 ;; *) want=1 ;; esac
    [ "$rc" = "$want" ] && pass "platform_removal $bad on a removal title exits $want (only boolean true is the exemption)" || fail "platform_removal $bad rc=$rc"
done
for bad in 'Fix Windows dropdown rendering' 'Fix the Windows cleanroom'; do
    pl_gen title "$bad" yes; rc=$?
    [ "$rc" = 1 ] && ! pl_written && pass "platform_removal true on '$bad' is refused (no removal verb)" || fail "'$bad' with platform_removal rc=$rc"
done
for good in 'Drop Windows support' 'Sweep Windows leftovers' 'Retire the WSL lane' 'Delete the .ps1 twins' 'Clean up Windows paths' 'Removing Windows code'; do
    pl_gen title "$good" yes; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "platform_removal true on '$good' is accepted" || fail "'$good' with platform_removal rc=$rc: $(cat "$WORK/pl.err")"
done
for ok in 'Close WRAPPED chief windows' 'Stop worker windows piling up' 'Spread work over 5-hour windows' 'Trim the context-windows report'; do
    pl_gen title "$ok"; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "'$ok' is chief wording, not the OS" || fail "'$ok' refused rc=$rc: $(cat "$WORK/pl.err")"
done
# Fail closed: with the pattern file gone the script exits 2 rather than briefing unfiltered.
NF="$WORK/nopat"; mkdir -p "$NF"; cp "$SUT" "$NF/gen-briefs.py"; cp "$HERE/salus_marked.py" "$HERE/holds.py" "$NF/"
python3 "$NF/gen-briefs.py" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$NF/out" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "a missing pattern file exits 2" || fail "missing pattern file rc=$rc"
pl_gen title 'Remove runtime Windows compatibility'; rc=$?
[ "$rc" = 1 ] && ! pl_written && pass "'runtime Windows' is not excused by the time-window qualifier" || fail "runtime Windows rc=$rc"
for ok in 'cap the context window' 'widen the time window' 'Windowed rate limit' 'the context windows budget'; do
    pl_gen title "$ok"; rc=$?
    [ "$rc" = 0 ] && pl_complete && pass "'$ok' is not a platform mention" || fail "'$ok' refused rc=$rc: $(cat "$WORK/pl.err")"
done

# Every worker and chief pays these two files on every turn: keep the always-on core small
# (rarely-read rules live in docs/handover/worker-sections/ and chief-sections/).
HANDOVER_DOCS="${HANDOVER_DOCS:-$HERE/../../../docs/handover}"
# worker-preface.md carries the adapter-repo stop-at-READY rule, so its budget is 12800.
# chief-template.md carries the AG-UI board pointer in step 12 and the item 19 suite-evidence
# note, so its budget is 17400; worker-preface.md's 12800 was raised to 12900 for the same change,
# and to 13100 for the write-barrier bullet. chief-template.md's was raised to 18000 for the
# two lines that make a chief read the direction companion files in its first batch.
for budget in "worker-preface.md:13300" "chief-template.md:18000"; do
    f="${budget%%:*}"; max="${budget##*:}"
    size="$(wc -c < "$HANDOVER_DOCS/$f" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$size" ] && [ "$size" -le "$max" ] && pass "$f is within its byte budget ($size <= $max)" || fail "$f is over its byte budget (${size:-missing} > $max)"
done

tr '\n' ' ' < "$HANDOVER_DOCS/worker-preface.md" | grep -Eq 'ONE +turn.*text-only turn' \
    && pass "worker-preface.md tells a worker to batch tool calls into ONE turn and skip text-only turns" \
    || fail "worker-preface.md lacks the batch-tool-calls / no text-only turn rule"

# The renamed templates are regular files and the old paths are gone.
for pair in leg-preface.md:worker-preface.md console-template.md:chief-template.md leg-brief-template.md:worker-brief-template.md; do
    old="${pair%%:*}"; new="${pair##*:}"
    [ -f "$HANDOVER_DOCS/$new" ] && [ ! -L "$HANDOVER_DOCS/$new" ] && pass "$new is a regular file" || fail "$new is missing or not a regular file"
    [ ! -e "$HANDOVER_DOCS/$old" ] && [ ! -L "$HANDOVER_DOCS/$old" ] && pass "$old is gone" || fail "$old still exists"
done
# A worker launched through the launcher's default preface path (the plain
# worker branch, last of the role defaults) gets the worker preface.
# shellcheck disable=SC2016  # $HERE is the launcher's literal text, matched not expanded
launch_preface="$(sed -n 's#.*PREFACE:-\$HERE/../../../\(docs/handover/[a-z-]*\.md\)}.*#\1#p' "$HERE/headed-arm-worker.sh" | tail -n 1)"
[ -n "$launch_preface" ] && cmp -s "$HERE/../../../$launch_preface" "$HANDOVER_DOCS/worker-preface.md" \
    && pass "the launcher's default preface ($launch_preface) is the worker preface, byte for byte" \
    || fail "the launcher's default preface (${launch_preface:-unparsed}) is not the worker preface"

# --- bare --bucket resolves under the handover root; --no-worktree needs a real worktree ---
# (the rows above stub the worktree step, so they skip the existing-worktree check)
mkdir -p "$WORK/hr/tester" "$WORK/gitcwd"
git -C "$WORK/gitcwd" init -q 2>/dev/null
rc=0; (cd "$WORK/gitcwd" && USER_SLUG=tester python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket himmel --repo "$REPO" --handover-root "$WORK/hr" --no-worktree --manifest "$WORK/fb.json" >"$WORK/bb.out" 2>"$WORK/bb.err") || rc=$?
[ "$rc" = 0 ] && [ -f "$WORK/hr/tester/himmel/launch-N901.sh" ] && pass "a bare --bucket resolves to <handover-root>/<user>/<bucket>" || fail "bare bucket rc=$rc: $(cat "$WORK/bb.err")"
[ ! -e "$WORK/gitcwd/himmel" ] && pass "and writes no stray dir under the cwd" || fail "stray himmel/ dir under the cwd"
grep -q -- "$WORK/hr/tester/himmel/HIMMEL-9001-N901" "$WORK/hr/tester/himmel/launch-N901.sh" 2>/dev/null && pass "the launcher passes an absolute doc path" || fail "launcher doc path not absolute"
rc=0; (cd "$WORK" && python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket ./gitcwd/rel --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >"$WORK/rel.out" 2>"$WORK/rel.err") || rc=$?
[ "$rc" = 1 ] && grep -q 'inside a git checkout' "$WORK/rel.err" && [ ! -e "$WORK/gitcwd/rel" ] && pass "a path --bucket inside a git checkout (outside the handover root) is refused" || fail "git-checkout bucket rc=$rc: $(cat "$WORK/rel.err")"
ln -s "$WORK/gitcwd" "$WORK/hr/tester/link"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/hr/tester/link/sub" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/lnk.err" || rc=$?
[ "$rc" = 1 ] && grep -q 'inside a git checkout' "$WORK/lnk.err" && [ ! -e "$WORK/gitcwd/sub" ] && pass "a bucket under a handover-root symlink into a git checkout is refused" || fail "symlink bucket rc=$rc: $(cat "$WORK/lnk.err")"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/hr/tester/abs" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "RED control: an absolute --bucket works unchanged" || fail "absolute bucket rc=$rc"
rc=0; (unset GEN_BRIEFS_NO_WT_CHECK; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/nw" --repo "$REPO" --handover-root "$WORK/hr" --no-worktree >"$WORK/nw.out" 2>"$WORK/nw.err") || rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/nw/launch-N901.sh" ] && pass "--no-worktree with a missing worktree exits 1 and writes nothing" || fail "no-worktree rc=$rc"
has "and prints the exact worktree.sh line" "$(cat "$WORK/nw.err")" "bash scripts/worktree.sh new fix/himmel-9001-plain-fix --no-prune"
NWREPO="$WORK/nwrepo"; git init -q "$NWREPO" && git -C "$NWREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$NWREPO" worktree add -q "$NWREPO/.claude/worktrees/fix+himmel-9001-plain-fix" -b fix/himmel-9001-plain-fix 2>/dev/null
git -C "$NWREPO" worktree add -q "$NWREPO/.claude/worktrees/fix+himmel-9002-hook-fix" -b fix/himmel-9002-hook-fix 2>/dev/null
rc=0; (unset GEN_BRIEFS_NO_WT_CHECK; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/hr/tester/nw2" --repo "$NWREPO" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/nw2.err") || rc=$?
[ "$rc" = 0 ] && pass "RED control: --no-worktree with existing worktrees works unchanged" || fail "existing worktrees rc=$rc: $(cat "$WORK/nw2.err")"

# --- an adopted repo (a git checkout with no chief-kit of its own): the worktree is made by
# himmel's _new-worktree.sh run inside the adopter, and the launcher names himmel's kit and exports the
# adopter worktree as WORKER_SESSION_REPO (headed-arm.sh starts the session in that dir) ---
KIT="$WORK/kit"; mkdir -p "$KIT/scripts/handover/chief-kit"
mkdir -p "$KIT/scripts/ci"
cp "$SUT" "$HERE/salus_marked.py" "$HERE/holds.py" "$HERE/platform-dropped.re" "$HERE/size-override.sh" "$KIT/scripts/handover/chief-kit/"
cp "$HERE/../../ci/ci-trust-paths.txt" "$HERE/../../ci/pr-size-bands.tsv" "$KIT/scripts/ci/"
mkdir -p "$KIT/scripts/lib"; cp "$HERE/../../lib/flags.py" "$HERE/../../lib/flags.tsv" "$HERE/../../lib/go-gate.sh" "$HERE/../../lib/handover-path.sh" "$KIT/scripts/lib/"
cp "$HERE/brief-lint.sh" "$KIT/scripts/handover/chief-kit/"; cp -R "$HERE/../../lib/." "$KIT/scripts/lib/"
export ADP_WT_LOG="$WORK/adp-wt.log"
cat > "$KIT/scripts/_new-worktree.sh" <<'EOF'
#!/usr/bin/env bash
[ "$2" = --no-install ] || { echo "_new-worktree.sh stub: unexpected 2nd argument [$2]" >&2; exit 64; }
printf '%s|%s|%s\n' "$PWD" "$1" "$2" >> "$ADP_WT_LOG"
git worktree add -q "$PWD/.claude/worktrees/${1//\//+}" -b "$1"
EOF
ADP="$WORK/adapter"; git init -q "$ADP" && git -C "$ADP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
ADPBASE="$(git -C "$ADP" rev-parse HEAD)"
rc=0; env -u GEN_BRIEFS_WORKTREE_CMD python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/adp" --repo "$ADP" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 --manifest "$WORK/adp.fleet.json" >"$WORK/adp.out" 2>"$WORK/adp.err" || rc=$?
[ "$rc" = 0 ] && pass "an adopted repo generates (rc 0)" || fail "adopted repo rc=$rc: $(cat "$WORK/adp.err") $(cat "$WORK/adp.out")"
has "the adopter worktree is made by himmel's _new-worktree.sh run inside the adopter, without the install step" "$(cat "$WORK/adp-wt.log" 2>/dev/null)" "$ADP|fix/himmel-9001-plain-fix|--no-install"
has "and so is the second worker's" "$(cat "$WORK/adp-wt.log" 2>/dev/null)" "$ADP|fix/himmel-9002-hook-fix|--no-install"
al="$(cat "$WORK/hr/tester/adp/launch-N901.sh" 2>/dev/null)"
has "the adopter launcher names himmel's headed-arm-worker.sh" "$al" "$KIT/scripts/handover/chief-kit/headed-arm-worker.sh --profile worker-impl"
lacks "and not a copy under the adopter" "$al" "$ADP/scripts/handover/chief-kit/"
has "the adopter launcher exports the adopter worktree as WORKER_SESSION_REPO" "$al" "export WORKER_SESSION_REPO=$ADP/.claude/worktrees/fix+himmel-9001-plain-fix"
has "the adopter launcher's manifest add uses himmel's fleet-manifest.sh" "$al" "$KIT/scripts/handover/chief-kit/fleet-manifest.sh add"
has "the adopter brief's ticket-read line uses himmel's jira CLI" "$(cat "$WORK"/hr/tester/adp/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)" "node $KIT/scripts/jira/dist/index.js get HIMMEL-9001"
lacks "RED control: a himmel-repo launcher exports no WORKER_SESSION_REPO" "$l1" "WORKER_SESSION_REPO"
AB="$(tr '\n' ' ' < "$WORK"/hr/tester/adp/HIMMEL-9001-N901-plain-fix-*.md | tr -s ' ')"
has "the adopter brief searches luna" "$AB" 'query -c luna "a plain fix"'
has "the adopter brief says it has no Jira mirror" "$AB" "no Jira mirror"
has "the adopter brief says it has no graph lookup" "$AB" "no graph lookup"
lacks "the adopter brief names no jira-himmel search" "$AB" "-c jira-himmel"
lacks "the adopter brief names no worker-graph lookup" "$AB" "worker-graph.sh"
bash "$HERE/brief-lint.sh" "$WORK"/hr/tester/adp/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-adp.err"; rc=$?
[ "$rc" = 0 ] && pass "the adopter brief passes brief-lint.sh" || fail "adopter brief brief-lint rc=$rc: $(cat "$WORK/lint-adp.err")"
# A salus-marked repo (a .salus marker, or a phi-roots entry) searches nothing: a query would send the ticket title off the machine.
SAL="$WORK/salus-repo"; git init -q "$SAL"; : > "$SAL/.salus"
rc=0; GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh" GEN_BRIEFS_NO_WT_CHECK=1 python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/sal" --repo "$SAL" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >"$WORK/sal.out" 2>"$WORK/sal.err" || rc=$?
[ "$rc" = 0 ] && pass "a .salus-marked repo generates (rc 0)" || fail "salus repo rc=$rc: $(cat "$WORK/sal.err")"
SB="$(tr '\n' ' ' < "$WORK"/hr/tester/sal/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null | tr -s ' ')"
lacks "the salus brief names no luna search" "$SB" "query -c luna"
lacks "the salus brief names no jira-himmel search" "$SB" "-c jira-himmel"
lacks "the salus brief names no worker-graph lookup" "$SB" "worker-graph.sh"
has "the salus brief says in words that it searches nothing" "$SB" "no notes search"
bash "$HERE/brief-lint.sh" "$WORK"/hr/tester/sal/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-sal.err"; rc=$?
[ "$rc" = 0 ] && pass "the salus brief passes brief-lint.sh" || fail "salus brief brief-lint rc=$rc: $(cat "$WORK/lint-sal.err")"
PHI="$WORK/phi-repo"; git init -q "$PHI"; mkdir -p "$WORK/home/.config/claude-codex"; printf '%s\n' "$PHI" > "$WORK/home/.config/claude-codex/phi-roots"
rc=0; HOME="$WORK/home" GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh" GEN_BRIEFS_NO_WT_CHECK=1 python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/phi" --repo "$PHI" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >"$WORK/phi.out" 2>"$WORK/phi.err" || rc=$?
PB="$(tr '\n' ' ' < "$WORK"/hr/tester/phi/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
has "a phi-roots repo says it searches nothing" "$PB" "no notes search"
lacks "and names no luna search" "$PB" "query -c luna"
WTR="$WORK/wt-marked-repo"; git init -q "$WTR"; mkdir -p "$WTR/.claude/worktrees/fix+himmel-9001-plain-fix"; : > "$WTR/.claude/worktrees/fix+himmel-9001-plain-fix/.salus"
rc=0; GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh" GEN_BRIEFS_NO_WT_CHECK=1 python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/wtm" --repo "$WTR" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >"$WORK/wtm.out" 2>"$WORK/wtm.err" || rc=$?
has "a marker on the worker's own worktree (the repo unmarked) makes that worker's brief search nothing" "$(tr '\n' ' ' < "$WORK"/hr/tester/wtm/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)" "no notes search"
DEN="$WORK/deny-repo"; git init -q "$DEN"; mkdir -p "$WORK/home2/.config/claude-glm"; printf '%s\n' "$DEN" > "$WORK/home2/.config/claude-glm/egress-denylist"
rc=0; HOME="$WORK/home2" GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh" GEN_BRIEFS_NO_WT_CHECK=1 python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/den" --repo "$DEN" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >"$WORK/den.out" 2>"$WORK/den.err" || rc=$?
has "an egress-denylist repo says it searches nothing" "$(tr '\n' ' ' < "$WORK"/hr/tester/den/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)" "no notes search"
# The generator and the lint share one classifier, so they agree on a linked worktree outside a marked primary and on a repo that holds a listed root.
GPR="$WORK/marked-primary"; git init -q "$GPR"; : > "$GPR/.salus"; git -C "$GPR" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$GPR" worktree add -q "$WORK/outside-wt" -b outside-wt
rc=0; GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh" GEN_BRIEFS_NO_WT_CHECK=1 python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/owt" --repo "$WORK/outside-wt" --handover-root "$WORK/hr" >/dev/null 2>"$WORK/owt.err" || rc=$?
OB="$(tr '\n' ' ' < "$WORK"/hr/tester/owt/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
has "a linked worktree outside a marked primary: the brief says it searches nothing" "$OB" "no notes search"
lacks "and names no luna search" "$OB" "query -c luna"
bash "$HERE/brief-lint.sh" "$WORK"/hr/tester/owt/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-owt.err"; rc=$?
[ "$rc" = 0 ] && pass "and the lint agrees (passes it)" || fail "outside-worktree brief brief-lint rc=$rc: $(cat "$WORK/lint-owt.err")"
HLR="$WORK/holds-root"; git init -q "$HLR"; mkdir -p "$HLR/vault" "$WORK/home3/.config/claude-codex"; printf '%s\n' "$HLR/vault" > "$WORK/home3/.config/claude-codex/phi-roots"
rc=0; HOME="$WORK/home3" GEN_BRIEFS_WORKTREE_CMD="$WORK/wt.sh" GEN_BRIEFS_NO_WT_CHECK=1 python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/hlr" --repo "$HLR" --handover-root "$WORK/hr" >/dev/null 2>"$WORK/hlr.err" || rc=$?
has "a repo that holds a listed root: the brief says it searches nothing" "$(tr '\n' ' ' < "$WORK"/hr/tester/hlr/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)" "no notes search"
HOME="$WORK/home3" bash "$HERE/brief-lint.sh" "$WORK"/hr/tester/hlr/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/lint-hlr.err"; rc=$?
[ "$rc" = 0 ] && pass "and the lint agrees (passes it)" || fail "holds-root brief brief-lint rc=$rc: $(cat "$WORK/lint-hlr.err")"
ADP2="$WORK/adapter2"; git init -q "$ADP2"
rc=0; (unset GEN_BRIEFS_NO_WT_CHECK; python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/adp2" --repo "$ADP2" --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/adp2.err") || rc=$?
has "an adopter --no-worktree refusal prints himmel's _new-worktree.sh line, not a worktree.sh the adopter lacks" "$(cat "$WORK/adp2.err")" "$KIT/scripts/_new-worktree.sh fix/himmel-9001-plain-fix --no-install"
[ "$rc" = 1 ] && [ ! -e "$WORK/hr/tester/adp2/launch-N901.sh" ] && pass "and exits 1 writing no launcher" || fail "adopter no-worktree refusal rc=$rc"
rc=0; (cd "$WORK" && unset GEN_BRIEFS_NO_WT_CHECK; python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/workers.json" --base "$ADPBASE" --chief BZ --bucket "$WORK/hr/tester/adp3" --repo adapter --handover-root "$WORK/hr" --no-worktree >/dev/null 2>"$WORK/adp3.err") || rc=$?
has "a relative --repo still exports an absolute worktree path" "$(cat "$WORK/hr/tester/adp3/launch-N901.sh" 2>/dev/null)" "export WORKER_SESSION_REPO=$ADP/.claude/worktrees/fix+himmel-9001-plain-fix"

# --- the rm kind: a release-manager brief filled from docs/handover/rm-brief-template.md ---
cat > "$WORK/rm.json" <<EOF
[
 {"kind":"rm","label":"N910","keys":["HIMMEL-9010"],"slug":"rm","release":"R1","versions":"v1 + v2, current v1","epoch":3,"state_dir":"$WORK/hr/tester/himmel/release/R1","mode":"observe"}
]
EOF
: > "$WT_LOG"
# an rm worker with an ab_arm is refused: its launcher applies no A/B arm
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["ab_arm"]="400k"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/rm.json" "$WORK/rm-ab.json"
rc=0; python3 "$SUT" "$WORK/rm-ab.json" --base 4ccb59d --chief BZ --bucket "$WORK/rmb-ab" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >/dev/null 2>"$WORK/rm-ab.err" || rc=$?
[ "$rc" = 1 ] && grep -q 'ab_arm' "$WORK/rm-ab.err" && [ ! -e "$WORK/rmb-ab/launch-N910.sh" ] && pass "an rm worker with an ab_arm is refused before anything is written (HIMMEL-7811)" || fail "rm ab_arm rc=$rc"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["release"]="r"*120; l[0]["state_dir"]=sys.argv[3]+"/"+"r"*120; json.dump(l,open(sys.argv[2],"w"))' "$WORK/rm.json" "$WORK/rm-long.json" "$WORK/hr/tester/himmel/release"
rc=0; python3 "$SUT" "$WORK/rm-long.json" --base 4ccb59d --chief BZ --bucket "$WORK/rmb-long" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >/dev/null 2>"$WORK/rm-long.err" || rc=$?
[ "$rc" = 1 ] && grep -q '128' "$WORK/rm-long.err" && [ ! -e "$WORK/rmb-long/launch-N910.sh" ] && pass "9537 e: an rm worker whose name is over the bus limit is refused naming 128, nothing written" || fail "9537 e: rm over-limit rc=$rc: $(cat "$WORK/rm-long.err")"
rmout="$(python3 "$SUT" "$WORK/rm.json" --base 4ccb59d --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/rmb" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 --manifest "$WORK/rmf.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "an rm worker generates (rc 0)" || fail "rm rc=$rc: $rmout"
RMD="$WORK/rmb/HIMMEL-9010-N910-rm-R1-2026-10-08.md"
[ -f "$RMD" ] && [ -f "$WORK/rmb/launch-N910.sh" ] && pass "an rm worker writes <KEY>-<label>-rm-<R>-<date>.md and its launcher" || fail "rm files missing in $WORK/rmb"
[ ! -s "$WT_LOG" ] && pass "an rm worker creates no worktree" || fail "worktree stub called: $(cat "$WT_LOG")"
RMB="$(sed 's/^> *//' "$RMD" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
has "the rm brief carries the release and its versions" "$RMB" 'Release manager for R1 (v1 + v2, current v1)'
has "the rm brief names the lease epoch to acquire" "$RMB" '--expect-epoch 3'
has "the rm brief names the state directory" "$RMB" "State directory \`$WORK/hr/tester/himmel/release/R1\`"
has "the rm brief carries a minted token in the RM shape" "$RMB" 'BZ-RM-R1-'
has "the rm brief carries the opus tier line" "$RMB" '**Tier:** opus'
has "the rm brief resumes in the release scratch dir" "$(head -3 "$RMD" 2>/dev/null)" "/.cache/himmel/rm/R1/scratch"
if sed 's/REQ <id>/REQ/' "$RMD" 2>/dev/null | grep -Eq '<[A-Za-z$]'; then fail "the rm brief keeps an unfilled placeholder: $(sed 's/REQ <id>/REQ/' "$RMD" | grep -E '<[A-Za-z$]' | head -2)"; else pass "the rm brief keeps no unfilled placeholder"; fi
RML="$(cat "$WORK/rmb/launch-N910.sh" 2>/dev/null)"
has "the rm launcher arms the release-manager profile for its release" "$RML" '--profile release-manager --rm-release R1'
has "the rm launcher skips the prior-art lint an rm brief has no field for" "$RML" '--no-prior-art-check'
has "the printed manifest line is native" "$rmout" "--lane native"
rmbad() { # <name> <python edit> <stderr fragment>: refused, rc 1, nothing written
    local n="$1" edit="$2" frag="$3"
    rm -rf "$WORK/rmbad" "$WORK/rmbad.json"
    python3 -I -c "import json,sys; l=json.load(open(sys.argv[1])); d=l[0]; $edit; json.dump(l,open(sys.argv[2],'w'))" "$WORK/rm.json" "$WORK/rmbad.json" || { fail "$n (fixture setup failed)"; return; }
    python3 "$SUT" "$WORK/rmbad.json" --base 4ccb59d --chief BZ --bucket "$WORK/rmbad" --repo "$REPO" --handover-root /h >/dev/null 2>"$WORK/rmbad.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q "$frag" "$WORK/rmbad.err" && ! ls "$WORK/rmbad"/* >/dev/null 2>&1; then pass "$n"; else fail "$n (rc=$rc, err: $(cat "$WORK/rmbad.err"))"; fi
}
rmbad "an rm worker with a release holding a slash is refused" 'd["release"]="a/b"' "release"
rmbad "an rm worker with a non-integer epoch is refused" 'd["epoch"]="three"' "epoch"
rmbad "an rm worker with a negative epoch is refused" 'd["epoch"]=-1' "epoch"
rmbad "an rm worker with a mode other than observe or live is refused" 'd["mode"]="dry"' "mode"
rmbad "an rm worker missing its state_dir is refused" 'del d["state_dir"]' "state_dir"
rmbad "an rm worker on a non-native lane is refused" 'd["lane"]="claudex"' "lane"
rmbad "an rm worker whose state_dir names another release is refused" 'd["state_dir"]="/h/tester/himmel/release/R2"' "must end in release/R1"
rmbad "an rm worker whose state_dir is not under a release directory is refused" 'd["state_dir"]="/h/tester/himmel/R1"' "must end in release/R1"
rmbad "an rm worker on a non-opus model is refused" 'd["model"]="claude-sonnet-5-5"' "opus"

# --- every brief's front matter parses as YAML and the description reads back as the folded text ---
fm_desc() { # <doc>: the parsed description of the doc's front matter, or PARSE-ERROR
    python3 -I -c 'import sys,yaml
t=open(sys.argv[1],encoding="utf-8").read().split("\n---\n")[0].lstrip("-\n")
try: print(yaml.safe_load(t)["description"],end="")
except Exception: print("PARSE-ERROR",end="")' "$1"
}
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["desc"]="Operator ask: x\nsay \"y\""; l[0]["label"]="N911"; l[0]["slug"]="colon-desc"; json.dump(l,open(sys.argv[2],"w"),ensure_ascii=False)' "$WORK/workers.json" "$WORK/y-colon.json"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["desc"]="café \U0001F680 ok"; l[0]["label"]="N912"; l[0]["slug"]="utf-desc"; json.dump(l,open(sys.argv[2],"w"),ensure_ascii=False)' "$WORK/workers.json" "$WORK/y-utf.json"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; l[0]["label"]="N914"; l[0]["slug"]="plain-desc"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/y-plain.json"
for f in y-colon y-utf y-plain; do
    python3 "$SUT" "$WORK/$f.json" --base 4ccb59d --chief BZ --bucket "$WORK/yb" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >/dev/null 2>"$WORK/$f.err" || fail "$f generates (err: $(cat "$WORK/$f.err"))"
done
YC="$(ls "$WORK"/yb/*-N911-*.md 2>/dev/null)"; YU="$(ls "$WORK"/yb/*-N912-*.md 2>/dev/null)"
[ "$(fm_desc "$YC")" = 'Operator ask: x say "y"' ] && pass "a desc with a colon and a newline parses back to the folded text" || fail "colon desc parsed as: $(fm_desc "$YC")"
[ "$(fm_desc "$YU")" = "caf$(printf '\303\251') $(printf '\360\237\232\200') ok" ] && pass "a non-ASCII desc parses back unchanged" || fail "utf desc parsed as: $(fm_desc "$YU")"
lacks "and its raw description line holds no \\u escape" "$(grep '^description:' "$YU" 2>/dev/null)" '\u'
[ "$(fm_desc "$(ls "$WORK"/yb/*-N914-*.md 2>/dev/null)")" = "fix the plain thing" ] && pass "a plain desc still parses to itself" || fail "plain desc parsed as: $(fm_desc "$(ls "$WORK"/yb/*-N914-*.md 2>/dev/null)")"
[ "$(fm_desc "$RMD")" = 'Release manager for R1 (v1 + v2, current v1): rule every placement, report STATUS, BURN-DOWN and READY' ] && pass "the rm brief's description parses back to the template text" || fail "rm desc parsed as: $(fm_desc "$RMD")"
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["versions"]="v1 \"q\" \\ z"; l[0]["label"]="N913"; json.dump(l,open(sys.argv[2],"w"))' "$WORK/rm.json" "$WORK/rm-q.json"
python3 "$SUT" "$WORK/rm-q.json" --base 4ccb59d --chief BZ --bucket "$WORK/rmq" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >/dev/null 2>"$WORK/rm-q.err" || fail "the quoting rm generates (err: $(cat "$WORK/rm-q.err"))"
[ "$(fm_desc "$(ls "$WORK"/rmq/*-N913-*.md 2>/dev/null)")" = 'Release manager for R1 (v1 "q" \ z): rule every placement, report STATUS, BURN-DOWN and READY' ] && pass "an rm versions string holding a quote and a backslash parses back unchanged" || fail "rm quoting desc parsed as: $(fm_desc "$(ls "$WORK"/rmq/*-N913-*.md 2>/dev/null)")"

# --- a brief naming VM work carries the guest-exec line; one that does not stays without it ---
python3 -I -c "import json,sys; l=json.load(open(sys.argv[1])); l[0]['why']='the install must be proven on a test VM first'; json.dump(l,open(sys.argv[2],'w'))" "$WORK/workers.json" "$WORK/vmlegs.json"
rc=0; python3 "$SUT" "$WORK/vmlegs.json" --base 4ccb59d --chief BZ --bucket "$WORK/vmb" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/hr" --work-dir "$WORK/w" --deadline 1791475000 >"$WORK/vm.out" 2>&1 || rc=$?
[ "$rc" = 0 ] && pass "a workers file naming VM work generates (rc 0)" || fail "vm workers rc=$rc: $(cat "$WORK/vm.out")"
VMB1="$(tr '\n' ' ' < "$WORK/vmb/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>/dev/null | tr -s ' ')"
VMB2="$(tr '\n' ' ' < "$WORK/vmb/HIMMEL-9002-N902-hook-fix-2026-10-08.md" 2>/dev/null | tr -s ' ')"
has "a brief naming VM work says to drive the guest only through guest-exec.sh" "$VMB1" "drive the guest only through guest-exec.sh"
lacks "a brief that names no VM work does not carry the guest-exec line" "$VMB2" "guest-exec.sh"
bash "$HERE/brief-lint.sh" "$WORK/vmb/HIMMEL-9001-N901-plain-fix-2026-10-08.md" 2>"$WORK/vmlint.err"; rc=$?
[ "$rc" = 0 ] && pass "the VM brief passes brief-lint.sh" || fail "vm brief brief-lint rc=$rc: $(cat "$WORK/vmlint.err")"

# --- a grants list renders a Pre-granted follow-ups block; a grant reaching a forbidden path or a bypass is refused ---
python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1])); l[0]["grants"]=[{"text":"add the RED row to the harness suite","paths":["scripts/handover/chief-kit/test-gen-briefs.sh"]},{"text":"mirror the change in the twin","paths":["scripts/a.sh","scripts/b.sh"]}]; json.dump(l[:1],open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/gr.json" || fail "grants fixture setup failed"
python3 "$SUT" "$WORK/gr.json" --base 4ccb59d --chief BZ --bucket "$WORK/gr" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/gr.err"; rc=$?
[ "$rc" = 0 ] && pass "a worker with grants generates (rc 0)" || fail "grants rc=$rc: $(cat "$WORK/gr.err")"
GR="$(cat "$WORK"/gr/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
has "a brief with grants carries the Pre-granted follow-ups block" "$GR" "> **Pre-granted follow-ups** (HIMMEL-7091)"
# shellcheck disable=SC2016 # literal backticks in the sed pattern
GR_NONCE="$(sed -n 's/^> \*\*RETASK:\*\* your nonce is `\([^`]*\)`.*/\1/p' "$WORK"/gr/HIMMEL-9001-N901-plain-fix-*.md)"
if [ -n "$GR_NONCE" ]; then has "the grants block binds the ruling to the worker's own nonce" "$GR" "\`RULING $GR_NONCE grant=<Gn> :: <action>\`"; else fail "no RETASK nonce in the grants brief"; fi
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "G1 names its text and backticked path" "$GR" '> - G1 add the RED row to the harness suite: `scripts/handover/chief-kit/test-gen-briefs.sh`'
# shellcheck disable=SC2016 # literal backticks in the expected brief text
has "G2 lists every path it names" "$GR" '> - G2 mirror the change in the twin: `scripts/a.sh`, `scripts/b.sh`'
has "an off-grant ruling gets a needs-rebrief FINDING" "$GR" "FINDING needs-rebrief <Gn>"
# shellcheck disable=SC2016 # literal backticks in the expected brief text
lacks "the grants block no longer says the chief runs holds.py grant" "$GR" 'Your chief runs `holds.py grant`'
has "the chief records the ruling and the worker acts on it" "$GR" 'Your chief records the ruling, and you act on it once you have it.'
bash "$HERE/brief-lint.sh" "$WORK"/gr/HIMMEL-9001-N901-plain-fix-*.md 2>"$WORK/grlint.err"; rc=$?
[ "$rc" = 0 ] && pass "the grants brief passes brief-lint.sh" || fail "grants brief brief-lint rc=$rc: $(cat "$WORK/grlint.err")"
lacks "a worker without grants carries no grants block" "$ct_no" "Pre-granted follow-ups"
grbad() { # <name> <python edit of the grant g> <stderr fragment>
    rm -rf "$WORK/grbad" "$WORK/grbad.json"
    python3 -I -c "import json,sys; l=json.load(open(sys.argv[1])); g={'text':'fix the twin','paths':['scripts/a.sh']}; $2; l[0]['grants']=[g]; json.dump(l[:1],open(sys.argv[2],'w'))" "$WORK/workers.json" "$WORK/grbad.json" || { fail "$1 (fixture setup failed)"; return; }
    python3 "$SUT" "$WORK/grbad.json" --base 4ccb59d --chief BZ --bucket "$WORK/grbad" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/grbad.err"; rc=$?
    if [ "$rc" = 1 ] && grep -q -- "$3" "$WORK/grbad.err" && ! ls "$WORK/grbad"/* >/dev/null 2>&1; then pass "$1"; else fail "$1 (rc=$rc, err: $(cat "$WORK/grbad.err"))"; fi
}
grbad "a grant with no paths is refused" 'g["paths"]=[]' "must name its paths"
grbad "a grant naming a settings file is refused" 'g["paths"]=[".claude/settings.json"]' "settings, CI-workflow or trust path"
grbad "a grant naming a CI workflow is refused" 'g["paths"]=[".github/workflows/ci.yml"]' "settings, CI-workflow or trust path"
grbad "a grant naming a ci-trust-paths file is refused" 'g["paths"]=["scripts/handover/chief-kit/brief-lint.sh"]' "settings, CI-workflow or trust path"
grbad "a grant whose text names a bypass is refused" 'g["text"]="skip review with SKIP_CR"' "never carries a bypass"
grbad "a grant whose text names an amend is refused" 'g["text"]="amend the first commit"' "never carries a bypass"
grbad "a grant with a glob path is refused" 'g["paths"]=["scripts/*.sh"]' "literal repo-relative file path"
grbad "a grant with a parent-relative path is refused" 'g["paths"]=["../x.sh"]' "literal repo-relative file path"
grbad "a dot-prefixed spelling of a workflow path is refused" 'g["paths"]=["./.github/workflows/ci.yml"]' "literal repo-relative file path"
grbad "a doubled-slash spelling of a trust path is refused" 'g["paths"]=["scripts/handover//chief-kit/brief-lint.sh"]' "literal repo-relative file path"
grbad "a grant path with a trailing slash is refused" 'g["paths"]=["scripts/"]' "literal repo-relative file path"
grbad "a grant path naming the repo root is refused" 'g["paths"]=["."]' "literal repo-relative file path"
mkdir -p "$REPO/grantdir" || fail "grantdir fixture setup failed"
grbad "a grant path naming an existing directory is refused" 'g["paths"]=["grantdir"]' "literal repo-relative file path"
grbad "a grant path holding a backtick is refused" 'g["paths"]=["scripts/a`.sh"]' "literal repo-relative file path"
grbad "a grant whose text names a short-flag force push is refused" 'g["text"]="git push -f origin main"' "never carries a bypass"
grbad "a grant whose text names a spaced force push is refused" 'g["text"]="force push the branch"' "never carries a bypass"
grbad "a grant whose text holds a backtick is refused" 'g["text"]="fix "+chr(96)+"x"' "<placeholder>"
grbad "a grant whose text holds a control character is refused" 'g["text"]="fix\tthe twin"' "<placeholder>"
grbad "a grant with a placeholder in its text is refused" 'g["text"]="edit <file>"' "<placeholder>"
grbad "a grant with an extra key is refused" 'g["why"]="x"' "exactly {text, paths}"

python3 "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "no arguments is a usage error (rc 2)" || fail "usage rc=$rc"

# --- a ticket whose body lacks a DoD or a Proof is refused, the ticket printed for the chief to fix ---
pm() { # <KEY> <body>: a mirror ticket with that Description
    printf -- '---\nkey: %s\n---\n# %s: t\n\n## Description\n\n%s\n\n## Comments\n\nnone\n' "$1" "$1" "$2" > "$GEN_BRIEFS_MIRROR/$1.md"
}
PROOF_TAIL=$'\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n'
pm HIMMEL-9001 $'Edit scripts/x.\n\nDoD\n- the row is green\n'
pm HIMMEL-9002 "Edit scripts/hooks/h.sh.$PROOF_TAIL"
pm HIMMEL-9003 "Edit the hook.$PROOF_TAIL"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/pb" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pb.err" || rc=$?
[ "$rc" = 1 ] && pass "proof: a ticket with a DoD but no Proof is refused (rc 1)" || fail "proof: no-Proof rc=$rc"
has "proof: the refusal names the ticket and the missing section" "$(cat "$WORK/pb.err")" "HIMMEL-9001 lacks Proof"
has "proof: the refusal prints the ticket body for the chief to fix" "$(cat "$WORK/pb.err")" "Edit scripts/x."
lacks "proof: a ticket that has both is not named" "$(cat "$WORK/pb.err")" "HIMMEL-9002 lacks"
[ ! -e "$WORK/pb/launch-N901.sh" ] && pass "proof: nothing is written for a refused ticket" || fail "proof: wrote files for a refused ticket"
pm HIMMEL-9001 "Edit scripts/x.$PROOF_TAIL"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/pb" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pb.err" || rc=$?
[ "$rc" = 0 ] && pass "proof: tickets that all have DoD and Proof generate" || fail "proof: complete tickets rc=$rc: $(cat "$WORK/pb.err")"
pm HIMMEL-9003 $'Edit the hook.\n\nDoD\n- the row is green\n\nProof\nTBD\n'
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/pb2" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pb2.err" || rc=$?
[ "$rc" = 1 ] && has "proof: a placeholder Proof on the second key of a worker is refused" "$(cat "$WORK/pb2.err")" "HIMMEL-9003 lacks Proof" || fail "proof: placeholder rc=$rc"
rm -f "$GEN_BRIEFS_MIRROR/HIMMEL-9003.md"
rc=0; python3 "$SUT" "$WORK/workers.json" --base 4ccb59d --chief BZ --bucket "$WORK/pb3" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/pb3.err" || rc=$?
[ "$rc" = 0 ] && has "proof: a ticket missing from the mirror warns and does not refuse (mirror lag)" "$(cat "$WORK/pb3.err")" "HIMMEL-9003" || fail "proof: absent mirror rc=$rc"

# --- an optional inherited key renders the Inherited PR block; a bad value is refused ---
inh_gen() { # <python expr for the inherited value, or -: writes N901 alone into $WORK/inh; sets inh_rc
    rm -rf "$WORK/inh" "$WORK/inh.json" "$WORK/inh.err"
    inh_rc=1
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]
if sys.argv[3] != "-": l[0]["inherited"]=eval(sys.argv[3])
json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/inh.json" "$1" || return 1
    python3 "$SUT" "$WORK/inh.json" --base 4ccb59d --chief BZ --bucket "$WORK/inh" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/inh.err"; inh_rc=$?
}
inh_gen "{'pr': 4033, 'authors': ['Ada Lovelace', 'Alan Turing'], 'mode': 'takeover'}"
inh_brief="$(cat "$WORK/inh"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
[ "$inh_rc" = 0 ] && pass "a worker with a valid inherited key generates (rc 0)" || fail "inherited worker rc=$inh_rc: $(cat "$WORK/inh.err")"
has "a worker with inherited renders the Inherited PR block" "$inh_brief" "> **Inherited PR (the resume of an \`ORPHAN PR\`"
has "the Inherited PR block names the PR number" "$inh_brief" "PR \`4033\`"
has "the Inherited PR block names every original author" "$inh_brief" "by \`Ada Lovelace, Alan Turing\`"
has "the Inherited PR block carries the mode" "$inh_brief" "Mode: \`takeover\`"
has "the Inherited PR block keeps the disposition rule" "$inh_brief" "**Before the first push, decide a disposition**"
inh_gen -
plain_brief="$(cat "$WORK/inh"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
[ "$inh_rc" = 0 ] && [ -n "$plain_brief" ] && lacks "a worker without inherited renders no Inherited PR block" "$plain_brief" "Inherited PR" || fail "plain worker rc=$inh_rc or no brief written"
inhbad() { # <name> <python expr for the inherited value>: refused, rc 1, nothing written
    inh_gen "$2"
    if [ "$inh_rc" = 1 ] && grep -q "inherited" "$WORK/inh.err" && ! ls "$WORK/inh"/*.md >/dev/null 2>&1; then pass "$1"; else fail "$1 (rc=$inh_rc, err: $(cat "$WORK/inh.err"))"; fi
}
inhbad "an inherited key that is not an object is refused" "'4033'"
inhbad "an inherited key with an empty authors list is refused" "{'pr': 4033, 'authors': [], 'mode': 'resume'}"
inhbad "an inherited key with authors as a bare string is refused" "{'pr': 4033, 'authors': 'Ada', 'mode': 'resume'}"
inhbad "an inherited key with a pr that is not an integer is refused" "{'pr': '4033', 'authors': ['Ada'], 'mode': 'resume'}"
inhbad "an inherited key with a mode other than resume or takeover is refused" "{'pr': 4033, 'authors': ['Ada'], 'mode': 'fork'}"
inhbad "an inherited key with no mode is refused" "{'pr': 4033, 'authors': ['Ada']}"

# A worker whose scope Writes name scripts/config-ui/ launches with worker-e2e (worker-impl plus the
# Playwright MCP server) and its brief says how to look at the page; any other worker stays on worker-impl.
ui_gen() { # <scope prefix or -> <profile key or ->: one worker generated into $WORK/ui
    rm -rf "$WORK/ui"; ui_rc=1
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]
if sys.argv[3] != "-": l[0]["writes"]=sys.argv[3]
if sys.argv[4] != "-": l[0]["profile"]=sys.argv[4]
json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/ui.json" "$1" "$2" || return 1
    python3 "$SUT" "$WORK/ui.json" --base 4ccb59d --chief BZ --bucket "$WORK/ui" --repo "$REPO" --handover-root /h --no-worktree >/dev/null 2>"$WORK/ui.err"; ui_rc=$?
    ui_launch="$(cat "$WORK/ui"/launch-N901.sh 2>/dev/null)"; ui_brief="$(cat "$WORK/ui"/HIMMEL-9001-N901-plain-fix-*.md 2>/dev/null)"
}
ui_mcp() { # the mcp= field a dry-run launch with <profile> reports for the generated brief
    mkdir -p "$WORK/uiarm"; sed "s|^resume_cwd:.*|resume_cwd: $WORK|" "$WORK/ui"/HIMMEL-9001-N901-plain-fix-*.md > "$WORK/uiarm/HIMMEL-9001-N901-copy.md"
    HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --profile "$1" HIMMEL-9001-N901 "$WORK/uiarm/HIMMEL-9001-N901-copy.md" "$WORK/uiarm/signal" 9999999999 "$WORK/uiarm/log" claude-sonnet-5-5 2>&1 | grep -o ' mcp=[^ ]*'
}
ui_gen "Writes scripts/config-ui/page.ts." -
[ "$ui_rc" = 0 ] && pass "a config-ui worker generates (rc 0)" || fail "config-ui worker rc=$ui_rc: $(cat "$WORK/ui.err")"
has "a config-ui worker's launcher arms worker-e2e" "$ui_launch" "--profile worker-e2e --chief BZ"
has "a config-ui worker's brief says the chief starts himmelctl ui from the worker's own worktree" "$ui_brief" "from YOUR worktree"
has "a config-ui worker's brief tells the worker to ask for the URL and never start the UI itself" "$ui_brief" "ask for it, never start it yourself"
lacks "a config-ui worker's brief hands out no standing agent-session bypass" "$ui_brief" "allow-agent-session"
has "a config-ui worker's brief says to open the URL with the browser MCP headless" "$ui_brief" "browser MCP headless"
lacks "a config-ui worker's brief never sends a browser screenshot to the scratch dir (outside the server's output root)" "$ui_brief" "save screenshots to your scratch dir"
has "a config-ui worker's brief names a relative browser output filename" "$ui_brief" "a relative filename"
has "a config-ui worker's brief names the .playwright-mcp output root" "$ui_brief" ".playwright-mcp"
has "a config-ui worker's brief cites the server-returned artifact path" "$ui_brief" "the path the server returns"
has "a config-ui worker's brief navigates over HTTP, never file://" "$ui_brief" "never a file:// URL"
ui_launch_profile="$(printf '%s' "$ui_launch" | grep -o -e '--profile [a-z0-9-]*')"
has "the dry-run launch of a config-ui worker lists playwright among its MCP servers" "$(ui_mcp "${ui_launch_profile#--profile }")" "playwright"
ui_gen "Writes scripts/config-ui/page.ts." worker-bus
has "an explicit worker profile key wins over the config-ui choice" "$ui_launch" "--profile worker-bus --chief BZ"
has "the explicit-profile worker's brief was written" "$ui_brief" "> **Writes:**"
lacks "and a worker off the browser profile gets no browser line" "$ui_brief" "UI work:"
ui_gen - -
[ "$ui_rc" = 0 ] && pass "a non-UI worker generates (rc 0)" || fail "non-UI worker rc=$ui_rc: $(cat "$WORK/ui.err")"
has "a non-UI worker's launcher stays on worker-impl" "$ui_launch" "--profile worker-impl --chief BZ"
has "the non-UI worker's brief was written" "$ui_brief" "> **Writes:**"
lacks "a non-UI worker's brief has no browser line" "$ui_brief" "UI work:"

# A worker whose Writes are all under docs/ or are *.md defaults to worker-docs; one code path,
# a missing Writes line, or a config-ui path keeps its profile; worker-eval is only an explicit key.
ui_gen "Writes docs/internals/a.md and README.md." -
has "a docs-only worker's launcher arms worker-docs" "$ui_launch" "--profile worker-docs --chief BZ"
ui_gen "Writes docs/internals/ (a.md)." -
has "a docs/ dir worker arms worker-docs" "$ui_launch" "--profile worker-docs --chief BZ"
ui_gen "Writes docs/internals/a.md and scripts/lib/x.sh." -
has "a worker writing docs and one script stays on worker-impl" "$ui_launch" "--profile worker-impl --chief BZ"
for unk in "src/main.py" "Makefile" "LICENSE"; do
  ui_gen "Writes docs/internals/a.md and $unk." -
  has "a docs path plus an unrecognised path ($unk) stays on worker-impl" "$ui_launch" "--profile worker-impl --chief BZ"
done
ui_gen "Writes docs/internals/a.md and scripts/config-ui/page.ts." -
has "a docs plus config-ui worker keeps worker-e2e" "$ui_launch" "--profile worker-e2e --chief BZ"
ui_gen "Writes docs/internals/a.md." worker-eval
has "an explicit worker-eval key wins over the docs default" "$ui_launch" "--profile worker-eval --chief BZ"
ui_gen "Writes docs/internals/a.md." worker-impl
has "an explicit worker-impl key wins over the docs default" "$ui_launch" "--profile worker-impl --chief BZ"
ui_launch_profile="$(printf '%s' "$ui_launch" | grep -o -e '--profile [a-z0-9-]*')"
ui_mcp_impl="$(ui_mcp "${ui_launch_profile#--profile }")"
has "the dry-run launch of a non-UI worker reports its MCP servers" "$ui_mcp_impl" 'mcp=["qmd","himmel-bus"]'
lacks "the dry-run launch of a non-UI worker lists no playwright" "$ui_mcp_impl" "playwright"
ui_gen - 'Bad;x'
[ "$ui_rc" = 1 ] && grep -q 'profile' "$WORK/ui.err" && [ ! -e "$WORK/ui/launch-N901.sh" ] && pass "an invalid worker profile is refused before anything is written" || fail "bad profile rc=$ui_rc"

# The brief names every merged contract=no PR of its ticket and the PR body's Remaining: text, so merged work is never redone.
mkdir -p "$WORK/pm-state"
cat > "$WORK/pm-state/status-events.jsonl" <<'EOF'
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4313","head":"aaa","contract":"no","result":"noop"}
{"ts":"t","event":"derive","key":"HIMMEL-9101","pr":"4313","result":"moved","rule":"D3"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4313","result":"moved","rule":"D3"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4320","head":"bbb","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4340","head":"eee","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4350","head":"fff","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4375","head":"h75","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4376","head":"h76","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4330","head":"ccc","contract":"yes","result":"moved"}
{"ts":"t","event":"merge","key":"HIMMEL-9102","pr":"4399","head":"ddd","contract":"no","result":"noop"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4360","head":"g60","contract":"no","result":"pending","stage":"pre-merge"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4370","head":"g70","contract":"no","result":"pending","stage":"pre-merge"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4380","head":"g80","contract":"no","result":"pending","stage":"pre-merge"}
{"ts":"t","event":"merge","key":"HIMMEL-9101","pr":"4380","head":"g80","result":"not-merged","stage":"policy-refused"}
EOF
cat > "$WORK/mrgh-stub.sh" <<'EOF'
#!/usr/bin/env bash
# the merge-rows filter's gh seam: `pr view <n> --json state,headRefOid --jq ...`; PR 4380 answers MERGED, so only its not-merged row keeps it out
case "$3" in
    4360) echo "OPEN g60" ;;
    4370) echo "MERGED g70" ;;
    4380) echo "MERGED g80" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$WORK/mrgh-stub.sh"
cat > "$WORK/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$3" in
    4370) printf 'Remaining: the kill-after-merge slice\n' ;;
    4313) printf 'Slice C1a of the thing.\n\nRemaining: slices C1b and C4 (the {brace} readers)\n' ;;
    4320) printf 'No remaining line here.\n' ;;
    4340) printf 'Remaining:\n\nAn unrelated section follows.\n' ;;
    4375) printf '## Summary\nslice one\n\n## Ticket coverage\n- slice one: done\n- rest: deferred \xe2\x86\x92 HIMMEL-9\n' ;;
    4376) printf '## Ticket coverage\n- slice one: done\n' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$WORK/gh-stub.sh"
cat > "$WORK/pm.json" <<'EOF'
[{"label":"N911","keys":["HIMMEL-9101"],"slug":"pm-fix","branch":"fix/himmel-9101-pm-fix","title":"a partial ticket","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","writes":"scripts/x/","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9101] f"},
 {"label":"N912","keys":["HIMMEL-9103"],"slug":"pm-none","branch":"fix/himmel-9103-pm-none","title":"a clean ticket","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: `git log -3 -- scripts/x`.","writes":"scripts/x/","scope":"`scripts/x/`","scope_short":"scripts/x","commit":"fix(x): [HIMMEL-9103] f"}]
EOF
pm_out="$(MERGE_ROWS_GH="$WORK/mrgh-stub.sh" TICKET_STATUS_STATE_DIR="$WORK/pm-state" GEN_BRIEFS_GH_CMD="$WORK/gh-stub.sh" python3 "$SUT" "$WORK/pm.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/pm-bucket" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/pmw" --deadline 1791475000 2>&1)"; pm_rc=$?
[ "$pm_rc" = 0 ] && pass "a ticket with partial merges generates (rc 0)" || fail "partial-merge gen rc=$pm_rc: $pm_out"
PM1="$(tr '\n' ' ' < "$WORK/pm-bucket/HIMMEL-9101-N911-pm-fix-2026-10-08.md" | tr -s ' ')"
has "the brief names the merged contract=no PR and its Remaining: text" "$PM1" "PR \`#4313\`: Remaining: slices C1b and C4 (the {brace} readers)"
has "a partial PR whose body has no Remaining: line is marked as needing a chief note" "$PM1" "PR \`#4320\`: needs a chief note"
has "an empty Remaining: line does not borrow the text of the next line" "$PM1" "PR \`#4340\`: needs a chief note"
has "a PR whose body gh cannot read says so, not that it has no Remaining: line" "$PM1" "PR \`#4350\`: needs a chief note (its body could not be read)"
has "a coverage-only partial PR carries its deferred line as the remainder" "$PM1" "PR \`#4375\`: Remaining: rest: deferred → HIMMEL-9"
has "a partial PR whose coverage has only done lines is marked as needing a chief note and names the missing line" "$PM1" "PR \`#4376\`: needs a chief note (its body has no \`Remaining:\` line and no \`deferred -> <KEY>\` line under \`## Ticket coverage\`)"
lacks "a contract=yes merge row is not listed as a partial" "$PM1" '#4330'
has "a pre-merge row whose PR GitHub reports MERGED is named (a kill after the merge keeps the record)" "$PM1" "PR \`#4370\`: Remaining: the kill-after-merge slice"
lacks "a pre-merge row whose PR is still open is not named" "$PM1" '#4360'
lacks "a pre-merge row followed by a not-merged row is not named" "$PM1" '#4380'
lacks "another ticket's partial merge is not listed" "$PM1" '#4399'
bash "$HERE/brief-lint.sh" "$WORK/pm-bucket/HIMMEL-9101-N911-pm-fix-2026-10-08.md" 2>"$WORK/lintpm.err"; rc=$?
[ "$rc" = 0 ] && pass "the partial-merge brief passes brief-lint.sh" || fail "partial-merge brief-lint rc=$rc: $(cat "$WORK/lintpm.err")"
lacks "a ticket with no partial merge gets no Already merged block" "$(cat "$WORK/pm-bucket/HIMMEL-9103-N912-pm-none-2026-10-08.md")" "Already merged"
# a status log that exists but cannot be read is reported, not read as "no partial merges"
mkdir -p "$WORK/pm-state-bad/status-events.jsonl"
pm_bad="$(TICKET_STATUS_STATE_DIR="$WORK/pm-state-bad" GEN_BRIEFS_GH_CMD="$WORK/gh-stub.sh" python3 "$SUT" "$WORK/pm.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/pm-bucket2" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/pmw2" --deadline 1791475000 2>&1)"
has "an unreadable status log is warned about, not silently read as empty" "$pm_bad" "status-events.jsonl is unreadable"

# The shared reader itself (scripts/lib/pr_remainder.py): one answer line per body, in ready-check.sh's grammar
# (the key follows the arrow and ends the line; anything else stays remaining work).
RDR="$HERE/../../lib/pr_remainder.py"
T=$'\t'
rdr() { printf '%b' "$2" | python3 -I "$RDR" "$1"; }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
H=$'## Ticket coverage\n'
same "reader: a body with neither form is none" "$(rdr HIMMEL-1 'just a summary')" "none"
same "reader: a Remaining: line stays remaining" "$(rdr HIMMEL-1 'Remaining: slice 2')" "remaining${T}slice 2"
same "reader: Remaining: is read in any case, indented" "$(rdr HIMMEL-1 '  remaining: slice 2')" "remaining${T}slice 2"
same "reader: an empty Remaining: line records nothing" "$(rdr HIMMEL-1 'Remaining:\n\nnot this')" "none"
same "reader: a deferred arrow line hands off" "$(rdr HIMMEL-1 "$H- rest: deferred → HIMMEL-9")" "handed-off${T}HIMMEL-9${T}rest: deferred → HIMMEL-9"
same "reader: the ascii arrow and a trailing period hand off" "$(rdr HIMMEL-1 "$H- rest: deferred -> HIMMEL-9.")" "handed-off${T}HIMMEL-9${T}rest: deferred -> HIMMEL-9."
same "reader: a deferred line with no key stays remaining" "$(rdr HIMMEL-1 "$H- rest: deferred -> later")" "remaining${T}rest: deferred -> later"
same "reader: a key that is not last stays remaining" "$(rdr HIMMEL-1 "$H- rest: deferred -> after HIMMEL-9 merges, stays here")" "remaining${T}rest: deferred -> after HIMMEL-9 merges, stays here"
same "reader: a key that is not first stays remaining" "$(rdr HIMMEL-1 "$H- rest: deferred -> slice-2 then HIMMEL-9 too")" "remaining${T}rest: deferred -> slice-2 then HIMMEL-9 too"
same "reader: two keys on one line stay remaining" "$(rdr HIMMEL-1 "$H- rest: deferred -> HIMMEL-9, HIMMEL-10")" "remaining${T}rest: deferred -> HIMMEL-9, HIMMEL-10"
same "reader: a deferral to the ticket itself stays remaining" "$(rdr HIMMEL-1 "$H- rest: deferred -> HIMMEL-1")" "remaining${T}rest: deferred -> HIMMEL-1"
same "reader: the own key is compared upper-cased" "$(rdr himmel-1 "$H- rest: deferred -> HIMMEL-1")" "remaining${T}rest: deferred -> HIMMEL-1"
same "reader: a lower-case key in the body is named upper-cased" "$(rdr HIMMEL-1 "$H- rest: deferred -> himmel-9")" "handed-off${T}HIMMEL-9${T}rest: deferred -> himmel-9"
same "reader: two lines naming one ticket name it once" "$(rdr HIMMEL-1 "$H- a: deferred -> HIMMEL-9\n- b: deferred -> HIMMEL-9")" "handed-off${T}HIMMEL-9${T}a: deferred -> HIMMEL-9; b: deferred -> HIMMEL-9"
same "reader: two lines naming two tickets name both in order" "$(rdr HIMMEL-1 "$H- a: deferred -> HIMMEL-9\n- b: deferred -> HIMMEL-10")" "handed-off${T}HIMMEL-9, HIMMEL-10${T}a: deferred -> HIMMEL-9; b: deferred -> HIMMEL-10"
same "reader: one handed-off line and one keyless line stay remaining" "$(rdr HIMMEL-1 "$H- a: deferred -> HIMMEL-9\n- b: deferred -> later")" "remaining${T}a: deferred -> HIMMEL-9; b: deferred -> later"
same "reader: a Remaining: line beside a handed-off line stays remaining" "$(rdr HIMMEL-1 "Remaining: x\n$H- a: deferred -> HIMMEL-9")" "remaining${T}x; a: deferred -> HIMMEL-9"
same "reader: a * bullet is read and its marker dropped" "$(rdr HIMMEL-1 "$H* a: deferred -> HIMMEL-9")" "handed-off${T}HIMMEL-9${T}a: deferred -> HIMMEL-9"
same "reader: a + bullet is read and its marker dropped" "$(rdr HIMMEL-1 "$H+ a: deferred -> HIMMEL-9")" "handed-off${T}HIMMEL-9${T}a: deferred -> HIMMEL-9"
same "reader: the coverage heading and the word deferred match in any case" "$(rdr HIMMEL-1 "## TICKET COVERAGE\n- a: DEFERRED -> HIMMEL-9")" "handed-off${T}HIMMEL-9${T}a: DEFERRED -> HIMMEL-9"
same "reader: a deferred line outside the coverage section is not read" "$(rdr HIMMEL-1 '- a: deferred -> HIMMEL-9')" "none"
same "reader: a level-one heading ends the coverage section" "$(rdr HIMMEL-1 "$H- a: done\n# Other\n- b: deferred -> HIMMEL-9")" "none"
same "reader: a level-two heading ends the coverage section" "$(rdr HIMMEL-1 "$H- a: done\n## Other\n- b: deferred -> HIMMEL-9")" "none"
same "reader: a level-three heading stays inside the coverage section" "$(rdr HIMMEL-1 "$H### Sub\n- b: deferred -> HIMMEL-9")" "handed-off${T}HIMMEL-9${T}b: deferred -> HIMMEL-9"
same "reader: an empty heading ends the coverage section" "$(rdr HIMMEL-1 "$H##\n- b: deferred -> HIMMEL-9")" "none"
same "reader: a #123 reference line is not a heading" "$(rdr HIMMEL-1 "$H#4587 merged\n- b: deferred -> HIMMEL-9")" "handed-off${T}HIMMEL-9${T}b: deferred -> HIMMEL-9"
same "reader: a tab inside the text does not split the answer line" "$(rdr HIMMEL-1 'Remaining: a\tb')" "remaining${T}a b"
if python3 -I "$RDR" >/dev/null 2>&1 </dev/null; then fail "reader: no key argument is a usage error"; else pass "reader: no key argument is a usage error"; fi
if python3 -I "$RDR" HIMMEL-1 extra >/dev/null 2>&1 </dev/null; then fail "reader: a second argument is a usage error"; else pass "reader: a second argument is a usage error"; fi

# ---- the PR size projection (own block) ----
# A Writes list that expands to more than the hard max of scripts/ci/pr-size-bands.tsv (40 files) is refused with
# pr_size_gate on, unless the worker carries bulk: mechanical; flag off, or past only the soft max (20), is a warning.
PS="$WORK/ps"; mkdir -p "$PS/scripts/big" "$PS/scripts/mid" "$PS/scripts/few" "$PS/scripts/hooks" "$PS/scripts/forty" "$PS/src"
for n in $(seq 1 41); do echo "$n" > "$PS/scripts/big/f$n.txt"; echo "$n" > "$PS/scripts/hooks/guard-$n.sh"; echo "$n" > "$PS/src/m$n.py"; done
for n in $(seq 1 40); do echo "$n" > "$PS/scripts/forty/f$n.txt"; done
for n in $(seq 1 41); do echo "$n" > "$PS/r$n.rt"; done; echo readme > "$PS/README.md"
# directory, wildcard-segment and nested shapes: files only under a subdirectory, a g-*.sh glob with a g-dir/ look-alike,
# a ** with a zero-directory match, and 41 two-character names for ?
mkdir -p "$PS/scripts/tree/sub" "$PS/scripts/xs/g-dir" "$PS/scripts/dd" "$PS/scripts/hl/a/b" "$PS/scripts/q"
for n in $(seq 1 41); do echo "$n" > "$PS/scripts/tree/sub/f$n.txt"; echo "$n" > "$PS/scripts/xs/g-dir/f$n.sh"; echo "$n" > "$PS/scripts/hl/a/b/f$n.txt"; done
for n in 1 2 3; do echo "$n" > "$PS/scripts/xs/g-$n.sh"; done
echo x > "$PS/scripts/dd/x.sh"; for n in $(seq 1 40); do mkdir -p "$PS/scripts/dd/d$n"; echo x > "$PS/scripts/dd/d$n/x.sh"; done
for n in $(seq 0 40); do echo "$n" > "$(printf '%s/scripts/q/f%02d.txt' "$PS" "$n")"; done
for n in $(seq 1 25); do echo "$n" > "$PS/scripts/mid/f$n.txt"; done
for n in 1 2 3; do echo "$n" > "$PS/scripts/few/f$n.txt"; done
mkdir -p "$PS/scripts/ci"; for n in $(seq 1 25); do echo "$n" > "$PS/scripts/ci/t$n.sh"; done  # 25 files under a ci-trust-paths.txt pattern
if git init -q "$PS" && git -C "$PS" add -A && git -C "$PS" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base && PSBASE="$(git -C "$PS" rev-parse HEAD)"; then
    pass "the size-projection fixture repo holds a base commit"
else
    fail "the size-projection fixture repo could not be committed; the rows below cannot be trusted"
    PSBASE=0000000000000000000000000000000000000000
fi
export HIMMEL_CONFIG_DIR="$WORK/no-conf"
ps_workers() { # <name> <dir/> [extra json members]
    cat > "$WORK/ps-$1.json" <<PSEOF
[{"label":"N921","keys":["HIMMEL-9201"],"slug":"size","branch":"fix/himmel-9201-size","title":"a sized fix","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: \`git log -3 -- scripts/x\`.","writes":"$2","scope":"\`$2\`","scope_short":"${2:-none}","commit":"fix(x): [HIMMEL-9201] f"$3}]
PSEOF
}
psrun() { python3 "$SUT" "$WORK/ps-$1.json" --base "$PSBASE" --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/ps-bucket-$1${2:-}" --date 2026-10-08 --repo "$PS" --handover-root "$WORK/handovers" --work-dir "$WORK/psw-$1${2:-}" --deadline 1791475000 2>&1; }
ps_brief() { ls "$WORK/ps-bucket-$1${2:-}"/HIMMEL-9201-*.md 2>/dev/null; }
ps_workers glob 'scripts/hooks/guard-*.sh' ''; ps_workers mixed 'scripts/few/ src/' ''; ps_workers forty scripts/forty/ ''
ps_workers rootglob '*.rt' ''; ps_workers rootfile 'README.md' ''
ps_workers treeglob 'scripts/tree/*' ''; ps_workers segglob 'scripts/xs/g-*.sh' ''; ps_workers ddglob 'scripts/dd/**/x.sh' ''
ps_workers hlglob 'scripts/hl/**' ''; ps_workers qglob 'scripts/q/f??.txt' ''; ps_workers prose 'scripts/forty/ and/or' ''
ps_workers dotslash './scripts/big/*' ''; ps_workers slashglob 'scripts/tree/*/' ''; ps_workers paren 'scripts/few/ README.md (src/ and more)' ''
ps_workers abspath 'scripts/forty/ /abs/path/note.md' ''
ps_workers new41 "$(for n in $(seq 1 41); do printf 'scripts/newd/n%s.txt ' "$n"; done)" ''
ps_workers absent 'scripts/new/a.sh scripts/new/b.sh' '';ps_workers nonamed 'none named' ''; ps_workers emptyw '' ''
ps_workers big scripts/big/ ''; ps_workers bulk scripts/big/ ',"bulk":"mechanical"'; ps_workers mid scripts/mid/ ''; ps_workers few scripts/few/ ''; ps_workers badbulk scripts/few/ ',"bulk":"yes"'

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun big)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a Writes dir of 41 tracked files is refused (rc 1)" || fail "41 files with the gate on: rc=$rc: $pso"
has "the refusal names the 40-file hard max" "$pso" "40-file hard max"
has "the refusal names the pr-size-bands.tsv hard row" "$pso" "pr-size-bands.tsv row hard"
has "the refusal says how many files the Writes expand to" "$pso" "41 files"
[ -z "$(ps_brief big)" ] && pass "a refused brief writes no doc" || fail "a refused brief wrote a doc"

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun bulk)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on, bulk: mechanical: 41 files pass (rc 0)" || fail "bulk mechanical: rc=$rc: $pso"
[ -n "$(ps_brief bulk)" ] && pass "the bulk mechanical worker gets its brief" || fail "bulk mechanical: no brief"

pso="$(psrun big off)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate off: 41 files still write the brief (rc 0)" || fail "flag off: rc=$rc: $pso"
has "flag off: a warning names the 40-file hard max" "$pso" "warning: worker N921 Writes project to 41 files, over the 40-file hard max"
[ -n "$(ps_brief big off)" ] && pass "flag off: the brief is written" || fail "flag off: no brief"

pso="$(unset HIMMEL_FLAG_PR_SIZE_GATE HIMMEL_FLAGS_TSV; psrun big dflt)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate at its registry default (on): 41 files are refused (rc 1)" || fail "registry default: rc=$rc: $pso"
has "registry default: the refusal names the 40-file hard max" "$pso" "40-file hard max"
[ -z "$(ps_brief big dflt)" ] && pass "registry default: a refused brief writes no doc" || fail "registry default: a refused brief wrote a doc"

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun mid)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on: 25 files (soft max only) pass (rc 0)" || fail "25 files: rc=$rc: $pso"
has "25 files: a warning names the 20-file soft max" "$pso" "over the 20-file soft max"

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun few)"; rc=$?
[ "$rc" = 0 ] && pass "3 files pass (rc 0)" || fail "3 files: rc=$rc: $pso"
lacks "3 files: no size warning" "$pso" "warning:"

PSBASE_GOOD="$PSBASE"; PSBASE="4ccb59dd6de2eba962c75f136096cd7b721ae312"  # a sha this fixture repo does not hold
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun few nobase)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a base git cannot read refuses instead of counting one file (rc 1)" || fail "unreadable base, gate on: rc=$rc: $pso"
has "the unreadable-base refusal says the Writes cannot be projected" "$pso" "cannot be projected"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun glob nobase-glob)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a glob over a base git cannot read refuses instead of counting one file (rc 1)" || fail "unreadable base, glob worker: rc=$rc: $pso"
has "the glob unreadable-base refusal says the Writes cannot be projected" "$pso" "cannot be projected"
pso="$(psrun few nobase-off)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate off: an unreadable base warns and writes the brief (rc 0)" || fail "unreadable base, gate off: rc=$rc: $pso"
has "gate off: the unreadable base is a warning" "$pso" "warning: worker N921 Writes cannot be projected"
PSBASE="$PSBASE_GOOD"

pso="$(psrun badbulk)"; rc=$?
[ "$rc" = 1 ] && pass "bulk other than mechanical is refused (rc 1)" || fail "bulk yes: rc=$rc: $pso"
[ "$rc" != 1 ] || has "the bulk refusal names the bulk key" "$pso" "bulk"

# The projection counts what a Writes list really touches. The one rule: a path names itself, a directory
# its tracked files, a glob the tracked files it matches at base; a Writes list with no path tracked at base (none named,
# empty, only new files) cannot be size-checked, so it is reported with the rule, never passed silently.
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun glob)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a Writes glob over 41 tracked files is refused (rc 1)" || fail "glob of 41 files, gate on: rc=$rc: $pso"
has "the glob refusal says the Writes expand to 41 files" "$pso" "41 files"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun mixed)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: scripts/few/ plus src/ (44 files) is refused (rc 1)" || fail "mixed roots, gate on: rc=$rc: $pso"
has "the mixed-root refusal counts both roots" "$pso" "44 files"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun rootglob)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a root-level glob over 41 tracked files is refused (rc 1)" || fail "root glob of 41 files, gate on: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun rootfile)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on: a tracked repository-root file passes (rc 0)" || fail "root file: rc=$rc: $pso"
lacks "a tracked repository-root file counts as tracked (no unverified report)" "$pso" "name no file tracked at base"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun treeglob)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: scripts/tree/* counts the 41 files under its subdirectory (rc 1)" || fail "glob matching a directory, gate on: rc=$rc: $pso"
has "the directory glob counts every file under the match" "$pso" "41 files"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun segglob)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on: scripts/xs/g-*.sh does not reach into a g-dir/ look-alike (rc 0)" || fail "star stays inside one segment: rc=$rc: $pso"
lacks "a star does not cross a slash" "$pso" "hard max"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun ddglob)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a **/ glob also matches zero directories (41 files, rc 1)" || fail "**/ glob: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun hlglob)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a trailing ** counts the nested files (rc 1)" || fail "trailing **: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun qglob)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a ? glob matches one character each (41 files, rc 1)" || fail "? glob: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun prose)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on: the word and/or is not a path (40 files, rc 0)" || fail "and/or: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun dotslash)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a ./ prefix is stripped before the projection (rc 1)" || fail "./ prefix: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun slashglob)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: a glob with a trailing slash counts the files under its directories (rc 1)" || fail "trailing-slash glob: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun paren)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on: a parenthetical note names no files (rc 0)" || fail "parenthetical: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun abspath)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on: an absolute path is not counted (40 files, rc 0)" || fail "absolute path: rc=$rc: $pso"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun new41)"; rc=$?
[ "$rc" = 1 ] && pass "pr_size_gate on: 41 new files are refused (a path absent at base counts once) (rc 1)" || fail "41 new files, gate on: rc=$rc: $pso"
has "the 41-new-files refusal says how many files" "$pso" "41 files"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun forty)"; rc=$?
[ "$rc" = 0 ] && pass "pr_size_gate on: a Writes dir of exactly 40 files passes (rc 0)" || fail "exactly 40 files: rc=$rc: $pso"
lacks "exactly 40 files: no hard-max message" "$pso" "hard max"
for pw in absent nonamed; do
    pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun $pw)"; rc=$?
    [ "$rc" = 0 ] && pass "pr_size_gate on: $pw Writes list is reported, not refused (rc 0)" || fail "$pw: rc=$rc: $pso"
    has "$pw: the report names the rule" "$pso" "warning: worker N921 Writes name no file tracked at base"
done
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun emptyw)"; rc=$?
[ "$rc" = 1 ] && has "pr_size_gate on: an empty Writes list is refused by brief-lint, not the size gate" "$pso" "brief-lint refuses the brief" || fail "emptyw: rc=$rc: $pso"
lacks "emptyw: the size gate does not refuse it" "$pso" "hard max"
has "emptyw: the report names the rule" "$pso" "warning: worker N921 Writes name no file tracked at base"

pso="$(HIMMEL_FLAG_PR_SIZE_GATE=maybe psrun big gv)"; rc=$?
[ "$rc" = 2 ] && pass "an invalid pr_size_gate value exits 2 (configuration error)" || fail "invalid flag value: rc=$rc: $pso"
lacks "an invalid pr_size_gate value prints no traceback" "$pso" "Traceback"
has "an invalid pr_size_gate value is named" "$pso" "pr_size_gate"
pso="$(HIMMEL_FLAGS_TSV="$WORK/no-such-registry.tsv" psrun big gr)"; rc=$?
[ "$rc" = 2 ] && pass "an unreadable flag registry exits 2 (configuration error)" || fail "unreadable registry: rc=$rc: $pso"
lacks "an unreadable flag registry prints no traceback" "$pso" "Traceback"

# ---- the monitored size escape ----
SZK=$(printf 'HIMMEL-%s' 9201)  # the key of the ps_workers fixture, built so the line holds no literal ticket key
# Every refusal and every bulk: mechanical use writes a SIZE-ESCALATE row to <handover root>/.locks/size-escalate.tsv;
# only a chief-signed size-override record lets a refused brief through; a trust-path brief over the soft band and a
# brief past the 300-file cap go to the operator whatever the chief signs.
OV="$HERE/size-override.sh"; SEL="$WORK/handovers/.locks/size-escalate.tsv"
PSHOME="$WORK/ps-home"; mkdir -p "$PSHOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$PSHOME/.config/himmel/go-hmac.key"
sel_count() { grep -c "^SIZE-ESCALATE" "$SEL" 2>/dev/null || true; }
ps_workers trustsoft scripts/ci/ ''
ps_workers huge "$(for n in $(seq 1 301); do printf 'scripts/newd/n%s.txt ' "$n"; done)" ''
rm -f "$SEL"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun big esc1)"; rc=$?
[ "$rc" = 1 ] && pass "size escape: a 41-file refusal still exits 1" || fail "size escape refusal: rc=$rc: $pso"
[ "$(sel_count)" = 1 ] && pass "size escape: the refusal writes exactly one SIZE-ESCALATE row" || fail "refusal rows: $(sel_count): $(cat "$SEL" 2>/dev/null)"  # read-sink-ok: test reads its own mktemp ledger path
has "size escape: the row names the refusal, the key, the worker and the file count" "$(cat "$SEL" 2>/dev/null)" "refuse$(printf '\t')HIMMEL-9201$(printf '\t')N921$(printf '\t')41"  # read-sink-ok: test reads its own mktemp ledger path
has "size escape: the refusal tells the chief how to sign an override" "$pso" "size-override.sh record"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun bulk esc1)"; rc=$?
[ "$rc" = 0 ] && [ "$(sel_count)" = 2 ] && pass "size escape: a bulk: mechanical use writes one more row" || fail "bulk rows: rc=$rc count=$(sel_count)"
has "size escape: the bulk row says bulk" "$(tail -n 1 "$SEL" 2>/dev/null)" "bulk$(printf '\t')HIMMEL-9201"  # read-sink-ok: test reads its own mktemp ledger path
pso="$(psrun big esc-off)"; rc=$?
[ "$rc" = 0 ] && [ "$(sel_count)" = 2 ] && pass "size escape: with the gate off nothing is escalated and no row is written" || fail "gate off rows: rc=$rc count=$(sel_count)"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 psrun few esc1)"; rc=$?
[ "$rc" = 0 ] && [ "$(sel_count)" = 2 ] && pass "size escape: a small brief writes no row" || fail "small brief rows: rc=$rc count=$(sel_count)"

# an unsigned or worker-written override does not let the brief through
printf 'SIZE-OVERRIDE\t1\tHIMMEL-9201\tN921\t41\t0\tno\tconsole:chief-x\tkeep whole\t\n' >> "$SEL"
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun big esc2)"; rc=$?
[ "$rc" = 1 ] && pass "size escape: an unsigned override row is refused (rc 1)" || fail "unsigned override: rc=$rc: $pso"
pso="$(HOME="$PSHOME" HIMMEL_CONSOLE_LEG=1 HIMMEL_FLAG_PR_SIZE_GATE=1 bash "$OV" record "$SZK" N921 --files 41 --reason "worker says so" --root "$WORK/handovers" 2>&1)"; rc=$?
[ "$rc" = 3 ] && pass "size escape: a worker cannot sign an override (rc 3)" || fail "worker record: rc=$rc: $pso"
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun big esc3)"; rc=$?
[ "$rc" = 1 ] && pass "size escape: a refused worker record leaves the brief refused (rc 1)" || fail "after worker record: rc=$rc: $pso"
# a chief-signed override lets it through
pso="$(HOME="$PSHOME" env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME=chief-t bash "$OV" record "$SZK" N921 --files 41 --reason "one scripted rename, split would break it" --root "$WORK/handovers" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "size escape: the chief signs an override" || fail "chief record: rc=$rc: $pso"
before="$(sel_count)"
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun big esc4)"; rc=$?
[ "$rc" = 0 ] && pass "size escape: a chief-signed override lets the 41-file brief through (rc 0)" || fail "signed override: rc=$rc: $pso"
[ -n "$(ps_brief big esc4)" ] && pass "size escape: the overridden brief is written" || fail "overridden brief missing"
has "size escape: the pass names the override" "$pso" "one scripted rename"
[ "$(sel_count)" = "$before" ] && pass "size escape: a brief the override lets through is not a new refusal row" || fail "override pass wrote a row"

# the operator's cases: refused even with a chief override, and the message says so
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun trustsoft esc5)"; rc=$?
[ "$rc" = 1 ] && pass "size escape: a trust-path brief over the soft band (25 files) is refused (rc 1)" || fail "trust soft: rc=$rc: $pso"
has "size escape: the trust-path refusal routes to the operator" "$pso" "operator"
[ -z "$(ps_brief trustsoft esc5)" ] && pass "size escape: the trust-path brief writes no doc" || fail "trust-path brief was written"
pso="$(HOME="$PSHOME" env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME=chief-t bash "$OV" record "$SZK" N921 --files 25 --trust yes --reason "keep whole" --root "$WORK/handovers" 2>&1)"; rc=$?
[ "$rc" = 4 ] && pass "size escape: the chief cannot sign for a trust-path brief over the soft band (rc 4)" || fail "trust record: rc=$rc: $pso"
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun trustsoft esc6)"; rc=$?
[ "$rc" = 1 ] && has "size escape: still the operator's after the attempted record" "$pso" "operator" || fail "trust soft after record: rc=$rc: $pso"
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun huge esc7)"; rc=$?
[ "$rc" = 1 ] && pass "size escape: a brief past the 300-file cap is refused (rc 1)" || fail "huge: rc=$rc: $pso"
has "size escape: the 300-file refusal says split the ticket" "$pso" "split the ticket"
pso="$(HOME="$PSHOME" env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME=chief-t bash "$OV" record "$SZK" N921 --files 301 --reason "huge" --root "$WORK/handovers" 2>&1)"; rc=$?
[ "$rc" = 4 ] && pass "size escape: the chief cannot sign for a brief past 300 files (rc 4)" || fail "huge record: rc=$rc: $pso"
pso="$(HOME="$PSHOME" env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME=chief-t bash "$OV" record "$SZK" N921 --files 41 --lines 1501 --reason "huge" --root "$WORK/handovers" 2>&1)"; rc=$?
[ "$rc" = 4 ] && pass "size escape: the chief cannot sign for a brief past 1500 lines (rc 4)" || fail "lines record: rc=$rc: $pso"
# bulk: mechanical skips only the bands the chief can rule, never a case the operator owns
ps_workers bulktrust scripts/ci/ ',"bulk":"mechanical"'
ps_workers bulkhuge "$(for n in $(seq 1 301); do printf 'scripts/newd/n%s.txt ' "$n"; done)" ',"bulk":"mechanical"'
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun bulktrust esc10)"; rc=$?
[ "$rc" = 1 ] && pass "size escape: bulk: mechanical on a trust-path brief over the soft band is refused (rc 1)" || fail "bulk trust soft: rc=$rc: $pso"
has "size escape: the bulk trust-path refusal routes to the operator" "$pso" "operator"
[ -z "$(ps_brief bulktrust esc10)" ] && pass "size escape: the bulk trust-path brief writes no doc" || fail "bulk trust-path brief was written"
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun bulkhuge esc11)"; rc=$?
[ "$rc" = 1 ] && pass "size escape: bulk: mechanical past the 300-file cap is refused (rc 1)" || fail "bulk huge: rc=$rc: $pso"
has "size escape: the bulk past-cap refusal says split the ticket" "$pso" "past the 300-file CodeRabbit cap: this cannot open as one PR; split the ticket"
lacks "size escape: the bulk past-cap refusal prints no Telegram approve line" "$pso" "/op size-approval"
lacks "size escape: the bulk past-cap refusal prints no terminal approve line" "$pso" "size-override.sh operator"
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun huge esc12)"
has "size escape: the past-cap refusal says split the ticket" "$pso" "past the 300-file CodeRabbit cap: this cannot open as one PR; split the ticket"
lacks "size escape: the past-cap refusal prints no Telegram approve line" "$pso" "/op size-approval"
lacks "size escape: the past-cap refusal prints no terminal approve line" "$pso" "size-override.sh operator"
SAFIX="$HERE/fixtures/size-approval-op-line.txt"
SAKEY=$(printf 'HIMMEL-%s' 9228)
SAD=$(sed -n 's/.* scope=\([0-9a-f]*\) .*/\1/p' "$SAFIX")
if [ -e "/var/lib/himmel/size-approvals/$SAKEY.N5216.272.$SAD" ]; then
    fail "the host holds an approval for the R7 fixture (/var/lib/himmel/size-approvals/$SAKEY.N5216.272.$SAD); gen-briefs reads it"
else
    pass "the host holds no approval for the R7 fixture"
fi
cat > "$WORK/ps-opline.json" <<PSEOF
[{"label":"N5216","keys":["$SAKEY"],"slug":"size","branch":"fix/himmel-9228-size","title":"a sized fix","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: \`git log -3 -- scripts/x\`.","writes":"scripts/ci/t1.sh $(for n in $(seq 1 271); do printf 'scripts/newd/n%s.txt ' "$n"; done)","scope":"\`scripts/ci/t1.sh\`","scope_short":"scripts/ci/t1.sh","commit":"fix(x): [$SAKEY] f"}]
PSEOF
pso="$(HOME="$PSHOME" HIMMEL_FLAG_PR_SIZE_GATE=1 psrun opline esc13)"; rc=$?
[ "$rc" = 1 ] && pass "size escape: a 272-file trust-path brief is refused (rc 1)" || fail "opline: rc=$rc: $pso"
has "size escape: the refusal names the base, the scope digest and the list ends" "$pso" "base ${PSBASE:0:12}, scope $SAD = 272 files, first scripts/ci/t1.sh, last scripts/newd/n99.txt"
has "size escape: the refusal prints the Telegram line byte for byte as the shared fixture" "$pso" "$(head -n 1 "$SAFIX")"
has "size escape: the refusal prints the terminal line" "$pso" "size-override.sh operator $SAKEY N5216 --files 272 --scope $SAD --reason keep-whole"
pso2="$(psrun trustsoft esc9)"; rc2=$?
[ "$rc2" = 0 ] && pass "size escape: with the gate off a trust-path brief over the soft band only warns (rc 0)" || fail "trust soft gate off: rc=$rc2: $pso2"

# the adopted-kit fixture holds the flags.py copy, so the size gate is reached there; a kit without it exits 2, not a traceback
[ -f "$KIT/scripts/lib/flags.py" ] && pass "the adopted-kit fixture holds the flags.py copy" || fail "the adopted-kit fixture has no flags.py copy"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 python3 "$KIT/scripts/handover/chief-kit/gen-briefs.py" "$WORK/ps-big.json" --base "$PSBASE" --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/ps-bucket-kit" --date 2026-10-08 --repo "$PS" --handover-root "$WORK/handovers-kit" --work-dir "$WORK/psw-kit" --deadline 1791475000 2>&1)"; rc=$?
[ "$rc" = 1 ] && has "an adopted kit reaches the size gate and refuses" "$pso" "40-file hard max" || fail "adopted kit, gate on: rc=$rc: $pso"
KIT2="$WORK/kit2"; cp -r "$KIT" "$KIT2"; rm -f "$KIT2/scripts/lib/flags.py"
pso="$(HIMMEL_FLAG_PR_SIZE_GATE=1 python3 "$KIT2/scripts/handover/chief-kit/gen-briefs.py" "$WORK/ps-big.json" --base "$PSBASE" --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/ps-bucket-kit2" --date 2026-10-08 --repo "$PS" --handover-root "$WORK/handovers" --work-dir "$WORK/psw-kit2" --deadline 1791475000 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "an adopted kit without flags.py exits 2 (configuration error)" || fail "kit without flags.py: rc=$rc: $pso"
lacks "an adopted kit without flags.py prints no traceback" "$pso" "Traceback"
unset HIMMEL_CONFIG_DIR

# --- S2a: with stacked_series on, a writer's `series: [<label>, ...]` writes ONE brief (Series line, grant line, the union of
# the items' Writes) and creates the ledger through series-ledger.py; the named workers get no brief or launcher. Flag off: the key is ignored. ---
export HIMMEL_CONFIG_DIR="$WORK/no-conf"; unset HIMMEL_FLAG_STACKED_SERIES
SRP="HIMMEL-9000 (the earlier fix). Source: \`git log -3 -- scripts/sa\`."
cat > "$WORK/sr-base.json" <<SREOF
[
 {"label":"N931","keys":["HIMMEL-9301"],"slug":"sr-a","branch":"feat/himmel-9301-sr-a","title":"series writer","desc":"d","why":"w","prior":"$SRP","writes":"scripts/sa/a.sh","scope":"\`scripts/sa/a.sh\` completes-ticket: no","scope_short":"a.sh","commit":"feat(sa): [HIMMEL-9301] a","series":["N932","N933"],"series_grant":{"family":"scripts/sa/","decision":388}},
 {"label":"N932","keys":["HIMMEL-9302"],"slug":"sr-b","branch":"feat/himmel-9302-sr-b","title":"series item b","desc":"d","why":"w","prior":"$SRP","writes":"scripts/sa/b.sh","scope":"\`scripts/sa/b.sh\` completes-ticket: no","scope_short":"b.sh","commit":"feat(sa): [HIMMEL-9302] b"},
 {"label":"N933","keys":["HIMMEL-9303"],"slug":"sr-c","branch":"feat/himmel-9303-sr-c","title":"series item c","desc":"d","why":"w","prior":"$SRP","writes":"scripts/sa/c.sh","scope":"\`scripts/sa/c.sh\` completes-ticket: no","scope_short":"c.sh","commit":"feat(sa): [HIMMEL-9303] c"}
]
SREOF
srmut() { # <name> <python statements editing the worker list w>: sr-<name>.json from the base
    python3 -I -c 'import json, sys; w = json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(w, open(sys.argv[2], "w"))' "$WORK/sr-base.json" "$WORK/sr-$1.json" "$2"
}
srrun() { # <name> [flag value, default 1]
    HIMMEL_FLAG_STACKED_SERIES="${2:-1}" python3 "$SUT" "$WORK/sr-$1.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/sr-b-$1" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/srw-$1" --deadline 1791475000 2>&1
}
srledger() { python3 -I "$HERE/series-ledger.py" read --ledger "$1" 2>&1; }
srsummary() { printf '%s' "$1" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(",".join(i["key"] for i in d["items"]), ",".join(i["state"] for i in d["items"]), ",".join(",".join(i["writes"]) for i in d["items"]), d["writer"], d["completes_ticket"], d["grant"], sep="|")'; }
srbad() { # <name> <python edit> <stderr fragment>: refused, rc 1, no brief, no launcher, no ledger
    srmut "$1" "$2"
    local o rc=0; o="$(srrun "$1")" || rc=$?
    [ "$rc" = 1 ] && has "S2a: $1 refusal names its cause" "$o" "$3" || fail "S2a: $1 rc=$rc: $o"
    lacks "S2a: $1 refusal is no traceback" "$o" "Traceback"
    [ -z "$(find "$WORK/sr-b-$1" -type f -print -quit 2>/dev/null)" ] && pass "S2a: $1 refusal writes no brief, launcher or ledger" || fail "S2a: $1 wrote $(find "$WORK/sr-b-$1" -type f)"
}

srmut ok 'pass'
sro="$(srrun ok)"; rc=$?
[ "$rc" = 0 ] && pass "S2a: a series writer with stacked_series on generates (rc 0)" || fail "S2a ok rc=$rc: $sro"
SRB="$WORK/sr-b-ok"; SRD="$SRB/HIMMEL-9301-N931-sr-a-2026-10-08.md"; SRL="$SRB/series/HIMMEL-9301-N931.json"
[ -f "$SRD" ] && pass "S2a: the writer's brief is written" || fail "S2a: no brief $SRD"
[ ! -e "$SRB/launch-N932.sh" ] && [ ! -e "$SRB/launch-N933.sh" ] && [ -z "$(find "$SRB" -name 'HIMMEL-9302-*' -o -name 'HIMMEL-9303-*')" ] && pass "S2a: the named workers get no brief and no launcher" || fail "S2a: a named worker got a file: $(ls "$SRB")"
[ -f "$SRB/launch-N931.sh" ] && pass "S2a: the writer gets its launcher" || fail "S2a: no writer launcher"
srbrief="$(cat "$SRD" 2>/dev/null)"  # read-sink-ok: SRD is a fixture path under this test's own mktemp dir
has "S2a: the Series line carries the sid, the ledger path and the series.md path" "$srbrief" "> **Series:** HIMMEL-9301-N931 $SRL — read docs/handover/worker-sections/series.md"
has "S2a: the grant line names the family and the operator decision" "$srbrief" "> **Series grant:** scripts/sa/ (operator decision 388)"
has "S2a: the Writes line is the union of the items' Writes" "$srbrief" "> **Writes:** scripts/sa/a.sh scripts/sa/b.sh scripts/sa/c.sh"
has "S2a: the ledger holds the three items planned, their writes, the brief doc as writer, one completes value and the grant" "$(srsummary "$(srledger "$SRL")")" "HIMMEL-9301,HIMMEL-9302,HIMMEL-9303|planned,planned,planned|scripts/sa/a.sh,scripts/sa/b.sh,scripts/sa/c.sh|$SRD|no|scripts/sa/ (operator decision 388)"
bash "$HERE/brief-lint.sh" "$SRD" 2>"$WORK/srlint.err"; rc=$?
[ "$rc" = 0 ] && pass "S2a: the series brief passes brief-lint.sh" || fail "S2a: series brief brief-lint rc=$rc: $(cat "$WORK/srlint.err")"
lacks "S2a: the .out file lists no named worker" "$(cat "$WORK/sr-ok.json.out" 2>/dev/null)" "\"label\": \"N932\""

# the brief gen-briefs wrote is read by the real next-dispatchable.sh: the Series line parses and the series worker holds the files
mkdir -p "$WORK/sr-nd/HIMMEL"
printf 'v1.0.1\tfalse\t\n' > "$WORK/sr-nd/HIMMEL.versions.tsv"
printf -- '---\nkey: "HIMMEL-9390"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "High"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-9390: wants a series file\n\n## Description\n\nEdit scripts/sa/a.sh please.\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n' > "$WORK/sr-nd/HIMMEL/HIMMEL-9390.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/sr-gh"; chmod +x "$WORK/sr-gh"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N931"}]}\n' "$SRD" > "$SRB/fleet.json"
srnd="$(HIMMEL_FLAG_STACKED_SERIES=1 NEXT_DISPATCH_JIRA_CLI="$GEN_BRIEFS_JIRA_CLI" NEXT_DISPATCH_MIRROR="$WORK/sr-nd/HIMMEL" NEXT_DISPATCH_GH_CMD="$WORK/sr-gh" bash "$HERE/next-dispatchable.sh" --workers-from "$SRB/fleet.json" --no-classify --why 2>"$WORK/srnd.err")"; rc=$?
[ "$rc" = 0 ] && pass "S2a: next-dispatchable exits 0 on the written series (rc 0)" || fail "S2a: next-dispatchable rc=$rc: $srnd"
has "S2a: next-dispatchable lists the series writer as the holder a colliding candidate stacks on" "$srnd" "STACKABLE HIMMEL-9390 $SRD"
lacks "S2a: next-dispatchable reports no unreadable ledger or doc for the written series" "$(cat "$WORK/srnd.err")" "unreadable"

# Each follow-on worker's own scope, "Do not" lines and commit text reach its ledger item (series-next.sh start prints
# them from there); the writer's item and a follow-on with no "Do not" line record no do_not key
srmut itemscope 'w[1]["scope"] = "scripts/sa/b.sh Do not touch scripts/x. Never edit scripts/y. completes-ticket: no"'
sro="$(srrun itemscope)"; rc=$?
[ "$rc" = 0 ] && pass "8583: a follow-on worker whose scope carries Do-not lines generates (rc 0)" || fail "8583: itemscope rc=$rc: $sro"
SRIL="$(ls "$WORK"/sr-b-itemscope/series/*.json)"
srit() { srledger "$SRIL" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
check_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1: [$2] != [$3]"; }
check_eq "8583: follow-on B's ledger item records its do-not lines, one entry each" "$(srit 'd["items"][1].get("do_not")')" "['Do not touch scripts/x.', 'Never edit scripts/y.']"
check_eq "8583: follow-on B's ledger item records its scope without the do-not lines" "$(srit 'd["items"][1].get("scope")')" 'scripts/sa/b.sh completes-ticket: no'
check_eq "8583: follow-on B's ledger item records its commit text" "$(srit 'd["items"][1].get("commit_text")')" "feat(sa): [HIMMEL-9302] b"
check_eq "8583: follow-on C with no Do-not line records scope and commit text and no do_not key" "$(srit '(d["items"][2].get("scope"), d["items"][2].get("commit_text"), "do_not" in d["items"][2])')" "('\`scripts/sa/c.sh\` completes-ticket: no', 'feat(sa): [HIMMEL-9303] c', False)"
check_eq "8583: the writer's own item records none of the three (its brief carries them)" "$(srit '[k for k in ("scope", "do_not", "commit_text") if k in d["items"][0]]')" "[]"
check_eq "8583: the Writes of the items are unchanged by the scope text" "$(srsummary "$(srledger "$SRIL")" | cut -d'|' -f3)" "scripts/sa/a.sh,scripts/sa/b.sh,scripts/sa/c.sh"

srbad mixed 'w[2]["scope"] ="scripts/sa/c.sh completes-ticket: yes"' "completes-ticket"
srbad nogrant 'w[0]["series_grant"] = {"family": "scripts/sa/"}' "decision"
srbad nograntkey 'del w[0]["series_grant"]' "decision"
srbad compact 'w[0]["context_guard"] = "compact"' "compact mode"
srbad fifth 'w += [dict(w[2], label="N93%d" % i, keys=["HIMMEL-930%d" % i], slug="sr-x%d" % i, branch="feat/himmel-930%d-sr-x%d" % (i, i)) for i in (4, 5)]; w[0]["series"] = ["N932", "N933", "N934", "N935"]' "at most 4"
srbad unknown 'w[0]["series"] = ["N932", "N999"]' "N999"
srbad dupkey 'w[2]["keys"] = ["HIMMEL-9302"]' "more than once"

# a manifest outside the bucket would hide the ledger from next-dispatchable.sh, which reads series/ beside the manifest
srmut mfout 'pass'
mfo="$(HIMMEL_FLAG_STACKED_SERIES=1 python3 "$SUT" "$WORK/sr-mfout.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/sr-b-mfout" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/srw-mfout" --deadline 1791475000 --manifest "$WORK/elsewhere.fleet.json" 2>&1)"; rc=$?
[ "$rc" = 1 ] && has "S2a: a manifest outside the bucket is refused" "$mfo" "not in the bucket" || fail "S2a: manifest outside the bucket rc=$rc: $mfo"
[ -z "$(find "$WORK/sr-b-mfout" -type f -print -quit 2>/dev/null)" ] && pass "S2a: the manifest refusal writes no brief, launcher or ledger" || fail "S2a: the manifest refusal wrote $(find "$WORK/sr-b-mfout" -type f)"
srmut mfin 'pass'
mfi="$(HIMMEL_FLAG_STACKED_SERIES=1 python3 "$SUT" "$WORK/sr-mfin.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/sr-b-mfin" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/srw-mfin" --deadline 1791475000 --manifest "$WORK/sr-b-mfin/x.fleet.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$WORK/sr-b-mfin/series/HIMMEL-9301-N931.json" ] && pass "S2a: a manifest in the bucket writes the ledger beside it (rc 0)" || fail "S2a: manifest in the bucket rc=$rc: $mfi"

# a ledger that already exists is exit 4 from the verb: a refusal, not a traceback, and no brief
srmut exists 'pass'
mkdir -p "$WORK/sr-b-exists/series"
python3 -I "$HERE/series-ledger.py" create --ledger "$WORK/sr-b-exists/series/HIMMEL-9301-N931.json" --sid HIMMEL-9301-N931 --completes-ticket no --writer /elsewhere.md
o="$(srrun exists)"; rc=$?
[ "$rc" = 1 ] && has "S2a: an existing ledger is a refusal that names it" "$o" "already exists" || fail "S2a: existing ledger rc=$rc: $o"
lacks "S2a: an existing ledger is no traceback" "$o" "Traceback"
[ -z "$(find "$WORK/sr-b-exists" -name '*.md' -print -quit)" ] && pass "S2a: an existing ledger leaves no brief" || fail "S2a: a brief was written beside an existing ledger"

# flag off: the series keys are ignored: one brief per worker, no ledger, and the writer's brief is the one a workers file without the keys gets
srmut off 'pass'
sroff="$(srrun off 0)"; rc=$?
[ "$rc" = 0 ] && pass "S2a: stacked_series off generates (rc 0)" || fail "S2a off rc=$rc: $sroff"
[ -f "$WORK/sr-b-off/HIMMEL-9302-N932-sr-b-2026-10-08.md" ] && [ ! -e "$WORK/sr-b-off/series" ] && pass "S2a: flag off writes a brief per worker and no ledger" || fail "S2a: flag off wrote: $(find "$WORK/sr-b-off")"
srmut plain 'for x in w: x.pop("series", None); x.pop("series_grant", None)'
srrun plain 0 >/dev/null
norm() { sed -E 's#BZ-N[0-9]+-[0-9a-f]{8}#NONCE#g; s#sr-b-[a-z]+#BUCKET#g' "$1"; }
[ "$(norm "$WORK/sr-b-off/HIMMEL-9301-N931-sr-a-2026-10-08.md")" = "$(norm "$WORK/sr-b-plain/HIMMEL-9301-N931-sr-a-2026-10-08.md")" ] && pass "S2a: flag off, the writer's brief is byte-identical to the one without the series keys (I8)" || fail "S2a: flag off changed the writer's brief"
lacks "S2a: flag off, the brief carries no Series line" "$(cat "$WORK/sr-b-off/HIMMEL-9301-N931-sr-a-2026-10-08.md")" "**Series"
unset HIMMEL_CONFIG_DIR

# ---- the core gate (spec section 3 and 4) ----
# gen-briefs asks the jira CLI (the fixture stand-in above) per key, always (there is no flag): a core build
# leg with no signed minerva spec is refused; a bypass (design leg, Bug, emergency) passes with one core-gate.jsonl row; a mirror
# miss and a core-check that cannot run refuse.
CG="$WORK/cg"; mkdir -p "$CG/mirror" "$CG/specs" "$CG_STUB_SIGNED"
export HIMMEL_CONFIG_DIR="$WORK/no-conf"
printf '{"lastSync":"2026-11-01T00:00:00Z"}\n' > "$CG/mirror/.cursor.json"
cg_mirror() { # <KEY> <type> <priority> <labels json array>: a mirror ticket the proof check and core-check both read
    printf -- '---\nkey: "%s"\nstatus: "To Do"\ntype: "%s"\npriority: "%s"\nlabels: %s\n---\n# %s: t\n\n## Description\n\nEdit the thing.\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n\n## Comments\n\nnone\n' "$1" "$2" "$3" "$4" "$1" > "$CG/mirror/$1.md"
}
cg_workers() { # <name> <key> <writes> [extra json members]
    cat > "$CG/$1.json" <<CGEOF
[{"label":"N941","keys":["$2"],"slug":"cg","branch":"feat/himmel-9400-cg","title":"a core fix","desc":"d","why":"w","prior":"HIMMEL-9000 (the earlier fix). Source: \`git log -3 -- scripts/x\`.","writes":"$3","scope":"\`$3\`","scope_short":"x","commit":"feat(x): [$2] f"$4}]
CGEOF
}
cgrun() { # <name>: the same bucket per name, so a re-run is a re-run
    GEN_BRIEFS_MIRROR="$CG/mirror" python3 "$SUT" "$CG/$1.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$CG/b-$1" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$CG/w-$1" --deadline 1791475000 2>&1
}
cg_brief() { ls "$CG/b-$1"/*-N941-cg-2026-10-08.md 2>/dev/null; }
cg_log() { printf '%s' "$CG/b-$1/core-gate.jsonl"; }
cg_rows() { [ -f "$(cg_log "$1")" ] && grep -c "\"key\": \"$2\"" "$(cg_log "$1")" || echo 0; }
cg_field() { python3 -I -c 'import json, sys; [print(r.get(sys.argv[3])) for r in map(json.loads, open(sys.argv[1])) if r["key"] == sys.argv[2]]' "$(cg_log "$1")" "$2" "$3" 2>/dev/null; }
cg_sign() { # <name> <key>: the stand-in's spec-check answers SPEC ok for that key, with this spec path and record id
    mkdir -p "$CG/specs/$1"
    printf '# %s: a fixture design\n' "$2" > "$CG/specs/$1/spec-$1-2026-11-01.md"
    printf '%s O-R1-%s\n' "$CG/specs/$1/spec-$1-2026-11-01.md" "$1" > "$CG_STUB_SIGNED/$2"
}

CORE_WRITES="scripts/handover/chief-kit/next-dispatchable.sh"
cg_mirror HIMMEL-9411 Task Medium '[]'
cg_workers nospec HIMMEL-9411 "$CORE_WRITES" ''
cgo="$(cgrun nospec)"; rc=$?
[ "$rc" = 1 ] && has "a build leg with core Writes and no spec exits 1 naming the missing spec" "$cgo" "HIMMEL-9411 is core" || fail "a build leg with core Writes and no spec exits 1 naming the missing spec (rc=$rc): $cgo"
has "the refusal names the spec-check line (NO-SPEC <KEY>)" "$cgo" "NO-SPEC HIMMEL-9411"
has "the refusal names the matched path" "$cgo" "$CORE_WRITES"
has "the refusal says how to sign: minerva, then jira release operator spec" "$cgo" "run minerva, then jira release operator spec"
[ -z "$(cg_brief nospec)" ] && [ ! -e "$CG/b-nospec/launch-N941.sh" ] && pass "a refused core worker gets no brief and no launcher" || fail "a refused core worker was written"
[ "$(cg_rows nospec HIMMEL-9411)" = 1 ] && [ "$(cg_field nospec HIMMEL-9411 outcome)" = refused ] && pass "the refusal appends one refused row" || fail "refused row: $(cat "$(cg_log nospec)" 2>/dev/null)"
cgo="$(cgrun nospec)"; rc=$?
[ "$rc" = 1 ] && [ "$(cg_rows nospec HIMMEL-9411)" = 1 ] && pass "a re-run reaching the same outcome for the same key and brief appends no second row" || fail "re-run rows=$(cg_rows nospec HIMMEL-9411) rc=$rc"

cg_sign one HIMMEL-9412
cg_mirror HIMMEL-9412 Task Medium '[]'
cg_workers signed HIMMEL-9412 "$CORE_WRITES" ''
cgo="$(cgrun signed)"; rc=$?
[ "$rc" = 0 ] && pass "a core build leg with a signed spec generates (rc 0)" || fail "signed rc=$rc: $cgo"
has "the signed brief carries a Spec: line with the spec path and record id" "$(cat "$(cg_brief signed)" 2>/dev/null)" "> **Spec:** HIMMEL-9412 $CG/specs/one/spec-one-2026-11-01.md (O-R1-"
[ "$(cg_rows signed HIMMEL-9412)" = 1 ] && [ "$(cg_field signed HIMMEL-9412 outcome)" = spec ] && pass "the signed spec appends one spec row" || fail "spec row: $(cat "$(cg_log signed)" 2>/dev/null)"
BRIEF_LINT_MIRROR="$CG/mirror" bash "$HERE/brief-lint.sh" "$(cg_brief signed)" 2>"$CG/lint.err"; rc=$?
[ "$rc" = 0 ] && pass "the signed brief passes brief-lint.sh" || fail "signed brief-lint rc=$rc: $(cat "$CG/lint.err")"

cg_mirror HIMMEL-9413 Task Medium '["core"]'
cg_workers design HIMMEL-9413 "docs/internals/core-gate-fixture.md" ''
cgo="$(cgrun design)"; rc=$?
[ "$rc" = 0 ] && pass "a label-only design leg (docs-only Writes) passes (rc 0)" || fail "design rc=$rc: $cgo"
has "the design leg's brief carries a Core gate bypass=design line" "$(cat "$(cg_brief design)" 2>/dev/null)" "> **Core gate:** HIMMEL-9413 bypass=design"
[ "$(cg_rows design HIMMEL-9413)" = 1 ] && [ "$(cg_field design HIMMEL-9413 outcome)" = bypass ] && [ "$(cg_field design HIMMEL-9413 bypass)" = design ] && pass "the design leg appends one bypass row of kind design" || fail "design row: $(cat "$(cg_log design)" 2>/dev/null)"

NK=HIMMEL-9640
cg_mirror HIMMEL-9640 Task Medium '[]'
touch "$CG_STUB_NEEDS/HIMMEL-9640"
cg_workers needs HIMMEL-9640 "$CORE_WRITES" ''
cgo="$(cgrun needs)"; rc=$?
[ "$rc" = 1 ] && has "a BYPASS-NEEDS-SPEC key is refused naming the missing record" "$cgo" "no spec-review record for HIMMEL-9640" || fail "a BYPASS-NEEDS-SPEC key is refused naming the missing record (rc=$rc): $cgo"
has "the BYPASS-NEEDS-SPEC refusal says the bypass waives the signature, never the spec" "$cgo" "waives the signature, never the spec"
lacks "the BYPASS-NEEDS-SPEC refusal is not a CORE-CHECK-FAILED" "$cgo" "CORE-CHECK-FAILED"
[ -z "$(cg_brief needs)" ] && [ ! -e "$CG/b-needs/launch-N941.sh" ] && pass "a BYPASS-NEEDS-SPEC worker gets no brief and no launcher" || fail "a BYPASS-NEEDS-SPEC worker was written"
[ "$(cg_rows needs $NK)" = 1 ] && [ "$(cg_field needs $NK outcome)" = refused ] && [ "$(cg_field needs $NK bypass)" = operator ] && pass "the refusal appends one refused row with bypass set" || fail "needs row: $(cat "$(cg_log needs)" 2>/dev/null)"
[ "$(python3 -I -c 'import json, sys; print(*[len(json.loads(l)) for l in open(sys.argv[1])])' "$(cg_log needs)" 2>/dev/null)" = 9 ] && pass "the refused row has exactly the nine keys" || fail "needs row keys: $(cat "$(cg_log needs)" 2>/dev/null)"
cgo="$(cgrun needs)"; rc=$?
[ "$rc" = 1 ] && [ "$(cg_rows needs $NK)" = 1 ] && pass "a re-run of the BYPASS-NEEDS-SPEC refusal appends no second row" || fail "needs re-run rows=$(cg_rows needs $NK) rc=$rc"
cg_mirror HIMMEL-9640 Task Medium '["core"]'
cg_workers needsdesign HIMMEL-9640 "docs/internals/core-gate-fixture.md" ''
cgo="$(cgrun needsdesign)"; rc=$?
[ "$rc" = 0 ] && [ "$(cg_field needsdesign $NK bypass)" = design ] && pass "a docs-only design leg for a key with no spec is still allowed" || fail "needs design rc=$rc: $cgo $(cat "$(cg_log needsdesign)" 2>/dev/null)"
export CG_SPECS_DIR="$CG/specs/needs"; mkdir -p "$CG_SPECS_DIR"
for f in HIMMEL-9640-spec.md HIMMEL-9640-plan.md HIMMEL-9640-critic-spec-r1.md; do printf '# fixture\n' > "$CG_SPECS_DIR/$f"; done
cgo_with="$(cgrun needs)"; rc_with=$?
rm -f "$CG_SPECS_DIR/"*
cgo_without="$(cgrun needs)"; rc_without=$?
[ "$rc_with" = "$rc_without" ] && [ "$cgo_with" = "$cgo_without" ] && [ "$rc_with" = 1 ] && pass "gen-briefs decides nothing from spec files: the same answer with the fixture specs removed" || fail "specs changed the answer: rc $rc_with vs $rc_without: [$cgo_with] vs [$cgo_without]"
rm -f "$CG_STUB_NEEDS/HIMMEL-9640"

# an absolute Writes path under the handover root is a relative non-core stand-in, never a --paths argument (the CLI refuses absolute ones)
cg_mirror HIMMEL-9440 Task Medium '["core"]'
cg_workers absdesign HIMMEL-9440 "$WORK/handovers/specs/core-gate-fixture.md" ''
cgo="$(cgrun absdesign)"; rc=$?
[ "$rc" = 0 ] && pass "a label-only leg writing an absolute handover-root .md is a design leg (rc 0)" || fail "absolute design rc=$rc: $cgo"
[ "$(cg_field absdesign HIMMEL-9440 bypass)" = design ] && pass "the absolute-path design leg appends one bypass row of kind design" || fail "absolute design row: $(cat "$(cg_log absdesign)" 2>/dev/null)"

cg_mirror HIMMEL-9414 Bug Medium '[]'
cg_workers bug HIMMEL-9414 "$CORE_WRITES" ''
cgo="$(cgrun bug)"; rc=$?
[ "$rc" = 0 ] && pass "a Bug on core Writes passes (rc 0)" || fail "bug rc=$rc: $cgo"
has "the Bug's brief carries a Core gate bypass=bug line" "$(cat "$(cg_brief bug)" 2>/dev/null)" "> **Core gate:** HIMMEL-9414 bypass=bug"
[ "$(cg_rows bug HIMMEL-9414)" = 1 ] && [ "$(cg_field bug HIMMEL-9414 bypass)" = bug ] && pass "the Bug appends one bypass row of kind bug" || fail "bug row: $(cat "$(cg_log bug)" 2>/dev/null)"

cg_mirror HIMMEL-9415 Bug Highest '[]'
cg_workers emergency HIMMEL-9415 "$CORE_WRITES" ''
cgo="$(cgrun emergency)"; rc=$?
[ "$rc" = 0 ] && pass "an emergency (a Bug at Highest) on core Writes passes (rc 0)" || fail "emergency rc=$rc: $cgo"
has "the emergency's brief carries a Core gate bypass=emergency line" "$(cat "$(cg_brief emergency)" 2>/dev/null)" "> **Core gate:** HIMMEL-9415 bypass=emergency"
[ "$(cg_rows emergency HIMMEL-9415)" = 1 ] && [ "$(cg_field emergency HIMMEL-9415 bypass)" = emergency ] && pass "the emergency appends one bypass row of kind emergency" || fail "emergency row: $(cat "$(cg_log emergency)" 2>/dev/null)"

# a design leg whose Writes match core-paths is refused, never bypassed (a SKILL.md under the bus plugin is a docs file in a core directory)
cg_mirror HIMMEL-9416 Task Medium '["core"]'
cg_workers designcore HIMMEL-9416 "marketplace/plugins/himmel-bus/SKILL.md" ''
cgo="$(cgrun designcore)"; rc=$?
[ "$rc" = 1 ] && has "a design leg writing core code is refused, not bypassed" "$cgo" "HIMMEL-9416 is core" || fail "design-core rc=$rc: $cgo"
[ -z "$(cg_brief designcore)" ] && [ "$(cg_field designcore HIMMEL-9416 outcome)" = refused ] && pass "the refused design-core leg writes no brief and one refused row" || fail "design-core: $(cat "$(cg_log designcore)" 2>/dev/null)"

# a free-text bypass is refused naming the key (the key is in the mirror, so the refusal is the bypass key and nothing else)
cg_mirror HIMMEL-9417 Task Medium '[]'
cg_workers cb HIMMEL-9417 "$CORE_WRITES" ',"core_bypass":"operator said so"'
cgo="$(cgrun cb)"; rc=$?
[ "$rc" = 1 ] && has "a worker carrying core_bypass is refused naming it" "$cgo" "core_bypass is refused" || fail "core_bypass rc=$rc: $cgo"
cg_workers bp HIMMEL-9417 "$CORE_WRITES" ',"bypass":"emergency"'
cgo="$(cgrun bp)"; rc=$?
[ "$rc" = 1 ] && has "a worker carrying bypass is refused naming it" "$cgo" "bypass is refused" || fail "bypass rc=$rc: $cgo"
[ -z "$(cg_brief cb)$(cg_brief bp)" ] && pass "a worker carrying a bypass key gets no brief" || fail "a bypass-key worker was written"

# a mirror miss: the worker is refused (neither core nor a bypass can be proven), one unknown row
touch "$CG_STUB_UNKNOWN/HIMMEL-9418"  # the stand-in answers UNKNOWN for a marked key; any other key it has no mirror file for is NOT-CORE
cg_workers miss HIMMEL-9418 "$CORE_WRITES" ''
cgo="$(cgrun miss)"; rc=$?
[ "$rc" = 1 ] && has "a mirror miss is refused" "$cgo" "HIMMEL-9418" || fail "mirror miss rc=$rc: $cgo"
[ "$(cg_rows miss HIMMEL-9418)" = 1 ] && [ "$(cg_field miss HIMMEL-9418 outcome)" = unknown ] && pass "the mirror miss appends one unknown row" || fail "unknown row: $(cat "$(cg_log miss)" 2>/dev/null)"

# a core-check that cannot run is a refusal
cg_mirror HIMMEL-9419 Task Medium '[]'
cg_workers nodist HIMMEL-9419 "$CORE_WRITES" ''
cgo="$(GEN_BRIEFS_JIRA_CLI="$CG/no-dist/index.js" cgrun nodist)"; rc=$?
[ "$rc" = 1 ] && has "no dist/: CORE-CHECK-FAILED" "$cgo" "CORE-CHECK-FAILED" || fail "no dist on rc=$rc: $cgo"
[ "$(cg_field nodist HIMMEL-9419 outcome)" = failed ] && pass "no dist/ appends a failed row" || fail "failed row: $(cat "$(cg_log nodist)" 2>/dev/null)"
[ -z "$(cg_brief nodist)" ] && pass "a core-check that cannot run writes no brief" || fail "a brief was written with no dist"
printf '// valid JavaScript that exits 0 and prints no verdict line\n' > "$CG/junk.js"
cgo="$(GEN_BRIEFS_JIRA_CLI="$CG/junk.js" cgrun nodist)"; rc=$?
[ "$rc" = 1 ] && has "a core-check that prints nothing parseable is CORE-CHECK-FAILED" "$cgo" "CORE-CHECK-FAILED" || fail "unparseable rc=$rc: $cgo"
printf "console.log('BYPASS HIMMEL-9419');\n" > "$CG/truncated.js"
cgo="$(GEN_BRIEFS_JIRA_CLI="$CG/truncated.js" cgrun nodist)"; rc=$?
[ "$rc" = 1 ] && has "a truncated BYPASS line (no kind, no reason) is CORE-CHECK-FAILED, never a bypass" "$cgo" "CORE-CHECK-FAILED" || fail "truncated BYPASS rc=$rc: $cgo"
[ -z "$(cg_brief nodist)" ] && pass "a truncated BYPASS line writes no brief" || fail "a brief was written for a truncated BYPASS line"

# no flag exists: the old flag variable set to 0 changes nothing, so a core key with no signed spec is still refused
# (the old flag-off row, which generated the brief, is a refusal now), and so are a mirror miss and a missing CLI
cg_mirror HIMMEL-9421 Task Medium '[]'
cg_workers off HIMMEL-9421 "$CORE_WRITES" ''
cgo="$(HIMMEL_FLAG_CORE_GATE=0 cgrun off)"; rc=$?
[ "$rc" = 1 ] && has "the old flag variable set to 0: a core build leg with no spec is refused" "$cgo" "HIMMEL-9421 is core" || fail "old flag 0 rc=$rc: $cgo"
[ -z "$(cg_brief off)" ] && [ "$(cg_rows off HIMMEL-9421)" = 1 ] && pass "the refusal writes no brief and one refused row" || fail "old flag 0 wrote a brief or a wrong log: $(cat "$(cg_log off)" 2>/dev/null)"
cg_sign two HIMMEL-9421
cg_workers on9421 HIMMEL-9421 "$CORE_WRITES" ''
cgo="$(cgrun on9421)"; rc=$?
[ "$rc" = 0 ] && pass "the same worker with a signed spec generates (rc 0)" || fail "on9421 rc=$rc: $cgo"

WS="$WORK/handovers/yotamleo/himmel/specs"; mkdir -p "$WS/designs" "$WS/ledgers/spec-rounds"
NOLEDGER_KEY="HIMMEL-9432" EMPTY_KEY="HIMMEL-9439"
# shellcheck disable=SC2016  # the instruction line's backticks are literal product text
INSTR='each id is a `## Ticket coverage` line: `- <id>: done` or `- <id>: deferred → HIMMEL-<n>`'
cg_signed_at() {
    printf '%s O-R1-%s\n' "$2" "$1" > "$CG_STUB_SIGNED/$1"
}
cg_mirror HIMMEL-9431 Task Medium '[]'; cg_signed_at HIMMEL-9431 "$WS/designs/HIMMEL-9431-fold.md"
printf -- '- m-a (minor) spec r3 %s\n- c1 (minor; out-of-closure) spec r4 %s\n' "$WS/designs/HIMMEL-9431-fold.md.critic-spec-r3.md" "$WS/designs/HIMMEL-9431-fold.md.critic-spec-r4.md" > "$ROUTE_STUB/HIMMEL-9431-fold.md.fold"
cg_workers r13 HIMMEL-9431 "$CORE_WRITES" ''
: > "$ROUTE_LOG"; cgo="$(cgrun r13)"; rc=$?
B13="$(cat "$(cg_brief r13)" 2>/dev/null)"
[ "$rc" = 0 ] && pass "R13: a signed key with folded findings generates (rc 0)" || fail "R13 rc=$rc: $cgo"
has "R13: the brief carries the Folded critic findings heading" "$B13" "## Folded critic findings"
has "R13: the brief carries the first fold-list line" "$B13" "- m-a (minor) spec r3 $WS/designs/HIMMEL-9431-fold.md.critic-spec-r3.md"
has "R13: the brief carries the second fold-list line" "$B13" "- c1 (minor; out-of-closure) spec r4 $WS/designs/HIMMEL-9431-fold.md.critic-spec-r4.md"
has "R13: the block ends with the Ticket coverage instruction line" "$B13" "$INSTR"
has "R13: the stand-in saw fold-list --spec <the SPEC ok path>" "$(cat "$ROUTE_LOG")" "fold-list --spec $WS/designs/HIMMEL-9431-fold.md"
BRIEF_LINT_MIRROR="$CG/mirror" bash "$HERE/brief-lint.sh" "$(cg_brief r13)" 2>"$CG/lint13.err"; rc=$?
[ "$rc" = 0 ] && pass "R13: the brief with the folded block passes brief-lint.sh" || fail "R13 brief-lint rc=$rc: $(cat "$CG/lint13.err")"
cg_mirror HIMMEL-9432 Task Medium '[]'; cg_signed_at HIMMEL-9432 "$WS/designs/HIMMEL-9432-fold.md"
cg_workers r13none HIMMEL-9432 "$CORE_WRITES" ''
cgo="$(cgrun r13none)"; rc=$?
B13N="$(cat "$(cg_brief r13none)" 2>/dev/null)"
[ "$rc" = 0 ] && has "R13 sibling: a key with no ledger gets none recorded" "$B13N" "> **Folded critic findings:** none recorded ($NOLEDGER_KEY has no round ledger)" || fail "R13 sibling rc=$rc: $cgo"
lacks "R13 sibling: no Folded critic findings heading when nothing is folded" "$B13N" "## Folded critic findings"
printf '{"v":1}\n' > "$WS/ledgers/spec-rounds/HIMMEL-9439.jsonl"
cg_mirror HIMMEL-9439 Task Medium '[]'; cg_signed_at HIMMEL-9439 "$WS/designs/HIMMEL-9439-fold.md"
cg_workers r13empty HIMMEL-9439 "$CORE_WRITES" ''
cgo="$(cgrun r13empty)"; rc=$?
[ "$rc" = 0 ] && has "R13 sibling: a key whose ledger folds nothing says so" "$(cat "$(cg_brief r13empty)" 2>/dev/null)" "> **Folded critic findings:** none recorded (${EMPTY_KEY}'s ledger folds no finding)" || fail "R13 empty-ledger rc=$rc: $cgo"
cg_mirror HIMMEL-9433 Task Medium '[]'; cg_signed_at HIMMEL-9433 "$WS/designs/HIMMEL-9687-borrowed.md"
printf -- '- m-z (minor) spec r3 %s\n' "$WS/designs/HIMMEL-9687-borrowed.md.critic-spec-r3.md" > "$ROUTE_STUB/HIMMEL-9687-borrowed.md.fold"
cg_workers r13b HIMMEL-9433 "$CORE_WRITES" ''
: > "$ROUTE_LOG"; cgo="$(cgrun r13b)"; rc=$?
[ "$rc" = 0 ] && has "R13b: the brief carries the borrowed spec's folded line" "$(cat "$(cg_brief r13b)" 2>/dev/null)" "- m-z (minor) spec r3" || fail "R13b rc=$rc: $cgo"
has "R13b: the stand-in saw the SPEC ok path" "$(cat "$ROUTE_LOG")" "fold-list --spec $WS/designs/HIMMEL-9687-borrowed.md"
lacks "R13b: no fold-list path built from the worker's key" "$(grep '^fold-list' "$ROUTE_LOG")" "HIMMEL-9433"
cg_mirror HIMMEL-9438 Task Medium '[]'; cg_signed_at HIMMEL-9438 "$WS/designs/HIMMEL-9438-fold.md"
printf 'HIMMEL-9438 ledger line 3 does not parse; restore it from the state repo history\n' > "$ROUTE_STUB/HIMMEL-9438-fold.md.fail"
cg_workers r13fail HIMMEL-9438 "$CORE_WRITES" ''
cgo="$(cgrun r13fail)"; rc=$?
[ "$rc" = 1 ] && has "R13: a failing fold-list refuses the brief naming its error" "$cgo" "HIMMEL-9438 ledger line 3 does not parse" || fail "R13 fold-list failure rc=$rc: $cgo"
[ -z "$(cg_brief r13fail)" ] && pass "R13: a failing fold-list writes no brief" || fail "R13: a brief was written though fold-list failed"

T13='HIMMEL-9434 has had its writer rounds; sign it under 848, send the page to the operator, or record round-override'
cg_mirror HIMMEL-9434 Task Medium '[]'
printf '{"key":"HIMMEL-9434","spec":3,"plan":3,"writer":3,"next":"none","why":"spec round 4: HIMMEL-9434 spec round 4 needs a blocking finding in round 3 of either kind; plan round 4: HIMMEL-9434 plan round 4 needs a blocking finding in round 3 of either kind"}\n' > "$ROUTE_STUB/HIMMEL-9434.json"
cg_workers r14 HIMMEL-9434 "$WS/designs/HIMMEL-9434-x.md" ''
: > "$ROUTE_LOG"; cgo="$(cgrun r14)"; rc=$?
[ "$rc" = 1 ] && has "R14: a writer leg at next=none is refused with T13" "$cgo" "$T13" || fail "R14 rc=$rc: $cgo"
[ -z "$(cg_brief r14)" ] && [ ! -e "$CG/b-r14/launch-N941.sh" ] && pass "R14: the refused writer leg gets no brief and no launcher" || fail "R14: a brief was written for a key with no rounds left"
has "R14: round-status is asked for the key over the path's specs root" "$(cat "$ROUTE_LOG")" "round-status HIMMEL-9434 --specs $WS --json"
cg_mirror HIMMEL-9435 Task Medium '[]'
cg_workers r14full HIMMEL-9435 "$WS/designs/HIMMEL-9435-x.md" ''
cgo="$(cgrun r14full)"; rc=$?
[ "$rc" = 0 ] && [ -n "$(cg_brief r14full)" ] && pass "R14 sibling: a writer leg at next=full gets its brief" || fail "R14 sibling rc=$rc: $cgo"
lacks "R14 sibling: next=full adds no Round line" "$(cat "$(cg_brief r14full)" 2>/dev/null)" "> **Round:**"
cg_mirror HIMMEL-9437 Task Medium '[]'
printf '{"key":"HIMMEL-9437","spec":3,"plan":3,"writer":3,"next":"closure","why":"spec round 4: closure; plan round 4: HIMMEL-9437 plan round 4 needs a blocking finding in round 3 of either kind"}\n' > "$ROUTE_STUB/HIMMEL-9437.json"
cg_workers r14closure HIMMEL-9437 "$WS/designs/HIMMEL-9437-x.md" ''
cgo="$(cgrun r14closure)"; rc=$?
[ "$rc" = 0 ] && has "R14: next=closure adds the Round line" "$(cat "$(cg_brief r14closure)" 2>/dev/null)" "> **Round:** HIMMEL-9437 writer round 4 is a closure check: dispatch the critic with chief-route.ts closure-pack" || fail "R14 closure rc=$rc: $cgo"

cg_mirror HIMMEL-9687 Task Medium '[]'
cg_workers r14b HIMMEL-9687 "$WS/designs/HIMMEL-96870-x.md" ''
cgo="$(cgrun r14b)"; rc=$?
[ "$rc" = 1 ] && has "R14b: a path whose key is HIMMEL-96870 is refused for HIMMEL-9687 with T14" "$cgo" "a writer leg writes only its own keys' specs: $WS/designs/HIMMEL-96870-x.md is HIMMEL-96870" || fail "R14b rc=$rc: $cgo"
[ -z "$(cg_brief r14b)" ] && pass "R14b: the foreign-key writer leg gets no brief" || fail "R14b: a brief was written for a foreign key"
cg_workers r14bok HIMMEL-9687 "$WS/designs/HIMMEL-9687-x.md" ''
cgo="$(cgrun r14bok)"; rc=$?
[ "$rc" = 0 ] && [ -n "$(cg_brief r14bok)" ] && pass "R14b sibling: Writes naming HIMMEL-9687-x.md get the brief" || fail "R14b sibling rc=$rc: $cgo"
cg_workers r14bplan HIMMEL-9687 "$WS/plans/2026-11-04-HIMMEL-9687-x-plan.md" ''
: > "$ROUTE_LOG"; cgo="$(cgrun r14bplan)"; rc=$?
[ "$rc" = 0 ] && has "R14b: a date-prefixed plan takes its key from inside the name" "$(cat "$ROUTE_LOG")" "round-status HIMMEL-9687 --specs $WS --json" || fail "R14b date-prefixed plan rc=$rc: $cgo"
cg_workers r14bplanx HIMMEL-9687 "$WS/plans/2026-11-04-HIMMEL-96870-x-plan.md" ''
cgo="$(cgrun r14bplanx)"; rc=$?
[ "$rc" = 1 ] && has "R14b: a date-prefixed plan of another key is refused with T14" "$cgo" "a writer leg writes only its own keys' specs: $WS/plans/2026-11-04-HIMMEL-96870-x-plan.md is HIMMEL-96870" || fail "R14b date-prefixed foreign plan rc=$rc: $cgo"
cg_workers r14bfolder HIMMEL-9687 "$WS/HIMMEL-9687/notes.md" ''
cgo="$(cgrun r14bfolder)"; rc=$?
[ "$rc" = 0 ] && [ -n "$(cg_brief r14bfolder)" ] && pass "R14b: a folder-form path specs/<KEY>/ takes the folder's key" || fail "R14b folder form rc=$rc: $cgo"
cg_workers r14bdeep HIMMEL-9687 "$WS/HIMMEL-9687/sub/notes.md" ''
cgo="$(cgrun r14bdeep)"; rc=$?
[ "$rc" = 0 ] && [ -n "$(cg_brief r14bdeep)" ] && pass "R14b: a deeper path in specs/<KEY>/ still takes the folder's key" || fail "R14b deep folder rc=$rc: $cgo"
cg_workers r14bdeepx HIMMEL-9435 "$WS/HIMMEL-9687/sub/HIMMEL-9435-x.md" ''
cgo="$(cgrun r14bdeepx)"; rc=$?
[ "$rc" = 1 ] && has "R14b: a file named for the worker's key inside another key's folder is refused with T14" "$cgo" "a writer leg writes only its own keys' specs: $WS/HIMMEL-9687/sub/HIMMEL-9435-x.md is HIMMEL-9687" || fail "R14b deep foreign folder rc=$rc: $cgo"
cg_workers r14bnokey HIMMEL-9687 "$WS/designs/notes.md" ''
cgo="$(cgrun r14bnokey)"; rc=$?
[ "$rc" = 1 ] && has "R14b: a writer-leg path with no key is refused" "$cgo" "$WS/designs/notes.md has no ticket key" || fail "R14b no-key rc=$rc: $cgo"

cg_mirror HIMMEL-9436 Task Medium '[]'
printf 'HIMMEL-9436 ledger line 2 does not parse; restore it from the state repo history\n' > "$ROUTE_STUB/HIMMEL-9436.fail"
cg_workers r11 HIMMEL-9436 "$WS/designs/HIMMEL-9436-x.md" ''
cgo="$(cgrun r11)"; rc=$?
[ "$rc" = 1 ] && has "R11-brief: an unreadable ledger refuses the writer brief naming the error" "$cgo" "HIMMEL-9436 ledger line 2 does not parse" || fail "R11-brief rc=$rc: $cgo"
[ -z "$(cg_brief r11)" ] && pass "R11-brief: the unreadable-ledger writer leg gets no brief" || fail "R11-brief: a brief was written over an unreadable ledger"
rm -f "$ROUTE_STUB/HIMMEL-9436.fail"
cg_workers r11ok HIMMEL-9436 "$WS/designs/HIMMEL-9436-x.md" ''
cgo="$(cgrun r11ok)"; rc=$?
[ "$rc" = 0 ] && [ -n "$(cg_brief r11ok)" ] && pass "R11-brief sibling: the same ledger readable gets the brief" || fail "R11-brief sibling rc=$rc: $cgo"

unset HIMMEL_CONFIG_DIR

# ---- single-writer barrier: the Writes line gen-briefs writes and holds.py parse (the barrier's one parser) read the same paths
cat > "$WORK/agree.py" <<'PYEOF'
import importlib.util, os, sys
here = sys.argv[1]
sys.path.insert(0, here)
import holds
spec = importlib.util.spec_from_file_location('gen_briefs', os.path.join(here, 'gen-briefs.py'))
gb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gb)
table = [
    ('scripts/handover/chief-kit/holds.py scripts/lib/chief-context.sh', 'scripts/handover/chief-kit/holds.py scripts/lib/chief-context.sh'),
    ('scripts/handover/chief-kit/ (a.sh, sub/b.sh)', 'scripts/handover/chief-kit/a.sh scripts/handover/chief-kit/sub/b.sh'),
    ('Do not touch scripts/lib/x.sh. Edit scripts/y.sh and docs/a.md', 'scripts/y.sh docs/a.md'),
    ('`scripts/z.sh`, CLAUDE.md, README.md', 'scripts/z.sh CLAUDE.md README.md'),
    ('Impacted suites scripts/handover/test-x.sh. Edit scripts/q.sh', 'scripts/q.sh'),
    # a parenthesised path (the caller's own search hint) drops from the line: scripts/lib/ is not written
    ('find and fix the caller in scripts/c.sh (git grep -n foo scripts/lib/)', 'scripts/c.sh'),
    ('none named', 'none named'),
    # Writes lines taken from live briefs
    ('.claude/settings.json scripts/hooks/retrieval-nudge.sh scripts/hooks/test-retrieval-nudge.sh', '.claude/settings.json scripts/hooks/retrieval-nudge.sh scripts/hooks/test-retrieval-nudge.sh'),
    ('.claude/skills/ .claude/commands/ .claude/agents/ marketplace/plugins/ marketplace/.claude-plugin/marketplace.json scripts/eval/routing/ scripts/eval/README.md', '.claude/skills/ .claude/commands/ .claude/agents/ marketplace/plugins/ marketplace/.claude-plugin/marketplace.json scripts/eval/routing/ scripts/eval/README.md'),
    ('docs/setup/user-scope-claude-md-template.md scripts/agents-md/preamble.md templates/luna-second-brain/_CLAUDE.md templates/luna-second-brain/docs/', 'docs/setup/user-scope-claude-md-template.md scripts/agents-md/preamble.md templates/luna-second-brain/_CLAUDE.md templates/luna-second-brain/docs/'),
    ('.github/workflows/macos-cadence.yml scripts/ci/test-macos-cadence-concurrency.sh scripts/ci/suite-tiers.tsv scripts/ci/suite-durations.tsv', '.github/workflows/macos-cadence.yml scripts/ci/test-macos-cadence-concurrency.sh scripts/ci/suite-tiers.tsv scripts/ci/suite-durations.tsv'),
]
bad = 0
for scope, expected in table:
    line = gb.write_paths(scope)
    parsed = ' '.join(p for _k, p in holds.parse_text('> **Writes:** ' + line)) if line != 'none named' else 'none named'
    ok = line == expected and parsed == expected
    print(('agree' if ok else 'DIFF') + ' | ' + scope + ' | want ' + expected + ' | got ' + line + ' | parsed ' + parsed)
    bad += not ok
sys.exit(1 if bad else 0)
PYEOF
agree="$(cd "$REPO" && python3 -I "$WORK/agree.py" "$HERE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "gen-briefs write_paths and holds.py parse agree on all $(printf '%s\n' "$agree" | grep -c '^agree') real Writes lines" || fail "gen-briefs and holds.py parse disagree: $agree"

mk98() {
    python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; w=l[0]; exec(sys.argv[3]); json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$2" "$1" "${3:-}"
}
gen98() {
    python3 "$SUT" "$1" --base 4ccb59d --chief BZ --bucket "$2" --repo "$REPO" --handover-root "$WORK/handovers" --date 2026-10-08 --no-worktree "${@:3}" >"$WORK/g98.out" 2>"$WORK/g98.err"
}
pm HIMMEL-9801 "Edit the thing.$PROOF_TAIL"
ABS98="$WORK/handovers/yotamleo/himmel/specs/plan/HIMMEL-9801-p98.md"
mk98 'w["keys"]=["HIMMEL-9801"]; w["writes"]=sys.argv[4]' "$WORK/a98.json" "$ABS98"
gen98 "$WORK/a98.json" "$WORK/ba98"; rc=$?
A98="$WORK/ba98/HIMMEL-9801-N901-plain-fix-2026-10-08.md"
[ "$rc" = 0 ] && pass "9598 a: a bucket-absolute Writes list generates" || fail "9598 a: rc=$rc: $(cat "$WORK/g98.err")"
[ "$(grep '^> \*\*Writes:\*\* ' "$A98" 2>/dev/null)" = "> **Writes:** $ABS98" ] && pass "9598 a: the Writes line keeps the bucket-absolute path" || fail "9598 a: Writes line is [$(grep '^> \*\*Writes:\*\* ' "$A98" 2>/dev/null)]"
HANDOVER_DIR="$WORK/handovers" bash "$HERE/brief-lint.sh" "$A98" 2>"$WORK/a98.lint"; rc=$?
[ "$rc" = 0 ] && pass "9598 a: that brief passes brief-lint.sh" || fail "9598 a: brief-lint rc=$rc: $(cat "$WORK/a98.lint")"

pm HIMMEL-9802 $'Edit scripts/x.\n\nDoD\n- the row is green\n'
mkdir -p "$WORK/fresh98"; : > "$WORK/mirror98.log"
printf -- '---\nkey: HIMMEL-9802\n---\n# HIMMEL-9802: t\n\n## Description\n\nEdit scripts/x.%s\n\n## Comments\n\nnone\n' "$PROOF_TAIL" > "$WORK/fresh98/HIMMEL-9802.md"
mk98 'w["keys"]=["HIMMEL-9802"]' "$WORK/b98.json"
MIRROR_FRESH="$WORK/fresh98" MIRROR_LOG="$WORK/mirror98.log" gen98 "$WORK/b98.json" "$WORK/bb98"; rc=$?
[ "$rc" = 0 ] && pass "9598 b: a ticket edited after the last mirror refresh passes the Proof check" || fail "9598 b: rc=$rc: $(cat "$WORK/g98.err")"
has "9598 b: the refresh ran the incremental mirror for the ticket's project" "$(cat "$WORK/mirror98.log")" "project=HIMMEL"
pm HIMMEL-9802 $'Edit scripts/x.\n\nDoD\n- the row is green\n'
MIRROR_FRESH="" MIRROR_LOG="$WORK/mirror98.log" gen98 "$WORK/b98.json" "$WORK/bb98x"; rc=$?
[ "$rc" = 1 ] && has "9598 b: a ticket still lacking Proof after the refresh is refused" "$(cat "$WORK/g98.err")" "HIMMEL-9802 lacks Proof" || fail "9598 b: still-stale rc=$rc"
[ ! -e "$WORK/bb98x/launch-N901.sh" ] && pass "9598 b: nothing is written for it" || fail "9598 b: wrote a launcher for a refused ticket"
: > "$WORK/mirror98.log"
mk98 'w["keys"]=["HIMMEL-9801"]' "$WORK/b98ok.json"
MIRROR_LOG="$WORK/mirror98.log" gen98 "$WORK/b98ok.json" "$WORK/bb98ok"; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$WORK/mirror98.log" ]; } && pass "9598 b: a ticket whose mirror row is complete runs no refresh" || fail "9598 b: rc=$rc, refresh log [$(cat "$WORK/mirror98.log")]"

mk98 'w["keys"]=["HIMMEL-9801"]; w["slug"]="-".join(["wordy"]*30)' "$WORK/c101.json"
gen98 "$WORK/c101.json" "$WORK/bc101" --manifest "$WORK/c101-fleet.json"; rc=$?
[ "$rc" = 0 ] && pass "9537 a: a slug too long for the bus is trimmed, not refused" || fail "9537 a: rc=$rc: $(cat "$WORK/g98.err")"
C101="$(find "$WORK/bc101" -name '*-N901-*.md' -print -quit 2>/dev/null)"; C101="$(basename "$C101" .md)"
[ -n "$C101" ] && [ "${#C101}" -le 120 ] && pass "9537 a: the trimmed name and its -RESUME form fit the bus limit (${#C101} + 8 of 128)" || fail "9537 a: name [$C101] is ${#C101} characters"
case "$C101" in HIMMEL-9801-N901-wordy-*wordy-2026-10-08) pass "9537 a: the key, label and date are intact and the slug ends on a whole word";; *) fail "9537 a: name [$C101] lost its key, label, date or cut a word";; esac
has "9537 a: the trim is printed" "$(cat "$WORK/g98.out")" "trimmed"
has "9537 a: the printed manifest add line names the trimmed doc" "$(cat "$WORK/g98.out")" "$C101.md"
has "9537 a: the launcher names the trimmed doc" "$(cat "$WORK/bc101/launch-N901.sh" 2>/dev/null)" "$C101.md"
has "9537 a: the branch is the one given" "$(cat "$WORK/bc101/$C101.md" 2>/dev/null)" "fix/himmel-9001-plain-fix"
mk98 'w["keys"]=["HIMMEL-9801"]; w["slug"]="s"*200' "$WORK/c102.json"
gen98 "$WORK/c102.json" "$WORK/bc102"; rc=$?
C102="$(basename "$(find "$WORK/bc102" -name '*-N901-*.md' -print -quit 2>/dev/null)" .md)"
[ "$rc" = 0 ] && [ "${#C102}" -eq 120 ] && pass "9537 b: a slug with no word boundary is cut to exactly the room left (120 characters)" || fail "9537 b: rc=$rc name [$C102]"
BUSMAX_GB="$(sed -n 's/^BUS_NAME_MAX = \([0-9]*\)$/\1/p' "$SUT")"
BUSMAX_STORE="$(sed -n 's/^export const SESSION_NAME = .*{0,\([0-9]*\)}\$\/;$/\1/p' "$HERE/../../../marketplace/plugins/himmel-bus/lib/store.mjs" | awk '{print $1+1}')"
[ -n "$BUSMAX_GB" ] && [ "$BUSMAX_GB" = "$BUSMAX_STORE" ] && pass "9537 d: BUS_NAME_MAX is the bus validator's limit ($BUSMAX_STORE)" || fail "9537 d: BUS_NAME_MAX [$BUSMAX_GB] != store.mjs [$BUSMAX_STORE]"
gen98 "$WORK/a98.json" "$WORK/bc104" --manifest "$WORK/c104-fleet.json"; rc=$?
C104="$WORK/bc104/HIMMEL-9801-N901-plain-fix-2026-10-08.md"
{ [ "$rc" = 0 ] && [ -f "$C104" ]; } && pass "9537 c: a short slug keeps its name byte for byte" || fail "9537 c: rc=$rc"
lacks "9537 c: a short slug prints no trim" "$(cat "$WORK/g98.out")" "trimmed"
has "9537 c: the printed manifest add line matches the doc name" "$(cat "$WORK/g98.out")" "$C104"
has "9537 c: the launcher names the same doc" "$(cat "$WORK/bc104/launch-N901.sh" 2>/dev/null)" "$C104"

OPUS98='w["keys"]=["HIMMEL-9801"]; w["model"]="claude-opus-5-5"; w["tier"]={"category":"design","reason":"multi-step design: x"}'
mk98 "$OPUS98; w[\"context_1m\"]=\"decision 844: the operator wants the 1M window on this ticket\"" "$WORK/d98.json"
gen98 "$WORK/d98.json" "$WORK/bd98"; rc=$?
D98="$WORK/bd98/HIMMEL-9801-N901-plain-fix-2026-10-08.md"
[ "$rc" = 0 ] && pass "9598 d: an opus worker with context_1m generates" || fail "9598 d: rc=$rc: $(cat "$WORK/g98.err")"
has "9598 d: the brief carries the Context line headed-arm-worker.sh greps" "$(cat "$D98" 2>/dev/null)" "> **Context:** 1m — operator-ruling: decision 844: the operator wants the 1M window on this ticket"
has "9598 d: the launcher exports WORKER_SESSION_CONTEXT=1m" "$(cat "$WORK/bd98/launch-N901.sh" 2>/dev/null)" "export WORKER_SESSION_CONTEXT=1m"
mkdir -p "$WORK/d98arm"; sed "s|^resume_cwd:.*|resume_cwd: $WORK|" "$D98" > "$WORK/d98arm/d98-copy.md"
rc=0; d98_out="$(WORKER_SESSION_CONTEXT=1m HEADED_ARM_WORKER_PREFLIGHT="$WORK/preflight.sh" WORKER_SESSION_REPO="$WORK" bash "$HERE/headed-arm-worker.sh" --dry-run --profile worker-impl d98-N901 "$WORK/d98arm/d98-copy.md" "$WORK/d98arm/signal" 9999999999 "$WORK/d98arm/log" claude-opus-5-5 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "9598 d: headed-arm-worker.sh accepts the generated 1m brief under WORKER_SESSION_CONTEXT=1m" || fail "9598 d: launcher refused rc=$rc: $d98_out"
mk98 "$OPUS98" "$WORK/d98n.json"
gen98 "$WORK/d98n.json" "$WORK/bd98n"
lacks "9598 d: an opus worker with no context_1m gets no Context line" "$(cat "$WORK/bd98n"/*-N901-plain-fix-2026-10-08.md 2>/dev/null)" "**Context:**"
lacks "9598 d: and its launcher exports no context override" "$(cat "$WORK/bd98n/launch-N901.sh" 2>/dev/null)" "WORKER_SESSION_CONTEXT"
d98bad() {
    mk98 "$1" "$WORK/d98b.json"
    gen98 "$WORK/d98b.json" "$WORK/bd98b"; rc=$?
    [ "$rc" = 1 ] && grep -qF -- "$2" "$WORK/g98.err" && pass "9598 d: context_1m with [$1] is refused: $2" || fail "9598 d: [$1] rc=$rc: $(cat "$WORK/g98.err")"
    rm -rf "$WORK/bd98b"
}
d98bad "$OPUS98; w[\"context_1m\"]=\"decision 844: 1M\"; w[\"ab_arm\"]=\"200k\"; w[\"profile\"]=\"worker-docs\"" "cannot both be set"
d98bad 'w["keys"]=["HIMMEL-9801"]; w["context_1m"]="decision 844: 1M"; w["lane"]="claudex"' "context_1m is native-lane only"
d98bad "$OPUS98; w[\"context_1m\"]=\"  \"" "context_1m must be a non-blank"

mk98 'w.pop("prior"); w["keys"]=["HIMMEL-9801"]; w["inherited"]={"pr":4242,"authors":["someone"],"mode":"resume"}' "$WORK/e98.json"
gen98 "$WORK/e98.json" "$WORK/be98"; rc=$?
E98="$WORK/be98/HIMMEL-9801-N901-plain-fix-2026-10-08.md"
[ "$rc" = 0 ] && pass "9598 e: a resume worker with no prior key generates" || fail "9598 e: rc=$rc: $(cat "$WORK/g98.err")"
has "9598 e: its Prior art line names the query that found nothing" "$(cat "$E98" 2>/dev/null)" "> **Prior art:** none found (a plain fix)"
HANDOVER_DIR="$WORK/handovers" bash "$HERE/brief-lint.sh" "$E98" 2>"$WORK/e98.lint"; rc=$?
[ "$rc" = 0 ] && pass "9598 e: that brief passes brief-lint.sh" || fail "9598 e: brief-lint rc=$rc: $(cat "$WORK/e98.lint")"
mk98 'w.pop("prior"); w["keys"]=["HIMMEL-9801"]; w["inherited"]={"pr":4242,"authors":["someone"],"mode":"takeover"}' "$WORK/e98t.json"
gen98 "$WORK/e98t.json" "$WORK/be98t"; rc=$?
[ "$rc" = 1 ] && pass "9598 e: a takeover with no prior key is still refused" || fail "9598 e: takeover rc=$rc"

mk98 'w["keys"]=["HIMMEL-9801"]; w.pop("writes")' "$WORK/f98.json"
gen98 "$WORK/f98.json" "$WORK/bf98"; rc=$?
[ "$rc" != 0 ] && has "9598 f: a brief with an empty Writes line is refused by the lint gen-briefs runs" "$(cat "$WORK/g98.err")" "brief-lint" || fail "9598 f: empty-Writes brief generated, rc=$rc"
[ ! -e "$WORK/bf98/launch-N901.sh" ] && ! ls "$WORK/bf98"/*.md >/dev/null 2>&1 && pass "9598 f: neither a launcher nor a brief is left for it" || fail "9598 f: files left in $WORK/bf98: $(ls "$WORK/bf98" 2>&1)"

cat > "$WORK/lintfail.py" <<'PYEOF'
import importlib.util, os, subprocess, sys
here, out = sys.argv[1], sys.argv[2]
sys.path.insert(0, here)
spec = importlib.util.spec_from_file_location('gen_briefs', os.path.join(here, 'gen-briefs.py'))
gb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gb)
bad = 0
for exc in (subprocess.TimeoutExpired('bash', 120), FileNotFoundError('bash')):
    doc = os.path.join(out, type(exc).__name__ + '.md')
    open(doc, 'w').write('x')
    def boom(*a, **k):
        raise exc
    gb.subprocess.run = boom
    try:
        gb.lint_brief(doc, {'label': 'N1'}, '/h')
    except SystemExit:
        pass
    except Exception as e:
        print('uncaught ' + type(e).__name__)
        bad += 1
    if os.path.exists(doc):
        print('brief left behind: ' + doc)
        bad += 1
sys.exit(1 if bad else 0)
PYEOF
mkdir -p "$WORK/lintfail"
lf="$(python3 -I "$WORK/lintfail.py" "$HERE" "$WORK/lintfail" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "a brief-lint timeout or start failure leaves no brief behind" || fail "lint failure path: $lf"

mk98 'w["keys"]=["HIMMEL-9801"]; w["writes"]="scripts/x/ /etc/outside98.md "+sys.argv[4]' "$WORK/g98o.json" "$WORK/handovers/../esc98/y.md"
gen98 "$WORK/g98o.json" "$WORK/bg98o"; rc=$?
[ "$rc" = 0 ] && [ "$(grep '^> \*\*Writes:\*\* ' "$WORK/bg98o"/*-N901-plain-fix-2026-10-08.md 2>/dev/null)" = "> **Writes:** scripts/x/" ] && pass "9598 a: an absolute path outside the handover root, and one with .., stay off the Writes line" || fail "9598 a: outside paths rc=$rc, Writes [$(grep -h '^> \*\*Writes:\*\* ' "$WORK/bg98o"/*.md 2>/dev/null)]"

srmut lintref 'pass'
rc=0; o="$(BRIEF_LINT_JIRA_CLI="$WORK/no-such-cli.js" srrun lintref)" || rc=$?
{ [ "$rc" = 1 ] && case "$o" in *"brief-lint refuses"*) true ;; *) false ;; esac; } && pass "9598 f: a series writer brief lint refuses exits 1" || fail "9598 f: series lint refusal rc=$rc: $o"
[ -z "$(find "$WORK/sr-b-lintref" -type f \( -name '*.md' -o -name 'launch-*' -o -path '*/series/*' \) -print -quit 2>/dev/null)" ] && pass "9598 f: and leaves no brief, launcher, series ledger or lock behind" || fail "9598 f: left $(find "$WORK/sr-b-lintref" -type f)"

# I10, I16: a live_test worker gets the Live test line from the live-test verb, and an unmarked brief that reads
# like a live Jira test is refused. The verb is the stub's live-test branch, printing a canned scripts/jira/src/fixtures file.
ltmk() { python3 -I -c 'import json,sys; l=json.load(open(sys.argv[1]))[:1]; w=l[0]; exec(sys.argv[3]); json.dump(l,open(sys.argv[2],"w"))' "$WORK/workers.json" "$WORK/lt-$1.json" "$2"; }
ltrun() { python3 "$SUT" "$WORK/lt-$1.json" --base 4ccb59dd6de2eba962c75f136096cd7b721ae312 --chief HIMMEL-nextleg-2026-10-08BZ-roadmap-chief --bucket "$WORK/lt-b-$1" --date 2026-10-08 --repo "$REPO" --handover-root "$WORK/handovers" --work-dir "$WORK/lt-w-$1" --deadline 1791475000 2>&1; }
ltbrief() { cat "$WORK/lt-b-$1"/*-N901-*.md 2>/dev/null; }
LT_OK="$LT_FIXTURES/live-test-ok.json"

ltmk jira 'w["live_test"]="jira"; w["model"]="claude-opus-5-5"; w["tier"]={"category":"design","reason":"multi-step design: x"}'
o="$(LT_STUB_FILE="$LT_OK" ltrun jira)"; rc=$?
[ "$rc" = 0 ] && has "I10 a live_test jira worker gets the Live test line with HTEST and own=<its keys>" "$(ltbrief jira)" "> **Live test:** jira HTEST own=HIMMEL-9001 — every Jira write this session makes goes to HTEST; the jira CLI refuses any other project except this brief's own tickets. Create with --project HTEST." || fail "I10 live_test jira rc=$rc: $o"
lt_order="$(ltbrief jira | grep -e '^> \*\*Tier:\*\*' -e '^> \*\*Live test:\*\*' -e '^> \*\*Why' | cut -c1-14 | tr '\n' '|')"
[ "$lt_order" = '> **Tier:** op|> **Live test:|> **Why (read |' ] && pass "I10 the Live test line comes after the Tier line and before the Why" || fail "I10 line order: $lt_order"
ltmk jnone 'w["live_test"]="jira"'
o="$(ltrun jnone)"; rc=$?
{ [ "$rc" = 1 ] && [ -z "$(ltbrief jnone)" ]; } && has "I10 live_test jira with no valid test project dies naming jira.testProject" "$o" "himmelctl config set jira.testProject" || fail "I10 no test project rc=$rc: $o"
has "I10 the no-test-project death carries the verb's problem" "$o" "no JIRA_TEST_PROJECT is set"
ltmk jwork 'w["live_test"]="jira"'
o="$(LT_STUB_FILE="$LT_FIXTURES/live-test-work.json" ltrun jwork)"; rc=$?
[ "$rc" = 1 ] && has "I10 live_test jira with a work project configured dies with the verb's problem" "$o" "HIMMEL is a work project" || fail "I10 work project rc=$rc: $o"
for v in '"yes"' 'True' '{"none":""}' '{"none":"a\nb"}' '{"jira":"x"}'; do
    ltmk unk 'w["live_test"]='"$v"
    rm -rf "$WORK/lt-b-unk"; o="$(LT_STUB_FILE="$LT_OK" ltrun unk)"; rc=$?
    { [ "$rc" = 1 ] && [ -z "$(ltbrief unk)" ]; } && has "I10 an unknown live_test value $v dies" "$o" "live_test" || fail "I10 unknown live_test $v rc=$rc: $o"
done
ltmk lnone 'w["live_test"]={"none":"reads Jira, writes nothing"}; w["scope"]+=" then create throwaway test tickets in HTEST"'
o="$(LT_STUB_FILE="$LT_OK" ltrun lnone)"; rc=$?
[ "$rc" = 0 ] && has "I10 a none override prints the Live test none line with its reason" "$(ltbrief lnone)" "> **Live test:** none — reads Jira, writes nothing" || fail "I10 none override rc=$rc: $o"
has "I10 a worker with live_test none is not scanned by the tripwire" "$(ltbrief lnone)" "throwaway test tickets in HTEST"
n=0
for f in 'w["scope"]+=" then create THROWAWAY test tickets"' 'w["desc"]+=" against Live JIRA"' 'w["why"]+=" the throwaway ticket stays"' 'w["extra"]="run jira Transition on it"' 'w["tier"]={"category":"design","reason":"a jira comment probe"}; w["model"]="claude-opus-5-5"'; do
    n=$((n + 1)); ltmk trip$n "$f"
    o="$(LT_STUB_FILE="$LT_OK" ltrun trip$n)"; rc=$?
    { [ "$rc" = 1 ] && [ -z "$(ltbrief trip$n)" ] && case "$o" in *'live_test: "jira"'*'live_test: {"none": "<reason>"}'*) true ;; *) false ;; esac; } \
        && pass "I10 tripwire: an unmarked worker matching phrase row $n dies and asks for live_test" || fail "I10 tripwire row $n rc=$rc: $o"
done
ltmk tripkey 'w["prior"]+=" Fixture tickets live in HTEST-3."'
o="$(LT_STUB_FILE="$LT_OK" ltrun tripkey)"; rc=$?
[ "$rc" = 1 ] && has "I10 tripwire: an unmarked worker naming the configured test key dies naming it" "$o" "HTEST" || fail "I10 tripwire key rc=$rc: $o"
printf '{"context": false, "own_keys": [], "test_project": "TEST", "problem": null, "jira_configured": true}\n' > "$WORK/lt-key-test.json"
ltmk keyword 'w["scope"]+=" and run the tests; TESTS and TESTING stay green"'
o="$(LT_STUB_FILE="$WORK/lt-key-test.json" ltrun keyword)"; rc=$?
[ "$rc" = 0 ] && pass "I10 tripwire: test project key TEST does not match the words tests, TESTS or TESTING" || fail "I10 key TEST vs tests rc=$rc: $o"
ltmk keyhit 'w["scope"]+=" and close TEST-4"'
o="$(LT_STUB_FILE="$WORK/lt-key-test.json" ltrun keyhit)"; rc=$?
[ "$rc" = 1 ] && pass "I10 tripwire: test project key TEST matches TEST-4" || fail "I10 key TEST-4 rc=$rc: $o"
ltmk vfj 'w["live_test"]="jira"'
o="$(LT_STUB_RC=1 ltrun vfj)"; rc=$?
{ [ "$rc" = 1 ] && [ -z "$(ltbrief vfj)" ]; } && has "I10 the verb failing dies like CORE-CHECK-FAILED for a live_test jira worker" "$o" "CORE-CHECK-FAILED jira live-test" || fail "I10 verb failure (jira worker) rc=$rc: $o"
ltmk vfu ''
o="$(LT_STUB_RC=1 ltrun vfu)"; rc=$?
{ [ "$rc" = 1 ] && [ -z "$(ltbrief vfu)" ]; } && has "I10 the verb failing dies like CORE-CHECK-FAILED for an unmarked worker (the key scan never skips)" "$o" "CORE-CHECK-FAILED jira live-test" || fail "I10 verb failure (unmarked) rc=$rc: $o"
printf 'not json\n' > "$WORK/lt-junk.json"
ltmk vjunk ''
o="$(LT_STUB_FILE="$WORK/lt-junk.json" ltrun vjunk)"; rc=$?
[ "$rc" = 1 ] && has "I10 a verb answer that does not parse dies like CORE-CHECK-FAILED" "$o" "CORE-CHECK-FAILED jira live-test" || fail "I10 unparseable verb rc=$rc: $o"
lacks "I10 control: an unmarked worker with no phrase generates with no Live test line" "$b1" "**Live test:**"
# shellcheck disable=SC2016  # python source in single quotes
lt16="$(python3 -I -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gen_briefs", os.path.join(sys.argv[1], "gen-briefs.py"))
gb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gb)
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2], encoding="utf-8") if l.strip("\n")]
bad = [r for r in rows if ("accept" if gb.own_keys_ok(r[0]) else "refuse") != r[1]]
print("%d rows, %d wrong %r" % (len(rows), len(bad), bad))
sys.exit(1 if bad or len(rows) < 10 else 0)' "$HERE" "$LT_FIXTURES/own-keys.tsv" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "I16 the own= check accepts and refuses every own-keys.tsv row like parseOwnKeys ($lt16)" || fail "I16 own_keys_ok vs own-keys.tsv: $lt16"
ltmk x1 'w["keys"]=["X-1"]; w["live_test"]="jira"'
o="$(LT_STUB_FILE="$LT_OK" ltrun x1)"; rc=$?
{ [ "$rc" = 1 ] && [ -z "$(ltbrief x1)" ]; } && has "I16 X-1 passes the workers.json key check but dies at the own= check" "$o" "own=X-1" || fail "I16 X-1 rc=$rc: $o"
ltmk two 'w["keys"]=["HIMMEL-1","LUNA-22"]; w["live_test"]="jira"'
o="$(LT_STUB_FILE="$LT_OK" ltrun two)"; rc=$?
[ "$rc" = 0 ] && has "I16 HIMMEL-1,LUNA-22 passes the own= check onto the line" "$(ltbrief two)" "> **Live test:** jira HTEST own=HIMMEL-1,LUNA-22 — " || fail "I16 two keys rc=$rc: $o"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
