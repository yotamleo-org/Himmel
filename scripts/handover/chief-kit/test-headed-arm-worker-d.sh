#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2154  # SC2015: A && B || C is intentional in check()/contains()/ends_with()/not_contains(), as in scripts/handover/test-headed-arm.sh; the rest: assigned in the sourced testlib
# scripts/handover/chief-kit/test-headed-arm-worker-d.sh - the fourth part of the
# headed-arm-worker.sh suite (see test-headed-arm-worker.sh for the four parts and
# testlib-headed-arm-worker.sh for what they share): section 17s, the readiness launch -
# headed-arm-worker.sh --profile readiness, its private startup config, lease, delivery gate,
# exec pins and signal handling.
#
# Platform guard: POSIX bash 3.2+, same as headed-arm.sh
# itself (konsole is Linux/KDE-only).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/testlib-headed-arm-worker.sh
. "$HERE/tests/testlib-headed-arm-worker.sh" || { printf 'FAIL - %s (tests/testlib-headed-arm-worker.sh missing, unreadable or failing to load)\n' "$(basename "$0")"; exit 1; }

# What the earlier parts leave exported for the launches below (the definitions are in testlib-headed-arm-worker.sh).
haw_ready26_env
haw_consult_env

# --- 17s. The readiness launch (C0s cycle 2): headed-arm-worker.sh --profile readiness is the ONE launcher of the
# readiness role. It mints the actual session id BEFORE any private config or lease, writes the private startup
# config (the --session-id binding the launcher render checks), validates the final argv with the REAL launcher's
# NUL-preserving render and the C0p effectiveness reader BEFORE it acquires, then acquires ON BEHALF (registering
# nothing for the launcher's own session) and hands the token over through a separate private transport file.
# Every case runs the REAL wrapper, headed-arm.sh, profile resolver, launcher shim and queue-lock.sh against a fake
# HOME, fake queue root, fake runtime dir and a stub konsole: no native claude, provider, VM, real config or secret.
# Every launch passes a Claude Code marker beside seams, which the seam guard refuses on a primary checkout with no claude
# ancestor, so the launcher runs from LAUNCH_TREE (the same bytes, in a tree that is not one): from here HERE names that tree's
# chief-kit directory, and what the rows expect beside the launcher (the adapter, the queue library) follows it.
HERE="$LAUNCH_TREE/scripts/handover/chief-kit"; SCRIPT="$HERE/headed-arm-worker.sh"; HEADED_ARM="$HERE/../headed-arm.sh"
RS="$tmp/rs"; mkdir -p "$RS/hdir/u/r" "$RS/home/.claude" "$RS/repo" "$RS/bin" "$RS/primary/scripts/jira/dist" "$RS/primary-broken/scripts/jira/dist"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RS/bin/claude"; chmod 755 "$RS/bin/claude"
# an outside-the-root canary: a `claude` and a `curl` that log every call. They sit on PATH AFTER the fixture's own claude stub (so
# the stub is what a bare `claude` resolves to) and no row may ever execute them; the final canary row counts their calls.
RS_OUT="$tmp/rs-outside"; mkdir -p "$RS_OUT/canary-bin"; chmod 755 "$RS_OUT"
RS_CANARY_LOG="$RS_OUT/canary.log"; : > "$RS_CANARY_LOG"
for rs_c in claude curl; do
  printf '%s\n' '#!/usr/bin/env bash' "echo \"$rs_c \$*\" >> \"$RS_CANARY_LOG\"" 'exit 22' > "$RS_OUT/canary-bin/$rs_c"; chmod 755 "$RS_OUT/canary-bin/$rs_c"
done
rs_canary() { wc -l < "$RS_CANARY_LOG" 2>/dev/null | tr -d ' ' || true; }
# a background job of a non-interactive shell starts with SIGINT ignored, which no trap can undo: the INT rows need env's --default-signal (GNU)
rs_defsig=()
if env --default-signal=INT true >/dev/null 2>&1; then rs_defsig=(--default-signal=INT); fi
# the fixture root: every root, binary and port a readiness launch touches lives under $RS (see the delivery gate in the wrapper)
printf 'himmel-readiness-fixture-v1' > "$RS/.himmel-readiness-fixture"; chmod 600 "$RS/.himmel-readiness-fixture"; chmod 755 "$RS"
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$RS/proceed-preflight.sh"; chmod 755 "$RS/proceed-preflight.sh"
rs_hook='{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"bash scripts/handover/queue-lock.sh self-heartbeat"}]}]}}'
printf '%s\n' "$rs_hook" > "$RS/home/.claude/settings.json"
mkdir -p "$RS/home-nohook/.claude" "$RS/home-off/.claude" "$RS/home-bad/.claude"
printf '{"hooks":{}}\n' > "$RS/home-nohook/.claude/settings.json"
printf '{"disableAllHooks":true,"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"bash scripts/handover/queue-lock.sh self-heartbeat"}]}]}}\n' > "$RS/home-off/.claude/settings.json"
printf 'not json\n' > "$RS/home-bad/.claude/settings.json"
RS_QL="$(cd "$HERE/.." && pwd -P)/queue-lock.sh"
RS_SECRET="FAKE-SENTINEL-TOKEN-0000"
printf '%s\n' "import { appendFileSync } from 'node:fs'; appendFileSync('$RS/init-calls.log', 'init\n');" \
  "export const baseUrl = () => 'http://127.0.0.1:9';" "export const projectKey = () => 'FIXT';" \
  "export function authHeader() { return 'Basic ' + Buffer.from('fixture@example.invalid:$RS_SECRET').toString('base64'); }" > "$RS/primary/scripts/jira/dist/client.js"
printf '// fake primary CLI\n' > "$RS/primary/scripts/jira/dist/index.js"
printf '%s\n' "export const baseUrl = () => { throw new Error('JIRA_BASE_URL is not set'); };" "export const projectKey = () => 'FIXT';" "export const authHeader = () => 'Basic x';" > "$RS/primary-broken/scripts/jira/dist/client.js"
printf '// fake primary CLI\n' > "$RS/primary-broken/scripts/jira/dist/index.js"
rs_n=0
RS_FLAGS=()
RS_PROFILE=readiness
RS_HOME="$RS/home"
RS_DOC_KIND=plain
rs_status() { env HANDOVER_DIR="$RS/hdir" XDG_RUNTIME_DIR="$RS_D/xdg" bash "$RS_QL" status "$RS_DOC" 2>/dev/null | tail -n 1; }
rs_attempts() { find "$RS_D/xdg/himmel-readiness" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }
rs_lockdir() { find "$RS/hdir/.locks/queue" -maxdepth 1 -name "*$(basename "$RS_DOC" .md | tr -c 'A-Za-z0-9_\n-' '-')*.lock" 2>/dev/null | head -n 1; }
# rs_launch [ENV=val ...]: one real launch. Sets RS_D (stub + run dir), RS_DOC, RS_RC, RS_SID (the id the launcher was handed), RS_A (its attempt dir).
# rs_managed_prepare: a managed fleet bucket for the doc (a keyless manifest row + fleet-control.json), built with the real
# fleet-manifest.sh; the control is made active by editing its anchor the way `control set --mode active` does, without that
# command's policy-cap read of the primary checkout's .env.
rs_managed_prepare() {
  local mf="$RS_DOC_DIR/x.fleet.json" ac="$RS_DOC_DIR/fleet-control.json"
  bash "$HERE/fleet-manifest.sh" control init "$mf" --target 4 >/dev/null 2>&1 || return 1
  jq '.mode = "active" | .generation = 2' "$ac" > "$ac.tmp" && mv "$ac.tmp" "$ac" || return 1
  bash "$HERE/fleet-manifest.sh" add "$mf" "$(cd "$RS_DOC_DIR" && pwd -P)/$(basename "$RS_DOC")" --lane native --pending >/dev/null 2>&1
}
# rs_run_wrapper <env...>: cd + exec of the real wrapper; always called as a subshell or a background job, so the
# background job's pid IS the wrapper's own
rs_run_wrapper() {
  cd "$rs_cwd" && exec env ${rs_defsig[@]+"${rs_defsig[@]}"} PATH="$RS/bin:$RS_OUT/canary-bin:$PATH" IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' HOME="$RS_HOME" CLAUDE_CONFIG_DIR="$RS_HOME/.claude" XDG_RUNTIME_DIR="$RS_D/xdg" HANDOVER_DIR="$RS/hdir" \
    CLAUDE_CODE_SESSION_ID="launcher-scope-$rs_n" HEADED_ARM_WORKER_CLAUDE_BIN="$RS/bin/claude" \
    HEADED_ARM_WORKER_TARGET="$HEADED_ARM" HEADED_ARM_WORKER_PREFLIGHT="$RS/proceed-preflight.sh" \
    KONSOLE_CMD="$RS_D/konsole" PGREP_CMD="$RS_D/pgrep" WORKER_SESSION_REPO="$RS/repo" HEADED_ARM_LOCK_DIR="$RS_D/locks" HEADED_ARM_PROC="$RS_D/proc" \
    WORKER_SESSION_READINESS_FIXTURE="$RS" RS_QL="$RS_QL" "$@" bash "$SCRIPT" ${RS_FLAGS[@]+"${RS_FLAGS[@]}"} --profile "$RS_PROFILE" "$RS_NAME" "$rs_arg" "$RS_D/signal-never" "$PAST" "${RS_LOG_DIR:-$RS_D}/log" claude-sonnet-5-5 > "$RS_D/out" 2>&1
}
rs_launch() {
  rs_n=$((rs_n + 1))
  # RS_MANAGED=1 puts the doc in its own managed fleet bucket
  RS_DOC_DIR="$RS/hdir/u/r"
  [ "${RS_MANAGED:-0}" != 1 ] || { RS_DOC_DIR="$RS/hdir/m$rs_n"; mkdir -p "$RS_DOC_DIR"; }
  [ "${RS_DOC_OUTSIDE:-0}" != 1 ] || { RS_DOC_DIR="$tmp/rs-outside/docs"; mkdir -p "$RS_DOC_DIR"; }
  RS_D="$RS/c$rs_n"; RS_DOC="$RS_DOC_DIR/readiness-v1.$rs_n.0.md"; RS_NAME="${RS_NAME_FIXED:-PROJ-9999-rs$rs_n}"
  mk_launch_stubs "$RS_D" "$RS_NAME"; mkdir -p "$RS_D/xdg"; chmod 700 "$RS_D/xdg"
  [ "${RS_PRE_CONFIRM:-0}" != 1 ] || : > "$RS_D/confirmable"
  case "$RS_DOC_KIND" in
    symlink) fx_brief "# target $rs_n" > "$RS/hdir/u/r/target-$rs_n.md"; ln -s "$RS/hdir/u/r/target-$rs_n.md" "$RS_DOC" ;;
    nofm) printf '# no front matter\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' > "$RS_DOC" ;;
    oddname) RS_DOC="$RS_DOC_DIR/not-a-readiness-doc-$rs_n.md"; fx_brief "# odd name $rs_n" > "$RS_DOC" ;;
    *) fx_brief "# readiness v1.$rs_n.0 fixture" > "$RS_DOC" ;;
  esac
  [ "${RS_MANAGED:-0}" != 1 ] || rs_managed_prepare || echo "FAIL - 17s: the managed fleet fixture could not be built"
  RS_RC=0
  # RS_DOC_REL=1 launches from the doc's own directory with the bare file name, so a relative DOC is the real shape under test
  rs_arg="$RS_DOC"; rs_cwd="$PWD"
  [ "${RS_DOC_REL:-0}" != 1 ] || { rs_cwd="$(dirname "$RS_DOC")"; rs_arg="$(basename "$RS_DOC")"; }
  if [ -n "${RS_BG_UNTIL:-}" ]; then
    rs_run_wrapper "$@" &
    RS_BG_PID=$! RS_BG_D="$RS_D"
    local i=0
    while [ ! -e "$RS_BG_UNTIL" ] && [ "$i" -lt 400 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    [ -e "$RS_BG_UNTIL" ]
    return
  fi
  if [ -n "${RS_SIGNAL_AFTER:-}" ]; then
    # RS_SIGNAL_AFTER=<marker>: a background launch that gets one signal (RS_SIGNAL, default TERM) as soon as a stub creates the marker
    rs_run_wrapper "$@" &
    rs_pid=$!
    rs_i=0; while [ ! -e "$RS_SIGNAL_AFTER" ] && [ "$rs_i" -lt 400 ]; do sleep 0.05; rs_i=$((rs_i + 1)); done
    kill -"${RS_SIGNAL:-TERM}" "$rs_pid" 2>/dev/null
    RS_SECOND_SENT=0
    if [ -n "${RS_SECOND_SIGNAL:-}" ]; then
      sleep 0.2
      kill -"$RS_SECOND_SIGNAL" "$rs_pid" 2>/dev/null && RS_SECOND_SENT=1
    fi
    wait "$rs_pid" || RS_RC=$?
  else
    ( rs_run_wrapper "$@" ) || RS_RC=$?
  fi
  rs_launch_result
}
rs_bg_finish() {
  RS_D="$RS_BG_D" RS_RC=0
  wait "$RS_BG_PID" || RS_RC=$?
  rs_launch_result
}
rs_launch_result() {
  [ -z "${RS_DEBUG:-}" ] || { echo "--- rs$rs_n rc=$RS_RC"; cat "$RS_D/out"; }
  [ "$RS_RC" -ne 0 ] || wait_record "$RS_D" || true
  RS_SID="$(grep -oE 'WORKER_SESSION_ID=[0-9a-f-]{36}' "$RS_D/record" 2>/dev/null | head -n 1 | cut -d= -f2)"
  RS_A="$RS_D/xdg/himmel-readiness/$RS_SID"
}
rs_decode() { local el; while IFS= read -r -d '' el; do printf '[%s]' "$el"; done; printf '\n'; }
# rs_msg <label> <text>: the launch's own output names the reason
rs_msg() { contains "17s $1" "$(cat "$RS_D/out" 2>/dev/null)" "$2"; }
# rs_refused <label>: the launch was refused and NOTHING was acquired, written to the queue, or launched.
rs_refused() {
  check "17s refuses $1: non-zero exit" "$([ "$RS_RC" -ne 0 ] && echo yes || echo no)" "yes"
  check "17s refuses $1: never reached konsole" "$([ -e "$RS_D/record" ] && echo launched || echo no)" "no"
  check "17s refuses $1: the queue lock is still free (nothing acquired)" "$(rs_status)" "free"
  check "17s refuses $1: no private attempt directory is left behind" "$(rs_attempts)" "0"
  check "17s refuses $1: no lock directory was created" "$([ -n "$(rs_lockdir)" ] && echo yes || echo no)" "no"
}

# the success path
rs_launch
rs_tok="$(cat "$RS_A/lease-token" 2>/dev/null || true)"
rs_set="$RS_A/leg-settings.json"; rs_mcp="$RS_A/leg-mcp.json"
check "17s launch: exit 0 and the launch reached konsole" "$RS_RC:$([ -s "$RS_D/record" ] && echo yes)" "0:yes"
contains "17s launch: the launcher env carries the readiness role marker" "$(cat "$RS_D/record")" "WORKER_SESSION_PROFILE_READINESS=1"
check "17s launch: the minted session id is a uuid" "$(printf '%s' "$RS_SID" | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')" "1"
not_contains "17s launch: no Remote Control name (the readiness role is never remote)" "$(cat "$RS_D/record")" "WORKER_SESSION_REMOTE_CONTROL="
check "17s launch: the generated settings are exactly the four allowed keys, no hooks, exactly the two grants" \
  "$(jq -c '[(keys | sort), .permissions.allow, (.permissions | keys | sort)]' "$rs_set" 2>/dev/null || true)" \
  '[["enabledPlugins","permissions","skillListingBudgetFraction","skillOverrides"],["mcp__readiness__inspect","mcp__readiness__act"],["allow","deny"]]'
check "17s launch: the strict MCP config is exactly the one readiness adapter bound to the private startup config" \
  "$(jq -c . "$rs_mcp" 2>/dev/null || true)" \
  "$(jq -cn --arg a "$(cd "$HERE" && pwd -P)/readiness-tools.mjs" --arg s "$RS_A/startup.json" '{mcpServers:{readiness:{command:"node",args:[$a,"--startup-config",$s]}}}')"
check "17s launch: the private attempt directory is mode 0700 and holds four files at mode 0600" \
  "$(stat -c '%a' "$RS_A" 2>/dev/null):$(find "$RS_A" -mindepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' '):$(stat -c '%a' "$RS_A"/leg-mcp.json "$RS_A"/leg-settings.json "$RS_A"/lease-token "$RS_A"/startup.json 2>/dev/null | tr '\n' ' ')" "700:lease-token leg-mcp.json leg-settings.json startup.json :600 600 600 600 "  # gnu-ok: this suite is Linux-only (konsole), where GNU stat is the platform tool
check "17s launch: the startup config carries the minted id as its immutable session scope, the canonical doc and no token" \
  "$(jq -c '[.schema, .session_scope, .version, .doc, .lane, .model, .port, .queue_lock, .runtime_dir, .handover_dir, (.attempt_id | length > 0), (keys | join(","))]' "$RS_A/startup.json" 2>/dev/null || true)" \
  "$(jq -cn --arg sid "$RS_SID" --arg ver "v1.$rs_n.0" --arg doc "$RS_DOC" --arg ql "$RS_QL" --arg xdg "$RS_D/xdg" --arg hd "$RS/hdir" '["readiness-startup-v1",$sid,$ver,$doc,"native","claude-sonnet-5-5",{kind:"copy"},$ql,$xdg,$hd,true,"attempt_id,doc,handover_dir,lane,model,port,queue_lock,runtime_dir,schema,session_scope,version"]')"
rs_render="$(env -i PATH="$PATH" HOME="$RS/home" WORKER_SESSION_CLAUDE_BIN="$RS/bin/claude" WORKER_SESSION_PROFILE_READINESS=1 WORKER_SESSION_RENDER_ARGV=1 \
  WORKER_SESSION_PROFILE_SETTINGS="$rs_set" WORKER_SESSION_PROFILE_MCP_CONFIG="$rs_mcp" WORKER_SESSION_ID="$RS_SID" \
  bash "$SHIM" --model claude-sonnet-5-5 --autocompact 200000 -n "$RS_NAME" "load $RS_DOC and continue" 2>/dev/null | rs_decode)"
contains "17s launch: the REAL launcher render accepts the generated files and binds exactly the minted id" "$rs_render" "[--session-id][$RS_SID]"
check "17s launch: the lock is held on behalf (a fresh holder exists, nobody registered)" "$(rs_status)" "status: FRESH"
check "17s launch: the lock owner is the transported token" "$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null || true)" "$rs_tok"
check "17s launch: the token is non-empty" "$([ -n "$rs_tok" ] && echo yes)" "yes"
check "17s launch: nothing is registered for the launcher's own session scope (no token file, no sidecar)" "$(find "$RS_D/xdg/himmel-queue-lock" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
check "17s launch: no liveness marker was written for the unadopted lease" "$([ -e "$(rs_lockdir)/liveness" ] && echo yes || echo no)" "no"
check "17s launch: the token appears only in its transport and the lock's owner record" \
  "$(grep -rlF -- "$rs_tok" "$RS_D" "$RS/hdir" "$tmp/pinned-himmelctl-cache" 2>/dev/null | sed 's|.*/||' | sort | tr '\n' ' ')" "lease-token owner owner.json "
check "17s launch: the minted id is recorded in the doc front matter" "$(grep -c "^session_ids:.*$RS_SID" "$RS_DOC")" "1"
check "17s copy port: never creates a credentials file" "$(find "$RS_D/xdg/himmel-readiness" -name credentials.json 2>/dev/null | wc -l | tr -d ' ')" "0"
# the generic worker preface is for a worker that acquires, ships and holds: this role is already leased, has no shell and two tools
check "17s preface: the readiness role writes no generic worker preface or brief contract and hands the launcher no preface path" \
  "$([ -e "$RS_D/$RS_NAME.worker-preface.md" ] && echo file || echo none):$(grep -c '^WORKER_SESSION_PROFILE_PREFACE=' "$RS_D/env-record" 2>/dev/null || true):$([ -e "$RS_D/$RS_NAME.worker-contract.md" ] && echo contract || echo none)" "none:0:none"
# the REAL render, in the very environment the stub konsole received (the preface variable included when there is one)
rs_render_env="$(grep -E '^WORKER_SESSION_PROFILE_PREFACE=' "$RS_D/env-record" 2>/dev/null || true)"
rs_render3="$(env -i PATH="$PATH" HOME="$RS/home" WORKER_SESSION_CLAUDE_BIN="$RS/bin/claude" WORKER_SESSION_PROFILE_READINESS=1 WORKER_SESSION_RENDER_ARGV=1 \
  WORKER_SESSION_PROFILE_SETTINGS="$rs_set" WORKER_SESSION_PROFILE_MCP_CONFIG="$rs_mcp" WORKER_SESSION_ID="$RS_SID" ${rs_render_env:+"$rs_render_env"} \
  bash "$SHIM" --model claude-sonnet-5-5 --autocompact 200000 -n "$RS_NAME" "load $RS_DOC and continue" 2>/dev/null | rs_decode)"
contains "17s preface: the rendered final argv still binds the minted id and the strict MCP config" "$rs_render3" "[--session-id][$RS_SID]"
not_contains "17s preface: the rendered final argv carries no --append-system-prompt-file" "$rs_render3" "[--append-system-prompt-file]"

mkdir -p "$RS/shared"
cat > "$RS/hold-preflight.sh" <<'HOLD_PREFLIGHT'
#!/usr/bin/env bash
dir="$(dirname "$0")"
: > "$dir/held"
for ((i = 0; i < 600; i++)); do
  if [ -e "$dir/hold.go" ]; then
    echo PROCEED
    exit 0
  fi
  sleep 0.1
done
: > "$dir/hold.timed-out"
echo SKIPPED-FLEET
HOLD_PREFLIGHT
chmod 755 "$RS/hold-preflight.sh"
rs_shared_name=PROJ-9999-rs-shared
rs_case_render() {
  env -i PATH="$PATH" HOME="$RS/home" WORKER_SESSION_CLAUDE_BIN="$RS/bin/claude" WORKER_SESSION_PROFILE_READINESS=1 WORKER_SESSION_RENDER_ARGV=1 \
    WORKER_SESSION_PROFILE_SETTINGS="$1" WORKER_SESSION_PROFILE_MCP_CONFIG="$2" WORKER_SESSION_ID="$RS_SID" \
    bash "$SHIM" --model claude-sonnet-5-5 --autocompact 200000 -n "$rs_shared_name" "load $3 and continue" 2>/dev/null | rs_decode
}
rs_hold_rc=0
RS_NAME_FIXED="$rs_shared_name" RS_LOG_DIR="$RS/shared" RS_BG_UNTIL="$RS/held" rs_launch HEADED_ARM_WORKER_PREFLIGHT="$RS/hold-preflight.sh" || rs_hold_rc=$?
check "17s-10351 T1 control: A reached its held preflight" "$rs_hold_rc" "0"
rs_a_doc="$RS_DOC"
RS_NAME_FIXED="$rs_shared_name" RS_LOG_DIR="$RS/shared" rs_launch
check "17s-10351 T1 control: B finished and reached konsole" "$RS_RC:$([ -s "$RS_D/record" ] && echo yes)" "0:yes"
rs_b_config="$RS_A/leg"
[ -f "$rs_b_config-mcp.json" ] || rs_b_config="$RS/shared/$rs_shared_name.leg"
contains "17s-10351 T1 control: B renders with its own id" "$(rs_case_render "$rs_b_config-settings.json" "$rs_b_config-mcp.json" "$RS_DOC")" "[--session-id][$RS_SID]"
: > "$RS/hold.go"
rs_bg_finish
check "17s-10351 T1 control: A did not time out" "$([ -e "$RS/hold.timed-out" ] && echo yes || echo no)" "no"
rs_a_render="$(rs_case_render "$RS_A/leg-settings.json" "$RS_A/leg-mcp.json" "$rs_a_doc")"
rs_a_scope="$(jq -r .session_scope "$RS_A/startup.json" 2>/dev/null)"
rs_a_bound=no
if [ -n "$RS_SID" ] && [ "$RS_SID" = "$rs_a_scope" ] && [[ "$rs_a_render" == *"[--session-id][$RS_SID]"* ]]; then
  rs_a_bound=yes
fi
check "17s-10351 T1: A launches and renders with its own immutable id" \
  "$RS_RC:$(grep -cF 'the launcher refused the generated argv' "$RS_D/out" || true):$rs_a_bound" "0:0:yes"

rs_launch
rs_t2_layout="$(stat -c '%a' "$RS_A" 2>/dev/null):$(find "$RS_A" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' '):$(stat -c '%a' "$RS_A"/leg-mcp.json "$RS_A"/leg-settings.json "$RS_A"/lease-token "$RS_A"/startup.json 2>/dev/null | tr '\n' ' ')"  # gnu-ok: this suite is Linux-only
check "17s-10351 T2: readiness files are private and absent from the log directory" \
  "$rs_t2_layout:$(find "$RS_D" -maxdepth 1 -name "$RS_NAME.leg-*.json" -type f | wc -l | tr -d ' ')" \
  "700:lease-token leg-mcp.json leg-settings.json startup.json :600 600 600 600 :0"

# a relative DOC is leased, configured AND loaded as the same canonical document
RS_DOC_REL=1; rs_launch; RS_DOC_REL=0
check "17s relative doc: the launch succeeds" "$RS_RC" "0"
check "17s relative doc: the startup config names the canonical absolute doc and that doc is the one leased" \
  "$(jq -r .doc "$RS_A/startup.json" 2>/dev/null || true):$(rs_status)" "$RS_DOC:status: FRESH"
contains "17s relative doc: the loaded prompt names the canonical absolute doc" "$(cat "$RS_D/record")" "load $RS_DOC and continue"
not_contains "17s relative doc: the loaded prompt never carries the bare relative name" "$(cat "$RS_D/record")" "load readiness-v1.$rs_n.0.md and continue"

# every unsupported shape refuses BEFORE it acquires
for rs_shape in "lane claudex|--lane claudex" "lane openrouter|--lane openrouter" "lane deepseek|--lane deepseek" "a consult|--consult" "a judge|--judge" "a relay|--relay" "headless|--headless" "no-profile|--no-profile"; do
  # shellcheck disable=SC2206 # the flag spelling splits into its words on purpose
  RS_FLAGS=(${rs_shape#*|}); rs_launch; rs_refused "${rs_shape%%|*}"
done
RS_FLAGS=()
RS_PROFILE="readiness,worker-impl"; rs_launch; rs_refused "a composed profile list"
RS_PROFILE="worker-impl"; rs_launch
check "17s a generic profile launch is unchanged: launched, no readiness marker, no attempt directory" "$RS_RC:$(grep -c 'WORKER_SESSION_PROFILE_READINESS' "$RS_D/record" 2>/dev/null || true):$(rs_attempts)" "0:0:0"
check "17s a generic profile launch keeps its worker preface and the brief contract (only the readiness role drops them)" \
  "$([ -s "$RS_D/$RS_NAME.worker-preface.md" ] && echo preface):$(grep -c '^WORKER_SESSION_PROFILE_PREFACE=' "$RS_D/env-record" 2>/dev/null || true):$([ -e "$RS_D/$RS_NAME.worker-contract.md" ] && echo contract)" "preface:1:contract"
check "17s-10351 T2 control: generic profile keeps settings in the log directory and has no attempt" \
  "$([ -s "$RS_D/$RS_NAME.leg-settings.json" ] && echo yes):$(rs_attempts)" "yes:0"
RS_PROFILE=readiness
RS_FLAGS=(--dry-run); rs_launch; RS_FLAGS=()
check "17s dry-run: exits 0 and writes nothing (no attempt directory, no lease, no settings or MCP file, no recorded id, no launch)" \
  "$RS_RC:$(rs_attempts):$(rs_status):$(find "$RS_D" -name 'leg-*.json' -o -name '*.leg-*.json' | wc -l | tr -d ' '):$(grep -c '^session_ids:' "$RS_DOC"):$([ -e "$RS_D/record" ] && echo launched || echo none)" "0:0:free:0:0:none"
rs_launch HEADED_ARM_WORKER_CLAUDE_BIN=relative/claude;   rs_refused "a relative binary (refused before the acquire)"
rs_launch HEADED_ARM_WORKER_CLAUDE_BIN="$RS/bin/no-such"; rs_refused "a missing binary (the real render refuses before the acquire)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RS/bin/claude-codex"; chmod 755 "$RS/bin/claude-codex"
rs_launch HEADED_ARM_WORKER_CLAUDE_BIN="$RS/bin/claude-codex"; rs_refused "a lane launcher binary (claude-codex)"
RS_DOC_KIND=symlink; rs_launch; rs_refused "a doc that is a symlink"
RS_DOC_KIND=nofm;    rs_launch; rs_refused "a doc with no front matter"
RS_DOC_KIND=oddname; rs_launch; rs_refused "a doc not named readiness-<VERSION>.md"
RS_DOC_KIND=plain

# C0p: only an effective self-heartbeat wiring may acquire; ineffective AND unknown refuse before the acquire
RS_HOME="$RS/home-nohook"; rs_launch; rs_refused "an ineffective self-heartbeat wiring (no hook)"
RS_HOME="$RS/home-off";    rs_launch; rs_refused "an ineffective self-heartbeat wiring (disableAllHooks)"
RS_HOME="$RS/home-bad";    rs_launch; rs_refused "an unknown self-heartbeat wiring (malformed layer)"
RS_HOME="$RS/home"

# the host-private Jira port: the credentials come only from the existing client flow, only into the private file
rs_launch WORKER_SESSION_READINESS_PORT=jira WORKER_SESSION_READINESS_PRIMARY_CLI="$RS/primary/scripts/jira/dist/index.js"
check "17s jira port: exit 0 and the credentials file is a private mode-0600 file in the 0700 attempt directory" \
  "$RS_RC:$(stat -c '%a' "$RS_A" "$RS_A/credentials.json" 2>/dev/null | tr '\n' ' ')" "0:700 600 "  # gnu-ok: this suite is Linux-only (konsole), where GNU stat is the platform tool
check "17s jira port: the credentials file holds exactly the four resolved fields" \
  "$(jq -c '[keys, .base_url, .project, .email, .api_token]' "$RS_A/credentials.json" 2>/dev/null || true)" \
  "$(jq -cn --arg t "$RS_SECRET" '[["api_token","base_url","email","project"],"http://127.0.0.1:9","FIXT","fixture@example.invalid",$t]')"
check "17s jira port: the startup config names the host-chosen port, the credentials path and the primary CLI" \
  "$(jq -c '.port' "$RS_A/startup.json" 2>/dev/null || true)" \
  "$(jq -cn --arg c "$RS_A/credentials.json" --arg p "$RS/primary/scripts/jira/dist/index.js" '{kind:"jira",credentials_path:$c,primary_cli:$p}')"
check "17s jira port: the credential appears in the private credentials file only" \
  "$(grep -rlF -- "$RS_SECRET" "$RS_D" "$RS/hdir" "$tmp/pinned-himmelctl-cache" 2>/dev/null | sed 's|.*/||' | sort | tr '\n' ' ')" "credentials.json "
rs_launch WORKER_SESSION_READINESS_PORT=jira;                                                             rs_refused "the jira port with no primary CLI"
rs_launch WORKER_SESSION_READINESS_PORT=jira WORKER_SESSION_READINESS_PRIMARY_CLI=relative/index.js;     rs_refused "the jira port with a relative primary CLI"
rs_launch WORKER_SESSION_READINESS_PORT=jira WORKER_SESSION_READINESS_PRIMARY_CLI="$RS/primary-broken/scripts/jira/dist/index.js"; rs_refused "a jira port whose client cannot resolve its configuration"
rs_launch WORKER_SESSION_READINESS_PORT=other;                                                            rs_refused "a port kind that is neither copy nor jira"

# the readiness guard's role marker (C0s cycle 5): HIMMEL_READINESS=1 reaches the worker from THIS trusted launcher only, to
# exactly 1; an ambient claim never survives, and a generic worker never carries it. The oracle is konsole's own environment.
rs_marker() { grep -E '^HIMMEL_READINESS=' "$RS_D/env-record" 2>/dev/null | tr '\n' ' ' || true; }
rs_launch
check "17s marker: a readiness launch hands the worker HIMMEL_READINESS=1, exactly once" "$RS_RC:$(rs_marker)" "0:HIMMEL_READINESS=1 "
rs_launch HIMMEL_READINESS=yes
check "17s marker: an ambient claim (yes) on a readiness launch is replaced by exactly 1" "$RS_RC:$(rs_marker)" "0:HIMMEL_READINESS=1 "
rs_launch HIMMEL_READINESS=0
check "17s marker: an ambient claim (0) on a readiness launch is replaced by exactly 1" "$RS_RC:$(rs_marker)" "0:HIMMEL_READINESS=1 "
RS_PROFILE=worker-impl
rs_launch
check "17s marker: a generic worker launch carries no readiness marker" "$RS_RC:$(rs_marker)" "0:"
rs_launch HIMMEL_READINESS=1
check "17s marker: an ambient HIMMEL_READINESS=1 never reaches a generic worker" "$RS_RC:$(rs_marker)" "0:"
RS_PROFILE=readiness

# the host-admitted catalog (thin C0): a launching-shell seam like the port and the primary CLI. The launcher copies exactly
# {source_head, roots, catalog} into the private startup config (the adapter is the one validator); anything else refuses
# BEFORE the attempt directory exists, and the seam itself is never handed to the worker.
rs_cat_sha="$(printf 'b%.0s' $(seq 1 64))"
rs_cat_head="$(printf 'a%.0s' $(seq 1 40))"
jq -cn --arg h "$rs_cat_head" --arg r "$RS" --arg s "$rs_cat_sha" \
  '{source_head:$h,roots:{repo:$r,evidence:$r},catalog:[{id:"issue.copied",kind:"issue",key:"HIMMEL-1",file:"i.json",size:2,sha256:$s,purpose:"copied issue"}]}' > "$RS/catalog-ok.json"
chmod 600 "$RS/catalog-ok.json"
rs_launch WORKER_SESSION_READINESS_CATALOG="$RS/catalog-ok.json"
check "17s catalog: a valid host catalog launches" "$RS_RC" "0"
check "17s catalog: the startup config holds the existing keys plus exactly source_head, roots and catalog" \
  "$(jq -c 'keys | join(",")' "$RS_A/startup.json" 2>/dev/null || true)" '"attempt_id,catalog,doc,handover_dir,lane,model,port,queue_lock,roots,runtime_dir,schema,session_scope,source_head,version"'
check "17s catalog: the three fields are the host file's, byte for byte" \
  "$(jq -cS '[.source_head,.roots,.catalog]' "$RS_A/startup.json" 2>/dev/null || true)" "$(jq -cS '[.source_head,.roots,.catalog]' "$RS/catalog-ok.json")"
check "17s catalog: the startup config stays a private mode-0600 file" "$(stat -c '%a' "$RS_A/startup.json" 2>/dev/null || true)" "600"  # gnu-ok: the readiness rows above assert the same Linux-only GNU stat
check "17s catalog: the seam is never handed to the worker's environment" "$(grep -c '^WORKER_SESSION_READINESS_CATALOG=' "$RS_D/env-record" 2>/dev/null || true)" "0"
rs_launch
check "17s catalog: with no seam the startup config carries no catalog fields (unchanged)" \
  "$(jq -c '[has("source_head"), has("roots"), has("catalog")]' "$RS_A/startup.json" 2>/dev/null || true)" "[false,false,false]"
RS_FLAGS=(--dry-run); rs_launch WORKER_SESSION_READINESS_CATALOG="$RS/catalog-ok.json"; RS_FLAGS=()
check "17s catalog: a dry run with the seam still writes nothing (no attempt directory, no lease, no launch)" "$RS_RC:$(rs_attempts):$(rs_status):$([ -e "$RS_D/record" ] && echo launched || echo none)" "0:0:free:none"
printf 'not json\n' > "$RS/catalog-notjson.json"
printf '[]\n' > "$RS/catalog-array.json"
printf '{}\n' > "$RS/catalog-empty.json"
jq -c '. + {extra: 1}' "$RS/catalog-ok.json" > "$RS/catalog-4keys.json"
jq -c 'del(.roots)' "$RS/catalog-ok.json" > "$RS/catalog-2keys.json"
jq -cn --arg p "$(head -c 17000 /dev/zero | tr '\0' x)" '{source_head:$p,roots:{},catalog:[]}' > "$RS/catalog-big.json"
ln -sf "$RS/catalog-ok.json" "$RS/catalog-link.json"
mkdir -p "$RS/catalog-dir"
cp "$RS/catalog-ok.json" "$RS_OUT/catalog-outside.json"
for rs_cat_case in "a relative path|catalog-ok.json" "a missing file|$RS/catalog-missing.json" "a symlinked file|$RS/catalog-link.json" "a directory|$RS/catalog-dir" \
  "a file over 16 KiB|$RS/catalog-big.json" "a file that is not JSON|$RS/catalog-notjson.json" "a JSON array|$RS/catalog-array.json" "an empty object|$RS/catalog-empty.json" \
  "a document with a fourth key|$RS/catalog-4keys.json" "a document missing a key|$RS/catalog-2keys.json" "a file outside the fixture root|$RS_OUT/catalog-outside.json"; do
  rs_launch WORKER_SESSION_READINESS_CATALOG="${rs_cat_case#*|}"
  rs_refused "the host catalog seam as ${rs_cat_case%%|*}"
done
# the catalog's CONTENTS are validated by the adapter's own validator before anything is created or acquired (cycle 5 review F6):
# a document with exactly the three keys but invalid contents refuses before the attempt directory, the credentials and the lease
jq -c '.source_head = "HEAD"' "$RS/catalog-ok.json" > "$RS/catalog-badhead.json"
jq -c '.roots.repo = "relative/repo"' "$RS/catalog-ok.json" > "$RS/catalog-badroot.json"
jq -c '.catalog[0].kind = "url"' "$RS/catalog-ok.json" > "$RS/catalog-badkind.json"
jq -c '.catalog = [range(0; 9) as $i | .catalog[0] + {id: ("issue.n" + ($i | tostring))}]' "$RS/catalog-ok.json" > "$RS/catalog-nine.json"
jq -c '.catalog[0].size = 70000' "$RS/catalog-ok.json" > "$RS/catalog-oversize.json"
RS_FLAGS=(--dry-run)
rs_launch WORKER_SESSION_READINESS_CATALOG="$RS/catalog-badhead.json"
RS_FLAGS=()
check "17s-10351 T7: dry run refuses a malformed catalog without writing" \
  "$RS_RC:$(rs_attempts):$(rs_status):$([ -e "$RS_D/record" ] && echo launched || echo none)" "2:0:free:none"
rs_msg "10351 T7: dry-run catalog reason" "the host catalog contents are not a valid readiness catalog"
for rs_cat_case in "a head that is not a 40-hex commit|$RS/catalog-badhead.json" "a relative repo root|$RS/catalog-badroot.json" "an unknown entry kind|$RS/catalog-badkind.json" \
  "nine entries (and several copied issues)|$RS/catalog-nine.json" "an entry larger than the per-request limit|$RS/catalog-oversize.json"; do
  rs_launch WORKER_SESSION_READINESS_CATALOG="${rs_cat_case#*|}"
  rs_refused "the host catalog with ${rs_cat_case%%|*} (valid keys, invalid contents)"
done
rs_launch WORKER_SESSION_READINESS_CATALOG="$RS/catalog-ok.json"
check "17s catalog: the valid catalog still launches after the contents pre-check, with the same bytes embedded" \
  "$RS_RC:$(jq -cS '[.source_head,.roots,.catalog]' "$RS_A/startup.json" 2>/dev/null || true)" "0:$(jq -cS '[.source_head,.roots,.catalog]' "$RS/catalog-ok.json")"
rs_launch WORKER_SESSION_READINESS_FIXTURE= WORKER_SESSION_READINESS_CATALOG="$RS/catalog-ok.json"
rs_refused "a catalog seam with no fixture root (the delivery gate still refuses first)"
rs_msg "catalog seam: the delivery gate names its own reason, not the catalog" "its delivery is not registered"

# the credential initialisation (a real secret resolution in the real flow) runs only after EVERY cheap refusal, and before the acquire
rs_init_calls() { wc -l < "$RS/init-calls.log" 2>/dev/null | tr -d ' ' || true; }
rs_jira=(WORKER_SESSION_READINESS_PORT=jira WORKER_SESSION_READINESS_PRIMARY_CLI="$RS/primary/scripts/jira/dist/index.js")
rs_before="$(rs_init_calls)"
rs_launch "${rs_jira[@]}" HEADED_ARM_WORKER_CLAUDE_BIN=relative/claude
rs_refused "a relative binary with the jira port (render refuses)"
check "17s credential order: a launch the render refuses never initialises credentials" "$(rs_init_calls)" "$rs_before"
RS_HOME="$RS/home-nohook"; rs_before="$(rs_init_calls)"; rs_launch "${rs_jira[@]}"
rs_refused "an ineffective self-heartbeat wiring with the jira port"
check "17s credential order: a launch C0p refuses never initialises credentials" "$(rs_init_calls)" "$rs_before"
RS_HOME="$RS/home-bad"; rs_before="$(rs_init_calls)"; rs_launch "${rs_jira[@]}"
rs_refused "an unknown self-heartbeat wiring with the jira port"
check "17s credential order: an unknown C0p result never initialises credentials" "$(rs_init_calls)" "$rs_before"
RS_HOME="$RS/home"; RS_DOC_KIND=oddname; rs_before="$(rs_init_calls)"; rs_launch "${rs_jira[@]}"
rs_refused "a mis-named doc with the jira port"
check "17s credential order: a shape refusal never initialises credentials" "$(rs_init_calls)" "$rs_before"
RS_DOC_KIND=plain
# a held lease refuses AFTER the initialisation (it precedes the acquire): the credential file goes with the attempt directory
rs_next=$((rs_n + 1)); rs_held_doc="$RS/hdir/u/r/readiness-v1.$rs_next.0.md"; fx_brief "# held readiness fixture (jira)" > "$rs_held_doc"
mkdir -p "$RS/held-runtime-j"; chmod 700 "$RS/held-runtime-j"
env HANDOVER_DIR="$RS/hdir" XDG_RUNTIME_DIR="$RS/held-runtime-j" QUEUE_LOCK_ON_BEHALF=1 bash "$RS_QL" acquire "$rs_held_doc" foreign-jira-holder >/dev/null 2>&1
rs_before="$(rs_init_calls)"; rs_launch "${rs_jira[@]}"
check "17s credential order: a held lease refuses the launch after exactly one initialisation" "$([ "$RS_RC" -ne 0 ] && echo refused):$(( $(rs_init_calls) - rs_before ))" "refused:1"
check "17s credential order: ... the credential file is removed with the attempt directory and the holder keeps the lease" \
  "$(rs_attempts):$(find "$RS_D" -name credentials.json 2>/dev/null | wc -l | tr -d ' '):$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null || true)" "0:0:foreign-jira-holder"
# a failing initialisation acquires nothing and leaves nothing
rs_launch WORKER_SESSION_READINESS_PORT=jira WORKER_SESSION_READINESS_PRIMARY_CLI="$RS/primary-broken/scripts/jira/dist/index.js"
rs_refused "a jira client that cannot initialise (after every cheap refusal passed)"

# a failed hand-off after the acquire releases the launcher's OWN captured token, and never a successor's
printf '%s\n' '#!/usr/bin/env bash' 'exit 5' > "$RS/fail-target.sh"; chmod 755 "$RS/fail-target.sh"
rs_launch HEADED_ARM_WORKER_TARGET="$RS/fail-target.sh"
check "17s failed hand-off: the wrapper returns the target's status" "$RS_RC" "5"
check "17s failed hand-off: the launcher's own lease is released" "$(rs_status)" "free"
check "17s failed hand-off: the private attempt directory (transport included) is removed" "$(rs_attempts)" "0"
cat > "$RS/successor-target.sh" <<'SUCC_EOF'
#!/usr/bin/env bash
# a successor takes the lock between the launcher's acquire and its failure cleanup ($2 is the doc)
tok="$(cat "$XDG_RUNTIME_DIR"/himmel-readiness/*/lease-token)"
bash "$RS_QL" release "$2" "$tok" >/dev/null 2>&1
bash "$RS_QL" acquire "$2" successor-token-for-test >/dev/null 2>&1
exit 5
SUCC_EOF
chmod 755 "$RS/successor-target.sh"
rs_launch HEADED_ARM_WORKER_TARGET="$RS/successor-target.sh"
check "17s successor: the launcher cleanup never releases a successor's lock (it is still held by the successor)" \
  "$(rs_status):$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null || true)" "status: FRESH:successor-token-for-test"
check "17s successor: the launcher's own attempt directory is still removed" "$(rs_attempts)" "0"

rs_launch HEADED_ARM_WORKER_TARGET="$RS/successor-target.sh" QUEUE_LOCK_FORCE_RELEASE=1 QUEUE_LOCK_SESSION_SCOPE=foreign-launcher
check "17s ambient force release never releases the successor's lock" \
  "$(rs_status):$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null || true)" "status: FRESH:successor-token-for-test"
check "17s ambient force release still removes only the launcher's attempt directory" "$(rs_attempts)" "0"

rs_next=$((rs_n + 1))
rs_held_doc="$RS/hdir/u/r/readiness-v1.$rs_next.0.md"
fx_brief "# held readiness fixture" > "$rs_held_doc"
mkdir -p "$RS/held-runtime"; chmod 700 "$RS/held-runtime"
env HANDOVER_DIR="$RS/hdir" XDG_RUNTIME_DIR="$RS/held-runtime" QUEUE_LOCK_ON_BEHALF=1 \
  bash "$RS_QL" acquire "$rs_held_doc" foreign-readiness-token >/dev/null 2>&1
rs_launch QUEUE_LOCK_TAKEOVER=1 QUEUE_LOCK_FORCE_RELEASE=1
check "17s ambient takeover refuses an already held lease" "$([ "$RS_RC" -ne 0 ] && echo yes || echo no)" "yes"
check "17s ambient takeover never reaches konsole" "$([ -e "$RS_D/record" ] && echo launched || echo no)" "no"
check "17s ambient takeover preserves the original holder" \
  "$(rs_status):$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null || true)" "status: FRESH:foreign-readiness-token"

# a session may be coming up on hand-off statuses 7 (konsole up, claude unseen) and 9 (scan indeterminate): the lease, its
# transport and the attempt directory are KEPT for the session's own adoption
rs_kept() { # rs_kept <label>: the launcher's own token still holds the lease and its transport is still there
  local tf; tf="$(find "$RS_D/xdg/himmel-readiness" -name lease-token 2>/dev/null | head -n 1)"
  check "17s $1: the lease is kept, held by the transported token" \
    "$(rs_status):$([ -n "$tf" ] && [ "$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null)" = "$(cat "$tf")" ] && echo same)" "status: FRESH:same"
  check "17s $1: the attempt directory is kept" "$(find "$RS_D/xdg/himmel-readiness" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" "1"
}
for rs_rc in 7 9; do
  printf '%s\n' '#!/usr/bin/env bash' "exit $rs_rc" > "$RS/rc$rs_rc-target.sh"; chmod 755 "$RS/rc$rs_rc-target.sh"
  rs_launch HEADED_ARM_WORKER_TARGET="$RS/rc$rs_rc-target.sh"
  check "17s hand-off status $rs_rc is returned" "$RS_RC" "$rs_rc"
  rs_kept "hand-off status $rs_rc"
done

RS_PRE_CONFIRM=1 rs_launch
check "17s-10351 T3: already-running succeeds without reaching konsole" \
  "$RS_RC:$([ -e "$RS_D/record" ] && echo launched || echo no)" "0:no"
check "17s-10351 T3: already-running releases the lease and removes the attempt" \
  "$(rs_status):$(find "$RS_D/xdg/himmel-readiness" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" "free:0"
cat > "$RS/word-target.sh" <<'WORD_TARGET'
#!/usr/bin/env bash
trap 'sleep 1; exit 0' TERM
printf '%s\n' already-running > "$HEADED_ARM_OUTCOME_FILE"
: > "$(dirname "$0")/word-mark"
sleep 10 &
wait
WORD_TARGET
chmod 755 "$RS/word-target.sh"
RS_SIGNAL_AFTER="$RS/word-mark" rs_launch HEADED_ARM_WORKER_TARGET="$RS/word-target.sh"
check "17s-10351 T3b: the signalled child wrote its word and returned zero" "$([ -e "$RS/word-mark" ] && echo yes):$RS_RC" "yes:0"
rs_kept "10351 T3b forwarded signal with an already-running word"

# every post-acquire, pre-hand-off exit releases the launcher's OWN lease and never a successor's. The managed layout is
# the production one: a readiness doc is a managed doc (keyless manifest row + fleet-control.json), and the wrapper's
# hand-off then asks the fleet runtime, which refuses once the fleet is paused.
RS_REAL_PY3="$(command -v python3)"
mkdir -p "$RS/pyshim"
cat > "$RS/pyshim/python3" <<'PYSHIM_EOF'
#!/usr/bin/env bash
# a test shim in front of python3: ONLY the managed fleet `handoff` op is intercepted (the doc is $5); every other call is the real python3
if [ "${3:-}" = handoff ] && [ -n "${RS_SHIM_MODE:-}" ]; then
  swap() { # a successor takes the lock between the launcher's acquire and its exit
    tok="$(cat "$XDG_RUNTIME_DIR"/himmel-readiness/*/lease-token)"
    bash "$RS_QL" release "$5" "$tok" >/dev/null 2>&1
    bash "$RS_QL" acquire "$5" successor-token-for-test >/dev/null 2>&1
  }
  case "$RS_SHIM_MODE" in
    refuse) exit 1 ;;
    successor-refuse) swap "$@"; exit 1 ;;
    block) : > "$RS_SHIM_MARK"; sleep 2 ;;
    block-successor) : > "$RS_SHIM_MARK"; sleep 2; swap "$@" ;;
  esac
fi
exec "$RS_REAL_PY3" "$@"
PYSHIM_EOF
chmod 755 "$RS/pyshim/python3"
# shellcheck disable=SC2016  # written literally, expanded when the stub runs
printf '%s\n' '#!/usr/bin/env bash' 'jq ".mode = \"paused\" | .generation += 1" "$RS_PAUSE_ANCHOR" > "$RS_PAUSE_ANCHOR.tmp" && mv "$RS_PAUSE_ANCHOR.tmp" "$RS_PAUSE_ANCHOR"' 'echo PROCEED' > "$RS/pause-preflight.sh"
chmod 755 "$RS/pause-preflight.sh"
# a managed launch must never reach the real headed-arm.sh, whose managed commit runs the machine's real usage preflight: its
# exec target is a fixture that ignores TERM and leaves a mark when (if ever) it starts
# shellcheck disable=SC2016  # written literally, expanded when the stub runs
printf '%s\n' '#!/usr/bin/env bash' 'trap "" TERM HUP INT' ': > "$RS_TARGET_MARK"' 'exit 0' > "$RS/deaf-target.sh"; chmod 755 "$RS/deaf-target.sh"
rs_pyenv=(PATH="$RS/pyshim:$RS/bin:$RS_OUT/canary-bin:$PATH" RS_REAL_PY3="$RS_REAL_PY3" HEADED_ARM_WORKER_TARGET="$RS/deaf-target.sh")
rs_free_and_gone() { # rs_free_and_gone <label>: the launcher's own lease is released and nothing of the attempt is left
  check "17s $1: the launcher's own lease is released" "$(rs_status)" "free"
  check "17s $1: the attempt directory (transport included) is removed" "$(rs_attempts)" "0"
  check "17s $1: konsole was never reached" "$([ -e "$RS_D/record" ] && echo launched || echo no)" "no"
}
if command -v flock >/dev/null 2>&1; then
  RS_MANAGED=1
  # a real fleet pause between the fleet check (before the acquire) and the hand-off (after it)
  rs_launch HEADED_ARM_WORKER_PREFLIGHT="$RS/pause-preflight.sh" RS_PAUSE_ANCHOR="$RS/hdir/m$((rs_n + 1))/fleet-control.json" HEADED_ARM_WORKER_TARGET="$RS/deaf-target.sh" RS_TARGET_MARK="$RS/target-mark-pause"
  check "17s managed pause: the wrapper refuses with 10 (fleet paused)" "$RS_RC" "10"
  contains "17s managed pause: the refusal is the fleet-paused one" "$(cat "$RS_D/out")" "fleet-paused"
  rs_free_and_gone "managed pause"
  # the same refusal when a successor took the lock after the acquire: only the launcher's own token is ever released
  rs_launch "${rs_pyenv[@]}" RS_SHIM_MODE=successor-refuse RS_TARGET_MARK="$RS/target-mark-succ"
  check "17s managed refusal with a successor: the wrapper refuses with 10" "$RS_RC" "10"
  check "17s managed refusal with a successor: the successor still holds the lock" \
    "$(rs_status):$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null || true)" "status: FRESH:successor-token-for-test"
  check "17s managed refusal with a successor: the attempt directory is removed" "$(rs_attempts)" "0"
  # a TERM while the wrapper is between its acquire and the child start ends the launch and releases the lease
  rm -f "$RS/shim-mark-s1" "$RS/target-mark-s1"
  RS_SIGNAL_AFTER="$RS/shim-mark-s1" rs_launch "${rs_pyenv[@]}" RS_SHIM_MODE=block RS_SHIM_MARK="$RS/shim-mark-s1" RS_TARGET_MARK="$RS/target-mark-s1"
  check "17s signal before the hand-off: the wrapper ends with 143" "$RS_RC" "143"
  rs_free_and_gone "signal before the hand-off"
  check "17s signal before the hand-off: the exec target was never started (the launch ends before the child exists)" "$([ -e "$RS/target-mark-s1" ] && echo started || echo never)" "never"
  rm -f "$RS/shim-mark-s2" "$RS/target-mark-s2"
  RS_SIGNAL_AFTER="$RS/shim-mark-s2" rs_launch "${rs_pyenv[@]}" RS_SHIM_MODE=block-successor RS_SHIM_MARK="$RS/shim-mark-s2" RS_TARGET_MARK="$RS/target-mark-s2"
  check "17s signal before the hand-off with a successor: the wrapper ends with 143" "$RS_RC" "143"
  check "17s signal before the hand-off with a successor: the successor still holds the lock" \
    "$(rs_status):$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null || true)" "status: FRESH:successor-token-for-test"
  check "17s signal before the hand-off with a successor: the attempt directory is removed" "$(rs_attempts)" "0"
  check "17s signal before the hand-off with a successor: the exec target was never started" "$([ -e "$RS/target-mark-s2" ] && echo started || echo never)" "never"
  # A managed doc makes headed-arm.sh run the machine's usage preflight at a fixed in-repo path (no seam): the exec target of a
  # managed fixture launch must be an absolute path inside the fixture root. The default (the in-repo headed-arm.sh), an empty
  # target and one outside the root are refused before the acquire, before any child, policy read or provider call.
  mkdir -p "$RS_OUT"; printf '%s\n' '#!/usr/bin/env bash' 'echo outside-target-ran' > "$RS_OUT/managed-target.sh"; chmod 755 "$RS_OUT/managed-target.sh"
  for rs_tgt in "$HEADED_ARM" "" "$RS_OUT/managed-target.sh"; do
    rs_cn="$(rs_canary)"
    rs_launch HEADED_ARM_WORKER_TARGET="$rs_tgt"
    rs_refused "a managed doc with the exec target [${rs_tgt##*/}]"
    rs_msg "managed target [${rs_tgt##*/}]: refused by name" "a managed doc needs HEADED_ARM_WORKER_TARGET inside the fixture root"
    check "17s managed target [${rs_tgt##*/}]: the usage preflight was never reached (no bank-preflight, no fleet census, no outside command)" \
      "$(grep -rlE 'bank-preflight|outside-target-ran' "$RS_D" 2>/dev/null | wc -l | tr -d ' '):$(( $(rs_canary) - rs_cn ))" "0:0"
  done
  rm -f "$RS/target-mark-ok"
  rs_launch HEADED_ARM_WORKER_TARGET="$RS/deaf-target.sh" RS_TARGET_MARK="$RS/target-mark-ok"
  check "17s managed target: a target inside the fixture root launches" "$RS_RC:$([ -e "$RS/target-mark-ok" ] && echo started || echo never)" "0:started"
  RS_FLAGS=(--dry-run)
  rs_launch
  check "17s-10351 T6: managed dry run refuses the in-repo target without a lease or attempt" \
    "$RS_RC:$(rs_status):$(rs_attempts)" "2:free:0"
  rs_msg "10351 T6: managed dry-run target reason" "a managed doc needs HEADED_ARM_WORKER_TARGET inside the fixture root"
  rs_launch HEADED_ARM_WORKER_TARGET="$RS/deaf-target.sh" RS_TARGET_MARK="$RS/dry-target-mark"
  check "17s-10351 T6 control: managed dry run accepts an in-root target without writing" \
    "$RS_RC:$(rs_status):$(rs_attempts):$([ -e "$RS/dry-target-mark" ] && echo launched || echo none):$(find "$RS_D" -name 'leg-*.json' -o -name '*.leg-*.json' | wc -l | tr -d ' ')" "0:free:0:none:0"
  RS_FLAGS=()
  RS_MANAGED=0
else
  echo "SKIP - 17s managed hand-off rows (fleet-manifest.sh needs util-linux flock, absent here)"
fi

# --- the delivery gate (this role's hooks, STDIO server, guard and supervisor are later cycles) and the fixture boundary:
# by default a launch is REFUSED before anything is minted, written, acquired or resolved; only an isolated fixture root, which
# must vouch for every root, binary and port the launch touches, may launch it.
rs_before="$(rs_init_calls)"
rs_launch WORKER_SESSION_READINESS_FIXTURE=
rs_refused "a launch with no fixture root (the default)"
rs_msg "delivery gate: the default refusal names every missing delivery" "its delivery is not registered (missing: session-hooks stdio-server guard supervisor)"
rs_launch WORKER_SESSION_READINESS_FIXTURE= READINESS_DELIVERED_HOOKS=1 READINESS_DELIVERED_STDIO=1 READINESS_DELIVERED_GUARD=1 READINESS_DELIVERED_SUPERVISOR=1 READINESS_DELIVERED_REAPER=1
rs_refused "a default launch even with every delivered word set in the environment"
RS_FLAGS=(--dry-run); rs_launch WORKER_SESSION_READINESS_FIXTURE=; RS_FLAGS=()
rs_refused "a default DRY RUN (it predicts the very decision)"
rs_launch WORKER_SESSION_READINESS_FIXTURE=1;  rs_refused "a bare =1 fixture seam";       rs_msg "fixture seam: =1 is not a path" "is not an absolute path"
rs_launch WORKER_SESSION_READINESS_FIXTURE=/;  rs_refused "the filesystem root as the fixture"; rs_msg "fixture seam: / is refused" "cannot be /"
rs_launch "${rs_jira[@]}" WORKER_SESSION_READINESS_FIXTURE=
rs_refused "the jira port by default (before any secret resolution)"
rs_msg "delivery gate: the jira port also names the missing credential reaper" "supervisor credential-reaper)"
check "17s delivery gate: the default jira refusal never initialised credentials" "$(rs_init_calls)" "$rs_before"
# a fixture root must be a marked, private, owned directory
mkdir -p "$tmp/rs-outside"; chmod 755 "$tmp/rs-outside"
mkdir -p "$tmp/rs-nomarker" "$tmp/rs-badmarker" "$tmp/rs-loose"; chmod 755 "$tmp/rs-nomarker" "$tmp/rs-badmarker"
printf 'not-the-marker' > "$tmp/rs-badmarker/.himmel-readiness-fixture"
printf 'himmel-readiness-fixture-v1' > "$tmp/rs-loose/.himmel-readiness-fixture"; chmod 777 "$tmp/rs-loose"
rs_launch WORKER_SESSION_READINESS_FIXTURE="$tmp/rs-nomarker";  rs_refused "a fixture root without its marker"; rs_msg "fixture root: no marker" "carries no valid .himmel-readiness-fixture marker"
rs_launch WORKER_SESSION_READINESS_FIXTURE="$tmp/rs-badmarker"; rs_refused "a fixture root with a wrong marker"; rs_msg "fixture root: wrong marker" "carries no valid .himmel-readiness-fixture marker"
rs_launch WORKER_SESSION_READINESS_FIXTURE="$tmp/rs-loose";     rs_refused "a group/world-writable fixture root"; rs_msg "fixture root: loose mode" "group/world writable"
# under a valid fixture root, EVERY root, binary and port must resolve inside it
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/rs-outside/claude"; chmod 755 "$tmp/rs-outside/claude"
cp "$RS/c1/konsole" "$tmp/rs-outside/konsole" 2>/dev/null || cp "$RS/bin/claude" "$tmp/rs-outside/konsole"
mkdir -p "$tmp/rs-outside/home/.claude" "$tmp/rs-outside/xdg" "$tmp/rs-outside/hdir" "$tmp/rs-outside/primary/scripts/jira/dist"
chmod 700 "$tmp/rs-outside/xdg"
printf '// outside client\n' > "$tmp/rs-outside/primary/scripts/jira/dist/index.js"
ln -s "$tmp/rs-outside/claude" "$RS/bin/claude-escape"; ln -s "$tmp/rs-outside/home" "$RS/home-escape"
rs_launch HOME="$tmp/rs-outside/home";                    rs_refused "HOME outside the fixture root";       rs_msg "fixture boundary: HOME" "HOME=$tmp/rs-outside/home is outside the fixture root"
rs_launch HOME="$RS/home-escape";                         rs_refused "a HOME symlink that escapes the fixture root"; rs_msg "fixture boundary: HOME symlink" "is outside the fixture root"
rs_launch CLAUDE_CONFIG_DIR="$tmp/rs-outside/home/.claude"; rs_refused "CLAUDE_CONFIG_DIR outside the fixture root"; rs_msg "fixture boundary: CLAUDE_CONFIG_DIR" "CLAUDE_CONFIG_DIR=$tmp/rs-outside/home/.claude is outside the fixture root"
rs_launch HANDOVER_DIR="$tmp/rs-outside/hdir";            rs_refused "HANDOVER_DIR outside the fixture root"; rs_msg "fixture boundary: HANDOVER_DIR" "HANDOVER_DIR=$tmp/rs-outside/hdir is outside the fixture root"
rs_launch XDG_RUNTIME_DIR="$tmp/rs-outside/xdg";          rs_refused "XDG_RUNTIME_DIR outside the fixture root"; rs_msg "fixture boundary: XDG_RUNTIME_DIR" "XDG_RUNTIME_DIR=$tmp/rs-outside/xdg is outside the fixture root"
rs_launch HEADED_ARM_WORKER_CLAUDE_BIN="$tmp/rs-outside/claude"; rs_refused "a claude binary outside the fixture root"; rs_msg "fixture boundary: claude binary" "HEADED_ARM_WORKER_CLAUDE_BIN=$tmp/rs-outside/claude is outside the fixture root"
rs_launch HEADED_ARM_WORKER_CLAUDE_BIN="$RS/bin/claude-escape"; rs_refused "a claude binary symlink that escapes the fixture root"; rs_msg "fixture boundary: claude symlink" "is outside the fixture root"
rs_launch KONSOLE_CMD="$tmp/rs-outside/konsole";          rs_refused "konsole outside the fixture root";    rs_msg "fixture boundary: konsole" "KONSOLE_CMD=$tmp/rs-outside/konsole is outside the fixture root"
rs_launch KONSOLE_CMD=konsole;                            rs_refused "a konsole found on PATH (not an absolute path)"; rs_msg "fixture boundary: konsole by name" "KONSOLE_CMD must be an absolute path inside the fixture root"
rs_launch HEADED_ARM_WORKER_PREFLIGHT="$PROCEED_PREFLIGHT"; rs_refused "a usage preflight outside the fixture root"; rs_msg "fixture boundary: preflight" "HEADED_ARM_WORKER_PREFLIGHT=$PROCEED_PREFLIGHT is outside the fixture root"
rs_launch HEADED_ARM_WORKER_PREFLIGHT=;                   rs_refused "no usage preflight (its default reads machine-wide usage state)"; rs_msg "fixture boundary: default preflight" "HEADED_ARM_WORKER_PREFLIGHT must be an absolute path inside the fixture root"
# a root that holds the account's real home is not a fixture, however it is marked (the passwd lookup is shimmed to name $RS as the home)
mkdir -p "$RS/getent-shim"
printf '%s\n' '#!/usr/bin/env bash' "echo \"fixture-user:x:\$2:\$2::$RS:/bin/bash\"" > "$RS/getent-shim/getent"; chmod 755 "$RS/getent-shim/getent"
rs_launch PATH="$RS/getent-shim:$RS/bin:$RS_OUT/canary-bin:$PATH"; rs_refused "a fixture root that contains the account's real home"; rs_msg "fixture boundary: the real home" "the fixture root contains the account's real home"
mkdir -p "$RS/getent-fail" "$RS/getent-empty" "$RS/getent-missing"
printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$RS/getent-fail/getent"
# shellcheck disable=SC2016 # written literally for the stub's positional arguments
printf '%s\n' '#!/usr/bin/env bash' 'printf "fixture-user:x:%s:%s:::/bin/bash\n" "$2" "$2"' > "$RS/getent-empty/getent"
printf '%s\n' '#!/usr/bin/env bash' "echo \"fixture-user:x:\$2:\$2::$tmp/rs-nohome-missing:/bin/bash\"" > "$RS/getent-missing/getent"
chmod 755 "$RS/getent-fail/getent" "$RS/getent-empty/getent" "$RS/getent-missing/getent"
for rs_home_case in T4:fail T4b:empty T4c:missing; do
  rs_launch PATH="$RS/getent-${rs_home_case#*:}:$RS/bin:$RS_OUT/canary-bin:$PATH"
  rs_refused "10351 ${rs_home_case%%:*} an unresolved passwd home"
  rs_msg "10351 ${rs_home_case%%:*} fixture boundary: unresolved passwd home" "the account's real home cannot be resolved"
done
rs_launch CLAUDE_CONFIG_DIR=.claude-rel
rs_refused "10351 T5 a relative CLAUDE_CONFIG_DIR"
rs_msg "10351 T5 fixture boundary: relative CLAUDE_CONFIG_DIR" "CLAUDE_CONFIG_DIR must be an absolute path inside the fixture root"
RS_DOC_OUTSIDE=1; rs_launch; RS_DOC_OUTSIDE=0
check "17s fixture boundary: a doc outside the fixture root is refused before the acquire" "$([ "$RS_RC" -ne 0 ] && echo refused):$([ -e "$RS_D/record" ] && echo launched || echo no):$(rs_attempts)" "refused:no:0"
rs_msg "fixture boundary: doc" "is outside the fixture root"
rs_before="$(rs_init_calls)"
rs_launch WORKER_SESSION_READINESS_PORT=jira WORKER_SESSION_READINESS_PRIMARY_CLI="$tmp/rs-outside/primary/scripts/jira/dist/index.js"
rs_refused "a jira client outside the fixture root"; rs_msg "fixture boundary: jira client" "is outside the fixture root"
check "17s fixture boundary: ... and no credential initialisation ran" "$(rs_init_calls)" "$rs_before"
# the exec target and the profile resolver are pinned to the in-repo files (an override only inside a valid fixture root)
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/rs-outside/target.sh"; chmod 755 "$tmp/rs-outside/target.sh"
rs_launch HEADED_ARM_WORKER_TARGET="$tmp/rs-outside/target.sh"; rs_refused "an exec target outside the repo and outside the fixture root"
rs_msg "exec pin: the target" "HEADED_ARM_WORKER_TARGET=$tmp/rs-outside/target.sh is neither the in-repo file"
printf '// outside resolver\n' > "$tmp/rs-outside/profiles.mjs"
rs_launch HEADED_ARM_WORKER_PROFILES="$tmp/rs-outside/profiles.mjs"; rs_refused "a profile resolver outside the repo and outside the fixture root"
rs_msg "exec pin: the resolver" "HEADED_ARM_WORKER_PROFILES=$tmp/rs-outside/profiles.mjs is neither the in-repo file"
# positive controls: the in-repo file by another spelling, and a target inside the fixture root
rs_launch HEADED_ARM_WORKER_TARGET="${HEADED_ARM%/*}/./${HEADED_ARM##*/}" HEADED_ARM_WORKER_PROFILES="$(cd "$HERE/../../lanes" && pwd)/./plugin-profiles.mjs"
check "17s exec pin: the in-repo target and resolver by another spelling launch" "$RS_RC:$([ -s "$RS_D/record" ] && echo yes)" "0:yes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RS/inside-target.sh"; chmod 755 "$RS/inside-target.sh"
rs_launch HEADED_ARM_WORKER_TARGET="$RS/inside-target.sh"
check "17s exec pin: a target inside the fixture root is accepted" "$RS_RC" "0"

# The claude binary is REQUIRED to be an absolute path inside the fixture root (an unset, empty, relative or bare one would be
# resolved by name through PATH), and the launch-floor gate headed-arm.sh runs (`$HEADED_ARM_CLAUDE_CLI --version`, default a
# bare `claude`) is pinned to that same binary: a contained binary plus an outside `claude` first on PATH, or an explicit outside
# HEADED_ARM_CLAUDE_CLI, must never execute the outside command.
rs_oc="PATH=$RS_OUT/canary-bin:$RS/bin:$PATH"
for rs_bin in "" relative/claude claude; do
  rs_cn="$(rs_canary)"
  rs_launch HEADED_ARM_WORKER_CLAUDE_BIN="$rs_bin" "$rs_oc"
  rs_refused "the claude binary [$rs_bin] with an outside claude first on PATH"
  rs_msg "claude binary [$rs_bin]: refused by name" "HEADED_ARM_WORKER_CLAUDE_BIN must be an absolute path inside the fixture root"
  check "17s claude binary [$rs_bin]: the outside PATH claude was never executed" "$(( $(rs_canary) - rs_cn ))" "0"
done
mkdir -p "$RS/logged"; RS_LOGGED_LOG="$RS/logged/calls.log"
# shellcheck disable=SC2016  # written literally, expanded when the stub runs
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "$RS_LOGGED_LOG"' 'exit 0' > "$RS/logged/claude"; chmod 755 "$RS/logged/claude"
: > "$RS_LOGGED_LOG"; rs_cn="$(rs_canary)"
rs_launch HEADED_ARM_WORKER_CLAUDE_BIN="$RS/logged/claude" RS_LOGGED_LOG="$RS_LOGGED_LOG" "$rs_oc"
check "17s launch floor: a contained binary with an outside claude first on PATH launches" "$RS_RC:$([ -s "$RS_D/record" ] && echo yes)" "0:yes"
check "17s launch floor: the outside PATH claude was never executed" "$(( $(rs_canary) - rs_cn ))" "0"
check "17s launch floor: the floor gate ran the contained binary, and only for its version" "$(sort -u "$RS_LOGGED_LOG" | tr '\n' ' ')" "--version "
: > "$RS_LOGGED_LOG"; rs_cn="$(rs_canary)"
rs_launch HEADED_ARM_WORKER_CLAUDE_BIN="$RS/logged/claude" RS_LOGGED_LOG="$RS_LOGGED_LOG" HEADED_ARM_CLAUDE_CLI="$RS_OUT/canary-bin/claude"
check "17s launch floor: an explicit outside HEADED_ARM_CLAUDE_CLI still launches" "$RS_RC:$([ -s "$RS_D/record" ] && echo yes)" "0:yes"
check "17s launch floor: ... the outside command was never executed (the seam is pinned to the contained binary)" "$(( $(rs_canary) - rs_cn ))" "0"
check "17s launch floor: ... the floor gate ran the contained binary instead" "$(sort -u "$RS_LOGGED_LOG" | tr '\n' ' ')" "--version "

# Inject TERM after acquire returns, before the wrapper can decode its stdout.
cat > "$RS/capture-signal.sh" <<'CAPTURE_SIGNAL_EOF'
_capture_signal_sent=0
_capture_signal_fault() {
  if [ "${READINESS:-0}" = 1 ] && [ -n "${_ready_acq:-}" ] && [ "${_ready_acq_rc:-1}" = 0 ] && [ "$_capture_signal_sent" = 0 ]; then
    _capture_signal_sent=1
    kill -"${CAPTURE_SIG:-TERM}" "$BASHPID"
  fi
}
trap _capture_signal_fault DEBUG
CAPTURE_SIGNAL_EOF
# the same signal in the instant between the acquire child's fork and the capture of its pid (the DEBUG trap fires before that assignment)
cat > "$RS/pid-signal.sh" <<'PID_SIGNAL_EOF'
_pid_signal_sent=0
_pid_signal_fault() {
  if [ "${READINESS:-0}" = 1 ] && [ "$BASH_COMMAND" = 'READINESS_ACQ_PID=$!' ] && [ "$_pid_signal_sent" = 0 ]; then
    _pid_signal_sent=1
    kill -TERM "$BASHPID"
  fi
}
trap _pid_signal_fault DEBUG
PID_SIGNAL_EOF
for rs_sig_pair in TERM:143 HUP:129 INT:130; do
  rs_sig="${rs_sig_pair%%:*}"
  if [ "$rs_sig" = INT ] && [ "${#rs_defsig[@]}" -eq 0 ]; then echo "SKIP - 17s INT rows (env --default-signal is absent: a background job cannot receive SIGINT here)"; continue; fi
  rs_launch BASH_ENV="$RS/capture-signal.sh" CAPTURE_SIG="$rs_sig"
  check "17s $rs_sig at acquire response: the wrapper ends with ${rs_sig_pair##*:}" "$RS_RC" "${rs_sig_pair##*:}"
  check "17s $rs_sig at acquire response: the known owned lease is released" "$(rs_status)" "free"
  check "17s $rs_sig at acquire response: private attempt files are removed" "$(rs_attempts)" "0"
  check "17s $rs_sig at acquire response: no child reached konsole" "$([ -e "$RS_D/record" ] && echo launched || echo no)" "no"
done

# A signal while the acquire is STILL RUNNING: the wrapper's cleanup owns and reaps the acquire child before it releases its own
# token, so the lease the acquire is about to create is freed too (a cleanup that raced ahead of it would be refused as "no lock"
# and the lease would then appear, held by a token nobody has, until its TTL). A date shim stretches only the on-behalf acquire's
# first date call (before the lock exists); the eventual state, after the stretched acquire has certainly finished, is what is asserted.
mkdir -p "$RS/slowdate"; RS_REAL_DATE="$(command -v date)"
cat > "$RS/slowdate/date" <<'SLOWDATE_EOF'
#!/usr/bin/env bash
# a test shim in front of date: ONLY the first date call of an on-behalf queue acquire is stretched. SLOW_SUCCESSOR_DOC makes a
# successor take that doc's lock inside the stretch (our acquire has not created its lock yet, so it is the one refused)
if [ "${QUEUE_LOCK_ON_BEHALF:-}" = 1 ] && [ -n "${SLOW_MARK:-}" ] && [ ! -e "$SLOW_MARK" ]; then
  : > "$SLOW_MARK"
  [ -z "${SLOW_SUCCESSOR_DOC:-}" ] || env -u QUEUE_LOCK_ON_BEHALF bash "$RS_QL" acquire "$SLOW_SUCCESSOR_DOC" successor-token-for-test >/dev/null 2>&1
  sleep "${SLOW_SECS:-1}"
fi
exec "$RS_REAL_DATE" "$@"
SLOWDATE_EOF
chmod 755 "$RS/slowdate/date"
rs_slow=(PATH="$RS/slowdate:$RS/bin:$RS_OUT/canary-bin:$PATH" RS_REAL_DATE="$RS_REAL_DATE")
# Repeated signals must not interrupt the already-running owned-token cleanup.
for rs_second in TERM HUP INT; do
  if [ "$rs_second" = INT ] && [ "${#rs_defsig[@]}" -eq 0 ]; then continue; fi
  rs_repeat_mark="$RS/repeat-$rs_second"
  RS_SECOND_SIGNAL="$rs_second" RS_SIGNAL_AFTER="$rs_repeat_mark" rs_launch "${rs_slow[@]}" SLOW_MARK="$rs_repeat_mark" SLOW_SECS=2
  check "17s TERM+$rs_second during cleanup: the acquire was running" "$([ -e "$rs_repeat_mark" ] && echo yes)" "yes"
  check "17s TERM+$rs_second during cleanup: the second signal reached the live wrapper" "$RS_SECOND_SENT" "1"
  check "17s TERM+$rs_second during cleanup: the original exit status is preserved" "$RS_RC" "143"
  sleep 3
  check "17s TERM+$rs_second during cleanup: no late lease or attempt survives" \
    "$(rs_status):$(rs_attempts):$([ -n "$(rs_lockdir)" ] && echo lockdir || echo none)" "free:0:none"
  check "17s TERM+$rs_second during cleanup: no child reached konsole" "$([ -e "$RS_D/record" ] && echo yes || echo no)" "no"
done
for rs_sig_pair in TERM:143 HUP:129 INT:130; do
  rs_sig="${rs_sig_pair%%:*}"
  if [ "$rs_sig" = INT ] && [ "${#rs_defsig[@]}" -eq 0 ]; then continue; fi
  rm -f "$RS/slow-mark-$rs_sig"
  RS_SIGNAL="$rs_sig" RS_SIGNAL_AFTER="$RS/slow-mark-$rs_sig" rs_launch "${rs_slow[@]}" SLOW_MARK="$RS/slow-mark-$rs_sig" SLOW_SECS=1
  check "17s $rs_sig while the acquire runs: the wrapper ends with ${rs_sig_pair##*:}" "$RS_RC" "${rs_sig_pair##*:}"
  check "17s $rs_sig while the acquire runs: the stretched acquire was running when the signal landed" "$([ -e "$RS/slow-mark-$rs_sig" ] && echo yes)" "yes"
  rs_free_and_gone "$rs_sig while the acquire runs"
  sleep 2
  check "17s $rs_sig while the acquire runs: still free after the stretched acquire has finished (no lease for a token nobody holds)" "$(rs_status):$(rs_attempts):$([ -n "$(rs_lockdir)" ] && echo lockdir || echo none)" "free:0:none"
done
# with a successor: it takes the lock inside the stretch, so the launcher's acquire is refused and its own-token release never touches the successor's lease
rm -f "$RS/slow-mark-succ"
RS_SIGNAL_AFTER="$RS/slow-mark-succ" rs_launch "${rs_slow[@]}" SLOW_MARK="$RS/slow-mark-succ" SLOW_SECS=1 SLOW_SUCCESSOR_DOC="$RS/hdir/u/r/readiness-v1.$((rs_n + 1)).0.md"
check "17s TERM while the acquire runs, with a successor: the wrapper ends with 143" "$RS_RC" "143"
sleep 2
check "17s TERM while the acquire runs, with a successor: the successor still holds the lock afterwards" \
  "$(rs_status):$(jq -r .session "$(rs_lockdir)/owner.json" 2>/dev/null || true)" "status: FRESH:successor-token-for-test"
check "17s TERM while the acquire runs, with a successor: the attempt directory is removed and nothing launched" "$(rs_attempts):$([ -e "$RS_D/record" ] && echo launched || echo no)" "0:no"
# the instant between the acquire child's fork and the capture of its pid is covered too
rm -f "$RS/slow-mark-pid"
rs_launch "${rs_slow[@]}" SLOW_MARK="$RS/slow-mark-pid" SLOW_SECS=1 BASH_ENV="$RS/pid-signal.sh"
check "17s TERM between the acquire's fork and its pid capture: the wrapper ends with 143" "$RS_RC" "143"
sleep 2
check "17s TERM between the acquire's fork and its pid capture: free, nothing left, nothing launched" \
  "$(rs_status):$(rs_attempts):$([ -e "$RS_D/record" ] && echo launched || echo no)" "free:0:no"
# a cleanup is bounded: an acquire that outlives the bound is stopped and said, not waited for
rm -f "$RS/slow-mark-bound"; SECONDS=0
RS_SIGNAL_AFTER="$RS/slow-mark-bound" rs_launch "${rs_slow[@]}" SLOW_MARK="$RS/slow-mark-bound" SLOW_SECS=8 WORKER_SESSION_READINESS_REAP_SECS=1
rs_elapsed=$SECONDS
check "17s an acquire that outlives the cleanup bound: the wrapper still ends with 143" "$RS_RC" "143"
check "17s an acquire that outlives the cleanup bound: the cleanup did not wait for the whole stretch" "$([ "$rs_elapsed" -lt 7 ] && echo bounded || echo "waited ${rs_elapsed}s")" "bounded"
contains "17s an acquire that outlives the cleanup bound: the stop is said" "$(cat "$RS_D/out")" "did not finish within 1s and was stopped"
sleep 8
check "17s an acquire that outlives the cleanup bound: nothing was left behind" "$(rs_status):$(rs_attempts)" "free:0"
# ... and one that ignores TERM is killed
# shellcheck disable=SC2016  # written literally, expanded when the file is sourced
printf '%s\n' '[ "${QUEUE_LOCK_ON_BEHALF:-}" != 1 ] || trap "" TERM' > "$RS/deaf-acquire.sh"
rm -f "$RS/slow-mark-deaf"; SECONDS=0
RS_SIGNAL_AFTER="$RS/slow-mark-deaf" rs_launch "${rs_slow[@]}" SLOW_MARK="$RS/slow-mark-deaf" SLOW_SECS=8 WORKER_SESSION_READINESS_REAP_SECS=1 BASH_ENV="$RS/deaf-acquire.sh"
rs_elapsed=$SECONDS
check "17s an acquire that ignores TERM: the wrapper still ends with 143, without waiting for the whole stretch" "$RS_RC:$([ "$rs_elapsed" -lt 7 ] && echo bounded || echo "waited ${rs_elapsed}s")" "143:bounded"
sleep 8
check "17s an acquire that ignores TERM: nothing was left behind" "$(rs_status):$(rs_attempts)" "free:0"

# the acquire's response still confirms the token the launcher chose: a queue that answers any other token is refused, and the
# lease the acquire did create (under the launcher's own token) is released. A sed shim rewrites only the confirmation filter.
mkdir -p "$RS/seddiv"; RS_REAL_SED="$(command -v sed)"
cat > "$RS/seddiv/sed" <<'SEDDIV_EOF'
#!/usr/bin/env bash
case "$*" in *release-token*) cat > /dev/null; echo "someone-elses-token"; exit 0 ;; esac
exec "$RS_REAL_SED" "$@"
SEDDIV_EOF
chmod 755 "$RS/seddiv/sed"
rs_launch PATH="$RS/seddiv:$RS/bin:$RS_OUT/canary-bin:$PATH" RS_REAL_SED="$RS_REAL_SED"
rs_refused "a queue that confirms a token other than the launcher's own"
rs_msg "token confirmation: the refusal names it" "the queue did not confirm the private lease token"

# nothing in any launch above executed the outside canary claude or curl (a bare claude resolves to the fixture's own stub)
check "17s canary: no launch executed the outside claude or curl on PATH" "$(rs_canary)" "0"


echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-headed-arm-worker-d.sh"
  exit 0
else
  echo "FAIL - test-headed-arm-worker-d.sh ($fails failure(s))"
  exit 1
fi
