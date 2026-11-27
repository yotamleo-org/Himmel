# shellcheck shell=bash
# sourced-lib: only ever sourced by the test-headed-arm-worker parts; the parts run in the environment their caller gives them
# shellcheck disable=SC2015,SC2034,SC2154,SC2329  # SC2015: A && B || C is intentional in the row helpers; the rest: the parts that source this file set, read and call what it defines
# scripts/handover/chief-kit/tests/testlib-headed-arm-worker.sh - what the four parts of the headed-arm-worker.sh
# suite share (test-headed-arm-worker.sh, -b, -c and -d): the hermetic environment pins, the row helpers
# (check, contains, not_contains, ends_with), the launch stubs, run_worker, the launcher tree, and the fixtures
# that more than one part reads.
# Sourced after the part has set its shell options and HERE, never run. bash 3.2-safe.
SCRIPT="$HERE/headed-arm-worker.sh"
# The bare tool names worker-impl denies from the registry, ahead of the launcher's own deny rules.
TRIM_DENY="$(jq -c '.profiles["worker-impl"].denyTools' "$HERE/../../lanes/plugin-profiles.json")"
HEADED_ARM="$HERE/../headed-arm.sh"
export HEADED_ARM_WORKER_PROFILES="$HERE/../../lanes/plugin-profiles.mjs"
export PLUGIN_PROFILES_ADAPTERS="$HERE/../../guardrails/himmel-adapters.json"
unset HIMMEL_CONSOLE_DOC 2>/dev/null || true
# shellcheck source=scripts/lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"
# The suite owns every launcher input; an ambient worker shell must not silently
# turn default-native cases into claudex cases.
unset CADENCE_USAGE_LANE WORKER_SESSION_LANE WORKER_SESSION_CONTEXT WORKER_SESSION_REPO WORKER_SESSION_REPO_MAP WORKER_SESSION_REPO_MAP_TOKENS WORKER_SESSION_REPO_MAP_TIMEOUT WORKER_SESSION_EFFORT HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV HEADED_ARM_RECORDER IMPL_GUARD_OK INLINE_IMPL_OK HIMMEL_CONSOLE_LEG HIMMEL_LEAN_WORKER_SESSION WORKER_SESSION_CLAUDE_BIN WORKER_SESSION_PROFILE WORKER_SESSION_PROFILE_SETTINGS WORKER_SESSION_PROFILE_PREFACE WORKER_SESSION_PROFILE_MCP_CONFIG WORKER_SESSION_PROFILE_NO_SETTING_SOURCES WORKER_SESSION_ID WORKER_SESSION_HEADLESS WORKER_SESSION_SUPPRESS_CR_TRIGGER WORKER_SESSION_API_LANE HIMMEL_API_LANE HIMMEL_API_ACCOUNT CR_TRIGGER_SUPPRESS HIMMEL_CONSOLE_NAME CLAUDE_PID SESSION_NAME_CMDLINE_FILE CLAUDE_CODE_EFFORT_LEVEL HIMMEL_WORKER_SESSION_CONTEXT_MODE HIMMEL_WORKER_SESSION_AUTOCOMPACT 2>/dev/null || true
# read-both: an ambient old spelling reaches the launcher too
unset WORKER_SESSION_ID 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/headed-arm-worker-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
# The launcher resolves every path it writes physically; macOS's TMPDIR sits
# behind /var -> /private/var, so pin the fixture root to its physical path.
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# Every non-dry launch wraps headed-arm.sh in a systemd scope. The
# suite puts a recorder first on PATH that logs its argv then runs the rest, so
# no run here opens a real scope (the real-scope row below opts back in). A
# --consult never reads PATH or the seam, so it stays off the recorder.
mkdir -p "$tmp/sysd-bin"
SYSD_STUB="$tmp/sysd-bin/systemd-run"
printf '#!%s\n' "$(command -v bash)" > "$SYSD_STUB"
cat >> "$SYSD_STUB" <<'SYSD_EOF'
printf '%s\n' "$*" >> "${SYSD_RECORD:-/dev/null}"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SYSD_EOF
chmod 755 "$SYSD_STUB"
# Stock macOS has no setsid, so headed-arm.sh would never start the waker; a
# pass-through stub on the same PATH dir keeps the waker rows host-independent.
printf '#!%s\nexec "$@"\n' "$(command -v bash)" > "$tmp/sysd-bin/setsid"
chmod 755 "$tmp/sysd-bin/setsid"
PATH="$tmp/sysd-bin:$PATH"
# The launch rows below assert the Linux launch shape (plain-export env, systemd
# scope, waker started); a Darwin host takes the shim branch and fails them all.
# The Darwin rows pin HEADED_ARM_UNAME=Darwin inline.
export HEADED_ARM_UNAME=Linux
export UNGUARDED_LAUNCH_OK=1  # scratch fixtures are not a guarded folder
# A dry-run row that passes a Claude Code marker (CLAUDE_CODE_*) drops the opt-out above and the policy-home seam exported below, and runs in this guarded folder, so the seam guard has nothing to deny.
guarded_repo="$(cd "$HERE/../../.." && pwd -P)"
# pin every root this suite could resolve to its own temp dir, at
# SUITE level. A chief-spawned worker exports the LIVE HANDOVER_DIR into this
# shell (headed-arm-worker.sh); the case-26 e2e below runs the real
# go.sh, which writes a GO file (merge authority) under whatever
# handover_root() resolves - so an inherited live root would get a fake GO for
# PR 26260 written into it. Same shield shape as the fleet-slots pin
# (usage-preflight.sh / headed-arm-worker.sh read HIMMEL_FLEET_SLOTS, then
# XDG_RUNTIME_DIR). Cases that need a different root (case 26) set their own.
export HANDOVER_DIR="$tmp/pinned-handover-root"
export HIMMEL_FLEET_SLOTS="$tmp/pinned-fleet-slots"
export XDG_RUNTIME_DIR="$tmp/pinned-xdg-runtime"
# every real launch appends a launch record under the himmelctl
# cache dir; pinned so this suite never writes into the operator's real
# ~/.claude/himmel (a suite must not touch shared state).
export HIMMELCTL_CACHE_DIR="$tmp/pinned-himmelctl-cache"
export HIMMEL_CONFIG_DIR="$tmp/pinned-himmel-config"
export JIRA_PROJECTS=HIMMEL,PROJ
# the single-writer register lives under $HOME/.himmel/state/holds; pinned, so no launch here can seed the real one.
REAL_HOME="$HOME"
export HOME="$tmp/pinned-home"
export HIMMEL_POLICY_FOLLOWS_HOME=1
mkdir -p "$HOME"
# the re-dispatch refusal reads page/ack records from this dir;
# pinned so no ambient ~/.himmel/state record can refuse (or pass) a case here.
export HIMMEL_DENIAL_ACK_DIR="$tmp/pinned-denial-acks"
# a real launch pre-trusts its cwd in the lane config under this home;
# pinned so no case here writes the operator's real ~/.claude.json.
export WORKER_SESSION_PRETRUST_HOME="$tmp/pinned-pretrust-home"
mkdir -p "$HANDOVER_DIR" "$HIMMEL_FLEET_SLOTS" "$XDG_RUNTIME_DIR" "$WORKER_SESSION_PRETRUST_HOME"
# the arming gate's core check (brief-lint.sh) asks the jira CLI for every brief whose title names a ticket key; scripts/jira/dist
# is untracked, absent in CI, so a fixture stand-in calls every key NOT-CORE (the refusals themselves are test-brief-lint.sh's)
mkdir -p "$tmp/notcore-jira"
cat > "$tmp/notcore-jira/index.js" <<'NCEOF'
const fs = require('fs');
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else if (a[0] === 'release' && a[1] === 'bucket-check') {
  if (process.env.BRIEF_LINT_TEST_LOG) fs.appendFileSync(process.env.BRIEF_LINT_TEST_LOG, a.join(' ') + '\n');
  for (const k of a.slice(a.indexOf('--mirror') + 2)) {
    let v = '';
    try { v = fs.readFileSync((process.env.BRIEF_LINT_TEST_BUCKET || '') + '/' + k, 'utf8').trim(); } catch (e) { v = ''; }
    console.log(v || 'IN ' + k + ' current=v1.1.3 via=mirror');
  }
}
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
NCEOF
export BRIEF_LINT_JIRA_CLI="$tmp/notcore-jira/index.js"
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
# the arming gate runs brief-lint on every brief, so a fixture brief carries
# the front-matter description and a Prior art line (title/body lines are its args).
fx_brief() { printf '%s\n' '---' 'description: fixture brief' '---' '> **Prior art:** none found (qmd -c jira-himmel "fixture")' '' "$@"; }
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
# only grep's rc 1 means "absent"; rc >1 is an execution error,
# which would otherwise pass every negative assertion vacuously (#1139).
not_contains() {
  local _rc=0
  grepq "$2" -F -e "$3" || _rc=$?
  case "$_rc" in
    0) echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)) ;;
    1) echo "ok - $1" ;;
    *) echo "FAIL - $1: grep itself failed (rc $_rc)"; fails=$((fails+1)) ;;
  esac
}
ends_with()    { grepq "$2" -E -e "$3\$" && echo "ok - $1" || { echo "FAIL - $1: [$2] does not end with [$3]"; fails=$((fails+1)); }; }

PAST=$(( $(date +%s) - 100 ))

# real (non-dry) native --profile launches now read DOC to build
# the per-worker preface, so the "some/doc.md" placeholder every other case uses
# (never opened before this ticket) must be a real, readable file wherever a
# --profile launch actually reaches that write.
some_doc="$tmp/some-doc.md"
fx_brief '# fixture doc' > "$some_doc"

# Every headed launch below arms a bus-idle-waker; the real one would poll a
# konsole that does not exist, so the wrapper's seam points at a recorder.
waker_stub="$tmp/waker-stub"
cat > "$waker_stub" <<'WAKER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${WAKER_CALLS:-/dev/null}"
WAKER_EOF
chmod 755 "$waker_stub"
export HEADED_ARM_WORKER_WAKER="$waker_stub"

# mk_launch_stubs <dir> <name> - konsole/pgrep/proc stubs, same shape
# headed-arm.sh's own suite (test-headed-arm.sh) uses: konsole records its
# FULL argv AND, filtered to the three non-secret guard vars (codex-1 review
# finding: dumping the WHOLE inherited environment to disk would also write
# exported credentials into the fixture directory), whether they reached its
# own environment - the IMPL_GUARD_OK propagation case needs that, since
# argv alone never carries an inherited env var - touches a confirmable
# marker, then stays alive; pgrep reports a match once
# that marker exists (so the post-launch visibility poll resolves
# immediately) and "no match" before that (so the pre-launch dedup layers
# pass through). session_confirmed() also walks the matched pid's real
# /proc/<pid>/cmdline for a POSITIONAL "-n <name>" pair (r9-codex-3 in
# headed-arm.sh), so the fixture cmdline must carry it NUL-separated, not
# just a comm of "claude".
mk_launch_stubs() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  cat > "$dir/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
env | grep -E '^(HIMMEL_HOLD_KEY|HIMMEL_HOLD_DOC|HIMMEL_HOLD_LABEL|WRITE_HOLD_OK|IMPL_GUARD_OK|INLINE_IMPL_OK|HIMMEL_CONSOLE|HIMMEL_CONSOLE_LEG|HEADED_ARM_REQUIRED_AUTOCOMPACT|HIMMEL_LEAN_WORKER_SESSION|WORKER_SESSION_CLAUDE_BIN|WORKER_SESSION_REMOTE_CONTROL|WORKER_SESSION_PROFILE_SETTINGS|WORKER_SESSION_PROFILE_PREFACE|WORKER_SESSION_PROFILE_MCP_CONFIG|WORKER_SESSION_PROFILE_NO_SETTING_SOURCES|CHIEF_CONTEXT|HANDOVER_DIR|HIMMEL_CONSOLE_NAME|CLAUDE_CODE_EFFORT_LEVEL|HEADED_ARM_WORKER_CLAUDE_BIN|HIMMEL_CONSOLE_JUDGE_EFFORT|HIMMEL_CONSOLE_JUDGE_DOC|HIMMEL_CONSOLE_JUDGE_QID|HIMMEL_CONSOLE_JUDGE|HIMMEL_WORKER_SESSION_CONTEXT_MODE|HIMMEL_WORKER_SESSION_AUTOCOMPACT|HIMMEL_WORKER_SESSION_CONTEXT_SHARE|WORKER_SESSION_LANE|CADENCE_USAGE_LANE|CODEX_MODEL|HIMMEL_READINESS|WORKER_SESSION_READINESS_CATALOG)=' > "$(dirname "$0")/env-record"
: > "$(dirname "$0")/confirmable"
sleep 5
KONSOLE_EOF
  chmod 755 "$dir/konsole"
  cat > "$dir/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
[ -e "$(dirname "$0")/confirmable" ] && { echo 9001; exit 0; }
exit 1
PGREP_EOF
  chmod 755 "$dir/pgrep"
  mkdir -p "$dir/proc/9001"
  echo claude > "$dir/proc/9001/comm"
  printf 'claude\0--model\0x\0-n\0%s\0load doc and continue\0' "$name" > "$dir/proc/9001/cmdline"
}

# wait_record <dir> - the launch runs backgrounded, so the stub may not have
# written yet the instant the wrapper returns. Bounded poll, never open-ended.
wait_record() {
  local dir="$1" n=0
  while [ "$n" -lt 60 ]; do
    [ -s "$dir/record" ] && return 0
    sleep 0.05
    n=$((n+1))
  done
  return 1
}

# run_worker <stubdir> <repo> <name> [model] - invokes the wrapper for real
# (non-dry), wired at the SAME seams headed-arm.sh's own suite exposes -
# HEADED_ARM_WORKER_TARGET is our own wrapper's only seam; everything else
# flows through to the real headed-arm.sh because the wrapper execs it.
# <repo> is passed as WORKER_SESSION_REPO (the wrapper's OWN contract), never as
# HEADED_ARM_REPO directly - codex-1 review finding: setting
# HEADED_ARM_REPO here would exercise headed-arm.sh's seam without ever
# proving the wrapper's own WORKER_SESSION_REPO->HEADED_ARM_REPO fold runs on the real
# (non-dry) path, which --dry-run's own report string (case 7) cannot prove
# on its own.
# PROCEED_PREFLIGHT / SKIPPED_FLEET_PREFLIGHT: stub
# scripts/lib/usage-preflight.sh invocations for HEADED_ARM_WORKER_PREFLIGHT.
# Without this, every full-launch case below would call the REAL
# usage-preflight.sh against THIS machine's own ambient process table -
# spuriously refusing on a host that genuinely has >= HIMMEL_FLEET_CAP
# `-n HIMMEL-*` sessions running (this suite is routinely run from inside
# one). run_worker defaults to the PROCEED stub so every pre-existing case
# keeps testing what it tests; the one SKIPPED-FLEET case below points at
# the other stub explicitly.
PROCEED_PREFLIGHT="$tmp/proceed-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$PROCEED_PREFLIGHT"
chmod 755 "$PROCEED_PREFLIGHT"
SKIPPED_FLEET_PREFLIGHT="$tmp/skipped-fleet-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo SKIPPED-FLEET' > "$SKIPPED_FLEET_PREFLIGHT"
chmod 755 "$SKIPPED_FLEET_PREFLIGHT"
# SKIPPED_BANK_PREFLIGHT: stub a bank-exhausted
# verdict so case 13b can assert headed-arm-worker.sh actually consults the
# SKIPPED-BANK token it computes (CADENCE_USAGE_LANE="$LANE") instead of
# discarding it, same rationale as SKIPPED_FLEET_PREFLIGHT above.
# Also write a `pid` file into the
# reservation it is standing in for, matching CADENCE_USAGE_CALLER_PID - the
# real usage-preflight.sh now does the same, and headed-arm-worker.sh's release
# path on this refusal only deletes a reservation it can verify it owns.
SKIPPED_BANK_PREFLIGHT="$tmp/skipped-bank-preflight.sh"
# shellcheck disable=SC2016  # deliberately unexpanded: written literally, evaluated when the stub runs.
printf '%s\n' '#!/usr/bin/env bash' \
  'slots="${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}"' \
  'mkdir -p "$slots/$CADENCE_USAGE_WORKER" 2>/dev/null' \
  'printf "%s\n" "$CADENCE_USAGE_CALLER_PID" > "$slots/$CADENCE_USAGE_WORKER/pid" 2>/dev/null' \
  'echo SKIPPED-BANK' > "$SKIPPED_BANK_PREFLIGHT"
chmod 755 "$SKIPPED_BANK_PREFLIGHT"

# mk_launcher_tree <dir> - a copy of the repo's scripts tree in which ONLY
# headed-arm-worker.sh is a real file (the caller mutates it); everything else is
# a symlink, so the launcher's HERE-relative lookups still resolve.
mk_launcher_tree() {
  local dst="$1" root e b
  root="$(cd "$HERE/../../.." && pwd)"
  mkdir -p "$dst/scripts/handover/chief-kit"
  for e in "$root"/*; do b="$(basename "$e")"; [ "$b" = scripts ] || ln -s "$e" "$dst/$b"; done
  for e in "$root"/scripts/*; do b="$(basename "$e")"; [ "$b" = handover ] || ln -s "$e" "$dst/scripts/$b"; done
  for e in "$root"/scripts/handover/*; do b="$(basename "$e")"; [ "$b" = chief-kit ] || ln -s "$e" "$dst/scripts/handover/$b"; done
  for e in "$root"/scripts/handover/chief-kit/*; do b="$(basename "$e")"; [ "$b" = headed-arm-worker.sh ] || ln -s "$e" "$dst/scripts/handover/chief-kit/$b"; done
  cp "$HERE/headed-arm-worker.sh" "$dst/scripts/handover/chief-kit/headed-arm-worker.sh"
}
# mk_anchorless_tree <dir> - mk_launcher_tree with a real scripts/lib directory (a symlink per library file and a COPY of the seam
# guard). The guard resolves its root from its own lib directory, so the launcher and every chokepoint it starts from this tree
# run in a tree that is not a primary checkout. A launch that passes a Claude Code marker beside a seam uses it: the guard
# refuses that on a primary checkout with no claude ancestor, which is what a CI checkout is.
mk_anchorless_tree() {
  local dst="$1" e
  mk_launcher_tree "$dst"
  rm "$dst/scripts/lib"; mkdir "$dst/scripts/lib"
  for e in "$HERE"/../../lib/*; do ln -s "$(cd "$(dirname "$e")" && pwd)/$(basename "$e")" "$dst/scripts/lib/$(basename "$e")"; done
  rm "$dst/scripts/lib/chokepoint-seam-guard.sh"; cp "$HERE/../../lib/chokepoint-seam-guard.sh" "$dst/scripts/lib/chokepoint-seam-guard.sh"
}
LAUNCH_TREE="$tmp/launch-tree"; mk_anchorless_tree "$LAUNCH_TREE"

# --- fixtures that more than one part reads (each is built here once per part; the part that asserts on it owns the rows) ---
fleet_target="$tmp/fleet-target.sh"
cat > "$fleet_target" <<'FLEET_TARGET'
#!/usr/bin/env bash
if [ "${FLEET_TEST_RC:-0}" = 0 ] && [ -n "${FLEET_LAUNCH_MANIFEST:-}" ]; then
  . "$FLEET_TEST_LIB/fleet-launch.sh" || exit 10
  fleet_launch_prepare "$2" "$1" "$FLEET_LAUNCH_MANIFEST" "$FLEET_LAUNCH_ATTEMPT" || exit 10
  fleet_launch_commit || exit 10
  [ "${FLEET_TEST_RECORD:-0}" != 1 ] || fleet_launch_outcome launched || exit 10
  printf 'launched\n' > "$HEADED_ARM_OUTCOME_FILE"
fi
exit "${FLEET_TEST_EXIT:-${FLEET_TEST_RC:-0}}"
FLEET_TARGET
chmod +x "$fleet_target"
REC_PREFLIGHT="$tmp/recording-preflight.sh"
# shellcheck disable=SC2016  # deliberately unexpanded: written literally, evaluated when the stub runs.
printf '%s\n' '#!/usr/bin/env bash' \
  'env | grep -E "^CADENCE_USAGE_(WORKER|LANE|LAUNCH)=" | sort > "$REC_PREFLIGHT_OUT"' \
  'echo PROCEED' > "$REC_PREFLIGHT"
chmod 755 "$REC_PREFLIGHT"
# RUN_WORKER_ARGS: the leading profile flags. Default is a REAL
# profile - a launch that no longer exists unprofiled is the shape a chief
# dispatches - and only a case whose subject IS the unprofiled path sets
# RUN_WORKER_ARGS=--no-profile. Set-but-empty deliberately means "no flag at all"
# (case 27b, the refusal).
RUN_WORKER_DEFAULT_ARGS="--profile worker-impl"
# shellcheck disable=SC2086  # deliberately word-split: zero, one or several flags.
run_worker() {
  local stubdir="$1" repo="$2" name="$3" model="${4:-}" preflight="${5:-$PROCEED_PREFLIGHT}"
  # Dynamic paths stay separate from RUN_WORKER_ARGS's fixed, word-split flags.
  if [ -n "${6:-}" ]; then set -- --fleet "$6"; else set --; fi
  # clear any IMPL_GUARD_OK inherited from the launching
  # shell (e.g. running this suite from inside an already-armed worker) before
  # invoking the wrapper, so case 10's propagation assertion can only pass
  # because the wrapper's own `export IMPL_GUARD_OK=1` ran - not because the
  # value was already there. HIMMEL_CONSOLE_LEG likewise.
  IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' \
  HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
  HEADED_ARM_WORKER_PREFLIGHT="$preflight" \
  KONSOLE_CMD="$stubdir/konsole" PGREP_CMD="$stubdir/pgrep" \
  WORKER_SESSION_REPO="$repo" HEADED_ARM_LOCK_DIR="$stubdir/locks" HEADED_ARM_PROC="$stubdir/proc" \
    ${RUN_WORKER_WRAP-} bash "$SCRIPT" ${RUN_WORKER_ARGS-$RUN_WORKER_DEFAULT_ARGS} "$@" "$name" "$some_doc" "$stubdir/signal-never" "$PAST" "$stubdir/log" "$model"
}
doc_tier_judge="$tmp/tier-doc-judge.md"
fx_brief '# fixture brief' '> **Tier:** opus — design: judge adjudication' > "$doc_tier_judge"
doc_tier_rm="$tmp/tier-doc-rm.md"
fx_brief '# fixture brief' '> **Tier:** opus — operator-ruling: release manager' > "$doc_tier_rm"
doc_tier_rm_phys="$(cd -P "$(dirname "$doc_tier_rm")" && pwd -P)/$(basename "$doc_tier_rm")"
claudex_stub="$tmp/claude-codex-stub"
# shellcheck disable=SC2016 # literal $* belongs to the stub script, not this one
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$(dirname "$0")/claudex-record"' > "$claudex_stub"
chmod 755 "$claudex_stub"
SHIM="$HERE/../../lanes/worker-claude-launcher.sh"
shim_argv="$tmp/shim-claude-argv"
# shellcheck disable=SC2016 # literal $@ belongs to the stub script, not this one
printf '%s\n' '#!/usr/bin/env bash' 'printf "[%s]" "$@" >> "$(dirname "$0")/shim-argv"; echo >> "$(dirname "$0")/shim-argv"' > "$shim_argv"
chmod 755 "$shim_argv"
fake4152="$tmp/fake4152"; mkdir -p "$fake4152/bin" "$fake4152/home/.local/bin"
# shellcheck disable=SC2016 # literal $0 belongs to the stub script, not this one
printf '%s\n' '#!/usr/bin/env bash' ': > "$(dirname "$0")/ran"' > "$fake4152/bin/claude"
cp "$fake4152/bin/claude" "$fake4152/home/.local/bin/claude"
chmod 755 "$fake4152/bin/claude" "$fake4152/home/.local/bin/claude"
rm -f "$fake4152/bin/ran" "$fake4152/home/.local/bin/ran"
mcpreg="$tmp/mcp-registry.json"
cat > "$mcpreg" <<'MCPREG_EOF'
{
  "floor": ["dummy@marketplace"],
  "catalog": ["dummy@marketplace"],
  "profiles": {
    "operator": null,
    "mcp-empty": { "enable": [], "mcpServers": [], "contextBudget": 1000 },
    "mcp-qmd": { "enable": [], "mcpServers": ["qmd"], "contextBudget": 1000 },
    "mcp-missing": { "enable": [], "mcpServers": ["no-such-server"], "contextBudget": 1000 },
    "mcp-none": { "enable": [], "contextBudget": 1000 }
  }
}
MCPREG_EOF
doc_tier_opus="$tmp/tier-doc-opus.md"
fx_brief '# fixture brief' '> **Tier:** opus — design: multi-step design' > "$doc_tier_opus"
LL_DIR="$HIMMELCTL_CACHE_DIR/launch-logs"
ll_line() { cat "$LL_DIR/$1.log" 2>/dev/null || true; }
door_run() {
  local d="$1"; shift
  bash "${DOOR_SCRIPT:-$SCRIPT}" --dry-run --no-profile "$@" PROJ-9999-leg "$d" /tmp/nosig 99999999999 /tmp/worker.log claude-sonnet-5 2>&1
}

# --- state that exactly one part builds and a later part reads: a function, so a part builds it only where its rows read it ---
# The part that owns the lines calls the function at the lines' old place; each later part that reads the result calls it before its first row.
haw_fx_38() {  # doc38, the throwaway repo with two worktrees, acks38 and page38 (-b section 38 builds it, -c section 51 reads it)
doc38="$tmp/c38-doc.md"
# the launcher refuses a resume_cwd that names a non-existent worker
# worktree, so the fixtures below name REAL worktrees of one throwaway repo.
repo4783="$tmp/repo4783"; mkdir -p "$repo4783/.claude/worktrees"
git -C "$repo4783" init -q
git -C "$repo4783" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$repo4783" worktree add -q -b feat/worker-38 "$repo4783/.claude/worktrees/feat+worker-38"
git -C "$repo4783" worktree add -q -b feat/worker-39 "$repo4783/.claude/worktrees/feat+worker-39"
printf -- '---\nresume_cwd: %s\ndescription: x\ntemplate_version: 3\n---\n> **Prior art:** none found (qmd -c jira-himmel "fixture")\n' "$repo4783/.claude/worktrees/feat+worker-38" > "$doc38"
acks38="$HIMMEL_DENIAL_ACK_DIR"
page38() { # <label> <class> <ts>
  mkdir -p "$acks38"
  printf 'worker=%s\ncount=1\nclass=%s\nts=%s\n' "$1" "$2" "$3" > "$acks38/$1.page"
}
}
haw_fx_39() {  # root39 and its link fixtures (-b section 39 builds it, -c section 51 reads it)
root39="$HANDOVER_DIR"
mkdir -p "$root39/u/himmel" "${root39}-sibling" "$tmp/home39/.cache/himmel/verdicts/q1" "$tmp/wt39/.claude/worktrees/feat+worker-39"
ln -s "$root39/u/himmel" "$tmp/home39/.cache/himmel/verdicts/q1/link"
ln -s "$root39" "$tmp/rootlink39"
}
haw_consult_env() {  # the consult seams -b section 41 exports for every launch after it
# a Linux --consult launch preflights bubblewrap + socat; the suite
# must not depend on the CI runner having them, so case 41 points the preflight
# at `true` (the 41h cases below point it at a missing binary to prove the refusal).
export CONSULT_BWRAP_BIN=true CONSULT_SOCAT_BIN=true
# the consult arm-time scope check reads user/managed settings; keep the
# suite off the operator's live files (the 41i cases point these at fixtures).
mkdir -p "$tmp/home41"
export CONSULT_SETTINGS_HOME="$tmp/home41" CONSULT_MANAGED_SETTINGS="$tmp/home41/managed-none.json"
# Config-dir settings are another user scope; never read a live lane's grants.
export CLAUDE_CONFIG_DIR="$tmp/home41/config"
}

# The environment an earlier part leaves exported, which every launch of a later part inherits; a later part calls it before its first row.
haw_ready26_env() {  # the gh snapshot cache dir that section 26 of test-headed-arm-worker.sh exports through ready_pass_bin
  export GH_PR_SNAPSHOT_CACHE_DIR="$tmp/ready26/snapshot-cache"
}

:
