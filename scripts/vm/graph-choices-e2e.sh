#!/usr/bin/env bash
# graph-choices-e2e.sh -- the VM end-to-end proof of the graph choices (slice S7 of the adopter
# graph choices plan): install himmel and graphify on a test VM, walk the setup answers, fire the
# daily pass once against a stub API and prove the uninstall leaves nothing behind.
#
#   graph-choices-e2e.sh [--expect-red] <vm>   host mode: takes the vm-lock on <vm> (a himmel-ar-N or
#                                              himmel-ci-N clone, never the golden image), restores the
#                                              clean snapshot, stages THIS worktree's tracked tree, runs
#                                              this script there with --guest through guest-exec.sh, then
#                                              restores the snapshot, powers the VM off and releases the lock.
#   graph-choices-e2e.sh --guest <tree>        guest mode: runs ON the VM (refuses anywhere else).
#
# Exit: 0 every assertion passed; 1 an assertion failed (or --expect-red did not fail where it must);
# 2 bad inputs; 3 the lock or the VM lifecycle failed. It prints PASS and FAIL lines and a final
# `RESULT: N failure(s)` line; a run with no RESULT line proved nothing and fails.
#
# --expect-red is the RED control: the staged tree has no S4 pass (graph-choices-pass.sh is left out of the
# tarball), so the guest's FIRST assertion must fail; the driver exits 0 only then.
#
# No real key and no paid call: the key is a dummy file, the API a loopback stub, claude a stub.
#
# Seams (tests): HIMMEL_GCE_VMSDK, HIMMEL_GCE_GUEST_EXEC, HIMMEL_GCE_STAGE_TMP, HIMMEL_GCE_SHOTS_DIR,
# HIMMEL_GCE_SNAPSHOT (default suite-ready-v4), HIMMEL_GCE_RESTORE_RETRY_SECS (default 10), HIMMEL_VM_LOCK_DIR.
#
# Sourced (BASH_SOURCE != $0) it defines only the pure helpers, for the hermetic test.


gce_words() {
  sed -n "s/^graph-choices-pass: \(- \)\{0,1\}$2 \([a-z][a-z-]*\)\([: ].*\)\{0,1\}\$/\2/p" "$1" 2>/dev/null
}

gce_word_before() {
  gce_words "$1" "$2" | awk -v a="$3" -v b="$4" '$0 == a && !ia { ia = NR } $0 == b && !ib { ib = NR } END { exit !(ia && ib && ia < ib) }'
}

gce_call_count() { local n; n="$(grep -c '^CALL ' "$1" 2>/dev/null)" || n=0; printf '%s\n' "${n:-0}"; }

gce_call_distinct() { grep '^CALL ' "$1" 2>/dev/null | awk '{ print $2 }' | sort -u | wc -l | tr -d ' '; }

gce_calls_with_key_var() { local n; n="$(grep '^CALL ' "$1" 2>/dev/null | grep -vc 'keyvars=none$')" || n=0; printf '%s\n' "${n:-0}"; }

gce_cron_rows() { local n; n="$(grep -c '# HIMMEL-GraphChoices$' "$1" 2>/dev/null)" || n=0; printf '%s\n' "${n:-0}"; }

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"

usage() {
  echo "usage: graph-choices-e2e.sh [--expect-red] <vm>   (vm: himmel-ar-N or himmel-ci-N, never the golden image)" >&2
  echo "       graph-choices-e2e.sh --guest <tree>        (runs on the test VM only; needs HIMMEL_GCE_GUEST=1)" >&2
  exit 2
}

guest_main() {
  [ "$#" -eq 1 ] || usage
  if [ "${HIMMEL_GCE_GUEST:-}" != 1 ]; then
    echo "graph-choices-e2e: --guest installs and uninstalls himmel in HOME; it runs only on a test VM (set HIMMEL_GCE_GUEST=1 there)" >&2
    exit 2
  fi
  local TREE="$1"
  [ -d "$TREE/scripts" ] || { echo "graph-choices-e2e: no himmel tree at '$TREE'" >&2; exit 2; }

  local fails=0
  pass() { echo "PASS $1"; }
  fail() { echo "FAIL $1"; fails=$((fails + 1)); }
  note() { echo "NOTE $1"; }
  verdict() { echo "RESULT: $fails failure(s)"; [ "$fails" -eq 0 ]; exit $?; }
  tail_of() { tail -n "${2:-15}" "$1" 2>/dev/null | sed 's/^/    | /'; }

  echo "==> 0. the tree carries S4"
  if [ -f "$TREE/scripts/graphify/graph-choices-pass.sh" ] && [ -f "$TREE/scripts/graphify/graph-choices-cadence.sh" ]; then
    pass "graph-choices-pass.sh is in the tree (S4 present)"
  else
    fail "graph-choices-pass.sh is in the tree (S4 present)"; verdict
  fi
  for t in node git python3 crontab base64; do
    command -v "$t" >/dev/null 2>&1 || { fail "the guest has $t"; verdict; }
  done

  local W="$HOME/gce-work" SD="$HOME/.himmel/state/api-credit"
  local GC="$TREE/scripts/himmelctl/lib/graph-choices.js" CTL="$TREE/scripts/himmelctl/bin.js"
  local RUNNER_DIR="$HOME/.claude/graph-choices-cadence"
  local BASE_PATH="$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"
  rm -rf "$W" "$HOME/.himmel" "$RUNNER_DIR" "$HOME/.claude/himmel"
  mkdir -p "$W/stubbin" "$W/repos" "$W/proj" "$W/shots" "$HOME/.local/bin"
  export PATH="$BASE_PATH"
  git config --global user.name gce
  git config --global user.email gce@example.invalid
  export USER_SLUG=gce

  if ! command -v uv >/dev/null 2>&1; then
    echo "==> 0b. the pinned uv (the guest image ships none)"
    . "$TREE/scripts/lib/prim.sh"
    pt="$(tmpdir)" || { fail "a scratch directory for the uv download"; verdict; }
    if ( . "$TREE/scripts/machine-setup/installer-pins.sh" \
         && pin_fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" "$UV_SHA256" "$pt/uv.tar.gz" \
         && tar -xzf "$pt/uv.tar.gz" -C "$pt" \
         && install -m 0755 "$pt/uv-x86_64-unknown-linux-gnu/uv" "$pt/uv-x86_64-unknown-linux-gnu/uvx" "$HOME/.local/bin/" ) > "$pt/uv.log" 2>&1; then
      pass "the pinned uv is installed ($(uv --version))"
    else
      fail "the pinned uv is installed"; tail_of "$pt/uv.log" 8; verdict
    fi
    rm -rf "$pt"
  fi

  git -C "$TREE" init -q -b main 2>/dev/null
  git -C "$TREE" add -A >/dev/null 2>&1
  git -C "$TREE" -c user.email=gce@example.invalid -c user.name=gce commit -q -m "stage" >/dev/null 2>&1
  git -C "$W/proj" init -q -b main
  git -C "$W/proj" -c user.email=gce@example.invalid -c user.name=gce commit -q --allow-empty -m init

  cat > "$W/stubbin/claude" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" -p "* | *" --print "*) ;;
  *) case "$1" in plugin) echo '[]' ;; esac; exit 0 ;;
esac
prompt="$(cat)"
h="$(printf '%s' "$prompt" | sha256sum | cut -c1-16)"
kv="$(env | sed 's/=.*//' | grep -E '^(ANTHROPIC_|anthropic_|CLAUDE_CODE_USE_|claude_code_use_|LQ_API_)' | paste -sd, -)"
echo "CALL $h keyvars=${kv:-none}" >> "${GCE_CALL_LOG:-/tmp/gce-claude-calls.log}"
echo '{"type":"result","subtype":"success","is_error":false,"result":"{\"nodes\":[{\"id\":\"gce_readme\",\"label\":\"gce readme\",\"file_type\":\"document\",\"source_file\":\"README.md\",\"source_location\":\"L1\"}],\"edges\":[]}","total_cost_usd":0,"usage":{"input_tokens":1,"output_tokens":1}}'
EOS
  chmod +x "$W/stubbin/claude"
  local CALLS="$W/claude-calls.log"
  : > "$CALLS"

  cat > "$W/stub-api.js" <<'EOS'
const http = require('http');
const fs = require('fs');
const [modeFile, logFile, portFile] = process.argv.slice(2);
http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const mode = fs.readFileSync(modeFile, 'utf8').trim();
    fs.appendFileSync(logFile, `${req.method} ${req.url} mode=${mode}\n`);
    const reply = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (mode === '401') return reply(401, { type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' } });
    return reply(400, { type: 'error', error: { type: 'invalid_request_error', message: 'Your credit balance is too low to access the Anthropic API.' } });
  });
}).listen(0, '127.0.0.1', function () { fs.writeFileSync(portFile, String(this.address().port)); });
EOS

  cat > "$W/answer.py" <<'EOS'
import json, os, select, subprocess, sys, time
rules = json.loads(sys.argv[1])
used = [0] * len(rules)
p = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
fd = p.stdout.fileno()
pending = ""
last = time.time()
while True:
    r, _, _ = select.select([fd], [], [], 5)
    if not r:
        if p.poll() is not None:
            break
        if time.time() - last > 240:
            p.kill()
            sys.stdout.write("\nanswer.py: no output for 240 s, killed the install\n")
            sys.exit(124)
        continue
    chunk = os.read(fd, 65536)
    if not chunk:
        break
    last = time.time()
    text = chunk.decode("utf-8", "replace")
    sys.stdout.write(text)
    sys.stdout.flush()
    pending += text
    if pending.endswith("> ") or pending.endswith("[Y/n] ") or pending.endswith("skip): "):
        ans = ""
        for i, (needle, answers) in enumerate(rules):
            if needle in pending:
                if used[i] < len(answers):
                    ans = answers[used[i]]
                    used[i] += 1
                break
        try:
            p.stdin.write((ans + "\n").encode())
            sys.stdout.write("[answer.py sent %r]\n" % ans)
            sys.stdout.flush()
            if pending.endswith("skip): "):
                p.stdin.close()
        except BrokenPipeError:
            sys.stdout.write("[answer.py: broken pipe]\n")
        pending = ""
try:
    p.stdin.close()
except Exception:
    pass
try:
    p.wait(timeout=120)
except Exception:
    p.kill()
sys.exit(p.returncode if p.returncode is not None else 1)
EOS

  ctl_env() { env -i HOME="$HOME" PATH="$BASE_PATH" HIMMELCTL_INTERACTIVE=1 HIMMELCTL_CACHE_DIR="$HOME/.claude/himmel" "$@"; }
  stub_env() { env -i HOME="$HOME" PATH="$W/stubbin:$BASE_PATH" GCE_CALL_LOG="$CALLS" "$@"; }
  gc() { env -i HOME="$HOME" PATH="$BASE_PATH" node "$GC" "$@"; }

  echo "==> 1. setup.sh --with-graphify"
  ( cd "$TREE" && bash scripts/setup.sh --with-graphify ) > "$W/setup.log" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then pass "setup.sh --with-graphify exits 0"; else fail "setup.sh --with-graphify exits 0 (rc=$rc)"; tail_of "$W/setup.log" 25; fi
  if command -v graphify >/dev/null 2>&1; then pass "graphify is on PATH ($(command -v graphify))"; else fail "graphify is on PATH"; tail_of "$W/setup.log" 25; verdict; fi
  uv cache clean >/dev/null 2>&1

  echo "==> 2. himmelctl install, Enter at the first graph question"
  ( cd "$W/proj" && ctl_env python3 -I "$W/answer.py" '[]' node "$CTL" install ) > "$W/install-enter.log" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then pass "himmelctl install exits 0"; else fail "himmelctl install exits 0 (rc=$rc)"; tail_of "$W/install-enter.log" 25; fi
  if grep -qF 'Which of your own git repos should be graphed on this machine?' "$W/install-enter.log"; then pass "the install asked the first question"; else fail "the install asked the first question"; fi
  sentence="$(gc sentence --state default)"
  if [ -n "$sentence" ] && grep -qF -- "$sentence" "$W/install-enter.log"; then pass "the no-choice sentence was printed"; else fail "the no-choice sentence was printed"; fi
  if grep -qF 'Who pays first?' "$W/install-enter.log"; then fail "nothing else was asked after Enter"; else pass "nothing else was asked after Enter"; fi
  st="$(gc route --state)"
  if [ "$st" = default ]; then pass "no store (graph choice state: default)"; else fail "no store (graph choice state: $st)"; fi
  if [ -f "$HOME/.himmel/config.json" ] && grep -q '"choices"' "$HOME/.himmel/config.json"; then fail "config.json holds no graphify.choices"; else pass "config.json holds no graphify.choices"; fi
  crontab -l > "$W/cron.step2" 2>/dev/null
  n="$(gce_cron_rows "$W/cron.step2")"
  if [ "$n" -eq 0 ] && [ ! -e "$RUNNER_DIR/graph-choices.sh" ]; then pass "no job: no HIMMEL-GraphChoices cron row and no runner"; else fail "no job: no HIMMEL-GraphChoices cron row and no runner ($n rows)"; fi
  git init -q -b main "$W/repos/adopter-check" 2>/dev/null
  printf '# note\n' > "$W/repos/adopter-check/note.md"
  git -C "$W/repos/adopter-check" add -A
  git -C "$W/repos/adopter-check" -c user.email=gce@example.invalid -c user.name=gce commit -q -m seed
  ( cd "$TREE" && stub_env bash scripts/graphify/refresh-graph-map.sh --name gce-adopter --corpus-root "$W/repos/adopter-check" \
      --maps-dir "$W/maps" --title gce --slug gce --backend claude-api ) > "$W/adopter-row.log" 2>&1; rc=$?
  if [ "$rc" -eq 3 ] && grep -qF 'no API account is chosen on this station' "$W/adopter-row.log"; then
    pass "the refresh-graph-map.sh adopter row refuses with no choice (rc 3)"
  else
    fail "the refresh-graph-map.sh adopter row refuses with no choice (rc=$rc)"; tail_of "$W/adopter-row.log" 8
  fi
  if [ "$(gce_call_count "$CALLS")" -eq 0 ]; then pass "the adopter row made no call"; else fail "the adopter row made no call ($(gce_call_count "$CALLS") calls)"; fi

  echo "==> 3. himmel-update.sh --only graph against a throwaway bare remote"
  built="$(git -C "$TREE" rev-parse HEAD)"
  git init -q --bare "$W/graph-remote.git"
  git init -q -b graph-data "$W/graph-pub" 2>/dev/null
  printf '{"nodes":[{"id":"gce_published","label":"published node"}],"edges":[],"built_at_commit":"%s"}\n' "$built" > "$W/graph-pub/graph.json"
  printf '# GRAPH_REPORT\n' > "$W/graph-pub/GRAPH_REPORT.md"
  printf '{"README.md":{"mtime":0}}\n' > "$W/graph-pub/manifest.json"
  printf '%s\n' "$built" > "$W/graph-pub/built_at_commit"
  git -C "$W/graph-pub" add -A
  git -C "$W/graph-pub" -c user.email=gce@example.invalid -c user.name=gce commit -q -m publish
  git -C "$W/graph-pub" push -q "$W/graph-remote.git" graph-data:refs/heads/graph-data
  ( cd "$TREE" && env -i HOME="$HOME" PATH="$BASE_PATH" HIMMEL_UPDATE_GRAPH_REMOTE="$W/graph-remote.git" bash scripts/himmel-update.sh --only graph ) > "$W/update-graph.log" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then pass "himmel-update.sh --only graph exits 0"; else fail "himmel-update.sh --only graph exits 0 (rc=$rc)"; tail_of "$W/update-graph.log" 15; fi
  ok=0
  for f in graph.json GRAPH_REPORT.md manifest.json; do
    cmp -s "$W/graph-pub/$f" "$TREE/graphify-out/$f" || ok=1
  done
  if [ "$ok" -eq 0 ]; then pass "graphify-out/ holds the published bytes (cmp)"; else fail "graphify-out/ holds the published bytes (cmp)"; tail_of "$W/update-graph.log" 15; fi

  echo "==> 4. setup with route A then subscription; the runner fires once against a stub API"
  mkdir -p "$SD"; chmod 700 "$SD"
  printf '{"version":1,"ledger_path":"%s/ledger.json","accounts":{"A":{"organization_id":"org-a","cycle_id":"cycle-a","cap_usd":"50.00","key_id":"key-a","reset_at":"2099-01-01T00:00:00Z"}}}\n' "$SD" > "$SD/config.json"
  write_snapshot() {
    local now; now=$(date +%s)
    printf '{"version":1,"accounts":{"A":{"organization_id":"org-a","cycle_id":"cycle-a","grant_usd":"50.00","remaining_usd":"50.00","reconciled_spent_usd":"0","starts_at":%d,"expires_at":%d,"observed_at":%d,"source":"operator-console-snapshot","exclusive_org":true,"discrepancy":false}}}\n' $((now - 1000)) $((now + 3600)) "$now" > "$SD/snapshot.json"
  }
  seed_dummy_subscription_login() {
    mkdir -p "$HOME/.claude"
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-dummy-not-a-real-token","refreshToken":"dummy","expiresAt":4102444800000}}\n' > "$HOME/.claude/.credentials.json"
    chmod 600 "$HOME/.claude/.credentials.json"
  }
  write_snapshot
  printf 'ANTHROPIC_API_KEY=sk-ant-dummy-not-a-real-key-0000\n' > "$SD/key-A.env"; chmod 600 "$SD/key-A.env"
  seed_dummy_subscription_login
  printf 'credit\n' > "$W/stub-mode"; : > "$W/stub-api.log"
  node "$W/stub-api.js" "$W/stub-mode" "$W/stub-api.log" "$W/stub-port" > "$W/stub-api.out" 2>&1 &
  STUB_PID=$!
  for _ in $(seq 1 50); do [ -s "$W/stub-port" ] && break; sleep 0.2; done
  [ -s "$W/stub-port" ] || { fail "the stub API is listening"; verdict; }
  local PORT; PORT="$(cat "$W/stub-port")"
  pass "the stub API is listening on 127.0.0.1:$PORT"

  REPO_FX="$W/repos/gce-repo"
  mkdir -p "$REPO_FX/docs"
  printf '# gce repo\n\nA fixture repo for the graph choices run.\n' > "$REPO_FX/README.md"
  printf '# notes\n\nThe pass describes this file once.\n' > "$REPO_FX/docs/notes.md"
  printf 'def hello():\n    return "hi"\n' > "$REPO_FX/app.py"
  git init -q -b main "$REPO_FX"
  git -C "$REPO_FX" add -A
  git -C "$REPO_FX" -c user.email=gce@example.invalid -c user.name=gce commit -q -m seed

  rules='[["Which of your own git repos",["'"$REPO_FX"'",""]],["Who pays first",["A"]],["try what next",["subscription"]],["At most how many USD",[""]],["Run this once a day",["yes"]]]'
  ( cd "$W/proj" && ctl_env python3 -I "$W/answer.py" "$rules" node "$CTL" install ) > "$W/install-route.log" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then pass "himmelctl install with the typed answers exits 0"; else fail "himmelctl install with the typed answers exits 0 (rc=$rc)"; tail_of "$W/install-route.log" 25; fi
  route="$(gc route)"
  case "$route" in *'"order":["A","subscription"]'*) pass "the stored route is A then subscription" ;; *) fail "the stored route is A then subscription ($route)" ;; esac
  case "$route" in *'"name":"gce-repo"'*) pass "the stored corpus is gce-repo" ;; *) fail "the stored corpus is gce-repo" ;; esac
  stub_env bash "$TREE/scripts/graphify/graph-choices-cadence.sh" arm --force > "$W/rearm.log" 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && grep -qF "$W/stubbin" "$RUNNER_DIR/graph-choices.sh" 2>/dev/null; then pass "the runner is re-rendered with the stub claude first on its PATH"
  else fail "the runner is re-rendered with the stub claude first on its PATH (rc=$rc)"; tail_of "$W/rearm.log" 8; fi
  crontab -l > "$W/cron.step4" 2>/dev/null
  if [ "$(gce_cron_rows "$W/cron.step4")" -eq 1 ] && [ -x "$RUNNER_DIR/graph-choices.sh" ]; then pass "the job is armed: one cron row and the runner"
  else fail "the job is armed: one cron row and the runner"; tail_of "$W/install-route.log" 30; kill "$STUB_PID" 2>/dev/null; verdict; fi

  jq '.oauthAccount = {"accountUuid": "00000000-0000-4000-8000-00000000gce0"}' "$HOME/.claude.json" > "$W/claude.json.new" \
    && mv "$W/claude.json.new" "$HOME/.claude.json"
  acct_hash="$(. "$TREE/scripts/lib/usage-cache-identity.sh"; current_account_hash)"
  fire() {
    local now; now=$(date +%s)
    printf '{"account":"%s","five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%d}\n' "$acct_hash" "$now" > "$W/usage-cache.json"
    env HIMMEL_BATCH_BASE_URL="http://127.0.0.1:$PORT" CADENCE_USAGE_CACHE="$W/usage-cache.json" GCE_CALL_LOG="$CALLS" \
      PATH="$W/stubbin:$PATH" "$RUNNER_DIR/graph-choices.sh" > "$W/fire.out" 2>&1
  }
  LOGF="$RUNNER_DIR/graph-choices.log"

  fire; rc=$?
  if [ "$rc" -eq 0 ]; then pass "the runner exits 0 (fire 1)"; else fail "the runner exits 0 (fire 1, rc=$rc)"; fi
  note "pass log after fire 1:"; sed 's/^/    | /' "$LOGF"
  if gce_word_before "$LOGF" gce-repo no-route extracted; then pass "words no-route then extracted, in that order"; else fail "words no-route then extracted, in that order"; fi
  acc="$(env -i HOME="$HOME" PATH="$BASE_PATH" node "$TREE/scripts/lib/api-credit-state.mjs" accounts 2>/dev/null)"
  case "$acc" in *'"tag":"marked exhausted"'*) pass "exhausted_at is set for A (accounts tags A marked exhausted)" ;; *) fail "exhausted_at is set for A (accounts: $acc)" ;; esac
  if grep -q 'exhausted_at' "$SD/ledger.json" 2>/dev/null; then pass "the ledger carries exhausted_at"; else fail "the ledger carries exhausted_at"; fi
  c="$(gce_call_count "$CALLS")"; d="$(gce_call_distinct "$CALLS")"
  if [ "$c" -ge 1 ] && [ "$c" -eq "$d" ]; then pass "exactly one stub claude call per chunk ($c calls, $d distinct prompts)"; else fail "exactly one stub claude call per chunk ($c calls, $d distinct prompts)"; fi
  if [ "$(gce_calls_with_key_var "$CALLS")" -eq 0 ]; then pass "no stub claude call had a key variable in its env"; else fail "no stub claude call had a key variable in its env"; grep '^CALL ' "$CALLS" | sed 's/^/    | /'; fi
  if [ -z "$(git -C "$REPO_FX" status --porcelain)" ]; then pass "git status --porcelain is empty in the repo"; else fail "git status --porcelain is empty in the repo"; git -C "$REPO_FX" status --porcelain | sed 's/^/    | /'; fi
  out_dir="$(gc out gce-repo)"
  case "$out_dir" in */choices/*) pass "the graph lives under choices/ ($(basename "$out_dir"))" ;; *) fail "the graph lives under choices/ ($out_dir)" ;; esac
  if [ -s "$out_dir/graph.json" ]; then pass "the choices graph.json exists"; else fail "the choices graph.json exists"; fi
  if grep -q 'mode=credit' "$W/stub-api.log"; then pass "the stub API was called and answered credit-exhausted"; else fail "the stub API was called and answered credit-exhausted"; fi

  printf '\nA second paragraph, written after the first fire.\n' >> "$REPO_FX/docs/notes.md"
  git -C "$REPO_FX" -c user.email=gce@example.invalid -c user.name=gce commit -q -am "edit notes"
  write_snapshot
  printf '401\n' > "$W/stub-mode"
  calls_before="$(gce_call_count "$CALLS")"
  : > "$W/log.mark"; wc -c < "$LOGF" | tr -d ' ' > "$W/log.mark"
  fire; rc=$?
  tail -c +"$(( $(cat "$W/log.mark") + 1 ))" "$LOGF" > "$W/fire2.log"
  if [ "$rc" -eq 0 ]; then pass "the runner exits 0 (fire 2)"; else fail "the runner exits 0 (fire 2, rc=$rc)"; fi
  note "pass log of fire 2:"; sed 's/^/    | /' "$W/fire2.log"
  words2="$(gce_words "$W/fire2.log" gce-repo)"
  if grep -qx key-rejected <<< "$words2"; then pass "the word key-rejected"; else fail "the word key-rejected"; fi
  if grep -q 'gce-repo ALERT key-rejected A' "$W/fire2.log"; then pass "the pass log names A as rejected"; else fail "the pass log names A as rejected"; fi
  if [ "$(gce_call_count "$CALLS")" -eq "$calls_before" ]; then pass "no stub claude call after the 401"; else fail "no stub claude call after the 401"; fi
  acc="$(env -i HOME="$HOME" PATH="$BASE_PATH" node "$TREE/scripts/lib/api-credit-state.mjs" accounts 2>/dev/null)"
  case "$acc" in *'"tag":"key rejected"'*) pass "accounts tags A key rejected" ;; *) fail "accounts tags A key rejected (accounts: $acc)" ;; esac
  ( cd "$TREE" && env -i HOME="$HOME" PATH="$BASE_PATH" bash scripts/himmel-doctor.sh --only C92 ) > "$W/doctor-c92.log" 2>&1
  warn_rows="$(grep -E 'WARN' "$W/doctor-c92.log")"
  if grep -q 'C92-graph-key-A' <<< "$warn_rows"; then pass "doctor C92 WARNs about account A"; else fail "doctor C92 WARNs about account A"; tail_of "$W/doctor-c92.log" 10; fi
  kill "$STUB_PID" 2>/dev/null

  echo "==> 5. the real usage-preflight under the runner's environment"
  runner_env="$(grep -E '^export (PATH|CLAUDE_CODE_OAUTH_TOKEN)=' "$RUNNER_DIR/graph-choices.sh" 2>/dev/null)"
  pf="$(cd "$TREE" && env -i HOME="$HOME" PATH=/usr/bin:/bin sh -c ":; $runner_env"'
bash scripts/lib/usage-preflight.sh' 2>"$W/preflight.err" | tail -n 1)"
  note "usage-preflight verdict under the runner environment: ${pf:-<none>}"
  case "$pf" in
    PROCEED | SKIPPED-BANK | SKIPPED-FLEET | BANK-STALE | BANK-UNKNOWN) pass "the real usage-preflight printed a verdict ($pf)" ;;
    *) fail "the real usage-preflight printed a verdict (got '${pf:-nothing}')"; tail_of "$W/preflight.err" 8 ;;
  esac
  [ "$pf" != BANK-UNKNOWN ] || note "no real subscription login or usage bank on this guest: the route would answer bank-refused"

  echo "==> 6. disarm, then a plain himmelctl uninstall"
  choices_dir="$(dirname "$(dirname "$(gc out probe)")")"
  bash "$TREE/scripts/graphify/graph-choices-cadence.sh" disarm > "$W/disarm.log" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then pass "graph-choices-cadence.sh disarm exits 0"; else fail "graph-choices-cadence.sh disarm exits 0 (rc=$rc)"; tail_of "$W/disarm.log" 8; fi
  ( cd "$W/proj" && ctl_env timeout 600 node "$CTL" uninstall --yes ) > "$W/uninstall.log" 2>&1; rc=$? # gnu-ok: guest mode runs only on the Ubuntu test VM
  if [ "$rc" -eq 0 ]; then pass "himmelctl uninstall (no --purge-state) exits 0"; else fail "himmelctl uninstall (no --purge-state) exits 0 (rc=$rc)"; tail_of "$W/uninstall.log" 20; fi
  crontab -l > "$W/cron.step6" 2>/dev/null
  if [ "$(gce_cron_rows "$W/cron.step6")" -eq 0 ]; then pass "no HIMMEL-GraphChoices cron row is left"; else fail "no HIMMEL-GraphChoices cron row is left"; fi
  if [ ! -e "$RUNNER_DIR/graph-choices.sh" ]; then pass "no runner is left"; else fail "no runner is left"; fi
  if [ ! -e "$choices_dir" ]; then pass "no choices/ directory is left"; else fail "no choices/ directory is left ($choices_dir)"; find "$choices_dir" -maxdepth 2 | head -8 | sed 's/^/    | /'; fi # gnu-ok: guest mode runs only on the Ubuntu test VM

  echo "==> 7. settings.e2e.ts on the guest"
  export PATH="$HOME/.bun/bin:$BASE_PATH"
  rm -rf "$HOME/.cache/uv" "$HOME/.cache/node-gyp" "$HOME/.cache/qmd"
  note "free space before the browser download: $(df -h / | awk 'NR==2 { print $4 }')"
  if ! command -v bun >/dev/null 2>&1; then
    fail "bun is on the guest PATH (settings.e2e.ts needs it)"
  else
    E2E="$TREE/scripts/config-ui/tests/e2e"
    ( cd "$E2E" && bun install ) > "$W/e2e-install.log" 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then fail "bun install in tests/e2e exits 0 (rc=$rc)"; tail_of "$W/e2e-install.log" 12
    else
      ( cd "$E2E" && bunx playwright install chromium && sudo -n env "PATH=$PATH" bunx playwright install-deps chromium ) > "$W/e2e-browser.log" 2>&1; rc=$?
      if [ "$rc" -eq 0 ]; then pass "the pinned Chromium and its libraries are installed"; else fail "the pinned Chromium and its libraries are installed (rc=$rc)"; tail_of "$W/e2e-browser.log" 12; fi
      ( cd "$E2E" && E2E_SHOTS="$W/shots" bunx playwright test settings.e2e.ts ) > "$W/e2e.log" 2>&1; rc=$?
      if [ "$rc" -eq 0 ]; then pass "settings.e2e.ts passes on the guest"; else fail "settings.e2e.ts passes on the guest (rc=$rc)"; tail_of "$W/e2e.log" 25; fi
    fi
    for scheme in light dark; do
      f="$W/shots/configure-graph-choices-$scheme.png"
      if [ -s "$f" ]; then
        pass "the $scheme screenshot exists ($(wc -c < "$f" | tr -d ' ') bytes)"
        echo "SHOT settings-graph-choices-$scheme.png $(base64 -w0 "$f")"
      else
        fail "the $scheme screenshot exists"
      fi
    done
    if [ -s "$W/shots/configure-graph-choices-light.png" ] && cmp -s "$W/shots/configure-graph-choices-light.png" "$W/shots/configure-graph-choices-dark.png"; then
      note "the light and dark screenshots are byte-identical: settings.e2e.ts emulateMedia does not switch the UI theme (data-theme)"
    fi
  fi

  verdict
}

host_main() {
  local EXPECT_RED=0
  if [ "${1:-}" = "--expect-red" ]; then EXPECT_RED=1; shift; fi
  [ "$#" -eq 1 ] || usage
  local VM="$1"
  case "$VM" in
    himmel-ar-[0-9] | himmel-ar-[0-9][0-9] | himmel-ci-[0-9] | himmel-ci-[0-9][0-9]) ;;
    *) usage ;;
  esac

  local SNAPSHOT="${HIMMEL_GCE_SNAPSHOT:-suite-ready-v4}"
  local REMOTE_DIR="/tmp/himmel-graph-choices-vm"
  local STAGE_PATHS=(scripts .claude docs/setup marketplace plugins templates .nvmrc .bun-version bunfig.toml VERSION)
  local STAGE_TMP="${HIMMEL_GCE_STAGE_TMP:-${TMPDIR:-/tmp}}"
  local SHOTS="${HIMMEL_GCE_SHOTS_DIR:-$PWD/graph-choices-e2e-shots}"

  vmsdk() {
    if [ -n "${HIMMEL_GCE_VMSDK:-}" ]; then "$HIMMEL_GCE_VMSDK" "$VM" "$@"
    elif command -v uv >/dev/null 2>&1; then uv run "$REPO/scripts/lib/vmsdk.py" "$VM" "$@"
    else python3 "$REPO/scripts/lib/vmsdk.py" "$VM" "$@"; fi
  }
  gx() {
    if [ -n "${HIMMEL_GCE_GUEST_EXEC:-}" ]; then "$HIMMEL_GCE_GUEST_EXEC" "$VM" "$@"
    else bash "$REPO/scripts/vm/guest-exec.sh" "$VM" "$@"; fi
  }
  # shellcheck disable=SC2329  # passed to vm_guest_assert_clean as its runner
  gx_run() { gx -- "$1"; }

  # shellcheck source=vm-lock.sh
  . "$HERE/vm-lock.sh" || { echo "graph-choices-e2e: cannot load vm-lock.sh" >&2; exit 3; }
  # shellcheck source=../lib/vm-guest-excludes.sh
  . "$REPO/scripts/lib/vm-guest-excludes.sh" || { echo "graph-choices-e2e: cannot load vm-guest-excludes.sh; nothing was copied" >&2; exit 3; }

  TARBALL="" OUT="" LOCKED=0 BOOTED=0
  # shellcheck disable=SC2329  # EXIT trap
  cleanup() {
    local rc=$?
    trap - EXIT
    [ -z "$TARBALL" ] || rm -f "$TARBALL"
    [ -z "$OUT" ] || rm -f "$OUT"
    if [ "$BOOTED" = 1 ]; then
      local tries=0
      until vmsdk restore "$SNAPSHOT" >/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ]; then echo "graph-choices-e2e: restore $SNAPSHOT after the run failed; $VM may be dirty" >&2; rc=3; break; fi
        sleep "${HIMMEL_GCE_RESTORE_RETRY_SECS:-10}"
      done
      vmsdk down >/dev/null 2>&1 || { echo "graph-choices-e2e: could not power $VM off" >&2; rc=3; }
    fi
    [ "$LOCKED" != 1 ] || vm_lock_release "$VM"
    exit "$rc"
  }
  trap cleanup EXIT

  vm_lock_acquire_waiting "$VM" || { echo "graph-choices-e2e: vm-lock for $VM is held; refusing" >&2; exit 3; }
  LOCKED=1

  echo "==> graph-choices stage: $VM @ $SNAPSHOT (worktree: $REPO)$([ "$EXPECT_RED" = 1 ] && echo ' [RED control: no S4 pass in the tree]')"
  BOOTED=1
  vmsdk restore "$SNAPSHOT" >/dev/null || { echo "graph-choices-e2e: restore $SNAPSHOT failed" >&2; exit 3; }
  vmsdk up >/dev/null || { echo "graph-choices-e2e: up failed" >&2; exit 3; }

  TARBALL="$(mktemp "$STAGE_TMP/graph-choices-tree.XXXXXX")" || exit 3
  local tar_excl=() _x
  while IFS= read -r _x; do tar_excl+=("$_x"); done < <(vm_guest_tar_excludes)
  [ "$EXPECT_RED" -ne 1 ] || tar_excl+=(--exclude=scripts/graphify/graph-choices-pass.sh)
  { git -C "$REPO" ls-files -z --cached --others --exclude-standard -- "${STAGE_PATHS[@]}" \
      | while IFS= read -r -d '' _f; do [ -L "$REPO/$_f" ] || printf '%s\0' "$_f"; done; } \
    | tar -C "$REPO" "${tar_excl[@]}" -czf "$TARBALL" --null -T - \
    || { echo "graph-choices-e2e: could not build the stage tarball" >&2; exit 3; }
  vmsdk push "$TARBALL" /tmp/himmel-graph-choices-tree.tgz >/dev/null || { echo "graph-choices-e2e: push failed" >&2; exit 3; }
  gx -- "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR && tar -xzf /tmp/himmel-graph-choices-tree.tgz -C $REMOTE_DIR && rm -f /tmp/himmel-graph-choices-tree.tgz" >/dev/null \
    || { echo "graph-choices-e2e: could not unpack the tree on $VM" >&2; exit 3; }
  vm_guest_assert_clean gx_run "$REMOTE_DIR" full || exit 3

  rm -f "$SHOTS/settings-graph-choices-light.png" "$SHOTS/settings-graph-choices-dark.png"
  OUT="$(mktemp "$STAGE_TMP/graph-choices-out.XXXXXX")" || exit 3
  local red=""
  [ "$EXPECT_RED" -ne 1 ] || red="HIMMEL_GCE_RED=1 "
  gx --timeout 3000 -- "${red}HIMMEL_GCE_GUEST=1 bash $REMOTE_DIR/scripts/vm/graph-choices-e2e.sh --guest $REMOTE_DIR" 2>&1 \
    | tee "$OUT" | sed -E 's/^(SHOT [^ ]+) .*/\1 (saved)/'
  local rc="${PIPESTATUS[0]}"

  local name b64 saved=0
  while read -r _tag name b64; do
    case "$name" in *[!A-Za-z0-9._-]* | '' | .* ) continue ;; esac
    case "$name" in *.png) ;; *) continue ;; esac
    mkdir -p "$SHOTS"
    if printf '%s' "$b64" | base64 -d > "$SHOTS/$name" 2>/dev/null; then saved=$((saved + 1)); else rm -f "$SHOTS/$name"; fi
  done < <(grep '^SHOT ' "$OUT")
  [ "$saved" -eq 0 ] || echo "==> saved $saved screenshot(s) to $SHOTS"
  local shot_missing=0 shot
  if [ "$EXPECT_RED" -ne 1 ]; then
    for shot in settings-graph-choices-light.png settings-graph-choices-dark.png; do
      [ -s "$SHOTS/$shot" ] || { echo "graph-choices-e2e: screenshot $shot was not saved to $SHOTS" >&2; shot_missing=1; }
    done
  fi

  local first_line nfail
  first_line="$(grep -m1 -E '^(PASS|FAIL) ' "$OUT")"
  nfail="$(grep -c '^FAIL ' "$OUT")"
  if [ "$EXPECT_RED" -eq 1 ]; then
    if [ "$rc" -ne 0 ] && [ "$first_line" = 'FAIL graph-choices-pass.sh is in the tree (S4 present)' ] && grep -q '^RESULT: 1 failure(s)' "$OUT"; then
      echo "==> RED control PASSED: the first assertion failed on the tree without S4 (rc=$rc)"
      exit 0
    fi
    echo "==> RED control FAILED: the tree without S4 did not fail the stage on its first assertion (rc=$rc, first line: ${first_line:-none})" >&2
    exit 1
  fi
  if [ "$rc" -eq 0 ] && [ "$nfail" -eq 0 ] && [ "$shot_missing" -eq 0 ] && grep -q '^RESULT: 0 failure(s)' "$OUT"; then
    echo "==> graph-choices stage PASSED"
    exit 0
  fi
  echo "==> graph-choices stage FAILED (rc=$rc, $nfail FAIL line(s)$(grep -q '^RESULT: ' "$OUT" || echo ', no RESULT line'))" >&2
  exit 1
}

if [ "${1:-}" = "--guest" ]; then shift; guest_main "$@"; else host_main "$@"; fi
