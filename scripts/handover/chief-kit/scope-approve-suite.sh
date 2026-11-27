#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is the check() shape of the sibling suites
# scope-approve-suite.sh - the rows of scope-approve.sh (SCOPE-10774) that need the BUILT Jira CLI.
#
#   bash scripts/handover/chief-kit/scope-approve-suite.sh
#
# Real pieces: `release core-check` (rows A3.b, A3.b.ctl) and the real ADF renderer: the stub post re-renders the fixture
# issue file through the exported renderIssue of dist/commands/mirror.js, so a comment lands in the mirror text exactly as a
# mirror run would write it (rows A1.b, A1.b.ctl, which builds the same lines through markdownToAdf, the route
# `--comment-file` takes: it joins them, and the joined mid-line Writes: still reads). The real next-dispatchable.sh judges every ticket. A checkout without the build fails by name
# (PREREQUISITE-ABSENT): this is not a test-*.sh suite, which the shell runner would also run where there is no build.
# CI runs it in the node-suites (jira) job, after the build. SCOPE_APPROVE_SUITE_CLI names another build.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SUT="$HERE/scope-approve.sh"
ND="$HERE/next-dispatchable.sh"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
TOP="$(git -C "$HERE" rev-parse --show-toplevel)"
common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)"
PRIMARY="${common%/.git}"
CLI="${SCOPE_APPROVE_SUITE_CLI:-}"
if [ -z "$CLI" ]; then
    CLI="$TOP/scripts/jira/dist/index.js"
    [ -f "$CLI" ] || CLI="$PRIMARY/scripts/jira/dist/index.js"
fi
if [ ! -f "$CLI" ]; then
    echo "PREREQUISITE-ABSENT: the built Jira CLI is required at $CLI (npm --prefix scripts/jira run build)" >&2
    exit 1
fi
DIST="$(dirname "$CLI")"

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
has() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: missing [$3] in [$2]"; fails=$((fails+1)) ;; esac; }
lacks() { case "$2" in *"$3"*) echo "FAIL - $1: found [$3] in [$2]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/scope-approve-suite.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }  # prim-ok: the suite's own scratch directory, removed by its EXIT trap
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" HANDOVER_DIR="$tmp/h" TICKET_STATUS_STATE_DIR="$tmp/ts-none" HIMMEL_ADMISSIONS_LEDGER="$tmp/ledger-none.jsonl"
mkdir -p "$HOME" "$HANDOVER_DIR"
export HIMMEL_RELEASE_STATE_DIR="$tmp/state" HIMMEL_RELEASE_KEY_DIR="$tmp/keys" HIMMEL_CONSOLE='' HIMMEL_CONSOLE_LEG='' HIMMEL_RELEASE_MANAGER=''
unset JIRA_PROJECT_KEY HIMMEL_JIRA_MIRROR SCOPE_APPROVE_TEST SCOPE_APPROVE_JIRA_CLI SCOPE_APPROVE_ND SCOPE_APPROVE_MIRROR SCOPE_APPROVE_REPO

M="$tmp/mirror"; B="$tmp/batch"; ST="$tmp/stub"; REPO="$tmp/repo"; STATE="$tmp/state"
mkdir -p "$M" "$B" "$ST/issues" "$STATE/workers" "$REPO"

mkdir -p "$REPO/scripts/handover/chief-kit" "$REPO/docs" "$REPO/scripts/lib"
: > "$REPO/scripts/handover/chief-kit/next-dispatchable.sh"; : > "$REPO/docs/x.md"; : > "$REPO/scripts/lib/a.sh"
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m fixture
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
GN="$tmp/git-none"; mkdir -p "$GN"
git -C "$GN" init -q -b main
git -C "$GN" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m init

cat > "$ST/index.mjs" <<'STUB_EOF'
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const a = process.argv.slice(2);
const st = process.env.STUB_DIR, mir = process.env.STUB_MIRROR, dist = process.env.STUB_DIST;
const arg = (n) => a[a.indexOf(n) + 1];
if (a[0] === 'release') {
  const r = spawnSync('node', [dist + '/index.js', ...a], { encoding: 'utf8' });
  process.stdout.write(r.stdout); process.stderr.write(r.stderr); process.exit(r.status ?? 1);
} else if (a[0] === 'comment') {
  const key = a[1];
  const { renderIssue } = await import(dist + '/commands/mirror.js');
  const { markdownToAdf } = await import(dist + '/adf.js');
  const adf = JSON.parse(fs.readFileSync(arg('--adf-file'), 'utf8'));
  const lines = adf.content.map((p) => p.content.map((t) => t.text).join(''));
  const body = process.env.STUB_POST === 'markdown' ? markdownToAdf(lines.join('\n')) : adf;
  fs.appendFileSync(st + '/cli.log', 'POST ' + key + '\n');
  const issue = JSON.parse(fs.readFileSync(st + '/issues/' + key + '.json', 'utf8'));
  const cf = st + '/issues/' + key + '.comments.json';
  const comments = fs.existsSync(cf) ? JSON.parse(fs.readFileSync(cf, 'utf8')) : [];
  comments.push({ id: String(comments.length + 1), created: '2026-11-23T00:00:00.000+0000', author: { displayName: 'chief' }, body });
  fs.writeFileSync(cf, JSON.stringify(comments));
  fs.writeFileSync(mir + '/' + key + '.md', renderIssue(issue, comments));
  console.error('Comment added to ' + key);
  console.log('10001');
} else if (a[0] === 'mirror') {
  fs.appendFileSync(st + '/cli.log', 'MIRROR\n');
} else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
STUB_EOF
cat > "$tmp/nd-notcore.js" <<'NC_EOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else process.exit(2);
NC_EOF
cat > "$tmp/gh" <<'GH_EOF'
#!/usr/bin/env bash
exit 1
GH_EOF
chmod +x "$tmp/gh"
cat > "$tmp/nd-wrap.sh" <<WRAP_EOF
#!/usr/bin/env bash
args=()
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = --mirror ] && [ -n "\${ND_MIRROR_OVERRIDE:-}" ]; then args+=(--mirror "\$ND_MIRROR_OVERRIDE"); shift 2; else args+=("\$1"); shift; fi
done
exec env NEXT_DISPATCH_GIT_DIR="$GN" NEXT_DISPATCH_MAIN_REF=main NEXT_DISPATCH_BODY_CACHE="$tmp/cache.json" NEXT_DISPATCH_GH_CMD="$tmp/gh" \\
    NEXT_DISPATCH_JIRA_CLI="$tmp/nd-notcore.js" NEXT_DISPATCH_DEADLINE=400 bash "$ND" --workers-dir "$STATE/workers" "\${args[@]}"
WRAP_EOF
chmod +x "$tmp/nd-wrap.sh"

CHIEF=c1
BATCH=20261123T0000-SCOPE-801
fresh() { rm -rf "$M" "$B" "$ST/issues" "$ST/cli.log"; mkdir -p "$M" "$B" "$ST/issues"; : > "$STATE/status-events.jsonl"; unset ND_MIRROR_OVERRIDE STUB_POST; }
tkt() {
    jq -n --arg k "$1" --arg t "${2:-Task}" '{key:$k, fields:{summary:"fixture", issuetype:{name:$t}, status:{name:"To Do", statusCategory:{name:"To Do"}}, priority:{name:"Medium"},
        labels:[], created:"2026-11-20T00:00:00.000+0000", updated:"2026-11-20T00:00:00.000+0000",
        description:{type:"doc",version:1,content:[
            {type:"paragraph",content:[{type:"text",text:"Something vague that names no file."}]},
            {type:"paragraph",content:[{type:"text",text:"DoD"}]},{type:"paragraph",content:[{type:"text",text:"- the row is green"}]},
            {type:"paragraph",content:[{type:"text",text:"Proof"}]},{type:"paragraph",content:[{type:"text",text:"- a RED row that fails before the change"}]}]}}}' > "$ST/issues/$1.json"
    node --input-type=module -e "
import fs from 'node:fs';
const { renderIssue } = await import('$DIST/commands/mirror.js');
fs.writeFileSync('$M/$1.md', renderIssue(JSON.parse(fs.readFileSync('$ST/issues/$1.json', 'utf8')), []));"
}
row() { jq -cn --arg k "$1" --argjson w "$2" --arg b "$BATCH" '{batch:$b,key:$k,rank:1,title:"t",excerpt:"e",writes:$w,new:[],core:false,why:"w",approve:"yes"}' >> "$B/batch.jsonl"; }
sa() {
    OUT="$(SCOPE_APPROVE_TEST=1 SCOPE_APPROVE_JIRA_CLI="$ST/index.mjs" SCOPE_APPROVE_ND="$tmp/nd-wrap.sh" SCOPE_APPROVE_MIRROR="$M" SCOPE_APPROVE_REPO="$REPO" \
        SCOPE_APPROVE_POST_TIMEOUT=30 STUB_DIR="$ST" STUB_MIRROR="$M" STUB_DIST="$DIST" STUB_POST="${STUB_POST:-}" bash "$SUT" --chief "$CHIEF" "$B/batch.jsonl" 2> "$tmp/err")"; RC=$?
}
posts() { if [ -f "$ST/cli.log" ]; then grep -c '^POST ' "$ST/cli.log" || true; else echo 0; fi; }  # swallow-ok: grep -c exits 1 on a count of 0, and prints it
nd_why() { bash "$tmp/nd-wrap.sh" --no-classify --mirror "$M" --why-ticket "$1" 2>&1; }

fresh; for k in 801 802 803; do tkt "SCOPE-$k"; done
row SCOPE-801 '["scripts/lib/a.sh"]'; row SCOPE-802 '["docs/x.md"]'; row SCOPE-803 '["scripts/lib/a.sh","docs/x.md"]'
sa
check "A1.b three rows print CLEARED three times" 3 "$(printf '%s\n' "$OUT" | grep -c '^CLEARED ')"; check "A1.b exit 0" 0 "$RC"
for k in 801 802 803; do lacks "A1.b SCOPE-$k: ND prints no no-scope gate" "$(nd_why "SCOPE-$k")" 'no-scope:'; done
has "A1.b the rendered mirror keeps one Writes line per path (one paragraph per line)" "$(sed -n '/^Writes: scripts\/lib\/a.sh$/,/^Writes: docs\/x.md$/p' "$M/SCOPE-803.md" | head -2)" "$(printf 'Writes: scripts/lib/a.sh\nWrites: docs/x.md')"

fresh; tkt SCOPE-801; row SCOPE-801 '["scripts/lib/a.sh"]'
STUB_POST=markdown sa
has "A1.b.ctl the markdown route's joined line reads: CLEARED" "$OUT" 'CLEARED SCOPE-801'; check "A1.b.ctl exit 0" 0 "$RC"
lacks "A1.b.ctl ND prints no no-scope gate" "$(nd_why SCOPE-801)" 'no-scope:'

fresh; tkt SCOPE-811; tkt SCOPE-812 Bug; tkt SCOPE-813
row SCOPE-811 '["scripts/handover/chief-kit/next-dispatchable.sh"]'; row SCOPE-812 '["scripts/handover/chief-kit/next-dispatchable.sh"]'; row SCOPE-813 '["scripts/lib/a.sh"]'
rm -rf "$tmp/nd-mirror"; mkdir -p "$tmp/nd-mirror"; cp "$M"/*.md "$tmp/nd-mirror/"; rm -f "$M/SCOPE-813.md"
ND_MIRROR_OVERRIDE="$tmp/nd-mirror" sa
has "A3.b a core path on a Task is REFUSED core" "$OUT" 'REFUSED SCOPE-811 core'
has "A3.b a Bug proposing a core path is REFUSED core" "$OUT" 'REFUSED SCOPE-812 core'
has "A3.b a key with no mirror file is REFUSED core" "$OUT" 'REFUSED SCOPE-813 core'
check "A3.b no post" 0 "$(posts)"

fresh; tkt SCOPE-821; tkt SCOPE-822 Bug
row SCOPE-821 '["scripts/lib/a.sh"]'; row SCOPE-822 '["docs/x.md"]'
sa
check "A3.b.ctl both post" 2 "$(posts)"; has "A3.b.ctl the Task clears" "$OUT" 'CLEARED SCOPE-821'; has "A3.b.ctl the Bug with non-core paths clears" "$OUT" 'CLEARED SCOPE-822'

if [ -z "${SCOPE_APPROVE_SUITE_NESTED:-}" ]; then
    rc=0; env SCOPE_APPROVE_SUITE_NESTED=1 SCOPE_APPROVE_SUITE_CLI="$tmp/no-such-build/index.js" bash "$0" > "$tmp/prereq.out" 2>&1 || rc=$?
    check "prerequisite control: with no build the suite fails (rc != 0) and names PREREQUISITE-ABSENT and the missing path" \
        "$([ "$rc" -ne 0 ] && echo failed):$(grep -c "PREREQUISITE-ABSENT: the built Jira CLI is required at $tmp/no-such-build/index.js" "$tmp/prereq.out" | sed 's/^[1-9][0-9]*$/named/')" "failed:named"
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - scope-approve-suite.sh"; exit 0; fi
echo "FAIL - scope-approve-suite.sh ($fails failure(s))"; exit 1
