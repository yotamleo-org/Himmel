#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NODE="$(command -v node)"
FAILS=0; ROWFAIL=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); ROWFAIL=1; }
ok() { if [ "$ROWFAIL" = 0 ]; then echo "ok: $*"; fi; ROWFAIL=0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-jira-token-probe.XXXXXX") || exit 1
SRV_PID=""
cleanup() { [ -z "$SRV_PID" ] || kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

. "$REPO/scripts/lib/fixtures/keyring-stub.sh"

TOKEN="STUBTOKEN-zq81x-never-print"
HOMEDIR="$TMP/home"; mkdir -p "$HOMEDIR"
export HOME="$HOMEDIR"
unset JIRA_API_TOKEN JIRA_EMAIL JIRA_BASE_URL

cat >"$TMP/srv.js" <<'JS'
const http = require('http');
const fs = require('fs');
const dir = process.argv[2];
http.createServer((req, res) => {
  const mode = fs.readFileSync(dir + '/mode', 'utf8').trim();
  fs.appendFileSync(dir + '/hits', req.method + ' ' + req.url + '\n');
  if (mode === 'hang') return;
  if (req.url === '/ok') { res.statusCode = 200; return res.end('{"accountId":"abc"}'); }
  if (mode === 'redirect') { res.statusCode = 302; res.setHeader('Location', '/ok'); return res.end(); }
  const want = 'Basic ' + Buffer.from(process.argv[3]).toString('base64');
  const authed = req.headers.authorization === want;
  if (mode === 'nobody') { res.statusCode = authed ? 200 : 401; return res.end('{}'); }
  res.statusCode = authed ? Number(mode) : 401;
  res.end(res.statusCode === 200 ? '{"accountId":"abc"}' : '{}');
}).listen(0, '127.0.0.1', function () { fs.writeFileSync(dir + '/port', String(this.address().port)); });
JS
"$NODE" "$TMP/srv.js" "$TMP" "me@example.com:$TOKEN" &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || { echo "FAIL: stub server did not start" >&2; exit 1; }
PORT=$(cat "$TMP/port")

mkrepo() {
    local d="$TMP/$1"; mkdir -p "$d"
    printf 'JIRA_BASE_URL=http://127.0.0.1:%s\nJIRA_EMAIL=me@example.com\nJIRA_PROJECT_KEY=HIMMEL\n' "$PORT" >"$d/.env"
    [ "$2" = no ] || printf 'JIRA_API_TOKEN=%s\n' "$TOKEN" >>"$d/.env"
    echo "$d"
}

probe() {
    env -u JIRA_API_TOKEN -u JIRA_EMAIL -u JIRA_BASE_URL -u CREDENTIALS_DIRECTORY "$NODE" -e "
const { runProbe } = require('$REPO/scripts/himmelctl/lib/probes.js');
const manifest = JSON.parse(require('fs').readFileSync('$REPO/scripts/install/manifest.json', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-env-keys');
const ctx = { repoRoot: '$1', targetPath: '$REPO', scope: 'project', env: process.env, jiraChain: ${2:-1} === 1 };
console.log(JSON.stringify(runProbe(item, ctx)));
" 2>&1 | tee -a "$TMP/out.log"
}

seed() { kreset; printf 'service=himmel key=JIRA_API_TOKEN scope=user\t%s\n' "$TOKEN" >>"$KSTUB_STORE"; }

R_NOTOKEN=$(mkrepo notoken no)
R_ENVTOKEN=$(mkrepo envtoken yes)

seed; echo 200 >"$TMP/mode"
out=$(probe "$R_NOTOKEN")
echo "$out" | jq -e '.actual == "present" and (.detail | contains("verified"))' >/dev/null || fail "keyring token + 200 must read green (got: $out)"
grep -q 'GET /rest/api/3/myself' "$TMP/hits" || fail "probe must call GET /rest/api/3/myself"
ok "keyring token + HTTP 200 reads green"

seed; echo 401 >"$TMP/mode"
out=$(probe "$R_NOTOKEN")
echo "$out" | jq -e '.actual == "absent" and (.detail | contains("keyring")) and (.detail | contains("401"))' >/dev/null || fail "keyring token + 401 must read red naming keyring (got: $out)"
ok "keyring token + HTTP 401 reads red naming the keyring"

kreset; echo 200 >"$TMP/mode"
out=$(probe "$R_NOTOKEN")
echo "$out" | jq -e '.actual == "absent" and (.detail | contains("JIRA_API_TOKEN")) and (.cleanAbsence != true)' >/dev/null || fail "no key anywhere must stay red (got: $out)"
ok "a token in no source reads red"

kreset; echo 200 >"$TMP/mode"
out=$(probe "$R_ENVTOKEN")
echo "$out" | jq -e '.actual == "present" and (.detail | contains("verified"))' >/dev/null || fail ".env token + 200 must read green (got: $out)"
ok ".env token + HTTP 200 reads green"

seed; echo hang >"$TMP/mode"
out=$(probe "$R_NOTOKEN")
echo "$out" | jq -e '.actual == "degraded" and .unverified == true and (.detail | contains("could not verify"))' >/dev/null || fail "a timeout must read could-not-verify (got: $out)"
ok "timeout reads could-not-verify"

seed
dead="$TMP/dead"; mkdir -p "$dead"
printf 'JIRA_BASE_URL=http://127.0.0.1:1\nJIRA_EMAIL=me@example.com\nJIRA_PROJECT_KEY=HIMMEL\n' >"$dead/.env"
out=$(probe "$dead")
echo "$out" | jq -e '.actual == "degraded" and .unverified == true' >/dev/null || fail "a refused connection must read could-not-verify (got: $out)"
ok "network error reads could-not-verify"

kreset
none="$TMP/none"; mkdir -p "$none"
out=$(probe "$none")
echo "$out" | jq -e '.actual == "absent" and .cleanAbsence == true' >/dev/null || fail "no .env and an empty keyring must stay a clean absence (got: $out)"
ok "no .env and no key keeps the opt-in clean absence"

seed; echo 200 >"$TMP/mode"; : >"$TMP/hits"
out=$(probe "$R_NOTOKEN" 0)
echo "$out" | jq -e '.actual == "absent"' >/dev/null || fail "no chain flag must keep the .env-only read (got: $out)"
[ ! -s "$TMP/hits" ] || fail "no chain flag must make no HTTP call"
ok "the chain and the call are opt-in per caller"

seed; echo redirect >"$TMP/mode"
out=$(probe "$R_NOTOKEN")
echo "$out" | jq -e '.actual == "degraded" and .unverified == true' >/dev/null || fail "a redirect to a 200 page must read could-not-verify (got: $out)"
ok "a 3xx is never followed to green"

seed; echo nobody >"$TMP/mode"
out=$(probe "$R_NOTOKEN")
echo "$out" | jq -e '.actual == "degraded" and .unverified == true and (.detail | contains("without an account"))' >/dev/null || fail "a 200 body without an accountId must read could-not-verify (got: $out)"
ok "a 200 without an accountId is not green"

seed; echo 200 >"$TMP/mode"
out=$(JIRA_API_TOKEN="AMBIENT-never-send" probe "$R_NOTOKEN")
echo "$out" | jq -e '.actual == "present"' >/dev/null || fail "the call must carry the keyring token, not an ambient one (got: $out)"
ok "an ambient JIRA_API_TOKEN is not what the verify call sends when the probe env is scrubbed"

confrepo="$TMP/confrepo"; mkdir -p "$confrepo"
printf 'JIRA_BASE_URL=http://127.0.0.1:%s\nJIRA_PROJECT_KEY=HIMMEL\n' "$PORT" >"$confrepo/.env"
mkdir -p "$HOME/.himmel"; printf 'JIRA_EMAIL=me@example.com\n' >"$HOME/.himmel/himmel.conf"
seed; printf 'service=himmel key=JIRA_EMAIL scope=user\twrong@example.com\n' >>"$KSTUB_STORE"; echo 200 >"$TMP/mode"
out=$(probe "$confrepo")
rm -f "$HOME/.himmel/himmel.conf"
echo "$out" | jq -e '.actual == "present"' >/dev/null || fail "himmel.conf email must beat the keyring email, as the plugin orders them (got: $out)"
ok "the probe sends the email the plugin would send"

manifest_one="$TMP/manifest-one.json"
jq '{schemaVersion, harness, items: [.items[] | select(.id == "jira-env-keys")]}' "$REPO/scripts/install/manifest.json" >"$manifest_one"
target="$TMP/target"; mkdir -p "$target"; git -C "$target" init -q -b main
status_item() {
    ( cd "$target" && env -u JIRA_API_TOKEN -u JIRA_EMAIL -u JIRA_BASE_URL -u CREDENTIALS_DIRECTORY "$@" HIMMELCTL_CACHE_DIR="$TMP/cache" HIMMEL_LUNA_CONFIG_PATH="$TMP/luna.json" HIMMELCTL_REPO_ROOT="$R_NOTOKEN" "$NODE" -e "
const { statusReport } = require('$REPO/scripts/himmelctl/lib/status-report.js');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_one', 'utf8'));
const answers = { role: 'adopter', tier: 'standard', scope: 'project', vault: { mode: 'none', path: '' }, handover: { mode: 'inline', path: '' }, pluginSet: 'lean', lanes: [], alwaysOn: false };
console.log(JSON.stringify(statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers })));
" 2>&1 | tee -a "$TMP/out.log" )
}
seed; echo 200 >"$TMP/mode"; : >"$TMP/hits"
out=$(status_item TRACKER=jira)
echo "$out" | jq -e '.items[0].severity == "green"' >/dev/null || fail "status with a Jira tracker must verify through the chain and read green (got: $out)"
[ -s "$TMP/hits" ] || fail "status with a Jira tracker must make the verify call"
ok "status-report turns the chain on for a Jira install"

seed; echo 200 >"$TMP/mode"; : >"$TMP/hits"
out=$(status_item TRACKER=none)
[ ! -s "$TMP/hits" ] || fail "an install that opted out of Jira must make no call"
echo "$out" | jq -e '.items[0].severity != "red" and .items[0].severity != "degraded"' >/dev/null || fail "an install that opted out of Jira must not read red or degraded (got: $out)"
ok "an install that opted out of Jira makes no call"

if grep -q "$TOKEN" "$TMP/out.log"; then fail "a token value appeared in probe output"; else ok "no token value in any output"; fi

[ "$FAILS" = 0 ] || { echo "$FAILS failure(s)" >&2; exit 1; }
echo "all passed"
