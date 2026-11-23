#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is the check() shape of the sibling suites
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$HERE/../../../.." && pwd -P)"
SUT="$HERE/../next-dispatchable.sh"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails+1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$3] not in output"; printf '%s\n' "$2" | head -n 8 | cut -c1-160 ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: [$3] is in the output" ;; *) ok "$1" ;; esac; }
at_most() { awk -v v="$2" -v m="$3" 'BEGIN{exit !(v+0 <= m+0)}' && ok "$1 ($2 <= $3)" || bad "$1: $2 > $3"; }
more_than() { awk -v v="$2" -v m="$3" 'BEGIN{exit !(v+0 > m+0)}' && ok "$1 ($2 > $3)" || bad "$1: $2 <= $3"; }

# shellcheck source=../../lib/git-clean.sh
. "$REPO/scripts/lib/git-clean.sh"
git_env_scrub
COMMON="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)" || { echo "FAIL - PREREQUISITE-ABSENT: no git common dir for $REPO"; exit 1; }
PRIMARY="${COMMON%/.git}"
DIST="${CORE_CHECK_BATCH_DIST:-$PRIMARY/scripts/jira/dist/index.js}"
if [ ! -f "$DIST" ]; then echo "FAIL - PREREQUISITE-ABSENT: no built jira CLI at $DIST (npm run build in scripts/jira)"; exit 1; fi
DIST_DIR="$(cd "$(dirname "$DIST")" && pwd -P)"
DIST_ROOT="$(cd "$DIST_DIR/../../.." && pwd -P)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/core-check-batch-suite.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }  # prim-ok: the suite's own scratch directory, removed by its EXIT trap
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home" HANDOVER_DIR="$tmp/h" TICKET_STATUS_STATE_DIR="$tmp/ts-none" HIMMEL_ADMISSIONS_LEDGER="$tmp/ledger-none.jsonl"
export HIMMEL_RELEASE_STATE_DIR="$tmp/state" HIMMEL_RELEASE_KEY_DIR="$tmp/keys" JIRA_PROJECT_KEY=HIMMEL
export HIMMEL_CONSOLE='' HIMMEL_CONSOLE_LEG='' HIMMEL_RELEASE_MANAGER=''
export NEXT_DISPATCH_MAIN_REF=main NEXT_DISPATCH_BODY_CACHE=off NEXT_DISPATCH_GIT_DIR="$tmp/git-none"
mkdir -p "$HOME" "$HANDOVER_DIR" "$tmp/workers" "$tmp/bin" "$tmp/git-none"
git -C "$tmp/git-none" init -q -b main && git -C "$tmp/git-none" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m init \
    || { echo "FAIL: could not build the fixture main"; exit 1; }
# shellcheck disable=SC2016  # the stub gh body is single-quoted on purpose: $1 $2 expand when the stub runs
printf '#!/usr/bin/env bash\ncase "$1 $2" in "pr list") exit 0 ;; esac\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
export NEXT_DISPATCH_GH_CMD="$tmp/bin/gh"

mkdir -p "$tmp/wrap"
cat > "$tmp/wrap/index.js" <<'EOF'
const { spawnSync } = require('child_process');
const r = spawnSync('python3', ['-I', process.env.CCB_WRAPPER, ...process.argv.slice(2)], { stdio: 'inherit' });
process.exit(r.status === null ? 1 : r.status);
EOF
cat > "$tmp/wrap/wrapper.py" <<'EOF'
import os, subprocess, sys, time
a = sys.argv[1:]
log, mode = os.environ['CCB_LOG'], os.environ.get('CCB_MODE', 'pass')
verb = ' '.join(a[:2])
batch = a[:2] == ['release', 'core-check-batch']
def put(cpu):
    with open(log, 'a') as f:
        f.write('%s\t%s\n' % (verb, cpu))
if batch and mode == 'reject':
    sys.stderr.write("error: unknown command 'core-check-batch'\n")
    put('0.000000')
    sys.exit(1)
if batch and mode.startswith('sleep:'):
    put('0.000000')
    time.sleep(float(mode[6:]))
p = subprocess.Popen(['node', os.environ['CCB_DIST']] + a, cwd=os.environ['CCB_CWD'], stdout=subprocess.PIPE)
out = p.stdout.read()
_, status, ru = os.wait4(p.pid, 0)
if batch and mode == 'drop2':
    out = b''.join(l for l in out.splitlines(True) if l.strip() != b'== 2')
sys.stdout.buffer.write(out)
sys.stdout.buffer.flush()
if not (batch and mode.startswith('sleep:')):
    put('%.6f' % (ru.ru_utime + ru.ru_stime))
sys.exit(os.waitstatus_to_exitcode(status))
EOF
export CCB_WRAPPER="$tmp/wrap/wrapper.py" CCB_DIST="$DIST" CCB_CWD="$DIST_ROOT" CCB_LOG="$tmp/calls.log"
SHIM="$tmp/wrap/index.js"

git -C "$DIST_ROOT" ls-files > "$tmp/tracked.txt"
cat > "$tmp/gen.mjs" <<'EOF'
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
const { GEN_DIST: D, GEN_OUT: out, GEN_TRACKED: tracked, GEN_ROWS: rows, HIMMEL_RELEASE_KEY_DIR: keyDir, HIMMEL_RELEASE_STATE_DIR: root } = process.env;
const L = await import(`file://${D}/release/ledger.js`);
const ts = '2026-11-23T00:00:00Z';
const dir = join(root, 'R1');
mkdirSync(dir, { recursive: true });
const k = L.mintKey(join(keyDir, 'R1.key'));
const decl = { project: 'HIMMEL', release: 'R1', versions: ['v1.0.1'], current: 'v1.0.1', mode: 'observe', decision: '1', ts };
L.writeSigned(join(dir, 'release.json'), k, decl);
const chain = join(dir, 'operator.jsonl');
L.appendChain(chain, k, { id: 'O-R1-1', kind: 'declare', ts, decision: '1', verbatim: 'fixture', file: 'release.json', sha: L.contentSha(decl) });
const spec = join(out, 'spec.md');
writeFileSync(spec, '# a signed fixture spec\n');
L.appendChain(chain, k, { id: 'O-R1-spec', kind: 'spec', ts, decision: null, keys: ['HIMMEL-30001'], spec_path: spec, spec_sha256: createHash('sha256').update(readFileSync(spec)).digest('hex') });
L.appendChain(chain, k, { id: 'O-R1-bypass', kind: 'core-bypass', ts, decision: '2', keys: ['HIMMEL-30003'], verbatim: 'fixture' });
for (let i = 0; i < Number(rows); i++) {
  L.appendChain(chain, k, { id: `O-R1-b${i}`, kind: 'core-bypass', ts, decision: '2', keys: [`HIMMEL-9${String(i).padStart(4, '0')}`], verbatim: 'fixture' });
}
L.appendChain(chain, k, { id: 'O-R1-snap', kind: 'core-snapshot', ts, decision: null, keys: ['HIMMEL-30005'] });
// candidate files: tracked paths a Writes line can carry (FILE_RE), none of them core
const core = readFileSync(join(process.env.GEN_ROOT, 'scripts/ci/core-paths.txt'), 'utf8').split('\n').filter((l) => l && !l.startsWith('#')).map((l) => new RegExp(l));
const shape = /^(scripts|docs|marketplace|plugins|templates|tools)\/[\w.+@-]+(\/[\w.+@-]+)*$/;
const files = readFileSync(tracked, 'utf8').split('\n').filter((p) => shape.test(p) && !core.some((r) => r.test(p))).sort();
const verdict = [
  ['HIMMEL-30001', 'scripts/handover/merge-on-green.sh'],
  ['HIMMEL-30002', 'scripts/handover/chief-kit/go.sh'],
  ['HIMMEL-30003', 'scripts/cr/review-round.sh'],
  ['HIMMEL-30004', 'scripts/odd+name@v1.sh'],
  ['HIMMEL-30005', 'scripts/handover/chief-kit/brief-lint.sh'],
];
function ticket(key, path) {
  return `---\nkey: "${key}"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# ${key}: fixture\n\n## Description\n\nWrites: ${path}\n\nDoD\n- the row is green\n\nProof\n- a RED row\n`;
}
function mirror(name, n, withVerdicts) {
  const m = join(out, name, 'HIMMEL');
  mkdirSync(m, { recursive: true });
  writeFileSync(join(out, name, 'HIMMEL.versions.tsv'), 'v1.0.1\tfalse\t\nv1.0.0\ttrue\t2026-01-01\n');
  writeFileSync(join(m, '.cursor.json'), JSON.stringify({ lastSync: ts }));
  const v = withVerdicts ? verdict : [];
  for (const [key, path] of v) writeFileSync(join(m, `${key}.md`), ticket(key, path));
  for (let i = 0; i < n - v.length; i++) writeFileSync(join(m, `HIMMEL-${31000 + i}.md`), ticket(`HIMMEL-${31000 + i}`, files[i]));
}
mirror('m1', 1, false);
mirror('m15', 15, true);
mirror('m50', 50, true);
mirror('m2000', 2000, true);
mirror('mx', 2, false);
writeFileSync(join(out, 'mx', 'HIMMEL', 'HIMMEL-31000.md'), ticket('HIMMEL-31000', 'scripts/../../x'));
writeFileSync(join(out, 'mx', 'HIMMEL', 'HIMMEL-31001.md'), ticket('HIMMEL-31001', files[1]));
mirror('mok', 2, false);
writeFileSync(join(out, 'mok', 'HIMMEL', 'HIMMEL-31000.md'), ticket('HIMMEL-31000', 'scripts/x'));
writeFileSync(join(out, 'mok', 'HIMMEL', 'HIMMEL-31001.md'), ticket('HIMMEL-31001', files[1]));
EOF
FIX="$tmp/fix"; mkdir -p "$FIX"
GEN_DIST="$DIST_DIR" GEN_OUT="$FIX" GEN_TRACKED="$tmp/tracked.txt" GEN_ROWS=1000 GEN_ROOT="$DIST_ROOT" node "$tmp/gen.mjs" || { echo "FAIL - the fixture generator failed"; exit 1; }

run_cli() {
    : > "$CCB_LOG"
    CLI_OUT="$(python3 -I "$CCB_WRAPPER" "$@" 2>"$tmp/cli.err")"
}

CORE_LIST="$DIST_ROOT/scripts/ci/core-paths.txt"
run_cli release core-check --paths scripts/handover/merge-on-green.sh --mirror "$FIX/m15/HIMMEL" --core-paths "$CORE_LIST" --key HIMMEL-30001 HIMMEL-30003 HIMMEL-30005 HIMMEL-30004 HIMMEL-39999
has "fixture: signed-spec key is core" "$CLI_OUT" "CORE HIMMEL-30001 scripts/handover/merge-on-green.sh"
has "fixture: core-bypass key is BYPASS" "$CLI_OUT" "BYPASS HIMMEL-30003 operator O-R1-bypass"
has "fixture: snapshot key is grandfathered" "$CLI_OUT" "BYPASS HIMMEL-30005 grandfathered O-R1-snap core-snapshot"
has "fixture: a key outside the mirror is UNKNOWN" "$CLI_OUT" "UNKNOWN HIMMEL-39999"
run_cli release core-check --paths scripts/lib/nothing.sh --mirror "$FIX/m15/HIMMEL" --core-paths "$CORE_LIST" --key HIMMEL-30004
has "fixture: an ordinary file is NOT-CORE" "$CLI_OUT" "NOT-CORE HIMMEL-30004"
run_cli release spec-check HIMMEL-30001 HIMMEL-30002 --mirror "$FIX/m15/HIMMEL"
has "fixture: the signed spec reads SPEC ok" "$CLI_OUT" "SPEC ok HIMMEL-30001"
has "fixture: an unsigned core key reads NO-SPEC" "$CLI_OUT" "NO-SPEC HIMMEL-30002"
cpu_ok() { awk -F'\t' 'NF != 2 || $2 !~ /^[0-9]+(\.[0-9]+)?$/ {bad=1} END {exit bad ? 1 : 0}' "$1"; }
cpu_sum() { awk -F'\t' -v v="$2" '$1 ~ v {s += $2} END {printf "%.3f", s + 0}' "$1"; }
count() { awk -F'\t' -v v="$2" '$1 == v {n++} END {print n + 0}' "$1"; }
cpu_ok "$CCB_LOG" && ok "J8 every log line carries a CPU value" || bad "MEASURE-ABSENT: a log line has no CPU value"
more_than "J8 control: one single call logs a non-zero CPU value" "$(cpu_sum "$CCB_LOG" 'release')" 0

MODE=pass; BATCHFLAG=''; TO=''; CLI="$SHIM"; SUT_RUN="$SUT"
scan() {
    local m="$1"; shift
    local -a e=(HIMMEL_CORE_CHECK_BATCH="$BATCHFLAG" CCB_MODE="$MODE" NEXT_DISPATCH_MIRROR="$FIX/$m/HIMMEL")
    [ -n "$TO" ] && e+=(NEXT_DISPATCH_CORE_TIMEOUT="$TO")
    local -a unset_cli=()
    if [ -n "$CLI" ]; then e+=(NEXT_DISPATCH_JIRA_CLI="$CLI"); else unset_cli=(-u NEXT_DISPATCH_JIRA_CLI); fi
    : > "$CCB_LOG"
    OUT="$(cd "$tmp" && env ${unset_cli[@]+"${unset_cli[@]}"} "${e[@]}" bash "$SUT_RUN" --no-classify --workers-dir "$tmp/workers" "$@" 2>"$tmp/stderr")"
}
rows() { printf '%s\n' "$OUT" | grep -cE '^(LOCAL|DESIGN)' || true; }
norm() { printf '%s\n' "$OUT" | grep -v '^# WARN' | sort; }

for m in m15:15 m50:50; do
    name="${m%%:*}"; n="${m##*:}"
    scan "$name" --why --top 100
    check "P1 $name: exactly 1 core-check-batch" "$(count "$CCB_LOG" 'release core-check-batch')" 1
    check "P1 $name: no per-group core-check" "$(count "$CCB_LOG" 'release core-check')" 0
    check "P1 $name: the pool really has $n groups" "$(printf '%s\n' "$OUT" | grep -c '^# why HIMMEL-')" "$n"
done
scan m15 --why-ticket HIMMEL-31000
check "P1 --why-ticket: exactly 1 core-check-batch" "$(count "$CCB_LOG" 'release core-check-batch')" 1
check "P1 --why-ticket: no per-group core-check" "$(count "$CCB_LOG" 'release core-check')" 0
scan m1 --why --top 100
check "P1 control: a 1-group pool logs exactly 1 core call" "$(( $(count "$CCB_LOG" 'release core-check-batch') + $(count "$CCB_LOG" 'release core-check') ))" 1
scan m15 --why --top 100
has "P1 the odd-path group rides the one batch (a row for it)" "$OUT" "HIMMEL-30004"
check "P1 and the pool still logs exactly 1 core call" "$(count "$CCB_LOG" 'release core-check-batch')" 1

scan m50 --why --top 100
BATCH_CPU="$(cpu_sum "$CCB_LOG" 'release core-check')"
at_most "P2 the batched 50-pool core CPU-s" "$BATCH_CPU" 3
BATCHFLAG=off
scan m50 --why --top 100
OFF_CPU="$(cpu_sum "$CCB_LOG" 'release core-check')"
more_than "P2 control: the same scan with HIMMEL_CORE_CHECK_BATCH=off fails the ceiling" "$OFF_CPU" 3
BATCHFLAG=''

scan m50 --why --top 100; norm > "$tmp/rows-on"; ON_OUT="$OUT"; ON_LOG="$(count "$CCB_LOG" 'release core-check-batch'):$(count "$CCB_LOG" 'release core-check')"
BATCHFLAG=off; scan m50 --why --top 100; norm > "$tmp/rows-off"; OFF_OUT="$OUT"; OFF_LOG="$(count "$CCB_LOG" 'release core-check-batch'):$(count "$CCB_LOG" 'release core-check')"
BATCHFLAG=''; MODE=reject; scan m50 --why --top 100; norm > "$tmp/rows-rej"; REJ_OUT="$OUT"; REJ_LOG="$(count "$CCB_LOG" 'release core-check-batch'):$(count "$CCB_LOG" 'release core-check')"
MODE=pass
check "P3 batch on logs 1 batch and no plain call" "$ON_LOG" "1:0"
check "P3 batch off logs 50 plain calls and no batch" "$OFF_LOG" "0:50"
check "P3 a rejecting CLI logs its batch try and 50 plain calls" "$REJ_LOG" "1:50"
cmp -s "$tmp/rows-on" "$tmp/rows-off" && ok "P3 on and off give equal rows" || { bad "P3 on and off differ"; diff "$tmp/rows-on" "$tmp/rows-off" | head -n 10; }
cmp -s "$tmp/rows-on" "$tmp/rows-rej" && ok "P3 on and rejected give equal rows" || { bad "P3 on and rejected differ"; diff "$tmp/rows-on" "$tmp/rows-rej" | head -n 10; }
for v in HIMMEL-30001 HIMMEL-30002 HIMMEL-30003 HIMMEL-30004 HIMMEL-30005; do has "P3 the pool carries a row for $v" "$ON_OUT" "$v"; done
has "P3 an unsigned core key is a DESIGN row" "$ON_OUT" "DESIGN"
lacks "P3 batch on prints no WARN" "$ON_OUT" "# WARN"
lacks "P3 batch off prints no WARN" "$OFF_OUT" "# WARN"
has "P3 a rejecting CLI prints the exit WARN" "$REJ_OUT" "# WARN CORE-CHECK-BATCH-FALLBACK exit"
MODE=drop2; scan m50 --why --top 100
has "P3 control: a missing == 2 prints the headers WARN" "$OUT" "# WARN CORE-CHECK-BATCH-FALLBACK headers"
check "P3 control: it logs 1 batch and 50 plain calls" "$(count "$CCB_LOG" 'release core-check-batch'):$(count "$CCB_LOG" 'release core-check')" "1:50"
MODE=pass

MODE=sleep:8; TO=2; scan mok --why --top 100
has "P4 a batch past the timeout prints CORE-CHECK-FAILED" "$OUT" "# WARN CORE-CHECK-FAILED"
lacks "P4 a timeout falls back to nothing (kind timeout, no WARN)" "$OUT" "CORE-CHECK-BATCH-FALLBACK"
check "P4 a timeout lists no To Do row" "$(rows)" 0
MODE=pass; TO=2; scan mok --why --top 100
check "P4 control: no sleep lists the pool's To Do rows" "$(rows)" 2
MODE=pass; TO=''; scan mx --why --top 100
has "P4 a Writes line naming scripts/../../x prints the exit WARN" "$OUT" "# WARN CORE-CHECK-BATCH-FALLBACK exit"
has "P4 and then CORE-CHECK-FAILED" "$OUT" "# WARN CORE-CHECK-FAILED"
check "P4 and lists no To Do row" "$(rows)" 0
scan mok --why --top 100
check "P4 control: scripts/x lists the pool's To Do rows" "$(rows)" 2
mkdir -p "$tmp/j4"; ln -s "$REPO/scripts" "$tmp/j4/scripts"
SUT_RUN="$tmp/j4/scripts/handover/chief-kit/next-dispatchable.sh"; CLI=''
scan mok --why --top 100
has "P4 J4: no CLI and no checkout prints CORE-CHECK-FAILED" "$OUT$(head -c 400 "$tmp/stderr")" "# WARN CORE-CHECK-FAILED"
check "P4 J4: and lists no To Do row" "$(rows)" 0
SUT_RUN="$SUT"; CLI="$SHIM"
scan mok --why --top 100
check "P4 J4 control: a real checkout lists the pool's To Do rows" "$(rows)" 2

MODE=sleep:4; TO=1; scan mok --why --top 100
check "J2 a valid value (1) times the batch out" "$(rows)" 0
for bad_to in abc 0 -5 999 1.5; do
    TO="$bad_to"; scan mok --why --top 100
    check "J2 mutation control: '$bad_to' keeps 120 (the 4 s batch completes)" "$(rows)" 2
done
MODE=pass; TO=''

BATCHFLAG=''; scan m2000 --why --top 100
check "P7 the 2,000-group scan logs exactly 1 core-check-batch" "$(count "$CCB_LOG" 'release core-check-batch')" 1
check "P7 and no per-group core-check" "$(count "$CCB_LOG" 'release core-check')" 0
at_most "P7 the 2,000-group batch CPU-s" "$(cpu_sum "$CCB_LOG" 'release core-check-batch')" 10
: > "$CCB_LOG"
n=0
for f in $(sed -n 's/^\(scripts\/[^ ]*\)$/\1/p' "$tmp/tracked.txt" | head -n 60); do
    python3 -I "$CCB_WRAPPER" release core-check --paths "$f" --mirror "$FIX/m2000/HIMMEL" --core-paths "$CORE_LIST" --key HIMMEL-30004 >/dev/null 2>&1
    n=$((n + 1))
done
more_than "P7 control: $n single calls pass 10 summed CPU-s" "$(cpu_sum "$CCB_LOG" 'release core-check')" 10

echo
if [ "$fails" -eq 0 ]; then echo "core-check-batch-suite: all rows passed"; exit 0; fi
echo "core-check-batch-suite: $fails FAILED"
exit 1
