#!/usr/bin/env bash
# test-socket-scan.sh - socket-scan.sh and .github/workflows/socket-scan.yml: the manifest
# and lock-file gate, the one-scan rule, the quota-reply skip, the key handling and the
# workflow shape. Hermetic: socket and the secrets resolver are stubs, HOME and every dir
# live in a mktemp dir; the real Socket API is never called and no real key is read.
# Fixtures: MANIFESTS below is `git ls-files` of the dependency manifests and lock files
# at 2f3d9f2ea (the real names and depths); the quota reply follows the 429 response of
# the Socket OpenAPI (docs.socket.dev/reference/getquota): a JSON error object
# {error:{message,details}} described as "Insufficient quota for API route", with a
# Retry-After header. No real reply was captured: that needs a live key at quota.
# Exit: 0 = all pass, 1 = a case failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SCAN="$DIR/socket-scan.sh"
WF="$ROOT/.github/workflows/socket-scan.yml"
PASSED=0; FAILED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (no '$2' in $3)"; fi; }
hasnt() { # a missing or unreadable file is a failure, never proof of absence
    if [ ! -r "$3" ]; then fail "$1 ($3 is unreadable)"; return; fi
    if grep -qF -- "$2" "$3" 2>/dev/null; then fail "$1 ('$2' present in $3)"; else pass "$1"; fi
}

W="$(mktemp -d "${TMPDIR:-/tmp}/socket-scan-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
KEY="canary-socket-key-must-never-print"
unset SOCKET_DEV_API_KEY SOCKET_CLI_API_TOKEN

MANIFESTS='.github/ci-image/requirements-ci.txt
.github/ci-image/requirements-shellcheck.txt
marketplace/plugins/claude-hud/package-lock.json
marketplace/plugins/claude-hud/package.json
marketplace/plugins/himmel-bus/package-lock.json
marketplace/plugins/himmel-bus/package.json
marketplace/plugins/luna-correlate/bun.lock
marketplace/plugins/luna-correlate/package.json
marketplace/plugins/obsidian-triage/tools/package-lock.json
marketplace/plugins/obsidian-triage/tools/package.json
marketplace/plugins/obsidian-triage/tools/requirements-scrapling.txt
marketplace/plugins/obsidian-triage/tools/requirements-whisper-cuda.txt
marketplace/plugins/obsidian-triage/tools/requirements-whisper.txt
marketplace/plugins/pstack/skills/statechart/scripts/package-lock.json
marketplace/plugins/pstack/skills/statechart/scripts/package.json
marketplace/plugins/telegram-himmel/bun.lock
marketplace/plugins/telegram-himmel/package.json
plugins/himmel-gh/package-lock.json
plugins/himmel-gh/package.json
plugins/himmel-jira/package-lock.json
plugins/himmel-jira/package.json
scripts/bitbucket/package-lock.json
scripts/bitbucket/package.json
scripts/ci-orchestrator/package-lock.json
scripts/ci-orchestrator/package.json
scripts/config-ui/agui-web/bun.lock
scripts/config-ui/agui-web/package.json
scripts/config-ui/tests/e2e/bun.lock
scripts/config-ui/tests/e2e/package.json
scripts/himmel-run/package-lock.json
scripts/himmel-run/package.json
scripts/hooks/license-scanner/package-lock.json
scripts/hooks/license-scanner/package.json
scripts/jira/package-lock.json
scripts/jira/package.json
scripts/luna-vitals/bun.lock
scripts/luna-vitals/package.json
site/package-lock.json
site/package.json'
# the tracked manifests under a directory the scan leaves out (fixtures)
FIXTURE_MANIFESTS='scripts/lanes/bench/fixtures/T6/input/examples/demo-app/package.json
scripts/lanes/bench/fixtures/T6/input/package-lock.json
scripts/lanes/bench/fixtures/T6/input/package.json
scripts/lanes/bench/fixtures/T6/input/packages/core/package.json
scripts/lanes/bench/fixtures/T6/input/packages/utils/package.json
scripts/lanes/bench/fixtures/T6/input/tools/codegen/scripts/package.json'
# tracked files that are not dependency manifests
NOISE='README.md
.github/workflows/snyk-weekly.yml
scripts/security/snyk-scan.sh
scripts/ci/suite-tiers.tsv
docs/internals/enforcement.md'

# The repo the scan runs in: every manifest exists on disk, the noise files too.
R="$W/repo"; mkdir -p "$R"
for f in $MANIFESTS $FIXTURE_MANIFESTS $NOISE; do mkdir -p "$R/$(dirname "$f")"; printf '{}\n' > "$R/$f"; done

# Stub socket: records the argv and whether the token env was set (never its value on
# the argv). STUB_RC / STUB_OUT / STUB_ERR shape the reply; STUB_ECHO_KEY=1 makes the
# stub print the token it was given, to prove the script redacts it.
BIN="$W/bin"; mkdir -p "$BIN"
cat > "$BIN/socket" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/calls.log"
printf '%s' "${SOCKET_CLI_API_TOKEN:-}" > "$STUB_DIR/token.seen"
[ "${STUB_ECHO_KEY:-0}" = 1 ] && echo "using token ${SOCKET_CLI_API_TOKEN:-}"
[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"
[ -n "${STUB_ERR:-}" ] && printf '%s\n' "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
SH
chmod +x "$BIN/socket"
# Stub secrets resolver: prints NAME=value like `himmel-secrets get`.
cat > "$BIN/secrets" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/secrets.log"
[ "${STUB_SECRET:-}" = "" ] && exit 1
printf 'SOCKET_DEV_API_KEY=%s\n' "$STUB_SECRET"
SH
chmod +x "$BIN/secrets"
export STUB_DIR="$W" SOCKET_BIN="$BIN/socket" SOCKET_SCAN_SECRETS_BIN="$BIN/secrets"
QUOTA_BODY='{"error":{"message":"Insufficient quota for API route","details":null}}'

run() { # <name> <changed-list> [extra env via the caller]; sets OUT, RC, CALLS
    local n="$1" list="$2"
    OUT="$W/$n.log"; SUMMARY="$W/$n.summary"; : > "$W/calls.log"; : > "$SUMMARY"; rm -f "$W/secrets.log" "$W/token.seen"
    printf '%s\n' "$list" > "$W/$n.list"
    GITHUB_STEP_SUMMARY="$SUMMARY" bash "$SCAN" --files "$W/$n.list" --root "$R" --repo himmel --branch feat-x > "$OUT" 2>&1
    RC=$?
    CALLS="$(grep -c 'scan create' "$W/calls.log")"
}
export SOCKET_DEV_API_KEY="$KEY"

# --- the gate: no manifest or lock file starts no scan --------------------------
run nomanifest "$NOISE"
check "a change set with no manifest or lock file exits 0" 0 "$RC"
check "a change set with no manifest or lock file starts no scan" 0 "$CALLS"
has "the no-manifest skip is named" "SKIP no-manifest" "$OUT"
run fixtureonly "$FIXTURE_MANIFESTS"
check "manifests under a fixtures dir start no scan" 0 "$CALLS"
check "manifests under a fixtures dir exit 0" 0 "$RC"
run empty ""
check "an empty change set starts no scan" 0 "$CALLS"
check "an empty change set exits 0" 0 "$RC"
run deleted "gone/package-lock.json"
check "a deleted lock file (not on disk) starts no scan" 0 "$CALLS"

# --- the gate: a lock file starts exactly one scan ------------------------------
run onelock "$(printf '%s\n%s' "$NOISE" "site/package-lock.json")"
check "a change set with a lock file exits 0 on a passing scan" 0 "$RC"
check "a change set with a lock file starts exactly one scan" 1 "$CALLS"
has "the scan names the lock file as its target" "site/package-lock.json" "$W/calls.log"
hasnt "the scan leaves the noise files out" "snyk-scan.sh" "$W/calls.log"
has "the scan is a report scan" "scan create --report" "$W/calls.log"
has "the result line says OK" "OK" "$OUT"
has "the result shows in the job summary" "socket-scan: OK" "$SUMMARY"

# every real manifest and lock-file name in the repo: one scan, all of them as targets
run allmanifests "$(printf '%s\n%s\n%s' "$MANIFESTS" "$FIXTURE_MANIFESTS" "$NOISE")"
check "the whole repo's manifests start exactly one scan" 1 "$CALLS"
check "every real manifest outside fixtures is a target" "$(printf '%s\n' "$MANIFESTS" | wc -l | tr -d ' ')" \
    "$(tr ' ' '\n' < "$W/calls.log" | grep -cE '(package(-lock)?\.json|bun\.lockb?|requirements[^/]*\.txt)$')"
hasnt "a fixtures manifest is never a target" "fixtures/T6" "$W/calls.log"
for name in package.json package-lock.json bun.lock bun.lockb uv.lock requirements-dev.txt pyproject.toml pnpm-lock.yaml yarn.lock; do
    mkdir -p "$R/n"; printf '' > "$R/n/$name"
    run "name-$name" "n/$name"
    check "$name is a manifest name" 1 "$CALLS"
done

# --- the scan result: policy failure is red, quota is a skip --------------------
STUB_RC=1 STUB_ERR="Socket scan is not healthy: 1 alert with policy action error" run policy "site/package-lock.json"
check "a policy failure exits 1" 1 "$RC"
has "a policy failure is named" "FAIL" "$OUT"

STUB_RC=1 STUB_ERR="$QUOTA_BODY" run quota "site/package-lock.json"
check "a quota reply exits 0, not red" 0 "$RC"
has "a quota reply reads as a skip" "SKIP quota" "$OUT"
has "the skip carries the reason from the reply" "Insufficient quota for API route" "$OUT"
hasnt "a quota reply is not a FAIL" "FAIL" "$OUT"
has "the quota skip shows in the job summary" "SKIP quota" "$SUMMARY"
STUB_RC=1 STUB_ERR="HTTP 429 Too Many Requests" run tooMany "site/package-lock.json"
check "a bare 429 reply exits 0" 0 "$RC"
has "a bare 429 reply reads as a skip" "SKIP quota" "$OUT"
STUB_RC=2 STUB_ERR="getaddrinfo ENOTFOUND api.socket.dev" run neterr "site/package-lock.json"
check "a network error exits 2, not a skip" 2 "$RC"

# --- the key ------------------------------------------------------------------
STUB_ECHO_KEY=1 STUB_RC=1 STUB_ERR="rejected token $KEY" run echokey "site/package-lock.json"
cat "$W/echokey.log" "$W/echokey.summary" > "$W/all-echo.txt"
hasnt "the key never reaches the output or the summary" "$KEY" "$W/all-echo.txt"
hasnt "the key is never on the socket command line" "$KEY" "$W/calls.log"
check "the key reaches socket through its environment" "$KEY" "$(cat "$W/token.seen")"
run okkey "site/package-lock.json"
cat "$OUT" "$SUMMARY" > "$W/all-ok.txt"
hasnt "a passing scan never prints the key" "$KEY" "$W/all-ok.txt"

unset SOCKET_DEV_API_KEY
run nokey "site/package-lock.json"
check "no key exits 0" 0 "$RC"
check "no key starts no scan" 0 "$CALLS"
has "no key is a named skip" "SKIP no-key" "$OUT"
has "the no-key skip names the gh secret set command" "gh secret set SOCKET_DEV_API_KEY" "$OUT"
has "no key asks the resolver without the .env fallback" "--no-dotenv" "$W/secrets.log"
STUB_SECRET="$KEY" run resolver "site/package-lock.json"
check "a key from the resolver starts the scan" 1 "$CALLS"
check "a resolver key reaches socket through its environment" "$KEY" "$(cat "$W/token.seen")"
cat "$OUT" "$SUMMARY" "$W/calls.log" > "$W/all-res.txt"
hasnt "a resolver key is never printed" "$KEY" "$W/all-res.txt"
run nogate_nokey ""
check "a no-manifest change set never asks the resolver for the key" 0 "$([ -f "$W/secrets.log" ] && echo 1 || echo 0)"

# --- usage ----------------------------------------------------------------------
bash "$SCAN" --bogus > "$W/bogus.log" 2>&1
check "an unknown flag exits 2" 2 "$?"
bash "$SCAN" --files "$W/does-not-exist" > "$W/nofile.log" 2>&1
check "a missing change list exits 2" 2 "$?"

# --- the workflow ---------------------------------------------------------------
[ -r "$WF" ] && pass "socket-scan.yml exists" || fail "socket-scan.yml exists"
has "workflow runs on pull_request" "pull_request:" "$WF"
has "workflow has a manual dispatch" "workflow_dispatch:" "$WF"
hasnt "workflow has no schedule" "schedule:" "$WF"
has "workflow filters on paths" "paths:" "$WF"
for p in "'**/package.json'" "'**/package-lock.json'" "'**/bun.lock'" "'**/bun.lockb'" "'**/uv.lock'" "'**/requirements*.txt'" "'**/pyproject.toml'"; do
    has "workflow paths filter holds $p" "$p" "$WF"
done
has "workflow permissions are contents read" "contents: read" "$WF"
has "workflow skips with the gh secret set command" "gh secret set SOCKET_DEV_API_KEY" "$WF"
has "workflow reads the key from the repo secret" "secrets.SOCKET_DEV_API_KEY" "$WF"
has "workflow runs the gate script" "scripts/security/socket-scan.sh" "$WF"
hasnt "workflow never puts the key in a with: block" "token: \${{ secrets.SOCKET_DEV_API_KEY" "$WF"
bash "$ROOT/scripts/ci/check-actions-pinned.sh" "$WF" > "$W/pinned.log" 2>&1
check "every action in the workflow is SHA-pinned" 0 "$?"
bash "$ROOT/scripts/ci/check-ci-install-locks.sh" "$ROOT" > "$W/locks.log" 2>&1
check "the workflow's installs pass the install-lock check" 0 "$?"

echo "socket-scan: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
