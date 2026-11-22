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
  res.statusCode = Number(mode);
  res.end('{}');
}).listen(0, '127.0.0.1', function () { fs.writeFileSync(dir + '/port', String(this.address().port)); });
JS
"$NODE" "$TMP/srv.js" "$TMP" &
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
    "$NODE" -e "
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

if grep -q "$TOKEN" "$TMP/out.log"; then fail "a token value appeared in probe output"; else ok "no token value in any output"; fi

[ "$FAILS" = 0 ] || { echo "$FAILS failure(s)" >&2; exit 1; }
echo "all passed"
