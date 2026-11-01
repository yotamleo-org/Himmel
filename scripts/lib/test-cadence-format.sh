#!/usr/bin/env bash
# scripts/lib/test-cadence-format.sh — unit tests for cadence-format.sh.
#
# Covers POSIX runner stamps, provenance, and the shared flow/alert snippets.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/cadence-format.sh
# shellcheck disable=SC1091  # sourced file not in input on test-only commits
. "$SCRIPT_DIR/cadence-format.sh"

pass=0
fail=0

# assert_eq <desc> <got> <expected>
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    echo "  ok: $desc"
  else
    fail=$((fail + 1))
    echo "  FAIL: $desc"
    echo "        want: [$want]"
    echo "        got:  [$got]"
  fi
}

echo "[test-cadence-format] only POSIX runners contribute to the stamp"
_stamp_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cadence-posix.XXXXXX") || exit 1
printf '#!/bin/sh\n# %s 17\n' "$CADENCE_FORMAT_MARKER" > "$_stamp_tmp/pipeline-harvest.sh"
printf 'rem %s 1\r\n' "$CADENCE_FORMAT_MARKER" > "$_stamp_tmp/pipeline-harvest.bat"
for _platform in linux darwin windows; do
  assert_eq "$_platform uses the POSIX runner stamp, never the retired format" \
    "$(CADENCE_RUNNER_PLATFORM_OS="$_platform" cadence_runner_stamp "$_stamp_tmp")" "17"
done
rm -f "$_stamp_tmp/pipeline-harvest.sh"
_stamp_rc=0
CADENCE_RUNNER_PLATFORM_OS=windows cadence_runner_stamp "$_stamp_tmp" >/dev/null || _stamp_rc=$?
assert_eq "retired-format-only directory is not armed" "$_stamp_rc" "1"
rm -rf "$_stamp_tmp"

echo "[test-cadence-format] runner format stamp"
# Pinned to the exact current value, not merely "is an integer" — an
# any-integer assertion can never fail, so it pinned nothing. The point of a
# literal here is the tripwire: a version bump is a deliberate act (it nudges
# every armed operator to `arm --force`), so it should require touching this
# line. Bump it in the same commit that bumps cadence-format.sh.
if [ "$CADENCE_RUNNER_FORMAT_VERSION" = 24 ]; then
  pass=$((pass + 1)); echo "  ok: CADENCE_RUNNER_FORMAT_VERSION is the expected 24"
else
  fail=$((fail + 1)); echo "  FAIL: expected CADENCE_RUNNER_FORMAT_VERSION=24, got '$CADENCE_RUNNER_FORMAT_VERSION'"
fi

echo "[test-cadence-format] CADENCE_RUNNER_BASENAMES includes upstream-watch (HIMMEL-2367)"
case " $CADENCE_RUNNER_BASENAMES " in
  *" upstream-watch "*)
    pass=$((pass + 1)); echo "  ok: upstream-watch is a stamped runner basename" ;;
  *)
    fail=$((fail + 1)); echo "  FAIL: upstream-watch missing from CADENCE_RUNNER_BASENAMES: '$CADENCE_RUNNER_BASENAMES'" ;;
esac

echo "[test-cadence-format] cadence_runner_stamp sees armed graphmap AST/publish runners (HIMMEL-4285)"
# The weekly semantic runners (graphmap-luna/-himmel) are NOT armed here: only
# the three structural .sh runners exist, which is the live shape the probe
# missed ("not armed — no runner files found" while they sat in the crontab).
_ast_tmp="$(mktemp -d -t cadence-ast.XXXXXX)" || exit 1
for _n in graphmap-ast-luna graphmap-ast-himmel graphmap-publish-himmel; do
  printf '#!/usr/bin/env bash\n# %s 17\n' "$CADENCE_FORMAT_MARKER" > "$_ast_tmp/$_n.sh"
done
_ast_got="$(CADENCE_RUNNER_PLATFORM_OS=linux cadence_runner_stamp "$_ast_tmp")"; _ast_rc=$?
if [ "$_ast_rc" -eq 0 ] && [ "$_ast_got" = 17 ]; then
  pass=$((pass + 1)); echo "  ok: AST/publish-only .sh runners are seen (stamp 17)"
else
  fail=$((fail + 1)); echo "  FAIL: AST/publish-only .sh runners not seen (rc=$_ast_rc stamp='$_ast_got', want rc=0 stamp=17)"
fi
# Each basename alone must be seen: one row per runner, so a missing entry in
# CADENCE_RUNNER_BASENAMES names the exact runner.
for _n in graphmap-ast-luna graphmap-ast-himmel graphmap-publish-himmel graphmap-semantic-luna doctor-cadence; do
  _one_tmp="$(mktemp -d -t cadence-one.XXXXXX)" || exit 1
  printf '#!/usr/bin/env bash\n# %s 17\n' "$CADENCE_FORMAT_MARKER" > "$_one_tmp/$_n.sh"
  _one_got="$(CADENCE_RUNNER_PLATFORM_OS=linux cadence_runner_stamp "$_one_tmp")"; _one_rc=$?
  if [ "$_one_rc" -eq 0 ] && [ "$_one_got" = 17 ]; then
    pass=$((pass + 1)); echo "  ok: $_n alone is seen (stamp 17)"
  else
    fail=$((fail + 1)); echo "  FAIL: $_n alone not seen (rc=$_one_rc stamp='$_one_got', want rc=0 stamp=17)"
  fi
  rm -rf "$_one_tmp"
done
# One stale runner among them must pull the minimum down, not be masked.
printf '#!/usr/bin/env bash\n# %s 12\n' "$CADENCE_FORMAT_MARKER" > "$_ast_tmp/graphmap-publish-himmel.sh"
_ast_got="$(CADENCE_RUNNER_PLATFORM_OS=linux cadence_runner_stamp "$_ast_tmp")"
if [ "$_ast_got" = 12 ]; then
  pass=$((pass + 1)); echo "  ok: a stale publish runner pulls the minimum to 12"
else
  fail=$((fail + 1)); echo "  FAIL: expected minimum 12 with a stale publish runner, got '$_ast_got'"
fi
rm -rf "$_ast_tmp"

echo "[test-cadence-format] CADENCE_RUNNER_BASENAMES includes doctor-cadence (HIMMEL-4285)"
case " $CADENCE_RUNNER_BASENAMES " in
  *" doctor-cadence "*)
    pass=$((pass + 1)); echo "  ok: doctor-cadence is a probed runner basename" ;;
  *)
    fail=$((fail + 1)); echo "  FAIL: doctor-cadence missing from CADENCE_RUNNER_BASENAMES: '$CADENCE_RUNNER_BASENAMES'" ;;
esac

# S8: cadence_prov_record records a `job register` row (ours,
# scheduler cron) and never fails an arm when the ledger cannot be written.
_prov_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cadence-prov.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
HIMMEL_PROVENANCE_DIR="$_prov_tmp/ledger" cadence_prov_record HIMMEL-Fmt-Probe; _prc=$?
_prow=$(grep '"op":"register"' "$_prov_tmp/ledger/provenance.jsonl" 2>/dev/null)
if [ "$_prc" -eq 0 ] && grep -q '"unit":"HIMMEL-Fmt-Probe"' <<< "$_prow" \
    && grep -q '"kind":"job"' <<< "$_prow" && grep -q '"scheduler":"cron"' <<< "$_prow" \
    && grep -q '"preexisted":false' <<< "$_prow"; then
  pass=$((pass + 1)); echo "  ok: cadence_prov_record writes a job register row (cron, preexisted=false)"
else
  fail=$((fail + 1)); echo "  FAIL: cadence_prov_record row wrong (rc=$_prc): $_prow"
fi
: > "$_prov_tmp/blocker"
_pwarn=$(HIMMEL_PROVENANCE_DIR="$_prov_tmp/blocker/ledger" cadence_prov_record HIMMEL-Fmt-Probe 2>&1 >/dev/null); _prc=$?
if [ "$_prc" -eq 0 ] && grep -q 'could not record provenance for HIMMEL-Fmt-Probe' <<< "$_pwarn"; then
  pass=$((pass + 1)); echo "  ok: cadence_prov_record warns but returns 0 when the ledger is unwritable"
else
  fail=$((fail + 1)); echo "  FAIL: cadence_prov_record must WARN and return 0 on an unwritable ledger (rc=$_prc, stderr: $_pwarn)"
fi
rm -rf "$_prov_tmp"

# S18: with a real (fake) crontab on PATH holding the just-armed
# line, cadence_prov_record reads its own identity straight back and records
# --post-text <token> --field identity_v=1, so uninstall can tell this exact
# line apart from an edited one later.
_prov_tmp2=$(mktemp -d "${TMPDIR:-/tmp}/cadence-prov2.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
_cron_bin="$_prov_tmp2/bin"; mkdir -p "$_cron_bin"
cat > "$_cron_bin/crontab" <<'CRON_STUB'
#!/usr/bin/env bash
printf '%s\n' "0 3 * * * run.sh # HIMMEL-Fmt-Probe2"
CRON_STUB
chmod 755 "$_cron_bin/crontab"
PATH="$_cron_bin:$PATH" HIMMEL_PROVENANCE_DIR="$_prov_tmp2/ledger" cadence_prov_record HIMMEL-Fmt-Probe2; _prc=$?
_prow2=$(grep '"op":"register"' "$_prov_tmp2/ledger/provenance.jsonl" 2>/dev/null)
if [ "$_prc" -eq 0 ] && grep -q '"unit":"HIMMEL-Fmt-Probe2"' <<< "$_prow2" \
    && grep -q '"identity_v":1' <<< "$_prow2" \
    && grep -qE '"post":\{"sha":"[0-9a-f]{64}"\}' <<< "$_prow2"; then
  pass=$((pass + 1)); echo "  ok: cadence_prov_record reads the live line back and records identity_v=1 + a post sha"
else
  fail=$((fail + 1)); echo "  FAIL: cadence_prov_record did not record the read-back identity (rc=$_prc): $_prow2"
fi
rm -rf "$_prov_tmp2"

# --- cadence_posix_worker_start / cadence_posix_worker_end ---------
# The shared POSIX emitter every generated cadence runner inherits: flow-run
# start/end rows plus `cadence-alert.sh fail` on a failed worker and `clear` on a
# completed one. Each row generates the snippet, wraps it in a throwaway script
# around a stub flow lib and a stub alert lib, and runs it with a chosen _rc.
echo "[test-cadence-format] cadence_posix_worker_* — alert + flow rows"
_worker_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cadence-worker.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
cat > "$_worker_tmp/flow-lib.sh" <<'STUB'
#!/bin/sh
printf 'flow %s\n' "$*" >> "$WORKER_SESSION_CALLS"
case "$1" in --append-start) echo RUN-1 ;; esac
exit 0
STUB
cat > "$_worker_tmp/alert-lib.sh" <<'STUB'
#!/bin/sh
printf 'alert %s\n' "$*" >> "$WORKER_SESSION_CALLS"
exit 0
STUB
chmod 755 "$_worker_tmp/flow-lib.sh" "$_worker_tmp/alert-lib.sh"

# run_worker <rc> <ok_rcs> <skip_rcs> -> runs the emitted snippet, prints calls
# shellcheck disable=SC2016  # $_rc is emitted literally for the generated script
run_worker() {
  local rc="$1" ok="$2" skip="$3"
  {
    printf 'log=%s/worker.log\n_rc=%s\n' "$_worker_tmp" "$rc"
    cadence_posix_worker_start "$_worker_tmp/flow-lib.sh" demo-flow HIMMEL-Demo
    cadence_posix_worker_end "$_worker_tmp/flow-lib.sh" "$_worker_tmp/alert-lib.sh" demo-flow "$ok" "$skip"
    printf 'exit "$_rc"\n'
  } > "$_worker_tmp/worker.sh"
  : > "$_worker_tmp/calls"
  WORKER_SESSION_CALLS="$_worker_tmp/calls" sh "$_worker_tmp/worker.sh"
  echo "$?" > "$_worker_tmp/rc"
  cat "$_worker_tmp/calls"
}

_out=$(run_worker 3 "" "")
case "$_out" in
  *"flow --append-start demo-flow"*) pass=$((pass + 1)); echo "  ok: worker start writes a flow-run start row" ;;
  *) fail=$((fail + 1)); echo "  FAIL: no flow-run start row: $_out" ;;
esac
case "$_out" in
  *"flow --append-end demo-flow RUN-1  3 error"*) pass=$((pass + 1)); echo "  ok: non-zero rc writes an error end row" ;;
  *) fail=$((fail + 1)); echo "  FAIL: no error end row for rc 3: $_out" ;;
esac
case "$_out" in
  *"alert fail demo-flow rc-3 "*"worker.log"*) pass=$((pass + 1)); echo "  ok: non-zero rc calls cadence-alert fail" ;;
  *) fail=$((fail + 1)); echo "  FAIL: no alert fail for rc 3: $_out" ;;
esac
assert_eq "snippet preserves the worker's own rc" "$(cat "$_worker_tmp/rc")" "3"

_out=$(run_worker 0 "" "")
case "$_out" in
  *"alert clear demo-flow"*) pass=$((pass + 1)); echo "  ok: rc 0 calls cadence-alert clear" ;;
  *) fail=$((fail + 1)); echo "  FAIL: no alert clear for rc 0: $_out" ;;
esac
case "$_out" in
  *"alert fail"*) fail=$((fail + 1)); echo "  FAIL: rc 0 must not alert fail: $_out" ;;
  *) pass=$((pass + 1)); echo "  ok: rc 0 never alerts fail" ;;
esac

# An expected non-zero exit (upstream-watch's rc 10 = delta handled) is a
# success, not a page.
_out=$(run_worker 10 "0 10" "")
case "$_out" in
  *"alert clear demo-flow"*) pass=$((pass + 1)); echo "  ok: an ok-listed rc clears, never fails" ;;
  *) fail=$((fail + 1)); echo "  FAIL: ok-listed rc 10 did not clear: $_out" ;;
esac
case "$_out" in
  *"alert fail"*) fail=$((fail + 1)); echo "  FAIL: ok-listed rc 10 alerted: $_out" ;;
  *) pass=$((pass + 1)); echo "  ok: an ok-listed rc never alerts fail" ;;
esac

# A benign skip (ast-update.sh rc 4 = promote lock held) neither alerts nor
# clears an outstanding alert, and is recorded as skipped.
_out=$(run_worker 4 "" "4")
case "$_out" in
  *"alert "*) fail=$((fail + 1)); echo "  FAIL: skip rc 4 touched the alert sink: $_out" ;;
  *) pass=$((pass + 1)); echo "  ok: a skip-listed rc neither fails nor clears" ;;
esac
case "$_out" in
  *" 4 skipped"*) pass=$((pass + 1)); echo "  ok: a skip-listed rc is recorded as skipped" ;;
  *) fail=$((fail + 1)); echo "  FAIL: skip rc 4 not recorded skipped: $_out" ;;
esac
# Under cron the runner's PATH is the minimal /usr/bin:/bin, but the alert
# sender needs bun (~/.bun/bin): the alert call must carry the ARM-time PATH
# snapshot (shape), never the fire-time one.
mkdir -p "$_worker_tmp/bunbin"
printf '#!/bin/sh\nexit 0\n' > "$_worker_tmp/bunbin/bun"
chmod 755 "$_worker_tmp/bunbin/bun"
cat > "$_worker_tmp/alert-path.sh" <<'STUB'
#!/bin/sh
printf 'bun=%s\n' "$(command -v bun)" >> "$WORKER_SESSION_CALLS"
exit 0
STUB
chmod 755 "$_worker_tmp/alert-path.sh"
{
  printf 'log=%s/worker.log\n_rc=3\n' "$_worker_tmp"
  PATH="$_worker_tmp/bunbin:$PATH" cadence_posix_worker_end "$_worker_tmp/flow-lib.sh" "$_worker_tmp/alert-path.sh" demo-flow
} > "$_worker_tmp/worker-path.sh"
: > "$_worker_tmp/calls"
env -i PATH=/usr/bin:/bin WORKER_SESSION_CALLS="$_worker_tmp/calls" sh "$_worker_tmp/worker-path.sh"
case "$(cat "$_worker_tmp/calls")" in
  *"bun=$_worker_tmp/bunbin/bun"*) pass=$((pass + 1)); echo "  ok: the alert call resolves bun from the arm-time PATH under a minimal fire PATH" ;;
  *) fail=$((fail + 1)); echo "  FAIL: alert call did not see the arm-time PATH: $(cat "$_worker_tmp/calls")" ;;
esac
rm -rf "$_worker_tmp"

# --- cadence_oauth_token_lines (SCRUM-4) -------------------------------
# On macOS the interactive login lives in the Keychain, which a cron job cannot
# read, so scheduled claude runs fail "Not logged in". The runner loads
# CLAUDE_CODE_OAUTH_TOKEN from an operator-owned token file instead. Each row
# generates the snippet, then runs it ALONE under /bin/sh with a minimal env and
# a probe that prints what a child process would inherit.
echo "[test-cadence-format] cadence_oauth_token_lines — token file load"
_tok_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cadence-token.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
HOME="$_tok_tmp/home" cadence_oauth_token_lines > "$_tok_tmp/snippet.sh"
_tok_text=$(cat "$_tok_tmp/snippet.sh")
case "$_tok_text" in
  *CLAUDE_CODE_OAUTH_TOKEN*"$_tok_tmp/home/.config/himmel/claude-oauth-token"*) pass=$((pass + 1)); echo "  ok: the snippet bakes the home-relative default token path" ;;
  *) fail=$((fail + 1)); echo "  FAIL: no baked default token path in the snippet: $_tok_text" ;;
esac
case "$_tok_text" in
  *"set -x"*|*echo*|*printf*) fail=$((fail + 1)); echo "  FAIL: the snippet must never echo, print or trace the token" ;;
  *) pass=$((pass + 1)); echo "  ok: the snippet never echoes, prints or traces" ;;
esac
cat > "$_tok_tmp/probe.sh" <<'PROBE'
# read-sink-ok: test probe sources the snippet under test, a fixture file under the test's own mktemp dir
. "$1"
exec /bin/sh -c 'printf "<%s>" "${CLAUDE_CODE_OAUTH_TOKEN-UNSET}"'
PROBE
# run_token_snippet [VAR=value ...] — the snippet alone, minimal env.
run_token_snippet() { env -i PATH=/usr/bin:/bin "$@" /bin/sh "$_tok_tmp/probe.sh" "$_tok_tmp/snippet.sh"; }
printf 'fake-token-123\r\nsecond-line\n' > "$_tok_tmp/tok"
assert_eq "token file: first line is exported, CR/LF stripped, nothing printed" \
  "$(run_token_snippet HIMMEL_CLAUDE_TOKEN_FILE="$_tok_tmp/tok")" "<fake-token-123>"
assert_eq "file absent: nothing exported, nothing printed" \
  "$(run_token_snippet HIMMEL_CLAUDE_TOKEN_FILE="$_tok_tmp/absent")" "<UNSET>"
assert_eq "variable already set: not overwritten" \
  "$(run_token_snippet HIMMEL_CLAUDE_TOKEN_FILE="$_tok_tmp/tok" CLAUDE_CODE_OAUTH_TOKEN=already-set)" "<already-set>"
assert_eq "variable empty: loaded from the file" \
  "$(run_token_snippet HIMMEL_CLAUDE_TOKEN_FILE="$_tok_tmp/tok" CLAUDE_CODE_OAUTH_TOKEN=)" "<fake-token-123>"
mkdir "$_tok_tmp/dir"
assert_eq "a directory is not a token file" \
  "$(run_token_snippet HIMMEL_CLAUDE_TOKEN_FILE="$_tok_tmp/dir")" "<UNSET>"
printf 'no-newline-token' > "$_tok_tmp/tok2"
assert_eq "token file without a trailing newline loads" \
  "$(run_token_snippet HIMMEL_CLAUDE_TOKEN_FILE="$_tok_tmp/tok2")" "<no-newline-token>"
mkdir -p "$_tok_tmp/home/.config/himmel"
printf 'fake-token-123\n' > "$_tok_tmp/home/.config/himmel/claude-oauth-token"
assert_eq "default path is used when HIMMEL_CLAUDE_TOKEN_FILE is unset" \
  "$(run_token_snippet)" "<fake-token-123>"
rm -rf "$_tok_tmp"

echo
echo "[test-cadence-format] pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
